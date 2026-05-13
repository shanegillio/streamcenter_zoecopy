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

  // Special event keywords that indicate a non-matchup listing (no "vs" expected)
  private static let eventKeywords = [
    "draft", "combine", "all-star", "all star", "pro bowl", "skills challenge",
    "showcase", "awards", "scouting", "super bowl", "superbowl", "nba finals",
    "world series", "stanley cup", "championship game", "title fight", "press conference",
    "weigh-in", "open practice",
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

  // MARK: - Public API

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    let links = await scrapeLinks()
    var found = Set<SportLeague>()
    // Permissive: detect leagues from any same-domain link so two-level sites
    // (like crackstreams) surface their sports even without game links on the home page.
    for link in links {
      guard let linkURL = URL(string: link.href), let linkHost = linkURL.host else { continue }
      let root = rootDomain(of: baseURL.host ?? "")
      guard linkHost == baseURL.host || linkHost.hasSuffix("." + root) || linkHost == root else { continue }
      if let league = Self.detectLeague(href: link.href, text: link.text) {
        found.insert(league)
      }
    }
    return Array(found).sorted { $0.displayName < $1.displayName }
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    let homeLinks = await scrapeLinks()

    // Try to find games directly on the home/base page (e.g. streameast.ga)
    var games = buildGames(from: homeLinks, for: league)

    // If nothing found, this is likely a two-level site (e.g. crackstreams.ms) where
    // the home page only lists league categories and games live on sub-pages.
    if games.isEmpty {
      games = await fetchGamesFromSubPages(for: league, homeLinks: homeLinks)
    }

    return games.sorted { a, b in
      if a.isLive != b.isLive { return a.isLive }
      switch (a.scheduledTime, b.scheduledTime) {
      case let (at?, bt?): return at < bt
      case (.some, .none): return true
      default: return false
      }
    }
  }

  // MARK: - Two-level scraping

  private func fetchGamesFromSubPages(for league: SportLeague, homeLinks: [ScrapedLink]) async -> [Game] {
    // Find category/section links for this league: same domain, 1 path segment, no "vs" in URL.
    var seenURLs = Set<String>()
    let sectionURLs: [URL] = homeLinks.compactMap { link in
      guard let url = URL(string: link.href), let host = url.host else { return nil }
      let root = rootDomain(of: baseURL.host ?? "")
      guard host == baseURL.host || host.hasSuffix("." + root) || host == root else { return nil }
      let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
      guard segments.count == 1,
            !url.path.lowercased().contains("-vs-"),
            Self.detectLeague(href: link.href, text: link.text) == league,
            seenURLs.insert(url.absoluteString).inserted else { return nil }
      return url
    }

    guard !sectionURLs.isEmpty else { return [] }

    var allGames: [Game] = []
    // Scrape up to 2 section pages to avoid excessive network requests
    for sectionURL in sectionURLs.prefix(2) {
      let subLinks = await scrapeLinks(url: sectionURL, timeout: 20)
      allGames.append(contentsOf: buildGames(from: subLinks, for: league))
    }
    return allGames
  }

  // MARK: - Game building

  private func buildGames(from links: [ScrapedLink], for league: SportLeague) -> [Game] {
    var seen = Set<String>()
    return links.compactMap { link -> Game? in
      let isMatch = isGameLink(link)
      let isEvt   = !isMatch && isEventLink(link)
      guard (isMatch || isEvt),
            Self.detectLeague(href: link.href, text: link.text) == league,
            let url = URL(string: link.href),
            !seen.contains(link.href) else { return nil }
      seen.insert(link.href)

      let (home, away): (String, String)
      if isEvt {
        home = cleanEventName(from: link.text)
        away = ""
      } else {
        (home, away) = parseTeams(from: link.text, href: link.href)
      }

      let scheduledTime = parseTime(from: link.text)
      let liveStatus = parseLiveStatus(domStatus: link.status, linkText: link.text)
      let isLive = liveStatus != nil || detectLive(text: link.text, domStatus: link.status, scheduledTime: scheduledTime)

      return Game(
        id: link.href,
        homeTeam: home,
        awayTeam: away,
        scheduledTime: scheduledTime,
        isLive: isLive,
        liveStatus: liveStatus,
        isEvent: isEvt,
        pageURL: url,
        league: league
      )
    }
  }

  // MARK: - Link classification

  private func isGameLink(_ link: ScrapedLink) -> Bool {
    guard passes(domainAndBlocklistCheck: link) else { return false }
    guard let linkURL = URL(string: link.href) else { return false }
    let segments = linkURL.pathComponents.filter { $0 != "/" }
    guard segments.count >= 2 else { return false }

    let path = linkURL.path.lowercased()
    let text = link.text.lowercased()
    let hasVsText    = text.contains(" vs ") || text.contains(" vs. ") || text.contains(" @ ") || text.contains(" v. ")
    let hasVsURL     = path.contains("-vs-") || path.contains("-vs.")
    let hasDOMStatus = !link.status.isEmpty && link.status.count < 60
    return hasVsText || hasVsURL || hasDOMStatus
  }

  private func isEventLink(_ link: ScrapedLink) -> Bool {
    guard passes(domainAndBlocklistCheck: link) else { return false }
    guard let linkURL = URL(string: link.href) else { return false }
    let segments = linkURL.pathComponents.filter { $0 != "/" }
    guard segments.count >= 2 else { return false }
    guard Self.detectLeague(href: link.href, text: link.text) != nil else { return false }
    let combined = (link.text + " " + link.href).lowercased()
    return Self.eventKeywords.contains(where: { combined.contains($0) })
  }

  // Shared domain + blocklist gate used by both isGameLink and isEventLink
  private func passes(domainAndBlocklistCheck link: ScrapedLink) -> Bool {
    guard let linkURL = URL(string: link.href), let linkHost = linkURL.host else { return false }
    let root = rootDomain(of: baseURL.host ?? "")
    guard linkHost == baseURL.host || linkHost.hasSuffix("." + root) || linkHost == root else { return false }
    let path = linkURL.path.lowercased()
    let pathBlocklist = ["/about", "/contact", "/login", "/register", "/signup", "/privacy", "/terms", "/faq", "/home"]
    guard !pathBlocklist.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
    let navSegments: Set<String> = ["schedule", "standings", "news", "stats", "category", "tag", "page", "index"]
    let lastSeg = linkURL.pathComponents.filter { $0 != "/" }.last?.lowercased() ?? ""
    return !navSegments.contains(lastSeg)
  }

  // MARK: - Parsing helpers

  private func rootDomain(of host: String) -> String {
    let parts = host.split(separator: ".")
    guard parts.count >= 2 else { return host }
    return parts.suffix(2).joined(separator: ".")
  }

  private func parseTeams(from text: String, href: String) -> (String, String) {
    let cleaned = text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    for separator in [" vs. ", " vs ", " @ ", " v. ", " v "] {
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
          awayPart = awayPart.replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
          let home = homePart.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
          let away = awayPart.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
          if !home.isEmpty && !away.isEmpty { return (home, away) }
        }
      }
    }

    return (cleaned.isEmpty ? "TBD" : cleaned, "TBD")
  }

  private func cleanEventName(from text: String) -> String {
    var name = text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Strip trailing noise like "Live Stream", "HD", "Watch Online"
    let noisePatterns = [#"\s+(live stream|live|hd|stream|free|watch online|watch|online)$"#]
    for pattern in noisePatterns {
      if let r = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
        name = String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return name.isEmpty ? "Special Event" : name
  }

  private func parseLiveStatus(domStatus: String, linkText: String) -> String? {
    if !domStatus.isEmpty {
      let domLower = domStatus.lowercased()
      let isNoise = domLower == "live" || domLower == "watch" || domLower.hasPrefix("http") || domStatus.count > 60
      if !isNoise {
        if let period = detectPeriod(in: domLower) {
          let score = detectScore(in: domStatus)
          return score.map { "\($0) • \(period)" } ?? period
        }
        return domStatus
      }
    }
    let period = detectPeriod(in: linkText.lowercased())
    let score  = detectScore(in: linkText)
    switch (score, period) {
    case let (s?, p?): return "\(s) • \(p)"
    case let (s?, nil): return s
    case let (nil, p?): return p
    case (nil, nil): return nil
    }
  }

  private func detectPeriod(in lower: String) -> String? {
    if lower.contains("extra inn") { return "Extra Innings" }

    let ordKW = #"((?:top|bot(?:tom)?)\s+)?(\d+(?:st|nd|rd|th))\s+(inning|inn|quarter|qtr|period|half|leg|set|round)"#
    if let regex = try? NSRegularExpression(pattern: ordKW, options: .caseInsensitive),
       let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
      let pre = m.range(at: 1).length > 0
        ? (Range(m.range(at: 1), in: lower).map { String(lower[$0]).trimmingCharacters(in: .whitespaces) } ?? "")
        : ""
      let ord = Range(m.range(at: 2), in: lower).map { String(lower[$0]) } ?? ""
      let kw  = Range(m.range(at: 3), in: lower).map { String(lower[$0]) } ?? ""
      switch kw {
      case "inning", "inn":
        if pre.hasPrefix("top") { return "Top \(ord) Inning" }
        if pre.hasPrefix("bot") { return "Bot \(ord) Inning" }
        return "\(ord) Inning"
      case "quarter", "qtr": return "\(ord) Quarter"
      case "period":         return "\(ord) Period"
      case "half":           return "\(ord) Half"
      case "leg":            return "\(ord) Leg"
      case "set":            return "\(ord) Set"
      case "round":          return "\(ord) Round"
      default: break
      }
    }

    let qKW = #"\bq([1-4])\b"#
    if let regex = try? NSRegularExpression(pattern: qKW, options: .caseInsensitive),
       let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
       let r = Range(m.range(at: 1), in: lower) {
      let ordinals = ["1": "1st", "2": "2nd", "3": "3rd", "4": "4th"]
      return "\(ordinals[String(lower[r])] ?? String(lower[r])) Quarter"
    }

    let statics: [(String, String)] = [
      ("halftime", "Halftime"), ("half time", "Halftime"),
      ("extra time", "Extra Time"), ("overtime", "Overtime"),
      ("shootout", "Shootout"), ("tiebreak", "Tiebreak"),
      ("penalties", "Penalties"), ("in progress", "In Progress"),
    ]
    for (kw, label) in statics where lower.contains(kw) { return label }
    return nil
  }

  private func detectScore(in text: String) -> String? {
    let scorePattern = #"\b(\d{1,3})\s*[-:]\s*(\d{1,3})\b(?!\s*[AaPp][Mm])"#
    guard let regex = try? NSRegularExpression(pattern: scorePattern),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r1 = Range(m.range(at: 1), in: text),
          let r2 = Range(m.range(at: 2), in: text) else { return nil }
    return "\(text[r1])-\(text[r2])"
  }

  private func detectLive(text: String, domStatus: String, scheduledTime: Date?) -> Bool {
    if !domStatus.isEmpty && !domStatus.lowercased().hasPrefix("http") { return true }
    let lower = text.lowercased()
    if lower.contains("live") { return true }
    if let t = scheduledTime {
      let diff = Date().timeIntervalSince(t)
      return diff >= -300 && diff < 14400
    }
    return false
  }

  private func parseTime(from text: String) -> Date? {
    let pattern = #"(\d{1,2}:\d{2}\s*[AaPp][Mm](?:\s*[A-Z]{2,3})?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }

    var raw = String(text[range])
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
      .uppercased()
    for tz in [" ET", " EST", " EDT", " GMT", " UTC", " PT", " CT", " MT"] {
      raw = raw.replacingOccurrences(of: tz, with: "")
    }

    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = etTZ

    for format in ["h:mm a", "hh:mm a"] {
      formatter.dateFormat = format
      guard let parsed = formatter.date(from: raw) else { continue }
      var comps = etCal.dateComponents([.year, .month, .day], from: Date())
      let t = etCal.dateComponents([.hour, .minute], from: parsed)
      comps.hour = t.hour; comps.minute = t.minute; comps.second = 0
      return etCal.date(from: comps)
    }
    return nil
  }

  private func scrapeLinks(url: URL? = nil, timeout: TimeInterval = 30) async -> [ScrapedLink] {
    let scraper = await MainActor.run { WebViewScraper() }
    return await scraper.scrape(url: url ?? baseURL, timeout: timeout)
  }
}
