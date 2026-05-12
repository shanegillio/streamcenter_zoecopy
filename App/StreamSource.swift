import Foundation
import SwiftUI

protocol StreamSource {
  var id: String { get }
  var name: String { get }
  var baseURL: URL { get }

  func fetchAvailableLeagues() async throws -> [SportLeague]
  func fetchGames(for league: SportLeague) async throws -> [Game]
}

// Type-erased wrapper so sources with value or reference semantics both work
struct AnyStreamSource: Identifiable, Equatable {
  let id: String
  let name: String
  let baseURL: URL
  private let _fetchLeagues: () async throws -> [SportLeague]
  private let _fetchGames: (SportLeague) async throws -> [Game]

  init<S: StreamSource>(_ source: S) {
    id = source.id
    name = source.name
    baseURL = source.baseURL
    _fetchLeagues = source.fetchAvailableLeagues
    _fetchGames = source.fetchGames
  }

  func fetchAvailableLeagues() async throws -> [SportLeague] {
    try await _fetchLeagues()
  }

  func fetchGames(for league: SportLeague) async throws -> [Game] {
    try await _fetchGames(league)
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

  private static let customSourcesKey = "customSources"

  private init() {
    var all: [AnyStreamSource] = [AnyStreamSource(BuffStreamsSource())]
    if let saved = UserDefaults.standard.array(forKey: Self.customSourcesKey) as? [[String: String]] {
      for entry in saved {
        if let name = entry["name"], let urlStr = entry["url"], let url = URL(string: urlStr) {
          all.append(AnyStreamSource(CustomStreamSource(name: name, baseURL: url)))
        }
      }
    }
    sources = all
    selectedSource = all[0]
  }

  func addSource(name: String, urlString: String) -> Bool {
    var cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
      cleaned = "https://" + cleaned
    }
    guard let url = URL(string: cleaned), url.host != nil else { return false }
    let source = AnyStreamSource(CustomStreamSource(name: name, baseURL: url))
    guard !sources.contains(where: { $0.baseURL.host == url.host }) else { return false }
    sources.append(source)
    persistCustomSources()
    return true
  }

  func removeSource(_ source: AnyStreamSource) {
    guard source.id != "buffstreams" else { return }
    sources.removeAll { $0.id == source.id }
    if selectedSource == source { selectedSource = sources[0] }
    persistCustomSources()
  }

  private func persistCustomSources() {
    let custom = sources.dropFirst().map { ["name": $0.name, "url": $0.baseURL.absoluteString] }
    UserDefaults.standard.set(Array(custom), forKey: Self.customSourcesKey)
  }
}
