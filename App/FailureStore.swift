import Foundation

/// v2.30: per-(game, source) failure memory with TTL.
///
/// When playback fails for a specific game on a specific source, record
/// the pair. `searchSourcesForGamePage` filters the parallel race set so
/// we don't repeatedly waste 12 s discovering the same failure. Cleared
/// on successful playback for that game (so a transient issue doesn't
/// blacklist the source forever).
///
/// Source-agnostic: nothing here names a specific source ID.
@MainActor
final class FailureStore: ObservableObject {
  static let shared = FailureStore()

  /// 1 h memory window. Long enough that a tap-and-retry on the same game
  /// skips known-bad sources; short enough that crackstreams's parking
  /// page going away after the hour gets a fresh chance.
  static let ttl: TimeInterval = 60 * 60

  private struct Entry: Codable {
    let gameKey: String
    let sourceID: String
    let failedAt: Date
  }

  private var entries: [Entry] = []

  private init() {
    load()
  }

  // MARK: Queries

  /// True iff we recorded a failure for this exact pair within `ttl`.
  func isFailedRecently(gameKey: String, sourceID: String) -> Bool {
    let cutoff = Date().addingTimeInterval(-Self.ttl)
    return entries.contains { e in
      e.gameKey == gameKey && e.sourceID == sourceID && e.failedAt > cutoff
    }
  }

  // MARK: Mutations

  func markFailed(gameKey: String, sourceID: String) {
    // Replace any older entry for the same pair so failedAt is current.
    entries.removeAll { $0.gameKey == gameKey && $0.sourceID == sourceID }
    entries.append(Entry(gameKey: gameKey, sourceID: sourceID, failedAt: Date()))
    pruneExpired()
    save()
  }

  /// Called on first playable frame. Clears every failure recorded for
  /// this game across every source — a successful resolution means we
  /// got what the user wanted, no need to remember which sources missed.
  func clearForGame(gameKey: String) {
    entries.removeAll { $0.gameKey == gameKey }
    save()
  }

  // MARK: Persistence

  private static let storageKey = "FailureStore.entries.v1"

  private func pruneExpired() {
    let cutoff = Date().addingTimeInterval(-Self.ttl)
    entries.removeAll { $0.failedAt < cutoff }
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let decoded = try? JSONDecoder().decode([Entry].self, from: data)
    else { return }
    entries = decoded
    pruneExpired()
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}

/// Stable per-game key used by FailureStore and SourcePreference.
///
/// ESPN event ID when present; otherwise a deterministic hash of
/// (league, teams, scheduledAt-rounded-to-day) so the same game on the
/// same day produces the same key across taps. Rounding to the day
/// avoids drift from minor scheduledTime updates.
enum GameKey {
  static func make(for game: Game) -> String {
    let id = game.id
    // ESPN event IDs are numeric strings ~10 digits. Aggregator-only games
    // synthesize their own IDs which may already be stable — use them as-is
    // when non-empty. Fall back to a derived hash only for the empty case.
    if !id.isEmpty, id != "0" { return "g:\(id)" }
    let day: String
    if let t = game.scheduledTime {
      let fmt = ISO8601DateFormatter()
      fmt.formatOptions = [.withFullDate]
      day = fmt.string(from: t)
    } else {
      day = "0"
    }
    let normalized = "\(game.league.rawValue)|\(game.homeTeam.lowercased())|\(game.awayTeam.lowercased())|\(day)"
    return "h:\(normalized.hashValue)"
  }
}
