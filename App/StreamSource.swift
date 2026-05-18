import Foundation
import SwiftUI

protocol StreamSource {
  var id: String { get }
  var name: String { get }
  var baseURL: URL { get }

  func fetchAvailableLeagues() async throws -> [SportLeague]
  func fetchAvailableLeagues(forceRefresh: Bool) async throws -> [SportLeague]
  func fetchGames(for league: SportLeague) async throws -> [Game]
  /// v2.29: given a target Game, scrape this source and return the
  /// per-game page URL most likely to host the stream. Returns nil
  /// when the source isn't searchable (built-in placeholders) or no
  /// page on the source matches the target. CustomStreamSource
  /// overrides with a real implementation that uses WebViewScraper +
  /// FoundationModelScraper.
  func findStreamPage(for game: Game) async -> URL?
}

extension StreamSource {
  /// Default convenience: existing callers that don't care about cache state
  /// keep getting cached results. Force-refresh paths (pull-to-refresh,
  /// Retry, Re-run Scrape) pass `true` to invalidate `APIDiscovery`'s
  /// per-host cache before fetching.
  func fetchAvailableLeagues(forceRefresh: Bool) async throws -> [SportLeague] {
    try await fetchAvailableLeagues()
  }

  /// Default: no per-game search capability. Sources that can't be
  /// scraped (placeholder/sentinel) just return nil.
  func findStreamPage(for game: Game) async -> URL? { nil }
}

/// Distinguishes *why* `fetchAvailableLeagues` couldn't find any leagues so
/// HomeView can render a clearer empty state than the catch-all "No leagues
/// detected". Thrown by `CustomStreamSource.fetchAvailableLeagues` when the
/// scrape lands on a recognisable block / sinkhole / parking page; legitimate
/// "site loaded fine but has no games today" still returns an empty array
/// rather than throwing.
enum LoadFailureReason: Error, Equatable {
  /// DNS / TCP / TLS failure — the host can't be reached at all.
  case unreachable
  /// Cloudflare rate-limit (1015) or unresolved challenge (1020 / "Just a moment…").
  case cloudflareBlocked
  /// MPAA / Imperva takedown landing (alliance4creativity.com etc.).
  case sinkholed
  /// Domain-parking service (Rebrandly broken-link, ParkLogic, HugeDomains, GoDaddy, Sedo).
  case parked
  /// Catch-all when the LLM classifier returns an unknown blocking page type
  /// or when the homepage loads but no games + no classifiable hint is found.
  case noLeagues

  /// Headline shown in HomeView's empty state.
  var emptyStateHeadline: String {
    switch self {
    case .unreachable:        return "Can't reach this site"
    case .cloudflareBlocked:  return "Blocked by Cloudflare"
    case .sinkholed:          return "Domain has been redirected"
    case .parked:             return "This domain has no streams"
    case .noLeagues:          return "No leagues detected"
    }
  }

  /// Detail copy below the headline.
  var emptyStateBody: String {
    switch self {
    case .unreachable:
      return "Check your connection, then try again. You can also browse the site manually."
    case .cloudflareBlocked:
      return "The site's CDN is rate-limiting or challenging this device. Try again in a few minutes — if it keeps happening, your network IP may be flagged."
    case .sinkholed:
      return "The address you entered now redirects to a piracy-awareness landing page. Try a different mirror in Settings."
    case .parked:
      return "Double-check the URL — a one-letter typo can land on the wrong site."
    case .noLeagues:
      return "The site loaded but no game listings were found. Browse the site manually — streams will be intercepted automatically when you tap one."
    }
  }

  /// SF Symbol for the empty state icon.
  var emptyStateSymbol: String {
    switch self {
    case .unreachable:        return "wifi.exclamationmark"
    case .cloudflareBlocked:  return "shield.lefthalf.filled.slash"
    case .sinkholed:          return "arrow.uturn.right.circle"
    case .parked:             return "square.dashed"
    case .noLeagues:          return "questionmark.circle"
    }
  }
}

struct AnyStreamSource: Identifiable, Equatable {
  let id: String
  let name: String
  let baseURL: URL
  let isBuiltIn: Bool
  private let _fetchLeagues: () async throws -> [SportLeague]
  private let _fetchLeaguesForced: (Bool) async throws -> [SportLeague]
  private let _fetchGames: (SportLeague) async throws -> [Game]
  private let _findStreamPage: (Game) async -> URL?

  init<S: StreamSource>(_ source: S, builtIn: Bool = false) {
    id = source.id
    name = source.name
    baseURL = source.baseURL
    isBuiltIn = builtIn
    _fetchLeagues = source.fetchAvailableLeagues
    _fetchLeaguesForced = source.fetchAvailableLeagues(forceRefresh:)
    _fetchGames = source.fetchGames
    _findStreamPage = source.findStreamPage(for:)
  }

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    try await _fetchLeagues()
  }

  func fetchAvailableLeagues(forceRefresh: Bool) async throws -> [SportLeague] {
    try await _fetchLeaguesForced(forceRefresh)
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    try await _fetchGames(league)
  }

  func findStreamPage(for game: Game) async -> URL? {
    await _findStreamPage(game)
  }

  static func == (lhs: AnyStreamSource, rhs: AnyStreamSource) -> Bool {
    lhs.id == rhs.id
  }
}

@Observable
final class SourceRegistry {
  static let shared = SourceRegistry()

  private(set) var sources: [AnyStreamSource]
  var selectedSource: AnyStreamSource
  /// v2.23: the set of source IDs the user has enabled for stream
  /// resolution. Multiple sources can be active simultaneously; the
  /// HomeView orchestrator pools their scrapes for gap-filling against
  /// ESPN's canonical listing, and on-tap stream resolution tries each
  /// in turn. `selectedSource` is retained for backwards compatibility
  /// with code paths not yet migrated; it's the "primary" of the pool.
  var enabledSourceIDs: Set<String> {
    didSet {
      UserDefaults.standard.set(Array(enabledSourceIDs), forKey: Self.enabledSourceIDsKey)
    }
  }

  /// Computed pool: every added source whose id is in `enabledSourceIDs`.
  /// Order follows `sources` (insertion order). Empty when no sources are
  /// enabled — HomeView treats that as "ESPN-only listing".
  var enabledSources: [AnyStreamSource] {
    sources.filter { enabledSourceIDs.contains($0.id) }
  }
  // Last-known leagues keyed by source ID, restored from UserDefaults on launch
  // so the grid can render immediately before the network fetch completes.
  private var leagueCache: [String: [SportLeague]] = [:]

  // In-memory game cache so the Streams tab's per-league fetch can be reused
  // when the user taps a league tile (GamesView). 60 s TTL — same as
  // ScrapeCache so layers expire together.
  private var gameCache: [String: (games: [Game], expiry: Date)] = [:]

  // Per-source recent scrape diagnostics, surfaced by the in-app
  // Settings → Source Diagnostics view. Keeps the last 30 entries per source.
  private var scrapeDiagnostics: [String: [ScrapeDiagnostic]] = [:]
  // The most recent scraped link list per source, used by DiagnosticsView to
  // show the raw extracted anchors/cards (with GAME/LEAGUE badges computed
  // by the view itself).
  private var lastScrapeLinks: [String: [ScrapedLink]] = [:]

  // Leagues for the currently selected source (nil = not yet cached for this source).
  var cachedLeaguesForSelected: [SportLeague]? { leagueCache[selectedSource.id] }

  private static let customSourcesKey  = "customSources"
  private static let cachedLeaguesKey  = "cachedLeagues_v2"
  private static let enabledSourceIDsKey = "enabledSourceIDs_v2.23"

  private init() {
    var all: [AnyStreamSource] = []
    if let saved = UserDefaults.standard.array(forKey: Self.customSourcesKey) as? [[String: String]] {
      for entry in saved {
        if let name = entry["name"], let urlStr = entry["url"], let url = URL(string: urlStr) {
          all.append(AnyStreamSource(CustomStreamSource(name: name, baseURL: url), builtIn: false))
        }
      }
    }
    sources = all
    // selectedSource is the first saved source, or a sentinel placeholder that shows the empty state.
    // HomeView guards against using the placeholder when sources is empty.
    selectedSource = all.first ?? AnyStreamSource(
      CustomStreamSource(name: "None", baseURL: URL(string: "about:blank")!),
      builtIn: false
    )
    // v2.23: restore enabled source pool. Migration: if no persisted set
    // exists (upgrade from v2.22 or earlier), seed with every available
    // source — the user previously had a single "selected" source, and
    // multi-source pooling is intended to be additive (the listing they
    // saw before still works; new sources are easy to add).
    if let persisted = UserDefaults.standard.array(forKey: Self.enabledSourceIDsKey) as? [String] {
      enabledSourceIDs = Set(persisted)
    } else {
      enabledSourceIDs = Set(all.map(\.id))
    }
    // Restore per-source league cache from UserDefaults
    if let raw = UserDefaults.standard.dictionary(forKey: Self.cachedLeaguesKey) as? [String: [String]] {
      leagueCache = raw.mapValues { $0.compactMap { SportLeague(rawValue: $0) } }
    }
  }

  func persistCachedLeagues(_ leagues: [SportLeague], for sourceID: String) {
    leagueCache[sourceID] = leagues
    let raw = leagueCache.mapValues { $0.map { $0.rawValue } }
    UserDefaults.standard.set(raw, forKey: Self.cachedLeaguesKey)
  }

  // MARK: - Mirror replacement (called when HostFallback finds a working TLD variant)

  /// Replaces the URL of an existing source. Used when `HostFallback` finds a
  /// working TLD variant after the user-typed host failed DNS. The change is
  /// persisted to UserDefaults so the source-list UI shows the actual
  /// reachable URL and subsequent launches go straight to it. Source ID
  /// stays the same (it's the original host) so caches keyed by source ID
  /// keep working — only the URL inside `AnyStreamSource` changes.
  func replaceSourceURL(originalID: String, newURL: URL) {
    guard let idx = sources.firstIndex(where: { $0.id == originalID }) else { return }
    let old = sources[idx]
    let replacement = AnyStreamSource(
      CustomStreamSource(name: old.name, baseURL: newURL),
      builtIn: old.isBuiltIn
    )
    sources[idx] = replacement
    if selectedSource.id == originalID {
      selectedSource = replacement
    }
    persistCustomSources()
  }

  // MARK: - Game cache

  private static func gameCacheKey(sourceID: String, leagueID: String) -> String {
    "\(sourceID)|\(leagueID)"
  }

  /// Returns games for (source, league) when a fresh (< 60 s) entry exists.
  func cachedGames(for league: SportLeague, source: AnyStreamSource) -> [Game]? {
    let key = Self.gameCacheKey(sourceID: source.id, leagueID: league.id)
    guard let entry = gameCache[key], Date() < entry.expiry else { return nil }
    return entry.games
  }

  /// Writes games to the cache with a 60 s TTL.
  func storeGames(_ games: [Game], for league: SportLeague, source: AnyStreamSource) {
    let key = Self.gameCacheKey(sourceID: source.id, leagueID: league.id)
    gameCache[key] = (games, Date().addingTimeInterval(60))
  }

  // MARK: - Scrape diagnostics (Settings → Source Diagnostics)

  func recordScrape(_ diagnostic: ScrapeDiagnostic, links: [ScrapedLink], for sourceID: String) {
    var entries = scrapeDiagnostics[sourceID] ?? []
    entries.insert(diagnostic, at: 0)
    if entries.count > 30 { entries = Array(entries.prefix(30)) }
    scrapeDiagnostics[sourceID] = entries
    if !links.isEmpty {
      lastScrapeLinks[sourceID] = links
    }
  }

  func recentScrapes(for sourceID: String) -> [ScrapeDiagnostic] {
    scrapeDiagnostics[sourceID] ?? []
  }

  func lastLinks(for sourceID: String) -> [ScrapedLink] {
    lastScrapeLinks[sourceID] ?? []
  }

  func addSource(name: String, urlString: String) -> Bool {
    var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
      cleaned = "https://" + cleaned
    }
    guard let url = URL(string: cleaned), url.host != nil else { return false }
    guard !sources.contains(where: { $0.baseURL.host == url.host }) else { return false }
    let source = AnyStreamSource(CustomStreamSource(name: name, baseURL: url), builtIn: false)
    sources.append(source)
    // v2.23: newly-added sources are enabled by default — the v2.23 pool
    // model means "added" and "enabled" should be the same thing until
    // the user explicitly toggles one off in Settings.
    enabledSourceIDs.insert(source.id)
    persistCustomSources()
    return true
  }

  func removeSource(_ source: AnyStreamSource) {
    guard !source.isBuiltIn else { return }
    sources.removeAll { $0.id == source.id }
    enabledSourceIDs.remove(source.id)
    if selectedSource == source {
      selectedSource = sources.first ?? AnyStreamSource(
        CustomStreamSource(name: "None", baseURL: URL(string: "about:blank")!),
        builtIn: false
      )
    }
    persistCustomSources()
  }

  private func persistCustomSources() {
    let custom = sources.filter { !$0.isBuiltIn }.map { ["name": $0.name, "url": $0.baseURL.absoluteString] }
    UserDefaults.standard.set(custom, forKey: Self.customSourcesKey)
  }
}
