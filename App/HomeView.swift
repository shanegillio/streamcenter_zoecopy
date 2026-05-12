import SwiftUI

struct HomeView: View {
  @Environment(SourceRegistry.self) private var registry
  @State private var availableLeagues: [SportLeague] = []
  @State private var isLoading = true
  @State private var showSourceManager = false

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
        SourceManagerSheet(selectedSourceID: registry.selectedSource.id) { source in
          registry.selectedSource = source
          showSourceManager = false
          Task { await loadLeagues() }
        } onAdd: { name, url in
          _ = registry.addSource(name: name, urlString: url)
        } onDelete: { source in
          registry.removeSource(source)
        }
        .environment(registry)
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

// MARK: - Source Manager Sheet

struct SourceManagerSheet: View {
  @Environment(SourceRegistry.self) private var registry
  var selectedSourceID: String
  var onSelect: (AnyStreamSource) -> Void
  var onAdd: (String, String) -> Void
  var onDelete: (AnyStreamSource) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var showAddSource = false

  var body: some View {
    NavigationStack {
      List {
        ForEach(registry.sources) { source in
          Button {
            onSelect(source)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                  .font(.body)
                  .foregroundStyle(.primary)
                Text(source.baseURL.host ?? source.baseURL.absoluteString)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if source.id == selectedSourceID {
                Image(systemName: "checkmark")
                  .font(.body.weight(.semibold))
                  .foregroundStyle(.tint)
              }
            }
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !source.isBuiltIn {
              Button(role: .destructive) {
                onDelete(source)
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
        AddSourceSheet(onAdd: onAdd)
      }
    }
  }
}

// MARK: - Add Source Sheet

struct AddSourceSheet: View {
  var onAdd: (String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var sourceName = ""
  @State private var sourceURL = ""
  @State private var showError = false

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
          if showError {
            Text("Please enter a valid name and URL.")
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
          Button("Add") {
            let trimName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimName.isEmpty && !trimURL.isEmpty else { showError = true; return }
            onAdd(trimName, trimURL)
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium])
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
