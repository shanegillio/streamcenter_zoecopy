import Foundation

/// v2.31 L5: real playability probe — replaces AVURLAsset.isPlayable.
///
/// `AVURLAsset.isPlayable` returns true for any manifest that exists,
/// even if its segments 403/timeout. The user-visible failure is
/// AVPlayer opening, staying black, then surfacing the play-with-line-
/// through-it failed icon — a probe-true / play-false split. This
/// probe closes that gap by:
///
/// 1. Fetching the manifest and picking the first media segment URL.
/// 2. Issuing a `Range: bytes=0-1023` request for that segment.
/// 3. Treating 200/206 as playable. 4xx/5xx/timeout as not.
///
/// Steps 1 and 2 use `URLSession` directly so we control timeouts and
/// can pass referer/origin/cookies forwarded from the WebView session
/// — same headers AVPlayer will use, so a probe pass means AVPlayer
/// pass.
struct ProbeResult: Equatable {
  let manifestOK: Bool
  let firstSegmentOK: Bool
  /// Bytes returned by the segment Range request. 0 when the probe
  /// got a redirect chain to nowhere or empty body.
  let firstSegmentBytes: Int
  /// True iff both manifest and first segment fetched cleanly. This
  /// is the gate for committing the URL to AVPlayer.
  var passed: Bool { manifestOK && firstSegmentOK && firstSegmentBytes > 0 }
}

enum SegmentProbe {

  /// Total timeout budget across manifest fetch + segment fetch.
  static let defaultTimeout: TimeInterval = 2.0

  static func probe(_ manifestURL: URL,
                    headers: [String: String] = [:],
                    timeout: TimeInterval = defaultTimeout) async -> ProbeResult {
    let deadline = Date().addingTimeInterval(timeout)

    // Step 1: fetch manifest.
    guard let body = await fetchText(
      manifestURL,
      headers: headers,
      timeout: max(0.5, deadline.timeIntervalSinceNow * 0.6)
    ), body.contains("#EXTM3U") else {
      return ProbeResult(manifestOK: false, firstSegmentOK: false, firstSegmentBytes: 0)
    }

    // Step 2: find the first media segment URL.
    // Master playlist case: first #EXT-X-STREAM-INF → next non-comment
    //   line is a media-playlist URL → recursively resolve.
    // Media playlist case: first non-comment line after #EXTINF.
    guard let firstSegmentURL = await findFirstSegmentURL(
      manifestBody: body,
      base: manifestURL,
      headers: headers,
      deadline: deadline
    ) else {
      return ProbeResult(manifestOK: true, firstSegmentOK: false, firstSegmentBytes: 0)
    }

    // Step 3: Range-probe the segment.
    let remaining = max(0.3, deadline.timeIntervalSinceNow)
    let bytes = await rangeFetch(firstSegmentURL, headers: headers, timeout: remaining)
    return ProbeResult(
      manifestOK: true,
      firstSegmentOK: bytes > 0,
      firstSegmentBytes: bytes
    )
  }

  // MARK: - Walk the playlist

  /// Walks one level into a master playlist if needed; returns the first
  /// actual media segment URL.
  private static func findFirstSegmentURL(
    manifestBody: String,
    base: URL,
    headers: [String: String],
    deadline: Date
  ) async -> URL? {
    let lines = manifestBody
      .replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    var isMaster = false
    var pickNextNonComment = false
    var firstNonCommentURL: URL?

    for line in lines {
      if line.isEmpty { continue }
      if line.hasPrefix("#EXT-X-STREAM-INF") {
        isMaster = true
        pickNextNonComment = true
        continue
      }
      if pickNextNonComment, !line.hasPrefix("#") {
        firstNonCommentURL = resolve(line, against: base)
        break
      }
      if !isMaster, line.hasPrefix("#EXTINF") {
        pickNextNonComment = true
        continue
      }
    }

    guard let url = firstNonCommentURL else { return nil }
    if !isMaster {
      // Media playlist — line is already a segment URL.
      return url
    }

    // Master playlist — `url` is a media playlist; recurse one level
    // (capped at one to avoid runaway).
    guard deadline.timeIntervalSinceNow > 0.3,
          let body = await fetchText(
            url,
            headers: headers,
            timeout: deadline.timeIntervalSinceNow * 0.5
          ),
          body.contains("#EXTM3U")
    else { return nil }
    let mediaLines = body
      .replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    var pickNext = false
    for line in mediaLines {
      if line.isEmpty { continue }
      if line.hasPrefix("#EXTINF") { pickNext = true; continue }
      if pickNext, !line.hasPrefix("#") {
        return resolve(line, against: url)
      }
    }
    return nil
  }

  // MARK: - HTTP

  private static func fetchText(
    _ url: URL,
    headers: [String: String],
    timeout: TimeInterval
  ) async -> String? {
    var req = URLRequest(url: url, timeoutInterval: max(0.3, timeout))
    applyDefaultHeaders(&req, override: headers)
    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
      else { return nil }
      return String(data: data, encoding: .utf8)
    } catch {
      return nil
    }
  }

  private static func rangeFetch(
    _ url: URL,
    headers: [String: String],
    timeout: TimeInterval
  ) async -> Int {
    var req = URLRequest(url: url, timeoutInterval: max(0.3, timeout))
    applyDefaultHeaders(&req, override: headers)
    req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse else { return 0 }
      // 200 (server ignored Range) and 206 (partial) both fine.
      guard http.statusCode == 200 || http.statusCode == 206 else { return 0 }
      return data.count
    } catch {
      return 0
    }
  }

  private static func applyDefaultHeaders(_ req: inout URLRequest,
                                          override: [String: String]) {
    for (k, v) in override { req.setValue(v, forHTTPHeaderField: k) }
    if req.value(forHTTPHeaderField: "User-Agent") == nil {
      req.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
      )
    }
  }

  private static func resolve(_ pathOrURL: String, against base: URL) -> URL? {
    if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") {
      return URL(string: pathOrURL)
    }
    return URL(string: pathOrURL, relativeTo: base)?.absoluteURL
  }
}
