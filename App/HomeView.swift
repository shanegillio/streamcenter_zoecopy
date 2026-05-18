import SwiftUI

struct HomeView: View {
  @Environment(SourceRegistry.self) private var registry
  @Environment(FavoritesStore.self) private var favorites
  @State private var availableLeagues: [SportLeague] = []
  @State private var allLiveGames: [Game] = []
  @State private var allUpcomingGames: [Game] = []
  @State private var isLoadingLeagues = true
  @State private var isLoadingLive = false
  /// Specific classified reason for the empty state, set when fetchAvailableLeagues
  /// throws a `LoadFailureReason`. `nil` means either still loading or success.
  @State private var loadFailureReason: LoadFailureReason? = nil
  @State private var isRetrying = false
  /// Active filter for the chip row. `nil` means "All" (show every league).
  @State private var selectedFilter: SportLeague? = nil

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Streams")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
              SettingsView()
                .environment(favorites)
                .environment(registry)
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
          }
        }
    }
    .task { await loadLeagues() }
    .task(id: registry.selectedSource.id) {
      guard !registry.sources.isEmpty else { return }
      // Refresh live games every 60s while the app is foregrounded so the
      // home stream list stays current without the user pulling-to-refresh.
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard !Task.isCancelled else { return }
        await loadAllLiveGames()
      }
    }
    .onChange(of: registry.selectedSource) { _, _ in Task { await loadLeagues() } }
    .onChange(of: registry.sources)        { _, _ in Task { await loadLeagues() } }
    // v2.23: pool toggles change the gap-fill mix without re-fetching ESPN
    // (ESPNScheduleService cache stays warm).
    .onChange(of: registry.enabledSourceIDs) { _, _ in Task { await loadLeagues() } }
    // v2.22: favorites only RE-SORT the existing arrays. Previously they
    // re-fetched the entire feed, which under v2.21's ESPN-canonical
    // pipeline meant a fresh scrape + ESPN reconcile every time the user
    // toggled a star — visible as "streams briefly disappear" while the
    // refetch ran. The whole point of favoriting is to reorder what's
    // already loaded.
    .onChange(of: favorites.favoriteLeagues) { _, _ in resortGames() }
    .onChange(of: favorites.favoriteTeams)   { _, _ in resortGames() }
    .onChange(of: favorites.favoriteSports)  { _, _ in resortGames() }
  }

  // MARK: - Main content

  @ViewBuilder
  private var content: some View {
    if registry.sources.isEmpty {
      ScrollView { noSourcesState.frame(maxWidth: .infinity, minHeight: 500) }
    } else if isLoadingLeagues && availableLeagues.isEmpty {
      ScrollView {
        LoadingPhraseView()
          .frame(maxWidth: .infinity, minHeight: 500)
      }
    } else if visibleLeagues.isEmpty && !isLoadingLive {
      ScrollView { emptyState.frame(maxWidth: .infinity, minHeight: 500) }
    } else {
      VStack(spacing: 0) {
        leagueChipRow
        streamList
      }
    }
  }

  // MARK: - Chip row

  /// Derived: leagues whose game listings actually loaded. Drives the chip
  /// row. Computed purely from games-with-data so a stale `availableLeagues`
  /// snapshot (e.g. partial league list from a flaky first scrape) doesn't
  /// hide a league whose games did surface. Sorted by popularityRank so chip
  /// ordering stays consistent.
  private var visibleLeagues: [SportLeague] {
    let withGames = Set(allLiveGames.map(\.league))
      .union(Set(allUpcomingGames.map(\.league)))
    return Array(withGames).sorted {
      if $0.popularityRank != $1.popularityRank {
        return $0.popularityRank < $1.popularityRank
      }
      return $0.displayName < $1.displayName
    }
  }

  private var leagueChipRow: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        AllStreamsChip(isSelected: selectedFilter == nil) {
          selectedFilter = nil
        }
        ForEach(visibleLeagues) { league in
          LeagueChip(
            league: league,
            isSelected: selectedFilter == league,
            isFavorite: favorites.isLeagueFavorite(league)
          ) {
            selectedFilter = (selectedFilter == league ? nil : league)
          }
          .contextMenu {
            Button {
              favorites.toggleLeague(league)
            } label: {
              Label(
                favorites.isLeagueFavorite(league) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: favorites.isLeagueFavorite(league) ? "star.slash.fill" : "star"
              )
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .background(Color(.systemBackground))
  }

  // MARK: - Stream list

  private var filteredLiveGames: [Game] {
    guard let league = selectedFilter else { return allLiveGames }
    return allLiveGames.filter { $0.league == league }
  }
  private var filteredUpcomingGames: [Game] {
    guard let league = selectedFilter else { return allUpcomingGames }
    return allUpcomingGames.filter { $0.league == league }
  }

  @ViewBuilder
  private var streamList: some View {
    ScrollView {
      let live = filteredLiveGames
      let upcoming = filteredUpcomingGames
      if isLoadingLive && live.isEmpty && upcoming.isEmpty {
        VStack { ProgressView().scaleEffect(1.3) }
          .frame(maxWidth: .infinity, minHeight: 400)
      } else if live.isEmpty && upcoming.isEmpty {
        VStack(spacing: 14) {
          Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 48))
            .foregroundStyle(.quaternary)
          Text(selectedFilter == nil ? "No games right now" : "No \(selectedFilter!.displayName) games right now")
            .font(.headline)
            .foregroundStyle(.secondary)
          Text("Check back when your favorite teams are playing.")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
      } else {
        VStack(spacing: 8) {
          ForEach(live) { game in
            NavigationLink(destination: PlayerView(game: game)) {
              LiveGameRow(game: game)
            }
            .buttonStyle(.plain)
          }
          ForEach(upcoming) { game in
            NavigationLink(destination: PlayerView(game: game)) {
              LiveGameRow(game: game)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 32)
      }
    }
    // v2.22: pull-to-refresh is the manual reload trigger. The feed
    // otherwise loads once per source switch — no background polling,
    // no per-favorite re-fetch.
    // v2.23: forceRefresh=true so this actually re-scrapes instead of
    // returning APIDiscovery's cached endpoint result.
    .refreshable {
      await loadLeagues(forceRefresh: true)
    }
  }

  // MARK: - No-sources state (first launch)

  private var noSourcesState: some View {
    VStack(spacing: 16) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .font(.system(size: 52))
        .foregroundStyle(.quaternary)
      Text("No sources yet")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Add a sports streaming site in Settings to get started.")
        .font(.subheadline)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      NavigationLink {
        SettingsView()
          .environment(favorites)
          .environment(registry)
      } label: {
        Text("Go to Settings")
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Empty / failed state

  /// Reason to render in the empty state — either the classified
  /// `loadFailureReason` from a thrown LoadFailureReason, or `.noLeagues` as
  /// the generic fallback when nothing failed but no games surfaced.
  private var effectiveFailureReason: LoadFailureReason {
    loadFailureReason ?? .noLeagues
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      if !registry.selectedSource.isBuiltIn {
        let reason = effectiveFailureReason
        Image(systemName: reason.emptyStateSymbol)
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text(reason == .unreachable
             ? "Couldn't reach \(registry.selectedSource.name)"
             : reason.emptyStateHeadline)
          .font(.headline)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 16)
        Text(reason.emptyStateBody)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 28)
        // Hide the "Browse" button for parked / sinkholed domains — there's
        // nothing meaningful to browse to, and surfacing the button implies
        // the URL is recoverable when it usually isn't.
        if reason != .parked && reason != .sinkholed {
          NavigationLink(destination: BrowseView(source: registry.selectedSource)) {
            Label("Browse \(registry.selectedSource.name)", systemImage: "globe")
              .padding(.horizontal, 8)
          }
          .buttonStyle(.borderedProminent)
        }
        Button(reason == .cloudflareBlocked ? "Try Again" : "Retry") {
          guard !isRetrying else { return }
          isRetrying = true
          Task { await loadLeagues(forceRefresh: true); isRetrying = false }
        }
        .disabled(isRetrying)
        .buttonStyle(.bordered)
      } else {
        Image(systemName: "sportscourt")
          .font(.system(size: 52))
          .foregroundStyle(.quaternary)
        Text("No leagues available")
          .font(.headline)
          .foregroundStyle(.secondary)
        Button("Retry") {
          guard !isRetrying else { return }
          isRetrying = true
          Task { await loadLeagues(forceRefresh: true); isRetrying = false }
        }
        .disabled(isRetrying)
        .buttonStyle(.bordered)
      }
    }
  }

  // MARK: - Data loading

  /// v2.23: orchestrator wrapper. Under the new ESPN-first model,
  /// availableLeagues is derived from the merged games list at the END
  /// of loading, not fetched separately first. This function just sets
  /// loading state and delegates to `loadAllLiveGames`.
  private func loadLeagues(forceRefresh: Bool = false) async {
    loadFailureReason = nil
    selectedFilter = nil
    isLoadingLeagues = true
    await loadAllLiveGames(forceRefresh: forceRefresh)
    isLoadingLeagues = false
  }

  private func loadAllLiveGames(forceRefresh: Bool = false) async {
    isLoadingLive = true
    let favLeagues = favorites.favoriteLeagues
    let favTeams   = favorites.favoriteTeams
    let favSports  = favorites.favoriteSports
    let enabled = registry.enabledSources

    // v2.23: ESPN-first listing. Start with the canonical list, no
    // aggregator dependency. ESPN owns teams, time, score, league.
    let espnGames = await ESPNScheduleService.shared.todaysGames(forceRefresh: forceRefresh)

    // For each enabled source, scrape its full feed (in parallel).
    // The aggregator path keeps the v2.21 ESPN-canonical reconcile logic
    // so ESPN-covered fixtures it returns are already ESPN-shaped — easy
    // to match by team-pair. Non-ESPN-covered fixtures (cricket, IIHF,
    // MotoGP, niche soccer) come back unchanged.
    var aggregatorResults: [(sourceID: String, games: [Game])] = []
    await withTaskGroup(of: (String, [Game]).self) { group in
      for source in enabled {
        group.addTask {
          // v2.28: 15 s per-source budget. A single hanging source
          // (CF challenge, DNS stall, slow JS-render) used to stall
          // pull-to-refresh indefinitely because no leaf had a timeout.
          // Race the scrape against a sleep and cancel whichever loses.
          await Self.boundedSourceFetch(source: source,
                                        forceRefresh: forceRefresh,
                                        budgetSeconds: 15)
        }
      }
      for await pair in group { aggregatorResults.append(pair) }
    }

    // Merge: attach streamURLs to ESPN games via team-pair matching;
    // games the aggregator surfaced that ESPN doesn't have become
    // gap-fills IFF the league is one ESPN doesn't cover. Stale ESPN-
    // covered fixtures (Streamed-images-json's "Detroit Pistons vs
    // Orlando Magic" from two weeks ago) get dropped — they have no
    // ESPN match in the supported set, but their league is ESPN-covered,
    // so we know they're stale rather than a coverage gap.
    var streamsByEspnID: [String: [GameStreamCandidate]] = [:]
    var gapFills: [Game] = []
    for (sourceID, games) in aggregatorResults {
      for agg in games {
        if let espn = Self.matchESPNGame(for: agg, in: espnGames) {
          let cand = GameStreamCandidate(sourceID: sourceID, pageURL: agg.pageURL)
          streamsByEspnID[espn.id, default: []].append(cand)
        } else if ESPNScoreboardService.apiPath(for: agg.league) == nil {
          // League ESPN doesn't cover — keep as gap-fill.
          gapFills.append(agg)
        }
        // else: ESPN-covered league + no ESPN match = stale, drop.
      }
    }

    // Build the final list. ESPN-canonical games carry their canonical
    // fields untouched; aggregator-supplied pageURL becomes the primary
    // pageURL when available (so PlayerView's existing path keeps working
    // until v2.24's StreamResolver rolls in).
    let espnWithStreams: [Game] = espnGames.map { game in
      let streams = streamsByEspnID[game.id] ?? []
      let primaryURL = streams.first?.pageURL ?? game.pageURL
      return Game(
        id: game.id,
        homeTeam: game.homeTeam,
        awayTeam: game.awayTeam,
        scheduledTime: game.scheduledTime,
        timeIsKnown: game.timeIsKnown,
        isLive: game.isLive,
        liveStatus: game.liveStatus,
        isEvent: game.isEvent,
        isPremium: game.isPremium,
        pageURL: primaryURL,
        streamURLs: streams,
        league: game.league
      )
    }

    // Dedupe gap-fills across sources (same fixture from multiple
    // aggregators) using v2.20's team-pair key.
    let dedupedGapFills = Self.dedupeGapFills(gapFills)
    // v2.25: cutoff filter — only list games up through end of tomorrow
    // ET. Live games always pass through regardless of their scheduled
    // start. Future-time games more than ~36 h out get dropped to keep
    // the feed focused on what's happening soon. ESPN games already
    // respect this via the v2.25 narrower window, but aggregator gap-
    // fills (cricket, IIHF, MotoGP) come from arbitrary catalogs that
    // may list weekend fixtures.
    let cutoff: Date = {
      let etTZ = TimeZone(identifier: "America/New_York")!
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = etTZ
      let startOfToday = cal.startOfDay(for: Date())
      // End of "tomorrow" ET = start of day after tomorrow.
      return cal.date(byAdding: .day, value: 2, to: startOfToday) ?? Date.distantFuture
    }()
    let unfiltered = espnWithStreams + dedupedGapFills
    let allGames = unfiltered.filter { game in
      if game.isLive { return true }
      guard let st = game.scheduledTime else { return true }
      return st < cutoff
    }

    await LogoPrefetcher.shared.warm(games: allGames)

    // Update availableLeagues to the union of leagues that have games.
    let leaguesWithGames = Set(allGames.map(\.league))
    availableLeagues = Array(leaguesWithGames).sorted {
      if $0.popularityRank != $1.popularityRank {
        return $0.popularityRank < $1.popularityRank
      }
      return $0.displayName < $1.displayName
    }

    // Re-use the local `all` variable name the sort closures below expect.
    let all = allGames

    let liveSortFn: (Game, Game) -> Bool = { a, b in
      let aFav = isFavorite(a, leagues: favLeagues, teams: favTeams, sports: favSports)
      let bFav = isFavorite(b, leagues: favLeagues, teams: favTeams, sports: favSports)
      if aFav != bFav { return aFav }
      if a.league.popularityRank != b.league.popularityRank {
        return a.league.popularityRank < b.league.popularityRank
      }
      return a.title < b.title
    }

    let upcomingSortFn: (Game, Game) -> Bool = { a, b in
      let aFav = isFavorite(a, leagues: favLeagues, teams: favTeams, sports: favSports)
      let bFav = isFavorite(b, leagues: favLeagues, teams: favTeams, sports: favSports)
      if aFav != bFav { return aFav }
      switch (a.scheduledTime, b.scheduledTime) {
      case let (at?, bt?): return at < bt
      case (.some, .none): return true
      default:
        if a.league.popularityRank != b.league.popularityRank {
          return a.league.popularityRank < b.league.popularityRank
        }
        return a.title < b.title
      }
    }

    allLiveGames     = all.filter {  $0.isLive }.sorted(by: liveSortFn)
    allUpcomingGames = all.filter { !$0.isLive }.sorted(by: upcomingSortFn)

    // v2.23: surface a failure reason only when the entire pipeline came
    // back empty AND we have no enabled sources to retry. ESPN alone is
    // enough to keep the feed populated for most users; the empty case
    // is rare (e.g., off-season + ESPN issue + no aggregators enabled).
    if all.isEmpty && enabled.isEmpty {
      loadFailureReason = .noLeagues
    }
    isLoadingLive = false
  }

  /// v2.28: bounded per-source scrape. Races the source's full feed
  /// fetch against a `budgetSeconds` sleep; whichever finishes first
  /// wins. Used by the orchestrator's per-source task group so a
  /// hanging source (CF / DNS / slow JS-render) can't stall the whole
  /// refresh. Returns `(source.id, [])` on timeout.
  static func boundedSourceFetch(
    source: AnyStreamSource,
    forceRefresh: Bool,
    budgetSeconds: Int
  ) async -> (String, [Game]) {
    let result = await withTaskGroup(of: (String, [Game])?.self) { group in
      group.addTask {
        guard let leagues = try? await source.fetchAvailableLeagues(forceRefresh: forceRefresh) else {
          return (source.id, [])
        }
        var bucket: [Game] = []
        await withTaskGroup(of: [Game].self) { sub in
          for league in leagues {
            sub.addTask {
              // Per-league sub-budget: ~10 s so a single hanging league
              // inside an otherwise-ok source can't burn the whole
              // source budget. Race against a sleep, take whichever.
              await withTaskGroup(of: [Game]?.self) { leagueGroup in
                leagueGroup.addTask {
                  (try? await source.fetchGames(for: league)) ?? []
                }
                leagueGroup.addTask {
                  try? await Task.sleep(nanoseconds: 10_000_000_000)
                  return nil
                }
                let winner = await leagueGroup.next() ?? nil
                leagueGroup.cancelAll()
                return winner ?? []
              }
            }
          }
          for await g in sub { bucket.append(contentsOf: g) }
        }
        return (source.id, bucket)
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(budgetSeconds) * 1_000_000_000)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner
    }
    return result ?? (source.id, [])
  }

  /// v2.23: order-insensitive team-pair match between an aggregator-side
  /// Game and one of ESPN's canonical Games. ESPN-covered aggregator
  /// fixtures already carry ESPN-canonical team names (the v2.21
  /// reconcileWithESPN overwrites them on the way out of fetchGames), so
  /// this is an exact-after-normalization match for ESPN-covered leagues.
  /// Non-ESPN aggregator fixtures won't find a match here — that's the
  /// signal to keep them as gap-fills.
  static func matchESPNGame(for aggGame: Game, in espnGames: [Game]) -> Game? {
    let aggKey = pairKeyForMatching(home: aggGame.homeTeam, away: aggGame.awayTeam)
    return espnGames.first(where: { espn in
      pairKeyForMatching(home: espn.homeTeam, away: espn.awayTeam) == aggKey
    })
  }

  /// v2.29: order-insensitive team-pair predicate exposed for callers
  /// outside HomeView (CustomStreamSource.findStreamPage uses it to
  /// pick the LLM-extracted game that matches the user's tap target).
  /// Same normalisation as `pairKeyForMatching` — lowercase, diacritic-
  /// fold, strip punctuation, drop common club suffixes.
  static func matchesTeamPair(home: String, away: String, target: Game) -> Bool {
    let lhs = pairKeyForMatching(home: home, away: away)
    let rhs = pairKeyForMatching(home: target.homeTeam, away: target.awayTeam)
    return lhs == rhs
  }

  static func pairKeyForMatching(home: String, away: String) -> String {
    let h = normalizeForMatch(home)
    let a = normalizeForMatch(away)
    return h <= a ? "\(h)|\(a)" : "\(a)|\(h)"
  }

  static func normalizeForMatch(_ s: String) -> String {
    s.lowercased()
      .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  /// Dedupe gap-fills across sources by team-pair. Multiple aggregators
  /// may list the same cricket / IIHF fixture; we keep the most-info-rich
  /// one (live > has-score > has-time > first).
  static func dedupeGapFills(_ games: [Game]) -> [Game] {
    var byKey: [String: Game] = [:]
    var orderKeys: [String] = []
    for game in games {
      let key = pairKeyForMatching(home: game.homeTeam, away: game.awayTeam)
      if let existing = byKey[key] {
        byKey[key] = preferredGapFill(existing, game)
      } else {
        byKey[key] = game
        orderKeys.append(key)
      }
    }
    return orderKeys.compactMap { byKey[$0] }
  }

  private static func preferredGapFill(_ a: Game, _ b: Game) -> Game {
    if a.isLive != b.isLive { return a.isLive ? a : b }
    let aHasStatus = a.liveStatus?.isEmpty == false
    let bHasStatus = b.liveStatus?.isEmpty == false
    if aHasStatus != bHasStatus { return aHasStatus ? a : b }
    let aHasTime = a.scheduledTime != nil && a.timeIsKnown
    let bHasTime = b.scheduledTime != nil && b.timeIsKnown
    if aHasTime != bHasTime { return aHasTime ? a : b }
    return a
  }

  /// Re-sorts `allLiveGames` and `allUpcomingGames` against current
  /// favorites WITHOUT re-fetching. Used by `.onChange(of: favorites.*)`
  /// to bump favorited content to the top without taking the UI through
  /// a full reload cycle (which was the v2.21 behavior — visible as
  /// streams disappearing while the refetch ran).
  private func resortGames() {
    let favLeagues = favorites.favoriteLeagues
    let favTeams   = favorites.favoriteTeams
    let favSports  = favorites.favoriteSports
    let liveSortFn: (Game, Game) -> Bool = { a, b in
      let aFav = isFavorite(a, leagues: favLeagues, teams: favTeams, sports: favSports)
      let bFav = isFavorite(b, leagues: favLeagues, teams: favTeams, sports: favSports)
      if aFav != bFav { return aFav }
      if a.league.popularityRank != b.league.popularityRank {
        return a.league.popularityRank < b.league.popularityRank
      }
      return a.title < b.title
    }
    let upcomingSortFn: (Game, Game) -> Bool = { a, b in
      let aFav = isFavorite(a, leagues: favLeagues, teams: favTeams, sports: favSports)
      let bFav = isFavorite(b, leagues: favLeagues, teams: favTeams, sports: favSports)
      if aFav != bFav { return aFav }
      switch (a.scheduledTime, b.scheduledTime) {
      case let (at?, bt?): return at < bt
      case (.some, .none): return true
      default:
        if a.league.popularityRank != b.league.popularityRank {
          return a.league.popularityRank < b.league.popularityRank
        }
        return a.title < b.title
      }
    }
    allLiveGames = allLiveGames.sorted(by: liveSortFn)
    allUpcomingGames = allUpcomingGames.sorted(by: upcomingSortFn)
  }

  private func isFavorite(
    _ game: Game,
    leagues: Set<SportLeague>,
    teams: Set<String>,
    sports: Set<Sport>
  ) -> Bool {
    if leagues.contains(game.league) { return true }
    if sports.contains(where: { $0.leagues.contains(game.league) }) { return true }
    let h = game.homeTeam.lowercased()
    let a = game.awayTeam.lowercased()
    return teams.contains { h.contains($0) || $0.contains(h) } ||
           teams.contains { a.contains($0) || $0.contains(a) }
  }
}

// MARK: - Loading phrase view

/// Cycles through sports-themed "thinking" phrases while leagues load. Same
/// vibe as Claude's "Cogitating…" / "Pondering…" — short, present-progressive,
/// athlete-anchored. Starts at a random phrase so two consecutive loads don't
/// open with the same line, and rotates every 2.5 s with a fade transition.
struct LoadingPhraseView: View {
  @State private var index: Int = Int.random(in: 0..<LoadingPhraseView.phrases.count)

  // v2.23: split into two buckets, then interleave 2-admiring-then-1-jab
  // so consecutive indices alternate. Previously the array was admiring
  // first, jabs last — a random START index could land in the jab section
  // and cycle through 15 jabs in a row before transitioning. Smooth 2:1
  // ratio keeps the lighter mix the user wanted.
  private static let admiringPhrases: [String] = [
    "Lobbing it up for LeBron",
    "Catching passes from Mahomes",
    "Serving to Alcaraz",
    "Practicing my jumper with Durant",
    "Setting screens for Caitlin Clark",
    "Studying tape with Belichick",
    "Warming up with Shohei Ohtani",
    "Skating circles with McDavid",
    "Boxing out for Embiid",
    "Trash-talking with Steph",
    "Drawing up a play with Spoelstra",
    "Lacing up with Sabrina Ionescu",
    "Cornering for Pacquiao",
    "Calling the audible with Patrick",
    "Threading a no-look to Jokić",
    "Tying my cleats with Messi",
    "Stretching with Serena",
    "Spotting for A'ja Wilson",
    "Holding the bag for Canelo",
    "Pacing the dugout with Judge",
    "Reading the route tree with Justin Jefferson",
    "Drafting Caleb Williams",
    "Working the corner with Crawford",
    "Driving the lane with Clark",
    "Calling pitches with Buster Posey",
    "Shadowboxing with Tyson Fury",
    "Cooling down with Bolt",
    "Rolling out the mat for Khabib",
    "Charting laps with Verstappen",
    "Splitting tens with Tiger",
  ]

  private static let jabPhrases: [String] = [
    "Choking the playoffs with Harden",
    "Blowing a 3-1 lead with Steph",
    "Missing free throws with Shaq",
    "Throwing INTs with Jameis",
    "Practicing the flop with Reaves",
    "Tanking the season with the Sixers",
    "Hitting the post with Salah",
    "Air-balling the game-winner with Ben Simmons",
    "Coughing it up at the goal line with Pete Carroll",
    "Calling it Hard-Knocks-life with the Jets",
    "Drafting a punter in round one",
    "Forgetting how many fingers Tristan points",
    "Bricking the at-bat with the interpreter",
    "Running the option wrong with Zach Wilson",
    "Trying to medal in skiing with Lindsey",
  ]

  static let phrases: [String] = {
    var out: [String] = []
    var ai = 0, ji = 0
    while ai < admiringPhrases.count || ji < jabPhrases.count {
      if ai < admiringPhrases.count { out.append(admiringPhrases[ai]); ai += 1 }
      if ai < admiringPhrases.count { out.append(admiringPhrases[ai]); ai += 1 }
      if ji < jabPhrases.count     { out.append(jabPhrases[ji]);     ji += 1 }
    }
    return out
  }()

  var body: some View {
    VStack(spacing: 14) {
      ProgressView().scaleEffect(1.3)
      Text(Self.phrases[index % Self.phrases.count] + "…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .id(index)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
      withAnimation(.easeInOut(duration: 0.35)) {
        index += 1
      }
    }
  }
}

// MARK: - All-Streams chip

struct AllStreamsChip: View {
  let isSelected: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 6) {
        ZStack {
          Circle()
            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
          Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(isSelected ? .white : Color.primary)
        }
        .frame(width: 64, height: 64)
        .overlay(
          Circle().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        Text("All")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(isSelected ? Color.accentColor : .secondary)
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - League chip

struct LeagueChip: View {
  let league: SportLeague
  let isSelected: Bool
  let isFavorite: Bool
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 6) {
        ZStack {
          Circle()
            .fill(isSelected ? league.accentColor : league.accentColor.opacity(0.15))
          if let logoURL = league.leagueLogoURL {
            CachedAsyncImage(url: logoURL) { image in
              image.resizable().scaledToFit().padding(12)
            } placeholder: {
              Text(league.emoji)
                .font(.system(size: 30))
            }
          } else {
            Text(league.emoji)
              .font(.system(size: 30))
          }
        }
        .frame(width: 64, height: 64)
        .overlay(
          Circle().stroke(isSelected ? league.accentColor : Color.clear, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
          if isFavorite {
            ZStack {
              Image(systemName: "star.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
              Image(systemName: "star.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.yellow)
            }
            .offset(x: 2, y: -2)
          }
        }
        Text(league.displayName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(isSelected ? league.accentColor : .secondary)
          .lineLimit(1)
          .frame(maxWidth: 80)
      }
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Live game row

struct LiveGameRow: View {
  let game: Game

  /// True when this league has no ESPN scoreboard support.
  /// For these leagues (WWE, boxing, tennis, golf, NASCAR) team logos
  /// won't be available, so we fall back to the league symbol instead.
  private var usesLeagueFallback: Bool {
    ESPNScoreboardService.apiPath(for: game.league) == nil
  }

  var body: some View {
    HStack(spacing: 14) {
      // Left: league symbol circle for events and ESPN-unsupported leagues;
      // stacked team logos for everything else.
      if game.isEvent || usesLeagueFallback {
        leagueIconCircle
      } else {
        VStack(spacing: 5) {
          TeamLogo(teamName: game.homeTeam, league: game.league, size: 24)
          TeamLogo(teamName: game.awayTeam, league: game.league, size: 24)
        }
        .frame(width: 52)
      }

      // Middle: team names (or event title)
      VStack(alignment: .leading, spacing: 5) {
        let isSingleName = game.isEvent || game.awayTeam.isEmpty || game.awayTeam == "TBD"
        if isSingleName {
          Text(game.homeTeam)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(game.homeTeam)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
          Text(game.awayTeam)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
        }
      }

      Spacer()

      // Right: LIVE badge when live, time when upcoming
      if game.isLive {
        LiveStatusBadge(status: game.liveStatus)
      } else {
        VStack(alignment: .trailing, spacing: 2) {
          if let day = game.displayDay {
            Text(day)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
          Text(game.displayTime)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }

      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    .overlay(alignment: .topLeading) {
      // v2.26: only show the small league-badge overlay when the row
      // is using stacked team logos. When the row already shows a big
      // league-icon circle (events / leagues with no ESPN coverage),
      // a second small badge for the same league reads as duplicated.
      if !game.isEvent && !usesLeagueFallback {
        LeagueIcon(league: game.league, size: 22)
          .offset(x: -8, y: -8)
      }
    }
  }

  /// League logo image (ESPN CDN) when available, emoji otherwise —
  /// inside a coloured circle matching the league accent.
  private var leagueIconCircle: some View {
    ZStack {
      Circle().fill(game.league.accentColor.opacity(0.15))
      if let logoURL = game.league.leagueLogoURL {
        CachedAsyncImage(url: logoURL) { image in
          image.resizable().scaledToFit().padding(8)
        } placeholder: {
          Text(game.league.emoji)
            .font(.system(size: 28))
        }
      } else {
        Text(game.league.emoji)
          .font(.system(size: 28))
      }
    }
    .frame(width: 52, height: 52)
  }
}

// MARK: - Browse tile (still used by other views if any)

struct BrowseTile: View {
  let source: AnyStreamSource

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16)
        .fill(Color.secondary.opacity(0.13))
        .aspectRatio(1, contentMode: .fit)
      VStack(spacing: 10) {
        Image(systemName: "globe")
          .font(.system(size: 36, weight: .bold))
          .foregroundStyle(Color.secondary)
          .frame(height: 50)
        Text("Browse")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(Color.secondary.opacity(0.85))
          .minimumScaleFactor(0.3)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 6)
      }
    }
  }
}

// MARK: - Favorites tile (still used by other views if any)

struct FavoritesTile: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16)
        .fill(Color.yellow.opacity(0.13))
        .aspectRatio(1, contentMode: .fit)
      VStack(spacing: 10) {
        Image(systemName: "star.fill")
          .font(.system(size: 36, weight: .bold))
          .foregroundStyle(.yellow)
          .frame(height: 50)
        Text("Favorites")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(Color.yellow.opacity(0.85))
          .minimumScaleFactor(0.3)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 6)
      }
    }
  }
}

// MARK: - League tile (still used by other views if any)

struct LeagueTile: View {
  let league: SportLeague
  var isFavorite: Bool = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16)
        .fill(league.accentColor.opacity(0.13))
        .aspectRatio(1, contentMode: .fit)

      VStack(spacing: 10) {
        if let logoURL = league.leagueLogoURL {
          CachedAsyncImage(url: logoURL) { image in
            image.resizable().scaledToFit()
          } placeholder: {
            Text(league.emoji)
              .font(.system(size: 42))
          }
          .frame(maxWidth: 68, maxHeight: 42)
        } else {
          Text(league.emoji)
            .font(.system(size: 42))
        }

        Text(league.displayName)
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(league.accentColor.opacity(0.85))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.3)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 6)
      }
    }
    .overlay(alignment: .topTrailing) {
      if isFavorite {
        ZStack {
          Image(systemName: "star.fill")
            .font(.system(size: 21, weight: .bold))
            .foregroundStyle(.white)
          Image(systemName: "star.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.yellow)
        }
        .padding(5)
      }
    }
  }
}
