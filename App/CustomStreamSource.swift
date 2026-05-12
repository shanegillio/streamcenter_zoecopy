import Foundation

struct CustomStreamSource: StreamSource {
  let name: String
  let baseURL: URL

  var id: String { baseURL.host ?? baseURL.absoluteString }

  func fetchAvailableLeagues() async throws -> [SportLeague] { [] }
  func fetchGames(for league: SportLeague) async throws -> [Game] { [] }
}
