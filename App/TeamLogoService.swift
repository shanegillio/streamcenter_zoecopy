import Foundation

enum TeamLogoService {
  static func logoURL(for teamName: String, league: SportLeague) -> URL? {
    guard let sport = espnSport(for: league),
          let abbr = abbreviation(for: teamName.lowercased(), league: league)
    else { return nil }
    return URL(string: "https://a.espncdn.com/i/teamlogos/\(sport)/500/\(abbr).png")
  }

  private static func espnSport(for league: SportLeague) -> String? {
    switch league {
    case .nba: return "nba"
    case .wnba: return "wnba"
    case .nfl, .ncaaf: return "nfl"
    case .mlb: return "mlb"
    case .nhl: return "nhl"
    case .ncaab: return "mens-college-basketball"
    case .premierLeague, .laLiga, .serieA, .bundesliga, .soccer,
         .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague: return "soccer"
    default: return nil
    }
  }

  private static func abbreviation(for name: String, league: SportLeague) -> String? {
    switch league {
    case .nba: return nba[name]
    case .wnba: return wnba[name]
    case .nfl, .ncaaf: return nfl[name]
    case .mlb: return mlb[name]
    case .nhl: return nhl[name]
    default: return nil
    }
  }

  // Keyword → ESPN abbreviation. Checked via String.contains so partial matches work.
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
    "braves": "atl",
    "orioles": "bal",
    "red sox": "bos", "redsox": "bos",
    "cubs": "chc",
    "white sox": "chw", "whitesox": "chw",
    "reds": "cin",
    "guardians": "cle",
    "rockies": "col",
    "tigers": "det",
    "astros": "hou",
    "royals": "kc",
    "angels": "laa",
    "dodgers": "lad",
    "marlins": "mia",
    "brewers": "mil",
    "twins": "min",
    "mets": "nym",
    "yankees": "nyy",
    "athletics": "oak", "a's": "oak",
    "phillies": "phi",
    "pirates": "pit",
    "padres": "sd",
    "giants": "sf",
    "mariners": "sea",
    "cardinals": "stl",
    "rays": "tb",
    "rangers": "tex",
    "blue jays": "tor", "bluejays": "tor",
    "nationals": "wsh",
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
}

extension TeamLogoService {
  // Try each keyword in the table against the team name.
  // Uses word-boundary matching — required because plain substring matching
  // produces false positives like "Birmingham Stallions" matching "lions"
  // (returns Detroit Lions logo). A keyword counts as a match only when
  // surrounded by a non-letter (or string edge) on each side.
  static func resolve(teamName: String, league: SportLeague) -> URL? {
    let lower = teamName.lowercased()
    guard let sport = espnSport(for: league) else { return nil }
    let table: [String: String]
    switch league {
    case .nba: table = nba
    case .wnba: table = wnba
    case .nfl, .ncaaf: table = nfl
    case .mlb: table = mlb
    case .nhl: table = nhl
    default: return nil
    }
    for (keyword, abbr) in table where matchesAsWord(haystack: lower, keyword: keyword) {
      return URL(string: "https://a.espncdn.com/i/teamlogos/\(sport)/500/\(abbr).png")
    }
    return nil
  }

  /// Returns true when `keyword` appears in `haystack` flanked by non-letter
  /// characters (or string edges) on both sides. Handles multi-word keywords
  /// like "red sox" and "blue jays".
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
}
