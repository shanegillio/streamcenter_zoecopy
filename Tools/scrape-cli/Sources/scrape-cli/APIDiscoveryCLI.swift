import Foundation

/// Macos-side port of `App/APIDiscovery.swift` — same probe paths, same
/// shape parsers, no host-specific code. Used by `--api-only` mode to test
/// API discovery without booting the iOS app or building the iOS .ipa.
///
/// === KEEP IN SYNC WITH App/APIDiscovery.swift ===
/// When the iOS file's shape parsers or candidate paths change, update this
/// file to match. The two files are intentionally duplicated so the CLI can
/// run without depending on the iOS app's target.

struct DiscoveredGameCLI: Encodable {
  let externalID: String
  let categoryLabel: String
  let homeName: String
  let awayName: String
  let startsAt: Date?
  let endsAt: Date?
  let isLive: Bool
  let pageURL: String
}

enum APIDiscoveryCLI {
  static let candidatePaths: [String] = [
    "/api/streams", "/api/games", "/api/events", "/api/matches",
    "/api/sport", "/api/sports", "/api/category", "/api/categories",
    "/api/v1/streams", "/api/v1/games", "/api/v1/events", "/api/v1/matches",
    "/api/v2/streams", "/api/v2/games",
    "/api/live", "/streams.json", "/games.json", "/events.json",
  ]
  static let subdomainPrefixes = ["api", "data", "www"]
  static let perRequestTimeout: TimeInterval = 6

  struct Result: Encodable {
    let endpoint: String
    let probed: [ProbeAttempt]
    let games: [DiscoveredGameCLI]
  }

  struct ProbeAttempt: Encodable {
    let url: String
    let statusCode: Int?
    let contentType: String?
    let shapeMatched: String?
    let parsedCount: Int
  }

  static func discover(baseURL: URL) async -> Result {
    let candidates = buildCandidates(for: baseURL)
    var probed: [ProbeAttempt] = []
    var winner: (endpoint: URL, games: [DiscoveredGameCLI])? = nil

    // Sequential (not parallel) so the CLI output shows the probe order
    // chronologically — easier to read when debugging a new site.
    for url in candidates {
      let attempt = await probe(url)
      probed.append(attempt)
      if !attempt.shapeMatched.isNilOrEmpty, attempt.parsedCount > 0, winner == nil {
        // Re-fetch to get the games (probe drops them to keep memory low)
        if let games = await fetchAndDecode(url), !games.isEmpty {
          winner = (url, games)
          break
        }
      }
    }

    return Result(
      endpoint: winner?.endpoint.absoluteString ?? "",
      probed: probed,
      games: winner?.games ?? []
    )
  }

  private static func buildCandidates(for baseURL: URL) -> [URL] {
    var urls: [URL] = []
    var seen = Set<String>()
    let scheme = baseURL.scheme ?? "https"
    let host = baseURL.host ?? ""
    guard !host.isEmpty else { return [] }
    var hosts: [String] = [host]
    for prefix in subdomainPrefixes where !host.hasPrefix(prefix + ".") {
      hosts.append("\(prefix).\(host)")
    }
    for h in hosts {
      for path in candidatePaths {
        let s = "\(scheme)://\(h)\(path)"
        guard seen.insert(s).inserted, let u = URL(string: s) else { continue }
        urls.append(u)
      }
    }
    return urls
  }

  private static func probe(_ url: URL) async -> ProbeAttempt {
    var request = URLRequest(url: url, timeoutInterval: perRequestTimeout)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request) else {
      return ProbeAttempt(url: url.absoluteString, statusCode: nil, contentType: nil, shapeMatched: nil, parsedCount: 0)
    }
    let http = response as? HTTPURLResponse
    let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
    if http?.statusCode != 200 || !ct.lowercased().contains("json") {
      return ProbeAttempt(url: url.absoluteString, statusCode: http?.statusCode, contentType: ct, shapeMatched: nil, parsedCount: 0)
    }
    guard let raw = try? JSONSerialization.jsonObject(with: data) else {
      return ProbeAttempt(url: url.absoluteString, statusCode: 200, contentType: ct, shapeMatched: nil, parsedCount: 0)
    }
    for shape in shapes {
      if let games = shape.parse(raw, url), !games.isEmpty {
        return ProbeAttempt(url: url.absoluteString, statusCode: 200, contentType: ct, shapeMatched: shape.id, parsedCount: games.count)
      }
    }
    return ProbeAttempt(url: url.absoluteString, statusCode: 200, contentType: ct, shapeMatched: nil, parsedCount: 0)
  }

  private static func fetchAndDecode(_ url: URL) async -> [DiscoveredGameCLI]? {
    var request = URLRequest(url: url, timeoutInterval: perRequestTimeout)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
    guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
    for shape in shapes {
      if let games = shape.parse(raw, url), !games.isEmpty { return games }
    }
    return nil
  }

  // MARK: - Shape registry

  struct APIShapeCLI {
    let id: String
    let parse: (Any, URL) -> [DiscoveredGameCLI]?
  }

  static let shapes: [APIShapeCLI] = [
    .nestedCategories, .flatGames, .flatEvents, .flatMatches,
  ]
}

// Mirror of the shape parsers in App/APIDiscovery.swift.
extension APIDiscoveryCLI.APIShapeCLI {
  static let nestedCategories = APIDiscoveryCLI.APIShapeCLI(id: "nestedCategories") { raw, endpoint in
    guard let dict = raw as? [String: Any] else { return nil }
    guard let categories = (dict["streams"] as? [[String: Any]]) ?? (dict["categories"] as? [[String: Any]]) else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + (endpoint.host ?? "").replacingOccurrences(of: "api.", with: "")
    var games: [DiscoveredGameCLI] = []
    for cat in categories {
      let label = (cat["category"] as? String) ?? (cat["name"] as? String) ?? ""
      let streams = (cat["streams"] as? [[String: Any]]) ?? (cat["items"] as? [[String: Any]]) ?? []
      for s in streams {
        if let g = makeGame(from: s, category: label, host: host) { games.append(g) }
      }
    }
    return games
  }

  static let flatGames = APIDiscoveryCLI.APIShapeCLI(id: "flatGames") { raw, endpoint in
    guard let dict = raw as? [String: Any], let arr = dict["games"] as? [[String: Any]] else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + (endpoint.host ?? "").replacingOccurrences(of: "api.", with: "")
    return arr.compactMap { g in
      let cat = (g["league"] as? String) ?? (g["category"] as? String) ?? (g["competition"] as? String) ?? ""
      return makeGame(from: g, category: cat, host: host)
    }
  }

  static let flatEvents = APIDiscoveryCLI.APIShapeCLI(id: "flatEvents") { raw, endpoint in
    guard let dict = raw as? [String: Any], let arr = dict["events"] as? [[String: Any]] else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + (endpoint.host ?? "").replacingOccurrences(of: "api.", with: "")
    return arr.compactMap { e in
      let cat = (e["competition"] as? String) ?? (e["league"] as? String) ?? (e["category"] as? String) ?? ""
      return makeGame(from: e, category: cat, host: host)
    }
  }

  static let flatMatches = APIDiscoveryCLI.APIShapeCLI(id: "flatMatches") { raw, endpoint in
    guard let dict = raw as? [String: Any], let arr = dict["matches"] as? [[String: Any]] else { return nil }
    let host = (endpoint.scheme ?? "https") + "://" + (endpoint.host ?? "").replacingOccurrences(of: "api.", with: "")
    return arr.compactMap { m in
      let cat = (m["league"] as? String) ?? (m["competition"] as? String) ?? ""
      var d = m
      if let teams = m["teams"] as? [String], teams.count == 2 {
        d["home_team"] = teams[0]; d["away_team"] = teams[1]
      }
      return makeGame(from: d, category: cat, host: host)
    }
  }

  private static func makeGame(from raw: [String: Any], category: String, host: String) -> DiscoveredGameCLI? {
    let id: String
    if let s = raw["id"] as? String { id = s }
    else if let i = raw["id"] as? Int { id = String(i) }
    else { id = UUID().uuidString }

    var home = (raw["home_team"] as? String) ?? (raw["home"] as? String) ?? ""
    var away = (raw["away_team"] as? String) ?? (raw["away"] as? String) ?? ""
    var isEvent = false
    if home.isEmpty || away.isEmpty,
       let name = (raw["name"] as? String) ?? (raw["title"] as? String) {
      let (h, a, evt) = splitName(name)
      if home.isEmpty { home = h }
      if away.isEmpty { away = a }
      isEvent = evt
    }
    if home.isEmpty && away.isEmpty { return nil }

    let startsAt = anyDate(raw["starts_at"] ?? raw["start_time"] ?? raw["start"] ?? raw["date"] ?? raw["datetime"])
    let endsAt = anyDate(raw["ends_at"] ?? raw["end_time"] ?? raw["end"])
    let alwaysLive = (raw["always_live"] as? Int ?? 0) == 1
    let now = Date()
    let isLive: Bool
    if alwaysLive { isLive = true }
    else if let s = startsAt, let e = endsAt { isLive = now >= s && now < e }
    else if let s = startsAt { isLive = abs(now.timeIntervalSince(s)) < 4 * 3600 }
    else { isLive = false }

    let pageURL: String = {
      for key in ["page_url", "url", "stream_url", "link"] {
        if let s = raw[key] as? String { return s }
      }
      if let uri = raw["uri_name"] as? String { return "\(host)/live/\(uri)" }
      if let iframe = raw["iframe"] as? String { return iframe }
      return host
    }()

    return DiscoveredGameCLI(
      externalID: id,
      categoryLabel: category,
      homeName: home.trimmingCharacters(in: .whitespacesAndNewlines),
      awayName: isEvent ? "" : away.trimmingCharacters(in: .whitespacesAndNewlines),
      startsAt: startsAt, endsAt: endsAt, isLive: isLive, pageURL: pageURL
    )
  }

  private static func splitName(_ name: String) -> (String, String, Bool) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    for separator in [" vs. ", " vs ", " v. ", " v ", " @ "] {
      if let r = trimmed.range(of: separator, options: .caseInsensitive) {
        let h = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let a = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if !h.isEmpty, !a.isEmpty { return (h, a, false) }
      }
    }
    return (trimmed, "", true)
  }

  private static func anyDate(_ value: Any?) -> Date? {
    if let i = value as? Int { return Date(timeIntervalSince1970: TimeInterval(i)) }
    if let d = value as? Double { return Date(timeIntervalSince1970: d) }
    if let s = value as? String, !s.isEmpty {
      let iso = ISO8601DateFormatter()
      if let d = iso.date(from: s) { return d }
      let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let d = isoFrac.date(from: s) { return d }
      if let epoch = TimeInterval(s) { return Date(timeIntervalSince1970: epoch) }
    }
    return nil
  }
}

extension Optional where Wrapped == String {
  fileprivate var isNilOrEmpty: Bool { (self ?? "").isEmpty }
}
