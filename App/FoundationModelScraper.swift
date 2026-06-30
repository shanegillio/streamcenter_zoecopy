import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - ExtractedGame

// Intermediate game representation returned by the on-device model.
// CustomStreamSource converts this to the app's Game model.
struct ExtractedGame {
  let league: String
  let homeTeam: String
  let awayTeam: String
  let scheduledDate: String?
  let scheduledTime: String?
  let isLive: Bool
  let pageURL: URL
}

// MARK: - SiteStructure

// Cached per-domain understanding of a streaming site's URL and card patterns.
// Stored in FoundationModelScraper's long-lived cache so the profiling LLM call
// only fires once per domain per app session.
struct SiteStructure {
  let gameURLPattern: String   // e.g. "/live/", "/watch/", "/nfl/"
  let cardClassPattern: String // e.g. "match-card", "event-item"
  let usesAbbreviations: Bool  // true when URLs use "bos-nyy" style slugs
}

// MARK: - Generable schema

#if canImport(FoundationModels)
// Guides are deliberately terse: the on-device window is only ~4096 tokens
// shared between the injected schema, the prompt, and the generated output, so
// verbose descriptions directly cost extraction headroom.
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMGameEntry {
  @Guide(description: "League, e.g. NBA, MLB, NHL, EPL, UFC, F1")
  var league: String

  @Guide(description: "Home team/participant verbatim from the link. Keep abbreviations.")
  var homeTeam: String

  @Guide(description: "Away team verbatim. Empty for solo events.")
  var awayTeam: String

  @Guide(description: "Date YYYY-MM-DD only if present in the link's URL/text, else empty.")
  var scheduledDate: String

  @Guide(description: "Start time HH:MM 24h ET only if present in the link, else empty.")
  var scheduledTime: String

  @Guide(description: "True if the status shows live, in progress, or a score.")
  var isLive: Bool

  @Guide(description: "The 'u' value of this link, copied exactly.")
  var pageURL: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMGamesList {
  @Guide(description: "Game/event listings only. Skip nav, standings, news, login, account.")
  var games: [LLMGameEntry]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMSiteProfile {
  @Guide(description: "URL path substring common to game/event pages on this site, e.g. '/live/', '/watch/', '/nhl/2026'. Empty if no clear pattern.")
  var gameURLPattern: String

  @Guide(description: "CSS class fragment found on game listing card containers, e.g. 'match-card', 'event-item', 'game'. Empty if no clear pattern.")
  var cardClassPattern: String

  @Guide(description: "True if the site routes game pages by team abbreviation in the URL (e.g. /mlb/bos-nyy/) rather than full team names.")
  var usesAbbreviations: Bool
}
#endif

// MARK: - Scraper actor

actor FoundationModelScraper {
  static let shared = FoundationModelScraper()

  // 60-second per-source game-list cache.
  private var gameCache: [URL: (games: [ExtractedGame], expiry: Date)] = [:]

  // Per-domain site structure cache. No expiry — site URL patterns change rarely.
  // Persists for the app session so the profiling call only fires once per domain.
  private var siteStructureCache: [String: SiteStructure] = [:]

  /// Returns true if Apple's on-device Foundation Models are available on this device.
  static var isSupported: Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      return SystemLanguageModel.default.availability == .available
    }
    #endif
    return false
  }

  // MARK: - Instructions

  // Concise per Apple's guidance (1–3 paragraphs). Abbreviation expansion is
  // handled in Swift post-processing via TeamAliasIndex, not in the model prompt.

  private static let siteProfilingInstructions = """
  You analyze a sample of links scraped from a sports streaming website to understand its structure.

  Identify: (1) the URL path substring common to game or event pages, (2) the CSS class fragment \
  on game listing card containers, (3) whether the site uses team abbreviations in URLs. \
  Base your answer only on the evidence in the provided link data.
  """

  // Grounding is critical for this small model. Without "only what's in the
  // link / never invent / one game per link" it (a) fabricates famous matchups
  // for section links carrying no team data, and (b) loops, repeating one game
  // until it overflows the window. Swift post-validation (`teamGrounded`)
  // re-checks every result, but cutting it at the source improves yield/speed.
  private static let gameMatchingInstructions = """
  You convert scraped link data into a list of sports games. Work ONLY from the \
  text and URL of each provided link — never use outside knowledge, and never \
  invent teams, dates, or matchups. Emit at most one game per link and never \
  repeat the same game. Copy team names verbatim from the link; keep \
  abbreviations as-is. Include live, upcoming, and countdown games. If a link \
  has no clear team or event in its own text/URL (e.g. a section link like \
  "NFL" → /nflstreams2), skip it.
  """

  // MARK: - Public API

  func extractGames(from links: [ScrapedLink], baseURL: URL, pageTitle: String? = nil) async -> [ExtractedGame]? {
    if let cached = gameCache[baseURL], Date() < cached.expiry { return cached.games }
    guard !links.isEmpty else { return nil }

    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      return await runWithFoundationModel(links: links, baseURL: baseURL, pageTitle: pageTitle)
    }
    #endif
    return nil
  }

  /// Returns the cached site structure for a domain if available.
  /// Used by GameURLResolver to prioritize section links without re-profiling.
  func cachedSiteStructure(forDomain domain: String) -> SiteStructure? {
    siteStructureCache[domain]
  }

  // MARK: - Two-phase implementation

  #if canImport(FoundationModels)
  @available(iOS 26.0, macOS 26.0, *)
  private func runWithFoundationModel(links: [ScrapedLink], baseURL: URL, pageTitle: String?) async -> [ExtractedGame]? {
    guard SystemLanguageModel.default.availability == .available else { return nil }
    let domain = baseURL.host ?? baseURL.absoluteString

    // Phase 1: Profile the site (once per domain per app session).
    // If the profile call fails, matchGames proceeds with nil profile (uses all links).
    let structure: SiteStructure?
    if let cached = siteStructureCache[domain] {
      structure = cached
    } else if let fresh = await buildSiteProfile(links: links, domain: domain, pageTitle: pageTitle) {
      siteStructureCache[domain] = fresh
      structure = fresh
    } else {
      structure = nil
    }

    // Phase 2: Match games with pre-filtered links.
    let games = await matchGames(links: links, baseURL: baseURL, structure: structure, pageTitle: pageTitle)
    if let games {
      gameCache[baseURL] = (games, Date().addingTimeInterval(60))
    }
    return games
  }

  // MARK: - Phase 1: site profiling

  @available(iOS 26.0, macOS 26.0, *)
  private func buildSiteProfile(links: [ScrapedLink], domain: String, pageTitle: String?) async -> SiteStructure? {
    // Feed a 60-link sample so the model can recognize URL and class patterns.
    let sample: [[String: String]] = links.prefix(60).compactMap { link -> [String: String]? in
      guard !link.href.isEmpty else { return nil }
      var e: [String: String] = ["href": link.href]
      let cls = link.containerClass.trimmingCharacters(in: .whitespacesAndNewlines)
      if !cls.isEmpty { e["class"] = String(cls.prefix(80)) }
      let txt = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !txt.isEmpty { e["text"] = String(txt.prefix(80)) }
      return e
    }
    guard !sample.isEmpty,
          let jsonData = try? JSONSerialization.data(withJSONObject: sample),
          let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

    var prompt = "Site: \(domain)"
    if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty, title.count < 150 {
      prompt += "\nTitle: \(title)"
    }
    prompt += "\n\nSample links:\n\(jsonStr)"

    do {
      let session = LanguageModelSession(instructions: Self.siteProfilingInstructions)
      let response = try await session.respond(to: prompt, generating: LLMSiteProfile.self)
      let p = response.content
      return SiteStructure(
        gameURLPattern: p.gameURLPattern,
        cardClassPattern: p.cardClassPattern,
        usesAbbreviations: p.usesAbbreviations
      )
    } catch {
      return nil
    }
  }

  // MARK: - Phase 2: game matching (chunked + grounded)

  // The on-device window is ~4096 tokens shared between input and output. A
  // single 200-link call always overflowed — and when it didn't, the model
  // looped/hallucinated. Instead we send small batches, let each response
  // complete (no token cap, which would truncate the JSON and lose the chunk),
  // and validate every result against its source link in Swift.
  private static let matchChunkSize = 8

  @available(iOS 26.0, macOS 26.0, *)
  private func matchGames(links: [ScrapedLink], baseURL: URL, structure: SiteStructure?, pageTitle: String?) async -> [ExtractedGame]? {
    let host = (baseURL.scheme ?? "https") + "://" + (baseURL.host ?? "")
    let baseNoSlash = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    // Cheap, conservative Swift-side junk filter (no model call). The model is
    // the real classifier, so this only drops things that are never games:
    // the homepage self-link, javascript hrefs, and obvious info pages.
    let junkPathTokens = ["/blog", "/news", "/about", "/contact", "/privacy",
                          "/terms", "/dmca", "/login", "/register", "/signup",
                          "/account", "/faq", "/tag/"]
    var seenHref = Set<String>()
    let candidates: [ScrapedLink] = links.compactMap { link in
      var href = link.href
      if href.hasPrefix("//") { href = (baseURL.scheme ?? "https") + ":" + href }
      else if href.hasPrefix("/") { href = host + href }
      guard href.hasPrefix("http"), !href.hasPrefix("javascript:") else { return nil }
      let lower = href.lowercased()
      if junkPathTokens.contains(where: { lower.contains($0) }) { return nil }
      if href.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == baseNoSlash { return nil }
      guard seenHref.insert(href).inserted else { return nil }
      return ScrapedLink(href: href, text: link.text, status: link.status, containerClass: link.containerClass)
    }
    guard !candidates.isEmpty else { return nil }

    // Chunk, classify, merge, dedupe across chunks by (URL, matchup).
    var games: [ExtractedGame] = []
    var seenGame = Set<String>()
    var index = 0
    while index < candidates.count {
      let chunk = Array(candidates[index..<min(index + Self.matchChunkSize, candidates.count)])
      index += Self.matchChunkSize
      for g in await matchChunk(chunk, baseURL: baseURL, host: host) {
        let key = g.pageURL.absoluteString + "|" + g.homeTeam.lowercased() + "|" + g.awayTeam.lowercased()
        if seenGame.insert(key).inserted { games.append(g) }
      }
    }
    return games.isEmpty ? nil : games
  }

  /// Classify one batch. Sends compact entries (short keys, path-only `u`),
  /// omits the schema from the prompt to save tokens, and validates every
  /// returned game against its source link's own text+URL so fabricated
  /// matchups and loop-duplicates are discarded.
  @available(iOS 26.0, macOS 26.0, *)
  private func matchChunk(_ links: [ScrapedLink], baseURL: URL, host: String) async -> [ExtractedGame] {
    var resolved: [String: String] = [:]   // key (path) → absolute URL
    var haystack: [String: String] = [:]    // key → lowercased text+URL
    let serialized: [[String: String]] = links.map { link in
      let abs = link.href
      let u = abs.hasPrefix(host) ? String(abs.dropFirst(host.count)) : abs
      let key = u.isEmpty ? "/" : u
      resolved[key] = abs
      haystack[key] = (link.text + " " + abs).lowercased()
      var e: [String: String] = ["u": key]
      let txt = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let sts = link.status.trimmingCharacters(in: .whitespacesAndNewlines)
      if !txt.isEmpty { e["t"] = String(txt.prefix(80)) }
      if !sts.isEmpty { e["s"] = String(sts.prefix(30)) }
      return e
    }
    guard !serialized.isEmpty,
          let jsonData = try? JSONSerialization.data(withJSONObject: serialized),
          let jsonStr = String(data: jsonData, encoding: .utf8) else { return [] }

    let prompt = "Host: \(host)\nLinks:\n\(jsonStr)"
    do {
      let session = LanguageModelSession(instructions: Self.gameMatchingInstructions)
      // temperature 0 (greedy): the small model otherwise varies wildly run to
      // run — sometimes looping into a 90s response that dedupes down to a
      // couple games. Greedy keeps extraction stable (~7–8 games, ~13s here).
      let response = try await session.respond(
        to: prompt,
        generating: LLMGamesList.self,
        includeSchemaInPrompt: false,
        options: GenerationOptions(temperature: 0)
      )
      return response.content.games.compactMap { entry -> ExtractedGame? in
        guard !entry.homeTeam.isEmpty else { return nil }
        // home == away is never a real matchup (the model emits this for
        // duplicated card text, e.g. a "multi-stream" tile).
        if !entry.awayTeam.isEmpty,
           entry.homeTeam.caseInsensitiveCompare(entry.awayTeam) == .orderedSame { return nil }
        let key = entry.pageURL.hasPrefix(host) ? String(entry.pageURL.dropFirst(host.count)) : entry.pageURL
        let absStr = resolved[key] ?? resolved["/" + key]
          ?? (entry.pageURL.hasPrefix("http") ? entry.pageURL : host + entry.pageURL)
        guard let url = URL(string: absStr) else { return nil }
        // Grounding: home (and away, if present) must appear in the source
        // link's own text/URL. Kills hallucinated matchups + recycled-URL loops.
        let hay = haystack[key] ?? haystack["/" + key] ?? ""
        guard !hay.isEmpty, Self.teamGrounded(entry.homeTeam, in: hay),
              entry.awayTeam.isEmpty || Self.teamGrounded(entry.awayTeam, in: hay) else { return nil }
        // Date guard: keep the model's date only if it actually appears in the
        // link (the model otherwise invents plausible-looking dates).
        let date: String? = {
          let d = entry.scheduledDate.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !d.isEmpty, hay.contains(d.lowercased()) else { return nil }
          return d
        }()
        return ExtractedGame(
          league:        entry.league,
          homeTeam:      entry.homeTeam,
          awayTeam:      entry.awayTeam,
          scheduledDate: date,
          scheduledTime: entry.scheduledTime.isEmpty ? nil : entry.scheduledTime,
          isLive:        entry.isLive,
          pageURL:       url
        )
      }
    } catch {
      return []
    }
  }

  /// True if a meaningful token of `team` appears in `haystack` (the source
  /// link's lowercased text+URL). Tolerant of slug hyphenation: any word ≥3
  /// chars from the team name counts; very short names match as a substring.
  private static func teamGrounded(_ team: String, in haystack: String) -> Bool {
    let normalized = haystack.replacingOccurrences(of: "-", with: " ")
    let words = team.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 3 }
    if words.isEmpty { return normalized.contains(team.lowercased()) }
    return words.contains { normalized.contains($0) }
  }
  #endif
}
