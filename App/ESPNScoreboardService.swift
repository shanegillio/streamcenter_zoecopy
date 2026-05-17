import Foundation

// Fetches live and scheduled game data from ESPN's public scoreboard API
// and enriches scraped Game objects with accurate dates, scores, and live status.
// Results are cached per-league: 60 s when any game is live, 5 min otherwise.
actor ESPNScoreboardService {
  static let shared = ESPNScoreboardService()

  struct ESPNEvent {
    let id: String
    let homeTeam: String
    let awayTeam: String
    let homeAbbr: String
    let awayAbbr: String
    let scheduledDate: Date
    let isLive: Bool
    let isCompleted: Bool
    let liveStatus: String?
  }

  private var cache: [SportLeague: (events: [ESPNEvent], expiry: Date)] = [:]

  // ESPN sport/slug for each supported league
  static func apiPath(for league: SportLeague) -> (sport: String, slug: String)? {
    switch league {
    case .nba:           return ("basketball", "nba")
    case .wnba:          return ("basketball", "wnba")
    case .ncaab:         return ("basketball", "mens-college-basketball")
    case .nfl:           return ("football", "nfl")
    case .ncaaf:         return ("football", "college-football")
    case .mlb:           return ("baseball", "mlb")
    case .nhl:           return ("hockey", "nhl")
    case .premierLeague: return ("soccer", "eng.1")
    case .laLiga:        return ("soccer", "esp.1")
    case .serieA:        return ("soccer", "ita.1")
    case .bundesliga:    return ("soccer", "ger.1")
    case .ligue1:        return ("soccer", "fra.1")
    case .eredivisie:    return ("soccer", "ned.1")
    case .mls:           return ("soccer", "usa.1")
    case .ligaMx:        return ("soccer", "mex.1")
    case .championsLeague: return ("soccer", "uefa.champions")
    case .europaLeague:  return ("soccer", "uefa.europa")
    // Generic .soccer catch-all stays on MLS; this is the bucket every
    // unclassified soccer game lands in, and US users are the primary
    // audience.
    case .soccer:        return ("soccer", "usa.1")
    case .f1:            return ("racing", "f1")
    case .mma, .ufc:     return ("mma", "ufc")
    default:             return nil
    }
  }

  // Returns cached (or freshly fetched) ESPN events for the league.
  // Fetches today and tomorrow in parallel to cover pre-game listings.
  func events(for league: SportLeague) async -> [ESPNEvent] {
    if let cached = cache[league], Date() < cached.expiry {
      return cached.events
    }
    guard let (sport, slug) = Self.apiPath(for: league) else { return [] }

    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    let dateFmt = DateFormatter()
    dateFmt.locale = Locale(identifier: "en_US_POSIX")
    dateFmt.timeZone = etTZ
    dateFmt.dateFormat = "yyyyMMdd"
    let today    = dateFmt.string(from: Date())
    let tomorrow = dateFmt.string(from: etCal.date(byAdding: .day, value: 1, to: Date()) ?? Date())

    // Fetch today and tomorrow in parallel
    var allRaw: [[String: Any]] = []
    await withTaskGroup(of: [[String: Any]].self) { group in
      for dateStr in [today, tomorrow] {
        let urlStr = "https://site.api.espn.com/apis/site/v2/sports/\(sport)/\(slug)/scoreboard?dates=\(dateStr)"
        group.addTask {
          guard let url = URL(string: urlStr) else { return [] }
          var req = URLRequest(url: url, timeoutInterval: 10)
          req.setValue("application/json", forHTTPHeaderField: "Accept")
          guard let (data, _) = try? await URLSession.shared.data(for: req),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let events = json["events"] as? [[String: Any]] else { return [] }
          return events
        }
      }
      for await chunk in group { allRaw.append(contentsOf: chunk) }
    }

    // Deduplicate by event ID (same game can appear in both date windows around midnight)
    var seen = Set<String>()
    let parsed: [ESPNEvent] = allRaw.compactMap { raw -> ESPNEvent? in
      guard let ev = Self.parseEvent(raw, league: league) else { return nil }
      guard seen.insert(ev.id).inserted else { return nil }
      return ev
    }
    let hasLive = parsed.contains { $0.isLive }
    // 60 s when live games exist (keeps score/period fresh), 90 s otherwise
    // (short enough to catch a game starting within two refresh cycles).
    cache[league] = (parsed, Date().addingTimeInterval(hasLive ? 60 : 90))
    return parsed
  }

  // Enrich an array of scraped games with ESPN metadata.
  // Keeps pageURL and isPremium from the original; replaces team names, time,
  // and live state with canonical ESPN data. Games not found in ESPN are
  // returned unchanged.
  func enrich(_ games: [Game], for league: SportLeague) async -> [Game] {
    let espnEvents = await events(for: league)
    guard !espnEvents.isEmpty else { return games }
    return games.map { game in
      guard let match = bestMatch(for: game, in: espnEvents) else { return game }
      return Game(
        id: game.id,
        homeTeam: match.homeTeam,
        awayTeam: match.awayTeam,
        scheduledTime: match.isCompleted ? nil : match.scheduledDate,
        timeIsKnown: !match.isCompleted,
        isLive: match.isLive,
        liveStatus: match.liveStatus,
        isEvent: game.isEvent,
        isPremium: game.isPremium,
        pageURL: game.pageURL,
        league: game.league
      )
    }
  }

  /// Pre-fetch the ESPN scoreboard for a set of leagues so subsequent
  /// `enrich()` calls hit the in-memory cache instantly. Called from the
  /// detached pre-warm task in CustomStreamSource.fetchAvailableLeagues.
  func prewarm(leagues: Set<SportLeague>) async {
    await withTaskGroup(of: Void.self) { group in
      for league in leagues where Self.apiPath(for: league) != nil {
        group.addTask { _ = await self.events(for: league) }
      }
    }
  }

  /// Pre-fetch the ESPN scoreboard for **every** league we support.
  /// Used during fetchAvailableLeagues so the team-name reverse lookup
  /// (`leagueForTeam`) has data to match against — even for leagues the
  /// scraper hasn't surfaced yet. ~12 leagues × 2 days = ~24 requests,
  /// cached for 60–90 s.
  func prewarmAllSupported() async {
    let all = Set(SportLeague.allCases.filter { Self.apiPath(for: $0) != nil })
    await prewarm(leagues: all)
  }

  /// Searches the schedule cache across **every** prewarmed league for an event
  /// matching the given home/away pair. Returns `(league, event)` so callers
  /// can recover BOTH a missing league assignment AND missing time/status from
  /// a single lookup — used by `CustomStreamSource.reconcileWithESPN` to fix
  /// games that came through API discovery without league/time data (bintv.net
  /// soccer matches that landed in `.other` because no static team table
  /// covers EPL / La Liga / etc.).
  func findEvent(homeTeam: String, awayTeam: String, pageURL: URL) -> (league: SportLeague, event: ESPNEvent)? {
    // Build a synthetic Game so we can reuse `bestMatch`'s day-pinning logic.
    // `.other` here is just a placeholder — the returned league comes from the
    // cache entry that matched.
    let synthetic = Game(
      id: "_reconcile",
      homeTeam: homeTeam,
      awayTeam: awayTeam,
      scheduledTime: nil,
      timeIsKnown: false,
      isLive: false,
      liveStatus: nil,
      pageURL: pageURL,
      league: .other
    )
    // Prefer leagues by popularity so collisions resolve toward the more
    // commonly-watched competition (e.g. EPL > championship if both have
    // a "Liverpool" entry from prewarm). Cache iteration order is arbitrary.
    let sortedLeagues = cache.keys
      .filter { Date() < (cache[$0]?.expiry ?? .distantPast) }
      .sorted { $0.popularityRank < $1.popularityRank }
    for league in sortedLeagues {
      guard let entry = cache[league] else { continue }
      if let event = bestMatch(for: synthetic, in: entry.events) {
        return (league, event)
      }
    }
    return nil
  }

  /// Returns the league for a given team name by checking the in-memory schedule cache.
  /// Only works after the cache has been pre-warmed (via the detached Task in
  /// fetchAvailableLeagues). Returns nil immediately if the cache is cold.
  /// Used by CustomStreamSource to detect leagues for teams not in its static table.
  func leagueForTeam(_ teamName: String) async -> SportLeague? {
    let lower = normalize(teamName)
    guard lower.count > 3 else { return nil }
    for (league, entry) in cache where Date() < entry.expiry {
      for event in entry.events {
        let candidates = [event.homeTeam, event.awayTeam].map { normalize($0) }
        for candidate in candidates {
          if candidate.contains(lower) || lower.contains(candidate) {
            return league
          }
          // Word-overlap: "cavaliers" matches "cleveland cavaliers"
          let cWords = Set(candidate.components(separatedBy: " ").filter { $0.count > 3 })
          let lWords = Set(lower.components(separatedBy: " ").filter { $0.count > 3 })
          if !cWords.intersection(lWords).isEmpty { return league }
        }
      }
    }
    return nil
  }

  // MARK: - Matching

  private func bestMatch(for game: Game, in events: [ESPNEvent]) -> ESPNEvent? {
    // Date guard: the ESPN candidate pool covers BOTH today and tomorrow,
    // so a team-name-only match can wrongly assign today's scraped game
    // (e.g. ppv.to's /live/mlb/2026-05-15/det-tor) to tomorrow's Det-Tor
    // matchup. When we know what day the scraped game is for — either from
    // a YYYY-MM-DD segment in pageURL or from an explicit scraped time —
    // filter to ESPN events on that same ET calendar day. If nothing
    // matches that day, return nil so enrich() keeps the scraped data
    // unchanged rather than borrowing the wrong day's row.
    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ

    let pinnedDay: Date? =
      Self.dateFromPageURL(game.pageURL)
      ?? (game.timeIsKnown ? game.scheduledTime : nil)

    let pool: [ESPNEvent]
    if let day = pinnedDay {
      pool = events.filter { etCal.isDate($0.scheduledDate, inSameDayAs: day) }
      if pool.isEmpty { return nil }
    } else {
      pool = events
    }

    let hName = normalize(game.homeTeam)
    let aName = normalize(game.awayTeam)
    // 1. Both teams match (either orientation)
    if let e = pool.first(where: {
      (teamMatches(hName, normalize($0.homeTeam), normalize($0.homeAbbr)) &&
       teamMatches(aName, normalize($0.awayTeam), normalize($0.awayAbbr))) ||
      (teamMatches(hName, normalize($0.awayTeam), normalize($0.awayAbbr)) &&
       teamMatches(aName, normalize($0.homeTeam), normalize($0.homeAbbr)))
    }) { return e }
    // 2. Single-team match when away is unknown
    if game.awayTeam == "TBD" || game.awayTeam.isEmpty {
      return pool.first {
        teamMatches(hName, normalize($0.homeTeam), normalize($0.homeAbbr)) ||
        teamMatches(hName, normalize($0.awayTeam), normalize($0.awayAbbr))
      }
    }
    return nil
  }

  /// Extracts a YYYY-MM-DD date from any path segment in `url`.
  /// Used by `bestMatch` to pin scraped games to a specific calendar day
  /// before searching the ESPN candidate pool.
  private static func dateFromPageURL(_ url: URL) -> Date? {
    let pattern = #"^\d{4}-\d{2}-\d{2}$"#
    for seg in url.pathComponents {
      guard seg.range(of: pattern, options: .regularExpression) != nil else { continue }
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone(identifier: "America/New_York")!
      f.dateFormat = "yyyy-MM-dd"
      return f.date(from: seg)
    }
    return nil
  }

  private func normalize(_ s: String) -> String {
    s.lowercased()
      .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  private func teamMatches(_ scraped: String, _ espnName: String, _ espnAbbr: String) -> Bool {
    if scraped == espnName { return true }
    if scraped == espnAbbr.lowercased() { return true }
    if espnName.contains(scraped) || scraped.contains(espnName) { return true }
    // Word overlap: any word > 3 chars (catches "cavaliers" ↔ "cleveland cavaliers")
    let sWords = Set(scraped.components(separatedBy: " ").filter { $0.count > 3 })
    let eWords = Set(espnName.components(separatedBy: " ").filter { $0.count > 3 })
    return !sWords.intersection(eWords).isEmpty
  }

  // MARK: - JSON Parsing

  private static func parseEvent(_ event: [String: Any], league: SportLeague) -> ESPNEvent? {
    guard let competitions = event["competitions"] as? [[String: Any]],
          let comp = competitions.first,
          let competitors = comp["competitors"] as? [[String: Any]] else { return nil }

    func team(_ side: String) -> (name: String, abbr: String) {
      guard let c = competitors.first(where: { ($0["homeAway"] as? String) == side }),
            let t = c["team"] as? [String: Any] else { return ("", "") }
      return (t["displayName"] as? String ?? "", t["abbreviation"] as? String ?? "")
    }

    let home = team("home")
    let away = team("away")
    guard !home.name.isEmpty, !away.name.isEmpty else { return nil }

    let eventID = event["id"] as? String ?? UUID().uuidString
    let dateStr = event["date"] as? String ?? ""
    guard let scheduledDate = Self.parseDate(dateStr) else { return nil }

    let statusObj  = comp["status"] as? [String: Any]
    let statusType = (statusObj?["type"] as? [String: Any])?["state"] as? String ?? "pre"
    let isLive      = statusType == "in"
    let isCompleted = statusType == "post"

    var liveStatus: String? = nil
    if isLive {
      let clock  = statusObj?["displayClock"] as? String
      let period = statusObj?["period"] as? Int ?? 0
      let hScore = competitors.first(where: { ($0["homeAway"] as? String) == "home" }).flatMap { $0["score"] as? String } ?? ""
      let aScore = competitors.first(where: { ($0["homeAway"] as? String) == "away" }).flatMap { $0["score"] as? String } ?? ""
      let score  = (!hScore.isEmpty && !aScore.isEmpty) ? "\(hScore)-\(aScore)" : nil
      let pLabel = periodLabel(period: period, league: league)
      let detail = statusObj.flatMap { ($0["type"] as? [String: Any])?["shortDetail"] as? String }
      if let d = detail, !d.isEmpty {
        liveStatus = (score != nil) ? "\(score!) • \(d)" : d
      } else if let p = pLabel {
        liveStatus = (score != nil) ? "\(score!) • \(p)" : p
        if let c = clock, c != "0:00", !c.isEmpty { liveStatus = (liveStatus ?? "") + " \(c)" }
      } else {
        liveStatus = score
      }
    }

    return ESPNEvent(
      id: eventID,
      homeTeam: home.name, awayTeam: away.name,
      homeAbbr: home.abbr, awayAbbr: away.abbr,
      scheduledDate: scheduledDate,
      isLive: isLive, isCompleted: isCompleted,
      liveStatus: liveStatus
    )
  }

  // Parses ESPN's ISO 8601 dates which may or may not include seconds.
  // ESPN returns formats like "2026-05-15T23:30Z" (no seconds) or "2026-05-15T23:30:00Z".
  private static func parseDate(_ str: String) -> Date? {
    guard !str.isEmpty else { return nil }
    // Standard formatter handles HH:MM:SSZ
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: str) { return d }
    // Fractional seconds: 2026-05-15T23:30:00.000Z
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = isoFrac.date(from: str) { return d }
    // No seconds: 2026-05-15T23:30Z — ESPN's most common pre-game format
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    for fmt in ["yyyy-MM-dd'T'HH:mmZ", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ"] {
      df.dateFormat = fmt
      if let d = df.date(from: str) { return d }
    }
    return nil
  }

  private static func periodLabel(period: Int, league: SportLeague) -> String? {
    guard period > 0 else { return nil }
    let ord = ["1st", "2nd", "3rd", "4th", "5th", "OT"]
    let label = period <= 4 ? ord[period - 1] : "OT"
    switch league {
    case .nba, .wnba, .ncaab, .nfl, .ncaaf: return "\(label) Quarter"
    case .nhl:                               return "\(label) Period"
    case .mlb:                               return "\(label) Inning"
    default:                                 return nil
    }
  }
}
