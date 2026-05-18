import Foundation

/// v2.30: per-league last-successful sourceID.
///
/// Drives source ordering: when the user taps a Premier League game, the
/// source that most recently produced a working PL stream attempts first.
/// Source-agnostic — sourceIDs are recorded from observation, never
/// hardcoded.
@MainActor
final class SourcePreference: ObservableObject {
  static let shared = SourcePreference()

  /// Maps SportLeague.rawValue → sourceID. Most-recent-write wins; we
  /// don't track per-league history beyond the latest success.
  private var lastSuccessful: [String: String] = [:]

  private init() {
    load()
  }

  func lastSuccessfulSource(for league: SportLeague) -> String? {
    lastSuccessful[league.rawValue]
  }

  func recordSuccess(league: SportLeague, sourceID: String) {
    lastSuccessful[league.rawValue] = sourceID
    save()
  }

  // MARK: Persistence

  private static let storageKey = "SourcePreference.lastSuccessful.v1"

  private func load() {
    guard let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey)
            as? [String: String]
    else { return }
    lastSuccessful = raw
  }

  private func save() {
    UserDefaults.standard.set(lastSuccessful, forKey: Self.storageKey)
  }
}
