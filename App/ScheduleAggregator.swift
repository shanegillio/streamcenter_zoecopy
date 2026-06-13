import Foundation

/// v2.30: multi-source canonical listing orchestrator.
///
/// ESPN remains the primary `ListingProducer` for the leagues it covers
/// well; complementary producers fill gaps (cricket + IIHF via
/// `TheSportsDBProducer`). All producers run in parallel; their Games
/// are merged with ESPN winning on Game.id collision. The pipeline
/// downstream (`CustomStreamSource.reconcileWithESPN`, `HomeView`
/// matchesTeamPair) treats every canonical Game identically regardless
/// of which producer emitted it.
///
/// Source-agnostic w.r.t. stream-source plumbing: producers are about
/// canonical metadata (what games exist today), not about scraping.
protocol ListingProducer: Sendable {
  /// SportLeagues this producer can supply Games for. Used for
  /// quick-check "do we already have a producer covering this league?"
  var coveredLeagues: Set<SportLeague> { get }

  /// Returns Games for today + tomorrow. Each producer manages its own
  /// caching / TTL internally; this call may return cached results.
  func todaysGames() async -> [Game]

  /// Same, but `forceRefresh=true` bypasses the producer's own cache so a
  /// pull-to-refresh re-fetches fresh data. Defaults to the cached path.
  func todaysGames(forceRefresh: Bool) async -> [Game]
}

extension ListingProducer {
  func todaysGames(forceRefresh: Bool) async -> [Game] { await todaysGames() }
}

/// Wraps the existing `ESPNScheduleService` as a `ListingProducer`. Kept
/// in this file so the protocol + its primary impl wrappers live together.
struct ESPNListingProducer: ListingProducer {
  var coveredLeagues: Set<SportLeague> {
    [.nba, .wnba, .ncaab, .nfl, .ncaaf, .mlb, .nhl, .mls,
     .premierLeague, .laLiga, .serieA, .bundesliga, .ligue1,
     .eredivisie, .ligaMx, .championsLeague, .europaLeague,
     .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague,
     .f1, .nascar, .ufc, .mma]
  }

  func todaysGames() async -> [Game] {
    await ESPNScheduleService.shared.todaysGames()
  }

  func todaysGames(forceRefresh: Bool) async -> [Game] {
    await ESPNScheduleService.shared.todaysGames(forceRefresh: forceRefresh)
  }
}

actor ScheduleAggregator {
  static let shared = ScheduleAggregator()

  /// Producers run in parallel. Order in this array is only a
  /// tie-breaker on Game.id collision (first wins). ESPN is first
  /// because it has the most accurate live/score data.
  private let producers: [any ListingProducer] = [
    ESPNListingProducer(),
    TheSportsDBProducer(),
  ]

  func todaysGames(forceRefresh: Bool = false) async -> [Game] {
    // Run all producers in parallel. Each manages its own cache.
    var results: [[Game]] = []
    await withTaskGroup(of: [Game].self) { group in
      for producer in producers {
        group.addTask {
          await producer.todaysGames(forceRefresh: forceRefresh)
        }
      }
      for await games in group { results.append(games) }
    }

    // Merge. First producer wins on Game.id collision (ESPN first).
    var seenIDs = Set<String>()
    var merged: [Game] = []
    for games in results {
      for g in games where seenIDs.insert(g.id).inserted {
        merged.append(g)
      }
    }
    return merged
  }
}
