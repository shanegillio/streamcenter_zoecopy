// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "scrape-cli",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "scrape-cli",
      path: "Sources/scrape-cli"
    )
  ]
)
