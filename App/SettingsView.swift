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
            settingsIcon(systemName: "antenna.radiowaves.left.and.right")
            Text("Sources")
              .foregroundStyle(GuideTheme.text)
            Spacer()
            Text("\(registry.enabledSources.count)")
              .font(.subheadline)
              .foregroundStyle(GuideTheme.textDim)
          }
          .padding(.vertical, 2)
        }
        .listRowBackground(GuideTheme.panel)
      }

      // MARK: Favorites
      Section {
        NavigationLink(destination: AllFavoritesView()) {
          settingsRow(
            icon: "star.fill",
            title: "All favorites",
            count: 0
          )
        }
        .listRowBackground(GuideTheme.panel)
        NavigationLink(destination: FavoriteSportsView()) {
          settingsRow(
            icon: "sportscourt.fill",
            title: "Sports",
            count: favorites.favoriteSports.count
          )
        }
        .listRowBackground(GuideTheme.panel)
        NavigationLink(destination: FavoriteLeaguesView()) {
          settingsRow(
            icon: "trophy.fill",
            title: "Leagues",
            count: favorites.favoriteLeagues.count
          )
        }
        .listRowBackground(GuideTheme.panel)
        NavigationLink(destination: FavoriteTeamsView()) {
          settingsRow(
            icon: "person.3.fill",
            title: "Teams",
            count: favorites.favoriteTeams.count
          )
        }
        .listRowBackground(GuideTheme.panel)
      } header: {
        Text("Favorites")
      } footer: {
        Text("Favorites surface live games on the home screen and mark tiles with a star.")
      }

      // MARK: Debugging
      Section {
        Toggle(isOn: $debugScraping) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "ladybug.fill")
            Text("Debugging mode")
              .foregroundStyle(GuideTheme.text)
          }
        }
        .listRowBackground(GuideTheme.panel)
        NavigationLink(destination: DiagnosticsView()) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "wrench.and.screwdriver.fill")
            Text("Source Diagnostics")
              .foregroundStyle(GuideTheme.text)
          }
          .padding(.vertical, 2)
        }
        .listRowBackground(GuideTheme.panel)
        NavigationLink(destination: TraversalLogView()) {
          HStack(spacing: 12) {
            settingsIcon(systemName: "list.bullet.rectangle.fill")
            Text("Traversal Log")
              .foregroundStyle(GuideTheme.text)
          }
          .padding(.vertical, 2)
        }
        .listRowBackground(GuideTheme.panel)
      } header: {
        Text("Debugging")
      } footer: {
        Text("Debugging mode shows the web view while finding a stream. When off, you'll just see a loading screen until playback starts.")
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(GuideTheme.background)
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.large)
  }

  // MARK: - Helpers

  /// Standard iOS-style settings glyph: a filled accent square with a white
  /// symbol. Every row uses the same accent so the list reads as one app.
  private func settingsIcon(systemName: String) -> some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .fill(Color.accentColor)
      .frame(width: 30, height: 30)
      .overlay(
        Image(systemName: systemName)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
      )
  }

  private func settingsRow(icon: String, title: String, count: Int) -> some View {
    HStack(spacing: 12) {
      settingsIcon(systemName: icon)
      Text(title).foregroundStyle(GuideTheme.text)
      Spacer()
      if count > 0 {
        Text("\(count)")
          .font(.subheadline)
          .foregroundStyle(GuideTheme.textDim)
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
  /// When pushed from the empty "no sources" screen we open straight into the
  /// add dialog so the very first launch is one tap to a working source.
  var autoPresentAdd: Bool = false

  @State private var showEditor = false
  /// nil while adding a new source; set to the source being edited otherwise.
  @State private var editingSource: AnyStreamSource? = nil
  @State private var draftName = ""
  @State private var draftURL  = ""
  @State private var editorError: String? = nil
  var body: some View {
    ZStack {
      GuideTheme.background.ignoresSafeArea()
      List {
        Section {
          ForEach(registry.sources) { source in
            swipeableSourceRow(source)
          }
        } footer: {
          Text("Any enabled source may be used to find a stream when you tap a game. Add multiple to improve coverage — ESPN provides the game listings; sources serve the streams.")
            .font(.footnote)
            .foregroundStyle(GuideTheme.textDim)
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(GuideTheme.background)

      // Dimming + popup card overlay (shared between Add and Edit).
      if showEditor {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .onTapGesture { dismissEditor() }
          .transition(.opacity)

        AddSourcePopup(
          title: editingSource == nil ? "Add Source" : "Edit Source",
          actionLabel: editingSource == nil ? "Add" : "Save",
          name: $draftName,
          url: $draftURL,
          errorMessage: editorError,
          onCancel: { dismissEditor() },
          onAdd: { commitEditor() }
        )
        .padding(.horizontal, 24)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
      }
    }
    .navigationTitle("Sources")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button { beginAdd() } label: {
          Label("Add", systemImage: "plus")
        }
      }
    }
    .animation(.spring(duration: 0.25), value: showEditor)
    .onAppear {
      if autoPresentAdd && registry.sources.isEmpty && !showEditor { beginAdd() }
    }
  }

  // Composes a source row with its rounded-on-swipe background and trailing
  // swipe actions. On iOS 27+ the `onPresentationChanged` callback tracks which
  // row is open so only that row rounds; older OSes keep the prior behavior.
  @ViewBuilder
  private func swipeableSourceRow(_ source: AnyStreamSource) -> some View {
    sourceRow(source)
      .listRowBackground(rowBackground(for: source))
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        swipeButtons(source)
      }
  }

  // Swipe-left actions: Edit (name + URL) and Delete, mirroring the system
  // Notes-style trailing actions. Built-in sources can't be edited or removed.
  @ViewBuilder
  private func swipeButtons(_ source: AnyStreamSource) -> some View {
    if !source.isBuiltIn {
      Button(role: .destructive) {
        registry.removeSource(source)
      } label: {
        Label("Delete", systemImage: "trash")
      }
      Button { beginEdit(source) } label: {
        Label("Edit", systemImage: "pencil")
      }
      .tint(.blue)
    }
  }

  // Rows render as one continuous group, matching the grouped list look.
  @ViewBuilder
  private func rowBackground(for source: AnyStreamSource) -> some View {
    Rectangle().fill(GuideTheme.panel)
  }

  private func sourceRow(_ source: AnyStreamSource) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(source.name)
          .font(.body.weight(.medium))
          .foregroundStyle(GuideTheme.text)
        Text(source.baseURL.host ?? source.baseURL.absoluteString)
          .font(.caption)
          .foregroundStyle(.blue)
      }
      Spacer()
      // v2.23 multi-toggle pool: each source has an independent enabled state.
      Toggle("", isOn: Binding(
        get: { registry.enabledSourceIDs.contains(source.id) },
        set: { isOn in
          if isOn { registry.enabledSourceIDs.insert(source.id) }
          else { registry.enabledSourceIDs.remove(source.id) }
        }
      ))
      .labelsHidden()
    }
  }

  private func beginAdd() {
    editingSource = nil
    draftName = ""
    draftURL  = ""
    editorError = nil
    withAnimation(.spring(duration: 0.25)) { showEditor = true }
  }

  private func beginEdit(_ source: AnyStreamSource) {
    editingSource = source
    draftName = source.name
    draftURL  = source.baseURL.absoluteString
    editorError = nil
    withAnimation(.spring(duration: 0.25)) { showEditor = true }
  }

  private func dismissEditor() {
    showEditor = false
    editingSource = nil
    draftName = ""
    draftURL  = ""
    editorError = nil
  }

  private func commitEditor() {
    let trimName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimURL  = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimName.isEmpty else { editorError = "Please enter a name."; return }
    guard !trimURL.isEmpty  else { editorError = "Please enter a URL."; return }
    let ok: Bool
    if let editing = editingSource {
      ok = registry.updateSource(editing, name: trimName, urlString: trimURL)
    } else {
      ok = registry.addSource(name: trimName, urlString: trimURL)
    }
    if ok { dismissEditor() }
    else { editorError = "Invalid URL or source already exists." }
  }
}

// MARK: - Add Source popup card

private struct AddSourcePopup: View {
  var title: String = "Add Source"
  var actionLabel: String = "Add"
  @Binding var name: String
  @Binding var url: String
  let errorMessage: String?
  let onCancel: () -> Void
  let onAdd: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      // Title
      Text(title)
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

        Button(actionLabel) { onAdd() }
          .font(.body.bold())
          .foregroundStyle(.tint)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
      }
    }
    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
  }
}

// MARK: - Shared favorites styling

extension View {
  /// Common dark, inset-grouped list chrome shared by every settings/favorites
  /// sub-page so they all match the overall Settings look.
  func darkSettingsList() -> some View {
    self
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(GuideTheme.background)
  }
}

/// Standard tap-to-toggle favorites star, filled-yellow when on.
@ViewBuilder
func FavoriteStar(_ on: Bool) -> some View {
  Image(systemName: on ? "star.fill" : "star")
    .font(.system(size: 17))
    .foregroundStyle(on ? AnyShapeStyle(.yellow) : AnyShapeStyle(Color(.tertiaryLabel)))
    // Nudge the star inward so it doesn't crowd the trailing A–Z index bar.
    .padding(.trailing, 6)
}

// MARK: - Favorite Sports

struct FavoriteSportsView: View {
  @Environment(FavoritesStore.self) private var favorites

  private var sports: [Sport] {
    Sport.allCases.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  var body: some View {
    List {
      ForEach(sports) { sport in
        Button { favorites.toggleSport(sport) } label: {
          HStack(spacing: 14) {
            ZStack {
              Circle()
                .fill(sport.accentColor.opacity(0.22))
                .frame(width: 40, height: 40)
              Image(systemName: sport.sfSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(sport.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(sport.displayName)
                .font(.body.weight(.medium))
                .foregroundStyle(GuideTheme.text)
              Text(sport.leagues.map(\.displayName).joined(separator: ", "))
                .font(.caption).foregroundStyle(GuideTheme.textDim)
                .lineLimit(1)
            }
            Spacer()
            FavoriteStar(favorites.isSportFavorite(sport))
          }
          .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(GuideTheme.panel)
      }
    }
    .navigationTitle("All Sports")
    .navigationBarTitleDisplayMode(.large)
    .darkSettingsList()
  }
}

// MARK: - Favorite Leagues

struct FavoriteLeaguesView: View {
  @Environment(FavoritesStore.self) private var favorites
  @State private var search = ""

  private var leagues: [SportLeague] {
    // Hide `.other` — it's a catch-all bucket, not a real league.
    let all = SportLeague.allCases.filter { $0 != .other }
    let sorted = all.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    guard !search.isEmpty else { return sorted }
    let q = search.lowercased()
    return sorted.filter { $0.displayName.lowercased().contains(q) }
  }

  /// Alphabetic sections, e.g. [("M", [MLB, MLS]), …].
  private var sections: [(letter: String, leagues: [SportLeague])] {
    let groups = Dictionary(grouping: leagues) { String($0.displayName.prefix(1)).uppercased() }
    return groups.keys.sorted().map { ($0, groups[$0]!) }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .trailing) {
        List {
          ForEach(sections, id: \.letter) { section in
            Section {
              ForEach(section.leagues) { league in
                leagueRow(league)
              }
            } header: {
              Text(section.letter)
                .font(.caption.weight(.bold))
                .foregroundStyle(GuideTheme.textDim)
                .id(section.letter)
            }
          }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(GuideTheme.background)

        // Contacts-style A–Z index — only when not searching and there's
        // more than one letter to jump between.
        if search.isEmpty && sections.count > 1 {
          let sectionLetters = sections.map(\.letter)
          SectionIndexBar(letters: LeagueTeamsView.alphabet, available: Set(sectionLetters)) { letter in
            let target = sectionLetters.first { $0 >= letter } ?? sectionLetters.last
            if let target {
              proxy.scrollTo(target, anchor: .top)
            }
          }
          .padding(.trailing, 4)
        }
      }
    }
    .navigationTitle("All Leagues")
    .navigationBarTitleDisplayMode(.large)
    .searchable(text: $search, prompt: "Search leagues…")
  }

  private func leagueRow(_ league: SportLeague) -> some View {
    Button { favorites.toggleLeague(league) } label: {
      HStack(spacing: 14) {
        LeagueIcon(league: league, size: 40)
        Text(league.displayName)
          .font(.body.weight(.medium))
          .foregroundStyle(GuideTheme.text)
        Spacer()
        FavoriteStar(favorites.isLeagueFavorite(league))
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .listRowBackground(GuideTheme.panel)
  }
}

// MARK: - Favorite Teams (league chooser)

/// Top-level Teams page: a list of leagues. Tapping one pushes a dedicated
/// page of that league's teams (instead of the old inline dropdown).
struct FavoriteTeamsView: View {
  private var groups: [(league: SportLeague, teams: [String])] {
    FavoritesStore.knownTeams.sorted {
      $0.league.displayName.localizedCaseInsensitiveCompare($1.league.displayName) == .orderedAscending
    }
  }

  var body: some View {
    List {
      ForEach(groups, id: \.league) { group in
        NavigationLink {
          LeagueTeamsView(league: group.league, teams: group.teams)
        } label: {
          HStack(spacing: 14) {
            LeagueIcon(league: group.league, size: 40)
            Text(group.league.displayName)
              .font(.body.weight(.medium))
              .foregroundStyle(GuideTheme.text)
          }
          .padding(.vertical, 4)
        }
        .listRowBackground(GuideTheme.panel)
      }
    }
    .navigationTitle("Select a league")
    .navigationBarTitleDisplayMode(.large)
    .darkSettingsList()
  }
}

// MARK: - League teams page (A–Z index + search)

struct LeagueTeamsView: View {
  let league: SportLeague
  let teams: [String]
  @Environment(FavoritesStore.self) private var favorites
  @State private var search = ""

  private var filtered: [String] {
    let sorted = teams.sorted()
    guard !search.isEmpty else { return sorted }
    let q = search.lowercased()
    return sorted.filter { $0.lowercased().contains(q) }
  }

  /// The full A–Z index shown on the trailing edge, regardless of which
  /// letters currently have teams.
  static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)

  /// Alphabetic sections, e.g. [("A", ["Astros", "Athletics"]), …].
  private var sections: [(letter: String, teams: [String])] {
    let groups = Dictionary(grouping: filtered) { String($0.prefix(1)).uppercased() }
    return groups.keys.sorted().map { ($0, groups[$0]!.sorted()) }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .trailing) {
        List {
          ForEach(sections, id: \.letter) { section in
            Section {
              ForEach(section.teams, id: \.self) { team in
                teamRow(team).listRowBackground(GuideTheme.panel)
              }
            } header: {
              Text(section.letter)
                .font(.caption.weight(.bold))
                .foregroundStyle(GuideTheme.textDim)
                .id(section.letter)
            }
          }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(GuideTheme.background)

        // Contacts-style A–Z index — only when not searching and there's
        // more than one letter to jump between.
        if search.isEmpty && sections.count > 1 {
          let sectionLetters = sections.map(\.letter)
          SectionIndexBar(letters: Self.alphabet, available: Set(sectionLetters)) { letter in
            // Empty letters jump to the next section at or after them, so the
            // full A–Z index stays usable even where a letter has no teams.
            let target = sectionLetters.first { $0 >= letter } ?? sectionLetters.last
            if let target {
              // Snap straight to the section (no animation) so dragging the
              // index tracks the finger instantly, like Contacts.
              proxy.scrollTo(target, anchor: .top)
            }
          }
          .padding(.trailing, 4)
        }
      }
    }
    .navigationTitle("All \(league.displayName) Teams")
    .navigationBarTitleDisplayMode(.large)
    .searchable(text: $search, prompt: "Search teams…")
  }

  private func teamRow(_ team: String) -> some View {
    Button { favorites.toggleTeam(team) } label: {
      HStack(spacing: 12) {
        TeamLogo(teamName: team, league: league, size: 32)
        Text(team).font(.body).foregroundStyle(GuideTheme.text)
        Spacer()
        FavoriteStar(favorites.isTeamFavorite(team))
      }
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
  }
}

/// Vertical alphabet index on the trailing edge. Tap or drag to jump. Sized to
/// its letters (compact) and centered vertically rather than stretched edge to
/// edge, with breathing room on either side.
struct SectionIndexBar: View {
  let letters: [String]
  /// Letters that actually have a section to jump to; others render dimmed.
  let available: Set<String>
  let onSelect: (String) -> Void

  var body: some View {
    VStack(spacing: 2) {
      ForEach(letters, id: \.self) { letter in
        Text(letter)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tint)
          .opacity(available.contains(letter) ? 1 : 0.3)
      }
    }
    .frame(maxHeight: .infinity)
    .padding(.vertical, 8)
    .padding(.horizontal, 7)
    .contentShape(Rectangle())
    .overlay {
      GeometryReader { geo in
        Color.clear
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in
                guard !letters.isEmpty, geo.size.height > 0 else { return }
                let slot = geo.size.height / CGFloat(letters.count)
                let idx = min(letters.count - 1, max(0, Int(value.location.y / slot)))
                onSelect(letters[idx])
              }
          )
      }
    }
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

// MARK: - All favorites

/// One page showing every current favorite across sports, leagues, and teams,
/// grouped into collapsible sections, with a tap-to-unfavorite star on each
/// row. Themed to match the TV-guide look.
struct AllFavoritesView: View {
  @Environment(FavoritesStore.self) private var favorites

  private var favoriteSports: [Sport] {
    Sport.allCases.filter { favorites.isSportFavorite($0) }
  }
  private var favoriteLeagues: [SportLeague] {
    SportLeague.allCases.filter { $0 != .other && favorites.favoriteLeagues.contains($0) }
  }
  private var favoriteTeams: [String] {
    favorites.favoriteTeams.sorted()
  }

  var body: some View {
    List {
      if favoriteSports.isEmpty && favoriteLeagues.isEmpty && favoriteTeams.isEmpty {
        Section {
          Text("No favorites yet. Star sports, leagues, or teams to see them here.")
            .font(.subheadline)
            .foregroundStyle(GuideTheme.textDim)
            .listRowBackground(GuideTheme.panel)
        }
      }

      if !favoriteSports.isEmpty {
        Section {
          DisclosureGroup {
            ForEach(favoriteSports) { sport in
              HStack(spacing: 12) {
                ZStack {
                  Circle().fill(sport.accentColor.opacity(0.22)).frame(width: 34, height: 34)
                  Image(systemName: sport.sfSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(sport.accentColor)
                }
                Text(sport.displayName).foregroundStyle(GuideTheme.text)
                Spacer()
                starButton { favorites.toggleSport(sport) }
              }
              .padding(.vertical, 2)
              .listRowBackground(GuideTheme.panel)
            }
          } label: {
            sectionLabel("Sports", systemImage: "sportscourt.fill")
          }
          .listRowBackground(GuideTheme.panel)
        }
      }

      if !favoriteLeagues.isEmpty {
        Section {
          DisclosureGroup {
            ForEach(favoriteLeagues) { league in
              HStack(spacing: 12) {
                LeagueIcon(league: league, size: 34)
                Text(league.displayName).foregroundStyle(GuideTheme.text)
                Spacer()
                starButton { favorites.toggleLeague(league) }
              }
              .padding(.vertical, 2)
              .listRowBackground(GuideTheme.panel)
            }
          } label: {
            sectionLabel("Leagues", systemImage: "trophy.fill")
          }
          .listRowBackground(GuideTheme.panel)
        }
      }

      if !favoriteTeams.isEmpty {
        Section {
          DisclosureGroup {
            ForEach(favoriteTeams, id: \.self) { team in
              HStack(spacing: 12) {
                // Real crest when we can resolve the team's league; TeamLogo
                // falls back to a colored initials circle when no logo exists.
                TeamLogo(
                  teamName: team.capitalized,
                  league: FavoritesStore.league(forTeamNamed: team) ?? .other,
                  size: 34
                )
                Text(team.capitalized).foregroundStyle(GuideTheme.text)
                Spacer()
                starButton { favorites.toggleTeam(team) }
              }
              .padding(.vertical, 2)
              .listRowBackground(GuideTheme.panel)
            }
          } label: {
            sectionLabel("Teams", systemImage: "person.3.fill")
          }
          .listRowBackground(GuideTheme.panel)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(GuideTheme.background)
    .navigationTitle("All Favorites")
    .navigationBarTitleDisplayMode(.large)
  }

  private func sectionLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.accentColor)
        .frame(width: 32, height: 32)
        .overlay(
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
        )
      Text(title).font(.body.weight(.semibold)).foregroundStyle(GuideTheme.text)
    }
  }

  private func starButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "star.fill")
        .font(.system(size: 17))
        .foregroundStyle(.yellow)
        // Fixed width + trailing inset so every row's star lines up in the
        // same column, pulled slightly in from the edge.
        .frame(width: 28, alignment: .center)
        .padding(.trailing, 4)
    }
    .buttonStyle(.plain)
  }
}
