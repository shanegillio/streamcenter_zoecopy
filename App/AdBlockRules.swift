import WebKit

enum AdBlockRules {
  static let rulesJSON: String = """
  [
    {"trigger":{"url-filter":".*\\\\.doubleclick\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googlesyndication\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googletagmanager\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*googletagservices\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*google-analytics\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adnxs\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adsrvr\\\\.org.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*outbrain\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*taboola\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*popads\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*popcash\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*propellerads\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*exoclick\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*trafficjunky\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*ads\\\\..*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*\\\\.ad\\\\..*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*trackedlink\\\\.net.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*ero-advertising\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*juicyads\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*hilltopads\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*adsterra\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*mgid\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*revcontent\\\\.com.*"},"action":{"type":"block"}},
    {"trigger":{"url-filter":".*clickadu\\\\.com.*"},"action":{"type":"block"}}
  ]
  """

  static func compile() async -> WKContentRuleList? {
    try? await withCheckedThrowingContinuation { continuation in
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "StreamZoneAdBlock",
        encodedContentRuleList: rulesJSON
      ) { list, error in
        if let list = list {
          continuation.resume(returning: list)
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }
}
