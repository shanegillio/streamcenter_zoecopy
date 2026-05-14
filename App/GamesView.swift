import SwiftUI

struct GamesView: View {
  let league: SportLeague
  let source: AnyStreamSource

  @Environment(FavoritesStore.self) private var favorites

  @State private var games: [Game] = []
  @State private var isLoading = true
  @State private var errorMessage: String? = nil
  @State private var selectedGame: Game? = nil
  @State private var pendingPremiumGame: Game? = nil

  var liveGames: [Game] {
    games.filter { $0.isLive }.sorted { favorites.isFavoriteGame($0) && !favorites.isFavoriteGame($1) }
  }
  var upcomingGames: [Game] {
    games.filter { !$0.isLive }.sorted { favorites.isFavoriteGame($0) && !favorites.isFavoriteGame($1) }
  }

  var sourceDomain: String { source.baseURL.host ?? source.id }

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
                    Button { handleTap(game) } label: { GameCard(game: game) }
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
                    Button { handleTap(game) } label: { GameCard(game: game) }
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
    .navigationDestination(item: $selectedGame) { game in
      PlayerView(game: game)
    }
    .sheet(item: $pendingPremiumGame) { game in
      PremiumCredentialSheet(sourceName: source.name, domain: sourceDomain) {
        pendingPremiumGame = nil
        selectedGame = game
      }
    }
    .task { await loadGames() }
    .refreshable { await loadGames() }
  }

  private func handleTap(_ game: Game) {
    if game.isPremium, CredentialStore.credentials(for: sourceDomain) == nil {
      pendingPremiumGame = game
    } else {
      selectedGame = game
    }
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

// MARK: - Premium credential sheet

struct PremiumCredentialSheet: View {
  let sourceName: String
  let domain: String
  let onContinue: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(spacing: 12) {
          ZStack {
            Circle()
              .fill(Color.yellow.opacity(0.15))
              .frame(width: 72, height: 72)
            Image(systemName: "crown.fill")
              .font(.system(size: 32))
              .foregroundStyle(.yellow)
          }
          Text("Premium Content")
            .font(.title2.bold())
          Text("This stream on **\(sourceName)** requires a premium account. Enter your credentials to auto sign-in.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .padding(.top, 32)
        .padding(.bottom, 28)

        VStack(spacing: 12) {
          TextField("Email or Username", text: $username)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

          SecureField("Password", text: $password)
            .textContentType(.password)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 24)

        Text("Credentials are stored locally on your device.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, 10)
          .padding(.horizontal, 24)

        Spacer()

        VStack(spacing: 10) {
          Button {
            if !username.isEmpty || !password.isEmpty {
              CredentialStore.save(SourceCredentials(username: username, password: password), for: domain)
            }
            dismiss()
            onContinue()
          } label: {
            Label("Save & Watch", systemImage: "play.fill")
              .font(.body.bold())
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(.tint, in: RoundedRectangle(cornerRadius: 14))
              .foregroundStyle(.white)
          }
          .buttonStyle(.plain)

          Button {
            dismiss()
            onContinue()
          } label: {
            Text("Watch Anyway")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.large])
    .onAppear {
      if let saved = CredentialStore.credentials(for: domain) {
        username = saved.username
        password = saved.password
      }
    }
  }
}

// MARK: - Game card

struct GameCard: View {
  let game: Game
  @Environment(FavoritesStore.self) private var favorites

  private func teamRow(_ name: String) -> some View {
    HStack(spacing: 5) {
      Text(name)
        .font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
        .lineLimit(1)
      if favorites.isTeamFavorite(name) {
        Image(systemName: "star.fill")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.yellow)
      }
    }
  }

  var body: some View {
    HStack(spacing: 14) {
      if game.isEvent {
        ZStack {
          Circle().fill(game.league.accentColor.opacity(0.15))
          Image(systemName: game.league.sfSymbol)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(game.league.accentColor)
        }
        .frame(width: 56, height: 56)
      } else {
        VStack(spacing: 6) {
          TeamLogo(teamName: game.homeTeam, league: game.league)
          TeamLogo(teamName: game.awayTeam, league: game.league)
        }
        .frame(width: 56)
      }

      if game.isEvent {
        Text(game.homeTeam)
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(.primary)
          .lineLimit(2)
      } else {
        VStack(alignment: .leading, spacing: 7) {
          teamRow(game.homeTeam)
          teamRow(game.awayTeam)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        if game.isLive {
          LiveStatusBadge(status: game.liveStatus)
        } else {
          Text(game.displayTime)
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }

        if game.isPremium {
          HStack(spacing: 3) {
            Image(systemName: "crown.fill")
              .font(.system(size: 9, weight: .bold))
            Text("Premium")
              .font(.system(size: 10, weight: .bold))
          }
          .foregroundStyle(.yellow)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.yellow.opacity(0.12), in: Capsule())
        }
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

// MARK: - Live status badge

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
