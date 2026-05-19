import SwiftUI

/// Shared small SwiftUI views. Lifted out of the now-deleted GamesView /
/// FavoritesView files so HomeView can keep using them.

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

struct TeamLogo: View {
  let teamName: String
  let league: SportLeague
  var size: CGFloat = 36

  @State private var resolvedURL: URL?

  init(teamName: String, league: SportLeague, size: CGFloat = 36) {
    self.teamName = teamName
    self.league = league
    self.size = size
    let key = "\(league.id)|\(teamName.lowercased())"
    _resolvedURL = State(initialValue: TeamLogoStore.shared.url(for: key))
  }

  private var initials: String {
    teamName.split(separator: " ").suffix(2).compactMap { $0.first }.map(String.init).joined()
  }

  var body: some View {
    Group {
      if let url = resolvedURL {
        CachedAsyncImage(url: url) { image in
          image.resizable().scaledToFit()
        } placeholder: {
          initialsView
        }
      } else {
        initialsView
      }
    }
    .frame(width: size, height: size)
    .task(id: teamName) {
      if let url = await TeamLogoCache.shared.logoURL(for: teamName, league: league) {
        resolvedURL = url
      }
    }
  }

  private var initialsView: some View {
    ZStack {
      Circle().fill(league.accentColor.opacity(0.15))
      Text(initials)
        .font(.system(size: max(8, size * 0.3), weight: .bold))
        .foregroundStyle(league.accentColor)
    }
  }
}
