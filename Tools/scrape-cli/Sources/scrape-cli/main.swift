import Foundation
import AppKit

// Parse CLI args. Form:
//   scrape-cli <URL> [--timeout SECS] [--debounce SECS] [--click-delay SECS] [--api-only]
// Outputs JSON to stdout.

func usage() -> Never {
  FileHandle.standardError.write(
    Data("""
    Usage:
      scrape-cli <URL> [--timeout 30] [--debounce 4.0] [--click-delay 2.5] [--api-only]
      scrape-cli --logo-test "Team Name" <league-id>
        Resolve the team's ESPN logo URL and time the image fetch.
        league-id is one of: mlb, nba, wnba, nfl, ncaaf, nhl, ncaab, etc.

    """.utf8)
  )
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

var urlString: String? = nil
var timeout: TimeInterval = 30
var debounce: TimeInterval = 4.0
var clickDelay: TimeInterval = 2.5
var apiOnly = false
var fullFlow = false
var llmMode = false
var logoTestTeam: String? = nil
var logoTestLeague: String? = nil

var i = 1
while i < args.count {
  let a = args[i]
  switch a {
  case "--timeout":
    i += 1
    guard i < args.count, let v = Double(args[i]) else { usage() }
    timeout = v
  case "--debounce":
    i += 1
    guard i < args.count, let v = Double(args[i]) else { usage() }
    debounce = v
  case "--click-delay":
    i += 1
    guard i < args.count, let v = Double(args[i]) else { usage() }
    clickDelay = v
  case "--api-only":
    apiOnly = true
  case "--full-flow":
    fullFlow = true
  case "--llm":
    llmMode = true
  case "--logo-test":
    i += 1
    guard i + 1 < args.count else { usage() }
    logoTestTeam = args[i]
    logoTestLeague = args[i + 1]
    i += 1
  default:
    if a.hasPrefix("--") { usage() }
    urlString = a
  }
  i += 1
}

// --logo-test path doesn't need a URL.
if let team = logoTestTeam, let league = logoTestLeague {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  Task { @MainActor in
    let result = await LogoTestCLI.run(team: team, league: league)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(result),
       let s = String(data: data, encoding: .utf8) {
      print(s)
    }
    exit(0)
  }
  app.run()
}

guard let urlString, let url = URL(string: urlString) else { usage() }

// AppKit boilerplate so WKWebView has a real run loop (needed only for the
// scraping path; for --api-only we still use the run loop for URLSession).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  encoder.dateEncodingStrategy = .iso8601

  if llmMode {
    let result = await LLMScrapeCLI.run(baseURL: url, debounce: debounce, clickDelay: clickDelay, timeout: timeout)
    if let data = try? encoder.encode(result),
       let s = String(data: data, encoding: .utf8) {
      print(s)
    }
  } else if fullFlow {
    let result = await FullFlowCLI.run(baseURL: url)
    if let data = try? encoder.encode(result),
       let s = String(data: data, encoding: .utf8) {
      print(s)
    }
  } else if apiOnly {
    // Pure API-discovery probe. No WKWebView.
    let result = await APIDiscoveryCLI.discover(baseURL: url)
    if let data = try? encoder.encode(result),
       let s = String(data: data, encoding: .utf8) {
      print(s)
    }
  } else {
    let scraper = MacScraper(url: url, debounce: debounce, clickDelay: clickDelay, timeout: timeout)
    let result = await scraper.scrape()
    if let data = try? encoder.encode(result),
       let s = String(data: data, encoding: .utf8) {
      print(s)
    } else {
      FileHandle.standardError.write(Data("Failed to encode result\n".utf8))
      exit(2)
    }
  }
  exit(0)
}

app.run()
