import Foundation

/// v2.23's ESPN-first listing engine. Produces the canonical Game list for
/// every supported league across today + the next 6 days, sourced entirely
/// from ESPN's scoreboard API via the existing `ESPNScoreboardService`
/// cache. Aggregator scraping no longer drives the listing — it only fills
/// gaps for sports ESPN doesn't cover (cricket, IIHF, MotoGP, etc.) and
/// contributes stream URLs to ESPN games it matches.
///
/// "ESPN data is never overwritten" is enforced architecturally here:
/// `todaysGames()` builds the entire list from ESPN BEFORE any aggregator
/// data flows in. The aggregator side (CustomStreamSource.findGapsAndMatches)
/// only contributes pageURLs to the existing list — it never replaces
/// team names, times, scores, or league assignments.
actor ESPNScheduleService {
  static let shared = ESPNScheduleService()

  /// Leagues we ask ESPN about. Matches the set with non-nil `apiPath`
  /// in `ESPNScoreboardService`. Order matters for popularityRank-based
  /// sorting downstream, but ESPN's events themselves carry their league
  /// so order is non-load-bearing here.
  private static let leagues: [SportLeague] = [
    .nba, .wnba, .ncaab, .nfl, .ncaaf, .mlb, .nhl, .mls,
    .premierLeague, .laLiga, .serieA, .bundesliga, .ligue1,
    .eredivisie, .ligaMx, .championsLeague, .europaLeague,
    .f1, .nascar, .ufc,
  ]

  private struct CacheEntry {
    let games: [Game]
    let expiry: Date
  }
  private var cache: CacheEntry?

  /// Returns ESPN-canonical games across every supported league. Cached
  /// for 60 s when any game is live (so scores stay fresh) or 5 min
  /// otherwise. `forceRefresh=true` ignores the cached freshness check
  /// and triggers a new fetch, but does NOT pre-clear the cache — the
  /// existing entry stays available as a fallback if the fresh fetch
  /// returns nothing (so a transient ESPN failure on rescan can't leave
  /// the user looking at an empty feed).
  func todaysGames(forceRefresh: Bool = false) async -> [Game] {
    if !forceRefresh, let cached = cache, Date() < cached.expiry {
      return cached.games
    }
    let previousCache = cache

    // Fan out per-league scoreboard fetches. Each delegates to
    // `ESPNScoreboardService.events(for:)` which already has its own
    // per-league cache + 7-day window logic.
    var leagueResults: [(SportLeague, [ESPNScoreboardService.ESPNEvent])] = []
    await withTaskGroup(of: (SportLeague, [ESPNScoreboardService.ESPNEvent]).self) { group in
      for league in Self.leagues {
        group.addTask {
          let events = await ESPNScoreboardService.shared.events(for: league)
          return (league, events)
        }
      }
      for await pair in group { leagueResults.append(pair) }
    }

    var games: [Game] = []
    for (league, events) in leagueResults {
      for event in events {
        // Skip completed events — they're not "today's games" in any
        // forward-looking sense. v2.20's hard past-game filter applied
        // here too; same intent.
        if event.isCompleted { continue }
        games.append(makeGame(from: event, league: league))
      }
    }

    // Dedupe across leagues. A given fixture may appear under both
    // .laLiga and .championsLeague (UCL clubs play in their domestic
    // league too); keep the more specific / earlier-listed entry.
    var seenIDs = Set<String>()
    let deduped = games.filter { seenIDs.insert($0.id).inserted }

    // v2.27: if the fresh fetch came back empty (transient ESPN issue,
    // network blip, off-season for every supported league at once), keep
    // the previous cache rather than overwriting good data with nothing.
    // The user perceived this as "rescan removed all the games" because
    // any aggregator gap-fills still landed while ESPN's contribution
    // vanished.
    if deduped.isEmpty, let previousCache, Date() < previousCache.expiry {
      return previousCache.games
    }
    let anyLive = deduped.contains(where: { $0.isLive })
    let ttl: TimeInterval = anyLive ? 60 : 5 * 60
    cache = CacheEntry(games: deduped, expiry: Date().addingTimeInterval(ttl))
    return deduped
  }

  /// Convert one ESPNEvent into a Game. `pageURL` defaults to the ESPN
  /// game page; `streamURLs` is empty until the aggregator-side merge
  /// populates it. Aggregator-only-game-side construction lives in
  /// CustomStreamSource.
  private func makeGame(
    from event: ESPNScoreboardService.ESPNEvent,
    league: SportLeague
  ) -> Game {
    let espnURL = URL(string: "https://www.espn.com/\(league.rawValue)/game/_/gameId/\(event.id)")
                  ?? URL(string: "https://www.espn.com")!
    return Game(
      id: "espn|\(event.id)",
      homeTeam: event.homeTeam,
      awayTeam: event.awayTeam,
      scheduledTime: event.scheduledDate,
      timeIsKnown: true,
      isLive: event.isLive,
      liveStatus: event.liveStatus,
      isEvent: false,
      isPremium: false,
      pageURL: espnURL,
      streamURLs: [],
      league: league
    )
  }
}
