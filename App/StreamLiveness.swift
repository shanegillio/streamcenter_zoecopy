import Foundation

/// v2.72: host-agnostic verification that a captured stream is a LIVE, reachable
/// playlist — the one signal takedown-evading aggregators can't fake by rotating
/// hosts/tokens. A real live game is a sliding HLS/DASH live window whose first
/// segment loads *right now*; filler loops, ad pre-rolls, recordings, dead
/// endpoints, and gated CDNs (segments 403) all fail this. Used as a commit gate
/// so we don't get fooled into committing a wrong/dead stream just because its
/// manifest parsed. Sources here are all live games, so VOD/finite = reject.
enum StreamLiveness {
  private static let userAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  /// True iff `url` resolves to a live, currently-reachable stream. `referer`
  /// and `cookies` are the same request context playback will use, so a gated
  /// CDN is judged under the conditions AVPlayer (or the WebView) will face.
  static func isLive(_ url: URL, referer: URL?, cookies: [HTTPCookie]) async -> Bool {
    let lower = url.absoluteString.lowercased()

    // DASH: liveness is explicit in the MPD root (`type="dynamic"` vs "static").
    if lower.contains(".mpd") {
      guard let text = await fetchText(url, referer: referer, cookies: cookies) else { return false }
      return text.range(of: "type=\"dynamic\"", options: .caseInsensitive) != nil
    }

    // HLS.
    guard let text = await fetchText(url, referer: referer, cookies: cookies),
          text.contains("#EXTM3U") else { return false }

    // Master playlist → resolve the first variant and check that media playlist.
    if text.range(of: "#EXT-X-STREAM-INF", options: .caseInsensitive) != nil {
      guard let variant = firstResourceURI(in: text, base: url),
            let vtext = await fetchText(variant, referer: referer, cookies: cookies),
            vtext.contains("#EXTM3U") else { return false }
      return await isLiveMedia(vtext, mediaURL: variant, referer: referer, cookies: cookies)
    }
    return await isLiveMedia(text, mediaURL: url, referer: referer, cookies: cookies)
  }

  /// A media playlist is a live game iff it isn't finite/VOD and its first
  /// segment is reachable under the playback request context.
  private static func isLiveMedia(_ text: String, mediaURL: URL,
                                  referer: URL?, cookies: [HTTPCookie]) async -> Bool {
    if text.range(of: "#EXT-X-ENDLIST", options: .caseInsensitive) != nil { return false }
    if text.range(of: "#EXT-X-PLAYLIST-TYPE:VOD", options: .caseInsensitive) != nil { return false }
    guard let segment = firstResourceURI(in: text, base: mediaURL) else { return false }
    return await segmentReachable(segment, referer: referer, cookies: cookies)
  }

  /// First non-comment, non-tag line resolved against `base` — a variant
  /// playlist URI in a master, or a segment URI in a media playlist.
  private static func firstResourceURI(in text: String, base: URL) -> URL? {
    for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      return URL(string: line, relativeTo: base)?.absoluteURL
    }
    return nil
  }

  /// Range-request the first bytes of a segment to confirm it actually serves
  /// data now (catches gated/dead endpoints whose manifest parses but whose
  /// segments 403/404). Lenient on ambiguous transport errors so a transient
  /// blip doesn't reject a good stream; only an explicit 4xx/5xx is a reject.
  private static func segmentReachable(_ url: URL, referer: URL?, cookies: [HTTPCookie]) async -> Bool {
    var req = URLRequest(url: url)
    req.timeoutInterval = 5
    applyHeaders(&req, referer: referer, cookies: cookies)
    req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse else { return true }
      if (200...299).contains(http.statusCode) { return true }
      if (400...599).contains(http.statusCode) { return false }
      return true
    } catch {
      return true
    }
  }

  private static func fetchText(_ url: URL, referer: URL?, cookies: [HTTPCookie]) async -> String? {
    var req = URLRequest(url: url)
    req.timeoutInterval = 5
    applyHeaders(&req, referer: referer, cookies: cookies)
    guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
    // Manifests are small; cap to avoid decoding a huge mis-captured body.
    let slice = data.count > 524_288 ? data.prefix(524_288) : data[...]
    return String(data: slice, encoding: .utf8)
  }

  private static func applyHeaders(_ req: inout URLRequest, referer: URL?, cookies: [HTTPCookie]) {
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let referer {
      req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
      req.setValue((referer.scheme ?? "https") + "://" + (referer.host ?? ""), forHTTPHeaderField: "Origin")
    }
    if !cookies.isEmpty {
      for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { req.setValue(v, forHTTPHeaderField: k) }
    }
  }
}
