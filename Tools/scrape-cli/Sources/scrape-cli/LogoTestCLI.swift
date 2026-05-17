import Foundation

/// CLI counterpart of `App/TeamLogoService.swift` + image-fetch timing.
/// Mirrors the static keyword tables so we can test logo resolution and
/// fetch latency for any team without rebuilding the iOS app.
///
/// === KEEP IN SYNC WITH App/TeamLogoService.swift ===

enum LogoTestCLI {
  struct Result: Encodable {
    let team: String
    let league: String
    let resolved: Bool
    let url: String?
    let resolveMs: Int
    let fetchMs: Int?
    let bytes: Int?
    let httpStatus: Int?
    let cacheControl: String?
    let etag: String?
    let error: String?
  }

  static func run(team: String, league: String) async -> Result {
    let resolveStart = Date()
    // Full resolution stack: static table → ESPN search API fallback.
    // Mirrors App/TeamLogoCache.swift's behaviour so CLI timings match
    // what the iOS app would experience.
    var urlString = resolveLogoURL(team: team, league: league.lowercased())
    if urlString == nil {
      urlString = await espnSearchForLogo(team: team, league: league.lowercased())
    }
    let resolveMs = Int(Date().timeIntervalSince(resolveStart) * 1000)

    guard let urlString, let url = URL(string: urlString) else {
      return Result(team: team, league: league, resolved: false, url: nil,
                    resolveMs: resolveMs, fetchMs: nil, bytes: nil,
                    httpStatus: nil, cacheControl: nil, etag: nil,
                    error: "no match in static table or ESPN search")
    }

    var request = URLRequest(url: url, timeoutInterval: 10)
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
    let fetchStart = Date()
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
      let http = response as? HTTPURLResponse
      return Result(
        team: team, league: league, resolved: true, url: urlString,
        resolveMs: resolveMs, fetchMs: fetchMs, bytes: data.count,
        httpStatus: http?.statusCode,
        cacheControl: http?.value(forHTTPHeaderField: "Cache-Control"),
        etag: http?.value(forHTTPHeaderField: "ETag"),
        error: nil
      )
    } catch {
      let fetchMs = Int(Date().timeIntervalSince(fetchStart) * 1000)
      return Result(
        team: team, league: league, resolved: true, url: urlString,
        resolveMs: resolveMs, fetchMs: fetchMs, bytes: nil,
        httpStatus: nil, cacheControl: nil, etag: nil,
        error: error.localizedDescription
      )
    }
  }

  // MARK: - Tables (mirror of App/TeamLogoService.swift)

  private static let nba: [String: String] = [
    "hawks": "atl", "celtics": "bos", "nets": "bkn", "hornets": "cha",
    "bulls": "chi", "cavaliers": "cle", "mavericks": "dal", "nuggets": "den",
    "pistons": "det", "warriors": "gs", "rockets": "hou", "pacers": "ind",
    "clippers": "lac", "lakers": "lal", "grizzlies": "mem", "heat": "mia",
    "bucks": "mil", "timberwolves": "min", "pelicans": "no", "knicks": "ny",
    "thunder": "okc", "magic": "orl", "76ers": "phi", "sixers": "phi",
    "suns": "phx", "blazers": "por", "kings": "sac", "spurs": "sa",
    "raptors": "tor", "jazz": "utah", "wizards": "wsh",
  ]
  private static let wnba: [String: String] = [
    "dream": "atl", "sky": "chi", "sun": "conn", "wings": "dal",
    "fever": "ind", "aces": "lv", "sparks": "la", "lynx": "min",
    "liberty": "ny", "mercury": "phx", "storm": "sea", "mystics": "wsh",
    "valkyries": "gs",
  ]
  private static let nfl: [String: String] = [
    "cardinals": "ari", "falcons": "atl", "ravens": "bal", "bills": "buf",
    "panthers": "car", "bears": "chi", "bengals": "cin", "browns": "cle",
    "cowboys": "dal", "broncos": "den", "lions": "det", "packers": "gb",
    "texans": "hou", "colts": "ind", "jaguars": "jax", "chiefs": "kc",
    "raiders": "lv", "chargers": "lac", "rams": "lar", "dolphins": "mia",
    "vikings": "min", "patriots": "ne", "saints": "no", "giants": "nyg",
    "jets": "nyj", "eagles": "phi", "steelers": "pit", "49ers": "sf",
    "seahawks": "sea", "buccaneers": "tb", "titans": "ten", "commanders": "wsh",
  ]
  private static let mlb: [String: String] = [
    "diamondbacks": "ari", "d-backs": "ari",
    "braves": "atl", "orioles": "bal",
    "red sox": "bos", "redsox": "bos",
    "cubs": "chc",
    "white sox": "chw", "whitesox": "chw",
    "reds": "cin", "guardians": "cle", "rockies": "col",
    "tigers": "det", "astros": "hou", "royals": "kc", "angels": "laa",
    "dodgers": "lad", "marlins": "mia", "brewers": "mil", "twins": "min",
    "mets": "nym", "yankees": "nyy", "athletics": "oak", "a's": "oak",
    "phillies": "phi", "pirates": "pit", "padres": "sd", "giants": "sf",
    "mariners": "sea", "cardinals": "stl", "rays": "tb", "rangers": "tex",
    "blue jays": "tor", "bluejays": "tor", "nationals": "wsh",
  ]
  private static let nhl: [String: String] = [
    "ducks": "ana", "coyotes": "ari", "bruins": "bos", "sabres": "buf",
    "flames": "cgy", "hurricanes": "car", "blackhawks": "chi", "avalanche": "col",
    "blue jackets": "cbj", "stars": "dal", "red wings": "det", "oilers": "edm",
    "panthers": "fla", "kings": "la", "wild": "min", "canadiens": "mtl",
    "predators": "nsh", "devils": "nj", "islanders": "nyi", "rangers": "nyr",
    "senators": "ott", "flyers": "phi", "penguins": "pit", "sharks": "sj",
    "kraken": "sea", "blues": "stl", "lightning": "tb", "maple leafs": "tor",
    "utah hockey": "utah", "canucks": "van", "golden knights": "vgk",
    "capitals": "wsh", "jets": "wpg",
  ]

  private static func resolveLogoURL(team: String, league: String) -> String? {
    let lower = team.lowercased()
    let sport: String
    let table: [String: String]
    switch league {
    case "nba": sport = "nba"; table = nba
    case "wnba": sport = "wnba"; table = wnba
    case "nfl", "ncaaf": sport = "nfl"; table = nfl
    case "mlb": sport = "mlb"; table = mlb
    case "nhl": sport = "nhl"; table = nhl
    default: return nil
    }
    // Word-boundary match — see App/TeamLogoService.swift for rationale.
    for (keyword, abbr) in table where matchesAsWord(haystack: lower, keyword: keyword) {
      return "https://a.espncdn.com/i/teamlogos/\(sport)/500/\(abbr).png"
    }
    return nil
  }

  private static func matchesAsWord(haystack: String, keyword: String) -> Bool {
    guard let r = haystack.range(of: keyword) else { return false }
    let isBoundaryBefore: Bool = {
      if r.lowerBound == haystack.startIndex { return true }
      let prev = haystack[haystack.index(before: r.lowerBound)]
      return !prev.isLetter
    }()
    let isBoundaryAfter: Bool = {
      if r.upperBound == haystack.endIndex { return true }
      let next = haystack[r.upperBound]
      return !next.isLetter
    }()
    return isBoundaryBefore && isBoundaryAfter
  }

  /// Mirror of App/TeamLogoCache.swift's fetchFromESPN. Hits ESPN's public
  /// team-search endpoint, returns the best match's logo URL.
  private static func espnSearchForLogo(team: String, league: String) async -> String? {
    guard !team.isEmpty,
          let encoded = team.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/search?query=\(encoded)&type=team&limit=5")
    else { return nil }

    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    do {
      let (data, _) = try await URLSession.shared.data(for: request)
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["items"] as? [[String: Any]] else { return nil }
      let nameLower = team.lowercased()
      let match = items.first(where: {
        ($0["displayName"] as? String)?.lowercased() == nameLower ||
        ($0["name"] as? String)?.lowercased() == nameLower
      }) ?? items.first(where: {
        let dn = ($0["displayName"] as? String ?? "").lowercased()
        return dn.contains(nameLower) || nameLower.contains(dn)
      }) ?? items.first
      guard let team = match,
            let logos = team["logos"] as? [[String: Any]],
            let href = logos.first?["href"] as? String else { return nil }
      return href
    } catch {
      return nil
    }
  }
}
