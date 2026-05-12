import SwiftUI

struct HomeView: View {
  @Environment(SourceRegistry.self) private var registry
  @State private var availableLeagues: [SportLeague] = []
  @State private var isLoading = true
  @State private var loadFailed = false
  @State private var showSourceManager = false

  private let columns = [
    GridItem(.flexible()),
    GridItem(.flexible()),
    GridItem(.flexible()),
  ]

  var body: some View {
    NavigationStack {
      ZStack {
        if isLoading {
          VStack(spacing: 14) {
            ProgressView().scaleEffect(1.3)
            if !registry.selectedSource.isBuiltIn {
              Text("Scanning \(registry.selectedSource.name) for streams…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
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
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text("StreamCenter")
            .font(.system(size: 22, weight: .bold))
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showSourceManager = true
          } label: {
            Label("Sources", systemImage: "antenna.radiowaves.left.and.right")
          }
        }
      }
      .sheet(isPresented: $showSourceManager) {
        SourceManagerSheet()
          .environment(registry)
          .onDisappear {
            Task { await loadLeagues() }
          }
      }
      .task { await loadLeagues() }
    }
  }

  private var leagueGrid: some View {
    LazyVGrid(columns: columns, spacing: 16) {
      // Browse tile always appears first for custom sources
      if !registry.selectedSource.isBuiltIn {
        NavigationLink(destination: BrowseView(source: registry.selectedSource)) {
          BrowseTile(source: registry.selectedSource)
        }
        .buttonStyle(.plain)
      }
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
      Spacer(minLength: 60)
      if !registry.selectedSource.isBuiltIn {
        Image(systemName: loadFailed ? "wifi.exclamationmark" : "questionmark.circle")
          .font(.system(size: 48))
          .foregroundStyle(.secondary)
        Text(loadFailed ? "Couldn't reach \(registry.selectedSource.name)" : "No leagues detected")
          .font(.headline)
        Text(loadFailed
          ? "Check your connection, then try again. You can also browse the site manually."
          : "The site loaded but no game listings were found. Browse the site manually — streams will be intercepted automatically when you tap one."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        NavigationLink(destination: BrowseView(source: registry.selectedSource)) {
          Label("Browse \(registry.selectedSource.name)", systemImage: "globe")
            .padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
        Button("Try Again") { Task { await loadLeagues() } }
          .buttonStyle(.bordered)
      } else {
        Image(systemName: "sportscourt")
          .font(.system(size: 52))
          .foregroundStyle(.quaternary)
        Text("No leagues available")
          .font(.headline)
          .foregroundStyle(.secondary)
        Button("Retry") { Task { await loadLeagues() } }
          .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func loadLeagues() async {
    isLoading = true
    loadFailed = false
    do {
      availableLeagues = try await registry.selectedSource.fetchAvailableLeagues()
    } catch {
      availableLeagues = []
      loadFailed = true
    }
    isLoading = false
  }
}

// MARK: - Source Manager Sheet

struct SourceManagerSheet: View {
  @Environment(SourceRegistry.self) private var registry
  @Environment(\.dismiss) private var dismiss
  @State private var showAddSource = false

  var body: some View {
    NavigationStack {
      List {
        ForEach(registry.sources) { source in
          Button {
            registry.selectedSource = source
            dismiss()
          } label: {
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                  .font(.body.weight(.medium))
                  .foregroundStyle(Color(.label))
                Text(source.baseURL.host ?? source.baseURL.absoluteString)
                  .font(.caption)
                  .foregroundStyle(.blue)
              }
              Spacer()
              if source.id == registry.selectedSource.id {
                Image(systemName: "checkmark")
                  .font(.body.weight(.semibold))
                  .foregroundStyle(.tint)
              }
            }
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !source.isBuiltIn {
              Button(role: .destructive) {
                registry.removeSource(source)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        }
      }
      .navigationTitle("Stream Sources")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showAddSource = true
          } label: {
            Label("Add", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $showAddSource) {
        AddSourceSheet()
          .environment(registry)
      }
    }
  }
}

// MARK: - Add Source Sheet

struct AddSourceSheet: View {
  @Environment(SourceRegistry.self) private var registry
  @Environment(\.dismiss) private var dismiss
  @State private var sourceName = ""
  @State private var sourceURL = ""
  @State private var errorMessage: String? = nil

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name (e.g. MyStreams)", text: $sourceName)
            .autocorrectionDisabled()
          TextField("URL (e.g. https://example.com)", text: $sourceURL)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } footer: {
          if let msg = errorMessage {
            Text(msg)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Add Source")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { attemptAdd() }
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func attemptAdd() {
    let trimName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimName.isEmpty else { errorMessage = "Please enter a name."; return }
    guard !trimURL.isEmpty else { errorMessage = "Please enter a URL."; return }
    let success = registry.addSource(name: trimName, urlString: trimURL)
    if success {
      dismiss()
    } else {
      errorMessage = "Invalid URL or source already exists."
    }
  }
}

// MARK: - Browse tile (custom sources)

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

// MARK: - League tile

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
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(league.accentColor.opacity(0.85))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .minimumScaleFactor(0.3)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 6)
      }
    }
  }
}
