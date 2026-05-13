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

// MARK: - Game card

struct GameCard: View {
  let game: Game

  var body: some View {
    HStack(spacing: 14) {
      VStack(spacing: 6) {
        TeamLogo(teamName: game.homeTeam, league: game.league)
        TeamLogo(teamName: game.awayTeam, league: game.league)
      }
      .frame(width: 56)

      VStack(alignment: .leading, spacing: 7) {
        Text(game.homeTeam)
          .font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
          .lineLimit(1)
        Text(game.awayTeam)
          .font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
          .lineLimit(1)
      }

      Spacer()

      if game.isLive {
        LiveStatusBadge(status: game.liveStatus)
      } else {
        Text(game.displayTime)
          .font(.caption).fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }

      Image(systemName: "chevron.right")
        .font(.caption2).fontWeight(.semibold)
        .foregroundStyle(.quaternary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    .contentShape(RoundedRectangle(cornerRadius: 16))
  }
}

// MARK: - Live status badge (unified scoreboard container)

struct LiveStatusBadge: View {
  let status: String?
  @State private var pulse = false

  var body: some View {
    VStack(alignment: .center, spacing: 4) {
      if let status {
        Text(status)
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      HStack(spacing: 4) {
        Circle()
          .fill(.red)
          .frame(width: 5, height: 5)
          .scaleEffect(pulse ? 1.4 : 0.85)
          .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
        Text("LIVE")
          .font(.system(size: 11, weight: .black))
          .foregroundStyle(.red)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    .onAppear { pulse = true }
  }
}

// MARK: - Team logo

struct TeamLogo: View {
  let teamName: String
  let league: SportLeague
  @State private var resolvedURL: URL? = nil

  private var initials: String {
    teamName.split(separator: " ").suffix(2).compactMap { $0.first }.map(String.init).joined()
  }

  var body: some View {
    Group {
      if let url = resolvedURL {
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
    .task(id: teamName) {
      resolvedURL = await TeamLogoCache.shared.logoURL(for: teamName, league: league)
    }
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
