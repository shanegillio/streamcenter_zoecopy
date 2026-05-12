import Foundation

struct CustomStreamSource: StreamSource {
  let name: String
  let baseURL: URL

  var id: String { baseURL.host ?? baseURL.absoluteString }

  // Ordered from most-specific to least-specific so a path like /premier-league/
  // beats a later /football/ match.
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
    let hrefLower = href.lowercased()
    // Split the URL path into segments and check each one
    if let url = URL(string: href) {
      let segments = url.pathComponents.map { $0.lowercased() }
      for (keyword, league) in urlSegmentLeague {
        if segments.contains(where: { $0 == keyword || $0.hasPrefix(keyword + "-") || $0.hasSuffix("-" + keyword) }) {
          return league
        }
      }
      // Also check the full path string for compound patterns
      for (keyword, league) in urlSegmentLeague where hrefLower.contains("/\(keyword)") {
        return league
      }
    }
    // Fall back to text keywords
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
      let (home, away) = parseTeams(from: link.text)
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
    let text = link.text.lowercased()
    guard text.contains(" vs ") || text.contains(" vs. ") || text.contains(" @ ") else { return false }
    guard let linkURL = URL(string: link.href), let linkHost = linkURL.host else { return false }
    // Accept same host OR any subdomain of the same root domain
    // e.g. base=v2.streameast.ga should accept links from streameast.ga or www.streameast.ga
    let rootDomain = rootDomain(of: baseURL.host ?? "")
    guard linkHost == baseURL.host || linkHost.hasSuffix("." + rootDomain) || linkHost == rootDomain else { return false }
    // Reject nav/utility paths
    let path = linkURL.path.lowercased()
    let blocklist = ["/about", "/contact", "/login", "/register", "/signup", "/privacy", "/terms", "/faq"]
    return !blocklist.contains(where: { path.hasPrefix($0) })
  }

  private func rootDomain(of host: String) -> String {
    let parts = host.split(separator: ".")
    guard parts.count >= 2 else { return host }
    return parts.suffix(2).joined(separator: ".")
  }

  private func parseTeams(from text: String) -> (String, String) {
    let cleaned = text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    for separator in [" vs. ", " vs ", " @ "] {
      guard let range = cleaned.range(of: separator, options: .caseInsensitive) else { continue }
      let home = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      var away = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      // Strip trailing noise: time, "LIVE", channel name after first meaningful break
      let noisePatterns = [#"\s+\d{1,2}:\d{2}"#, #"\s+LIVE\b"#, #"\s+HD\b"#, #"\s+\|"#]
      for pattern in noisePatterns {
        if let r = away.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
          away = String(away[..<r.lowerBound])
        }
      }
      away = away.trimmingCharacters(in: .whitespacesAndNewlines)
      if !home.isEmpty && !away.isEmpty { return (home, away) }
    }
    return (cleaned, "TBD")
  }

  private func scrapeLinks() async -> [ScrapedLink] {
    let scraper = await MainActor.run { WebViewScraper() }
    return await scraper.scrape(url: baseURL)
  }
}
