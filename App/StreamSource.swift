import Foundation
import SwiftUI

protocol StreamSource {
  var id: String { get }
  var name: String { get }
  var baseURL: URL { get }

  /// v2.32: the source's only job. For each canonical Game in `games`,
  /// return the per-game page URL on this source whose anchor text or
  /// href contains both team names. Empty when this source has no
  /// matches today.
  func matchedGameURLs(amongCanonical games: [Game]) async -> [String: URL]
}

/// Type-erased wrapper around any `StreamSource` so the registry can
/// hold them in a single array regardless of concrete type.
struct AnyStreamSource: Identifiable, Equatable {
  let id: String
  let name: String
  let baseURL: URL
  let isBuiltIn: Bool
  private let _matchedGameURLs: ([Game]) async -> [String: URL]

  init<S: StreamSource>(_ source: S, builtIn: Bool = false) {
    id = source.id
    name = source.name
    baseURL = source.baseURL
    isBuiltIn = builtIn
    _matchedGameURLs = source.matchedGameURLs(amongCanonical:)
  }

  func matchedGameURLs(amongCanonical games: [Game]) async -> [String: URL] {
    await _matchedGameURLs(games)
  }

  static func == (lhs: AnyStreamSource, rhs: AnyStreamSource) -> Bool {
    lhs.id == rhs.id
  }
}

@Observable
final class SourceRegistry {
  static let shared = SourceRegistry()

  private(set) var sources: [AnyStreamSource]
  var selectedSource: AnyStreamSource
  /// v2.23: the set of source IDs the user has enabled for stream
  /// resolution. Multiple sources can be active simultaneously; the
  /// HomeView orchestrator pools their scrapes for gap-filling against
  /// ESPN's canonical listing, and on-tap stream resolution tries each
  /// in turn. `selectedSource` is retained for backwards compatibility
  /// with code paths not yet migrated; it's the "primary" of the pool.
  var enabledSourceIDs: Set<String> {
    didSet {
      UserDefaults.standard.set(Array(enabledSourceIDs), forKey: Self.enabledSourceIDsKey)
    }
  }

  /// Computed pool: every added source whose id is in `enabledSourceIDs`.
  /// Order follows `sources` (insertion order). Empty when no sources are
  /// enabled — HomeView treats that as "ESPN-only listing".
  var enabledSources: [AnyStreamSource] {
    sources.filter { enabledSourceIDs.contains($0.id) }
  }

  // Per-source recent scrape diagnostics, surfaced by the in-app
  // Settings → Source Diagnostics view. Keeps the last 30 entries per source.
  private var scrapeDiagnostics: [String: [ScrapeDiagnostic]] = [:]
  // The most recent scraped link list per source, used by DiagnosticsView to
  // show the raw extracted anchors/cards.
  private var lastScrapeLinks: [String: [ScrapedLink]] = [:]

  private static let customSourcesKey  = "customSources"
  private static let enabledSourceIDsKey = "enabledSourceIDs_v2.23"

  private init() {
    var all: [AnyStreamSource] = []
    if let saved = UserDefaults.standard.array(forKey: Self.customSourcesKey) as? [[String: String]] {
      for entry in saved {
        if let name = entry["name"], let urlStr = entry["url"], let url = URL(string: urlStr) {
          // A source is always the site root. Normalizing on load self-heals
          // any entry a prior version persisted as a deep game link (which
          // would make every fetch start from one stale game page).
          let root = GameURLResolver.rootURL(url)
          all.append(AnyStreamSource(CustomStreamSource(name: name, baseURL: root), builtIn: false))
        }
      }
    }
    sources = all
    selectedSource = all.first ?? AnyStreamSource(
      CustomStreamSource(name: "None", baseURL: URL(string: "about:blank")!),
      builtIn: false
    )
    if let persisted = UserDefaults.standard.array(forKey: Self.enabledSourceIDsKey) as? [String] {
      enabledSourceIDs = Set(persisted)
    } else {
      enabledSourceIDs = Set(all.map(\.id))
    }
  }

  // MARK: - Mirror replacement (called when HostFallback finds a working TLD variant)

  /// Replaces the URL of an existing source. Used when `HostFallback` finds a
  /// working TLD variant after the user-typed host failed DNS. Source ID
  /// stays the same so caches keyed by source ID keep working.
  func replaceSourceURL(originalID: String, newURL: URL) {
    guard let idx = sources.firstIndex(where: { $0.id == originalID }) else { return }
    let old = sources[idx]
    // Persist the site root only. Play-time host-fallback may hand us a deep
    // game URL that just failed; saving that as the source's base would pin
    // the whole source to one stale game page. Keep only the working host.
    let replacement = AnyStreamSource(
      CustomStreamSource(name: old.name, baseURL: GameURLResolver.rootURL(newURL)),
      builtIn: old.isBuiltIn
    )
    sources[idx] = replacement
    if selectedSource.id == originalID {
      selectedSource = replacement
    }
    persistCustomSources()
  }

  // MARK: - Scrape diagnostics (Settings → Source Diagnostics)

  func recordScrape(_ diagnostic: ScrapeDiagnostic, links: [ScrapedLink], for sourceID: String) {
    var entries = scrapeDiagnostics[sourceID] ?? []
    entries.insert(diagnostic, at: 0)
    if entries.count > 30 { entries = Array(entries.prefix(30)) }
    scrapeDiagnostics[sourceID] = entries
    if !links.isEmpty {
      lastScrapeLinks[sourceID] = links
    }
  }

  func recentScrapes(for sourceID: String) -> [ScrapeDiagnostic] {
    scrapeDiagnostics[sourceID] ?? []
  }

  func lastLinks(for sourceID: String) -> [ScrapedLink] {
    lastScrapeLinks[sourceID] ?? []
  }

  func addSource(name: String, urlString: String) -> Bool {
    var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
      cleaned = "https://" + cleaned
    }
    guard let parsed = URL(string: cleaned), parsed.host != nil else { return false }
    // Store the site root; the app derives game URLs from there by reading
    // the site, so a pasted deep link shouldn't pin the source to one game.
    let url = GameURLResolver.rootURL(parsed)
    guard !sources.contains(where: { $0.baseURL.host == url.host }) else { return false }
    let source = AnyStreamSource(CustomStreamSource(name: name, baseURL: url), builtIn: false)
    sources.append(source)
    // v2.23: newly-added sources are enabled by default — the v2.23 pool
    // model means "added" and "enabled" should be the same thing until
    // the user explicitly toggles one off in Settings.
    enabledSourceIDs.insert(source.id)
    persistCustomSources()
    return true
  }

  /// Edits an existing custom source's name and URL. Returns false when the
  /// name is empty, the URL is invalid, or the new host collides with a
  /// *different* existing source. The source id is derived from the host, so
  /// changing the host changes the id — we migrate the enabled flag and the
  /// current selection onto the new id so nothing silently drops out.
  @discardableResult
  func updateSource(_ source: AnyStreamSource, name: String, urlString: String) -> Bool {
    guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return false }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return false }
    var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
      cleaned = "https://" + cleaned
    }
    guard let parsed = URL(string: cleaned), parsed.host != nil else { return false }
    let url = GameURLResolver.rootURL(parsed)
    let newID = url.host ?? url.absoluteString
    if newID != source.id, sources.contains(where: { $0.id == newID }) { return false }
    let replacement = AnyStreamSource(CustomStreamSource(name: trimmedName, baseURL: url), builtIn: false)
    sources[idx] = replacement
    if source.id != newID, enabledSourceIDs.contains(source.id) {
      enabledSourceIDs.remove(source.id)
      enabledSourceIDs.insert(newID)
    }
    if selectedSource.id == source.id { selectedSource = replacement }
    persistCustomSources()
    return true
  }

  func removeSource(_ source: AnyStreamSource) {
    guard !source.isBuiltIn else { return }
    sources.removeAll { $0.id == source.id }
    enabledSourceIDs.remove(source.id)
    if selectedSource == source {
      selectedSource = sources.first ?? AnyStreamSource(
        CustomStreamSource(name: "None", baseURL: URL(string: "about:blank")!),
        builtIn: false
      )
    }
    persistCustomSources()
  }

  private func persistCustomSources() {
    let custom = sources.filter { !$0.isBuiltIn }.map { ["name": $0.name, "url": $0.baseURL.absoluteString] }
    UserDefaults.standard.set(custom, forKey: Self.customSourcesKey)
  }
}
