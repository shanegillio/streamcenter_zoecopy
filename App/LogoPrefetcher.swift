import Foundation

/// Eagerly warms `URLCache.shared` with team logo PNGs for a batch of games.
///
/// Without this, every team logo on the Streams tab starts as initials and
/// transitions to its actual image only after `AsyncImage` finishes its own
/// PNG fetch — visibly slow when ~30 logos all fetch at once on first launch.
/// The prefetcher resolves each `(team, league)` to its static-table URL,
/// fires off parallel `URLSession.shared.data(for:)` requests, and lets
/// `URLCache.shared` (50/200 MB, configured in App.swift) absorb the data.
/// When the Streams tab later renders, the existing `AsyncImage` finds a
/// cache hit and paints instantly.
///
/// Each fetch is recorded into `TeamLogoDiagnostics` so we can see the
/// timing breakdown in Settings → Source Diagnostics → Logo Loading.
actor LogoPrefetcher {
  static let shared = LogoPrefetcher()

  // De-duplicate by URL so a team that appears in multiple games (e.g. live +
  // upcoming on the same day) is fetched only once per session.
  private var inFlight: Set<URL> = []
  private var prefetched: Set<URL> = []

  /// Kick off prefetches for every team in the games batch. Returns
  /// immediately for live callers; the task group inside runs in the
  /// background. Errors are swallowed (recorded in diagnostics instead).
  func warm(games: [Game]) {
    var pairs: [(team: String, league: SportLeague)] = []
    var seen = Set<String>()
    for g in games {
      if !g.homeTeam.isEmpty {
        let k = "\(g.league.id)|\(g.homeTeam.lowercased())"
        if seen.insert(k).inserted { pairs.append((g.homeTeam, g.league)) }
      }
      if !g.awayTeam.isEmpty {
        let k = "\(g.league.id)|\(g.awayTeam.lowercased())"
        if seen.insert(k).inserted { pairs.append((g.awayTeam, g.league)) }
      }
    }
    Task.detached(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for pair in pairs {
          group.addTask {
            await LogoPrefetcher.shared.warmOne(team: pair.team, league: pair.league)
          }
        }
      }
    }
  }

  private func warmOne(team: String, league: SportLeague) async {
    // Use the full resolution stack: static keyword table first (microseconds),
    // then ESPN search API for anything the static table doesn't cover.
    // This is critical for soccer clubs, Australian Football League teams,
    // and other niche-sport teams that aren't in our hardcoded MLB/NBA/NFL/
    // NHL/WNBA tables — ESPN search resolves Real Madrid, Manchester United,
    // etc. via its public team-search endpoint.
    //
    // TeamLogoCache.logoURL also populates TeamLogoStore (the observable
    // sync mirror) so the next TeamLogo.init() finds the URL immediately
    // without waiting for its own .task to run — eliminating the initials
    // flash on first render.
    //
    // TeamLogoCache also records its own resolve diagnostic, so we don't
    // double-record here — we only update the fetch outcome below.
    let resolved = await TeamLogoCache.shared.logoURL(for: team, league: league)
    let team_ = team
    let league_ = league

    guard let url = resolved else { return }
    if prefetched.contains(url) || inFlight.contains(url) {
      // Already cached this session — mark as cache hit (best-effort signal).
      await MainActor.run {
        TeamLogoDiagnostics.shared.updateFetch(
          team: team_, league: league_,
          outcome: .cacheHit(bytes: 0), fetchMs: 0
        )
      }
      return
    }
    inFlight.insert(url)
    defer { inFlight.remove(url) }

    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

    let fetchStart = Date()
    do {
      // URLSession.shared respects URLCache.shared automatically when the
      // response is cacheable. ESPN serves max-age=2608+ for these PNGs.
      let (data, response) = try await URLSession.shared.data(for: request)
      let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)

      // Determine whether this hit the URLCache or the network. URLSession
      // doesn't expose this directly, but we can sniff it from the response
      // — if the cache had the entry the latency is typically < 5ms.
      let outcome: TeamLogoDiagnostics.FetchOutcome
      if fetchMs < 20, let _ = response as? HTTPURLResponse {
        outcome = .cacheHit(bytes: data.count)
      } else {
        outcome = .networkOK(bytes: data.count)
      }
      prefetched.insert(url)
      await MainActor.run {
        TeamLogoDiagnostics.shared.updateFetch(
          team: team_, league: league_, outcome: outcome, fetchMs: fetchMs
        )
      }
    } catch {
      let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
      await MainActor.run {
        TeamLogoDiagnostics.shared.updateFetch(
          team: team_, league: league_,
          outcome: .failed(reason: error.localizedDescription),
          fetchMs: fetchMs
        )
      }
    }
  }
}
