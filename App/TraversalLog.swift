import Foundation
import Combine

/// v2.46: per-tap traversal session log. Captures everything that
/// happens during a single tap-to-play attempt so we can quantify how
/// reliably we navigate from a source's homepage to a playable stream.
///
/// Goal (per user): "create a testing method to see how well we are
/// traversing sites automatically to find a stream. The intent is that
/// the app is getting better at reading where a stream is and how to
/// click to it." Without a passive log, evaluating that across
/// iterations is anecdotal (screenshots, memory). With it, we get
/// labeled outcomes and event timelines we can compare version-over-
/// version.

struct TraversalSession: Codable, Identifiable {
  let id: UUID
  let startedAt: Date
  let sourceID: String
  let sourceName: String
  let sourceURL: String
  let gameHome: String
  let gameAway: String
  let gameLeague: String

  var navigationHops: [String]    // top-frame URLs visited, in order
  var events: [TraversalEvent]    // chronological shim events
  var capturedStreams: [String]   // m3u8/mpd URLs intercepted
  var endedAt: Date?
  var playbackOutcome: PlaybackOutcome?

  enum PlaybackOutcome: String, Codable { case worked, failed, unsure }

  // Derived
  var maxHopReached: Int { navigationHops.count }
  var streamCaptured: Bool { !capturedStreams.isEmpty }
  var durationMs: Int? {
    guard let endedAt else { return nil }
    return Int(endedAt.timeIntervalSince(startedAt) * 1000)
  }

  var gameTitle: String {
    gameAway.isEmpty ? gameHome : "\(gameAway) vs \(gameHome)"
  }
}

struct TraversalEvent: Codable, Identifiable {
  let id: UUID
  let at: Date
  let kind: String
  let info: String
  init(at: Date = Date(), kind: String, info: String) {
    self.id = UUID()
    self.at = at
    // Cap info at 200 chars to keep the log compact.
    self.kind = kind
    self.info = info.count > 200 ? String(info.prefix(200)) : info
  }
}

@MainActor
final class TraversalLog: ObservableObject {
  static let shared = TraversalLog()

  @Published private(set) var sessions: [TraversalSession] = []

  /// Cap to avoid unbounded growth on long-lived devices.
  private static let maxSessions = 100

  /// Debounce disk writes so a busy session doesn't thrash the disk.
  private var saveTask: Task<Void, Never>?

  private init() {
    load()
  }

  // MARK: Recording API

  func startSession(sourceID: String, sourceName: String, sourceURL: URL,
                    gameHome: String, gameAway: String, gameLeague: String) -> UUID {
    let id = UUID()
    let session = TraversalSession(
      id: id,
      startedAt: Date(),
      sourceID: sourceID,
      sourceName: sourceName,
      sourceURL: sourceURL.absoluteString,
      gameHome: gameHome,
      gameAway: gameAway,
      gameLeague: gameLeague,
      navigationHops: [sourceURL.absoluteString],
      events: [],
      capturedStreams: [],
      endedAt: nil,
      playbackOutcome: nil
    )
    sessions.insert(session, at: 0)
    if sessions.count > Self.maxSessions {
      sessions = Array(sessions.prefix(Self.maxSessions))
    }
    scheduleSave()
    return id
  }

  func recordEvent(_ id: UUID, kind: String, info: String) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    sessions[idx].events.append(TraversalEvent(kind: kind, info: info))
    scheduleSave()
  }

  func recordNavigation(_ id: UUID, url: URL) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    let s = url.absoluteString
    // De-dupe consecutive identical commits (didCommit fires for some
    // intra-page state changes that don't actually navigate)
    if sessions[idx].navigationHops.last != s {
      sessions[idx].navigationHops.append(s)
      sessions[idx].events.append(TraversalEvent(kind: "navigation", info: s))
      scheduleSave()
    }
  }

  func recordStream(_ id: UUID, url: URL) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    let s = url.absoluteString
    if !sessions[idx].capturedStreams.contains(s) {
      sessions[idx].capturedStreams.append(s)
      sessions[idx].events.append(TraversalEvent(kind: "stream_url", info: s))
      scheduleSave()
    }
  }

  func endSession(_ id: UUID) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    if sessions[idx].endedAt == nil {
      sessions[idx].endedAt = Date()
      scheduleSave()
    }
  }

  func markOutcome(_ id: UUID, _ outcome: TraversalSession.PlaybackOutcome) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    sessions[idx].playbackOutcome = outcome
    scheduleSave()
  }

  func clearAll() {
    sessions = []
    saveNow()
  }

  // MARK: Aggregate stats

  struct AggregateStats {
    let totalSessions: Int
    let reachedHop2: Int
    let capturedStreams: Int
    let outcomeWorked: Int
    /// Per-sourceID summary: name → (attempts, reached-Hop2, captured, worked)
    let perSource: [(name: String, attempts: Int, hop2: Int, captured: Int, worked: Int)]
  }

  /// Computes stats over sessions in the last `windowDays` days.
  func aggregateStats(windowDays: Int = 7) -> AggregateStats {
    let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86400)
    let recent = sessions.filter { $0.startedAt >= cutoff }
    let total = recent.count
    let hop2 = recent.filter { $0.maxHopReached >= 2 }.count
    let captured = recent.filter { $0.streamCaptured }.count
    let worked = recent.filter { $0.playbackOutcome == .worked }.count

    var bySource: [String: (name: String, attempts: Int, hop2: Int, captured: Int, worked: Int)] = [:]
    for s in recent {
      var entry = bySource[s.sourceID] ?? (s.sourceName, 0, 0, 0, 0)
      entry.attempts += 1
      if s.maxHopReached >= 2 { entry.hop2 += 1 }
      if s.streamCaptured { entry.captured += 1 }
      if s.playbackOutcome == .worked { entry.worked += 1 }
      bySource[s.sourceID] = entry
    }
    let perSource = bySource.values
      .sorted { $0.attempts > $1.attempts }
      .map { (name: $0.name, attempts: $0.attempts, hop2: $0.hop2,
              captured: $0.captured, worked: $0.worked) }
    return AggregateStats(
      totalSessions: total,
      reachedHop2: hop2,
      capturedStreams: captured,
      outcomeWorked: worked,
      perSource: perSource
    )
  }

  // MARK: Persistence

  private static var storeURL: URL {
    let docs = FileManager.default.urls(for: .documentDirectory,
                                        in: .userDomainMask).first!
    return docs.appendingPathComponent("traversal-log.json")
  }

  private func load() {
    guard let data = try? Data(contentsOf: Self.storeURL),
          let decoded = try? JSONDecoder().decode([TraversalSession].self, from: data)
    else { return }
    sessions = decoded
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms debounce
      guard !Task.isCancelled else { return }
      await MainActor.run { self?.saveNow() }
    }
  }

  private func saveNow() {
    guard let data = try? JSONEncoder().encode(sessions) else { return }
    try? data.write(to: Self.storeURL, options: [.atomic])
  }
}
