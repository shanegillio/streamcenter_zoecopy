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

  /// Drop the cached entry for `url` so the next scrape actually hits the
  /// network. Used by Cloudflare auto-retry to force a fresh request after
  /// `cf_clearance` is set on the failed attempt.
  func invalidate(_ url: URL) {
    store[url] = nil
  }
}

struct CustomStreamSource: StreamSource {
  let name: String
  let baseURL: URL

  var id: String { baseURL.host ?? baseURL.absoluteString }

  // MARK: - League detection tables

  private static let urlSegmentLeague: [(String, SportLeague)] = [
    // Soccer / football
    ("premier-league", .premierLeague), ("epl", .premierLeague),
    ("laliga", .laLiga), ("la-liga", .laLiga),
    ("serie-a", .serieA), ("seriea", .serieA),
    ("bundesliga", .bundesliga),
    ("ligue-1", .ligue1), ("ligue1", .ligue1),
    ("eredivisie", .eredivisie),
    ("champions-league", .championsLeague), ("ucl", .championsLeague),
    ("europa-league", .europaLeague), ("uel", .europaLeague),
    ("mls", .mls), ("liga-mx", .ligaMx), ("ligamx", .ligaMx),
    ("concacaf", .soccer), ("copa-del-rey", .soccer),
    ("soccer", .soccer), ("football", .soccer),
    // North American
    ("nba", .nba), ("nfl", .nfl), ("mlb", .mlb), ("nhl", .nhl),
    ("wnba", .wnba), ("nascar", .nascar),
    ("ncaaf", .ncaaf), ("college-football", .ncaaf),
    ("ncaab", .ncaab), ("college-basketball", .ncaab),
    // Combat / entertainment
    ("ufc", .ufc), ("mma", .mma), ("boxing", .boxing), ("wwe", .wwe),
    // Motorsport / other
    ("f1", .f1), ("formula-1", .f1), ("formula1", .f1),
    ("tennis", .tennis), ("golf", .golf),
    // International hockey — only IIHF is unambiguous. Generic "world-championship"
    // could be any sport (soccer, rugby, cricket, hockey, …) so we let it fall
    // through to .other rather than guessing.
    ("iihf", .nhl),
  ]

  private static let textLeague: [(String, SportLeague)] = [
    ("premier league", .premierLeague), ("la liga", .laLiga),
    ("serie a", .serieA), ("bundesliga", .bundesliga),
    ("ligue 1", .ligue1), ("eredivisie", .eredivisie),
    ("champions league", .championsLeague), ("europa league", .europaLeague),
    ("mls", .mls), ("liga mx", .ligaMx),
    ("nba", .nba), ("nfl", .nfl), ("mlb", .mlb), ("nhl", .nhl),
    ("ufc", .ufc), ("mma", .mma), ("boxing", .boxing),
    ("ncaaf", .ncaaf), ("college football", .ncaaf),
    ("ncaab", .ncaab), ("college basketball", .ncaab),
    ("wnba", .wnba), ("wwe", .wwe), ("smackdown", .wwe),
    ("formula 1", .f1), ("grand prix", .f1), ("f1", .f1),
    ("tennis", .tennis), ("golf", .golf), ("nascar", .nascar),
    ("soccer", .soccer),
    ("iihf", .nhl),
  ]

  /// Generic sport-name → league. Matched against link text when the URL/text
  /// doesn't contain a specific league keyword. Catches ppv.to-style tab labels
  /// like "Baseball" (the homepage anchor text), where the URL is a SPA
  /// fragment like `#36` with no path to inspect.
  private static let sportNameLeague: [(String, SportLeague)] = [
    ("ice hockey", .nhl),
    ("combat sports", .ufc),
    ("baseball", .mlb),
    ("basketball", .nba),
    ("hockey", .nhl),
    ("motorsports", .nascar),
    ("wrestling", .wwe),
    // Intentionally NOT mapped (ambiguous or sport-not-league):
    //   "american football" — ppv.to's "American Football" category contains
    //                         UFL/CFL/XFL games, not NFL. Classifying as .nfl
    //                         polluted the NFL tile with UFL teams (Orlando
    //                         Storm, Houston Gamblers, etc). Real NFL games
    //                         will classify via /nfl/ URL segment or via team
    //                         name match against the learned/static tables.
    //   "football"          — could be soccer or american football by region
    //   "cricket", "rugby"  — no canonical league in our SportLeague enum yet
  ]

  /// True when `name` is just a bare sport / category word (e.g. "Basketball",
  /// "American Football", "Tennis"). Real games have team names; bare sport
  /// strings come from homepage nav anchors that the scraper mis-interprets
  /// as games. Used to reject those entries across every game-construction
  /// path (rule-based scrape, Foundation Models, API discovery).
  static func isJustASportName(_ name: String) -> Bool {
    let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if n.isEmpty { return true }
    let terms: Set<String> = [
      "soccer", "football", "american football", "basketball", "baseball",
      "hockey", "ice hockey", "tennis", "golf", "boxing", "mma", "ufc",
      "wrestling", "wwe", "racing", "motorsports", "motor sports", "f1",
      "formula 1", "nascar", "afl", "rugby", "cricket", "darts", "snooker",
      "esports", "live tv", "live", "stream", "streams", "sports", "tv",
      "channel", "channels", "more",
    ]
    return terms.contains(n)
  }

  // MARK: - Team databases (used for slug splitting and abbreviation expansion)

  // All known team names in lowercase → their league, for slug-split detection
  static let teamLeagueMap: [String: SportLeague] = {
    var map: [String: SportLeague] = [:]
    for (name, league) in allTeamNames { map[name.lowercased()] = league }
    return map
  }()

  private static let allTeamNames: [(String, SportLeague)] = {
    var teams: [(String, SportLeague)] = []
    for (_, name) in mlbTeams  { teams.append((name, .mlb))  }
    for (_, name) in nbaTeams  { teams.append((name, .nba))  }
    for (_, name) in nflTeams  { teams.append((name, .nfl))  }
    for (_, name) in nhlTeams  { teams.append((name, .nhl))  }
    for (_, name) in wnbaTeams { teams.append((name, .wnba)) }
    for (_, name) in mlsTeams  { teams.append((name, .mls))  }
    return teams
  }()

  // Sport abbreviation tables keyed by lowercase 2-3 char code
  static let mlbTeams: [String: String] = [
    "ari": "Arizona Diamondbacks", "atl": "Atlanta Braves", "bal": "Baltimore Orioles",
    "bos": "Boston Red Sox", "chc": "Chicago Cubs", "chw": "Chicago White Sox",
    "cws": "Chicago White Sox", "cin": "Cincinnati Reds", "cle": "Cleveland Guardians",
    "col": "Colorado Rockies", "det": "Detroit Tigers", "hou": "Houston Astros",
    "kc": "Kansas City Royals", "kcr": "Kansas City Royals", "laa": "Los Angeles Angels",
    "ana": "Los Angeles Angels", "lad": "Los Angeles Dodgers", "mia": "Miami Marlins",
    "fla": "Miami Marlins", "mil": "Milwaukee Brewers", "min": "Minnesota Twins",
    "nym": "New York Mets", "nyy": "New York Yankees", "oak": "Oakland Athletics",
    "phi": "Philadelphia Phillies", "pit": "Pittsburgh Pirates", "sd": "San Diego Padres",
    "sdp": "San Diego Padres", "sf": "San Francisco Giants", "sfg": "San Francisco Giants",
    "sea": "Seattle Mariners", "stl": "St. Louis Cardinals", "tb": "Tampa Bay Rays",
    "tbr": "Tampa Bay Rays", "tex": "Texas Rangers", "tor": "Toronto Blue Jays",
    "wsh": "Washington Nationals", "was": "Washington Nationals", "wsn": "Washington Nationals",
  ]

  static let nbaTeams: [String: String] = [
    "atl": "Atlanta Hawks", "bos": "Boston Celtics", "bkn": "Brooklyn Nets",
    "bk": "Brooklyn Nets", "cha": "Charlotte Hornets", "chi": "Chicago Bulls",
    "cle": "Cleveland Cavaliers", "dal": "Dallas Mavericks", "den": "Denver Nuggets",
    "det": "Detroit Pistons", "gsw": "Golden State Warriors", "gs": "Golden State Warriors",
    "hou": "Houston Rockets", "ind": "Indiana Pacers", "lac": "LA Clippers",
    "lal": "Los Angeles Lakers", "la": "Los Angeles Lakers", "mem": "Memphis Grizzlies",
    "mia": "Miami Heat", "mil": "Milwaukee Bucks", "min": "Minnesota Timberwolves",
    "nop": "New Orleans Pelicans", "no": "New Orleans Pelicans",
    "nyk": "New York Knicks", "ny": "New York Knicks",
    "okc": "Oklahoma City Thunder", "orl": "Orlando Magic",
    "phi": "Philadelphia 76ers", "phx": "Phoenix Suns", "pho": "Phoenix Suns",
    "por": "Portland Trail Blazers", "sac": "Sacramento Kings",
    "sas": "San Antonio Spurs", "sa": "San Antonio Spurs",
    "tor": "Toronto Raptors", "uta": "Utah Jazz", "was": "Washington Wizards",
    "wsh": "Washington Wizards",
  ]

  static let nflTeams: [String: String] = [
    "ari": "Arizona Cardinals", "atl": "Atlanta Falcons", "bal": "Baltimore Ravens",
    "buf": "Buffalo Bills", "car": "Carolina Panthers", "chi": "Chicago Bears",
    "cin": "Cincinnati Bengals", "cle": "Cleveland Browns", "dal": "Dallas Cowboys",
    "den": "Denver Broncos", "det": "Detroit Lions", "gb": "Green Bay Packers",
    "gnb": "Green Bay Packers", "hou": "Houston Texans", "ind": "Indianapolis Colts",
    "jax": "Jacksonville Jaguars", "jac": "Jacksonville Jaguars",
    "kc": "Kansas City Chiefs", "lac": "Los Angeles Chargers",
    "lar": "Los Angeles Rams", "lv": "Las Vegas Raiders", "lvr": "Las Vegas Raiders",
    "mia": "Miami Dolphins", "min": "Minnesota Vikings", "ne": "New England Patriots",
    "nwe": "New England Patriots", "no": "New Orleans Saints", "nor": "New Orleans Saints",
    "nyg": "New York Giants", "nyj": "New York Jets",
    "phi": "Philadelphia Eagles", "pit": "Pittsburgh Steelers",
    "sea": "Seattle Seahawks", "sf": "San Francisco 49ers", "sfo": "San Francisco 49ers",
    "tb": "Tampa Bay Buccaneers", "tam": "Tampa Bay Buccaneers",
    "ten": "Tennessee Titans", "was": "Washington Commanders",
    "wsh": "Washington Commanders",
  ]

  static let nhlTeams: [String: String] = [
    "ana": "Anaheim Ducks", "bos": "Boston Bruins", "buf": "Buffalo Sabres",
    "car": "Carolina Hurricanes", "cbj": "Columbus Blue Jackets", "cgy": "Calgary Flames",
    "chi": "Chicago Blackhawks", "col": "Colorado Avalanche", "dal": "Dallas Stars",
    "det": "Detroit Red Wings", "edm": "Edmonton Oilers", "fla": "Florida Panthers",
    "lak": "Los Angeles Kings", "la": "Los Angeles Kings", "min": "Minnesota Wild",
    "mtl": "Montreal Canadiens", "njd": "New Jersey Devils", "nj": "New Jersey Devils",
    "nsh": "Nashville Predators", "nyi": "New York Islanders", "nyr": "New York Rangers",
    "ott": "Ottawa Senators", "phi": "Philadelphia Flyers", "pit": "Pittsburgh Penguins",
    "sea": "Seattle Kraken", "sjs": "San Jose Sharks", "sj": "San Jose Sharks",
    "stl": "St. Louis Blues", "tbl": "Tampa Bay Lightning", "tb": "Tampa Bay Lightning",
    "tor": "Toronto Maple Leafs", "uta": "Utah Hockey Club", "van": "Vancouver Canucks",
    "vgk": "Vegas Golden Knights", "vgs": "Vegas Golden Knights",
    "wpg": "Winnipeg Jets", "wsh": "Washington Capitals", "was": "Washington Capitals",
  ]

  /// MLS clubs (current 2026 season). Static team→league map keeps offline
  /// classification correct before ESPN's MLS scoreboard prewarm completes,
  /// and serves as a backstop when ESPN's API is unreachable. ESPN
  /// (via `ESPNScoreboardService.leagueForTeam`) provides the same data live
  /// but adds latency / network dependency.
  static let mlsTeams: [String: String] = [
    "atl": "Atlanta United", "atx": "Austin FC", "aus": "Austin FC",
    "mtl": "CF Montréal", "clt": "Charlotte FC", "chi": "Chicago Fire",
    "cin": "FC Cincinnati", "col": "Colorado Rapids", "clb": "Columbus Crew",
    "dc": "DC United", "dal": "FC Dallas", "hou": "Houston Dynamo",
    "mia": "Inter Miami", "lag": "LA Galaxy", "lafc": "Los Angeles FC",
    "min": "Minnesota United", "nsh": "Nashville SC",
    "ner": "New England Revolution", "nyc": "New York City FC",
    "nyrb": "New York Red Bulls", "orl": "Orlando City",
    "phi": "Philadelphia Union", "por": "Portland Timbers",
    "rsl": "Real Salt Lake", "sd": "San Diego FC",
    "sj": "San Jose Earthquakes", "sea": "Seattle Sounders",
    "skc": "Sporting Kansas City", "stl": "St. Louis City",
    "tor": "Toronto FC", "van": "Vancouver Whitecaps",
  ]

  static let wnbaTeams: [String: String] = [
    "atl": "Atlanta Dream", "chi": "Chicago Sky", "con": "Connecticut Sun",
    "dal": "Dallas Wings", "ind": "Indiana Fever", "lv": "Las Vegas Aces",
    "las": "Las Vegas Aces", "lva": "Las Vegas Aces", "la": "Los Angeles Sparks",
    "min": "Minnesota Lynx", "ny": "New York Liberty", "phx": "Phoenix Mercury",
    "sea": "Seattle Storm", "was": "Washington Mystics", "wsh": "Washington Mystics",
    // 2026 expansion teams.
    "tor": "Toronto Tempo", "gsv": "Golden State Valkyries",
  ]

  static let internationalTeams: [String: String] = [
    "usa": "United States", "can": "Canada", "rus": "Russia", "swe": "Sweden",
    "fin": "Finland", "sui": "Switzerland", "cze": "Czech Republic",
    "ger": "Germany", "svk": "Slovakia", "lat": "Latvia", "den": "Denmark",
    "nor": "Norway", "kaz": "Kazakhstan", "aut": "Austria", "fra": "France",
    "gbr": "Great Britain", "hun": "Hungary", "ita": "Italy", "slv": "Slovenia",
    "slo": "Slovenia", "pol": "Poland", "blr": "Belarus", "bel": "Belarus",
    "ukr": "Ukraine",
  ]

  /// Full country names used for international match URLs like
  /// `/world-championship-group-b/norway-slovakia/123` (buffstreams pattern).
  /// Lowercased, hyphen-free. Multi-word countries are joined with a hyphen.
  static let knownCountries: Set<String> = [
    "argentina", "australia", "austria", "belarus", "belgium", "bolivia",
    "brazil", "canada", "chile", "china", "colombia", "croatia", "czechia",
    "czech-republic", "denmark", "egypt", "england", "finland", "france",
    "germany", "greece", "hungary", "iceland", "ireland", "italy", "japan",
    "kazakhstan", "korea", "south-korea", "north-korea", "latvia", "mexico",
    "morocco", "netherlands", "norway", "peru", "poland", "portugal", "russia",
    "saudi-arabia", "scotland", "serbia", "slovakia", "slovenia", "spain",
    "sweden", "switzerland", "turkey", "ukraine", "uruguay", "usa",
    "united-states", "venezuela", "wales", "great-britain", "northern-ireland",
    "south-africa", "new-zealand", "estonia", "lithuania",
  ]

  /// Keywords that appear in section/category slugs (not team slugs).
  /// Used to suppress false positives like `world-championship-group-b`.
  private static let sectionKeywords: Set<String> = [
    "championship", "league", "group", "season", "playoffs", "tournament",
    "cup", "division", "conference", "qualifier", "qualifiers", "round",
    "final", "finals", "semifinal", "semifinals", "regional",
  ]

  private static let premiumKeywords = [
    "premium", "vip", "members only", "subscription", "locked", "pro only",
    "paid", "exclusive", "subscribers", "premium only", "crown",
  ]

  private static let eventKeywords = [
    "draft", "combine", "all-star", "all star", "pro bowl", "skills challenge",
    "showcase", "awards", "scouting", "super bowl", "superbowl", "nba finals",
    "world series", "stanley cup", "championship game", "title fight",
    "press conference", "weigh-in", "open practice",
  ]

  // MARK: - League detection

  static func detectLeague(href: String, text: String,
                           learned: LearnedSportsData.Snapshot? = nil) -> SportLeague? {
    if let url = URL(string: href) {
      let segments = url.pathComponents.map { $0.lowercased() }
      // Pass 1: 3+ character keywords get a generous match — exact, with
      //         dash boundaries, OR raw prefix/suffix. The raw prefix/suffix
      //         catches site-specific suffixed slugs like `nflstreams`,
      //         `nbaregular66`, `mlbwildcard` (seen on crackstreams.ms).
      //         Picks the LONGEST matching keyword to resolve substring
      //         collisions: segment "wnba" matches both `nba` and `wnba`
      //         keywords, but the 4-char `wnba` beats the 3-char `nba` so
      //         WNBA games classify correctly instead of bleeding into NBA.
      //         False positives at 3+ chars are otherwise vanishingly rare
      //         because league acronyms don't coincidentally appear as
      //         substrings of unrelated URL words.
      var bestKeywordLen = 0
      var bestLeague: SportLeague?
      for (keyword, league) in urlSegmentLeague where keyword.count >= 3 {
        if segments.contains(where: {
          $0 == keyword
            || $0.hasPrefix(keyword + "-") || $0.hasSuffix("-" + keyword)
            || $0.hasPrefix(keyword)        || $0.hasSuffix(keyword)
        }), keyword.count > bestKeywordLen {
          bestKeywordLen = keyword.count
          bestLeague = league
        }
      }
      if let bestLeague { return bestLeague }
      // Pass 2: short 1-2 char keys (e.g. "f1") need an exact-or-dash match
      //         because they collide with too many unrelated substrings.
      for (keyword, league) in urlSegmentLeague where keyword.count < 3 {
        if segments.contains(where: {
          $0 == keyword || $0.hasPrefix(keyword + "-") || $0.hasSuffix("-" + keyword)
        }) {
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
    // Static team-name table FIRST — a full team name uniquely identifies a
    // league, so "Atlanta Dream" → .wnba beats the generic "basketball" →
    // .nba mapping below. Same logic disambiguates MLS from generic Soccer,
    // MiLB from MLB, etc. when a card's text contains both a team and a
    // sport keyword.
    for (teamName, league) in teamLeagueMap where teamName.count >= 5 && textLower.contains(teamName) {
      return league
    }
    // Generic sport names ("Baseball", "Basketball", …) — used for SPA tab
    // labels like ppv.to where the URL is a fragment and the visible text is
    // the sport name only.
    if let sportLeague = sportNameLeagueMatch(textLower: textLower) {
      return sportLeague
    }
    // Final fallback: dynamic knowledge learned from any API we've discovered
    // so far this session. Catches niche team-league pairings (international
    // hockey teams, lower-tier soccer clubs, cricket clubs, …) that the static
    // tables don't cover.
    if let learned {
      if let l = learned.league(forCategory: textLower) { return l }
      if let l = learned.league(forTextContaining: text) { return l }
    }
    return nil
  }

  /// Lookup just the generic sport-name pass (e.g. "Basketball" → .nba).
  /// Exposed so callers can detect when `detectLeague`'s answer came from
  /// this fallback layer specifically and consider an ESPN override.
  /// Input is already-lowercased text.
  static func sportNameLeagueMatch(textLower: String) -> SportLeague? {
    for (keyword, league) in sportNameLeague where textLower.contains(keyword) {
      return league
    }
    return nil
  }

  /// Extract candidate team names from a card text by splitting on common
  /// "vs"/"@" separators, then ask ESPN whether either belongs to a known
  /// league. ESPN's cache must be warm (call `prewarmAllSupported` first).
  /// Returns nil when no team name matches.
  private func leagueFromESPNTeamLookup(_ text: String) async -> SportLeague? {
    let lower = text.lowercased()
    for separator in [" vs ", " vs. ", " @ ", " v. ", " v "] {
      guard let r = lower.range(of: separator) else { continue }
      let home = String(lower[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
      let away = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
      // Strip trailing date/time/status tokens (parseTeams's text cleanup).
      let cleanHome = Self.cleanTeamText(home)
      let cleanAway = Self.cleanTeamText(away)
      if let league = await ESPNScoreboardService.shared.leagueForTeam(cleanHome) {
        return league
      }
      if let league = await ESPNScoreboardService.shared.leagueForTeam(cleanAway) {
        return league
      }
      break
    }
    return nil
  }

  // MARK: - Public API

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    // Kick off ESPN prewarm at the top so every downstream path — including
    // the API-discovery and observed-URL early returns below — has a warm
    // cache for `reconcileWithESPN`. Previously prewarm lived inside the
    // rule-based fallback path only, so games surfaced via API discovery
    // (bintv.net's observed JSON, ppv.to's /api/streams, …) never benefited
    // from cross-league reconciliation and stayed in `.other`.
    //
    // Uses `Task` rather than `async let` because the function awaits this
    // from multiple branches (each early-return path before reconciling, plus
    // the rule-based fallback's existing wait): `Task.value` is read-many,
    // `async let` consumes on first await.
    let prewarmTask = Task { await ESPNScoreboardService.shared.prewarmAllSupported() }

    // 1) Generic API discovery — works on any source whose JSON happens to
    //    match one of our shape parsers. No site names anywhere in this code
    //    path. When it succeeds, we also ingest the result into
    //    LearnedSportsData so the scraper's classifier benefits from canonical
    //    team/league knowledge on subsequent calls (and on other sources).
    if let result = await APIDiscovery.shared.fetchGames(for: baseURL) {
      let mapped = await self.mapDiscovered(result.games)
      _ = await prewarmTask.value
      let games = await self.reconcileWithESPN(mapped)
      let leagues = Set(games.map(\.league))
      if !leagues.isEmpty {
        return Array(leagues).sorted {
          if $0.popularityRank != $1.popularityRank {
            return $0.popularityRank < $1.popularityRank
          }
          return $0.displayName < $1.displayName
        }
      }
    }

    var homeLinks = await scrapeLinks()

    // Parked / blocked / sinkhole classification. Three signals:
    //   (1) Page title / meta description / final URL matches a known
    //       template (Cloudflare 1015/1020, MPAA sinkhole at
    //       alliance4creativity.com, Rebrandly broken-link, ParkLogic, Sedo,
    //       GoDaddy, etc.). When matched, throw a typed `LoadFailureReason`
    //       so HomeView can render a clearer empty state than the generic
    //       "no leagues detected".
    //   (2) Every link on the homepage points off-domain — Rebrandly's
    //       broken-link template (ntv.sh) where the 2 anchors both go to
    //       rebrandly.com. Backstop for parking pages without a
    //       recognisable title.
    //   (3) (Below) LLM-driven page classification when title/URL alone is
    //       ambiguous.
    // Network-interception path: the homepage scrape captured every URL the
    // page's JS fetched during load via the document-start fetch/XHR shim.
    // For aggregator sites (bintv.net etc.) the games live in those endpoints,
    // not in the HTML the WebView extracts. Hand the observed URLs to
    // APIDiscovery — if any decode via our shape parsers, treat exactly like
    // a successful API discovery and short-circuit the rest of the function.
    let sid = self.id
    if let observed = await MainActor.run(body: {
      SourceRegistry.shared.recentScrapes(for: sid).first { $0.url == baseURL }?.observedAPIUrls
    }), !observed.isEmpty {
      if let result = await APIDiscovery.shared.decodeObservedURLs(observed, referer: baseURL) {
        let mapped = await self.mapDiscovered(result.games)
        _ = await prewarmTask.value
        let games = await self.reconcileWithESPN(mapped)
        let leagues = Set(games.map(\.league))
        if !leagues.isEmpty {
          return Array(leagues).sorted {
            if $0.popularityRank != $1.popularityRank {
              return $0.popularityRank < $1.popularityRank
            }
            return $0.displayName < $1.displayName
          }
        }
      }
    }

    var homepageDiag = await MainActor.run {
      SourceRegistry.shared.recentScrapes(for: sid).first { $0.url == baseURL }
    }
    var classified = Self.classifyPageFromTitleAndURL(
      title: homepageDiag?.pageTitle,
      metaDescription: homepageDiag?.metaDescription,
      finalURL: homepageDiag?.finalURL
    )
    // Cloudflare auto-retry. The first scrape often fails because the device's
    // cf_clearance cookie hasn't been issued yet. The failed attempt *does*
    // trigger Cloudflare to set the cookie (now persisted across scrapes via
    // the shared WKWebsiteDataStore from v2.6), so a retry seconds later
    // usually succeeds. Try twice with exponential backoff before surfacing
    // the error — total worst case ~12 s of extra latency for a genuinely
    // blocked source, but for the typical transient block we save the user
    // a manual tap on Try Again.
    if classified == .cloudflareBlocked {
      for delaySec in [3, 6] {
        try? await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
        await ScrapeCache.shared.invalidate(baseURL)
        homeLinks = await scrapeLinks()
        homepageDiag = await MainActor.run {
          SourceRegistry.shared.recentScrapes(for: sid).first { $0.url == baseURL }
        }
        classified = Self.classifyPageFromTitleAndURL(
          title: homepageDiag?.pageTitle,
          metaDescription: homepageDiag?.metaDescription,
          finalURL: homepageDiag?.finalURL
        )
        if classified != .cloudflareBlocked { break }
      }
    }
    if let reason = classified {
      throw reason
    }
    if !homeLinks.isEmpty, let homeHost = baseURL.host?.lowercased() {
      let allOffDomain = homeLinks.allSatisfy { link in
        guard let url = URL(string: link.href), let h = url.host?.lowercased() else {
          return false
        }
        return h != homeHost && !h.hasSuffix("." + homeHost) && !homeHost.hasSuffix("." + h)
      }
      if allOffDomain {
        throw LoadFailureReason.parked
      }
    }

    // Run Foundation Models and proactive section probing CONCURRENTLY.
    // ESPN prewarm was already kicked off at the top of this function so its
    // cache is warm by the time we reconcile games below. Previously the
    // probes were sequential, so a slow/hung Foundation Models call (iOS 26
    // on-device LLM can stall on first invocation) blocked the proactive
    // probes — which are essential for SPA sites with empty homepages.
    async let fmTask: [ExtractedGame]? = Self.runFoundationModelWithTimeout(
      links: homeLinks, baseURL: baseURL, pageTitle: homepageDiag?.pageTitle
    )
    // Read text-derived league hints off the homepage's title + meta
    // description so the probing fan-out prioritises leagues the site itself
    // claims to cover. Cuts probe count for sites like streamsports99.tv
    // where the meta says "NBA, NFL, MLB, NHL, UFC, F1, Soccer, Cricket".
    let leagueHints = Self.parseLeagueHints(
      title: homepageDiag?.pageTitle,
      metaDescription: homepageDiag?.metaDescription
    )
    async let proactiveTask: Set<SportLeague> = Self.runProactiveProbing(
      source: self, hints: leagueHints
    )

    _ = await prewarmTask.value
    let fmExtracted = await fmTask

    // Rule-based fallback: one-level (games on home page).
    // Game links without a detected league fall into ".other" so the user can
    // still browse them — for niche sports, international events, etc.
    // Capture the latest LearnedSportsData snapshot so detectLeague can use
    // team→league pairings learned from any source's API earlier this session.
    let learned = await LearnedSportsData.shared.snapshot()
    var directLeagues = Set<SportLeague>()
    var sawUnclassifiedGameLink = false
    for link in homeLinks where isGameLink(link) || isEventLink(link) {
      if let league = Self.detectLeague(href: link.href, text: link.text, learned: learned) {
        // ESPN override pass: when detectLeague's answer came from the
        // generic sport-name fallback (e.g. "Basketball" → .nba), ask ESPN
        // whether the team names point to a more specific league
        // ("Manchester United" → .premierLeague). ESPN's prewarm fills its
        // cache at the top of this function, so the lookup is in-memory.
        // Catches MLS / Premier League / La Liga teams not in our static DB.
        if isGameLink(link),
           let genericGuess = Self.sportNameLeagueMatch(textLower: link.text.lowercased()),
           genericGuess == league,
           let espnLeague = await leagueFromESPNTeamLookup(link.text),
           espnLeague != league {
          directLeagues.insert(espnLeague)
        } else {
          directLeagues.insert(league)
        }
      } else if isGameLink(link) {
        // ESPN-aware fallback: extract candidate team names from the link
        // text and ask ESPN's team→league reverse lookup. Catches games
        // like "Spurs vs Timberwolves" on ppv.to where the URL has no
        // "nba" keyword and our static team table didn't match.
        if let league = await leagueFromESPNTeamLookup(link.text) {
          directLeagues.insert(league)
        } else {
          sawUnclassifiedGameLink = true
        }
      }
    }
    if sawUnclassifiedGameLink { directLeagues.insert(.other) }
    // Always also try the two-level path: even if the homepage already has
    // some game links, section pages (/live/nba, /live/nhl, …) often expose
    // leagues that aren't directly linked from the homepage. We merge both
    // sources so the user sees the full set of available leagues.
    var sectionByLeague = [SportLeague: URL]()
    for link in homeLinks {
      guard !isGameLink(link), !isEventLink(link),
            let url = URL(string: link.href),
            isSameDomain(url),
            let league = Self.detectLeague(href: link.href, text: link.text),
            sectionByLeague[league] == nil,
            !directLeagues.contains(league) else { continue }
      let segs = url.pathComponents.filter { $0 != "/" }
      guard segs.count >= 1, segs.count <= 3 else { continue }
      sectionByLeague[league] = url
    }

    var verified = Set<SportLeague>()
    if !sectionByLeague.isEmpty {
      let candidates = Array(sectionByLeague)
      for batchStart in stride(from: 0, to: candidates.count, by: 5) {
        let batch = Array(candidates[batchStart ..< min(batchStart + 5, candidates.count)])
        await withTaskGroup(of: SportLeague?.self) { group in
          for (league, url) in batch {
            group.addTask {
              let sub = await self.scrapeLinks(url: url, timeout: 20)
              // League-aware verification: a generic "live now" page reached
              // via /live/{slug} may list only other sports — require at
              // least one game/event link that classifies back to `league`.
              let hit = sub.contains { link in
                guard self.isGameLink(link) || self.isEventLink(link) else { return false }
                return Self.detectLeague(href: link.href, text: link.text, learned: learned) == league
              }
              return hit ? league : nil
            }
          }
          for await result in group { if let l = result { verified.insert(l) } }
        }
      }
    }

    // Merge in the proactive section-probe results that have been running in
    // the background since the homepage scrape finished. They probe canonical
    // section paths (/live/{slug}, /{slug}, /sports/{slug}) for every league,
    // independent of the homepage links. Critical for sites whose homepage is
    // a heavy SPA / redirect that yields no classifiable anchors.
    let proactive = await proactiveTask
    verified.formUnion(proactive)

    // Foundation Models result (may be nil if disabled, timed out, or returned
    // no parsable games). Union into the final set rather than short-circuiting
    // — FM occasionally classifies cards the rule path misses, and vice versa.
    var fmLeagues = Set<SportLeague>()
    if let extracted = fmExtracted {
      fmLeagues = Set(extracted.compactMap { eg -> SportLeague? in
        // Skip sport-name-only junk so it doesn't add a phantom league
        // (e.g. "Basketball" → .nba) when no real game exists.
        if Self.isJustASportName(eg.homeTeam) { return nil }
        return Self.detectLeague(href: eg.pageURL.absoluteString, text: eg.league)
      })
    }

    let merged = directLeagues.union(verified).union(fmLeagues)

    if merged.isEmpty {
      // Nothing classified. Two common causes:
      //   1. The user typed a dead/wrong URL that *does* resolve via DNS but
      //      serves nonsense (e.g. ntv.sh is a Rebrandly broken-link page).
      //   2. The site we hit is real but doesn't expose anchors we recognise
      //      (heavy SPA, login wall, etc.).
      //
      // For case 1 — and only when this isn't already a fallback retry — try
      // the same hostname-prefix across our TLD candidate list. HostFallback
      // does HEAD probes in parallel; whichever variant responds 2xx/3xx
      // first replaces the source's URL via SourceRegistry. SwiftUI's
      // `onChange(of: registry.selectedSource)` then fires a fresh
      // `loadLeagues()` against the working mirror.
      if let variant = await HostFallback.shared.tryVariants(of: baseURL),
         variant != baseURL {
        let sid = self.id
        await MainActor.run {
          SourceRegistry.shared.replaceSourceURL(originalID: sid, newURL: variant)
        }
      }
      return []
    }

    // No additional pre-warm needed: `prewarmAllSupported()` at the top of
    // this function has already populated the ESPN cache for every league
    // we care about.

    return Array(merged).sorted {
      if $0.popularityRank != $1.popularityRank {
        return $0.popularityRank < $1.popularityRank
      }
      return $0.displayName < $1.displayName
    }
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    // Generic API-first path.
    if let result = await APIDiscovery.shared.fetchGames(for: baseURL) {
      let mapped = await self.mapDiscovered(result.games)
      // ESPN reconciliation: recover league + time + status for games that
      // came back as `.other` because no static team table covers them
      // (EPL / La Liga / etc.). The ESPN cache was warmed by the prior
      // `fetchAvailableLeagues` call — if it expired since then, this
      // is a no-op and games are returned unchanged.
      let reconciled = await self.reconcileWithESPN(mapped)
      var filtered = reconciled.filter { $0.league == league }
      // v2.19: per-league ESPN enrich for the API-discovery path too. The
      // rule-based fallback already does this at line ~777; the API path
      // was skipping it, which is why MLB live games from ppv.to showed
      // "● LIVE" with no score line ("3-1 • 2nd Inning"). Run the same
      // per-league enrich here so live-state details land on every path.
      if !filtered.isEmpty, ESPNScoreboardService.apiPath(for: league) != nil {
        filtered = await ESPNScoreboardService.shared.enrich(filtered, for: league)
      }
      if !filtered.isEmpty {
        return filtered.sorted { a, b in
          if a.isLive != b.isLive { return a.isLive }
          switch (a.scheduledTime, b.scheduledTime) {
          case let (at?, bt?): return at < bt
          case (.some, .none): return true
          default: return false
          }
        }
      }
    }

    let homeLinks = await scrapeLinks()

    // iOS 26+: try on-device Foundation Models first (silently no-ops on older OS)
    if FoundationModelScraper.isSupported,
       let extracted = await FoundationModelScraper.shared.extractGames(from: homeLinks, baseURL: baseURL) {
      let games: [Game] = extracted.compactMap { eg -> Game? in
        // Filter sport-name junk (Foundation Models occasionally surfaces
        // homepage nav anchors as "games" too).
        if Self.isJustASportName(eg.homeTeam) { return nil }
        if !eg.awayTeam.isEmpty, Self.isJustASportName(eg.awayTeam) { return nil }
        let detected = Self.detectLeague(href: eg.pageURL.absoluteString, text: eg.league)
        if league == .other {
          guard detected == nil else { return nil }
          return gameFromExtracted(eg, league: .other)
        }
        guard detected == league else { return nil }
        return gameFromExtracted(eg, league: league)
      }
      if !games.isEmpty {
        return games.sorted { a, b in
          if a.isLive != b.isLive { return a.isLive }
          switch (a.scheduledTime, b.scheduledTime) {
          case let (at?, bt?): return at < bt
          case (.some, .none): return true
          default: return false
          }
        }
      }
    }

    // Rule-based fallback. Capture the LearnedSportsData snapshot once and
    // thread it through so detectLeague can use API-learned team→league
    // pairings (e.g. learned earlier from ppv.to) to classify scraped links
    // on this source even if the source has no API of its own.
    let learned = await LearnedSportsData.shared.snapshot()
    var games = buildGames(from: homeLinks, for: league, requireLeagueDetection: true, learned: learned)

    // Always check section pages too — homepages often list only a handful of
    // featured games, but section pages (e.g. /live/mlb) have the full schedule.
    // We dedupe by URL after merging so games on both pages don't double up.
    let sectionURLs = findSectionURLs(for: league, in: homeLinks)
    if !sectionURLs.isEmpty {
      await withTaskGroup(of: [Game].self) { group in
        // Up to 3 section probes per league so the proactive path patterns
        // (/live/{slug}, /{slug}, /sports/{slug}) all get a chance even when
        // the homepage doesn't link any of them.
        for url in sectionURLs.prefix(3) {
          group.addTask {
            let subLinks = await self.scrapeLinks(url: url, timeout: 20)
            // Strict league check: even when scraping a probed section page
            // like `/live/nba`, only accept games whose own URL/text resolves
            // to the requested league. Many streaming sites' "section" URLs
            // are actually generic "live now" pages mixing every sport, so
            // a permissive accept would dump NASCAR / IIHF / WWE cards into
            // the NBA tab.
            return self.buildGames(from: subLinks, for: league, requireLeagueDetection: true, learned: learned)
          }
        }
        for await sectionGames in group {
          games.append(contentsOf: sectionGames)
        }
      }
    }

    // Dedupe by game ID (which is the page URL) so cross-listed games don't appear twice.
    var seen = Set<String>()
    games = games.filter { seen.insert($0.id).inserted }

    // ESPN enrichment: replace scraped times/scores/live status with canonical
    // ESPN data when the league is supported. This gives us accurate kick-off
    // times even when the source's link text has no time info, plus live
    // scores and period/inning labels.
    if ESPNScoreboardService.apiPath(for: league) != nil {
      games = await ESPNScoreboardService.shared.enrich(games, for: league)
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

  // MARK: - Convert DiscoveredGame → Game (API-discovery path)

  /// Maps each API-discovered game into the app's Game model, classifying its
  /// league via the existing detectLeague tables (which include the new sport
  /// name table) and the LearnedSportsData snapshot. Also feeds the batch
  /// back into LearnedSportsData so that every subsequent classification
  /// (including web-scraped calls on other sources) benefits.
  private func mapDiscovered(_ discovered: [DiscoveredGame]) async -> [Game] {
    // Resolve category labels using the static tables first.
    let resolveCategory: (String) -> SportLeague? = { label in
      Self.detectLeague(href: "", text: label)
    }

    // Ingest into the learning store before mapping, so even this batch's
    // own games benefit from the freshest learned team→league pairs.
    await LearnedSportsData.shared.ingest(discovered, resolveCategory: resolveCategory)
    let learned = await LearnedSportsData.shared.snapshot()
    // Snapshot the team database once (actor crossing is cheap but compactMap
    // below is sync). Longest names first so "Manchester United" wins over
    // "Manchester City" on substring matches that contain both.
    let dbEntries = await TeamDatabase.shared.allEntriesByLengthDescending()

    let mapped: [Game] = discovered.compactMap { dg -> Game? in
      // Reject entries whose home team is just a sport-category label —
      // these are usually nav anchors the API also surfaces by mistake.
      if Self.isJustASportName(dg.homeName) { return nil }
      // Reject "24/7 X" IPTV channel entries. The category-level filter
      // in APIDiscovery.nestedCategories catches the canonical ppv.to
      // case; this is the belt-and-suspenders layer for sources that
      // don't use a clean category label (e.g. when the channel gets
      // surfaced through a "Football" / generic bucket by mistake).
      let homeLower = dg.homeName.lowercased()
      if homeLower.hasPrefix("24/7 ") || homeLower.hasPrefix("24-7 ") { return nil }
      // Non-event games need a "vs" pair AND ideally a scheduled time;
      // bare entries without those signals are almost always navigation
      // noise. Single-team events (`awayName.isEmpty`) keep the relaxed
      // contract — they're real (e.g. Indy 500, OKTAGON 88).
      if !dg.awayName.isEmpty, dg.startsAt == nil, dg.homeName == dg.awayName {
        return nil
      }
      // Team-name disambiguation runs FIRST. Streaming APIs like NTVSTREAM /
      // streamed.pk lump every basketball game under category="basketball",
      // every soccer game under "football", etc. — so the category alone
      // can't tell NBA from WNBA, or MLS from Premier League. A full team
      // name match in the team database (e.g. "Atlanta Dream") resolves to
      // the specific league unambiguously and beats the generic category.
      //
      // Lookup order: TeamDatabase (GitHub-hosted, broadest coverage) →
      // legacy static `teamLeagueMap` (kept for abbreviation tables that
      // haven't moved into the DB yet) → category → learned data → .other.
      let teamCombined = (dg.homeName + " " + dg.awayName).lowercased()
      let teamLeague: SportLeague? = {
        for (name, league) in dbEntries
          where name.count >= 5 && teamCombined.contains(name) {
          return league
        }
        for (teamName, league) in Self.teamLeagueMap
          where teamName.count >= 5 && teamCombined.contains(teamName) {
          return league
        }
        return nil
      }()
      let categoryLeague = Self.detectLeague(
        href: dg.pageURL.absoluteString, text: dg.categoryLabel, learned: learned
      )
      // v2.20: country-team disambiguation. National teams ("Germany",
      // "Latvia", "Norway") are listed in teams.json under .soccer because
      // they play soccer internationally — but those same countries also
      // play ice hockey, basketball, handball, etc., under the same bare
      // name. When the team match resolves to .soccer AND the category
      // resolves to a specific non-soccer league, the category is the
      // more reliable signal (ppv.to literally labels these "Ice Hockey").
      // Club-level matches (Manchester United, AS Roma) are unaffected
      // because their team match isn't .soccer — it's already specific.
      let league: SportLeague = {
        if teamLeague == .soccer,
           let cat = categoryLeague, cat != .soccer, cat != .other {
          return cat
        }
        return teamLeague
          ?? categoryLeague
          ?? learned.league(forTextContaining: teamCombined)
          ?? .other
      }()

      let isEvent = dg.awayName.isEmpty
      return Game(
        id: dg.externalID.isEmpty ? dg.pageURL.absoluteString : "\(baseURL.host ?? "")|\(dg.externalID)",
        homeTeam: dg.homeName,
        awayTeam: dg.awayName,
        scheduledTime: dg.startsAt,
        timeIsKnown: dg.startsAt != nil,
        isLive: dg.isLive,
        // Leave nil: LiveStatusBadge already renders its own animated "● LIVE"
        // pill when isLive is true. Setting "LIVE" here would stack the word
        // on top of the pill ("LIVE\n● LIVE"). Reserve liveStatus for real
        // game state like "3-1 • 2nd Quarter" — which the discovery API
        // doesn't expose for ppv.to-style sources.
        liveStatus: nil,
        isEvent: isEvent,
        isPremium: false,
        pageURL: dg.pageURL,
        league: league
      )
    }

    // v2.20: dedupe by normalized team-pair. Multi-source merge (v2.18)
    // can produce two entries for the same fixture from different feeds
    // (e.g. ppv.to and Streamed-images-json both list "Sevilla vs Real
    // Madrid"), each with its own pageURL and externalID — the dedupe
    // in APIDiscovery doesn't catch these because its key is
    // (externalID, pageURL). Order-insensitive team-pair key + diacritic
    // folding catches both home/away orientations and accent variants.
    let deduped = Self.dedupeByTeams(mapped)

    // v2.20: hard past-game filter. Drop games whose scheduledTime is
    // more than 4 h in the past AND aren't live — these are typically
    // replays the source kept linked. User intent: "only making game
    // listings for actual links we found on these pages to active
    // streams or upcoming streams."
    let nowGated = deduped.filter { game in
      if game.isLive { return true }
      guard let st = game.scheduledTime else { return true }
      return st.timeIntervalSinceNow > -4 * 60 * 60
    }

    // LLM enrichment pass: hands the candidate games + page context to the
    // on-device model and lets it drop nonsense, correct ambiguous team
    // names ("United" → "Manchester United" on an EPL page), and re-tag
    // wrong-bucket leagues. Conservative by design — leaves entries alone
    // unless it's confident. iOS < 26: silent no-op.
    let enriched = await applyLLMEnrichment(nowGated)

    // Warm URLCache with team-logo PNGs immediately. By the time the user
    // sees the Streams tab, AsyncImage in each LiveGameRow hits the cache
    // and paints the logos without a network round-trip.
    await LogoPrefetcher.shared.warm(games: enriched)

    return enriched
  }

  /// Groups Games by a normalized, order-insensitive team-pair key and
  /// keeps the most-information-rich entry per group. Used after
  /// mapDiscovered to merge cross-source duplicates (same fixture surfaced
  /// by ppv.to AND a github.io catalog, etc.).
  private static func dedupeByTeams(_ games: [Game]) -> [Game] {
    var byKey: [String: Game] = [:]
    var orderKeys: [String] = []
    for game in games {
      let key = pairKey(home: game.homeTeam, away: game.awayTeam)
      if let existing = byKey[key] {
        byKey[key] = preferredGame(existing, game)
      } else {
        byKey[key] = game
        orderKeys.append(key)
      }
    }
    return orderKeys.compactMap { byKey[$0] }
  }

  /// Order-insensitive canonical pair key — "Real Madrid vs Sevilla"
  /// and "Sevilla vs Real Madrid" produce the same key, so home/away
  /// orientation differences across sources collapse to one entry.
  private static func pairKey(home: String, away: String) -> String {
    let h = normalizeTeamName(home)
    let a = normalizeTeamName(away)
    return h <= a ? "\(h)|\(a)" : "\(a)|\(h)"
  }

  /// Lowercase + strip diacritics + drop common club suffixes + collapse
  /// punctuation. "Sevilla FC" / "Sevilla" / "Sevilla F.C." all hash to
  /// the same key; "Atlético Madrid" matches "Atletico Madrid".
  private static func normalizeTeamName(_ s: String) -> String {
    let folded = s.lowercased()
      .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
    let cleaned = folded
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\b(fc|ac|sc|cf|afc)\\b", with: "",
                            options: .regularExpression)
      .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    return cleaned.trimmingCharacters(in: .whitespaces)
  }

  /// Prefer the more informative of two duplicate Game entries:
  ///   live > upcoming with status > upcoming with time > anything else.
  private static func preferredGame(_ a: Game, _ b: Game) -> Game {
    if a.isLive != b.isLive { return a.isLive ? a : b }
    let aHasStatus = a.liveStatus?.isEmpty == false
    let bHasStatus = b.liveStatus?.isEmpty == false
    if aHasStatus != bHasStatus { return aHasStatus ? a : b }
    let aHasTime = a.scheduledTime != nil && a.timeIsKnown
    let bHasTime = b.scheduledTime != nil && b.timeIsKnown
    if aHasTime != bHasTime { return aHasTime ? a : b }
    return a
  }

  /// Runs the FoundationModelScraper enrichment pass over the mapped game
  /// list, then applies the verdicts: drops `keep=false` entries, and for
  /// the rest applies `correctedHome` / `correctedAway` / `correctedLeague`
  /// when the model returned them. Non-enrichable cases (Foundation Models
  /// unavailable, model timed out) pass through unchanged.
  private func applyLLMEnrichment(_ games: [Game]) async -> [Game] {
    guard !games.isEmpty else { return games }

    // Build the candidate tuples and the original title for each game, so
    // the model can see what the source called the entry (helps when a
    // team name has been pre-canonicalized in our pipeline but the model
    // wants to refer back to the raw source string).
    let candidates: [(home: String, away: String, league: String, sourceTitle: String?)] =
      games.map { g in
        let title = g.awayTeam.isEmpty ? g.homeTeam : "\(g.homeTeam) vs \(g.awayTeam)"
        return (g.homeTeam, g.awayTeam, g.league.rawValue, title)
      }

    // Page context: source URL + the most recent scrape's title + meta
    // description if available. The scraper persists these into
    // `SourceRegistry.recentScrapes` (read on the main actor).
    let sid = self.id
    let base = baseURL
    let diag = await MainActor.run {
      SourceRegistry.shared.recentScrapes(for: sid).first { $0.url == base }
    }
    let pageContext = FoundationModelScraper.PageContext(
      sourceURL: baseURL,
      pageTitle: diag?.pageTitle,
      metaDescription: diag?.metaDescription
    )

    let verdicts = await FoundationModelScraper.shared.enrich(
      candidates: candidates,
      pageContext: pageContext
    )
    guard verdicts.count == games.count else { return games }

    var out: [Game] = []
    out.reserveCapacity(games.count)
    for (i, g) in games.enumerated() {
      let v = verdicts[i]
      if !v.keep { continue }
      // Apply corrections only when the model returned a non-empty value.
      // Map corrected league raw value back to SportLeague (silently ignore
      // unknown values so a model hallucination can't crash classification).
      let newLeague: SportLeague = {
        if let raw = v.correctedLeague,
           let parsed = SportLeague(rawValue: raw) {
          return parsed
        }
        return g.league
      }()
      let newHome = v.correctedHome ?? g.homeTeam
      let newAway = v.correctedAway ?? g.awayTeam
      if newLeague == g.league && newHome == g.homeTeam && newAway == g.awayTeam {
        out.append(g)
      } else {
        out.append(Game(
          id: g.id,
          homeTeam: newHome,
          awayTeam: newAway,
          scheduledTime: g.scheduledTime,
          timeIsKnown: g.timeIsKnown,
          isLive: g.isLive,
          liveStatus: g.liveStatus,
          isEvent: g.isEvent,
          isPremium: g.isPremium,
          pageURL: g.pageURL,
          league: newLeague
        ))
      }
    }
    return out
  }

  // MARK: - ESPN reconciliation

  /// Best-effort post-process for API-discovered games: searches the ESPN
  /// scoreboard cache across **every** prewarmed league for a matching event
  /// and fills in missing league assignment, scheduled time, and live status.
  ///
  /// The per-league `ESPNScoreboardService.enrich` only fires when we already
  /// know the league — this reconciliation pass catches the inverse case:
  /// games that came back from `mapDiscovered` as `.other` because their
  /// team names aren't in the static map (EPL / La Liga / Serie A teams
  /// that aggregator sites like bintv.net surface via observed API URLs).
  ///
  /// Caller is responsible for awaiting `prewarmAllSupported` before calling
  /// this. If the cache is cold, games are returned unchanged.
  /// Leagues we treat as generic buckets — when `mapDiscovered` returns one
  /// of these, reconciliation will replace it with whatever specific league
  /// ESPN found. ppv.to's `category` field is sport-coarse ("Soccer",
  /// "Football") which maps to these buckets; aggregator-style sources that
  /// don't classify at all land in `.other`. Specific leagues (.nba, .nfl, …)
  /// already came from the static team map or learned data — trust them.
  private static let genericLeagues: Set<SportLeague> = [.other, .soccer]

  private func reconcileWithESPN(_ games: [Game]) async -> [Game] {
    var out: [Game] = []
    out.reserveCapacity(games.count)
    for game in games {
      let leagueIsGeneric = Self.genericLeagues.contains(game.league)
      let needsTime       = game.scheduledTime == nil || !game.timeIsKnown
      let needsLiveStatus = game.liveStatus == nil
      // v2.19: also reconcile when a game already has a known league + time
      // but no live status. MLB games from ppv.to come back with isLive=true
      // and scheduledTime set but liveStatus=nil; previously the canBenefit
      // gate skipped them entirely so ESPN never filled in "3-1 • 2nd Inning".
      let canBenefit      = leagueIsGeneric || needsTime || !game.isLive || needsLiveStatus
      if !canBenefit {
        out.append(game)
        continue
      }
      // Skip single-team events (drafts, combines) — bestMatch's single-team
      // fallback can pull arbitrary games from the same league.
      if game.awayTeam.isEmpty {
        out.append(game)
        continue
      }
      guard let result = await ESPNScoreboardService.shared.findEvent(
        homeTeam: game.homeTeam, awayTeam: game.awayTeam, pageURL: game.pageURL
      ) else {
        out.append(game)
        continue
      }
      let event = result.event
      // v2.20: when ESPN says the event is completed, drop the entry
      // entirely. ppv.to often keeps a stream URL for past games for
      // replay/highlight purposes; user intent is "only list active or
      // upcoming streams." The v2.19 "show FT score" path is gone — no
      // listing means no listing.
      if event.isCompleted { continue }
      // For non-completed events, fill in time from ESPN when missing.
      let scheduledTime: Date? = needsTime ? event.scheduledDate : game.scheduledTime
      let timeIsKnown: Bool = needsTime ? true : game.timeIsKnown
      out.append(Game(
        id: game.id,
        homeTeam: game.homeTeam,
        awayTeam: game.awayTeam,
        scheduledTime: scheduledTime,
        timeIsKnown: timeIsKnown,
        isLive: event.isLive || game.isLive,
        liveStatus: event.liveStatus ?? game.liveStatus,
        isEvent: game.isEvent,
        isPremium: game.isPremium,
        pageURL: game.pageURL,
        league: leagueIsGeneric ? result.league : game.league
      ))
    }
    return out
  }

  // MARK: - Convert ExtractedGame → Game

  private func gameFromExtracted(_ eg: ExtractedGame, league: SportLeague) -> Game {
    let isEvent = eg.awayTeam.isEmpty
    let scheduledTime = parseExtractedDateTime(date: eg.scheduledDate, time: eg.scheduledTime)
    let isLive = eg.isLive || detectLive(text: "", domStatus: "", scheduledTime: scheduledTime)
    return Game(
      id: eg.pageURL.absoluteString,
      homeTeam: eg.homeTeam,
      awayTeam: eg.awayTeam,
      scheduledTime: scheduledTime,
      isLive: isLive,
      liveStatus: nil,
      isEvent: isEvent,
      isPremium: false,
      pageURL: eg.pageURL,
      league: league
    )
  }

  private func parseExtractedDateTime(date: String?, time: String?) -> Date? {
    guard let dateStr = date else { return nil }
    let etTZ = TimeZone(identifier: "America/New_York")!
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = etTZ
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = etTZ
    if let timeStr = time {
      formatter.dateFormat = "yyyy-MM-dd HH:mm"
      if let d = formatter.date(from: "\(dateStr) \(timeStr)") { return d }
    }
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: dateStr)
  }

  // MARK: - Internal helpers

  private func findSectionURLs(for league: SportLeague, in homeLinks: [ScrapedLink]) -> [URL] {
    var seen = Set<String>()
    var urls: [URL] = []

    // 1) URLs the homepage actually links to. Accept either:
    //    - regular sub-paths (1–3 segments), or
    //    - SPA fragment URLs like `https://ppv.to/#36` (0 segments but a hash).
    for link in homeLinks {
      guard !isGameLink(link), !isEventLink(link),
            let url = URL(string: link.href),
            isSameDomain(url),
            let detected = Self.detectLeague(href: link.href, text: link.text),
            detected == league else { continue }
      let segs = url.pathComponents.filter { $0 != "/" }
      let hasFragment = !(url.fragment ?? "").isEmpty
      let pathOk = (segs.count >= 1 && segs.count <= 3) || hasFragment
      guard pathOk, seen.insert(url.absoluteString).inserted else { continue }
      urls.append(url)
    }

    // 2) Proactive probes — common section-path patterns. Catches NBA on
    //    ppv.to even when the homepage doesn't surface /live/nba in its nav,
    //    so games only listed on the section page (Spurs-Timberwolves) still
    //    get discovered.
    if let slug = Self.sectionSlug(for: league) {
      for path in ["/live/\(slug)", "/\(slug)", "/sports/\(slug)"] {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              seen.insert(url.absoluteString).inserted else { continue }
        urls.append(url)
      }
    }

    return urls
  }

  /// Classifies a homepage scrape into a `LoadFailureReason` based on the
  /// page title, meta description, and final URL after redirects. Returns
  /// `nil` when nothing matches — caller continues with normal probing.
  ///
  /// Categories detected:
  /// - **Cloudflare** — title `Access denied | … used Cloudflare to re…` (1015)
  ///   or `Attention Required` (1020). Note: *interactive* JS challenges
  ///   ("Just a moment…") are handled inside WebViewScraper with a re-extract
  ///   loop; by the time they reach here they've either solved or failed hard.
  /// - **MPAA sinkhole** — final URL host matches a known piracy-awareness
  ///   landing (alliance4creativity.com is the big one used by streameast,
  ///   nflbite, and 100+ others).
  /// - **Parking** — Rebrandly broken-link, ParkLogic, HugeDomains, GoDaddy,
  ///   Sedo, Afternic, etc.
  private static func classifyPageFromTitleAndURL(
    title: String?, metaDescription: String?, finalURL: URL?
  ) -> LoadFailureReason? {
    let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let meta = (metaDescription ?? "").lowercased()

    // 1) MPAA / takedown sinkhole — primarily detected by final-URL host swap.
    if let host = finalURL?.host?.lowercased() {
      let sinkholes = [
        "alliance4creativity.com",
        "watchitlegally.com",
        "creativecontent.eu",
      ]
      if sinkholes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
        return .sinkholed
      }
    }
    // Sinkhole text patterns as a backstop.
    if t == "watch it legally" || t.hasPrefix("watch it legally")
        || meta.contains("piracy is illegal") || t.contains("seized by") {
      return .sinkholed
    }

    // 2) Cloudflare hard-block (1015 rate limit / 1020 WAF block).
    //    Title pattern: "Access denied | <host> used Cloudflare to restrict access"
    //    Or: "Attention Required! | Cloudflare"
    if t.contains("used cloudflare to restrict") {
      return .cloudflareBlocked
    }
    if t.hasPrefix("attention required") && t.contains("cloudflare") {
      return .cloudflareBlocked
    }
    if t.hasPrefix("access denied") && t.contains("cloudflare") {
      return .cloudflareBlocked
    }

    // 3) Domain parking / broken-link templates.
    guard !t.isEmpty else { return nil }
    let parkingExactOrPrefix = [
      "redirecting",
      "rebrandly",
      "domain parking",
      "domain for sale",
      "buy this domain",
      "parked domain",
    ]
    for pattern in parkingExactOrPrefix {
      if t == pattern || t.hasPrefix(pattern) { return .parked }
    }
    let parkingContains = [
      " is for sale",
      " is for-sale",
      " for sale -",
      "hugedomains",
      "godaddy",
      "sedoparking",
      "parklogic",
      "branded short domain",
      "this domain has expired",
      "afternic",
    ]
    for needle in parkingContains where t.contains(needle) { return .parked }
    return nil
  }

  /// Back-compat shim — true when classification returns any non-nil reason.
  /// Some legacy call sites still want a yes/no answer. Prefer
  /// `classifyPageFromTitleAndURL` directly.
  private static func looksLikeParkingTitle(_ title: String) -> Bool {
    classifyPageFromTitleAndURL(title: title, metaDescription: nil, finalURL: nil) != nil
  }

  /// Scans the homepage title + meta description for keywords that name
  /// specific leagues this site is known to cover. Used by
  /// `runProactiveProbing` to prioritise those leagues' probes first. Returns
  /// the set of league hints derived from text — empty when the site doesn't
  /// announce its coverage in title/meta.
  ///
  /// Most sports streaming sites publish their league set in the meta
  /// description (e.g. "Stream free live sports — NBA, NFL, MLB, NHL, UFC,
  /// F1, Soccer, Cricket and more."). Using that signal cuts the proactive
  /// probe count from ~20 → 6-8 for the typical site, which both speeds up
  /// first-load and keeps the device cool.
  private static func parseLeagueHints(title: String?, metaDescription: String?) -> Set<SportLeague> {
    var hints = Set<SportLeague>()
    let combined = ((title ?? "") + " " + (metaDescription ?? "")).lowercased()
    guard !combined.isEmpty else { return hints }
    // Match against urlSegmentLeague + textLeague keywords. Equality / word-
    // bounded matching only — substring would over-fire.
    for (keyword, league) in urlSegmentLeague where keyword.count >= 2 {
      // Word boundaries on the combined string: keyword surrounded by non-
      // alphanumeric chars (or string edges).
      if Self.containsAsWord(combined, keyword) {
        hints.insert(league)
      }
    }
    for (keyword, league) in textLeague where keyword.count >= 2 {
      if Self.containsAsWord(combined, keyword) {
        hints.insert(league)
      }
    }
    for (keyword, league) in sportNameLeague where keyword.count >= 4 {
      if Self.containsAsWord(combined, keyword) {
        hints.insert(league)
      }
    }
    return hints
  }

  /// Word-bounded substring check — `keyword` appears in `haystack` with
  /// non-alphanumeric characters (or string edges) on both sides. Prevents
  /// `"nba"` from matching `"wnba"` and `"f1"` from matching `"fly"`.
  private static func containsAsWord(_ haystack: String, _ keyword: String) -> Bool {
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let r = haystack.range(of: keyword, range: searchRange) {
      let beforeOK: Bool = {
        if r.lowerBound == haystack.startIndex { return true }
        let i = haystack.index(before: r.lowerBound)
        return !haystack[i].isLetter && !haystack[i].isNumber
      }()
      let afterOK: Bool = {
        if r.upperBound == haystack.endIndex { return true }
        return !haystack[r.upperBound].isLetter && !haystack[r.upperBound].isNumber
      }()
      if beforeOK && afterOK { return true }
      searchRange = r.upperBound..<haystack.endIndex
    }
    return false
  }

  /// Runs `probeSectionForLeague` for every supported league, prioritising
  /// leagues hinted at by the homepage title / meta description so the most
  /// likely candidates are scraped first. Concurrency is capped at 3 (was 5)
  /// to keep the device cool on slow / Cloudflare-walled sites. A 60-second
  /// soft wallclock budget bails out early if the site is grinding without
  /// returning anything useful.
  private static func runProactiveProbing(
    source: CustomStreamSource, hints: Set<SportLeague>
  ) async -> Set<SportLeague> {
    var found = Set<SportLeague>()
    let learned = await LearnedSportsData.shared.snapshot()
    let allLeagues = SportLeague.allCases.filter { Self.sectionSlug(for: $0) != nil }
    // Tier A first (text-hinted), then everything else.
    let tierA = allLeagues.filter { hints.contains($0) }
    let tierB = allLeagues.filter { !hints.contains($0) }
    let ordered = tierA + tierB
    let startedAt = Date()
    let budget: TimeInterval = 60
    for batchStart in stride(from: 0, to: ordered.count, by: 3) {
      // Stop probing once we've blown the wallclock budget. Whatever we have
      // is returned; HomeView surfaces it (possibly empty → empty state).
      if Date().timeIntervalSince(startedAt) > budget { break }
      let batch = Array(ordered[batchStart ..< min(batchStart + 3, ordered.count)])
      await withTaskGroup(of: SportLeague?.self) { group in
        for league in batch {
          group.addTask {
            await source.probeSectionForLeague(league, learned: learned)
          }
        }
        for await result in group { if let l = result { found.insert(l) } }
      }
    }
    return found
  }

  /// Wraps `FoundationModelScraper.extractGames` in a 10 s timeout. The
  /// on-device LLM on iOS 26 can occasionally stall on first invocation; we
  /// don't want it to block the rest of `fetchAvailableLeagues` indefinitely.
  /// Returns nil on either disabled, timed out, or empty extraction.
  private static func runFoundationModelWithTimeout(
    links: [ScrapedLink], baseURL: URL, pageTitle: String?
  ) async -> [ExtractedGame]? {
    guard FoundationModelScraper.isSupported else { return nil }
    return await withTaskGroup(of: [ExtractedGame]?.self) { group in
      group.addTask {
        await FoundationModelScraper.shared.extractGames(
          from: links, baseURL: baseURL, pageTitle: pageTitle
        )
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? nil
    }
  }

  /// Scrapes the canonical section paths for `league` and returns the league
  /// if any of them contain at least one game/event link that classifies to
  /// `league`. Stops at first hit. ScrapeCache makes subsequent fetchGames
  /// probes free.
  ///
  /// Per-URL timeout is 8 s rather than the WebView default of 20–30 s
  /// because these are speculative probes — three paths per league × 20+
  /// leagues = a lot of wallclock if every URL waits the full timeout. 8 s
  /// is enough for most real responses; sites that take longer (Cloudflare
  /// challenges) get a separate full-budget retry on the homepage itself.
  private func probeSectionForLeague(_ league: SportLeague,
                                     learned: LearnedSportsData.Snapshot?) async -> SportLeague? {
    guard let slug = Self.sectionSlug(for: league) else { return nil }
    for path in ["/live/\(slug)", "/\(slug)", "/sports/\(slug)"] {
      guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { continue }
      let sub = await scrapeLinks(url: url, timeout: 8)
      let hit = sub.contains { link in
        guard isGameLink(link) || isEventLink(link) else { return false }
        return Self.detectLeague(href: link.href, text: link.text, learned: learned) == league
      }
      if hit { return league }
    }
    return nil
  }

  /// Canonical URL slug for a league's section page on streaming sites.
  /// Used by `findSectionURLs` to probe `/live/{slug}`, `/{slug}`, `/sports/{slug}`
  /// even when the homepage doesn't expose those links.
  private static func sectionSlug(for league: SportLeague) -> String? {
    switch league {
    case .nba:           return "nba"
    case .wnba:          return "wnba"
    case .nfl:           return "nfl"
    case .mlb:           return "mlb"
    case .nhl:           return "nhl"
    case .ncaaf:         return "ncaaf"
    case .ncaab:         return "ncaab"
    case .premierLeague: return "premier-league"
    case .laLiga:        return "laliga"
    case .serieA:        return "serie-a"
    case .bundesliga:    return "bundesliga"
    case .ligue1:        return "ligue-1"
    case .eredivisie:    return "eredivisie"
    case .mls:           return "mls"
    case .ligaMx:        return "liga-mx"
    case .championsLeague: return "champions-league"
    case .europaLeague:  return "europa-league"
    case .soccer:        return "soccer"
    case .ufc:           return "ufc"
    case .mma:           return "mma"
    case .boxing:        return "boxing"
    case .wwe:           return "wwe"
    case .f1:            return "f1"
    case .tennis:        return "tennis"
    case .golf:          return "golf"
    case .nascar:        return "nascar"
    case .cricket:       return "cricket"
    case .other:         return nil
    }
  }

  private func buildGames(from links: [ScrapedLink], for league: SportLeague,
                          requireLeagueDetection: Bool,
                          learned: LearnedSportsData.Snapshot? = nil) -> [Game] {
    var seen = Set<String>()
    return links.compactMap { link -> Game? in
      let isMatch = isGameLink(link)
      let isEvt   = !isMatch && isEventLink(link)
      guard isMatch || isEvt,
            let url = URL(string: link.href),
            isSameDomain(url),
            !seen.contains(link.href) else { return nil }

      if requireLeagueDetection {
        let detected = Self.detectLeague(href: link.href, text: link.text, learned: learned)
        if league == .other {
          // ".other" is the catch-all for game links without a recognised league.
          if detected != nil { return nil }
        } else {
          guard detected == league else { return nil }
        }
      }

      seen.insert(link.href)

      // Reject homepage nav anchors that look like games but are really just
      // sport-category labels ("Basketball", "Soccer", etc.).
      if Self.isJustASportName(link.text) { return nil }

      let home: String
      let away: String
      if isEvt {
        home = cleanEventName(from: link.text)
        away = ""
      } else {
        (home, away) = parseTeams(from: link.text, href: link.href)
      }
      if Self.isJustASportName(home) { return nil }

      // Use date from URL if available; combine with time from text or status.
      // Try multiple sources: link text, then link status. Countdowns as last resort.
      var scheduledTime: Date?
      var timeIsKnown = true
      if let urlDate = parseDateFromURL(link.href) {
        let combined = combineDate(urlDate, withTimeFrom: link.text + " " + link.status)
        scheduledTime = combined.0
        timeIsKnown = combined.1
      } else if let t = parseTime(from: link.text) ?? parseTime(from: link.status) {
        scheduledTime = t
      }
      if scheduledTime == nil {
        // Countdown timers like "2h 30m" or "02:30:00" — common on ppv.to
        if !link.status.isEmpty, isCountdown(link.status) {
          scheduledTime = parseCountdown(from: link.status)
        } else if isCountdown(link.text) {
          scheduledTime = parseCountdown(from: link.text)
        }
      }

      let isLive     = detectLive(text: link.text, domStatus: link.status, scheduledTime: scheduledTime)
      let liveStatus = isLive ? parseLiveStatus(domStatus: link.status, linkText: link.text) : nil
      let isPremium  = detectPremium(text: link.text, status: link.status)

      return Game(
        id: link.href,
        homeTeam: home,
        awayTeam: away,
        scheduledTime: scheduledTime,
        timeIsKnown: timeIsKnown,
        isLive: isLive,
        liveStatus: liveStatus,
        isEvent: isEvt,
        isPremium: isPremium,
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

    // Synthetic upcoming-card entry from WebViewScraper's pass 2: the URL is
    // the site's home page + a "#upcoming-N" fragment, with team names in
    // text and a countdown in status. These represent listed games whose
    // actual stream URL isn't ready yet — keep them so they still show up.
    if link.href.contains("#upcoming-"),
       (isCountdown(link.status) || isCountdown(link.text) ||
        link.text.lowercased().contains(" vs ") ||
        link.text.lowercased().contains(" v ") ||
        link.text.lowercased().contains(" @ ")) {
      return true
    }

    let segs = url.pathComponents.filter { $0 != "/" }
    guard segs.count >= 2 else { return false }
    let path = url.path.lowercased()
    let text = link.text.lowercased()

    // Classic "vs" patterns
    let hasVsText    = text.contains(" vs ") || text.contains(" vs. ") || text.contains(" @ ") || text.contains(" v. ")
    let hasVsURL     = path.contains("-vs-") || path.contains("-vs.")
    let hasDOMStatus = !link.status.isEmpty && link.status.count < 60

    // Date-segment pattern: e.g. /live/nba/2026-05-15/phi-pit (ppv.to style)
    let hasDateSegment = segs.contains {
      $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    // Pick the team slug: segment immediately before a numeric ID, or the last
    // non-numeric segment if no ID is present. This avoids treating a section
    // segment like `world-championship-group-b` as a team slug when the real
    // team slug is `norway-slovakia` further along.
    let teamSlug = Self.teamSlug(in: segs)

    let hasTeamSlug: Bool = {
      guard let slug = teamSlug else { return false }
      let words = slug.components(separatedBy: "-")
      let lowerWords = words.map { $0.lowercased() }
      // Reject section-y slugs (championship, group, league, ...)
      if lowerWords.contains(where: { Self.sectionKeywords.contains($0) }) { return false }
      // 4+ hyphen-separated words → concatenated US-team slug
      if words.count >= 4 { return true }
      // 2-word country pair → international match
      if words.count == 2,
         Self.knownCountries.contains(lowerWords[0]),
         Self.knownCountries.contains(lowerWords[1]) {
        return true
      }
      return false
    }()

    return hasVsText || hasVsURL || hasDOMStatus || hasDateSegment || hasTeamSlug
  }

  /// Returns the path segment most likely to be the team slug:
  /// the one immediately before a numeric game-ID segment, or the last
  /// non-numeric segment if no numeric ID exists.
  static func teamSlug(in segs: [String]) -> String? {
    if let numIdx = segs.firstIndex(where: {
      $0.range(of: #"^\d+$"#, options: .regularExpression) != nil
    }), numIdx > 0 {
      return segs[numIdx - 1]
    }
    return segs.last(where: {
      $0.range(of: #"^\d+$"#, options: .regularExpression) == nil
    })
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

  private func sportFromURL(_ href: String) -> SportLeague? {
    guard let url = URL(string: href) else { return nil }
    let segs = url.pathComponents.map { $0.lowercased() }.filter { $0 != "/" && $0 != "live" }
    for seg in segs {
      for (keyword, league) in Self.urlSegmentLeague {
        if seg == keyword { return league }
      }
    }
    return nil
  }

  private func expandAbbreviation(_ code: String, forSport sport: SportLeague?) -> String? {
    let lower = code.lowercased()
    switch sport {
    case .mlb:  return Self.mlbTeams[lower]
    case .nba:  return Self.nbaTeams[lower]
    case .nfl:  return Self.nflTeams[lower]
    case .nhl:  return Self.nhlTeams[lower] ?? Self.internationalTeams[lower]
    case .wnba: return Self.wnbaTeams[lower]
    default:
      return Self.mlbTeams[lower] ?? Self.nbaTeams[lower] ?? Self.nflTeams[lower]
             ?? Self.nhlTeams[lower] ?? Self.wnbaTeams[lower] ?? Self.internationalTeams[lower]
    }
  }

  // Splits "cleveland-cavaliers-detroit-pistons" into ("Cleveland Cavaliers", "Detroit Pistons")
  // by finding the split point where both halves are known team names.
  private func splitTeamSlug(_ slug: String) -> (String, String)? {
    let words = slug.lowercased().components(separatedBy: "-")
    guard words.count >= 4 else { return nil }
    for mid in 1..<words.count {
      let homeLower = words.prefix(mid).joined(separator: " ")
      let awayLower = words.suffix(from: mid).joined(separator: " ")
      if Self.teamLeagueMap[homeLower] != nil && Self.teamLeagueMap[awayLower] != nil {
        let home = words.prefix(mid).map { $0.capitalized }.joined(separator: " ")
        let away = words.suffix(from: mid).map { $0.capitalized }.joined(separator: " ")
        return (home, away)
      }
    }
    // Fallback: even midpoint split
    let mid = words.count / 2
    let home = words.prefix(mid).map { $0.capitalized }.joined(separator: " ")
    let away = words.suffix(from: mid).map { $0.capitalized }.joined(separator: " ")
    return (home, away)
  }

  private func parseTeams(from text: String, href: String) -> (String, String) {
    // URL-first parsing: the URL is canonical when it has a clear pattern.
    // This avoids contamination from messy link text like "Detroit Tigers Apr 15 12:00 AM ET"
    // which would otherwise pollute the away-team name with date/time suffixes.
    if let url = URL(string: href) {
      let segs = url.pathComponents.filter { $0 != "/" }
      let sport = sportFromURL(href)

      // Pattern 1: ppv.to style /live/{sport}/{YYYY-MM-DD}/{abbr1-abbr2}
      if let dateIdx = segs.firstIndex(where: {
        $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
      }), dateIdx + 1 < segs.count {
        let teamSeg = segs[dateIdx + 1]
        let parts = teamSeg.lowercased().components(separatedBy: "-")
        if parts.count == 2 {
          // Try the sport-specific abbreviation table
          if let home = expandAbbreviation(parts[0], forSport: sport),
             let away = expandAbbreviation(parts[1], forSport: sport) {
            return (home, away)
          }
          // Try international country codes (for IIHF, World Cup, etc.)
          if let home = Self.internationalTeams[parts[0]],
             let away = Self.internationalTeams[parts[1]] {
            return (home, away)
          }
          // Fall back to uppercased codes so the user at least sees something
          return (parts[0].uppercased(), parts[1].uppercased())
        }
      }

      // Pattern 2: URL slug containing "-vs-" (streameast, classic sites)
      if let slug = url.pathComponents.last(where: { $0.contains("-vs-") }) {
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

      // Pattern 3: Team slug immediately before numeric ID (buffstreams style).
      //   - 4+ hyphenated words → concatenated US-team slug
      //   - 2 country names → international match (e.g. norway-slovakia)
      if let slug = Self.teamSlug(in: segs) {
        let parts = slug.lowercased().components(separatedBy: "-")
        if parts.count >= 4, let (home, away) = splitTeamSlug(slug) {
          return (home, away)
        }
        if parts.count == 2,
           Self.knownCountries.contains(parts[0]),
           Self.knownCountries.contains(parts[1]) {
          return (parts[0].capitalized, parts[1].capitalized)
        }
      }
    }

    // Fallback: text-based "vs" / "@" parsing (with aggressive cleanup
    // of trailing dates, times, weekdays, status badges, etc.).
    let cleaned = text
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    for separator in [" vs. ", " vs ", " @ ", " v. ", " v "] {
      guard let range = cleaned.range(of: separator, options: .caseInsensitive) else { continue }
      let home = Self.cleanTeamText(String(cleaned[..<range.lowerBound]))
      let away = Self.cleanTeamText(String(cleaned[range.upperBound...]))
      if !home.isEmpty && !away.isEmpty { return (home, away) }
    }

    return (cleaned.isEmpty ? "TBD" : Self.cleanTeamText(cleaned), "TBD")
  }

  /// Strips dates, times, weekdays, status badges, and other trailing noise
  /// from a team-name string so the result is just the team name.
  static func cleanTeamText(_ text: String) -> String {
    var result = text
    let patterns: [String] = [
      #"\s+\d{1,2}:\d{2}\s*[AaPp]?[Mm]?.*$"#,                                   // "7:00 PM ET ..."
      #"\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(uary|ruary|ch|il|e|y|ust|tember|ober|ember)?\b.*$"#,
      #"\s+\d{1,2}(st|nd|rd|th)\b.*$"#,                                          // "15th May ..."
      #"\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun)(day|sday|nesday|rsday|urday)?\b.*$"#,
      #"\s+(Today|Tomorrow|Yesterday|Tonight)\b.*$"#,
      #"\s+LIVE\b.*$"#, #"\s+HD\b.*$"#, #"\s+FHD\b.*$"#, #"\s+4K\b.*$"#,
      #"\s*\|.*$"#,                                                              // pipe-separated tail
      #"\s+\(.*\)$"#,                                                            // trailing parens
      #"\s*\-\s*(live|stream|watch|free)\b.*$"#,
    ]
    for pat in patterns {
      if let r = result.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
        result = String(result[..<r.lowerBound])
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
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

  // MARK: - Date extraction from URL

  private func parseDateFromURL(_ href: String) -> Date? {
    guard let url = URL(string: href) else { return nil }
    let pattern = #"(\d{4}-\d{2}-\d{2})"#
    for seg in url.pathComponents {
      guard seg.range(of: pattern, options: .regularExpression) != nil else { continue }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "America/New_York")!
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.date(from: seg)
    }
    return nil
  }

  // Combine a URL-extracted date with a time parsed from link text.
  // Returns (date, timeWasKnown): the date is always at noon ET when time is unknown
  // (so displayDay correctly says "Today"/"Tomorrow"), and timeIsKnown=false so the
  // UI shows "Upcoming" instead of a misleading "12:00 AM ET".
  private func combineDate(_ date: Date, withTimeFrom text: String) -> (Date, Bool) {
    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    var comps = etCal.dateComponents([.year, .month, .day], from: date)
    if let timeOnly = parseTime(from: text) {
      let timeComps = etCal.dateComponents([.hour, .minute], from: timeOnly)
      comps.hour = timeComps.hour
      comps.minute = timeComps.minute
      comps.second = 0
      return (etCal.date(from: comps) ?? date, true)
    }
    // No time in text — use noon ET so the day label still works
    comps.hour = 12; comps.minute = 0; comps.second = 0
    return (etCal.date(from: comps) ?? date, false)
  }

  // MARK: - Live status parsing

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

  private func detectPremium(text: String, status: String) -> Bool {
    let combined = (text + " " + status).lowercased()
    return Self.premiumKeywords.contains { combined.contains($0) }
  }

  private func detectLive(text: String, domStatus: String, scheduledTime: Date?) -> Bool {
    if !domStatus.isEmpty && isCountdown(domStatus) { return false }
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

  private func isCountdown(_ text: String) -> Bool {
    let s = text.lowercased()
    if (try? NSRegularExpression(pattern: #"\b\d+\s*d(ay)?s?\b"#))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
      return true
    }
    if (try? NSRegularExpression(pattern: #"\b\d+\s*h(r|our)?s?\b"#))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
      let sportsPeriod = s.contains("inning") || s.contains("quarter") || s.contains("period") || s.contains("half")
      if !sportsPeriod { return true }
    }
    if (try? NSRegularExpression(pattern: #"\b\d{1,2}:\d{2}:\d{2}\b"#))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
      return true
    }
    return false
  }

  private func parseCountdown(from text: String) -> Date? {
    let s = text.lowercased()
    var totalSeconds: TimeInterval = 0
    var matched = false

    let patterns: [(String, TimeInterval)] = [
      (#"(\d+)\s*d(ay)?s?"#, 86400),
      (#"(\d+)\s*h(r|our)?s?"#, 3600),
      (#"(\d+)\s*m(in|inute)?s?"#, 60),
    ]
    for (pat, multiplier) in patterns {
      if let regex = try? NSRegularExpression(pattern: pat),
         let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
         let r = Range(m.range(at: 1), in: s),
         let val = Double(s[r]) {
        totalSeconds += val * multiplier
        matched = true
      }
    }

    if !matched,
       let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2}):(\d{2})\b"#),
       let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let rh = Range(m.range(at: 1), in: s),
       let rm = Range(m.range(at: 2), in: s),
       let rs = Range(m.range(at: 3), in: s) {
      let h: TimeInterval = Double(s[rh]) ?? 0
      let mi: TimeInterval = Double(s[rm]) ?? 0
      let sec: TimeInterval = Double(s[rs]) ?? 0
      totalSeconds = h * 3600 + mi * 60 + sec
      matched = true
    }

    guard matched, totalSeconds > 60 else { return nil }
    return Date().addingTimeInterval(totalSeconds)
  }

  private func parseTime(from text: String) -> Date? {
    // 1) Most common: HH:MM AM/PM (with optional timezone like " ET")
    if let date = parseTimeWithAmPm(text) { return date }
    // 2) Shorthand: "7pm", "10 am", "7 PM ET"
    if let date = parseTimeShorthand(text) { return date }
    // 3) 24-hour clock: "19:00", "07:30"
    if let date = parseTime24h(text) { return date }
    return nil
  }

  private func parseTimeWithAmPm(_ text: String) -> Date? {
    let pattern = #"(\d{1,2}:\d{2}\s*[AaPp][Mm](?:\s*[A-Z]{2,3})?)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    var raw = String(text[range])
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces).uppercased()
    for tz in [" ET", " EST", " EDT", " GMT", " UTC", " PT", " CT", " MT", " PST", " CST", " MST"] {
      raw = raw.replacingOccurrences(of: tz, with: "")
    }
    return applyTodayTime(raw, formats: ["h:mm a", "hh:mm a"])
  }

  private func parseTimeShorthand(_ text: String) -> Date? {
    // "7pm", "10 am", "7 PM ET" — hour only, no minutes
    let pattern = #"\b(\d{1,2})\s*([AaPp][Mm])\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let hourRange = Range(match.range(at: 1), in: text),
          let ampmRange = Range(match.range(at: 2), in: text) else { return nil }
    let raw = "\(text[hourRange]):00 \(text[ampmRange])".uppercased()
    return applyTodayTime(raw, formats: ["h:mm a", "hh:mm a"])
  }

  private func parseTime24h(_ text: String) -> Date? {
    // 24-hour clock — strict: must have a digit-colon-digit pattern and the hour
    // value must be 0-23. Reject "1:23" without AM/PM context unless hour > 12.
    let pattern = #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let hRange = Range(match.range(at: 1), in: text),
          let mRange = Range(match.range(at: 2), in: text),
          let h = Int(text[hRange]),
          let m = Int(text[mRange]) else { return nil }
    // Only accept as 24h if hour > 12 (otherwise ambiguous with 12-hour clock
    // without AM/PM, which we don't want to guess).
    guard h > 12, h < 24 else { return nil }
    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    var comps = etCal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = h; comps.minute = m; comps.second = 0
    return etCal.date(from: comps)
  }

  private func applyTodayTime(_ raw: String, formats: [String]) -> Date? {
    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = etTZ
    for format in formats {
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
    var result = await scraper.scrapeWithDiagnostic(url: target, timeout: timeout)

    // DNS-failure fallback: when the WebView reports the host can't be
    // resolved, ask HostFallback to try the same hostname-prefix on a list
    // of common streaming-site TLDs. If a working variant is found, retry
    // the scrape against it and persist the new URL into SourceRegistry so
    // the user's source list shows the actual reachable URL.
    if Self.indicatesUnresolvedHost(result.diagnostic) {
      if let fallback = await HostFallback.shared.tryVariants(of: target) {
        let scraper2 = await MainActor.run { WebViewScraper() }
        let result2 = await scraper2.scrapeWithDiagnostic(url: fallback, timeout: timeout)
        await ScrapeCache.shared.set(result2.links, for: fallback)
        let sid = self.id
        await MainActor.run {
          SourceRegistry.shared.recordScrape(result2.diagnostic, links: result2.links, for: sid)
          // If this is the source's base URL (not a section probe), persist
          // the working host so subsequent launches go straight to it.
          if target == baseURL {
            SourceRegistry.shared.replaceSourceURL(originalID: sid, newURL: fallback)
          }
        }
        return result2.links
      }
    }

    await ScrapeCache.shared.set(result.links, for: target)
    // Record diagnostics so Settings → Source Diagnostics can show finish
    // reason, duration, and the raw link list. Recording happens on every
    // scrape (homepage + section probes); the registry keeps the last 30.
    let sid = self.id
    await MainActor.run {
      SourceRegistry.shared.recordScrape(result.diagnostic, links: result.links, for: sid)
    }
    return result.links
  }

  /// True when a scrape's diagnostic indicates a DNS-level "cannot find host"
  /// — the trigger for `HostFallback`. Matches Foundation's standard error
  /// message and the equivalent text on iOS Simulator.
  private static func indicatesUnresolvedHost(_ d: ScrapeDiagnostic) -> Bool {
    guard d.reason == .provisionalError || d.reason == .navError else { return false }
    let msg = (d.errorMessage ?? "").lowercased()
    return msg.contains("hostname could not be found")
      || msg.contains("a server with the specified hostname")
      || msg.contains("could not connect to the server")
      || msg.contains("the network connection was lost")
  }
}
