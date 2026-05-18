import Foundation

/// v2.30: source-agnostic learning store.
///
/// Records what the app observes about each source so future taps can
/// short-circuit work. Two things get learned per source:
///
/// 1. **URL templates** for per-game pages, induced from successful
///    matches. After `findStreamPage` resolves to a game-page URL AND
///    a stream actually plays from it, the URL's path is scanned for
///    the home/away team slugs. If found, the path with slugs replaced
///    by `{home}` / `{away}` markers becomes a template — next time
///    we need a page on this source for any game, we substitute the
///    team slugs and HEAD-check the constructed URL before scraping.
///
/// 2. **Team slug map** — the source-specific slug used for each
///    canonical team name. "Pumas UNAM" may slug to "pumas" on
///    streameast and "pumasunam" on another site. We populate this
///    from successful matches and reuse it for template substitution.
///
/// Nothing here references any specific source ID — patterns are
/// observed at runtime, not hardcoded. Adding a new source to the
/// pool gives that source its own empty learning slot which fills
/// in over use.
@MainActor
final class SourceLearningStore: ObservableObject {
  static let shared = SourceLearningStore()

  struct URLTemplate: Codable, Equatable, Hashable {
    /// Path with positional markers, e.g. "/soccer/{home}-vs-{away}".
    /// Scheme + host come from the source's baseURL at substitution time.
    let path: String
    /// Ordered list of markers in the path. Always one of:
    ///   ["{home}", "{away}"]  — typical
    ///   ["{away}", "{home}"]  — for sites that order away-first in URL
    let markerOrder: [String]
    /// How many times this template has produced a working stream.
    /// Used to pick the "best" template when multiple are recorded.
    var successCount: Int
    var lastUsedAt: Date
  }

  struct SourceLearning: Codable, Equatable {
    var templates: [URLTemplate]
    /// Lowercased canonical team name → source-specific slug.
    var teamSlugMap: [String: String]
    /// Path prefixes ("/soccer", "/football") observed in successful
    /// matches. Light hint used by `extractGames` pre-filter to prefer
    /// links under known-good directories.
    var goodPathPrefixes: Set<String>
    var lastUpdated: Date

    static let empty = SourceLearning(
      templates: [],
      teamSlugMap: [:],
      goodPathPrefixes: [],
      lastUpdated: .distantPast
    )
  }

  @Published private(set) var bySourceID: [String: SourceLearning] = [:]

  private init() {
    load()
  }

  // MARK: Queries

  func learning(for sourceID: String) -> SourceLearning {
    bySourceID[sourceID] ?? .empty
  }

  /// Returns up to `limit` URLs to try when looking for a game-page on
  /// the given source. Empty when we haven't learned enough yet — caller
  /// should fall back to scrape-+-LLM.
  ///
  /// Strategy: take known templates ordered by successCount; for each
  /// template, substitute the team's slugs from `teamSlugMap` if known,
  /// else fall back to derived slug candidates. Resolves relative to
  /// `baseURL`.
  func candidateURLs(for sourceID: String, game: Game, baseURL: URL,
                     limit: Int = 3) -> [URL] {
    let learning = learning(for: sourceID)
    guard !learning.templates.isEmpty else { return [] }

    let homeSlug = slug(for: game.homeTeam, sourceID: sourceID)
    let awaySlug = slug(for: game.awayTeam, sourceID: sourceID)
    let homeCandidates = slugCandidates(from: game.homeTeam, preferred: homeSlug)
    let awayCandidates = slugCandidates(from: game.awayTeam, preferred: awaySlug)

    var seen = Set<String>()
    var urls: [URL] = []
    let templates = learning.templates.sorted { $0.successCount > $1.successCount }
    for template in templates where urls.count < limit {
      for hSlug in homeCandidates where urls.count < limit {
        for aSlug in awayCandidates where urls.count < limit {
          let assignments: [String: String]
          if template.markerOrder == ["{home}", "{away}"] {
            assignments = ["{home}": hSlug, "{away}": aSlug]
          } else {
            assignments = ["{home}": hSlug, "{away}": aSlug]
            // Order-swapped templates use the same markers but slot
            // {away} first in the path string itself; substitution by
            // marker name still works.
          }
          var path = template.path
          for (marker, value) in assignments {
            path = path.replacingOccurrences(of: marker, with: value)
          }
          guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
                seen.insert(url.absoluteString).inserted
          else { continue }
          urls.append(url)
        }
      }
    }
    return urls
  }

  /// True iff a link's path matches a known-good directory prefix for
  /// this source. Used as a soft signal by the pre-LLM filter — when
  /// a source has accumulated good prefixes, links matching them are
  /// preserved and other paths get pruned. Returns true (don't prune)
  /// when no learning exists yet so we don't over-filter early on.
  func isLikelyGoodPath(_ url: URL, sourceID: String) -> Bool {
    let learning = learning(for: sourceID)
    if learning.goodPathPrefixes.isEmpty { return true }
    let path = url.path.lowercased()
    return learning.goodPathPrefixes.contains { path.hasPrefix($0) }
  }

  // MARK: Recording (called from PlayerView on successful playback)

  /// Records a successful (game → URL) mapping for a source. Induces
  /// a URL template from the path if both team slugs are detectable;
  /// updates the slug map; adds the path's first directory to the
  /// good-prefix set.
  func recordSuccess(sourceID: String, gamePageURL: URL, game: Game) {
    var learning = bySourceID[sourceID] ?? .empty

    let path = gamePageURL.path
    // Step 1: find which slugs of each team actually appear in the path.
    let homeMatch = firstMatchingSlug(in: path, for: game.homeTeam)
    let awayMatch = firstMatchingSlug(in: path, for: game.awayTeam)
    if let h = homeMatch { learning.teamSlugMap[game.homeTeam.lowercased()] = h }
    if let a = awayMatch { learning.teamSlugMap[game.awayTeam.lowercased()] = a }

    // Step 2: induce a template iff BOTH slugs were detected. Replacing
    // only one would produce a misleading template that breaks on
    // every other game.
    if let h = homeMatch, let a = awayMatch {
      // Order in path: did home appear before away or after?
      let hRange = path.range(of: h)
      let aRange = path.range(of: a)
      if let hR = hRange, let aR = aRange, hR.lowerBound != aR.lowerBound {
        // Replace away first if it appears later — order matters when
        // one slug is a prefix of the other (rare but possible).
        let homeFirst = hR.lowerBound < aR.lowerBound
        var templatePath = path
        if homeFirst {
          // Replace away first (later occurrence) to keep home's range stable
          templatePath = templatePath.replacingOccurrences(of: a, with: "{away}")
          templatePath = templatePath.replacingOccurrences(of: h, with: "{home}")
        } else {
          templatePath = templatePath.replacingOccurrences(of: h, with: "{home}")
          templatePath = templatePath.replacingOccurrences(of: a, with: "{away}")
        }
        let markerOrder: [String] = homeFirst ? ["{home}", "{away}"] : ["{away}", "{home}"]

        // De-dupe / promote: if an identical template exists, bump its
        // successCount and timestamp. Else append.
        if let idx = learning.templates.firstIndex(where: {
          $0.path == templatePath && $0.markerOrder == markerOrder
        }) {
          learning.templates[idx].successCount += 1
          learning.templates[idx].lastUsedAt = Date()
        } else {
          learning.templates.append(URLTemplate(
            path: templatePath,
            markerOrder: markerOrder,
            successCount: 1,
            lastUsedAt: Date()
          ))
        }
        // Cap to top 5 templates per source to prevent unbounded growth
        // from variant paths. Sort by successCount, keep the winners.
        learning.templates.sort { $0.successCount > $1.successCount }
        if learning.templates.count > 5 {
          learning.templates = Array(learning.templates.prefix(5))
        }
      }
    }

    // Step 3: good-prefix harvesting. Take the first path component
    // (e.g. "/soccer" from "/soccer/pumas-vs-pachuca") and add it to
    // the source's good-prefix set. Skip when path has no segments.
    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if let firstSegment = trimmed.split(separator: "/").first,
       firstSegment.count >= 2, firstSegment.count <= 24 {
      learning.goodPathPrefixes.insert("/\(firstSegment.lowercased())")
      // Cap to 20 prefixes per source.
      if learning.goodPathPrefixes.count > 20 {
        learning.goodPathPrefixes = Set(learning.goodPathPrefixes.prefix(20))
      }
    }

    learning.lastUpdated = Date()
    bySourceID[sourceID] = learning
    save()
  }

  // MARK: Slug derivation

  /// Returns the source-specific slug for a team if learned, else nil.
  private func slug(for teamName: String, sourceID: String) -> String? {
    bySourceID[sourceID]?.teamSlugMap[teamName.lowercased()]
  }

  /// Candidate slugs to try for a team. Includes the learned slug first
  /// (when present), then progressively shorter normalizations of the
  /// team name. Caller iterates over the list.
  ///
  /// Examples for "Pumas UNAM":
  ///   preferred: "pumas"  (learned)
  ///   then: "pumas-unam", "pumas", "unam"
  private func slugCandidates(from teamName: String, preferred: String?) -> [String] {
    var out: [String] = []
    if let preferred, !preferred.isEmpty { out.append(preferred) }
    let normalized = normalizeForSlug(teamName)
    if !normalized.isEmpty, !out.contains(normalized) { out.append(normalized) }
    // Per-word slug candidates: each word that's >= 3 chars
    let words = normalized.split(separator: "-").filter { $0.count >= 3 }
    for w in words {
      let s = String(w)
      if !out.contains(s) { out.append(s) }
    }
    return out
  }

  /// First slug candidate (of `teamName`) that appears as a substring of
  /// `path`. Returns the matched slug (not the position). Conservative:
  /// only matches >= 3 chars to avoid spurious sub-string hits like "u"
  /// matching the "u" in "/cup/".
  private func firstMatchingSlug(in path: String, for teamName: String) -> String? {
    let candidates = slugCandidates(from: teamName, preferred: nil)
    let lowerPath = path.lowercased()
    for c in candidates where c.count >= 3 {
      // Word-boundary-ish check: slug should be surrounded by
      // separators in the path (slash, hyphen) — not embedded in
      // a longer word. Cheap approximation: bracket with separators
      // and substring-search.
      let bracketed = "/-\(c)-/"
        .replacingOccurrences(of: "//", with: "/")
      _ = bracketed  // suppress unused; we use a simpler approach below
      // Look for the slug bordered by '/', '-', or end-of-string.
      if let r = lowerPath.range(of: c) {
        let before = r.lowerBound > lowerPath.startIndex
          ? lowerPath[lowerPath.index(before: r.lowerBound)]
          : "/"
        let after = r.upperBound < lowerPath.endIndex
          ? lowerPath[r.upperBound]
          : "/"
        let separators: Set<Character> = ["/", "-", "_"]
        if separators.contains(before) && separators.contains(after) {
          return c
        }
      }
    }
    return nil
  }

  /// Diacritic-fold + punctuation-strip + lowercase + spaces→hyphens.
  /// Mirrors the conventions used in `HomeView.normalizeForMatch` but
  /// produces a URL-shaped slug instead of a normalized team-pair key.
  private func normalizeForSlug(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                           locale: .current)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789- ")
    let scalars = folded.unicodeScalars.filter { allowed.contains($0) }
    let stripped = String(String.UnicodeScalarView(scalars))
    let collapsed = stripped.replacingOccurrences(
      of: "[ ]+", with: "-",
      options: .regularExpression
    )
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  // MARK: Persistence

  private static let storageKey = "SourceLearningStore.bySourceID.v1"

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let decoded = try? JSONDecoder().decode([String: SourceLearning].self, from: data)
    else { return }
    bySourceID = decoded
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(bySourceID) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}

// MARK: - Universal link-noise patterns (not source-specific)

/// Path components that are almost certainly navigation / legal / auth
/// pages on any aggregator. Used by the pre-LLM filter to drop noise
/// before sending links to the LLM. Source-agnostic — anyone's site
/// has these.
enum LinkNoise {
  static let badPathFragments: Set<String> = [
    "/login", "/register", "/signup", "/sign-up", "/signin", "/sign-in",
    "/logout", "/account", "/profile", "/settings", "/preferences",
    "/about", "/contact", "/privacy", "/dmca", "/terms", "/tos",
    "/help", "/faq", "/support", "/feedback",
    "/donate", "/sponsor", "/subscribe", "/upgrade", "/premium",
    "/blog", "/news", "/forum",
    "/cookie-policy", "/disclaimer", "/abuse"
  ]

  /// True iff the URL path appears to be navigation/legal noise.
  static func isNoise(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    if path.isEmpty || path == "/" { return false }
    return badPathFragments.contains { path.hasPrefix($0) || path == $0 }
  }
}
