import Foundation

/// Synchronous, read-only reverse index of team display name → match tokens,
/// loaded from the bundled `teams.json` (and the on-disk cache when present).
///
/// `TeamDatabase` (an actor) owns the name → league mapping the rest of the
/// app queries asynchronously. The game-URL matchers, however, need a team's
/// aliases *synchronously* — at the moment a WKWebView is built we have no
/// chance to await. They also need something `TeamDatabase` doesn't expose: a
/// lookup keyed by a team's display name returning its abbreviations. This
/// index provides exactly that.
///
/// The payoff is matching abbreviation-routed sites. ppv.to (and many others)
/// route by team abbreviation — the Nationals-vs-Diamondbacks page is
/// `/live/mlb/2026-06-07/wsh-ari`, never the full slug. Without the `WSH` /
/// `ARI` aliases the matchers can't recognize it, fall back to a category
/// guess, and follow the wrong game.
final class TeamAliasIndex {
  static let shared = TeamAliasIndex()

  /// Match tokens for one team, split by how they may be matched.
  struct Tokens {
    /// Length ≥4 — safe to match as a plain substring (e.g. "nationals").
    var long: [String]
    /// Length 2–3, letters only — abbreviations like "wsh"/"ari". These must
    /// be matched only as a bounded slug segment (delimited by non-alnum on
    /// both sides) so "ari" doesn't fire inside "marina".
    var abbr: [String]
  }

  /// normalized display name → its raw alias strings (plus canonical name).
  private var aliasesByName: [String: [String]] = [:]

  private init() {
    // Load the binary's bundled baseline first so its aliases are always
    // present, then overlay the on-disk cache (a fresher team list fetched
    // from the remote). Aliases are unioned per team, so a stale cache can
    // never drop an alias the bundled file ships — e.g. "USA"/"USMNT" for
    // United States, without which abbreviation-routed URLs like
    // `/world-championship/usa-turkiye` can't be matched.
    if let bundled = Self.loadBundledSchema() { ingest(bundled) }
    if let cached = Self.loadDiskSchema() { ingest(cached) }
  }

  /// Tokens for a team identified by its display name. Empty when the name
  /// isn't in the database (callers fall back to deriving tokens from the
  /// name slug themselves).
  func tokens(forTeam displayName: String) -> Tokens {
    let key = Self.normalize(displayName)
    guard !key.isEmpty else { return Tokens(long: [], abbr: []) }
    // Database aliases (or the name itself) plus cross-language / alternate
    // spellings so a site listing "Türkiye" or "España" still matches.
    let raw = (aliasesByName[key] ?? [displayName])
      + TeamNameVariants.variants(forNormalized: key)
    var long = Set<String>()
    var abbr = Set<String>()
    for alias in raw {
      // Split each alias on whitespace and hyphen, and also keep the
      // whitespace-stripped whole, so both "Red Sox" → "redsox" and its
      // words contribute.
      let folded = Self.normalize(alias)
      guard !folded.isEmpty else { continue }
      var atoms = folded.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
      let compact = folded.replacingOccurrences(of: " ", with: "")
                          .replacingOccurrences(of: "-", with: "")
      atoms.append(compact)
      for atom in atoms {
        if atom.count >= 4 {
          long.insert(atom)
        } else if (2...3).contains(atom.count), atom.allSatisfy({ $0.isLetter }) {
          abbr.insert(atom)
        }
      }
    }
    return Tokens(long: Array(long), abbr: Array(abbr))
  }

  /// True when we have any usable match token for this team.
  func hasTokens(forTeam displayName: String) -> Bool {
    let t = tokens(forTeam: displayName)
    return !t.long.isEmpty || !t.abbr.isEmpty
  }

  /// Whether `paddedHaystack` (a normalized string wrapped in leading and
  /// trailing spaces) mentions this team — via a long token (substring) or
  /// an abbreviation (whole word). Used by GameURLResolver.
  func matches(team displayName: String, inPadded paddedHaystack: String) -> Bool {
    let t = tokens(forTeam: displayName)
    if t.long.contains(where: { paddedHaystack.contains($0) }) { return true }
    if t.abbr.contains(where: { paddedHaystack.contains(" \($0) ") }) { return true }
    return false
  }

  // MARK: - Loading

  private static func loadBundledSchema() -> TeamDatabase.Schema? {
    guard let url = Bundle.main.url(forResource: "teams", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let schema = try? JSONDecoder().decode(TeamDatabase.Schema.self, from: data) else {
      return nil
    }
    return schema
  }

  private static func loadDiskSchema() -> TeamDatabase.Schema? {
    guard let url = diskCacheURL,
          let data = try? Data(contentsOf: url),
          let schema = try? JSONDecoder().decode(TeamDatabase.Schema.self, from: data) else {
      return nil
    }
    return schema
  }

  private static var diskCacheURL: URL? {
    let fm = FileManager.default
    guard let dir = try? fm.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    ) else { return nil }
    return dir.appendingPathComponent("teams-cache.json")
  }

  /// Merges a schema's team aliases into `aliasesByName`, unioning with any
  /// already-loaded values for the same name (the bundled baseline plus the
  /// disk cache both feed through here). Dedupes case-insensitively while
  /// preserving first-seen order.
  private func ingest(_ schema: TeamDatabase.Schema) {
    for (_, league) in schema.leagues {
      for team in league.teams {
        let key = Self.normalize(team.name)
        guard !key.isEmpty else { continue }
        var values = aliasesByName[key] ?? []
        values.append(team.name)
        values.append(contentsOf: team.aliases ?? [])
        var seen = Set<String>()
        aliasesByName[key] = values.filter { seen.insert($0.lowercased()).inserted }
      }
    }
  }

  static func normalize(_ s: String) -> String {
    s.lowercased()
      .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
      .replacingOccurrences(of: "[^a-z0-9 -]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }
}
