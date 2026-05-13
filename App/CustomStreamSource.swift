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
      let scheduledTime = parseTime(from: link.text)
      let liveStatus = parseLiveStatus(from: link.text)
      let isLive = liveStatus != nil || detectLive(text: link.text, scheduledTime: scheduledTime)
      return Game(
        id: link.href,
        homeTeam: home,
        awayTeam: away,
        scheduledTime: scheduledTime,
        isLive: isLive,
        liveStatus: liveStatus,
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

  private func parseLiveStatus(from text: String) -> String? {
    let period = detectPeriod(in: text.lowercased())
    let score  = detectScore(in: text)
    switch (score, period) {
    case let (s?, p?): return "\(s) • \(p)"
    case let (s?, nil): return s
    case let (nil, p?): return p
    case (nil, nil): return nil
    }
  }

  // Detects game period/state for any major sport from lowercased link text.
  // Uses regex for ordinal patterns (e.g. "8th Inning", "3rd Quarter") so it
  // handles any inning/quarter/period/round number without hard-coding each one.
  private func detectPeriod(in lower: String) -> String? {
    // Baseball: "Extra Innings" / "Extra Inning"
    if lower.contains("extra inn") { return "Extra Innings" }

    // Ordinal + sport keyword: captures "8th Inning", "Top 3rd", "3rd Quarter", "2nd Leg", etc.
    // Group 1: optional top/bottom prefix  Group 2: ordinal  Group 3: sport keyword
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

    // Q1/Q2/Q3/Q4 shorthand (e.g. "Q3")
    let qKW = #"\bq([1-4])\b"#
    if let regex = try? NSRegularExpression(pattern: qKW, options: .caseInsensitive),
       let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
       let r = Range(m.range(at: 1), in: lower) {
      let ordinals = ["1": "1st", "2": "2nd", "3": "3rd", "4": "4th"]
      return "\(ordinals[String(lower[r])] ?? String(lower[r])) Quarter"
    }

    // Static keywords (halftime, OT, etc.)
    let statics: [(String, String)] = [
      ("halftime", "Halftime"), ("half time", "Halftime"),
      ("extra time", "Extra Time"), ("overtime", "Overtime"),
      ("shootout", "Shootout"), ("tiebreak", "Tiebreak"),
      ("penalties", "Penalties"), ("in progress", "In Progress"),
    ]
    for (kw, label) in statics where lower.contains(kw) { return label }
    return nil
  }

  // Extracts a score like "3-1" from text; ignores time patterns (e.g. "8:00 PM").
  private func detectScore(in text: String) -> String? {
    let scorePattern = #"\b(\d{1,3})\s*[-:]\s*(\d{1,3})\b(?!\s*[AaPp][Mm])"#
    guard let regex = try? NSRegularExpression(pattern: scorePattern),
          let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r1 = Range(m.range(at: 1), in: text),
          let r2 = Range(m.range(at: 2), in: text) else { return nil }
    return "\(text[r1])-\(text[r2])"
  }

  private func detectLive(text: String, scheduledTime: Date?) -> Bool {
    let lower = text.lowercased()
    if lower.contains("live") { return true }
    // Time-based: game was scheduled within the last 4 hours
    if let t = scheduledTime {
      let diff = Date().timeIntervalSince(t)
      return diff >= -300 && diff < 14400
    }
    return false
  }

  // Extracts a time string like "8:00 PM", "02:30 AM ET" from link text and
  // resolves it to today's date in ET (matching how most US sports sites display times).
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

  private func scrapeLinks() async -> [ScrapedLink] {
    let scraper = await MainActor.run { WebViewScraper() }
    return await scraper.scrape(url: baseURL)
  }
}
