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
    let candidateLinkCount: Int
    let chunks: Int
    let games: [Game]
    let scrapeMs: Int
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
          profile: nil, candidateLinkCount: 0, chunks: 0, games: [],
          scrapeMs: scrapeMs, matchMs: 0
        )
      }
      return await runModel(baseURL: baseURL, links: links, scrape: scrape, scrapeMs: scrapeMs)
    }
    #endif

    return Result(
      baseURL: baseURL.absoluteString, modelAvailable: false,
      modelStatus: "FoundationModels unavailable (needs macOS 26 + Apple Intelligence)",
      scrapeReason: scrape.reason, rawLinkCount: links.count,
      profile: nil, candidateLinkCount: 0, chunks: 0, games: [],
      scrapeMs: scrapeMs, matchMs: 0
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
// Short @Guide strings: the on-device window is only ~4096 tokens and the
// injected schema is the single biggest consumer, so every word here is paid
// for in lost room for links. `scheduledTime` is intentionally dropped (it's
// rarely present in link data and is cheaply derivable later).
@available(macOS 26.0, *)
@Generable
private struct LLMGameEntry_CLI {
  @Guide(description: "League, e.g. NBA, MLB, NHL, EPL, UFC, F1")
  var league: String
  @Guide(description: "Home team/participant verbatim from the link. Keep abbreviations.")
  var homeTeam: String
  @Guide(description: "Away team verbatim. Empty for solo events.")
  var awayTeam: String
  @Guide(description: "Date as YYYY-MM-DD if present in the link, else empty.")
  var scheduledDate: String
  @Guide(description: "True if the status shows live, in progress, or a score.")
  var isLive: Bool
  @Guide(description: "The 'u' value of this link, copied exactly.")
  var pageURL: String
}

@available(macOS 26.0, *)
@Generable
private struct LLMGamesList_CLI {
  @Guide(description: "Game/event listings only. Skip nav, standings, news, login, account.")
  var games: [LLMGameEntry_CLI]
}

@available(macOS 26.0, *)
extension LLMScrapeCLI {
  // Grounding is everything for this small model: without the "only what's in
  // the link / never invent / one game per link" rules it (a) fabricates famous
  // matchups for section links that carry no team data, and (b) loops, emitting
  // the same game until it overflows the window. Both are caught again in Swift
  // by post-validation, but cutting them at the source improves yield.
  static let gameMatchingInstructions = """
  You convert scraped link data into a list of sports games. Work ONLY from the \
  text and URL of each provided link — never use outside knowledge, and never \
  invent teams, dates, or matchups. Emit at most one game per link, and never \
  repeat the same game. Copy team names verbatim from the link; keep \
  abbreviations as-is. If a link has no clear team or event in its own text/URL \
  (e.g. a section or navigation link like "NFL" → /nflstreams2), skip it.
  """

  // Small chunks keep a *complete* response inside the shared ~4096-token
  // window. We deliberately do NOT cap maximumResponseTokens: a hard cap
  // truncates the JSON mid-token and guided generation then fails to decode the
  // entire chunk. Looping is handled by post-validation + dedupe instead.
  static let chunkSize = 8

  static func runModel(baseURL: URL, links: [CLILink], scrape: ScrapeResult, scrapeMs: Int) async -> Result {
    let host = (baseURL.scheme ?? "https") + "://" + (baseURL.host ?? "")

    // Cheap Swift-side junk filter (no model call): drop the homepage itself,
    // javascript/anchor-only hrefs, and obvious non-game sections. Everything
    // surviving is a *candidate* — the model is the real classifier, so this
    // stays deliberately conservative to avoid the old "filter ate the games"
    // failure mode.
    let baseNoSlash = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let junkPathTokens = ["/blog", "/news", "/about", "/contact", "/privacy",
                          "/terms", "/dmca", "/login", "/register", "/signup",
                          "/account", "/faq", "/tag/", "/category/blog"]
    var seen = Set<String>()
    let candidates: [CLILink] = links.compactMap { link in
      var href = link.href
      if href.hasPrefix("//") { href = (baseURL.scheme ?? "https") + ":" + href }
      else if href.hasPrefix("/") { href = host + href }
      guard href.hasPrefix("http"), !href.hasPrefix("javascript:") else { return nil }
      let lower = href.lowercased()
      if junkPathTokens.contains(where: { lower.contains($0) }) { return nil }
      let trimmed = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if trimmed == baseNoSlash { return nil }            // homepage self-link
      guard seen.insert(href).inserted else { return nil } // dedupe
      return CLILink(href: href, text: link.text, status: link.status, containerClass: link.containerClass)
    }

    // Chunk and classify. Merge + dedupe by resolved pageURL.
    let matchStart = Date()
    let batches = stride(from: 0, to: candidates.count, by: chunkSize).map {
      Array(candidates[$0..<min($0 + chunkSize, candidates.count)])
    }
    var games: [Game] = []
    var gameSeen = Set<String>()
    for batch in batches {
      let batchGames = await matchChunk(batch, baseURL: baseURL, host: host)
      for g in batchGames where gameSeen.insert(g.pageURL).inserted {
        games.append(g)
      }
    }
    let matchMs = Int(Date().timeIntervalSince(matchStart) * 1000)

    return Result(
      baseURL: baseURL.absoluteString,
      modelAvailable: true,
      modelStatus: "available",
      scrapeReason: scrape.reason,
      rawLinkCount: links.count,
      profile: nil,
      candidateLinkCount: candidates.count,
      chunks: batches.count,
      games: games,
      scrapeMs: scrapeMs, matchMs: matchMs
    )
  }

  /// Classify one batch of links. Sends compact entries (short keys, path-only
  /// `u`) and disables schema-in-prompt to conserve the tiny context window.
  /// Every returned game is validated against its source link's own text+URL so
  /// hallucinated matchups and loop-duplicates are discarded.
  static func matchChunk(_ links: [CLILink], baseURL: URL, host: String) async -> [Game] {
    // key (path) → (absolute URL, lowercased haystack of the link's own text+URL)
    var resolved: [String: String] = [:]
    var haystack: [String: String] = [:]
    let serialized: [[String: String]] = links.compactMap { link in
      let abs = link.href
      let u: String
      if abs.hasPrefix(host) { u = String(abs.dropFirst(host.count)) } else { u = abs }
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
      let session = LanguageModelSession(instructions: gameMatchingInstructions)
      let response = try await session.respond(
        to: prompt,
        generating: LLMGamesList_CLI.self,
        includeSchemaInPrompt: false,
        options: GenerationOptions(temperature: 0)
      )
      var seenInChunk = Set<String>()
      return response.content.games.compactMap { e -> Game? in
        guard !e.homeTeam.isEmpty else { return nil }
        if !e.awayTeam.isEmpty, e.homeTeam.caseInsensitiveCompare(e.awayTeam) == .orderedSame { return nil }
        let key = e.pageURL.hasPrefix(host) ? String(e.pageURL.dropFirst(host.count)) : e.pageURL
        let abs = resolved[key] ?? resolved["/" + key] ?? (e.pageURL.hasPrefix("http") ? e.pageURL : host + e.pageURL)
        guard URL(string: abs) != nil else { return nil }
        // Grounding check: the home (and away, if present) team must actually
        // appear in the source link's text/URL. Kills fabricated matchups and
        // recycled-URL loop duplicates.
        let hay = haystack[key] ?? haystack["/" + key] ?? ""
        guard !hay.isEmpty, teamGrounded(e.homeTeam, in: hay),
              e.awayTeam.isEmpty || teamGrounded(e.awayTeam, in: hay) else { return nil }
        // Dedupe within the chunk by resolved URL + matchup.
        let dedupeKey = abs + "|" + e.homeTeam.lowercased() + "|" + e.awayTeam.lowercased()
        guard seenInChunk.insert(dedupeKey).inserted else { return nil }
        // Keep the date only if it actually appears in the link (else invented).
        let date: String? = {
          let d = e.scheduledDate.trimmingCharacters(in: .whitespacesAndNewlines)
          return (!d.isEmpty && hay.contains(d.lowercased())) ? d : nil
        }()
        return Game(
          league: e.league, homeTeam: e.homeTeam, awayTeam: e.awayTeam,
          scheduledDate: date,
          scheduledTime: nil,
          isLive: e.isLive, pageURL: abs
        )
      }
    } catch {
      FileHandle.standardError.write(Data("match error (\(links.count) links): \(error)\n".utf8))
      return []
    }
  }

  /// True if a meaningful token of `team` appears in `haystack` (the source
  /// link's lowercased text+URL). Tolerant of slug hyphenation and abbreviation:
  /// matches if any word ≥3 chars from the team name is present.
  static func teamGrounded(_ team: String, in haystack: String) -> Bool {
    let normalized = haystack.replacingOccurrences(of: "-", with: " ")
    let words = team.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count >= 3 }
    if words.isEmpty {
      // Very short name (abbreviation like "TOR"); require exact substring.
      return normalized.contains(team.lowercased())
    }
    return words.contains { normalized.contains($0) }
  }
}
#endif
