import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(FavoritesStore.self) private var favorites
  @State private var teamSearch = ""

  var body: some View {
    NavigationStack {
      List {
        leaguesSection
        teamsSection
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  // MARK: - Favorite Leagues

  private var leaguesSection: some View {
    Section {
      ForEach(SportLeague.allCases) { league in
        Button {
          favorites.toggleLeague(league)
        } label: {
          HStack(spacing: 12) {
            ZStack {
              Circle()
                .fill(league.accentColor.opacity(0.12))
                .frame(width: 36, height: 36)
              Image(systemName: league.sfSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(league.accentColor)
            }
            Text(league.displayName)
              .foregroundStyle(Color(.label))
            Spacer()
            if favorites.isLeagueFavorite(league) {
              Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
            } else {
              Image(systemName: "star")
                .foregroundStyle(.quaternary)
            }
          }
        }
        .buttonStyle(.plain)
      }
    } header: {
      Text("Favorite Leagues")
    } footer: {
      Text("Starred leagues show a badge on their home screen tile.")
    }
  }

  // MARK: - Favorite Teams

  private var filteredGroups: [(league: SportLeague, teams: [String])] {
    if teamSearch.isEmpty { return FavoritesStore.knownTeams }
    let q = teamSearch.lowercased()
    return FavoritesStore.knownTeams.compactMap { group in
      let matched = group.teams.filter { $0.lowercased().contains(q) }
      return matched.isEmpty ? nil : (group.league, matched)
    }
  }

  private var teamsSection: some View {
    Section {
      if !favorites.favoriteTeams.isEmpty {
        // Pinned favorites row
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(Array(favorites.favoriteTeams).sorted(), id: \.self) { team in
              Button {
                favorites.toggleTeam(team)
              } label: {
                HStack(spacing: 4) {
                  Text(team.capitalized)
                    .font(.caption.bold())
                  Image(systemName: "xmark")
                    .font(.caption2.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.12), in: Capsule())
                .foregroundStyle(.tint)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
      }

      if teamSearch.isEmpty || !filteredGroups.isEmpty {
        ForEach(filteredGroups, id: \.league) { group in
          DisclosureGroup {
            ForEach(group.teams, id: \.self) { team in
              Button {
                favorites.toggleTeam(team)
              } label: {
                HStack {
                  Text(team)
                    .foregroundStyle(Color(.label))
                  Spacer()
                  if favorites.isTeamFavorite(team) {
                    Image(systemName: "star.fill")
                      .foregroundStyle(.yellow)
                  } else {
                    Image(systemName: "star")
                      .foregroundStyle(.quaternary)
                  }
                }
              }
              .buttonStyle(.plain)
            }
          } label: {
            Label(group.league.displayName, systemImage: group.league.sfSymbol)
              .font(.subheadline.bold())
              .foregroundStyle(group.league.accentColor)
          }
        }
      }
    } header: {
      HStack {
        Text("Favorite Teams")
        Spacer()
        if !teamSearch.isEmpty {
          Button("Clear") { teamSearch = "" }
            .font(.caption)
        }
      }
    } footer: {
      Text("Favorite team games appear at the top of league listings and in the Favorites tile on the home screen.")
    }
    .searchable(text: $teamSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search teams…")
  }
}
