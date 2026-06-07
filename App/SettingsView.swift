import SwiftUI

// SettingsView is embedded inside a NavigationStack provided by the Settings tab
// in HomeView — it must NOT wrap itself in its own NavigationStack.
struct SettingsView: View {
  @Environment(FavoritesStore.self) private var favorites
  @Environment(SourceRegistry.self) private var registry
  @AppStorage("debugScrapingView") private var debugScraping = false

  var body: some View {
    List {
      // MARK: Sources
      Section("Sources") {
        NavigationLink(destination: SourceListView()) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "antenna.radiowaves.left.and.right", color: .blue)
            Text("Sources")
              .foregroundStyle(Color(.label))
            Spacer()
            Text("\(registry.enabledSources.count) active")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 2)
        }
        NavigationLink(destination: DiagnosticsView()) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "wrench.and.screwdriver.fill", color: .purple)
            Text("Source Diagnostics")
              .foregroundStyle(Color(.label))
          }
          .padding(.vertical, 2)
        }
        NavigationLink(destination: SourceStatsView()) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "chart.bar.fill", color: .teal)
            Text("Source Stats")
              .foregroundStyle(Color(.label))
          }
          .padding(.vertical, 2)
        }
        NavigationLink(destination: TraversalLogView()) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "list.bullet.rectangle.fill", color: .indigo)
            Text("Traversal Log")
              .foregroundStyle(Color(.label))
          }
          .padding(.vertical, 2)
        }
      }

      // MARK: Debug
      Section {
        Toggle(isOn: $debugScraping) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "ladybug.fill", color: .pink)
            Text("Debug Mode")
              .foregroundStyle(Color(.label))
          }
        }
      } footer: {
        Text("Show the web view while finding a stream. When off, you'll just see a loading screen until playback starts.")
      }

      // MARK: Favorites
      Section {
        NavigationLink(destination: FavoriteSportsView()) {
          settingsRow(
            icon: "sportscourt.fill", color: .green,
            title: "Sports",
            count: favorites.favoriteSports.count
          )
        }
        NavigationLink(destination: FavoriteLeaguesView()) {
          settingsRow(
            icon: "trophy.fill", color: .yellow,
            title: "Leagues",
            count: favorites.favoriteLeagues.count
          )
        }
        NavigationLink(destination: FavoriteTeamsView()) {
          settingsRow(
            icon: "star.fill", color: .orange,
            title: "Teams",
            count: favorites.favoriteTeams.count
          )
        }
      } header: {
        Text("Favorites")
      } footer: {
        Text("Favorites surface live games on the home screen and mark tiles with a star.")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.large)
  }

  // MARK: - Helpers

  private func settingsIcon(systemName: String, color: Color) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(color.opacity(0.15))
        .frame(width: 32, height: 32)
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(color)
    }
  }

  private func settingsRow(icon: String, color: Color, title: String, count: Int) -> some View {
    HStack(spacing: 12) {
      settingsIcon(systemName: icon, color: color)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).foregroundStyle(Color(.label))
        if count > 0 {
          Text("\(count) selected")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Source list page

/// Inline navigation page that lets the user switch sources or add a new one.
/// Pushed via NavigationLink from Settings; selecting a source pops back automatically.
/// The "Add Source" action shows an inline popup card overlay.
struct SourceListView: View {
  @Environment(SourceRegistry.self) private var registry
  @Environment(\.dismiss) private var dismiss
  @AppStorage("debugScrapingView") private var debugScraping = false
  private let templateStore = SourceTemplateStore.shared
  @State private var showAddSource = false
  @State private var newName = ""
  @State private var newURL  = ""
  @State private var addError: String? = nil

  var body: some View {
    ZStack {
      List {
        Section {
          ForEach(registry.sources) { source in
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
              // v2.23: multi-toggle pool. Each source has an independent
              // Enabled state. The bound toggle writes back to
              // SourceRegistry.enabledSourceIDs which triggers HomeView's
              // onChange to recompute the merged feed.
              Toggle("", isOn: Binding(
                get: { registry.enabledSourceIDs.contains(source.id) },
                set: { isOn in
                  if isOn {
                    registry.enabledSourceIDs.insert(source.id)
                  } else {
                    registry.enabledSourceIDs.remove(source.id)
                  }
                }
              ))
              .labelsHidden()
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
        } footer: {
          Text("Any enabled source may be used to find a stream when you tap a game. Add multiple to improve coverage — ESPN provides the game listings; sources serve the streams.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        // Debug Mode: per-source URL templates, learned by probing and
        // editable here.
        if debugScraping {
          Section {
            ForEach(registry.sources.filter { !$0.isBuiltIn }) { source in
              NavigationLink {
                SourceTemplateEditorView(host: source.baseURL.host ?? "", root: source.baseURL)
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text(source.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color(.label))
                  if let t = templateStore.template(forHost: source.baseURL.host) {
                    Text(t.pathPattern)
                      .font(.caption.monospaced())
                      .foregroundStyle(.green)
                  } else {
                    Text("No template — uses page walk")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          } header: {
            Text("URL Templates")
          } footer: {
            Text("Learned automatically when a source is added. A template lets the app jump straight to a game's page instead of walking the homepage.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("Sources")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { withAnimation(.spring(duration: 0.25)) { showAddSource = true } } label: {
            Label("Add", systemImage: "plus")
          }
        }
      }
      // Dimming + popup card overlay
      if showAddSource {
        Color.black.opacity(0.3)
          .ignoresSafeArea()
          .onTapGesture { dismissAddSource() }
          .transition(.opacity)

        AddSourcePopup(
          name: $newName,
          url: $newURL,
          errorMessage: addError,
          onCancel: { dismissAddSource() },
          onAdd: { attemptAdd() }
        )
        .padding(.horizontal, 24)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.25), value: showAddSource)
  }

  private func dismissAddSource() {
    showAddSource = false
    newName = ""
    newURL  = ""
    addError = nil
  }

  private func attemptAdd() {
    let trimName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimURL  = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimName.isEmpty else { addError = "Please enter a name."; return }
    guard !trimURL.isEmpty  else { addError = "Please enter a URL."; return }
    if registry.addSource(name: trimName, urlString: trimURL) {
      dismissAddSource()
    } else {
      addError = "Invalid URL or source already exists."
    }
  }
}

// MARK: - Add Source popup card

private struct AddSourcePopup: View {
  @Binding var name: String
  @Binding var url: String
  let errorMessage: String?
  let onCancel: () -> Void
  let onAdd: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      // Title
      Text("Add Source")
        .font(.headline)
        .padding(.top, 20)
        .padding(.bottom, 16)

      // Fields
      VStack(spacing: 0) {
        TextField("Name (e.g. MyStreams)", text: $name)
          .autocorrectionDisabled()
          .padding(.horizontal, 16)
          .padding(.vertical, 13)
        Divider().padding(.leading, 16)
        TextField("URL (e.g. https://example.com)", text: $url)
          .keyboardType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .padding(.horizontal, 16)
          .padding(.vertical, 13)
      }
      .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 4)

      // Inline error
      if let err = errorMessage {
        Text(err)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.top, 8)
          .padding(.horizontal, 4)
      }

      // Divider + buttons
      Divider().padding(.top, errorMessage == nil ? 16 : 8)

      HStack(spacing: 0) {
        Button("Cancel") { onCancel() }
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)

        Rectangle()
          .fill(Color(.separator))
          .frame(width: 0.5, height: 44)

        Button("Add") { onAdd() }
          .font(.body.bold())
          .foregroundStyle(.tint)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
      }
    }
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }
}

// MARK: - Source template editor (Debug Mode)

/// Debug-only editor for a source's learned URL template. Lets the user view,
/// hand-correct, clear, or re-probe the template. Placeholders supported in
/// the pattern: {league}, {date}, {home}, {away}.
struct SourceTemplateEditorView: View {
  let host: String
  let root: URL
  private let store = SourceTemplateStore.shared
  @Environment(\.dismiss) private var dismiss

  @State private var pattern = ""
  @State private var dateFormat = ""
  @State private var teamStyle: SourceTemplate.TeamStyle = .abbreviation
  @State private var verified = false
  @State private var probing = false
  @State private var previewURL: String?
  @State private var sampleGames: [Game] = []

  var body: some View {
    List {
      Section {
        TextField("/live/{league}/{date}/{away}-{home}", text: $pattern)
          .font(.body.monospaced())
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        TextField("Date format (e.g. yyyy-MM-dd)", text: $dateFormat)
          .font(.body.monospaced())
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        Picker("Team style", selection: $teamStyle) {
          Text("Abbreviation (wsh)").tag(SourceTemplate.TeamStyle.abbreviation)
          Text("Full slug (washington-nationals)").tag(SourceTemplate.TeamStyle.slug)
        }
      } header: {
        Text("Template")
      } footer: {
        Text("Placeholders: {league}, {date}, {home}, {away}.")
      }

      if let previewURL {
        Section("Preview") {
          Text(previewURL)
            .font(.caption.monospaced())
            .foregroundStyle(.blue)
            .textSelection(.enabled)
        }
      }

      if let status = store.status(forHost: host) {
        Section("Last Probe") {
          Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section {
        Button {
          save()
        } label: {
          Label("Save Template", systemImage: "checkmark.circle.fill")
        }
        .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)

        Button {
          reprobe()
        } label: {
          HStack {
            Label("Re-probe Source", systemImage: "arrow.clockwise")
            if probing { Spacer(); ProgressView() }
          }
        }
        .disabled(probing)

        Button(role: .destructive) {
          store.set(nil, forHost: host)
          pattern = ""; dateFormat = ""; verified = false; previewURL = nil
        } label: {
          Label("Clear Template", systemImage: "trash")
        }
      } footer: {
        if verified {
          Label("Verified against the site's links", systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(host)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear(perform: loadFromStore)
    .task {
      sampleGames = await ScheduleAggregator.shared.todaysGames()
      updatePreview()
    }
    .onChange(of: pattern) { _, _ in updatePreview() }
    .onChange(of: dateFormat) { _, _ in updatePreview() }
    .onChange(of: teamStyle) { _, _ in updatePreview() }
  }

  private func loadFromStore() {
    if let t = store.template(forHost: host) {
      pattern = t.pathPattern
      dateFormat = t.dateFormat
      teamStyle = t.teamStyle
      verified = t.verified
    }
  }

  private func currentTemplate() -> SourceTemplate {
    SourceTemplate(
      pathPattern: pattern.trimmingCharacters(in: .whitespaces),
      dateFormat: dateFormat.trimmingCharacters(in: .whitespaces),
      teamStyle: teamStyle,
      verified: verified
    )
  }

  private func save() {
    // A hand-edited template is no longer "probe-verified".
    verified = false
    store.set(currentTemplate(), forHost: host)
  }

  private func updatePreview() {
    let trimmed = pattern.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let game = sampleGames.first(where: { !$0.awayTeam.isEmpty }) ?? sampleGames.first else {
      previewURL = nil
      return
    }
    previewURL = currentTemplate().url(for: game, root: root)?.absoluteString
  }

  private func reprobe() {
    probing = true
    Task {
      let result = await SourceProbe.probeWithStatus(root: root)
      await MainActor.run {
        probing = false
        store.setStatus(result.status, forHost: host)
        if let learned = result.template {
          store.set(learned, forHost: host)
          pattern = learned.pathPattern
          dateFormat = learned.dateFormat
          teamStyle = learned.teamStyle
          verified = learned.verified
          updatePreview()
        }
      }
    }
  }
}

// MARK: - Favorite Sports

struct FavoriteSportsView: View {
  @Environment(FavoritesStore.self) private var favorites

  var body: some View {
    List {
      ForEach(Sport.allCases) { sport in
        Button { favorites.toggleSport(sport) } label: {
          HStack(spacing: 12) {
            ZStack {
              Circle()
                .fill(sport.accentColor.opacity(0.12))
                .frame(width: 36, height: 36)
              Image(systemName: sport.sfSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(sport.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(sport.displayName).foregroundStyle(Color(.label))
              Text(sport.leagues.map(\.displayName).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if favorites.isSportFavorite(sport) {
              Image(systemName: "star.fill").foregroundStyle(Color.yellow)
            } else {
              Image(systemName: "star").foregroundStyle(.quaternary)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Favorite Sports")
    .navigationBarTitleDisplayMode(.large)
  }
}

// MARK: - Favorite Leagues

struct FavoriteLeaguesView: View {
  @Environment(FavoritesStore.self) private var favorites

  var body: some View {
    List {
      // Hide `.other` from favorites — it's a catch-all bucket, not a real league.
      ForEach(SportLeague.allCases.filter { $0 != .other }) { league in
        Button { favorites.toggleLeague(league) } label: {
          HStack(spacing: 12) {
            LeagueIcon(league: league, size: 36)
            Text(league.displayName).foregroundStyle(Color(.label))
            Spacer()
            if favorites.isLeagueFavorite(league) {
              Image(systemName: "star.fill").foregroundStyle(Color.yellow)
            } else {
              Image(systemName: "star").foregroundStyle(.quaternary)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Favorite Leagues")
    .navigationBarTitleDisplayMode(.large)
  }
}

// MARK: - Favorite Teams

struct FavoriteTeamsView: View {
  @Environment(FavoritesStore.self) private var favorites
  @State private var teamSearch = ""

  var filteredGroups: [(league: SportLeague, teams: [String])] {
    if teamSearch.isEmpty { return FavoritesStore.knownTeams }
    let q = teamSearch.lowercased()
    return FavoritesStore.knownTeams.compactMap { group in
      let matched = group.teams.filter { $0.lowercased().contains(q) }
      return matched.isEmpty ? nil : (group.league, matched)
    }
  }

  var body: some View {
    List {
      ForEach(filteredGroups, id: \.league) { group in
        DisclosureGroup {
          ForEach(group.teams, id: \.self) { team in
            Button { favorites.toggleTeam(team) } label: {
              HStack(spacing: 12) {
                TeamLogo(teamName: team, league: group.league, size: 30)
                Text(team).foregroundStyle(Color(.label))
                Spacer()
                if favorites.isTeamFavorite(team) {
                  Image(systemName: "star.fill").foregroundStyle(Color.yellow)
                } else {
                  Image(systemName: "star").foregroundStyle(.quaternary)
                }
              }
            }
            .buttonStyle(.plain)
          }
        } label: {
          HStack(spacing: 10) {
            LeagueIcon(league: group.league, size: 28)
            Text(group.league.displayName)
              .font(.subheadline.bold())
              .foregroundStyle(group.league.accentColor)
            if !teamSearch.isEmpty {
              Text("(\(group.teams.count))")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Favorite Teams")
    .navigationBarTitleDisplayMode(.large)
    .searchable(text: $teamSearch, prompt: "Search teams…")
  }
}

// MARK: - Shared league icon

struct LeagueIcon: View {
  let league: SportLeague
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(league.accentColor.opacity(0.12))
        .frame(width: size, height: size)

      if let logoURL = league.leagueLogoURL {
        CachedAsyncImage(url: logoURL) { image in
          image.resizable().scaledToFit()
            .padding(size * 0.12)
        } placeholder: {
          Text(league.emoji)
            .font(.system(size: size * 0.55))
        }
        .frame(width: size, height: size)
      } else {
        Text(league.emoji)
          .font(.system(size: size * 0.55))
      }
    }
  }
}
