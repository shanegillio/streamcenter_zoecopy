import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `scrape-cli --llm <URL>`
///
/// The missing feedback loop: scrapes a page (same WebKit + extraction JS as
/// `--full` / the iOS app), then runs the **on-device Foundation Model** over
/// the resulting links using the exact two-phase pipeline from
/// `App/FoundationModelScraper.swift` (site profiling → game matching) with the
/// identical instructions and @Generable schema.
///
/// Output reports, in order:
///   1. model availability on this machine,
///   2. raw scraped-link count,
///   3. the inferred SiteStructure (phase 1),
///   4. how many links survived structural pre-filtering,
///   5. every game the model extracted (phase 2),
///   6. wall-clock timings for each phase.
///
/// === KEEP THE PROMPTS / SCHEMA IN SYNC WITH App/FoundationModelScraper.swift ===
/// When you change a @Guide string, an instructions block, or the pre-filter
/// here and confirm it improves extraction, port the same change back to the
/// app file in the same commit.

enum LLMScrapeCLI {
  struct Result: Encodable {
    let baseURL: String
    let modelAvailable: Bool
    let modelStatus: String
    let scrapeReason: String
    let rawLinkCount: Int
    let profile: Profile?
    let focusedLinkCount: Int
    let games: [Game]
    let scrapeMs: Int
    let profileMs: Int
    let matchMs: Int
  }
  struct Profile: Encodable {
    let gameURLPattern: String
    let cardClassPattern: String
    let usesAbbreviations: Bool
  }
  struct Game: Encodable {
    let league: String
    let homeTeam: String
    let awayTeam: String
    let scheduledDate: String?
    let scheduledTime: String?
    let isLive: Bool
    let pageURL: String
  }

  static func run(baseURL: URL, debounce: TimeInterval, clickDelay: TimeInterval, timeout: TimeInterval) async -> Result {
    // 1) Scrape (reuse MacScraper so links match what --full produces).
    let scrapeStart = Date()
    let scraper = await MacScraper(url: baseURL, debounce: debounce, clickDelay: clickDelay, timeout: timeout)
    let scrape = await scraper.scrape()
    let scrapeMs = Int(Date().timeIntervalSince(scrapeStart) * 1000)

    let links: [CLILink] = scrape.links.map {
      CLILink(href: $0.href, text: $0.text, status: $0.status, containerClass: $0.containerClass)
    }

    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      let model = SystemLanguageModel.default
      let available = model.availability == .available
      if !available {
        return Result(
          baseURL: baseURL.absoluteString, modelAvailable: false,
          modelStatus: String(describing: model.availability),
          scrapeReason: scrape.reason, rawLinkCount: links.count,
          profile: nil, focusedLinkCount: 0, games: [],
          scrapeMs: scrapeMs, profileMs: 0, matchMs: 0
        )
      }
      return await runModel(baseURL: baseURL, links: links, scrape: scrape, scrapeMs: scrapeMs)
    }
    #endif

    return Result(
      baseURL: baseURL.absoluteString, modelAvailable: false,
      modelStatus: "FoundationModels unavailable (needs macOS 26 + Apple Intelligence)",
      scrapeReason: scrape.reason, rawLinkCount: links.count,
      profile: nil, focusedLinkCount: 0, games: [],
      scrapeMs: scrapeMs, profileMs: 0, matchMs: 0
    )
  }

  // CLI mirror of ScrapedLink.
  struct CLILink {
    let href: String
    let text: String
    let status: String
    let containerClass: String
  }
}

// MARK: - Model pipeline (mirror of FoundationModelScraper)

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct LLMGameEntry_CLI {
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

@available(macOS 26.0, *)
@Generable
private struct LLMGamesList_CLI {
  @Guide(description: "All game or event listings found. Exclude navigation, schedule overviews, standings, news, and account links.")
  var games: [LLMGameEntry_CLI]
}

@available(macOS 26.0, *)
@Generable
private struct LLMSiteProfile_CLI {
  @Guide(description: "URL path substring common to game/event pages on this site, e.g. '/live/', '/watch/', '/nhl/2026'. Empty if no clear pattern.")
  var gameURLPattern: String
  @Guide(description: "CSS class fragment found on game listing card containers, e.g. 'match-card', 'event-item', 'game'. Empty if no clear pattern.")
  var cardClassPattern: String
  @Guide(description: "True if the site routes game pages by team abbreviation in the URL (e.g. /mlb/bos-nyy/) rather than full team names.")
  var usesAbbreviations: Bool
}

@available(macOS 26.0, *)
extension LLMScrapeCLI {
  static let siteProfilingInstructions = """
  You analyze a sample of links scraped from a sports streaming website to understand its structure.

  Identify: (1) the URL path substring common to game or event pages, (2) the CSS class fragment \
  on game listing card containers, (3) whether the site uses team abbreviations in URLs. \
  Base your answer only on the evidence in the provided link data.
  """

  static let gameMatchingInstructions = """
  You identify sports game listing links from scraped streaming website data.

  Return every game card — live, upcoming, or countdown-only. A card showing a countdown \
  timer ("2h 30m", "1d 4h") is a valid upcoming game; include it. Output team names exactly \
  as they appear in the URL slug or card text; do not expand abbreviations.

  Skip navigation, schedule overviews, standings, news, login, and account links. For games \
  whose href is a placeholder ("#", "javascript:void"), use the site's section URL. Extract \
  dates from URL path segments (e.g. /2026-05-15/ → scheduledDate "2026-05-15").
  """

  static func runModel(baseURL: URL, links: [CLILink], scrape: ScrapeResult, scrapeMs: Int) async -> Result {
    let domain = baseURL.host ?? baseURL.absoluteString

    // Phase 1: profile.
    let profileStart = Date()
    let structure = await buildSiteProfile(links: links, domain: domain, pageTitle: scrape.loadedURL)
    let profileMs = Int(Date().timeIntervalSince(profileStart) * 1000)

    // Phase 2: match (with pre-filter).
    let host = (baseURL.scheme ?? "https") + "://" + (baseURL.host ?? "")
    let focused: [CLILink]
    if let s = structure, !s.gameURLPattern.isEmpty || !s.cardClassPattern.isEmpty {
      let urlPat = s.gameURLPattern.lowercased()
      let clsPat = s.cardClassPattern.lowercased()
      let filtered = links.filter { link in
        let hrefMatch = !urlPat.isEmpty && link.href.lowercased().contains(urlPat)
        let classMatch = !clsPat.isEmpty && link.containerClass.lowercased().contains(clsPat)
        return hrefMatch || classMatch
      }
      focused = filtered.count >= 3 ? filtered : links
    } else {
      focused = links
    }

    let matchStart = Date()
    let games = await matchGames(links: focused, baseURL: baseURL, structure: structure, host: host)
    let matchMs = Int(Date().timeIntervalSince(matchStart) * 1000)

    return Result(
      baseURL: baseURL.absoluteString,
      modelAvailable: true,
      modelStatus: "available",
      scrapeReason: scrape.reason,
      rawLinkCount: links.count,
      profile: structure.map { Profile(gameURLPattern: $0.gameURLPattern, cardClassPattern: $0.cardClassPattern, usesAbbreviations: $0.usesAbbreviations) },
      focusedLinkCount: focused.count,
      games: games,
      scrapeMs: scrapeMs, profileMs: profileMs, matchMs: matchMs
    )
  }

  struct Structure { let gameURLPattern: String; let cardClassPattern: String; let usesAbbreviations: Bool }

  static func buildSiteProfile(links: [CLILink], domain: String, pageTitle: String?) async -> Structure? {
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
    let prompt = "Site: \(domain)\n\nSample links:\n\(jsonStr)"
    do {
      let session = LanguageModelSession(instructions: siteProfilingInstructions)
      let p = try await session.respond(to: prompt, generating: LLMSiteProfile_CLI.self).content
      return Structure(gameURLPattern: p.gameURLPattern, cardClassPattern: p.cardClassPattern, usesAbbreviations: p.usesAbbreviations)
    } catch {
      FileHandle.standardError.write(Data("profile error: \(error)\n".utf8))
      return nil
    }
  }

  static func matchGames(links: [CLILink], baseURL: URL, structure: Structure?, host: String) async -> [Game] {
    let serialized: [[String: String]] = links.prefix(200).compactMap { link in
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
          let jsonStr = String(data: jsonData, encoding: .utf8) else { return [] }

    var header = "Site: \(baseURL.absoluteString)"
    if let s = structure, !s.gameURLPattern.isEmpty {
      header += "\nGame pages on this site typically contain '\(s.gameURLPattern)' in the URL."
    }
    let prompt = "\(header)\n\nLinks:\n\(jsonStr)"
    do {
      let session = LanguageModelSession(instructions: gameMatchingInstructions)
      let response = try await session.respond(to: prompt, generating: LLMGamesList_CLI.self)
      return response.content.games.compactMap { e -> Game? in
        guard !e.homeTeam.isEmpty, URL(string: e.pageURL) != nil else { return nil }
        return Game(
          league: e.league, homeTeam: e.homeTeam, awayTeam: e.awayTeam,
          scheduledDate: e.scheduledDate.isEmpty ? nil : e.scheduledDate,
          scheduledTime: e.scheduledTime.isEmpty ? nil : e.scheduledTime,
          isLive: e.isLive, pageURL: e.pageURL
        )
      }
    } catch {
      FileHandle.standardError.write(Data("match error: \(error)\n".utf8))
      return []
    }
  }
}
#endif
