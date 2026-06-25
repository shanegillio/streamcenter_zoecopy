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

  /// The game currently shown in the TV. Auto-selected on load (best live
  /// game by favorites/popularity); changed by tapping a guide block or
  /// channel-surfing with the up/down controls.
  @State private var selectedGame: Game? = nil
  /// Stack of previously viewed game IDs, powering the "prev." button.
  @State private var history: [String] = []

  var body: some View {
    NavigationStack {
      ZStack {
        GuideTheme.background.ignoresSafeArea()
        content
      }
      .toolbar(.hidden, for: .navigationBar)
    }
    .preferredColorScheme(.dark)
    .task { await loadLeagues() }
    .task(id: registry.selectedSource.id) {
      guard !registry.sources.isEmpty else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard !Task.isCancelled else { return }
        await loadAllLiveGames()
      }
    }
    .onChange(of: registry.selectedSource) { _, _ in Task { await loadLeagues() } }
    .onChange(of: registry.sources)        { _, _ in Task { await loadLeagues() } }
    .onChange(of: registry.enabledSourceIDs) { _, _ in Task { await loadLeagues() } }
    .onChange(of: favorites.favoriteLeagues) { _, _ in resortGames() }
    .onChange(of: favorites.favoriteTeams)   { _, _ in resortGames() }
    .onChange(of: favorites.favoriteSports)  { _, _ in resortGames() }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Streams")
        .font(.system(size: 26, weight: .heavy))
        .foregroundStyle(GuideTheme.text)
      Spacer()
      NavigationLink {
        SettingsView()
          .environment(favorites)
          .environment(registry)
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(GuideTheme.text)
          .padding(11)
          .glassBackground(in: Circle())
      }
      .accessibilityLabel("Settings")
    }
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  // MARK: - Main content

  @ViewBuilder
  private var content: some View {
    VStack(spacing: 12) {
      header
      if registry.enabledSources.isEmpty {
        noSourcesState
      } else if isLoadingLeagues && availableLeagues.isEmpty {
        Spacer()
        LoadingPhraseView()
        Spacer()
      } else {
        TVStageView(
          game: selectedGame,
          canGoPrev: !history.isEmpty,
          onChannelUp: { surf(by: -1) },
          onChannelDown: { surf(by: 1) },
          onPrev: { goToPreviousChannel() }
        )
        guideArea
      }
    }
  }

  @ViewBuilder
  private var guideArea: some View {
    if isLoadingLive && allLiveGames.isEmpty && allUpcomingGames.isEmpty {
      Spacer()
      ProgressView().tint(.white).scaleEffect(1.3)
      Spacer()
    } else if allLiveGames.isEmpty && allUpcomingGames.isEmpty {
      Spacer(); emptyState; Spacer()
    } else {
      GeometryReader { geo in
        ScrollView(.vertical, showsIndicators: false) {
          TVGuideView(
            live: allLiveGames,
            upcoming: allUpcomingGames,
            selectedGameID: selectedGame?.id,
            availableWidth: geo.size.width,
            onSelect: { select($0) }
          )
        }
        .refreshable { await loadLeagues(forceRefresh: true) }
        .clipShape(RoundedRectangle(cornerRadius: 14))
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 10)
    }
  }

  // MARK: - Selection / channel surfing

  /// The guide's channel rows in the exact order they're drawn on screen, so
  /// the up/down controls walk the listing top-to-bottom like a TV remote.
  private var surfChannels: [GuideChannel] {
    TVGuideLayout.channels(live: allLiveGames, upcoming: allUpcomingGames, now: Date())
  }

  /// The game a channel row "tunes to": the live game if one is on, otherwise
  /// the next game up on that channel.
  private func tunedGame(for channel: GuideChannel) -> Game? {
    channel.games.first(where: { $0.isLive }) ?? channel.games.first
  }

  private func select(_ game: Game) {
    if let current = selectedGame, current.id != game.id {
      history.append(current.id)
    }
    selectedGame = game
  }

  /// Move up (-1) or down (+1) the channel listing, wrapping around. This walks
  /// channels in display order rather than jumping through the live-games list,
  /// so pressing down always lands on the next channel shown in the guide.
  private func surf(by delta: Int) {
    let channels = surfChannels
    guard !channels.isEmpty else { return }
    // Find the channel that currently holds the selected game.
    let currentIdx = channels.firstIndex { ch in
      ch.games.contains { $0.id == selectedGame?.id }
    }
    let nextIdx: Int
    if let i = currentIdx {
      nextIdx = (i + delta + channels.count) % channels.count
    } else {
      nextIdx = delta >= 0 ? 0 : channels.count - 1
    }
    if let game = tunedGame(for: channels[nextIdx]) {
      select(game)
    }
  }

  private func goToPreviousChannel() {
    guard let prevID = history.popLast() else { return }
    let all = allLiveGames + allUpcomingGames
    if let game = all.first(where: { $0.id == prevID }) {
      selectedGame = game
    }
  }

  /// Pick the best game for the TV when nothing is selected (or the prior
  /// selection has left the feed). Games are already sorted favorites-first,
  /// so the head of the live list is the best choice.
  private func autoSelectIfNeeded() {
    let all = allLiveGames + allUpcomingGames
    if let sel = selectedGame, all.contains(where: { $0.id == sel.id }) { return }
    selectedGame = allLiveGames.first ?? allUpcomingGames.first
  }

  // MARK: - No-sources state (first launch)

  private var noSourcesState: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "antenna.radiowaves.left.and.right")
        .font(.system(size: 58))
        .foregroundStyle(GuideTheme.textDim)
      Text("No sources yet")
        .font(.title3.weight(.semibold))
        .foregroundStyle(GuideTheme.text)
      Text("Add a sports streaming site by pressing Add Source below to get started.")
        .font(.subheadline)
        .foregroundStyle(GuideTheme.textDim)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
      Spacer()
      NavigationLink {
        SourceListView(autoPresentAdd: registry.sources.isEmpty)
          .environment(registry)
      } label: {
        Text("Add Source")
          .font(.headline)
          .foregroundStyle(GuideTheme.text)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
          .glassBackground(in: RoundedRectangle(cornerRadius: 16))
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "sportscourt")
        .font(.system(size: 52))
        .foregroundStyle(GuideTheme.textDim)
      Text("No games right now")
        .font(.headline)
        .foregroundStyle(GuideTheme.text)
      Text("Pull to refresh, or check back closer to game time.")
        .font(.subheadline)
        .foregroundStyle(GuideTheme.textDim)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
      Button("Retry") {
        guard !isRetrying else { return }
        isRetrying = true
        Task { await loadLeagues(forceRefresh: true); isRetrying = false }
      }
      .disabled(isRetrying)
      .buttonStyle(.bordered)
      .tint(.white)
    }
  }

  // MARK: - Data loading

  private func loadLeagues(forceRefresh: Bool = false) async {
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

    let canonicalGames = await ScheduleAggregator.shared.todaysGames(forceRefresh: forceRefresh)

    var matchesBySource: [(sourceID: String, matches: [String: URL])] = []
    await withTaskGroup(of: (String, [String: URL]).self) { group in
      for source in enabled {
        group.addTask {
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

    let cutoff: Date = {
      let etTZ = TimeZone(identifier: "America/New_York")!
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = etTZ
      let startOfToday = cal.startOfDay(for: Date())
      return cal.date(byAdding: .day, value: 2, to: startOfToday) ?? Date.distantFuture
    }()
    let allGames = gamesWithStreams.filter { game in
      if game.isLive { return true }
      // Drop games that have already finished — only live + still-upcoming
      // games belong in the guide.
      if Self.isFinished(game) { return false }
      guard let st = game.scheduledTime else { return true }
      return st < cutoff
    }

    await LogoPrefetcher.shared.warm(games: allGames)

    let leaguesWithGames = Set(allGames.map(\.league))
    availableLeagues = Array(leaguesWithGames).sorted {
      if $0.popularityRank != $1.popularityRank {
        return $0.popularityRank < $1.popularityRank
      }
      return $0.displayName < $1.displayName
    }

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

    autoSelectIfNeeded()
    isLoadingLive = false
  }

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

  /// Heuristic for "this game is over and should be hidden." Live games are
  /// never finished. A non-live game is finished when ESPN tagged it with a
  /// final marker (Final / FT / full time), when it's a completed event
  /// (no known time but a populated status line), or when it started long
  /// enough ago that its typical run-time has elapsed.
  static func isFinished(_ game: Game) -> Bool {
    if game.isLive { return false }
    if let s = game.liveStatus?.lowercased(), !s.isEmpty {
      if s.contains("final") || s.contains("ft") || s.contains("full time")
        || s.contains("ended") || s.contains("result") {
        return true
      }
      // Completed ESPN event: time is unknown but a status line exists.
      if game.scheduledTime == nil || !game.timeIsKnown { return true }
    }
    if let t = game.scheduledTime, game.timeIsKnown {
      let elapsed = -t.timeIntervalSinceNow
      // A non-live game whose typical run-time has fully elapsed is over.
      // (Anything still actually playing would be flagged `isLive`.)
      let runtime = Double(game.league.typicalDurationMinutes) * 60
      if elapsed > runtime { return true }
    }
    return false
  }

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
      ProgressView().scaleEffect(1.3).tint(.white)
      Text(Self.phrases[index % Self.phrases.count] + "…")
        .font(.subheadline)
        .foregroundStyle(GuideTheme.textDim)
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

// MARK: - Live game row

struct LiveGameRow: View {
  let game: Game

  private var usesLeagueFallback: Bool {
    ESPNScoreboardService.apiPath(for: game.league) == nil
  }

  var body: some View {
    HStack(spacing: 14) {
      if game.isEvent || usesLeagueFallback {
        leagueIconCircle
      } else {
        VStack(spacing: 5) {
          TeamLogo(teamName: game.homeTeam, league: game.league, size: 24)
          TeamLogo(teamName: game.awayTeam, league: game.league, size: 24)
        }
        .frame(width: 52)
      }

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
      if !game.isEvent && !usesLeagueFallback {
        LeagueIcon(league: game.league, size: 22)
          .offset(x: -8, y: -8)
      }
    }
  }

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
