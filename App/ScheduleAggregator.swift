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
  /// caching / TTL internally; this call may return cached results unless
  /// `forceRefresh` is set (e.g. pull-to-refresh), which bypasses the cache.
  func todaysGames(forceRefresh: Bool) async -> [Game]
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
    // Run all producers in parallel. Each manages its own cache. Results
    // are slotted by producer index so merge order is deterministic
    // regardless of which task finishes first (task-group completion order
    // is otherwise nondeterministic).
    var results = [[Game]](repeating: [], count: producers.count)
    await withTaskGroup(of: (Int, [Game]).self) { group in
      for (index, producer) in producers.enumerated() {
        group.addTask { (index, await producer.todaysGames(forceRefresh: forceRefresh)) }
      }
      for await (index, games) in group { results[index] = games }
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
