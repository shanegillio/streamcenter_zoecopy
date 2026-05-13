import Foundation

struct PPVToSource: StreamSource {
  let id = "ppvto"
  let name = "PPV.to"
  let baseURL = URL(string: "https://ppv.to")!

  private static let uriPrefixToLeague: [(String, SportLeague)] = [
    ("mlb/", .mlb),
    ("nba/", .nba),
    ("nhl/", .nhl),
    ("nfl/", .nfl),
    ("laliga/", .laLiga),
    ("premier-league/", .premierLeague),
    ("serie-a/", .serieA),
    ("bundesliga/", .bundesliga),
    ("ufc/", .ufc),
    ("wwe/", .wwe),
    ("boxing/", .boxing),
    ("f1/", .f1),
    ("ncaa/", .ncaab),
    ("ncaaf/", .ncaaf),
    ("wnba/", .wnba),
    ("nascar/", .nascar),
    ("tennis/", .tennis),
    ("golf/", .golf),
    ("soccer/", .soccer),
    ("mls/", .soccer),
  ]

  private static let categoryToLeague: [String: SportLeague] = [
    "baseball": .mlb,
    "basketball": .nba,
    "ice hockey": .nhl,
    "american football": .nfl,
    "football": .soccer,
    "wrestling": .wwe,
    "mma": .mma,
    "boxing": .boxing,
    "motor racing": .f1,
    "tennis": .tennis,
    "golf": .golf,
  ]

  static func league(for stream: PPVStream) -> SportLeague? {
    let lower = stream.uriName.lowercased()
    for (prefix, league) in uriPrefixToLeague where lower.hasPrefix(prefix) {
      return league
    }
    return categoryToLeague[stream.categoryName.lowercased()]
  }

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    let streams = try await fetchAllStreams()
    var found = Set<SportLeague>()
    for stream in streams {
      if let league = Self.league(for: stream) { found.insert(league) }
    }
    return Array(found).sorted { $0.displayName < $1.displayName }
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    let streams = try await fetchAllStreams()
    let now = Date().timeIntervalSince1970
    return streams.compactMap { stream -> Game? in
      guard Self.league(for: stream) == league else { return nil }
      guard let url = URL(string: stream.iframe) else { return nil }
      let parts = stream.name.components(separatedBy: " vs. ")
      let homeTeam = parts.first ?? stream.name
      let awayTeam = parts.count > 1 ? parts[1] : "TBD"
      let scheduledTime = stream.startsAt > 0 ? Date(timeIntervalSince1970: Double(stream.startsAt)) : nil
      let isLive = stream.startsAt > 0 && Double(stream.startsAt) <= now && now < Double(stream.endsAt)
      return Game(
        id: String(stream.id),
        homeTeam: homeTeam,
        awayTeam: awayTeam,
        scheduledTime: scheduledTime,
        isLive: isLive,
        liveStatus: nil,
        pageURL: url,
        league: league
      )
    }.sorted { a, b in
      if a.isLive != b.isLive { return a.isLive }
      switch (a.scheduledTime, b.scheduledTime) {
      case let (at?, bt?): return at < bt
      case (.some, .none): return true
      case (.none, .some): return false
      case (.none, .none): return false
      }
    }
  }

  private func fetchAllStreams() async throws -> [PPVStream] {
    let url = URL(string: "https://api.ppv.to/api/streams")!
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(PPVResponse.self, from: data)
    return response.streams.flatMap { $0.streams }
  }
}

// MARK: - Decodable models

private struct PPVResponse: Decodable {
  let streams: [PPVCategory]
}

private struct PPVCategory: Decodable {
  let streams: [PPVStream]
}

struct PPVStream: Decodable {
  let id: Int
  let name: String
  let uriName: String
  let startsAt: Int
  let endsAt: Int
  let categoryName: String
  let iframe: String

  enum CodingKeys: String, CodingKey {
    case id, name
    case uriName = "uri_name"
    case startsAt = "starts_at"
    case endsAt = "ends_at"
    case categoryName = "category_name"
    case iframe
  }
}
