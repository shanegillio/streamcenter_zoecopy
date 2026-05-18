import Foundation

/// v2.30: complementary canonical listing producer using TheSportsDB.
///
/// Closes the two real ESPN gaps confirmed by Phase A audit:
/// IIHF (Mens Ice Hockey World Championships) and Cricket (IPL +
/// other international fixtures). TheSportsDB is free, no-auth, JSON,
/// CF-fronted, and returns match-level data with full team names —
/// exactly what we need to feed the existing aggregator-side matcher.
///
/// Other gap leagues from Phase A (boxing, WWE) stay aggregator-only:
/// TheSportsDB returned 0 events for them today and has no reliable
/// coverage. Tennis and golf are tournament-level only on ESPN; not
/// worth wiring through for stream-page matching.
///
/// Endpoint: GET https://www.thesportsdb.com/api/v1/json/3/eventsday.php?d=YYYY-MM-DD&s={Sport}
actor TheSportsDBProducer: ListingProducer {
  nonisolated var coveredLeagues: Set<SportLeague> { [.iihf, .cricket] }

  /// Per-day cache (date string → games). TTL matches ESPNScheduleService:
  /// 60 s when any covered game is live, 5 min otherwise.
  private struct CacheEntry {
    let games: [Game]
    let expiry: Date
  }
  private var cache: CacheEntry?

  func todaysGames() async -> [Game] {
    if let cached = cache, Date() < cached.expiry {
      return cached.games
    }

    // Today + tomorrow in user's local TZ (matches ESPNScheduleService's
    // window). TheSportsDB uses UTC dates, but a single-day mismatch is
    // tolerable here — schedule rendering already handles tz conversion.
    let etTZ = TimeZone(identifier: "America/New_York")!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = etTZ
    let today = cal.startOfDay(for: Date())
    let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = etTZ
    fmt.dateFormat = "yyyy-MM-dd"
    let dates = [fmt.string(from: today), fmt.string(from: tomorrow)]

    // Fan out: (date, sport) pairs. Two sports × two days = 4 calls.
    var games: [Game] = []
    await withTaskGroup(of: [Game].self) { group in
      for date in dates {
        group.addTask { await Self.fetchIceHockey(date: date) }
        group.addTask { await Self.fetchCricket(date: date) }
      }
      for await batch in group { games.append(contentsOf: batch) }
    }

    // Dedupe by Game.id.
    var seen = Set<String>()
    let deduped = games.filter { seen.insert($0.id).inserted }

    let anyLive = deduped.contains(where: { $0.isLive })
    let ttl: TimeInterval = anyLive ? 60 : 5 * 60
    cache = CacheEntry(games: deduped, expiry: Date().addingTimeInterval(ttl))
    return deduped
  }

  // MARK: Sport-specific fetchers

  /// Fetches Ice Hockey events for the given date and filters down to the
  /// IIHF Mens World Championships (the relevant international fixtures
  /// we don't get from ESPN). AHL / Russian VHL / other minor leagues
  /// returned by the same call are filtered out — they're not what users
  /// expect when the IIHF chip is enabled and clutter the gap-fill.
  private static func fetchIceHockey(date: String) async -> [Game] {
    let raw = await fetchEventsDay(date: date, sport: "Ice_Hockey")
    return raw.compactMap { e in
      let league = (e.strLeague ?? "").lowercased()
      let isIIHF =
        league.contains("world championship") ||
        league.contains("iihf") ||
        league.contains("world cup of hockey")
      guard isIIHF else { return nil }
      return makeGame(from: e, league: .iihf)
    }
  }

  /// Fetches all cricket events for the date. Cricket's bucket is broad
  /// in our app (IPL, T20, ODI, Test all map to .cricket) so no further
  /// league filtering.
  private static func fetchCricket(date: String) async -> [Game] {
    let raw = await fetchEventsDay(date: date, sport: "Cricket")
    return raw.compactMap { makeGame(from: $0, league: .cricket) }
  }

  // MARK: HTTP

  private static let baseURL = "https://www.thesportsdb.com/api/v1/json/3/eventsday.php"

  /// Decodes the day endpoint response. TheSportsDB returns
  /// `{"events": [...]}` on hit or `{"events": null}` on empty.
  private struct DayResponse: Decodable {
    let events: [EventDTO]?
  }

  private struct EventDTO: Decodable {
    let idEvent: String?
    let strEvent: String?
    let strHomeTeam: String?
    let strAwayTeam: String?
    let strLeague: String?
    let strSport: String?
    let strSeason: String?
    let strStatus: String?     // "NS", "Match Finished", "FT", etc.
    let strTimestamp: String?  // ISO "2026-05-18T14:20:00"
    let dateEvent: String?
    let strTime: String?
    let strVenue: String?
  }

  private static func fetchEventsDay(date: String, sport: String) async -> [EventDTO] {
    guard var components = URLComponents(string: baseURL) else { return [] }
    components.queryItems = [
      URLQueryItem(name: "d", value: date),
      URLQueryItem(name: "s", value: sport),
    ]
    guard let url = components.url else { return [] }
    var req = URLRequest(url: url, timeoutInterval: 8)
    req.setValue("StreamCenter/2.30", forHTTPHeaderField: "User-Agent")
    do {
      let (data, _) = try await URLSession.shared.data(for: req)
      let resp = try JSONDecoder().decode(DayResponse.self, from: data)
      return resp.events ?? []
    } catch {
      return []
    }
  }

  // MARK: Game construction

  private static func makeGame(from e: EventDTO, league: SportLeague) -> Game? {
    guard let id = e.idEvent, !id.isEmpty,
          let home = e.strHomeTeam, !home.isEmpty
    else { return nil }
    let away = e.strAwayTeam ?? ""
    let isEvent = away.isEmpty

    // Clean team names: TheSportsDB sometimes suffixes ice hockey teams
    // with " Ice Hockey" (e.g. "Finland Ice Hockey"). That's noise for
    // display — strip it. Cricket national sides like "England Cricket"
    // stay as-is per existing FoundationModelScraper conventions.
    let homeClean = cleanTeamName(home, league: league)
    let awayClean = cleanTeamName(away, league: league)

    let scheduledTime = parseTimestamp(e.strTimestamp)
    let timeIsKnown = scheduledTime != nil
    let isLive = inferLive(status: e.strStatus, scheduledAt: scheduledTime)

    let pageURL = URL(string: "https://www.thesportsdb.com/event/\(id)")
                  ?? URL(string: "https://www.thesportsdb.com")!

    return Game(
      id: "tsdb|\(id)",
      homeTeam: homeClean,
      awayTeam: awayClean,
      scheduledTime: scheduledTime,
      timeIsKnown: timeIsKnown,
      isLive: isLive,
      liveStatus: humanStatus(e.strStatus),
      isEvent: isEvent,
      isPremium: false,
      pageURL: pageURL,
      streamURLs: [],
      league: league
    )
  }

  private static func cleanTeamName(_ name: String, league: SportLeague) -> String {
    var s = name
    // Strip " Ice Hockey" suffix from international hockey team names.
    if league == .iihf {
      if s.hasSuffix(" Ice Hockey") { s = String(s.dropLast(" Ice Hockey".count)) }
    }
    return s
  }

  /// Status mapping. TheSportsDB uses several conventions; we collapse
  /// them to a clean string. "NS" → nil (just show scheduled time).
  /// "Match Finished" / "FT" → "Final". Live games → status as-is.
  private static func humanStatus(_ status: String?) -> String? {
    guard let s = status, !s.isEmpty else { return nil }
    let upper = s.uppercased()
    if upper == "NS" || upper == "NOT STARTED" { return nil }
    if upper.contains("FINISHED") || upper == "FT" { return "Final" }
    return s
  }

  private static func inferLive(status: String?, scheduledAt: Date?) -> Bool {
    guard let s = status else { return false }
    let upper = s.uppercased()
    if upper == "NS" || upper == "NOT STARTED" { return false }
    if upper.contains("FINISHED") || upper == "FT" { return false }
    // Anything else (e.g. "1Q", "2H", "Live") implies in-progress. Be
    // defensive: also require a scheduledAt that's already in the past.
    if let at = scheduledAt, at > Date() { return false }
    return true
  }

  private static func parseTimestamp(_ ts: String?) -> Date? {
    guard let ts, !ts.isEmpty else { return nil }
    // TheSportsDB's strTimestamp is "yyyy-MM-dd'T'HH:mm:ss" in UTC.
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return fmt.date(from: ts)
  }
}
