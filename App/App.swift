import SwiftUI

@main
struct AppDefinition: App {
  private let registry  = SourceRegistry.shared
  private let favorites = FavoritesStore.shared

  init() {
    // Generous URLCache so league/team logos persist across tab switches & app launches.
    // Default URLCache is too small (~20 MB disk) and gets evicted quickly.
    URLCache.shared = URLCache(
      memoryCapacity: 50 * 1024 * 1024,   // 50 MB
      diskCapacity:   200 * 1024 * 1024,  // 200 MB
      diskPath:       "StreamCenterImageCache"
    )
    // Prefetch every league logo so AsyncImage hits the cache instantly on first paint,
    // even after tab switches that recreate the views.
    Task.detached(priority: .utility) {
      await withTaskGroup(of: Void.self) { group in
        for league in SportLeague.allCases {
          guard let url = league.leagueLogoURL else { continue }
          group.addTask {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            _ = try? await URLSession.shared.data(for: request)
          }
        }
      }
    }
    // Pre-generate the AirPlay color-bars loading clip at launch so it's ready
    // before the first cast — no first-play "generating" hitch.
    Task { @MainActor in ColorBarsVideo.prewarm() }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(registry)
        .environment(favorites)
    }
  }
}
