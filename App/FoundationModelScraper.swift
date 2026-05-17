import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Intermediate game representation returned by the on-device model.
// CustomStreamSource converts this to the app's Game model.
struct ExtractedGame {
  let league: String
  let homeTeam: String
  let awayTeam: String      // empty string for solo events
  let scheduledDate: String? // "YYYY-MM-DD"
  let scheduledTime: String? // "HH:MM" 24-h ET
  let isLive: Bool
  let pageURL: URL
}

// MARK: - Generable schema

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMGameEntry {
  @Guide(description: "Sport or league name, e.g. NBA, MLB, NHL, Premier League, IIHF, UFC, F1")
  var league: String

  @Guide(description: "Full official home team name with any abbreviations expanded, e.g. Philadelphia Phillies")
  var homeTeam: String

  @Guide(description: "Full official away team or country name. Empty string for solo events like a draft or fight card.")
  var awayTeam: String

  @Guide(description: "Game date extracted from the URL in YYYY-MM-DD format. Empty string if not determinable.")
  var scheduledDate: String

  @Guide(description: "Game start time in HH:MM 24-hour Eastern Time from visible page text. Empty string if not found.")
  var scheduledTime: String

  @Guide(description: "True only when status text indicates the game is currently live or in progress.")
  var isLive: Bool

  @Guide(description: "Full absolute URL to the individual stream page for this game.")
  var pageURL: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMGamesList {
  @Guide(description: "Every game or event listing found. Exclude navigation, schedule, standings, and account links.")
  var games: [LLMGameEntry]
}

// Enrichment-pass schema. For each candidate game, the model returns a
// verdict that may DROP the entry, CORRECT one or more fields, or KEEP
// it unchanged — backed by the page context (source URL, title, meta
// description). The corrected* fields are empty strings when the entry
// should be left alone; the actor maps empty → nil at the boundary.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMEnrichmentVerdict {
  @Guide(description: "0-based index from the input list this verdict refers to.")
  var index: Int

  @Guide(description: "true to keep the entry, false to drop it from the UI (use for navigation labels, mirror selectors, malformed listings).")
  var keep: Bool

  @Guide(description: "Corrected canonical home team name when the input was ambiguous (e.g., 'United' → 'Manchester United' on a Premier League page). Empty string to leave unchanged.")
  var correctedHome: String

  @Guide(description: "Corrected canonical away team name. Empty string to leave unchanged.")
  var correctedAway: String

  @Guide(description: "Corrected SportLeague raw value when the existing classification is wrong (e.g., 'soccer' → 'premierLeague'). Use one of: nfl, nba, mlb, nhl, mma, ufc, boxing, soccer, premierLeague, laLiga, serieA, bundesliga, ligue1, eredivisie, mls, ligaMx, championsLeague, europaLeague, f1, ncaaf, ncaab, wnba, wwe, tennis, golf, nascar, cricket, other. Empty string to leave unchanged.")
  var correctedLeague: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMEnrichmentList {
  @Guide(description: "Verdict for every input entry, one per index.")
  var verdicts: [LLMEnrichmentVerdict]
}
#endif

// MARK: - Scraper actor

actor FoundationModelScraper {
  static let shared = FoundationModelScraper()

  private var cache: [URL: (games: [ExtractedGame], expiry: Date)] = [:]

  /// Returns true if Apple's on-device Foundation Models are available on this device.
  static var isSupported: Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      return SystemLanguageModel.default.availability == .available
    }
    #endif
    return false
  }

  private static let instructions = """
  You identify sports game listings from links extracted from streaming websites.

  IMPORTANT — include EVERY game listed on the page, including:
  - Upcoming games whose stream link isn't ready yet (their card shows a
    countdown timer like "2h 30m" or "1d 4h" instead of a real status).
  - Games whose anchor href looks like a placeholder ("#", "#upcoming-…",
    "javascript:void(0)") — these are valid upcoming listings. Use the
    site's base URL or the date+league section URL as pageURL for these.
  - Live games with scores and period info.

  The user wants to see ALL listed games even when the actual stream URL
  isn't available yet. Do not filter out cards just because their link is
  a dead placeholder — the team names and countdown alone are enough to
  count as a valid listing.

  Abbreviation reference (expand these to full official names):
  MLB:  PHI=Philadelphia Phillies, PIT=Pittsburgh Pirates, DET=Detroit Tigers, CLE=Cleveland Guardians,
        NYY=New York Yankees, NYM=New York Mets, BOS=Boston Red Sox, ATL=Atlanta Braves,
        LAD=Los Angeles Dodgers, SF=San Francisco Giants, CHC=Chicago Cubs, STL=St. Louis Cardinals,
        HOU=Houston Astros, MIL=Milwaukee Brewers, MIN=Minnesota Twins, COL=Colorado Rockies,
        SD=San Diego Padres, SEA=Seattle Mariners, OAK=Oakland Athletics, TEX=Texas Rangers,
        KC=Kansas City Royals, TB=Tampa Bay Rays, TOR=Toronto Blue Jays, BAL=Baltimore Orioles,
        WSH=Washington Nationals, CIN=Cincinnati Reds, MIA=Miami Marlins, CWS=Chicago White Sox,
        ARI=Arizona Diamondbacks, LAA=Los Angeles Angels
  NBA:  DET=Detroit Pistons, CLE=Cleveland Cavaliers, PHI=Philadelphia 76ers, LAL=Los Angeles Lakers,
        GSW=Golden State Warriors, BOS=Boston Celtics, MIA=Miami Heat, CHI=Chicago Bulls,
        NYK=New York Knicks, BKN=Brooklyn Nets, MIL=Milwaukee Bucks, PHX=Phoenix Suns,
        DAL=Dallas Mavericks, DEN=Denver Nuggets, MEM=Memphis Grizzlies, OKC=Oklahoma City Thunder,
        MIN=Minnesota Timberwolves, SAC=Sacramento Kings, POR=Portland Trail Blazers, UTA=Utah Jazz,
        SAS=San Antonio Spurs, NOP=New Orleans Pelicans, IND=Indiana Pacers, ORL=Orlando Magic,
        WAS=Washington Wizards, TOR=Toronto Raptors, CHA=Charlotte Hornets, ATL=Atlanta Hawks,
        HOU=Houston Rockets, LAC=LA Clippers
  NFL:  PHI=Philadelphia Eagles, PIT=Pittsburgh Steelers, DET=Detroit Lions, CLE=Cleveland Browns,
        NYG=New York Giants, NYJ=New York Jets, NE=New England Patriots, MIA=Miami Dolphins,
        BUF=Buffalo Bills, BAL=Baltimore Ravens, KC=Kansas City Chiefs, LAR=Los Angeles Rams,
        SF=San Francisco 49ers, DAL=Dallas Cowboys, GB=Green Bay Packers, CHI=Chicago Bears,
        MIN=Minnesota Vikings, TB=Tampa Bay Buccaneers, NO=New Orleans Saints, ATL=Atlanta Falcons,
        CAR=Carolina Panthers, SEA=Seattle Seahawks, ARI=Arizona Cardinals, LAC=Los Angeles Chargers,
        DEN=Denver Broncos, LV=Las Vegas Raiders, IND=Indianapolis Colts, HOU=Houston Texans,
        JAX=Jacksonville Jaguars, TEN=Tennessee Titans, CIN=Cincinnati Bengals, WAS=Washington Commanders
  NHL:  DET=Detroit Red Wings, PIT=Pittsburgh Penguins, TOR=Toronto Maple Leafs, BOS=Boston Bruins,
        MTL=Montreal Canadiens, NYR=New York Rangers, NYI=New York Islanders, CHI=Chicago Blackhawks,
        EDM=Edmonton Oilers, COL=Colorado Avalanche, VGK=Vegas Golden Knights, FLA=Florida Panthers,
        TBL=Tampa Bay Lightning, CAR=Carolina Hurricanes, NSH=Nashville Predators, STL=St. Louis Blues,
        DAL=Dallas Stars, WPG=Winnipeg Jets, MIN=Minnesota Wild, VAN=Vancouver Canucks,
        CGY=Calgary Flames, OTT=Ottawa Senators, SEA=Seattle Kraken, SJS=San Jose Sharks,
        NJD=New Jersey Devils, PHI=Philadelphia Flyers, BUF=Buffalo Sabres, ANA=Anaheim Ducks,
        CBJ=Columbus Blue Jackets, WSH=Washington Capitals, LAK=Los Angeles Kings, UTA=Utah Hockey Club
  WNBA: CON=Connecticut Sun, LV=Las Vegas Aces, IND=Indiana Fever, NY=New York Liberty,
        SEA=Seattle Storm, CHI=Chicago Sky, PHX=Phoenix Mercury, MIN=Minnesota Lynx,
        ATL=Atlanta Dream, WAS=Washington Mystics, LA=Los Angeles Sparks, DAL=Dallas Wings
  International: USA=United States, CAN=Canada, RUS=Russia, SWE=Sweden, FIN=Finland,
                 SUI=Switzerland, CZE=Czech Republic, GER=Germany, SVK=Slovakia, LAT=Latvia,
                 DEN=Denmark, NOR=Norway, KAZ=Kazakhstan

  Additional rules:
  - For concatenated team slugs like "cleveland-cavaliers-detroit-pistons", split correctly into
    "Cleveland Cavaliers" (home) and "Detroit Pistons" (away).
  - Extract YYYY-MM-DD dates from URL path segments (e.g. /2026-05-15/ means scheduledDate="2026-05-15").
  - isLive is true only when status contains "live", a score, period info, or "in progress".
    A countdown timer ("2h 30m", "1d", "23:45:12") means UPCOMING, not live.
  - Skip true navigation links: /schedule, /standings, /news, /about, /login, /register, /home.
  - Game/event pages usually have 2+ path segments. EXCEPTION: if a link's status contains a
    countdown timer or its text contains a team-vs-team pattern, include it even if the URL
    looks like a placeholder ("#", "#card-…", or the base URL).
  - When you include a card with a placeholder href, set pageURL to the league section URL
    if you can construct one (e.g. site + "/live/" + league slug), otherwise the site base URL.
  """

  // MARK: - LLM enrichment pass

  /// Public verdict surface for the enrichment pass. Each field is optional
  /// because the model may leave the entry unchanged (`keep == true` and
  /// every corrected* field nil) or modify only a subset.
  struct EnrichmentVerdict: Sendable {
    let index: Int
    let keep: Bool
    let correctedHome: String?
    let correctedAway: String?
    let correctedLeague: String?
  }

  struct PageContext: Sendable {
    let sourceURL: URL
    let pageTitle: String?
    let metaDescription: String?
  }

  /// Asks the on-device LLM to interpret each candidate game in light of
  /// the source page's context, then per entry: keep / drop / correct
  /// fields. Supersedes the v2.17 boolean `validateGames` — the model is
  /// allowed to fix ambiguous team names ("United" → "Manchester United"
  /// on a Premier League aggregator), re-tag wrong leagues, and reject
  /// nonsense, all in one pass. Caller is responsible for applying the
  /// returned corrections.
  ///
  /// Returns all-keep / no-corrections when Foundation Models isn't
  /// available (iOS < 26 / not downloaded) or the call times out.
  func enrich(
    candidates: [(home: String, away: String, league: String, sourceTitle: String?)],
    pageContext: PageContext
  ) async -> [EnrichmentVerdict] {
    guard !candidates.isEmpty else { return [] }
    let defaultVerdicts = candidates.enumerated().map { (i, _) in
      EnrichmentVerdict(index: i, keep: true,
                        correctedHome: nil, correctedAway: nil, correctedLeague: nil)
    }
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *),
       SystemLanguageModel.default.availability == .available {
      return await runEnrich(candidates: candidates, pageContext: pageContext)
        ?? defaultVerdicts
    }
    #endif
    return defaultVerdicts
  }

  #if canImport(FoundationModels)
  @available(iOS 26.0, macOS 26.0, *)
  private func runEnrich(
    candidates: [(home: String, away: String, league: String, sourceTitle: String?)],
    pageContext: PageContext
  ) async -> [EnrichmentVerdict]? {
    // Cap candidates per call: ppv.to can list 200+ streams; the model's
    // useful context is shorter than that. Caller (mapDiscovered) is
    // responsible for prioritising live + soonest-to-start.
    let cap = 60
    let working = Array(candidates.prefix(cap))

    var lines: [String] = []
    for (i, c) in working.enumerated() {
      let pair = c.away.isEmpty ? c.home : "\(c.home) vs \(c.away)"
      var line = "\(i). \"\(pair)\" (current league: \(c.league)"
      if let t = c.sourceTitle, !t.isEmpty, t != pair { line += "; original title: \"\(t)\"" }
      line += ")"
      lines.append(line)
    }
    let body = lines.joined(separator: "\n")

    var contextHeader = "Source URL: \(pageContext.sourceURL.absoluteString)"
    if let t = pageContext.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !t.isEmpty, t.count < 200 {
      contextHeader += "\nPage title: \(t)"
    }
    if let m = pageContext.metaDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
       !m.isEmpty, m.count < 400 {
      contextHeader += "\nMeta description: \(m)"
    }

    let prompt = """
    \(contextHeader)

    Below are candidate sports game listings scraped from the streaming site
    above. For each numbered entry, decide what to do based on the page's
    context (a Premier League aggregator implies "United" means Manchester
    United; an international friendly card means "England" stays as England).

    PER-ENTRY VERDICT:
    - keep=true with no corrections: entry is fine as-is.
    - keep=true with correctedHome/correctedAway: ambiguous or partial team
      names you can canonicalize using the page context. Use the team's
      official full name (e.g. "Manchester United", "Real Madrid",
      "England Cricket"). Leave a field as the empty string to keep it.
    - keep=true with correctedLeague: existing classification is wrong.
      Use the SportLeague raw value (e.g. "premierLeague", "cricket",
      "laLiga"). Empty string to keep.
    - keep=false: drop the entry. Use for navigation labels ("Home",
      "Live TV", "More Sports"), mirror selectors ("Stream 2", "Mirror 1"),
      malformed listings ("Norway vs", "Live"), duplicated teams.

    PRESERVE — don't correct these (they ARE the canonical names):
    - "England Cricket", "India Cricket", etc. — the "Cricket" suffix
      distinguishes the national side from any club of the same country.
    - International soccer national teams like "Norway", "Hungary",
      "Brazil" — when the page is about international competition.

    Be conservative. When in doubt, keep=true with no corrections.
    Return exactly one verdict per input index.

    Entries:
    \(body)
    """

    // 6 s timeout — a bit looser than the v2.17 validateGames cap because
    // enrichment is doing more work per entry (interpretation, not just
    // yes/no). Still tighter than the extractGames cache TTL.
    let result = await withTaskGroup(of: [EnrichmentVerdict]?.self) { group in
      group.addTask {
        do {
          let session = LanguageModelSession(instructions: Self.enrichInstructions)
          let response = try await session.respond(to: prompt, generating: LLMEnrichmentList.self)
          var verdicts = candidates.enumerated().map { (i, _) in
            EnrichmentVerdict(index: i, keep: true,
                              correctedHome: nil, correctedAway: nil, correctedLeague: nil)
          }
          for v in response.content.verdicts where v.index >= 0 && v.index < working.count {
            let trimmedHome   = v.correctedHome.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAway   = v.correctedAway.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLeague = v.correctedLeague.trimmingCharacters(in: .whitespacesAndNewlines)
            verdicts[v.index] = EnrichmentVerdict(
              index: v.index,
              keep: v.keep,
              correctedHome:   trimmedHome.isEmpty   ? nil : trimmedHome,
              correctedAway:   trimmedAway.isEmpty   ? nil : trimmedAway,
              correctedLeague: trimmedLeague.isEmpty ? nil : trimmedLeague
            )
          }
          return verdicts
        } catch {
          return nil
        }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner
    }
    return result
  }

  private static let enrichInstructions = """
  You interpret candidate sports game listings scraped from streaming
  aggregator sites. The site context (URL, page title, meta description)
  comes first, then a numbered list of candidates. For each, you decide
  whether to keep, drop, or correct fields.

  Use the page context to canonicalize ambiguous entries:
  - On a Premier League page, an entry "Everton vs United" likely means
    "Everton vs Manchester United" (correctedAway = "Manchester United").
  - On an international friendly card, "Norway vs Brazil" stays as-is.
  - When the title says "Watch IPL", treat T20 cricket franchise entries
    as league=cricket.

  Do NOT invent games that aren't in the candidate list. Do NOT remove
  the "Cricket" suffix from national cricket sides ("England Cricket").

  When uncertain, return keep=true with no corrections — never make up
  team names from thin air. Empty-string fields mean "leave unchanged".

  Return exactly one verdict per input index.
  """
  #endif

  func extractGames(from links: [ScrapedLink], baseURL: URL, pageTitle: String? = nil) async -> [ExtractedGame]? {
    if let cached = cache[baseURL], Date() < cached.expiry { return cached.games }
    guard !links.isEmpty else { return nil }

    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      return await runWithFoundationModel(links: links, baseURL: baseURL, pageTitle: pageTitle)
    }
    #endif
    return nil
  }

  #if canImport(FoundationModels)
  @available(iOS 26.0, macOS 26.0, *)
  private func runWithFoundationModel(links: [ScrapedLink], baseURL: URL, pageTitle: String?) async -> [ExtractedGame]? {
    guard SystemLanguageModel.default.availability == .available else { return nil }

    // Resolve relative hrefs and build compact JSON for the model.
    // Cap at 200 (was 150) so upcoming-card synthetic entries from the second
    // scraper pass have room alongside the homepage anchors.
    let host = (baseURL.scheme ?? "https") + "://" + (baseURL.host ?? "")
    let serialized: [[String: String]] = links.prefix(200).compactMap { link in
      guard !link.href.isEmpty, !link.href.hasPrefix("javascript:") else { return nil }
      var href = link.href
      if href.hasPrefix("//") { href = (baseURL.scheme ?? "https") + ":" + href }
      else if href.hasPrefix("/")  { href = host + href }
      else if !href.hasPrefix("http") { return nil }
      var entry: [String: String] = ["href": href]
      let txt = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let sts = link.status.trimmingCharacters(in: .whitespacesAndNewlines)
      if !txt.isEmpty { entry["text"] = txt }
      if !sts.isEmpty { entry["status"] = sts }
      return entry
    }
    guard !serialized.isEmpty,
          let jsonData = try? JSONSerialization.data(withJSONObject: serialized),
          let jsonStr  = String(data: jsonData, encoding: .utf8) else { return nil }

    // Include the page title when available — gives the model another signal
    // for classifying the site (e.g. "NTVSTREAM - Watch Live Sports..." vs
    // "Redirecting...") and for resolving ambiguous category words.
    var promptHeader = "Site URL: \(baseURL.absoluteString)"
    if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty, title.count < 200 {
      promptHeader += "\nPage title: \(title)"
    }
    let prompt = """
    \(promptHeader)

    Links extracted from this sports streaming site:
    \(jsonStr)
    """

    do {
      let session = LanguageModelSession(instructions: Self.instructions)
      let response = try await session.respond(to: prompt, generating: LLMGamesList.self)
      let games: [ExtractedGame] = response.content.games.compactMap { entry in
        guard !entry.homeTeam.isEmpty,
              let url = URL(string: entry.pageURL) else { return nil }
        return ExtractedGame(
          league:        entry.league,
          homeTeam:      entry.homeTeam,
          awayTeam:      entry.awayTeam,
          scheduledDate: entry.scheduledDate.isEmpty ? nil : entry.scheduledDate,
          scheduledTime: entry.scheduledTime.isEmpty ? nil : entry.scheduledTime,
          isLive:        entry.isLive,
          pageURL:       url
        )
      }
      cache[baseURL] = (games, Date().addingTimeInterval(60))
      return games
    } catch {
      return nil
    }
  }
  #endif
}
