import Foundation

/// Resolves the exact game-page URL on a source site the way a person
/// does: read the page, find the link whose URL/text names the teams, and
/// go there. No synthetic clicks, no ad-popup fighting — just match an
/// anchor and load it directly.
///
/// Source-agnostic by construction. It keys off the game's team names and
/// league (universal sports terms), never a hardcoded site, path, or API.
/// If the game isn't on the landing page, it follows the best-matching
/// league/sport section once and looks again — covering the common
/// "homepage → MLB → game" layout without per-site rules.
enum GameURLResolver {
  /// Max league/section pages to follow when the game isn't on the root.
  private static let maxSections = 3

  /// Returns the deep-link game page on `sourceRoot`, or nil if reading the
  /// site didn't surface a confident match (caller falls back to the walk).
  static func resolve(game: Game, sourceRoot: URL, timeout: TimeInterval = 12) async -> URL? {
    let root = rootURL(sourceRoot)
    let rootLinks = await scrape(root, timeout: timeout)
    guard !rootLinks.isEmpty else { return nil }

    if let direct = matchGame(in: rootLinks, game: game, base: root) {
      return direct
    }
    for section in sectionLinks(in: rootLinks, game: game, base: root).prefix(maxSections) {
      let subLinks = await scrape(section, timeout: timeout)
      if let direct = matchGame(in: subLinks, game: game, base: section) {
        return direct
      }
    }
    return nil
  }

  // MARK: - Matching

  /// A link is the game when both teams (or, for solo events, the one team)
  /// appear in its href or text. The URL slug
  /// (`/mlb/san-francisco-giants-chicago-cubs/123`) is the strongest,
  /// least-spammy signal, so href is checked first.
  ///
  /// Each team is matched via its long tokens (full name + nickname words,
  /// ≥4 chars, plain substring) OR its abbreviation (e.g. "wsh"/"ari", 2–3
  /// chars, matched only as a whole word). The abbreviation path is what
  /// lets abbreviation-routed sites — ppv.to's `/live/mlb/2026-06-07/wsh-ari`
  /// — resolve directly instead of bouncing through the synthetic-click walk.
  private static func matchGame(in links: [ScrapedLink], game: Game, base: URL) -> URL? {
    let index = TeamAliasIndex.shared
    guard index.hasTokens(forTeam: game.homeTeam) else { return nil }
    let soloEvent = HomeView.normalizeForMatch(game.awayTeam).isEmpty

    for link in links {
      let key = " " + HomeView.normalizeForMatch(link.href) + " "
      if index.matches(team: game.homeTeam, inPadded: key),
         soloEvent || index.matches(team: game.awayTeam, inPadded: key),
         let url = absolute(link.href, base: base) {
        return url
      }
    }
    for link in links {
      let key = " " + HomeView.normalizeForMatch(link.text) + " "
      if index.matches(team: game.homeTeam, inPadded: key),
         soloEvent || index.matches(team: game.awayTeam, inPadded: key),
         let url = absolute(link.href, base: base) {
        return url
      }
    }
    return nil
  }

  /// League/section links worth following when the game isn't on the root,
  /// best (most specific) first. Matches the league's keywords against the
  /// link's text + href. League keywords are universal sports terms, not
  /// site config.
  private static func sectionLinks(in links: [ScrapedLink], game: Game, base: URL) -> [URL] {
    let keys = leagueKeys(game.league)
    guard !keys.isEmpty else { return [] }
    var scored: [(url: URL, rank: Int)] = []
    var seen = Set<String>()
    for link in links {
      let hay = " " + HomeView.normalizeForMatch(link.text + " " + link.href) + " "
      var rank = Int.max
      for (i, key) in keys.enumerated() where hay.contains(" \(key) ") || hay.contains(key) {
        rank = min(rank, i)
      }
      guard rank != Int.max, let url = absolute(link.href, base: base) else { continue }
      let key = url.absoluteString
      if seen.contains(key) { continue }
      seen.insert(key)
      scored.append((url, rank))
    }
    return scored.sorted { $0.rank < $1.rank }.map(\.url)
  }

  /// Generic league → keyword aliases. Universal sports terminology only;
  /// nothing here is tied to a specific source site.
  private static func leagueKeys(_ league: SportLeague) -> [String] {
    switch league {
    case .nfl: return ["nfl", "football"]
    case .nba: return ["nba", "basketball"]
    case .mlb: return ["mlb", "baseball"]
    case .nhl: return ["nhl", "hockey"]
    case .mma: return ["mma"]
    case .ufc: return ["ufc", "mma"]
    case .boxing: return ["boxing"]
    case .soccer, .premierLeague, .laLiga, .serieA, .bundesliga, .ligue1,
         .eredivisie, .mls, .ligaMx, .championsLeague, .europaLeague,
         .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague:
      return ["soccer", "football"]
    case .f1: return ["f1", "formula", "motor"]
    case .ncaaf: return ["ncaaf", "college", "football"]
    case .ncaab: return ["ncaab", "college", "basketball"]
    case .wnba: return ["wnba", "basketball"]
    case .wwe: return ["wwe", "wrestling"]
    case .tennis: return ["tennis"]
    case .golf: return ["golf"]
    case .nascar: return ["nascar", "motor"]
    case .cricket: return ["cricket"]
    case .iihf: return ["iihf", "hockey"]
    case .other: return []
    }
  }

  // MARK: - Helpers

  private static func absolute(_ href: String, base: URL) -> URL? {
    URL(string: href, relativeTo: base)?.absoluteURL
  }

  static func rootURL(_ url: URL) -> URL {
    var comp = URLComponents()
    comp.scheme = url.scheme ?? "https"
    comp.host = url.host
    comp.port = url.port
    return comp.url ?? url
  }

  /// Renders the page in a headless WKWebView and returns its anchors.
  /// Recovers from a dead host (TLD seizure) via the same HostFallback
  /// used elsewhere, so a `.plus` going down doesn't break resolution.
  private static func scrape(_ url: URL, timeout: TimeInterval) async -> [ScrapedLink] {
    let scraper = await MainActor.run { WebViewScraper() }
    let result = await scraper.scrapeWithDiagnostic(url: url, timeout: timeout)
    if !result.links.isEmpty { return result.links }
    if let fallback = await HostFallback.shared.tryVariants(of: url) {
      let scraper2 = await MainActor.run { WebViewScraper() }
      return await scraper2.scrapeWithDiagnostic(url: fallback, timeout: timeout).links
    }
    return result.links
  }
}
