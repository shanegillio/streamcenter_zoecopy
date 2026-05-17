import SwiftUI

struct FavoritesView: View {
  let source: AnyStreamSource

  @Environment(FavoritesStore.self) private var favorites
  @State private var sportGames: [Game] = []
  @State private var leagueGames: [Game] = []
  @State private var teamGames: [Game] = []
  @State private var isLoading = true

  var hasAnyGames: Bool { !sportGames.isEmpty || !leagueGames.isEmpty || !teamGames.isEmpty }

  var body: some View {
    ZStack {
      Color(.systemBackground).ignoresSafeArea()

      if isLoading {
        VStack(spacing: 14) {
          ProgressView().scaleEffect(1.3)
          Text("Loading favorites…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } else if !hasAnyGames {
        VStack(spacing: 12) {
          Image(systemName: "star.slash")
            .font(.system(size: 48))
            .foregroundStyle(.quaternary)
          Text("No favorite games found")
            .font(.headline)
            .foregroundStyle(.secondary)
          Text("Check back when your favorites are scheduled.")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            if !sportGames.isEmpty {
              gamesSection(title: "Favorite Sports", color: .green, games: sportGames)
            }
            if !leagueGames.isEmpty {
              gamesSection(title: "Favorite Leagues", color: .yellow, games: leagueGames)
            }
            if !teamGames.isEmpty {
              gamesSection(title: "Favorite Teams", color: .orange, games: teamGames)
            }
          }
          .padding(.bottom, 24)
        }
      }
    }
    .navigationTitle("Favorites")
    .navigationBarTitleDisplayMode(.large)
    .task { await loadFavoriteGames() }
    .refreshable { await loadFavoriteGames() }
  }

  @ViewBuilder
  private func gamesSection(title: String, color: Color, games: [Game]) -> some View {
    Section {
      VStack(spacing: 10) {
        ForEach(games) { game in
          NavigationLink(destination: PlayerView(game: game)) {
            GameCard(game: game)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 10)
      .padding(.bottom, 6)
    } header: {
      SectionHeader(title: title, color: color)
    }
  }

  @MainActor
  private func loadFavoriteGames() async {
    isLoading = true
    // Capture before first await — favorites is main-actor-isolated
    let favLeagues = favorites.favoriteLeagues
    let favTeams = favorites.favoriteTeams
    let favSports = favorites.favoriteSports
    let availableLeagues = (try? await source.fetchAvailableLeagues()) ?? []

    // Build league sets per category (more specific category wins)
    var sportLeagueSet = Set<SportLeague>()
    for sport in favSports {
      for league in sport.leagues where availableLeagues.contains(league) {
        sportLeagueSet.insert(league)
      }
    }

    let explicitLeagueSet = favLeagues.filter { availableLeagues.contains($0) }
    // Explicit league favorites take precedence over sport-level
    sportLeagueSet.subtract(explicitLeagueSet)

    var teamLeagueSet = Set<SportLeague>()
    for group in FavoritesStore.knownTeams {
      let hasFav = group.teams.contains { team in
        let lower = team.lowercased()
        return favTeams.contains { lower.contains($0) || $0.contains(lower) }
      }
      if hasFav, availableLeagues.contains(group.league) {
        teamLeagueSet.insert(group.league)
      }
    }
    // Explicit league/sport favorites take precedence over team-level
    teamLeagueSet.subtract(explicitLeagueSet)
    teamLeagueSet.subtract(sportLeagueSet)

    let allLeagues = sportLeagueSet.union(explicitLeagueSet).union(teamLeagueSet)
    guard !allLeagues.isEmpty else {
      sportGames = []; leagueGames = []; teamGames = []
      isLoading = false; return
    }

    var gamesByLeague: [SportLeague: [Game]] = [:]
    await withTaskGroup(of: (SportLeague, [Game]).self) { group in
      for league in allLeagues {
        group.addTask {
          let g = (try? await source.fetchGames(for: league)) ?? []
          return (league, g)
        }
      }
      for await (league, games) in group {
        gamesByLeague[league] = games
      }
    }

    func sortGames(_ games: [Game]) -> [Game] {
      games.sorted { a, b in
        if a.isLive != b.isLive { return a.isLive }
        switch (a.scheduledTime, b.scheduledTime) {
        case let (at?, bt?): return at < bt
        case (.some, .none): return true
        default: return false
        }
      }
    }

    var newSportGames: [Game] = []
    var newLeagueGames: [Game] = []
    var newTeamGames: [Game] = []

    for (league, games) in gamesByLeague {
      if teamLeagueSet.contains(league) {
        let filtered = games.filter { game in
          let h = game.homeTeam.lowercased()
          let a = game.awayTeam.lowercased()
          return favTeams.contains { h.contains($0) || $0.contains(h) } ||
                 favTeams.contains { a.contains($0) || $0.contains(a) }
        }
        newTeamGames.append(contentsOf: filtered)
      } else if explicitLeagueSet.contains(league) {
        newLeagueGames.append(contentsOf: games)
      } else if sportLeagueSet.contains(league) {
        newSportGames.append(contentsOf: games)
      }
    }

    sportGames = sortGames(newSportGames)
    leagueGames = sortGames(newLeagueGames)
    teamGames = sortGames(newTeamGames)
    isLoading = false
  }
}
