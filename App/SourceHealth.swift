import Foundation

/// v2.30: rolling per-source health stats over a 7-day window.
///
/// Used by `PlayerView.searchSourcesForGamePage` to order the parallel
/// race by recent success rate, and by Settings → Source Stats to show
/// the user which sources are actually working. Source-agnostic — no
/// source IDs appear in code.
///
/// "Attempt" semantics: one attempt = one tap on a game that resulted in
/// PlayerView trying to extract a stream from that source. "Success" =
/// AVPlayer received a playable URL before all attempts exhausted.
/// "Parking" = scrape detected a ParkLogic / Rebrandly / sinkhole
/// outcome (the kind of failure we want to back off from hard).
@MainActor
final class SourceHealth: ObservableObject {
  static let shared = SourceHealth()

  /// Rolling window for the success-rate computation. Long enough to
  /// smooth over single bad nights; short enough that an aggressive
  /// site change shows up in ordering within a few days.
  static let window: TimeInterval = 7 * 24 * 60 * 60

  /// Demotion threshold. After at least `minAttemptsForDemotion`
  /// attempts, sources with success-rate below this go to the second
  /// wave in the parallel race.
  static let demotionThreshold: Double = 0.10
  static let minAttemptsForDemotion: Int = 5

  private struct Event: Codable {
    enum Kind: String, Codable { case attempt, success, parking }
    let sourceID: String
    let kind: Kind
    let at: Date
    let durationMs: Int?
  }

  @Published private(set) var stats: [String: Stats] = [:]
  private var events: [Event] = []

  /// Public read-only stats per source, computed from the event log.
  struct Stats: Equatable {
    let attempts: Int
    let successes: Int
    let parkingDetections: Int
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    /// 0...1. nil when attempts == 0.
    var successRate: Double? {
      guard attempts > 0 else { return nil }
      return Double(successes) / Double(attempts)
    }
  }

  private init() {
    load()
    recomputeStats()
  }

  // MARK: Recording

  func recordAttempt(sourceID: String) {
    appendEvent(Event(sourceID: sourceID, kind: .attempt, at: Date(), durationMs: nil))
  }

  func recordSuccess(sourceID: String, durationMs: Int? = nil) {
    appendEvent(Event(sourceID: sourceID, kind: .success, at: Date(), durationMs: durationMs))
  }

  /// Caller observed a parking page / sinkhole / Rebrandly redirect for
  /// this source. We don't hardcode the detection — `CustomStreamSource`
  /// already has the detection plumbing; it just calls us when it fires.
  func recordParking(sourceID: String) {
    appendEvent(Event(sourceID: sourceID, kind: .parking, at: Date(), durationMs: nil))
  }

  // MARK: Queries

  /// Orders the given source IDs by recent success rate, descending. Ties
  /// broken by recency of last attempt. Source-agnostic: no source-name
  /// branches.
  func orderedByHealth(_ sourceIDs: [String]) -> [String] {
    return sourceIDs.sorted { a, b in
      let sa = stats[a]
      let sb = stats[b]
      let ra = sa?.successRate ?? -1
      let rb = sb?.successRate ?? -1
      if ra != rb { return ra > rb }
      let la = sa?.lastAttemptAt ?? .distantPast
      let lb = sb?.lastAttemptAt ?? .distantPast
      return la > lb
    }
  }

  /// True iff the source's stats meet the demotion criteria. A demoted
  /// source still gets attempted — just only in the "second wave" if
  /// the high-health sources all returned nothing.
  func isDemoted(_ sourceID: String) -> Bool {
    guard let s = stats[sourceID], let rate = s.successRate else { return false }
    return s.attempts >= Self.minAttemptsForDemotion && rate < Self.demotionThreshold
  }

  /// True iff the source has recorded ≥3 parking detections within the
  /// past hour. Drives a hard cool-down — skip this source entirely
  /// until the next hour.
  func isInParkingCooldown(_ sourceID: String) -> Bool {
    let cutoff = Date().addingTimeInterval(-60 * 60)
    let recentParking = events.filter {
      $0.sourceID == sourceID && $0.kind == .parking && $0.at > cutoff
    }
    return recentParking.count >= 3
  }

  // MARK: Internals

  private func appendEvent(_ event: Event) {
    events.append(event)
    pruneExpired()
    recomputeStats()
    save()
  }

  private func pruneExpired() {
    let cutoff = Date().addingTimeInterval(-Self.window)
    events.removeAll { $0.at < cutoff }
  }

  private func recomputeStats() {
    var byID: [String: (attempts: Int, successes: Int, parking: Int,
                        lastAttempt: Date?, lastSuccess: Date?)] = [:]
    for e in events {
      var entry = byID[e.sourceID] ?? (0, 0, 0, nil, nil)
      switch e.kind {
      case .attempt:
        entry.attempts += 1
        if (entry.lastAttempt ?? .distantPast) < e.at { entry.lastAttempt = e.at }
      case .success:
        entry.successes += 1
        if (entry.lastSuccess ?? .distantPast) < e.at { entry.lastSuccess = e.at }
      case .parking:
        entry.parking += 1
      }
      byID[e.sourceID] = entry
    }
    stats = byID.mapValues {
      Stats(attempts: $0.attempts,
            successes: $0.successes,
            parkingDetections: $0.parking,
            lastAttemptAt: $0.lastAttempt,
            lastSuccessAt: $0.lastSuccess)
    }
  }

  // MARK: Persistence

  private static let storageKey = "SourceHealth.events.v1"

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
          let decoded = try? JSONDecoder().decode([Event].self, from: data)
    else { return }
    events = decoded
    pruneExpired()
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(events) else { return }
    UserDefaults.standard.set(data, forKey: Self.storageKey)
  }
}
