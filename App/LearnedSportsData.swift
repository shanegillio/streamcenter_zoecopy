import Foundation

/// Runtime sports knowledge base populated by `APIDiscovery` whenever it
/// successfully reads structured game data from a source's JSON API.
///
/// The premise: every API-served source gives us *ground truth* — canonical
/// team names, the site's own category labels mapped to actual sports, today's
/// matchups, scheduled start times. We harvest those into a per-session
/// in-memory store that the web scraper (`CustomStreamSource`) consults as an
/// additional classification fallback. The net effect: each API source teaches
/// the app about sports knowledge that benefits every subsequent scrape,
/// including sources that have no API and would otherwise be classified by
/// just the static heuristics.
///
/// Knowledge persists for the app session only. Cleared on relaunch — the
/// next add-source flow will re-populate from APIs.
actor LearnedSportsData {
  static let shared = LearnedSportsData()

  // "philadelphia phillies" → .mlb, learned from API data
  private(set) var teamToLeague: [String: SportLeague] = [:]
  // "baseball" → .mlb — a site's own category label as it surfaces in data
  private(set) var categoryToLeague: [String: SportLeague] = [:]
  // Bumped on each ingest so callers can detect cache invalidation if needed
  private(set) var version: UInt64 = 0

  /// Ingest a batch of API-discovered games. For each game whose category
  /// can be resolved to a SportLeague (via the static `detectLeague` tables
  /// OR a previously-learned category mapping), we record the category label
  /// and both team names under that league.
  ///
  /// `resolveCategory` is the caller's classifier — typically
  /// `CustomStreamSource.detectLeague(href:text:)`. We pass it in so this
  /// type stays decoupled from CustomStreamSource for testability.
  func ingest(
    _ games: [DiscoveredGame],
    resolveCategory: (String) -> SportLeague?
  ) {
    var newTeams: [String: SportLeague] = [:]
    var newCategories: [String: SportLeague] = [:]

    for game in games {
      let cat = game.categoryLabel.lowercased()
      guard !cat.isEmpty else { continue }

      // Resolve category → league using either an existing learned mapping or
      // the caller's resolver (which consults static tables).
      let league = categoryToLeague[cat]
        ?? newCategories[cat]
        ?? resolveCategory(game.categoryLabel)

      guard let league else { continue }

      newCategories[cat] = league
      if !game.homeName.isEmpty {
        newTeams[game.homeName.lowercased()] = league
      }
      if !game.awayName.isEmpty {
        newTeams[game.awayName.lowercased()] = league
      }
    }

    // Apply atomically
    for (k, v) in newCategories { categoryToLeague[k] = v }
    for (k, v) in newTeams      { teamToLeague[k] = v }
    version &+= 1
  }

  /// Synchronous snapshot for fast lookup during scraping. Returning a
  /// value-type copy means callers can query it without `await`.
  func snapshot() -> Snapshot {
    Snapshot(
      teamToLeague: teamToLeague,
      categoryToLeague: categoryToLeague,
      version: version
    )
  }

  /// Test/debug helper: wipe the store. Not used in production code paths.
  func reset() {
    teamToLeague.removeAll()
    categoryToLeague.removeAll()
    version &+= 1
  }

  struct Snapshot: Sendable {
    let teamToLeague: [String: SportLeague]
    let categoryToLeague: [String: SportLeague]
    let version: UInt64

    /// Exact category-label match (e.g. "Baseball" → .mlb).
    func league(forCategory label: String) -> SportLeague? {
      categoryToLeague[label.lowercased()]
    }

    /// Substring match against learned team names. Slower than category lookup
    /// but useful when a scraped card text is e.g. "Cleveland Cavaliers vs
    /// Detroit Pistons - 8 PM ET" and we want to ask "do any learned teams
    /// appear in that text?"
    func league(forTextContaining text: String) -> SportLeague? {
      let lower = text.lowercased()
      // Iterate longest-first so "los angeles lakers" wins over "lakers".
      for team in teamToLeague.keys.sorted(by: { $0.count > $1.count }) {
        if team.count >= 5, lower.contains(team) {
          return teamToLeague[team]
        }
      }
      return nil
    }
  }
}
