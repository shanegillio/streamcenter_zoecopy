import SwiftUI

struct HomeView: View {
  @Environment(SourceRegistry.self) private var registry
  @State private var availableLeagues: [SportLeague] = []
  @State private var isLoading = true
  @State private var showSourcePicker = false

  private let columns = [
    GridItem(.flexible()),
    GridItem(.flexible()),
    GridItem(.flexible()),
  ]

  var body: some View {
    @Bindable var reg = registry
    NavigationStack {
      ZStack {
        if isLoading {
          ProgressView()
            .scaleEffect(1.3)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              if availableLeagues.isEmpty {
                emptyState
              } else {
                leagueGrid
              }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
          }
        }
      }
      .navigationTitle("StreamZone")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showSourcePicker = true
          } label: {
            Label("Source", systemImage: "antenna.radiowaves.left.and.right")
          }
        }
      }
      .confirmationDialog("Stream Source", isPresented: $showSourcePicker, titleVisibility: .visible) {
        ForEach(registry.sources) { source in
          Button {
            registry.selectedSource = source
            Task { await loadLeagues() }
          } label: {
            Text(source.name + (source.id == registry.selectedSource.id ? " ✓" : ""))
          }
        }
        Button("Cancel", role: .cancel) {}
      }
      .task { await loadLeagues() }
    }
  }

  private var leagueGrid: some View {
    LazyVGrid(columns: columns, spacing: 16) {
      ForEach(availableLeagues) { league in
        NavigationLink(destination: GamesView(league: league, source: registry.selectedSource)) {
          LeagueTile(league: league)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Spacer(minLength: 80)
      Image(systemName: "sportscourt")
        .font(.system(size: 56))
        .foregroundStyle(.quaternary)
      Text("No leagues available")
        .font(.headline)
        .foregroundStyle(.secondary)
      Button("Retry") { Task { await loadLeagues() } }
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
  }

  private func loadLeagues() async {
    isLoading = true
    availableLeagues = (try? await registry.selectedSource.fetchAvailableLeagues()) ?? []
    isLoading = false
  }
}

struct LeagueTile: View {
  let league: SportLeague

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16)
        .fill(league.accentColor.opacity(0.13))
        .aspectRatio(1, contentMode: .fit)

      VStack(spacing: 10) {
        Image(systemName: league.sfSymbol)
          .font(.system(size: 36, weight: .bold))
          .foregroundStyle(league.accentColor)

        Text(league.displayName)
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(league.accentColor.opacity(0.85))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.7)
          .padding(.horizontal, 6)
      }
    }
  }
}
