import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// `scrape-cli --measure`
///
/// Diagnostic: finds the true fixed token overhead of the game-matching
/// schema/instructions, and whether `includeSchemaInPrompt: false` actually
/// reduces it. Prints, for a few link counts, whether the call fits the
/// ~4096-token window and the token count when it overflows.
enum MeasureCLI {
  static func run() async {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      guard SystemLanguageModel.default.availability == .available else {
        print("model unavailable"); return
      }
      for includeSchema in [true, false] {
        for n in [0, 1, 3, 8] {
          var entries = ""
          for i in 0..<n {
            entries += "{\"u\":\"/mlb/san-diego-padres-chicago-cubs/13439\(i)\",\"t\":\"Chicago Cubs IN PROGRESS San Diego Padres\",\"s\":\"IN PROGRESS\"},"
          }
          let prompt = "Host: https://ibuffstreams.app\nLinks:\n[\(entries)]"
          let session = LanguageModelSession(instructions: MeasureMatch.instructions)
          do {
            _ = try await session.respond(to: prompt, generating: MeasureList.self, includeSchemaInPrompt: includeSchema)
            print("includeSchema=\(includeSchema) n=\(n): OK (fits)")
          } catch {
            let m = "\(error)"
            let tok = m.range(of: "contains ").flatMap { lo in
              m.range(of: " tokens").map { String(m[lo.upperBound..<$0.lowerBound]) }
            } ?? "?"
            print("includeSchema=\(includeSchema) n=\(n): OVERFLOW at \(tok) tokens")
          }
        }
      }
    } else {
      print("needs macOS 26")
    }
    #else
    print("FoundationModels not available")
    #endif
  }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct MeasureEntry {
  @Guide(description: "League")
  var league: String
  @Guide(description: "Home team")
  var homeTeam: String
  @Guide(description: "Away team")
  var awayTeam: String
  @Guide(description: "Date YYYY-MM-DD or empty")
  var scheduledDate: String
  @Guide(description: "True if live")
  var isLive: Bool
  @Guide(description: "The u value")
  var pageURL: String
}

@available(macOS 26.0, *)
@Generable
struct MeasureList {
  @Guide(description: "Games only")
  var games: [MeasureEntry]
}

@available(macOS 26.0, *)
enum MeasureMatch {
  static let instructions = "You extract sports games from link data. Skip nav and news."
}
#endif
