import Foundation
import Observation

/// Per-team logo-loading diagnostics. Records every URL resolution and image
/// fetch attempted by `TeamLogoCache` / `LogoPrefetcher`. Surfaced in
/// `DiagnosticsView` so we can see exactly which step is slow on any device.
///
/// Ring-buffered to the last 200 entries to keep memory bounded.
@Observable
@MainActor
final class TeamLogoDiagnostics {
  static let shared = TeamLogoDiagnostics()

  enum ResolveSource: String, Sendable {
    case staticTable    // TeamLogoService.resolve hit (microseconds)
    case espn           // ESPN search API fallback (network)
    case unresolved     // No URL produced
  }

  enum FetchOutcome: Sendable {
    case pending
    case cacheHit(bytes: Int)
    case networkOK(bytes: Int)
    case failed(reason: String)

    var label: String {
      switch self {
      case .pending:           return "PENDING"
      case .cacheHit:          return "CACHE HIT"
      case .networkOK:         return "NETWORK OK"
      case .failed:            return "FAILED"
      }
    }
  }

  struct Entry: Identifiable {
    let id = UUID()
    let team: String
    let league: SportLeague
    var url: URL?
    var resolveSource: ResolveSource
    var resolveMs: Int
    var fetchOutcome: FetchOutcome
    var fetchMs: Int?
    let timestamp: Date
  }

  private(set) var entries: [Entry] = []
  private static let cap = 200

  /// Record an initial resolution event. Subsequent `updateFetch` calls
  /// (keyed by team+league) update the same entry with fetch outcome.
  func recordResolve(team: String, league: SportLeague, url: URL?,
                     source: ResolveSource, resolveMs: Int) {
    let entry = Entry(
      team: team, league: league, url: url,
      resolveSource: source, resolveMs: resolveMs,
      fetchOutcome: .pending, fetchMs: nil,
      timestamp: Date()
    )
    // Replace any existing entry for this team+league so the diagnostic stays
    // current rather than accumulating duplicates.
    let key = TeamLogoDiagnostics.key(team: team, league: league)
    entries.removeAll { TeamLogoDiagnostics.key(team: $0.team, league: $0.league) == key }
    entries.insert(entry, at: 0)
    if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
  }

  func updateFetch(team: String, league: SportLeague,
                   outcome: FetchOutcome, fetchMs: Int) {
    let key = TeamLogoDiagnostics.key(team: team, league: league)
    if let idx = entries.firstIndex(where: { TeamLogoDiagnostics.key(team: $0.team, league: $0.league) == key }) {
      entries[idx].fetchOutcome = outcome
      entries[idx].fetchMs = fetchMs
    }
  }

  /// Summary counts for the header row in DiagnosticsView.
  var summary: (total: Int, cached: Int, network: Int, failed: Int, pending: Int, unresolved: Int) {
    var cached = 0, network = 0, failed = 0, pending = 0, unresolved = 0
    for e in entries {
      if e.resolveSource == .unresolved { unresolved += 1; continue }
      switch e.fetchOutcome {
      case .pending:    pending += 1
      case .cacheHit:   cached += 1
      case .networkOK:  network += 1
      case .failed:     failed += 1
      }
    }
    return (entries.count, cached, network, failed, pending, unresolved)
  }

  func reset() { entries.removeAll() }

  private static func key(team: String, league: SportLeague) -> String {
    "\(league.id)|\(team.lowercased())"
  }
}
