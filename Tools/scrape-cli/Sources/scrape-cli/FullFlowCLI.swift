import Foundation

/// `scrape-cli --full-flow <URL>`
///
/// Simulates exactly what the iOS app does when a user adds a source:
///   1. Probe the host for a JSON API via `APIDiscoveryCLI` (matches the
///      iOS app's `APIDiscovery`).
///   2. Iterate every discovered game, extract its home/away team + league.
///   3. For every unique (team, league) pair, resolve a logo URL via the
///      mirrored `LogoTestCLI.resolveLogoURL` static table.
///   4. In parallel, fetch each PNG via `URLSession.shared` — this is the
///      same code path `LogoPrefetcher.warmOne` runs in the iOS app.
///   5. Report a timing summary so we can spot bottlenecks without
///      rebuilding/installing the iOS app.
///
/// When this returns "total wall-clock < 2s, network fetches in parallel,
/// 0 failed" — the iOS app should behave the same and the Streams tab
/// renders with cached logos. When something's slow or failing, we see it
/// here first and fix in code before rebuilding.

enum FullFlowCLI {
  struct Result: Encodable {
    let baseURL: String
    let api: APIStats
    let logos: LogoStats
    let totalWallclockMs: Int
  }
  struct APIStats: Encodable {
    let endpoint: String?
    let games: Int
    let categories: [String: Int]
    let probedURLs: Int
    let ms: Int
  }
  struct LogoStats: Encodable {
    let uniqueTeams: Int
    let resolved: Int
    let unresolved: [String]
    let fetchedOK: Int
    let fetchFailed: [Failure]
    let avgFetchMs: Int
    let p95FetchMs: Int
    let parallelWallclockMs: Int
    let totalBytes: Int
  }
  struct Failure: Encodable {
    let team: String
    let league: String
    let url: String
    let reason: String
  }

  static func run(baseURL: URL) async -> Result {
    let overallStart = Date()

    // 1) API discovery
    let apiStart = Date()
    let apiResult = await APIDiscoveryCLI.discover(baseURL: baseURL)
    let apiMs = Int(Date().timeIntervalSince(apiStart) * 1000)
    var catCounts: [String: Int] = [:]
    for g in apiResult.games {
      catCounts[g.categoryLabel, default: 0] += 1
    }

    // 2) Unique team list (with category → guessed league via simple table)
    var seen = Set<String>()
    var pairs: [(team: String, league: String)] = []
    for g in apiResult.games {
      for name in [g.homeName, g.awayName] where !name.isEmpty {
        let league = categoryToLeague(g.categoryLabel)
        let key = "\(league)|\(name.lowercased())"
        if seen.insert(key).inserted {
          pairs.append((name, league))
        }
      }
    }

    // 3) Resolve + 4) parallel fetch
    let fetchStart = Date()
    let fetchResults = await withTaskGroup(of: (String, String, LogoTestCLI.Result).self) { group in
      for pair in pairs {
        group.addTask {
          let r = await LogoTestCLI.run(team: pair.team, league: pair.league)
          return (pair.team, pair.league, r)
        }
      }
      var collected: [(String, String, LogoTestCLI.Result)] = []
      for await item in group { collected.append(item) }
      return collected
    }
    let parallelMs = Int(Date().timeIntervalSince(fetchStart) * 1000)

    // 5) Aggregate stats
    var resolved = 0
    var unresolved: [String] = []
    var fetchedOK = 0
    var failures: [Failure] = []
    var fetchTimes: [Int] = []
    var totalBytes = 0
    for (team, league, r) in fetchResults {
      if !r.resolved {
        unresolved.append("\(team) (\(league))")
        continue
      }
      resolved += 1
      if let bytes = r.bytes, r.httpStatus == 200, r.error == nil {
        fetchedOK += 1
        totalBytes += bytes
        if let ms = r.fetchMs { fetchTimes.append(ms) }
      } else {
        failures.append(Failure(team: team, league: league,
                                url: r.url ?? "", reason: r.error ?? "HTTP \(r.httpStatus ?? -1)"))
      }
    }
    let sorted = fetchTimes.sorted()
    let avg = sorted.isEmpty ? 0 : sorted.reduce(0, +) / sorted.count
    let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

    let totalMs = Int(Date().timeIntervalSince(overallStart) * 1000)

    return Result(
      baseURL: baseURL.absoluteString,
      api: APIStats(
        endpoint: apiResult.endpoint.isEmpty ? nil : apiResult.endpoint,
        games: apiResult.games.count,
        categories: catCounts,
        probedURLs: apiResult.probed.count,
        ms: apiMs
      ),
      logos: LogoStats(
        uniqueTeams: pairs.count,
        resolved: resolved,
        unresolved: unresolved,
        fetchedOK: fetchedOK,
        fetchFailed: failures,
        avgFetchMs: avg,
        p95FetchMs: p95,
        parallelWallclockMs: parallelMs,
        totalBytes: totalBytes
      ),
      totalWallclockMs: totalMs
    )
  }

  /// Mirror of CustomStreamSource.detectLeague's sportNameLeague / textLeague
  /// rules — sufficient for the CLI to map category strings to TeamLogoService
  /// league IDs. Not exhaustive; just enough for diagnostic timing.
  private static func categoryToLeague(_ category: String) -> String {
    let lower = category.lowercased()
    if lower.contains("baseball") { return "mlb" }
    if lower.contains("basketball") { return "nba" }
    if lower.contains("american football") { return "nfl" }
    if lower.contains("hockey") { return "nhl" }
    if lower.contains("nba") { return "nba" }
    if lower.contains("mlb") { return "mlb" }
    if lower.contains("nfl") { return "nfl" }
    if lower.contains("nhl") { return "nhl" }
    if lower.contains("wnba") { return "wnba" }
    return "unknown"
  }
}
