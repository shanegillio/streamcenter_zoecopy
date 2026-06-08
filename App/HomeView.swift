import SwiftUI

struct HomeView: View {
  @Environment(SourceRegistry.self) private var registry
  @Environment(FavoritesStore.self) private var favorites
  @State private var availableLeagues: [SportLeague] = []
  @State private var allLiveGames: [Game] = []
  @State private var allUpcomingGames: [Game] = []
  @State private var isLoadingLeagues = true
  @State private var isLoadingLive = false
  @State private var isRetrying = false
  /// Active filter for the chip row. `nil` means "All" (show every league).
  @State private var selectedFilter: SportLeague? = nil

  var body: some View {
    NavigationStack {
      content
        // Pull-to-refresh applies to every state's ScrollView (loading,
        // empty, and the populated list) via the environment refresh action,
        // so a pull always re-scrapes the schedule and live scores.
        // forceRefresh=true bypasses the ESPN freshness cache.
        .refreshable { await loadLeagues(forceRefresh: true) }
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

  // MARK: - Empty state

  /// v2.32: single empty-state mode. With ESPN+TheSportsDB canonical
  /// listings, the only way the home feed is empty is "no games today
  /// across covered leagues" — usually off-season + no live cards.
  /// Source-side classification (Cloudflare-blocked, parked, sinkholed)
  /// went away with the old aggregator-as-truth model.
  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "sportscourt")
        .font(.system(size: 52))
        .foregroundStyle(.quaternary)
      Text("No games right now")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text("Pull to refresh, or check back closer to game time.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
      if !registry.selectedSource.isBuiltIn {
        NavigationLink(destination: BrowseView(source: registry.selectedSource)) {
          Label("Browse \(registry.selectedSource.name)", systemImage: "globe")
            .padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
      }
      Button("Retry") {
        guard !isRetrying else { return }
        isRetrying = true
        Task { await loadLeagues(forceRefresh: true); isRetrying = false }
      }
      .disabled(isRetrying)
      .buttonStyle(.bordered)
    }
  }

  // MARK: - Data loading

  /// v2.23: orchestrator wrapper. Under the new ESPN-first model,
  /// availableLeagues is derived from the merged games list at the END
  /// of loading, not fetched separately first. This function just sets
  /// loading state and delegates to `loadAllLiveGames`.
  private func loadLeagues(forceRefresh: Bool = false) async {
    // A manual refresh keeps the user's chip selection; a source/favorites
    // change resets to "All" since the available leagues may differ.
    if !forceRefresh { selectedFilter = nil }
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

    // v2.32: canonical listings come from ScheduleAggregator (ESPN +
    // TheSportsDB). Each enabled source then contributes per-game
    // stream URLs by plain substring-matching its scraped homepage
    // links against today's canonical games.
    let canonicalGames = await ScheduleAggregator.shared.todaysGames(forceRefresh: forceRefresh)

    var matchesBySource: [(sourceID: String, matches: [String: URL])] = []
    await withTaskGroup(of: (String, [String: URL]).self) { group in
      for source in enabled {
        group.addTask {
          // 15 s per-source budget — long enough for homepage load +
          // CF clearance + JS render + substring match. Plain matching
          // is cheap; the budget mostly bounds the scrape itself.
          await Self.boundedMatchedGameURLs(
            source: source, canonical: canonicalGames, budgetSeconds: 15
          )
        }
      }
      for await pair in group { matchesBySource.append(pair) }
    }

    var streamsByGameID: [String: [GameStreamCandidate]] = [:]
    for (sourceID, matches) in matchesBySource {
      for (gameID, url) in matches {
        streamsByGameID[gameID, default: []].append(
          GameStreamCandidate(sourceID: sourceID, pageURL: url)
        )
      }
    }

    let gamesWithStreams: [Game] = canonicalGames.map { game in
      let streams = streamsByGameID[game.id] ?? []
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

    // v2.25 cutoff: only list through end of tomorrow ET. Live games
    // always pass.
    let cutoff: Date = {
      let etTZ = TimeZone(identifier: "America/New_York")!
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = etTZ
      let startOfToday = cal.startOfDay(for: Date())
      return cal.date(byAdding: .day, value: 2, to: startOfToday) ?? Date.distantFuture
    }()
    let allGames = gamesWithStreams.filter { game in
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

    isLoadingLive = false
  }

  /// v2.32: bounded per-source matching call. Races the source's
  /// `matchedGameURLs` against a `budgetSeconds` sleep; whichever
  /// finishes first wins. Returns `(source.id, [:])` on timeout.
  static func boundedMatchedGameURLs(
    source: AnyStreamSource,
    canonical: [Game],
    budgetSeconds: Int
  ) async -> (String, [String: URL]) {
    let result = await withTaskGroup(of: (String, [String: URL])?.self) { group in
      group.addTask {
        let m = await source.matchedGameURLs(amongCanonical: canonical)
        return (source.id, m)
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(budgetSeconds) * 1_000_000_000)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner
    }
    return result ?? (source.id, [:])
  }

  /// Order-insensitive team-pair predicate. Used by CustomStreamSource's
  /// LLM fallback to map extracted games to canonical games. Same
  /// normalisation as `normalizeForMatch` — lowercase, diacritic-fold,
  /// strip punctuation.
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
