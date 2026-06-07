import Foundation

/// Learns a source's URL template by reading its homepage once and watching
/// how it links to today's known games.
///
/// Run automatically when a source is added. The idea: the homepage already
/// links to dozens of games we have canonical data for (from ESPN via
/// `ScheduleAggregator`). If we can recognize even one of those links, we can
/// reverse-engineer the path shape — `/live/mlb/2026-06-07/bos-nyy` becomes
/// `/live/{league}/{date}/{away}-{home}` — and reproduce it for any game. A
/// learned template lets `GameURLResolver` jump straight to the right page
/// instead of loading the homepage and walking the DOM (which is where the
/// wrong-game bug lived). When probing can't confidently learn a shape, it
/// returns nil and the source keeps using the walk.
enum SourceProbe {
  /// Candidate date encodings tried when recognizing a date path segment.
  private static let dateFormats = ["yyyy-MM-dd", "yyyyMMdd", "MM-dd-yyyy", "dd-MM-yyyy", "yyyy_MM_dd"]

  /// Probes `root` and returns a verified template, or nil to keep the walk.
  static func probe(root: URL) async -> SourceTemplate? {
    let games = await ScheduleAggregator.shared.todaysGames()
    guard !games.isEmpty else { return nil }
    let links = await scrape(root)
    guard !links.isEmpty else { return nil }

    let host = root.host?.lowercased()
    // Same-host deep-link paths, used both for matching and verification.
    var linkPaths = Set<String>()
    var pathByLink: [(path: String, normalized: String)] = []
    for link in links {
      guard let abs = URL(string: link.href, relativeTo: root)?.absoluteURL,
            abs.host?.lowercased() == host else { continue }
      let path = abs.path
      guard path.count > 1 else { continue }
      linkPaths.insert(path.lowercased())
      pathByLink.append((path, " " + HomeView.normalizeForMatch(path) + " "))
    }
    guard !pathByLink.isEmpty else { return nil }

    let index = TeamAliasIndex.shared

    // Derive a template from every (game, matching deep-link) pair we can find.
    var derived: [SourceTemplate] = []
    for entry in pathByLink {
      for game in games where index.hasTokens(forTeam: game.homeTeam) {
        let solo = game.awayTeam.isEmpty
        guard index.matches(team: game.homeTeam, inPadded: entry.normalized),
              solo || index.matches(team: game.awayTeam, inPadded: entry.normalized)
        else { continue }
        if let template = derive(path: entry.path, game: game) {
          derived.append(template)
        }
        break  // one game per link is enough
      }
    }
    guard !derived.isEmpty else { return nil }

    // Most-supported pattern wins.
    var tally: [String: (template: SourceTemplate, count: Int)] = [:]
    for t in derived {
      let key = "\(t.pathPattern)|\(t.teamStyle.rawValue)|\(t.dateFormat)"
      tally[key, default: (t, 0)].count += 1
    }
    guard var best = tally.values.max(by: { $0.count < $1.count })?.template else { return nil }

    // Verify: the template must regenerate at least one real homepage link.
    var verifiedCount = 0
    for game in games {
      if let url = best.url(for: game, root: root),
         linkPaths.contains(url.path.lowercased()) {
        verifiedCount += 1
      }
    }
    guard verifiedCount >= 1 else { return nil }
    best.verified = true
    return best
  }

  // MARK: - Template derivation

  /// Turns one concrete game path into a placeholder template, or nil when
  /// the teams aren't literally present in the path (so it can't be reused).
  private static func derive(path: String, game: Game) -> SourceTemplate? {
    let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !comps.isEmpty else { return nil }

    let leagueKey = SourceTemplate.leagueKey(game.league)
    let homeAbbr = TeamAliasIndex.shared.primaryAbbreviation(forTeam: game.homeTeam)
    let awayAbbr = game.awayTeam.isEmpty ? nil : TeamAliasIndex.shared.primaryAbbreviation(forTeam: game.awayTeam)
    let homeSlug = TeamAliasIndex.shared.slug(forTeam: game.homeTeam)
    let awaySlug = game.awayTeam.isEmpty ? "" : TeamAliasIndex.shared.slug(forTeam: game.awayTeam)
    let solo = game.awayTeam.isEmpty

    var out: [String] = []
    var dateFormat = ""
    var teamStyle: SourceTemplate.TeamStyle? = nil
    var placedHome = false, placedAway = false

    for raw in comps {
      let seg = raw.lowercased()
      // Date?
      if dateFormat.isEmpty, let time = game.scheduledTime,
         let fmt = dateFormatMatching(segment: seg, date: time) {
        dateFormat = fmt
        out.append("{date}")
        continue
      }
      // League?
      if let key = leagueKey, seg == key || seg == game.league.rawValue.lowercased() {
        out.append("{league}")
        continue
      }
      // Teams?
      if let teamized = teamize(
        segment: seg, homeAbbr: homeAbbr, awayAbbr: awayAbbr,
        homeSlug: homeSlug, awaySlug: awaySlug,
        teamStyle: &teamStyle, placedHome: &placedHome, placedAway: &placedAway
      ) {
        out.append(teamized)
        continue
      }
      out.append(raw)  // literal segment, original case preserved
    }

    guard placedHome, solo || placedAway, let style = teamStyle else { return nil }
    var pattern = "/" + out.joined(separator: "/")
    if path.hasSuffix("/"), !pattern.hasSuffix("/") { pattern += "/" }
    return SourceTemplate(pathPattern: pattern, dateFormat: dateFormat, teamStyle: style, verified: false)
  }

  /// Replaces team encodings inside one path segment with `{home}`/`{away}`,
  /// recording the style used. Returns nil when the segment names no team.
  private static func teamize(
    segment seg: String,
    homeAbbr: String?, awayAbbr: String?,
    homeSlug: String, awaySlug: String,
    teamStyle: inout SourceTemplate.TeamStyle?,
    placedHome: inout Bool, placedAway: inout Bool
  ) -> String? {
    // Abbreviation, combined ("away-home" or "home-away").
    if let ha = homeAbbr, let aa = awayAbbr, ha != aa {
      if seg == "\(aa)-\(ha)" {
        teamStyle = .abbreviation; placedAway = true; placedHome = true; return "{away}-{home}"
      }
      if seg == "\(ha)-\(aa)" {
        teamStyle = .abbreviation; placedHome = true; placedAway = true; return "{home}-{away}"
      }
    }
    // Abbreviation, standalone segment.
    if let aa = awayAbbr, seg == aa { teamStyle = .abbreviation; placedAway = true; return "{away}" }
    if let ha = homeAbbr, seg == ha { teamStyle = .abbreviation; placedHome = true; return "{home}" }
    // Full-name slug, possibly two slugs in one segment ("home-vs-away").
    if !homeSlug.isEmpty || !awaySlug.isEmpty {
      var s = seg
      var hit = false
      if !awaySlug.isEmpty, s.contains(awaySlug) {
        s = s.replacingOccurrences(of: awaySlug, with: "{away}"); placedAway = true; hit = true
      }
      if !homeSlug.isEmpty, s.contains(homeSlug) {
        s = s.replacingOccurrences(of: homeSlug, with: "{home}"); placedHome = true; hit = true
      }
      if hit { teamStyle = .slug; return s }
    }
    return nil
  }

  private static func dateFormatMatching(segment: String, date: Date) -> String? {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/New_York")
    for f in dateFormats {
      fmt.dateFormat = f
      if fmt.string(from: date).lowercased() == segment { return f }
    }
    return nil
  }

  // MARK: - Scraping

  /// Renders the homepage and returns its anchors, recovering from a dead
  /// host via the same HostFallback the rest of the app uses.
  private static func scrape(_ url: URL, timeout: TimeInterval = 15) async -> [ScrapedLink] {
    let scraper = await MainActor.run { WebViewScraper() }
    let result = await scraper.scrapeWithDiagnostic(url: url, timeout: timeout)
    if !result.links.isEmpty { return result.links }
    if let fallback = await HostFallback.shared.tryVariants(of: url) {
      let scraper2 = await MainActor.run { WebViewScraper() }
      return await scraper2.scrapeWithDiagnostic(url: fallback, timeout: timeout).links
    }
    return result.links
  }
}
