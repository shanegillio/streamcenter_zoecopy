import Foundation

// Resolves team logo URLs dynamically via the ESPN search API and caches results
// in memory for the session. Static tables are checked first (instant); the API
// is only hit for teams not in the table (e.g. soccer clubs).
actor TeamLogoCache {
  static let shared = TeamLogoCache()

  private var cache: [String: URL?] = [:]

  func logoURL(for teamName: String, league: SportLeague) async -> URL? {
    let key = "\(league.id)|\(teamName.lowercased())"
    if let cached = cache[key] { return cached }

    // 1. Static table (fast, covers all US major sports + common soccer clubs)
    if let url = TeamLogoService.resolve(teamName: teamName, league: league) {
      cache[key] = url
      return url
    }

    // 2. ESPN search API (dynamic fallback for soccer and unknown teams)
    let url = await fetchFromESPN(teamName: teamName, league: league)
    cache[key] = url
    return url
  }

  private func fetchFromESPN(teamName: String, league: SportLeague) async -> URL? {
    guard !teamName.isEmpty,
          let encoded = teamName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/search?query=\(encoded)&type=team&limit=5")
    else { return nil }

    do {
      var request = URLRequest(url: url, timeoutInterval: 8)
      request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
      let (data, _) = try await URLSession.shared.data(for: request)
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["items"] as? [[String: Any]] else { return nil }

      let nameLower = teamName.lowercased()
      // Pick the best match: prefer exact name match, then first result
      let match = items.first(where: {
        ($0["displayName"] as? String)?.lowercased() == nameLower ||
        ($0["name"] as? String)?.lowercased() == nameLower
      }) ?? items.first(where: {
        let dn = ($0["displayName"] as? String ?? "").lowercased()
        return dn.contains(nameLower) || nameLower.contains(dn)
      }) ?? items.first

      guard let team = match,
            let logos = team["logos"] as? [[String: Any]],
            let href = logos.first?["href"] as? String else { return nil }
      return URL(string: href)
    } catch {
      return nil
    }
  }
}
