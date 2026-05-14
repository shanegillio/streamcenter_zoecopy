import SwiftUI

struct FavoritesView: View {
  let source: AnyStreamSource

  @Environment(FavoritesStore.self) private var favorites
  @State private var games: [Game] = []
  @State private var isLoading = true

  var liveGames: [Game]     { games.filter { $0.isLive } }
  var upcomingGames: [Game] { games.filter { !$0.isLive } }

  var body: some View {
    ZStack {
      Color(.systemBackground).ignoresSafeArea()

      if isLoading {
        VStack(spacing: 14) {
          ProgressView().scaleEffect(1.3)
          Text("Searching for your teams…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } else if games.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "star.slash")
            .font(.system(size: 48))
            .foregroundStyle(.quaternary)
          Text("No favorite team games found")
            .font(.headline)
            .foregroundStyle(.secondary)
          Text("Check back when your teams are scheduled.")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            if !liveGames.isEmpty {
              Section {
                VStack(spacing: 10) {
                  ForEach(liveGames) { game in
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
                SectionHeader(title: "Live Now", color: .red)
              }
            }
            if !upcomingGames.isEmpty {
              Section {
                VStack(spacing: 10) {
                  ForEach(upcomingGames) { game in
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
                SectionHeader(title: "Upcoming", color: .secondary)
              }
            }
          }
          .padding(.bottom, 24)
        }
      }
    }
    .navigationTitle("My Teams")
    .navigationBarTitleDisplayMode(.large)
    .task { await loadFavoriteGames() }
    .refreshable { await loadFavoriteGames() }
  }

  private func loadFavoriteGames() async {
    isLoading = true
    let leagues = (try? await source.fetchAvailableLeagues()) ?? []
    var found: [Game] = []
    await withTaskGroup(of: [Game].self) { group in
      for league in leagues {
        group.addTask {
          let g = (try? await source.fetchGames(for: league)) ?? []
          return g.filter { self.favorites.isFavoriteGame($0) }
        }
      }
      for await result in group { found.append(contentsOf: result) }
    }
    // Sort: live first, then by scheduled time
    games = found.sorted { a, b in
      if a.isLive != b.isLive { return a.isLive }
      switch (a.scheduledTime, b.scheduledTime) {
      case let (at?, bt?): return at < bt
      case (.some, .none): return true
      default: return false
      }
    }
    isLoading = false
  }
}
