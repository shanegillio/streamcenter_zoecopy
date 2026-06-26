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
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMGameEntry {
  @Guide(description: "Sport or league name, e.g. NBA, MLB, NHL, Premier League, UFC, F1")
  var league: String

  @Guide(description: "Home team or participant as it appears in the URL or card text. Abbreviations are fine (e.g. TOR, PHI, NYY) — do not expand them.")
  var homeTeam: String

  @Guide(description: "Away team or participant. Empty string for solo events like a fight card, draft, or race.")
  var awayTeam: String

  @Guide(description: "Game date from the URL path in YYYY-MM-DD format. Empty if not determinable.")
  var scheduledDate: String

  @Guide(description: "Start time in HH:MM 24-hour Eastern Time. Empty if not found.")
  var scheduledTime: String

  @Guide(description: "True only when the status explicitly says live, in progress, or shows a score or period indicator.")
  var isLive: Bool

  @Guide(description: "Full absolute URL to the stream or game page for this entry.")
  var pageURL: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct LLMGamesList {
  @Guide(description: "All game or event listings found. Exclude navigation, schedule overviews, standings, news, and account links.")
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

  private static let gameMatchingInstructions = """
  You identify sports game listing links from scraped streaming website data.

  Return every game card — live, upcoming, or countdown-only. A card showing a countdown \
  timer ("2h 30m", "1d 4h") is a valid upcoming game; include it. Output team names exactly \
  as they appear in the URL slug or card text; do not expand abbreviations.

  Skip navigation, schedule overviews, standings, news, login, and account links. For games \
  whose href is a placeholder ("#", "javascript:void"), use the site's section URL. Extract \
  dates from URL path segments (e.g. /2026-05-15/ → scheduledDate "2026-05-15").
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

  // MARK: - Phase 2: game matching

  @available(iOS 26.0, macOS 26.0, *)
  private func matchGames(links: [ScrapedLink], baseURL: URL, structure: SiteStructure?, pageTitle: String?) async -> [ExtractedGame]? {
    let host = (baseURL.scheme ?? "https") + "://" + (baseURL.host ?? "")

    // Pre-filter links using the site structure so the model sees focused,
    // high-signal links rather than a raw 200-entry dump.
    let focused: [ScrapedLink]
    if let s = structure, !s.gameURLPattern.isEmpty || !s.cardClassPattern.isEmpty {
      let urlPat = s.gameURLPattern.lowercased()
      let clsPat = s.cardClassPattern.lowercased()
      let filtered = links.filter { link in
        let hrefMatch = !urlPat.isEmpty && link.href.lowercased().contains(urlPat)
        let classMatch = !clsPat.isEmpty && link.containerClass.lowercased().contains(clsPat)
        return hrefMatch || classMatch
      }
      // If filtering was too aggressive, fall back to the full set.
      focused = filtered.count >= 3 ? filtered : links
    } else {
      focused = links
    }

    // Serialize to compact JSON with containerClass and pathDepth included.
    let serialized: [[String: String]] = focused.prefix(200).compactMap { link in
      guard !link.href.isEmpty, !link.href.hasPrefix("javascript:") else { return nil }
      var href = link.href
      if href.hasPrefix("//") { href = (baseURL.scheme ?? "https") + ":" + href }
      else if href.hasPrefix("/") { href = host + href }
      else if !href.hasPrefix("http") { return nil }
      var entry: [String: String] = ["href": href]
      let txt = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let sts = link.status.trimmingCharacters(in: .whitespacesAndNewlines)
      let cls = link.containerClass.trimmingCharacters(in: .whitespacesAndNewlines)
      let pathDepth = URL(string: href)?.pathComponents.filter { $0 != "/" }.count ?? 0
      if !txt.isEmpty { entry["text"] = txt }
      if !sts.isEmpty { entry["status"] = sts }
      if !cls.isEmpty { entry["class"] = String(cls.prefix(80)) }
      if pathDepth > 0 { entry["depth"] = "\(pathDepth)" }
      return entry
    }
    guard !serialized.isEmpty,
          let jsonData = try? JSONSerialization.data(withJSONObject: serialized),
          let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

    var header = "Site: \(baseURL.absoluteString)"
    if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
       !title.isEmpty, title.count < 200 {
      header += "\nPage title: \(title)"
    }
    if let s = structure, !s.gameURLPattern.isEmpty {
      header += "\nGame pages on this site typically contain '\(s.gameURLPattern)' in the URL."
    }
    let prompt = "\(header)\n\nLinks:\n\(jsonStr)"

    do {
      return try await executeMatchPrompt(prompt)
    } catch {
      if isContextOverflow(error) {
        return await retryWithReducedLinks(focused: focused, baseURL: baseURL, structure: structure, pageTitle: pageTitle, host: host)
      }
      return nil
    }
  }

  @available(iOS 26.0, macOS 26.0, *)
  private func executeMatchPrompt(_ prompt: String) async throws -> [ExtractedGame] {
    let session = LanguageModelSession(instructions: Self.gameMatchingInstructions)
    let response = try await session.respond(to: prompt, generating: LLMGamesList.self)
    return response.content.games.compactMap { entry in
      guard !entry.homeTeam.isEmpty, let url = URL(string: entry.pageURL) else { return nil }
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
  }

  // MARK: - Context overflow retry

  @available(iOS 26.0, macOS 26.0, *)
  private func retryWithReducedLinks(
    focused: [ScrapedLink], baseURL: URL, structure: SiteStructure?,
    pageTitle: String?, host: String
  ) async -> [ExtractedGame]? {
    let urlPat = structure?.gameURLPattern.lowercased() ?? ""
    let clsPat = structure?.cardClassPattern.lowercased() ?? ""

    // Keep only links that look strongly like game pages:
    // path depth ≥ 2, OR a known card class, OR matching the site's URL pattern.
    let reduced = focused.filter { link in
      let depth = URL(string: link.href)?.pathComponents.filter { $0 != "/" }.count ?? 0
      if depth >= 2 { return true }
      let cls = link.containerClass.lowercased()
      let gameCardKeywords = ["match", "game", "event", "card", "live", "fixture"]
      if gameCardKeywords.contains(where: { cls.contains($0) }) { return true }
      if !clsPat.isEmpty && cls.contains(clsPat) { return true }
      if !urlPat.isEmpty && link.href.lowercased().contains(urlPat) { return true }
      return false
    }
    guard !reduced.isEmpty else { return nil }

    let serialized: [[String: String]] = reduced.prefix(80).compactMap { link in
      guard !link.href.isEmpty, !link.href.hasPrefix("javascript:") else { return nil }
      var href = link.href
      if href.hasPrefix("//") { href = (baseURL.scheme ?? "https") + ":" + href }
      else if href.hasPrefix("/") { href = host + href }
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
          let jsonStr = String(data: jsonData, encoding: .utf8) else { return nil }

    var header = "Site: \(baseURL.absoluteString) (reduced)"
    if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      header += "\nTitle: \(title)"
    }
    let prompt = "\(header)\n\nLinks:\n\(jsonStr)"

    do {
      return try await executeMatchPrompt(prompt)
    } catch {
      return nil
    }
  }

  // MARK: - Helpers

  private func isContextOverflow(_ error: Error) -> Bool {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      if let genErr = error as? LanguageModelSession.GenerationError,
         case .exceededContextWindowSize = genErr {
        return true
      }
    }
    #endif
    return false
  }
  #endif
}
