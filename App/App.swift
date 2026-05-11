import SwiftUI

@main
struct AppDefinition: App {
  private let registry = SourceRegistry.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(registry)
    }
  }
}
