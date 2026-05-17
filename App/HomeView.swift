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
    .refreshable {
      await loadLeagues()
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
          Task { await loadLeagues(); isRetrying = false }
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
          Task { await loadLeagues(); isRetrying = false }
        }
        .disabled(isRetrying)
        .buttonStyle(.bordered)
      }
    }
  }

  // MARK: - Data loading

  private func loadLeagues() async {
    guard !registry.sources.isEmpty else {
      isLoadingLeagues = false
      availableLeagues = []
      allLiveGames = []
      return
    }
    let source = registry.selectedSource
    loadFailureReason = nil
    allLiveGames = []
    // Reset the filter when the source changes — the previous source's
    // leagues may not be in the new source's chip row.
    selectedFilter = nil

    // v2.21: single-shot loading. Previously the UI eagerly applied cached
    // chips, then replaced them with fresh chips when the network fetch
    // returned — visible as a brief "flicker" of one chip set replaced by
    // another. With the v2.21 ESPN-canonical pipeline reshaping which
    // games even pass the reconcile filter, that flicker becomes more
    // disruptive (cached chip → wait → fresh chip → games → some games
    // disappear after ESPN reconcile). Hold the chips empty + loading
    // until the fresh fetch lands. Cached chips become a true fallback
    // for when the network is unreachable.
    availableLeagues = []
    isLoadingLeagues = true

    do {
      let fresh = try await source.fetchAvailableLeagues()
      guard registry.selectedSource.id == source.id else { return }
      availableLeagues = fresh
      // Persist only non-empty results so a transient failure doesn't wipe
      // a previously-good cached league list.
      if !fresh.isEmpty {
        registry.persistCachedLeagues(fresh, for: source.id)
      }
      Task { await loadAllLiveGames() }
    } catch let reason as LoadFailureReason {
      guard registry.selectedSource.id == source.id else { return }
      // Network/source error — fall back to cached chips so the user
      // still has UI; loadAllLiveGames will run against the cached set.
      if let cached = registry.cachedLeaguesForSelected, !cached.isEmpty {
        availableLeagues = cached
        Task { await loadAllLiveGames() }
      } else {
        availableLeagues = []
        loadFailureReason = reason
      }
    } catch {
      guard registry.selectedSource.id == source.id else { return }
      if let cached = registry.cachedLeaguesForSelected, !cached.isEmpty {
        availableLeagues = cached
        Task { await loadAllLiveGames() }
      } else {
        loadFailureReason = .unreachable
      }
    }
    isLoadingLeagues = false
  }

  private func loadAllLiveGames() async {
    guard !availableLeagues.isEmpty else { allLiveGames = []; allUpcomingGames = []; return }
    isLoadingLive = true
    let source = registry.selectedSource
    let favLeagues = favorites.favoriteLeagues
    let favTeams   = favorites.favoriteTeams
    let favSports  = favorites.favoriteSports

    var all: [Game] = []
    let registry = self.registry
    await withTaskGroup(of: (SportLeague, [Game]).self) { group in
      for league in availableLeagues {
        group.addTask {
          let fresh = (try? await source.fetchGames(for: league)) ?? []
          return (league, fresh)
        }
      }
      for await (league, games) in group {
        registry.storeGames(games, for: league, source: source)
        all.append(contentsOf: games)
      }
    }

    await LogoPrefetcher.shared.warm(games: all)

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

  static let phrases: [String] = [
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
    // Mild jabs — playful, narrative-based, no personal attacks.
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
              Image(systemName: league.sfSymbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(isSelected ? .white : league.accentColor)
            }
          } else {
            Image(systemName: league.sfSymbol)
              .font(.system(size: 26, weight: .bold))
              .foregroundStyle(isSelected ? .white : league.accentColor)
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
      LeagueIcon(league: game.league, size: 22)
        .offset(x: -8, y: -8)
    }
  }

  /// League logo image (ESPN CDN) when available, SF symbol otherwise —
  /// inside a coloured circle matching the league accent.
  private var leagueIconCircle: some View {
    ZStack {
      Circle().fill(game.league.accentColor.opacity(0.15))
      if let logoURL = game.league.leagueLogoURL {
        CachedAsyncImage(url: logoURL) { image in
          image.resizable().scaledToFit().padding(8)
        } placeholder: {
          Image(systemName: game.league.sfSymbol)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(game.league.accentColor)
        }
      } else {
        Image(systemName: game.league.sfSymbol)
          .font(.system(size: 22, weight: .bold))
          .foregroundStyle(game.league.accentColor)
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
            Image(systemName: league.sfSymbol)
              .font(.system(size: 36, weight: .bold))
              .foregroundStyle(league.accentColor)
          }
          .frame(maxWidth: 68, maxHeight: 42)
        } else {
          Image(systemName: league.sfSymbol)
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(league.accentColor)
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
