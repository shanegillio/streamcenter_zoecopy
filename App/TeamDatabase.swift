import Foundation

/// Externally-hosted team→league database. Replaces the practice of inlining
/// hundreds of team names into Swift source. The app boots with a baseline
/// copy bundled into the binary (`Resources/teams.json`) so first-launch
/// classification works offline; a background task fetches the live copy
/// from
/// `https://raw.githubusercontent.com/shanegillio/altstore-source/main/teams.json`
/// and overlays it. New seasons / new teams / new leagues can be added by
/// editing the GitHub file — no app rebuild required.
///
/// Lookup is substring-based to match the legacy `teamLeagueMap` semantics:
/// a scraped "Atlético Madrid vs Barcelona" contains "atlético madrid", so
/// the entry for Atlético maps the whole pair to `.laLiga`.
actor TeamDatabase {
  static let shared = TeamDatabase()

  // MARK: - Schema

  struct Schema: Decodable {
    let schemaVersion: Int
    let updatedAt: String?
    let leagues: [String: League]
  }
  struct League: Decodable {
    let displayName: String
    let espnSlug: String?
    let popularityRank: Int?
    let teams: [Team]
  }
  struct Team: Decodable {
    let name: String
    let aliases: [String]?
  }

  // MARK: - Constants

  private static let remoteURL = URL(
    string: "https://raw.githubusercontent.com/shanegillio/altstore-source/main/teams.json"
  )!
  private static let refreshTTL: TimeInterval = 24 * 60 * 60  // 24 h
  private static let minNameLengthForSubstringMatch = 4

  // MARK: - State

  /// Flat lookup table: lowercased team name (or alias) → league.
  /// Built once per load, used for both exact and substring queries.
  private var entries: [(name: String, league: SportLeague)] = []
  /// Fast O(1) path for exact-name lookup.
  private var exact: [String: SportLeague] = [:]
  /// Live fetch state.
  private var lastRefreshAt: Date?
  private var refreshTask: Task<Void, Never>?

  // MARK: - Init

  init() {
    // Synchronous baseline load so the first query after construction
    // returns useful data without awaiting a network round-trip.
    if let bundled = Self.loadBundled() {
      ingest(bundled)
    }
    // Kick off background refresh — silently no-ops if last refresh was
    // recent enough.
    refreshTask = Task { [weak self] in
      await self?.refreshIfStale()
    }
  }

  // MARK: - Public API

  /// Returns the league whose team table matches some substring of the
  /// scraped game's `teamCombined` text. Mirrors the legacy
  /// `for (teamName, league) in teamLeagueMap where teamCombined.contains(teamName)`
  /// loop in `CustomStreamSource.mapDiscovered`. Lowercases the input.
  func league(for teamCombined: String) -> SportLeague? {
    let needle = teamCombined.lowercased()
    if let exactMatch = exact[needle.trimmingCharacters(in: .whitespaces)] {
      return exactMatch
    }
    for (name, league) in entries
      where name.count >= Self.minNameLengthForSubstringMatch
        && needle.contains(name) {
      return league
    }
    return nil
  }

  /// Direct exact-name lookup. Used by callers that already know they have
  /// a single team name (e.g., ESPN reconciliation reverse lookup).
  func leagueForExactTeam(_ name: String) -> SportLeague? {
    exact[name.lowercased().trimmingCharacters(in: .whitespaces)]
  }

  /// Used by the legacy `teamLeagueMap` static initializer to seed itself
  /// from the database. Returns canonical names only (no aliases) and
  /// dedupes; preserves the legacy substring-contains semantics by sorting
  /// long names first so "Manchester United" beats "Manchester City" on
  /// ambiguous input.
  func allEntriesByLengthDescending() -> [(name: String, league: SportLeague)] {
    entries.sorted { $0.name.count > $1.name.count }
  }

  /// Forces a refresh now (used by retry / pull-to-refresh paths in the UI).
  /// No-op if a refresh is already in flight.
  func forceRefresh() async {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      await self?.fetchRemote()
    }
    await refreshTask?.value
  }

  // MARK: - Loading

  private static func loadBundled() -> Schema? {
    guard let url = Bundle.main.url(forResource: "teams", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let schema = try? JSONDecoder().decode(Schema.self, from: data) else {
      return nil
    }
    return schema
  }

  private func refreshIfStale() async {
    if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < Self.refreshTTL {
      return
    }
    // Use the on-disk cache first if it's not yet expired.
    if let cached = Self.loadDiskCache(),
       Date().timeIntervalSince(cached.timestamp) < Self.refreshTTL {
      ingest(cached.schema)
      lastRefreshAt = cached.timestamp
      return
    }
    await fetchRemote()
  }

  private func fetchRemote() async {
    var request = URLRequest(url: Self.remoteURL, timeoutInterval: 15)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse,
          http.statusCode == 200,
          let schema = try? JSONDecoder().decode(Schema.self, from: data) else {
      return
    }
    ingest(schema)
    lastRefreshAt = Date()
    Self.persistDiskCache(data: data, timestamp: Date())
  }

  // MARK: - Disk cache

  private static var diskCacheURL: URL? {
    let fm = FileManager.default
    guard let dir = try? fm.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ) else { return nil }
    return dir.appendingPathComponent("teams-cache.json")
  }

  private static func loadDiskCache() -> (schema: Schema, timestamp: Date)? {
    guard let url = diskCacheURL,
          let data = try? Data(contentsOf: url),
          let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modDate = attrs[.modificationDate] as? Date,
          let schema = try? JSONDecoder().decode(Schema.self, from: data) else {
      return nil
    }
    return (schema, modDate)
  }

  private static func persistDiskCache(data: Data, timestamp: Date) {
    guard let url = diskCacheURL else { return }
    try? data.write(to: url, options: .atomic)
  }

  // MARK: - Ingest

  /// Priority order for ingest. Earlier entries win when a team name
  /// appears in multiple leagues (e.g. "Real Madrid" exists in both
  /// laLiga and championsLeague). Without this, Swift Dictionary's
  /// non-deterministic iteration order could classify Real Madrid as
  /// `.championsLeague` on one launch and `.laLiga` on the next — same
  /// data, different chip placement. **Domestic / specific leagues
  /// must come before umbrella competitions (UCL, UEL).**
  private static let ingestPriority: [SportLeague] = [
    // Domestic / specific (these own their teams)
    .nba, .wnba, .ncaab, .nfl, .ncaaf, .mlb, .nhl, .mls,
    .premierLeague, .laLiga, .serieA, .bundesliga, .ligue1,
    .eredivisie, .ligaMx,
    // Niche / single-league sports
    .cricket, .iihf, .f1, .nascar,
    .ufc, .mma, .boxing,
    .tennis, .golf, .wwe,
    // Umbrella competitions — teams already claimed above, only fills
    // any gaps from clubs not in their domestic table.
    .championsLeague, .europaLeague,
    // Generic catch-alls last
    .soccer, .other,
  ]

  private func ingest(_ schema: Schema) {
    var newEntries: [(name: String, league: SportLeague)] = []
    var newExact: [String: SportLeague] = [:]
    // Walk in priority order so domestic leagues claim teams before
    // umbrella competitions get a chance.
    for league in Self.ingestPriority {
      guard let leagueData = schema.leagues[league.rawValue] else { continue }
      for team in leagueData.teams {
        let canonical = team.name.lowercased()
          .trimmingCharacters(in: .whitespaces)
        if !canonical.isEmpty, newExact[canonical] == nil {
          newExact[canonical] = league
          newEntries.append((canonical, league))
        }
        for alias in team.aliases ?? [] {
          let a = alias.lowercased().trimmingCharacters(in: .whitespaces)
          if !a.isEmpty, newExact[a] == nil {
            newExact[a] = league
            newEntries.append((a, league))
          }
        }
      }
    }
    // Any leagues in the schema we don't have priority for (future
    // unknown leagues like .afl shipped ahead of the Swift case) get
    // appended at the end. Forward-compat fallback.
    for (leagueKey, leagueData) in schema.leagues {
      guard let league = SportLeague(rawValue: leagueKey),
            !Self.ingestPriority.contains(league) else { continue }
      for team in leagueData.teams {
        let canonical = team.name.lowercased().trimmingCharacters(in: .whitespaces)
        if !canonical.isEmpty, newExact[canonical] == nil {
          newExact[canonical] = league
          newEntries.append((canonical, league))
        }
        for alias in team.aliases ?? [] {
          let a = alias.lowercased().trimmingCharacters(in: .whitespaces)
          if !a.isEmpty, newExact[a] == nil {
            newExact[a] = league
            newEntries.append((a, league))
          }
        }
      }
    }
    entries = newEntries
    exact = newExact
  }
}
