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
  /// When the homepage yields nothing, follows up to 2 "matches/live/
  /// schedule" section links in case games live on a subpage (e.g. ntv.cx
  /// whose homepage is a server-selector; games are at /matches/kobra).
  /// Falls back to a single LLM call when plain matching produces zero hits.
  func matchedGameURLs(amongCanonical games: [Game]) async -> [String: URL] {
    let rootLinks = await scrapeLinks()
    guard !rootLinks.isEmpty else { return [:] }

    var allLinks = rootLinks
    var matches: [String: URL] = [:]
    for game in games {
      if let url = findLink(in: allLinks, matching: game) {
        matches[game.id] = url
      }
    }

    // If nothing matched on the homepage, follow up to 2 "section" links
    // (paths containing matches/live/schedule/fixtures) and merge their
    // scraped links. Runs only when the homepage was genuinely empty of
    // game links — no extra latency for sites that work normally.
    if matches.isEmpty {
      let sections = Array(sectionURLs(in: rootLinks).prefix(2))
      if !sections.isEmpty {
        let extra = await withTaskGroup(of: [ScrapedLink].self) { group in
          for url in sections {
            group.addTask {
              let s = await MainActor.run { WebViewScraper() }
              return await s.scrapeWithDiagnostic(url: url, timeout: 10).links
            }
          }
          var out: [ScrapedLink] = []
          for await batch in group { out.append(contentsOf: batch) }
          return out
        }
        allLinks.append(contentsOf: extra)
        for game in games {
          if let url = findLink(in: allLinks, matching: game) {
            matches[game.id] = url
          }
        }
      }
    }

    // LLM fills remaining gaps. Fires at most once per source per refresh.
    let unmatched = games.filter { matches[$0.id] == nil }
    if !unmatched.isEmpty, FoundationModelScraper.isSupported {
      if let llmMatches = await llmFallback(links: allLinks, games: unmatched) {
        for (id, url) in llmMatches where matches[id] == nil {
          matches[id] = url
        }
      }
    }
    return matches
  }

  /// Returns same-domain links from `rootLinks` whose path or text contains
  /// a "matches/live/schedule/fixtures" keyword — these are candidate
  /// game-listing subpages when the homepage itself has no game links.
  private func sectionURLs(in rootLinks: [ScrapedLink]) -> [URL] {
    let keywords = ["matches", "live", "schedule", "fixtures", "streams"]
    var seen = Set<String>()
    var result: [URL] = []
    for link in rootLinks {
      guard !link.href.isEmpty, link.href != "/" else { continue }
      let hay = link.href.lowercased() + " " + link.text.lowercased()
      guard keywords.contains(where: { hay.contains($0) }) else { continue }
      guard let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL,
            url.host == baseURL.host else { continue }
      let key = url.absoluteString
      guard !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(url)
    }
    return result
  }

  // MARK: Matching

  /// Match a link to a game using TeamAliasIndex — handles both full-name
  /// slugs (buffstreams.plus: `/mlb/houston-astros-detroit-tigers/123`) and
  /// abbreviation-routed URLs (ppv.to: `/live/mlb/2026-06-07/wsh-ari`).
  /// Checks href first (URL slug is the strongest signal), then link text.
  /// Falls back to plain substring when neither team is in the index.
  private func findLink(in links: [ScrapedLink], matching game: Game) -> URL? {
    let index = TeamAliasIndex.shared
    let soloEvent = HomeView.normalizeForMatch(game.awayTeam).isEmpty
    let useIndex = index.hasTokens(forTeam: game.homeTeam) &&
                   (soloEvent || index.hasTokens(forTeam: game.awayTeam))

    if useIndex {
      // href first — URL slugs are the most reliable signal.
      for link in links {
        let key = " " + HomeView.normalizeForMatch(link.href) + " "
        if index.matches(team: game.homeTeam, inPadded: key),
           soloEvent || index.matches(team: game.awayTeam, inPadded: key),
           let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL {
          return url
        }
      }
      // link text second.
      for link in links {
        let key = " " + HomeView.normalizeForMatch(link.text) + " "
        if index.matches(team: game.homeTeam, inPadded: key),
           soloEvent || index.matches(team: game.awayTeam, inPadded: key),
           let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL {
          return url
        }
      }
      return nil
    }

    // Plain substring fallback for teams not in the database.
    let homeKey = HomeView.normalizeForMatch(game.homeTeam)
    let awayKey = HomeView.normalizeForMatch(game.awayTeam)
    guard !homeKey.isEmpty else { return nil }
    for link in links {
      let blob = HomeView.normalizeForMatch(link.text + " " + link.href)
      if blob.contains(homeKey), awayKey.isEmpty || blob.contains(awayKey),
         let url = URL(string: link.href, relativeTo: baseURL)?.absoluteURL {
        return url
      }
    }
    return nil
  }

  /// LLM fallback: hand the scraped links to FoundationModelScraper and
  /// see if it can map any of them to one of the canonical games.
  /// Bounded at 12 s so a slow LLM doesn't stall the refresh.
  private func llmFallback(links: [ScrapedLink],
                           games: [Game]) async -> [String: URL]? {
    let extracted: [ExtractedGame]? = await withTaskGroup(of: [ExtractedGame]?.self) { group in
      group.addTask {
        await FoundationModelScraper.shared.extractGames(
          from: links, baseURL: baseURL, pageTitle: nil
        )
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner ?? nil
    }
    guard let extracted else { return nil }
    var out: [String: URL] = [:]
    for game in games {
      for cand in extracted where out[game.id] == nil {
        if llmCandidateMatchesGame(cand, game) {
          out[game.id] = cand.pageURL
        }
      }
    }
    return out
  }

  /// Matches a model-extracted candidate to a canonical game using TeamAliasIndex
  /// so abbreviated outputs like "TOR"/"PHI" resolve correctly alongside full names.
  /// This is strictly more permissive than the former matchesTeamPair which required
  /// the model to have already expanded abbreviations.
  private func llmCandidateMatchesGame(_ cand: ExtractedGame, _ game: Game) -> Bool {
    let index = TeamAliasIndex.shared
    let soloEvent = HomeView.normalizeForMatch(game.awayTeam).isEmpty
    let homeHay = " " + HomeView.normalizeForMatch(cand.homeTeam) + " "
    let awayHay = " " + HomeView.normalizeForMatch(cand.awayTeam) + " "

    let candHomeIsGameHome = index.matches(team: game.homeTeam, inPadded: homeHay)
    let candHomeIsGameAway = !soloEvent && index.matches(team: game.awayTeam, inPadded: homeHay)
    let candAwayIsGameHome = index.matches(team: game.homeTeam, inPadded: awayHay)
    let candAwayIsGameAway = !soloEvent && index.matches(team: game.awayTeam, inPadded: awayHay)

    if soloEvent { return candHomeIsGameHome || candHomeIsGameAway }
    // Accept both orderings (some sites list home/away differently)
    return (candHomeIsGameHome && candAwayIsGameAway) ||
           (candHomeIsGameAway && candAwayIsGameHome)
  }

  // MARK: Scraping

  /// Loads the source's baseURL in a WKWebView and extracts anchor links.
  /// Also fetches any JSON API endpoints the page's JS called during load
  /// (captured by WebViewScraper's XHR shim) and extracts game-like entries
  /// from their responses — this picks up SPA sources like ppv.to whose
  /// game data arrives via XHR rather than being present in the initial HTML.
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
        let apiLinks = await Self.fetchAPILinks(from: result2.diagnostic.observedAPIUrls)
        let allLinks = result2.links + apiLinks
        await ScrapeCache.shared.set(allLinks, for: fallback)
        let sid = self.id
        await MainActor.run {
          SourceRegistry.shared.recordScrape(result2.diagnostic,
                                             links: allLinks,
                                             for: sid)
          SourceRegistry.shared.replaceSourceURL(originalID: sid, newURL: fallback)
        }
        return allLinks
      }
    }

    let apiLinks = await Self.fetchAPILinks(from: result.diagnostic.observedAPIUrls)
    let allLinks = result.links + apiLinks
    await ScrapeCache.shared.set(allLinks, for: baseURL)
    let sid = self.id
    await MainActor.run {
      SourceRegistry.shared.recordScrape(result.diagnostic,
                                         links: allLinks,
                                         for: sid)
    }
    return allLinks
  }

  /// Fetches up to 5 of the API URLs observed during the WebViewScraper run,
  /// parses their JSON, and extracts any game-like entries (objects with a
  /// "name" field containing " vs " and a URL-like field such as "iframe",
  /// "url", or "href"). Works for any SPA that loads game data via a JSON
  /// API — no site-specific code.
  private static func fetchAPILinks(from apiURLs: [URL]) async -> [ScrapedLink] {
    guard !apiURLs.isEmpty else { return [] }
    return await withTaskGroup(of: [ScrapedLink].self) { group in
      for url in apiURLs.prefix(5) {
        group.addTask {
          guard let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
          var links: [ScrapedLink] = []
          extractGameLinksFromJSON(json, into: &links)
          return links
        }
      }
      var out: [ScrapedLink] = []
      for await batch in group { out.append(contentsOf: batch) }
      return out
    }
  }

  /// Recursively walks any JSON value looking for objects whose "name" (or
  /// similar) field contains " vs" and also has an HTTP URL field (iframe,
  /// url, href, …). Depth-first so nested arrays (e.g. ppv.to's
  /// streams→category→streams→game structure) are fully traversed.
  private static func extractGameLinksFromJSON(_ value: Any, into results: inout [ScrapedLink]) {
    if let array = value as? [Any] {
      for item in array { extractGameLinksFromJSON(item, into: &results) }
    } else if let dict = value as? [String: Any] {
      let nameKeys = ["name", "title", "game", "event", "match"]
      let urlKeys  = ["iframe", "url", "href", "stream_url", "embed",
                      "link", "source", "video_url", "stream"]
      if let name = nameKeys.compactMap({ dict[$0] as? String }).first,
         name.contains(" vs") {
        if let url = urlKeys.compactMap({ dict[$0] as? String })
                            .first(where: { $0.hasPrefix("http") }) {
          results.append(ScrapedLink(href: url, text: name, status: "", containerClass: ""))
        }
      }
      for val in dict.values { extractGameLinksFromJSON(val, into: &results) }
    }
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
