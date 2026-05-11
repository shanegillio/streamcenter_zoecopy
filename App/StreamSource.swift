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

  let sources: [AnyStreamSource] = [
    AnyStreamSource(BuffStreamsSource())
  ]

  var selectedSource: AnyStreamSource

  private init() {
    let all = [AnyStreamSource(BuffStreamsSource())]
    selectedSource = all[0]
  }
}
