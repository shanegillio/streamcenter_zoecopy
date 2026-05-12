import Foundation

struct CustomStreamSource: StreamSource {
  let name: String
  let baseURL: URL

  var id: String { baseURL.host ?? baseURL.absoluteString }

  private static let urlSegmentLeague: [(String, SportLeague)] = [
    ("premier-league", .premierLeague), ("laliga", .laLiga), ("la-liga", .laLiga),
    ("serie-a", .serieA), ("bundesliga", .bundesliga),
    ("nba", .nba), ("nfl", .nfl), ("mlb", .mlb), ("nhl", .nhl),
    ("ufc", .ufc), ("mma", .mma), ("boxing", .boxing),
    ("ncaaf", .ncaaf), ("college-football", .ncaaf),
    ("ncaab", .ncaab), ("college-basketball", .ncaab),
    ("wnba", .wnba), ("wwe", .wwe),
    ("f1", .f1), ("formula-1", .f1), ("formula1", .f1),
    ("tennis", .tennis), ("golf", .golf), ("nascar", .nascar),
    ("soccer", .soccer), ("football", .soccer),
  ]

  private static let textLeague: [(String, SportLeague)] = [
    ("premier league", .premierLeague), ("la liga", .laLiga),
    ("serie a", .serieA), ("bundesliga", .bundesliga),
    ("nba", .nba), ("nfl", .nfl), ("mlb", .mlb), ("nhl", .nhl),
    ("ufc", .ufc), ("mma", .mma), ("boxing", .boxing),
    ("ncaaf", .ncaaf), ("college football", .ncaaf),
    ("ncaab", .ncaab), ("college basketball", .ncaab),
    ("wnba", .wnba), ("wwe", .wwe), ("smackdown", .wwe),
    ("formula 1", .f1), ("grand prix", .f1),
    ("tennis", .tennis), ("golf", .golf), ("nascar", .nascar),
    ("soccer", .soccer),
  ]

  static func detectLeague(href: String, text: String) -> SportLeague? {
    if let url = URL(string: href) {
      let segments = url.pathComponents.map { $0.lowercased() }
      for (keyword, league) in urlSegmentLeague {
        if segments.contains(where: { $0 == keyword || $0.hasPrefix(keyword + "-") || $0.hasSuffix("-" + keyword) }) {
          return league
        }
      }
      let hrefLower = href.lowercased()
      for (keyword, league) in urlSegmentLeague where hrefLower.contains("/\(keyword)") {
        return league
      }
    }
    let textLower = text.lowercased()
    for (keyword, league) in textLeague where textLower.contains(keyword) {
      return league
    }
    return nil
  }

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    let links = await scrapeLinks()
    var found = Set<SportLeague>()
    for link in links {
      guard isGameLink(link) else { continue }
      if let league = Self.detectLeague(href: link.href, text: link.text) {
        found.insert(league)
      }
    }
    return Array(found).sorted { $0.displayName < $1.displayName }
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    let links = await scrapeLinks()
    var seen = Set<String>()
    return links.compactMap { link -> Game? in
      guard isGameLink(link),
            Self.detectLeague(href: link.href, text: link.text) == league,
            let url = URL(string: link.href),
            !seen.contains(link.href) else { return nil }
      seen.insert(link.href)
      let (home, away) = parseTeams(from: link.text, href: link.href)
      let textLower = link.text.lowercased()
      let isLive = textLower.contains("live") || textLower.contains("in progress")
      return Game(
        id: link.href,
        homeTeam: home,
        awayTeam: away,
        scheduledTime: nil,
        isLive: isLive,
        pageURL: url,
        league: league
      )
    }
  }

  // MARK: - Helpers

  private func isGameLink(_ link: ScrapedLink) -> Bool {
    guard let linkURL = URL(string: link.href), let linkHost = linkURL.host else { return false }

    // Must be same root domain
    let root = rootDomain(of: baseURL.host ?? "")
    guard linkHost == baseURL.host || linkHost.hasSuffix("." + root) || linkHost == root else { return false }

    // Reject utility pages
    let path = linkURL.path.lowercased()
    let blocklist = ["/about", "/contact", "/login", "/register", "/signup", "/privacy", "/terms", "/faq", "/schedule", "/home"]
    guard !blocklist.contains(where: { path.hasPrefix($0) }) else { return false }

    // Must look like a matchup — check link text AND URL slug
    let text = link.text.lowercased()
    let hasVsText = text.contains(" vs ") || text.contains(" vs. ") || text.contains(" @ ")
    let hasVsURL  = path.contains("-vs-") || path.contains("-vs.")
    guard hasVsText || hasVsURL else { return false }

    // Must resolve to a specific game (not a category page) — path should have ≥ 2 segments
    let segments = linkURL.pathComponents.filter { $0 != "/" }
    return segments.count >= 2
  }

  private func rootDomain(of host: String) -> String {
    let parts = host.split(separator: ".")
    guard parts.count >= 2 else { return host }
    return parts.suffix(2).joined(separator: ".")
  }

  // Parses teams from link text first; falls back to URL slug if text is uninformative.
  private func parseTeams(from text: String, href: String) -> (String, String) {
    let cleaned = text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    for separator in [" vs. ", " vs ", " @ "] {
      guard let range = cleaned.range(of: separator, options: .caseInsensitive) else { continue }
      let home = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      var away = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      let noisePatterns = [#"\s+\d{1,2}:\d{2}"#, #"\s+LIVE\b"#, #"\s+HD\b"#, #"\s+\|"#]
      for pattern in noisePatterns {
        if let r = away.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
          away = String(away[..<r.lowerBound])
        }
      }
      away = away.trimmingCharacters(in: .whitespacesAndNewlines)
      if !home.isEmpty && !away.isEmpty { return (home, away) }
    }

    // Fall back to URL slug: /nba/detroit-pistons-vs-cleveland-cavaliers-3/
    if let url = URL(string: href) {
      let slug = url.pathComponents.last(where: { $0.contains("-vs-") }) ?? ""
      for sep in ["-vs-", "-vs."] {
        if let r = slug.range(of: sep, options: .caseInsensitive) {
          let homePart = String(slug[..<r.lowerBound])
          var awayPart = String(slug[r.upperBound...])
          // strip trailing "-N" (stream number suffix)
          awayPart = awayPart.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
          let home = homePart.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
          let away = awayPart.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
          if !home.isEmpty && !away.isEmpty { return (home, away) }
        }
      }
    }

    return (cleaned.isEmpty ? "TBD" : cleaned, "TBD")
  }

  private func scrapeLinks() async -> [ScrapedLink] {
    let scraper = await MainActor.run { WebViewScraper() }
    return await scraper.scrape(url: baseURL)
  }
}
