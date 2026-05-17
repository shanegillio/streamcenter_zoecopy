import Foundation

// Synchronous read-through mirror of TeamLogoCache.
// Updated by the actor whenever a URL is resolved; lets TeamLogo views
// read previously-resolved URLs on their first render with zero async overhead,
// eliminating the one-frame "initials flash" when lists are rebuilt.
//
// PERSISTED to UserDefaults under `teamLogoStore.v1`. On launch the dict is
// rehydrated, so every team we've ever seen has a URL ready before any view
// renders — combined with URLCache.shared (50/200 MB, disk-persistent), the
// second-and-later launches paint logos with zero network round-trip.
@Observable
final class TeamLogoStore {
  static let shared = TeamLogoStore()
  private static let prefsKey = "teamLogoStore.v1"
  private(set) var urls: [String: URL]

  init() {
    if let raw = UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String] {
      var loaded: [String: URL] = [:]
      for (k, v) in raw {
        if let u = URL(string: v) { loaded[k] = u }
      }
      self.urls = loaded
    } else {
      self.urls = [:]
    }
  }

  func store(url: URL, key: String) {
    urls[key] = url
    // Persist on every store. Cheap — UserDefaults coalesces writes, and the
    // dict tops out at a few hundred keys (one per unique (team, league) pair).
    let raw = urls.mapValues { $0.absoluteString }
    UserDefaults.standard.set(raw, forKey: Self.prefsKey)
  }

  func url(for key: String) -> URL? { urls[key] }
}

// Resolves team logo URLs dynamically via the ESPN search API and caches results
// in memory for the session. Static tables are checked first (instant); the API
// is only hit for teams not in the table (e.g. soccer clubs).
actor TeamLogoCache {
  static let shared = TeamLogoCache()

  private var cache: [String: URL?] = [:]

  func logoURL(for teamName: String, league: SportLeague) async -> URL? {
    let key = "\(league.id)|\(teamName.lowercased())"
    if let cached = cache[key] { return cached }

    let start = Date()

    // 1. Static table (fast, covers all US major sports + common soccer clubs)
    if let url = TeamLogoService.resolve(teamName: teamName, league: league) {
      cache[key] = url
      let resolveMs = Int(Date().timeIntervalSince(start) * 1000)
      let team_ = teamName
      let league_ = league
      let url_ = url
      await MainActor.run {
        TeamLogoStore.shared.store(url: url_, key: key)
        TeamLogoDiagnostics.shared.recordResolve(
          team: team_, league: league_, url: url_,
          source: .staticTable, resolveMs: resolveMs
        )
      }
      return url
    }

    // 2. ESPN search API (dynamic fallback for soccer and unknown teams)
    let url = await fetchFromESPN(teamName: teamName, league: league)
    cache[key] = url
    let resolveMs = Int(Date().timeIntervalSince(start) * 1000)
    let team_ = teamName
    let league_ = league
    let url_ = url
    await MainActor.run {
      if let u = url_ {
        TeamLogoStore.shared.store(url: u, key: key)
      }
      TeamLogoDiagnostics.shared.recordResolve(
        team: team_, league: league_, url: url_,
        source: url_ == nil ? .unresolved : .espn,
        resolveMs: resolveMs
      )
    }
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
