import Foundation
import SwiftUI

/// A learned URL template for a source site: the recipe for turning a game
/// into its deep-link page without loading the homepage and walking the DOM.
///
/// Most stream sites route by a stable path shape — ppv.to is
/// `/live/{league}/{date}/{away}-{home}`. Once we've learned that shape (see
/// `SourceProbe`), we can construct the exact game URL directly, which is far
/// more reliable than the synthetic-click walk and never mistakes one game
/// for another. The pattern is a plain string with `{…}` placeholders so it's
/// human-readable and editable in Debug Mode.
struct SourceTemplate: Codable, Equatable {
  /// How a team is encoded in the path.
  enum TeamStyle: String, Codable, CaseIterable {
    case abbreviation   // "wsh"
    case slug           // "washington-nationals"
  }

  /// Path template, e.g. `/live/{league}/{date}/{away}-{home}`. Supported
  /// placeholders: `{league}`, `{date}`, `{home}`, `{away}`.
  var pathPattern: String
  /// strftime-style format for `{date}` (interpreted in US Eastern, matching
  /// the schedule). Empty when the pattern has no `{date}`.
  var dateFormat: String
  /// Whether `{home}`/`{away}` are abbreviations or full-name slugs.
  var teamStyle: TeamStyle
  /// True once the pattern reproduced at least one real homepage link during
  /// probing. Unverified templates are stored only when edited by hand.
  var verified: Bool

  /// Builds the deep-link URL for `game` on `root`, or nil when a required
  /// placeholder can't be filled (e.g. an abbreviation-style team not in the
  /// database). A nil return is the caller's cue to fall back to the walk.
  func url(for game: Game, root: URL) -> URL? {
    var path = pathPattern
    if path.contains("{league}") {
      guard let key = Self.leagueKey(game.league) else { return nil }
      path = path.replacingOccurrences(of: "{league}", with: key)
    }
    if path.contains("{date}") {
      guard let time = game.scheduledTime else { return nil }
      let fmt = DateFormatter()
      fmt.locale = Locale(identifier: "en_US_POSIX")
      fmt.timeZone = TimeZone(identifier: "America/New_York")
      fmt.dateFormat = dateFormat.isEmpty ? "yyyy-MM-dd" : dateFormat
      path = path.replacingOccurrences(of: "{date}", with: fmt.string(from: time))
    }
    if path.contains("{home}") {
      guard let h = teamToken(game.homeTeam) else { return nil }
      path = path.replacingOccurrences(of: "{home}", with: h)
    }
    if path.contains("{away}") {
      // Solo events have no away team — only valid if the pattern doesn't
      // need one (handled above for {home}); if it does, bail.
      guard let a = teamToken(game.awayTeam) else { return nil }
      path = path.replacingOccurrences(of: "{away}", with: a)
    }
    guard !path.contains("{") else { return nil }
    return URL(string: path, relativeTo: GameURLResolver.rootURL(root))?.absoluteURL
  }

  private func teamToken(_ team: String) -> String? {
    guard !team.isEmpty else { return nil }
    switch teamStyle {
    case .abbreviation: return TeamAliasIndex.shared.primaryAbbreviation(forTeam: team)
    case .slug:
      let s = TeamAliasIndex.shared.slug(forTeam: team)
      return s.isEmpty ? nil : s
    }
  }

  /// The conventional URL key sites use for a league. Abbreviation-routed
  /// sites overwhelmingly use these exact short keys.
  static func leagueKey(_ league: SportLeague) -> String? {
    switch league {
    case .nfl: return "nfl"
    case .nba: return "nba"
    case .wnba: return "wnba"
    case .mlb: return "mlb"
    case .nhl: return "nhl"
    case .ncaaf: return "ncaaf"
    case .ncaab: return "ncaab"
    case .mma: return "mma"
    case .ufc: return "ufc"
    case .boxing: return "boxing"
    case .f1: return "f1"
    case .nascar: return "nascar"
    case .wwe: return "wwe"
    case .tennis: return "tennis"
    case .golf: return "golf"
    case .cricket: return "cricket"
    case .iihf: return "iihf"
    case .mls: return "mls"
    case .premierLeague: return "epl"
    case .laLiga: return "laliga"
    case .serieA: return "seriea"
    case .bundesliga: return "bundesliga"
    case .ligue1: return "ligue1"
    case .eredivisie: return "eredivisie"
    case .ligaMx: return "ligamx"
    case .championsLeague: return "ucl"
    case .europaLeague: return "uel"
    case .soccer: return "soccer"
    case .other: return nil
    }
  }
}

// MARK: - Store

/// Persists learned templates keyed by source host. Observable so the Debug
/// Mode editor reflects probe results as they land.
@MainActor
@Observable
final class SourceTemplateStore {
  static let shared = SourceTemplateStore()

  private(set) var templates: [String: SourceTemplate] = [:]

  private static let storageKey = "SourceTemplates.v1"

  private init() { load() }

  func template(forHost host: String?) -> SourceTemplate? {
    guard let host else { return nil }
    return templates[host.lowercased()]
  }

  func set(_ template: SourceTemplate?, forHost host: String?) {
    guard let host else { return }
    let key = host.lowercased()
    if let template {
      templates[key] = template
    } else {
      templates.removeValue(forKey: key)
    }
    save()
  }

  // MARK: Persistence

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let decoded = try? JSONDecoder().decode([String: SourceTemplate].self, from: data)
    else { return }
    templates = decoded
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(templates) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}
