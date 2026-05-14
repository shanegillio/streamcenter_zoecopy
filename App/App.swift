import SwiftUI

@main
struct AppDefinition: App {
  private let registry  = SourceRegistry.shared
  private let favorites = FavoritesStore.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(registry)
        .environment(favorites)
    }
  }
}
