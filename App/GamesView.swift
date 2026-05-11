import SwiftUI

struct GamesView: View {
  let league: SportLeague
  let source: AnyStreamSource

  @State private var games: [Game] = []
  @State private var isLoading = true
  @State private var errorMessage: String? = nil

  var liveGames: [Game] { games.filter { $0.isLive } }
  var upcomingGames: [Game] { games.filter { !$0.isLive } }

  var body: some View {
    ZStack {
      Color(.systemBackground).ignoresSafeArea()

      if isLoading {
        ProgressView()
          .scaleEffect(1.3)
      } else if let error = errorMessage {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(error)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Retry") { Task { await loadGames() } }
            .buttonStyle(.bordered)
        }
        .padding()
      } else if games.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: league.sfSymbol)
            .font(.system(size: 48))
            .foregroundStyle(.quaternary)
          Text("No games found")
            .font(.headline)
            .foregroundStyle(.secondary)
          Text("Check back closer to game time.")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        }
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            if !liveGames.isEmpty {
              Section {
                ForEach(liveGames) { game in
                  NavigationLink(destination: PlayerView(game: game)) {
                    GameRow(game: game)
                  }
                  .buttonStyle(.plain)
                  Divider().padding(.leading, 72)
                }
              } header: {
                SectionHeader(title: "Live Now", color: .red)
              }
            }

            if !upcomingGames.isEmpty {
              Section {
                ForEach(upcomingGames) { game in
                  NavigationLink(destination: PlayerView(game: game)) {
                    GameRow(game: game)
                  }
                  .buttonStyle(.plain)
                  Divider().padding(.leading, 72)
                }
              } header: {
                SectionHeader(title: "Upcoming", color: .secondary)
              }
            }
          }
          .padding(.bottom, 24)
        }
      }
    }
    .navigationTitle(league.displayName)
    .navigationBarTitleDisplayMode(.large)
    .task { await loadGames() }
    .refreshable { await loadGames() }
  }

  private func loadGames() async {
    isLoading = true
    errorMessage = nil
    do {
      games = try await source.fetchGames(for: league)
    } catch {
      errorMessage = "Couldn't load games. Check your connection."
    }
    isLoading = false
  }
}

struct GameRow: View {
  let game: Game

  var body: some View {
    HStack(spacing: 16) {
      ZStack {
        Circle()
          .fill(game.league.accentColor.opacity(0.15))
          .frame(width: 48, height: 48)
        Image(systemName: game.league.sfSymbol)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(game.league.accentColor)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(game.homeTeam)
          .font(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(.primary)
        Text(game.awayTeam)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if game.isLive {
        LiveBadge()
      } else {
        Text(game.displayTime)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }

      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .contentShape(Rectangle())
  }
}

struct LiveBadge: View {
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(.red)
        .frame(width: 7, height: 7)
        .scaleEffect(pulse ? 1.3 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
      Text("LIVE")
        .font(.caption2)
        .fontWeight(.bold)
        .foregroundStyle(.red)
    }
    .onAppear { pulse = true }
  }
}

struct SectionHeader: View {
  let title: String
  let color: Color

  var body: some View {
    Text(title.uppercased())
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(color)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial)
  }
}
