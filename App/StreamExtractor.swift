import Foundation

enum StreamExtractor {
  static func extractM3U8(from html: String, baseURL: URL) -> URL? {
    let patterns = [
      #"['"](https?://[^'"]+\.m3u8[^'"]*)['"']"#,
      #"file\s*:\s*['"](https?://[^'"]+)['"']"#,
      #"src\s*:\s*['"](https?://[^'"]+\.m3u8[^'"]*)['"']"#,
      #"source\s*:\s*\[?\s*\{?[^}]*['"](https?://[^'"]+\.m3u8[^'"]*)['"']"#,
      #"hls\.loadSource\(['"](https?://[^'"]+)['"']"#,
      #"Hls\.isSupported.*?['"](https?://[^'"]+\.m3u8[^'"]*)['"']"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
      let range = NSRange(html.startIndex..., in: html)
      let matches = regex.matches(in: html, range: range)
      for match in matches {
        guard match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else { continue }
        let urlStr = String(html[r])
        if let url = URL(string: urlStr) { return url }
      }
    }
    return nil
  }

  static func extractIframeURL(from html: String, base: URL) -> URL? {
    let pattern = #"<iframe[^>]+src=['"]([^'"]+)['"][^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    let matches = regex.matches(in: html, range: range)

    let adKeywords = ["ad", "google", "facebook", "twitter", "analytics", "recaptcha"]
    for match in matches {
      guard match.numberOfRanges >= 2,
            let r = Range(match.range(at: 1), in: html) else { continue }
      let src = String(html[r])
      let lower = src.lowercased()
      guard !adKeywords.contains(where: { lower.contains($0) }) else { continue }
      if let url = URL(string: src) { return url }
      if let url = URL(string: src, relativeTo: base)?.absoluteURL { return url }
    }
    return nil
  }
}
