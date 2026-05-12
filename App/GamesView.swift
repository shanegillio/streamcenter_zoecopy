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
        ProgressView().scaleEffect(1.3)
      } else if let error = errorMessage {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
          Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("Retry") { Task { await loadGames() } }.buttonStyle(.bordered)
        }.padding()
      } else if games.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: league.sfSymbol).font(.system(size: 48)).foregroundStyle(.quaternary)
          Text("No games found").font(.headline).foregroundStyle(.secondary)
          Text("Check back closer to game time.").font(.subheadline).foregroundStyle(.tertiary)
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
                  Divider().padding(.leading, 88)
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
                  Divider().padding(.leading, 88)
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

// MARK: - Game row

struct GameRow: View {
  let game: Game

  var body: some View {
    HStack(spacing: 14) {
      // Stacked team logos
      VStack(spacing: 6) {
        TeamLogo(teamName: game.homeTeam, league: game.league)
        TeamLogo(teamName: game.awayTeam, league: game.league)
      }
      .frame(width: 56)

      // Team names
      VStack(alignment: .leading, spacing: 7) {
        Text(game.homeTeam)
          .font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
          .lineLimit(1)
        Text(game.awayTeam)
          .font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
          .lineLimit(1)
      }

      Spacer()

      // Status
      Group {
        if game.isLive {
          LivePill()
        } else {
          Text(game.displayTime)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }

      Image(systemName: "chevron.right")
        .font(.caption2).fontWeight(.semibold)
        .foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }
}

// MARK: - Team logo

struct TeamLogo: View {
  let teamName: String
  let league: SportLeague

  private var logoURL: URL? {
    TeamLogoService.resolve(teamName: teamName, league: league)
  }

  private var initials: String {
    teamName.split(separator: " ").suffix(2).compactMap { $0.first }.map(String.init).joined()
  }

  var body: some View {
    Group {
      if let url = logoURL {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFit()
          default:
            initialsView
          }
        }
      } else {
        initialsView
      }
    }
    .frame(width: 36, height: 36)
  }

  private var initialsView: some View {
    ZStack {
      Circle().fill(league.accentColor.opacity(0.15))
      Text(initials)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(league.accentColor)
    }
  }
}

// MARK: - Live pill

struct LivePill: View {
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(.red)
        .frame(width: 6, height: 6)
        .scaleEffect(pulse ? 1.4 : 0.9)
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
      Text("LIVE")
        .font(.caption2).fontWeight(.black)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.red, in: Capsule())
    .onAppear { pulse = true }
  }
}

// MARK: - Section header

struct SectionHeader: View {
  let title: String
  let color: Color

  var body: some View {
    Text(title.uppercased())
      .font(.caption).fontWeight(.semibold)
      .foregroundStyle(color)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial)
  }
}
