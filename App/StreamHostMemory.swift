import Foundation

/// v2.71: per-source memory of which stream hosts actually played vs. which
/// were wrong. Solves the "we reached the right page but committed a totally
/// unrelated .m3u8" problem (ppv.to → `netanyahu.india…/index.m3u8`): once we
/// know the *style* of host a source's real streams come from, we prefer those
/// and reject hosts we've seen fail — source-agnostic, learned from observation
/// (confirmed playback + the user's Worked/Didn't taps), never hardcoded.
///
/// Hosts are stored as registrable domains (last two labels) so a CDN that
/// rotates subdomains (shiva.indianservers.st ↔ node2.indianservers.st) is
/// still recognized as the same known-good source.
@MainActor
final class StreamHostMemory: ObservableObject {
  static let shared = StreamHostMemory()

  private var good: [String: Set<String>] = [:]  // sourceID -> registrable domains
  private var bad: [String: Set<String>] = [:]

  private init() { load() }

  /// Registrable domain = the last two dot-labels of a host
  /// ("shiva.indianservers.st" -> "indianservers.st").
  static func registrableDomain(_ host: String?) -> String? {
    guard let host = host?.lowercased(), !host.isEmpty else { return nil }
    let parts = host.split(separator: ".")
    guard parts.count >= 2 else { return host }
    return parts.suffix(2).joined(separator: ".")
  }

  func goodDomains(for sourceID: String) -> Set<String> { good[sourceID] ?? [] }
  func badDomains(for sourceID: String) -> Set<String> { bad[sourceID] ?? [] }
  func hasGood(for sourceID: String) -> Bool { !(good[sourceID]?.isEmpty ?? true) }

  func isKnownGood(sourceID: String, host: String?) -> Bool {
    guard let d = Self.registrableDomain(host) else { return false }
    return good[sourceID]?.contains(d) ?? false
  }

  func isKnownBad(sourceID: String, host: String?) -> Bool {
    guard let d = Self.registrableDomain(host) else { return false }
    // A domain we've confirmed good is never treated as bad, even if an
    // earlier failure (e.g. a transient gating issue) recorded it.
    if good[sourceID]?.contains(d) == true { return false }
    return bad[sourceID]?.contains(d) ?? false
  }

  /// A stream from `streamURL` produced confirmed playback for `sourceID`.
  func recordGood(sourceID: String, streamURL: URL) {
    guard let d = Self.registrableDomain(streamURL.host) else { return }
    good[sourceID, default: []].insert(d)
    bad[sourceID]?.remove(d)
    save()
  }

  /// A stream from `streamURL` was confirmed wrong/unplayable for `sourceID`.
  func recordBad(sourceID: String, streamURL: URL) {
    guard let d = Self.registrableDomain(streamURL.host) else { return }
    // Never demote a domain we've seen genuinely work.
    if good[sourceID]?.contains(d) == true { return }
    bad[sourceID, default: []].insert(d)
    save()
  }

  // MARK: Persistence

  private static let goodKey = "StreamHostMemory.good.v1"
  private static let badKey  = "StreamHostMemory.bad.v1"

  private func load() {
    if let raw = UserDefaults.standard.dictionary(forKey: Self.goodKey) as? [String: [String]] {
      good = raw.mapValues(Set.init)
    }
    if let raw = UserDefaults.standard.dictionary(forKey: Self.badKey) as? [String: [String]] {
      bad = raw.mapValues(Set.init)
    }
  }

  private func save() {
    UserDefaults.standard.set(good.mapValues(Array.init), forKey: Self.goodKey)
    UserDefaults.standard.set(bad.mapValues(Array.init), forKey: Self.badKey)
  }
}
