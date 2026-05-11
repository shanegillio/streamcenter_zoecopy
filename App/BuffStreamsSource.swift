import Foundation

struct BuffStreamsSource: StreamSource {
  let id = "buffstreams"
  let name = "BuffStreams"
  let baseURL = URL(string: "https://buffstreams.plus")!

  // Maps URL slug prefixes to leagues.
  // Order matters: longer/more-specific prefixes first so "premier-league" beats "p".
  // Any slug that starts with a key is mapped to that league, e.g. "nhl-playoffs" → .nhl.
  static let slugPrefixToLeague: [(prefix: String, league: SportLeague)] = [
    ("nba", .nba),
    ("nfl", .nfl),
    ("mlb", .mlb),
    ("nhl", .nhl),
    ("hockey", .nhl),
    ("ice-hockey", .nhl),
    ("ufc", .ufc),
    ("mma", .mma),
    ("boxing", .boxing),
    ("premier-league", .premierLeague),
    ("laliga", .laLiga),
    ("serie-a", .serieA),
    ("bundesliga", .bundesliga),
    ("soccer", .soccer),
    ("football", .soccer),
    ("f1", .f1),
    ("formula-1", .f1),
    ("cfb", .ncaaf),
    ("college-football", .ncaaf),
    ("ncaaf", .ncaaf),
    ("ncaab", .ncaab),
    ("ncaa", .ncaab),
    ("college-basketball", .ncaab),
    ("wnba", .wnba),
    ("wwe", .wwe),
    ("tennis", .tennis),
    ("golf", .golf),
    ("nascar", .nascar),
    ("title-game", .wwe), // catch-all for title events
  ]

  static func league(for slug: String) -> SportLeague? {
    let lower = slug.lowercased()
    for entry in slugPrefixToLeague {
      if lower == entry.prefix || lower.hasPrefix(entry.prefix + "-") {
        return entry.league
      }
    }
    return nil
  }

  // League-specific stream page slugs (e.g. /nbastreams2)
  static let leagueStreamSlug: [SportLeague: String] = [
    .nba: "nbastreams2",
    .nfl: "nflstreams2",
    .mlb: "mlbstreams2",
    .nhl: "nhlstreams2",
    .mma: "mmastreams2",
    .ufc: "ufcstreams2",
    .boxing: "boxingstreams2",
    .soccer: "soccerstreams2",
    .f1: "f1streams2",
    .ncaaf: "cfbstreams2",
    .ncaab: "ncaastreams2",
    .wnba: "wnbastreams2",
    .wwe: "wwestreams2",
    .tennis: "tennisstreams2",
    .golf: "golfstreams2",
    .nascar: "nascarstreams2",
    .premierLeague: "plstreams2",
    .laLiga: "laligatvstreams2",
    .serieA: "serieastreams2",
    .bundesliga: "bundesligastreams2",
  ]

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    let url = URL(string: "https://buffstreams.plus/index16")!
    let html = try await fetchHTML(from: url)
    return parseAvailableLeagues(from: html)
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    guard let slug = Self.leagueStreamSlug[league] else { return [] }
    let url = URL(string: "https://buffstreams.plus/\(slug)")!
    let html = try await fetchHTML(from: url)
    return parseGames(from: html, league: league)
  }

  // MARK: - HTML Fetching

  func fetchHTML(from url: URL) async throws -> String {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("https://buffstreams.plus", forHTTPHeaderField: "Referer")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    let (data, _) = try await URLSession.shared.data(for: request)
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
  }

  // MARK: - Parsing

  private func parseAvailableLeagues(from html: String) -> [SportLeague] {
    // Derive available leagues from the game links actually present on the page
    var found = Set<SportLeague>()
    let hrefPattern = #"href=['"][^'"]*?/([a-z0-9-]+)/[a-z0-9-]+/\d+['"']"#
    if let regex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive) {
      let range = NSRange(html.startIndex..., in: html)
      for match in regex.matches(in: html, range: range) {
        if let r = Range(match.range(at: 1), in: html) {
          let slug = String(html[r])
          if let league = Self.league(for: slug) { found.insert(league) }
        }
      }
    }
    return Array(found).sorted { $0.displayName < $1.displayName }
  }

  func parseGames(from html: String, league: SportLeague) -> [Game] {
    var games: [Game] = []
    var seen = Set<String>()

    // Capture full anchor tag including its inner HTML so nested <span> elements don't break the match.
    // .dotMatchesLineSeparators lets (.*?) span newlines inside the tag.
    let anchorPattern = #"<a\b[^>]*href=['"](?:https://buffstreams\.plus)?(/([a-z0-9-]+)/([a-z0-9-]+)/(\d+))['"][^>]*>(.*?)</a>"#
    guard let anchorRegex = try? NSRegularExpression(
      pattern: anchorPattern,
      options: [.caseInsensitive, .dotMatchesLineSeparators]
    ) else { return [] }
    let nsHTML = html as NSString
    let matches = anchorRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

    for match in matches {
      guard match.numberOfRanges >= 6 else { continue }
      guard
        let pathRange     = Range(match.range(at: 1), in: html),
        let sportRange    = Range(match.range(at: 2), in: html),
        let gameSlugRange = Range(match.range(at: 3), in: html),
        let gameIDRange   = Range(match.range(at: 4), in: html),
        let innerRange    = Range(match.range(at: 5), in: html)
      else { continue }

      let path      = String(html[pathRange])
      let sportSlug = String(html[sportRange]).lowercased()
      let gameSlug  = String(html[gameSlugRange])
      let gameID    = String(html[gameIDRange])

      // Strip any nested HTML tags to get plain text
      let linkText = String(html[innerRange])
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      guard !path.contains("streams2") else { continue }

      guard let mappedLeague = Self.league(for: sportSlug), mappedLeague == league else { continue }
      guard !seen.contains(gameID) else { continue }
      seen.insert(gameID)

      let (homeTeam, awayTeam, scheduledTime) = parseLinkText(linkText, gameSlug: gameSlug)
      let isLive = detectLive(linkText: linkText, scheduledTime: scheduledTime)

      let pageURLString = "https://buffstreams.plus\(path)"
      guard let pageURL = URL(string: pageURLString) else { continue }

      games.append(Game(
        id: gameID,
        homeTeam: homeTeam,
        awayTeam: awayTeam,
        scheduledTime: scheduledTime,
        isLive: isLive,
        pageURL: pageURL,
        league: league
      ))
    }

    return games.sorted { a, b in
      if a.isLive != b.isLive { return a.isLive }
      switch (a.scheduledTime, b.scheduledTime) {
      case let (at?, bt?): return at < bt
      case (.some, .none): return true
      case (.none, .some): return false
      case (.none, .none): return false
      }
    }
  }

  // MARK: - Helpers

  // Parses anchor text like "Cleveland Cavaliers 12:00 AM Detroit Pistons Live Streams"
  // or live text like "Carolina Hurricanes 4' Philadelphia Flyers Live Streams"
  private func parseLinkText(_ raw: String, gameSlug: String) -> (String, String, Date?) {
    let text = raw
      .replacingOccurrences(of: "Live Streams", with: "", options: .caseInsensitive)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Time pattern: "12:00 AM", "02:30 PM", optionally followed by timezone
    let timePattern = #"(\d{1,2}:\d{2}\s*[AaPp][Mm](?:\s*[A-Z]{2,3})?)"#
    if let timeRegex = try? NSRegularExpression(pattern: timePattern),
       let m = timeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let fullRange = Range(m.range, in: text),
       let capRange  = Range(m.range(at: 1), in: text) {
      let before = text[text.startIndex..<fullRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      let after  = text[fullRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      let timeStr = String(text[capRange])
      return (
        before.isEmpty ? teamNameFromSlug(gameSlug, isHome: true) : before,
        after.isEmpty  ? teamNameFromSlug(gameSlug, isHome: false) : after,
        parseETTime(timeStr)
      )
    }

    // Live game: "Carolina Hurricanes 4' Philadelphia Flyers" — no clock time
    let livePattern = #"^(.+?)\s+\d+['′]\s+(.+)$"#
    if let liveRegex = try? NSRegularExpression(pattern: livePattern),
       let m = liveRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       m.numberOfRanges >= 3,
       let r1 = Range(m.range(at: 1), in: text),
       let r2 = Range(m.range(at: 2), in: text) {
      return (String(text[r1]), String(text[r2]), nil)
    }

    let (home, away) = splitTeamsFromSlug(gameSlug)
    return (home, away, nil)
  }

  private func cleanTeamName(_ raw: String) -> String {
    raw.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
  }

  private func teamNameFromSlug(_ slug: String, isHome: Bool) -> String {
    let (home, away) = splitTeamsFromSlug(slug)
    return isHome ? home : away
  }

  private func splitTeamsFromSlug(_ slug: String) -> (String, String) {
    let words = slug.split(separator: "-").map { $0.capitalized }
    guard words.count >= 2 else { return (slug.capitalized, "TBD") }
    let mid = words.count / 2
    return (words[0..<mid].joined(separator: " "), words[mid...].joined(separator: " "))
  }

  private func detectLive(linkText: String, scheduledTime: Date?) -> Bool {
    // A minute-marker like "4'" means the game is in progress
    let liveMarker = #"\d+['′]"#
    if (try? NSRegularExpression(pattern: liveMarker))?.firstMatch(
        in: linkText, range: NSRange(linkText.startIndex..., in: linkText)) != nil {
      return true
    }
    if let t = scheduledTime {
      let diff = Date().timeIntervalSince(t)
      return diff >= -300 && diff < 14400
    }
    return false
  }

  private func parseETTime(_ raw: String) -> Date? {
    let cleaned = raw
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
      .uppercased()
      .replacingOccurrences(of: " ET", with: "")
      .replacingOccurrences(of: " EST", with: "")
      .replacingOccurrences(of: " EDT", with: "")

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/New_York")

    for format in ["h:mm A", "hh:mm A"] {
      formatter.dateFormat = format
      if let parsed = formatter.date(from: cleaned) {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents(in: TimeZone(identifier: "America/New_York")!, from: now)
        let timeComps = cal.dateComponents([.hour, .minute], from: parsed)
        comps.hour = timeComps.hour
        comps.minute = timeComps.minute
        comps.second = 0
        if let date = cal.date(from: comps) {
          return date
        }
      }
    }
    return nil
  }
}
