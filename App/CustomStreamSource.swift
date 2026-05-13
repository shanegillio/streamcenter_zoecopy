import Foundation

// Short-lived cache (60 s TTL) so fetchAvailableLeagues and fetchGames reuse
// the same scraped pages without re-fetching within the same session.
private actor ScrapeCache {
  static let shared = ScrapeCache()
  private var store: [URL: (links: [ScrapedLink], expiry: Date)] = [:]

  func get(_ url: URL) -> [ScrapedLink]? {
    guard let entry = store[url], Date() < entry.expiry else { return nil }
    return entry.links
  }

  func set(_ links: [ScrapedLink], for url: URL) {
    store[url] = (links, Date().addingTimeInterval(60))
  }
}

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

  private static let eventKeywords = [
    "draft", "combine", "all-star", "all star", "pro bowl", "skills challenge",
    "showcase", "awards", "scouting", "super bowl", "superbowl", "nba finals",
    "world series", "stanley cup", "championship game", "title fight",
    "press conference", "weigh-in", "open practice",
  ]

  // MARK: - League detection

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

  /// Returns only leagues that have verifiable game listings.
  /// For one-level sites (games on the home page) this is instant.
  /// For two-level sites (crackstreams-style) it scrapes each league
  /// sub-page in parallel to confirm game content exists.
  func fetchAvailableLeagues() async throws -> [SportLeague] {
    let homeLinks = await scrapeLinks()

    // One-level sites: games appear directly on the home page
    var directLeagues = Set<SportLeague>()
    for link in homeLinks where isGameLink(link) || isEventLink(link) {
      if let league = Self.detectLeague(href: link.href, text: link.text) {
        directLeagues.insert(league)
      }
    }
    if !directLeagues.isEmpty {
      return Array(directLeagues).sorted { $0.displayName < $1.displayName }
    }

    // Two-level sites: find the best section link for each candidate league,
    // then verify in parallel that each section page actually has game listings.
    var sectionByLeague = [SportLeague: URL]()
    for link in homeLinks {
      guard !isGameLink(link), !isEventLink(link),
            let url = URL(string: link.href),
            isSameDomain(url),
            let league = Self.detectLeague(href: link.href, text: link.text),
            sectionByLeague[league] == nil else { continue }
      let segs = url.pathComponents.filter { $0 != "/" }
      guard segs.count >= 1, segs.count <= 3 else { continue }
      sectionByLeague[league] = url
    }

    guard !sectionByLeague.isEmpty else { return [] }

    // Run verification in parallel batches of 5 to keep memory reasonable
    let candidates = Array(sectionByLeague)
    var verified = Set<SportLeague>()
    for batchStart in stride(from: 0, to: candidates.count, by: 5) {
      let batch = Array(candidates[batchStart ..< min(batchStart + 5, candidates.count)])
      await withTaskGroup(of: SportLeague?.self) { group in
        for (league, url) in batch {
          group.addTask {
            let sub = await self.scrapeLinks(url: url, timeout: 20)
            return sub.contains { self.isGameLink($0) || self.isEventLink($0) } ? league : nil
          }
        }
        for await result in group { if let l = result { verified.insert(l) } }
      }
    }

    return Array(verified).sorted { $0.displayName < $1.displayName }
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    let homeLinks = await scrapeLinks()

    // One-level: games on the home page
    var games = buildGames(from: homeLinks, for: league, requireLeagueDetection: true)

    // Two-level: follow the league's section page
    if games.isEmpty {
      let sectionURLs = findSectionURLs(for: league, in: homeLinks)
      for url in sectionURLs.prefix(2) {
        let subLinks = await scrapeLinks(url: url, timeout: 20)
        // Don't filter by detectLeague here — game URLs like /stream/... have
        // no sport keyword, but we know we're on the right league's page.
        games.append(contentsOf: buildGames(from: subLinks, for: league, requireLeagueDetection: false))
      }
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

  // MARK: - Internal helpers

  private func findSectionURLs(for league: SportLeague, in homeLinks: [ScrapedLink]) -> [URL] {
    var seen = Set<String>()
    return homeLinks.compactMap { link -> URL? in
      guard !isGameLink(link), !isEventLink(link),
            let url = URL(string: link.href),
            isSameDomain(url),
            let detected = Self.detectLeague(href: link.href, text: link.text),
            detected == league else { return nil }
      let segs = url.pathComponents.filter { $0 != "/" }
      guard segs.count >= 1, segs.count <= 3,
            seen.insert(url.absoluteString).inserted else { return nil }
      return url
    }
  }

  private func buildGames(from links: [ScrapedLink], for league: SportLeague, requireLeagueDetection: Bool) -> [Game] {
    var seen = Set<String>()
    return links.compactMap { link -> Game? in
      let isMatch = isGameLink(link)
      let isEvt   = !isMatch && isEventLink(link)
      guard isMatch || isEvt,
            let url = URL(string: link.href),
            isSameDomain(url),
            !seen.contains(link.href) else { return nil }

      // When scraping a sub-page we already know the league — skip detectLeague.
      if requireLeagueDetection {
        guard Self.detectLeague(href: link.href, text: link.text) == league else { return nil }
      }

      seen.insert(link.href)

      let home: String
      let away: String
      if isEvt {
        home = cleanEventName(from: link.text)
        away = ""
      } else {
        (home, away) = parseTeams(from: link.text, href: link.href)
      }

      let scheduledTime = parseTime(from: link.text)
      // detectLive is the single source of truth — parseLiveStatus only produces the
      // display string and must NOT be used to infer live state, since it can return
      // non-nil for non-live content (e.g. a time string scraped from a status element).
      let isLive     = detectLive(text: link.text, domStatus: link.status, scheduledTime: scheduledTime)
      let liveStatus = isLive ? parseLiveStatus(domStatus: link.status, linkText: link.text) : nil

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

  private func isSameDomain(_ url: URL) -> Bool {
    guard let host = url.host else { return false }
    let root = rootDomain(of: baseURL.host ?? "")
    return host == baseURL.host || host.hasSuffix("." + root) || host == root
  }

  private func passes(domainAndBlocklistCheck link: ScrapedLink) -> Bool {
    guard let url = URL(string: link.href), isSameDomain(url) else { return false }
    let path = url.path.lowercased()
    let pathBlocklist = ["/about", "/contact", "/login", "/register", "/signup", "/privacy", "/terms", "/faq", "/home"]
    guard !pathBlocklist.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
    let navSegments: Set<String> = ["schedule", "standings", "news", "stats", "category", "tag", "page", "index"]
    let lastSeg = url.pathComponents.filter { $0 != "/" }.last?.lowercased() ?? ""
    return !navSegments.contains(lastSeg)
  }

  private func isGameLink(_ link: ScrapedLink) -> Bool {
    guard passes(domainAndBlocklistCheck: link),
          let url = URL(string: link.href) else { return false }
    let segs = url.pathComponents.filter { $0 != "/" }
    guard segs.count >= 2 else { return false }
    let path = url.path.lowercased()
    let text = link.text.lowercased()
    let hasVsText    = text.contains(" vs ") || text.contains(" vs. ") || text.contains(" @ ") || text.contains(" v. ")
    let hasVsURL     = path.contains("-vs-") || path.contains("-vs.")
    let hasDOMStatus = !link.status.isEmpty && link.status.count < 60
    return hasVsText || hasVsURL || hasDOMStatus
  }

  private func isEventLink(_ link: ScrapedLink) -> Bool {
    guard passes(domainAndBlocklistCheck: link),
          let url = URL(string: link.href),
          url.pathComponents.filter({ $0 != "/" }).count >= 2,
          Self.detectLeague(href: link.href, text: link.text) != nil else { return false }
    let combined = (link.text + " " + link.href).lowercased()
    return Self.eventKeywords.contains(where: { combined.contains($0) })
  }

  // MARK: - Parsing

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
      for pattern in [#"\s+\d{1,2}:\d{2}"#, #"\s+LIVE\b"#, #"\s+HD\b"#, #"\s+\|"#] {
        if let r = away.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
          away = String(away[..<r.lowerBound])
        }
      }
      away = away.trimmingCharacters(in: .whitespacesAndNewlines)
      if !home.isEmpty && !away.isEmpty { return (home, away) }
    }

    // Fall back to URL slug
    if let url = URL(string: href),
       let slug = url.pathComponents.last(where: { $0.contains("-vs-") }) {
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
    for pattern in [#"\s+(live stream|live|hd|stream|free|watch online|watch|online)$"#] {
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
          return detectScore(in: domStatus).map { "\($0) • \(period)" } ?? period
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
    let pattern = #"\b(\d{1,3})\s*[-:]\s*(\d{1,3})\b(?!\s*[AaPp][Mm])"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r1 = Range(m.range(at: 1), in: text),
          let r2 = Range(m.range(at: 2), in: text) else { return nil }
    return "\(text[r1])-\(text[r2])"
  }

  private func detectLive(text: String, domStatus: String, scheduledTime: Date?) -> Bool {
    // Only treat domStatus as a live signal when it actually looks like an active game
    // state. A non-empty domStatus alone is NOT sufficient — a time string like
    // "7:05 PM" or "Tomorrow" would otherwise mark every upcoming game as live.
    if !domStatus.isEmpty {
      let s = domStatus.lowercased()
      let isLiveState = s.contains("live") || s.contains("progress") ||
                        detectPeriod(in: s) != nil || detectScore(in: domStatus) != nil
      if isLiveState { return true }
    }
    let lower = text.lowercased()
    if lower.contains("live") || lower.contains("in progress") { return true }
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
      .trimmingCharacters(in: .whitespaces).uppercased()
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
    let target = url ?? baseURL
    if let cached = await ScrapeCache.shared.get(target) { return cached }
    let scraper = await MainActor.run { WebViewScraper() }
    let links = await scraper.scrape(url: target, timeout: timeout)
    await ScrapeCache.shared.set(links, for: target)
    return links
  }
}
