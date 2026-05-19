import Foundation

// MARK: - Scrape cache

/// 60 s in-memory cache of `WebViewScraper` results keyed by URL. One
/// homepage scrape per source per refresh is all we need; this prevents
/// duplicate scrapes when the orchestrator and a credential prompt both
/// hit the source within the cache window.
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

// MARK: - CustomStreamSource

/// v2.32 rewrite. The aggregator's only job: given today's canonical
/// games, return a `gameID → matchedURL` map for the games this
/// source's homepage links to. Plain substring match on team names;
/// LLM fallback only when zero matches surface from plain matching.
///
/// What this file used to be (2295 lines): a full aggregator-as-truth
/// scraping stack — per-league probing, LLM extraction + enrichment,
/// observed-JSON-API parsing, ESPN reconciliation, country-team
/// disambiguation, parking-page detection, URL pattern matchers.
/// All of it served the pre-v2.23 architecture where aggregators were
/// the source of truth for game listings. After ESPN+TheSportsDB
/// became canonical, that machinery sat doing work no one needed.
/// Stripped in v2.32.
struct CustomStreamSource: StreamSource {
  let name: String
  let baseURL: URL

  var id: String { baseURL.host ?? baseURL.absoluteString }

  /// For each game in `games`, return the URL on this source's homepage
  /// that matches (text or href contains both normalized team names).
  /// Falls back to a single LLM call when plain matching produces zero
  /// hits — the user's "LLM/scraper hybrid" verbatim.
  func matchedGameURLs(amongCanonical games: [Game]) async -> [String: URL] {
    let links = await scrapeLinks()
    guard !links.isEmpty else { return [:] }

    var matches: [String: URL] = [:]
    for game in games {
      if let url = findLink(in: links, matching: game) {
        matches[game.id] = url
      }
    }

    // v2.34: LLM fills gaps. With Pass 1.8 JSON-LD and accessibility-
    // attribute capture in v2.34 WebViewScraper, plain matching covers
    // the common case. The LLM only fires on the unmatched remainder
    // (one call per source per refresh, max), and only when something
    // actually slipped through plain matching.
    let unmatched = games.filter { matches[$0.id] == nil }
    if !unmatched.isEmpty, FoundationModelScraper.isSupported {
      if let llmMatches = await llmFallback(links: links, games: unmatched) {
        for (id, url) in llmMatches where matches[id] == nil {
          matches[id] = url
        }
      }
    }
    return matches
  }

  // MARK: Matching

  /// Plain substring match: both team names (normalized) must appear in
  /// the link's text or href. Solo events (empty awayTeam) match on home
  /// only. Normalization mirrors `HomeView.normalizeForMatch` — diacritic-
  /// fold + lowercase + punctuation-strip.
  private func findLink(in links: [ScrapedLink], matching game: Game) -> URL? {
    let homeKey = HomeView.normalizeForMatch(game.homeTeam)
    let awayKey = HomeView.normalizeForMatch(game.awayTeam)
    guard !homeKey.isEmpty else { return nil }
    for link in links {
      let blob = HomeView.normalizeForMatch(link.text + " " + link.href)
      let hasHome = blob.contains(homeKey)
      let hasAway = awayKey.isEmpty || blob.contains(awayKey)
      if hasHome && hasAway,
         let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL {
        return url
      }
    }
    return nil
  }

  /// LLM fallback: hand the scraped links to FoundationModelScraper and
  /// see if it can map any of them to one of the canonical games.
  /// Bounded at 10 s so a slow LLM doesn't stall the refresh.
  private func llmFallback(links: [ScrapedLink],
                           games: [Game]) async -> [String: URL]? {
    let extracted: [ExtractedGame]? = await withTaskGroup(of: [ExtractedGame]?.self) { group in
      group.addTask {
        await FoundationModelScraper.shared.extractGames(
          from: links, baseURL: baseURL, pageTitle: nil
        )
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner ?? nil
    }
    guard let extracted else { return nil }
    var out: [String: URL] = [:]
    for game in games {
      for cand in extracted {
        if HomeView.matchesTeamPair(
          home: cand.homeTeam,
          away: cand.awayTeam,
          target: game
        ) {
          out[game.id] = cand.pageURL
          break
        }
      }
    }
    return out
  }

  // MARK: Scraping

  /// Loads the source's baseURL in a WKWebView and extracts anchor links.
  /// Handles DNS failure by trying common TLD variants via `HostFallback`.
  /// Cached for 60 s via `ScrapeCache`.
  func scrapeLinks(timeout: TimeInterval = 15) async -> [ScrapedLink] {
    if let cached = await ScrapeCache.shared.get(baseURL) { return cached }
    let scraper = await MainActor.run { WebViewScraper() }
    let result = await scraper.scrapeWithDiagnostic(url: baseURL, timeout: timeout)

    // DNS-failure fallback: try TLD variants.
    if Self.indicatesUnresolvedHost(result.diagnostic) {
      if let fallback = await HostFallback.shared.tryVariants(of: baseURL) {
        let scraper2 = await MainActor.run { WebViewScraper() }
        let result2 = await scraper2.scrapeWithDiagnostic(url: fallback, timeout: timeout)
        await ScrapeCache.shared.set(result2.links, for: fallback)
        let sid = self.id
        await MainActor.run {
          SourceRegistry.shared.recordScrape(result2.diagnostic,
                                             links: result2.links,
                                             for: sid)
          SourceRegistry.shared.replaceSourceURL(originalID: sid, newURL: fallback)
        }
        return result2.links
      }
    }

    await ScrapeCache.shared.set(result.links, for: baseURL)
    let sid = self.id
    await MainActor.run {
      SourceRegistry.shared.recordScrape(result.diagnostic,
                                         links: result.links,
                                         for: sid)
    }
    return result.links
  }

  private static func indicatesUnresolvedHost(_ d: ScrapeDiagnostic) -> Bool {
    guard d.reason == .provisionalError || d.reason == .navError else { return false }
    let msg = (d.errorMessage ?? "").lowercased()
    return msg.contains("hostname could not be found")
        || msg.contains("a server with the specified hostname")
        || msg.contains("could not connect to the server")
        || msg.contains("the network connection was lost")
  }
}
