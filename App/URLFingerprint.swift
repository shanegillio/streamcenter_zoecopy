import Foundation

/// v2.31 L1: URL-only scoring + ad-server hard reject.
///
/// Fast, no I/O. Every URL the JS-shim reports goes through here first.
/// Rejected URLs never become candidates. Surviving URLs carry a base
/// score that L2 (manifest structure) and L3 (DOM context) add to.
///
/// The reject lists are intentionally short and well-known — ad-server
/// hostnames have been stable for a decade. Source-agnostic: no
/// aggregator names appear.
struct URLScore: Equatable {
  var value: Int
  var rejected: Bool
  /// Short human-readable reasons, surfaced in Source Stats for debug.
  var reasons: [String]
}

enum URLFingerprint {

  /// Hostnames that serve ads. Sub-domain match: `pagead2.googlesyndication.com`
  /// matches if its registrable suffix is in this set.
  static let adServerHostSuffixes: Set<String> = [
    "doubleclick.net",
    "googlesyndication.com",
    "googleadservices.com",
    "g.doubleclick.net",
    "adservice.google.com",
    "serving-sys.com",
    "advertising.com",
    "adsrvr.org",
    "adnxs.com",
    "moatads.com",
    "rubiconproject.com",
    "criteo.com",
    "scorecardresearch.com",
    "pubmatic.com",
    "openx.net",
  ]

  /// Path tokens that indicate ad payloads. Case-insensitive substring
  /// match against `url.path`.
  static let adPathFragments: [String] = [
    "/ads/", "/ad/", "/preroll", "/midroll", "/postroll",
    "/vmap", "/vast", "/banner", "/sponsored", "/companion",
  ]

  /// Returns the L1 score for a URL.
  ///
  /// - `targetGame`: when present, slugs derived from team names get
  ///   matched against the URL path for a +15 boost. When absent (e.g.
  ///   we don't know the target game yet) the boost is skipped.
  /// - `knownGoodHosts`: hostnames that have produced working streams
  ///   on this source in the past (populated from
  ///   `SourceLearningStore`). Hostname match gives +10.
  static func score(_ url: URL,
                    targetGame: Game?,
                    knownGoodHosts: Set<String>) -> URLScore {
    var reasons: [String] = []
    var value = 0

    // Hard reject: ad-server hostname.
    if let host = url.host?.lowercased() {
      for suffix in adServerHostSuffixes {
        if host == suffix || host.hasSuffix("." + suffix) {
          return URLScore(value: -1000, rejected: true,
                          reasons: ["ad-server host: \(host)"])
        }
      }
      if knownGoodHosts.contains(host) {
        value += 10
        reasons.append("+10 known good host")
      }
    }

    let path = url.path.lowercased()
    // Hard reject: ad path fragment.
    for frag in adPathFragments {
      if path.contains(frag) {
        return URLScore(value: -1000, rejected: true,
                        reasons: ["ad path: \(frag)"])
      }
    }

    // Soft boost: team slugs in URL path.
    if let game = targetGame {
      let homeSlug = normalizeForSlug(game.homeTeam)
      let awaySlug = normalizeForSlug(game.awayTeam)
      var matchedSlugs = 0
      if !homeSlug.isEmpty, path.contains(homeSlug) { matchedSlugs += 1 }
      if !awaySlug.isEmpty, path.contains(awaySlug) { matchedSlugs += 1 }
      // Per-slug words too (handles "pumas" matching when full slug "pumas-unam" doesn't).
      let homeWords = homeSlug.split(separator: "-").filter { $0.count >= 4 }.map(String.init)
      let awayWords = awaySlug.split(separator: "-").filter { $0.count >= 4 }.map(String.init)
      var anyWordMatch = false
      for w in homeWords + awayWords where path.contains(w) { anyWordMatch = true; break }
      if matchedSlugs == 2 {
        value += 15
        reasons.append("+15 both teams in URL")
      } else if matchedSlugs == 1 {
        value += 8
        reasons.append("+8 one team in URL")
      } else if anyWordMatch {
        value += 4
        reasons.append("+4 team word in URL")
      }
    }

    // Soft penalty: UUID-like session token in query (often ad retargeting).
    if let query = url.query, looksLikeSessionToken(query) {
      value -= 5
      reasons.append("-5 session token in query")
    }

    return URLScore(value: value, rejected: false, reasons: reasons)
  }

  // MARK: - Helpers

  private static func looksLikeSessionToken(_ query: String) -> Bool {
    // Heuristic: 32+ hex chars or UUID-style 8-4-4-4-12 anywhere in the
    // query string. Not perfect; just a tie-breaker.
    let uuidRegex = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    let hexRegex = #"[0-9a-fA-F]{32,}"#
    if query.range(of: uuidRegex, options: .regularExpression) != nil { return true }
    if query.range(of: hexRegex, options: .regularExpression) != nil { return true }
    return false
  }

  /// Diacritic-fold + lowercase + spaces→hyphens, mirrors
  /// SourceLearningStore.normalizeForSlug. Kept private to this file so
  /// callers can't accidentally substitute a different normalization.
  private static func normalizeForSlug(_ s: String) -> String {
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
}
