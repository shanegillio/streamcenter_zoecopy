import Foundation

/// v2.31 L2: HLS manifest structure scoring.
///
/// Fetches the master playlist (no segments) and parses the
/// `#EXT-X-*` tags. The score reflects the playlist's "shape" — live
/// vs VOD, presence of ad markers, count of variant renditions, max
/// resolution. These signals were chosen because they correlate
/// strongly with "this is the real broadcast" vs "this is an ad clip
/// or placeholder":
///
/// - A live broadcast omits `#EXT-X-ENDLIST` (the playlist grows
///   indefinitely). Ad pre-rolls are short VODs with an ENDLIST.
/// - Ad-stitched manifests carry `#EXT-X-CUE-OUT` / `#EXT-X-CUE-IN`
///   markers; unstitched broadcasts don't.
/// - Master playlists typically declare multiple renditions
///   (1080p/720p/480p/...); ad clips usually carry one.
/// - Max declared resolution is a coarse quality signal.
///
/// Returns nil on timeout or non-HLS content. Caller treats nil as
/// "no L2 contribution" — the candidate keeps its L1 score, no
/// penalty.
struct ManifestScore: Equatable {
  enum Kind: String, Codable { case live, vod, unknown }
  var value: Int
  var kind: Kind
  var hasAdMarkers: Bool
  var variantCount: Int
  var maxResolution: Int?
  /// Estimated VOD duration in seconds (sum of EXTINFs in a media
  /// playlist). nil when not a media playlist or no segments.
  var vodDurationSec: Double?
  var reasons: [String]
}

enum M3U8Scorer {

  static func score(_ url: URL,
                    headers: [String: String] = [:]) async -> ManifestScore? {
    guard let body = await fetch(url, headers: headers, timeout: 2.0) else {
      return nil
    }
    // Sniff: must contain "#EXTM3U" header.
    guard body.contains("#EXTM3U") else { return nil }

    let lines = body
      .replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    var hasEndlist = false
    var hasVODType = false
    var hasCueOut = false
    var variantCount = 0
    var maxResolution: Int? = nil
    var vodDuration: Double = 0
    var sawExtInf = false

    for line in lines {
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.isEmpty { continue }
      if t.hasPrefix("#EXT-X-ENDLIST") {
        hasEndlist = true
      } else if t.hasPrefix("#EXT-X-PLAYLIST-TYPE") {
        if t.uppercased().contains("VOD") { hasVODType = true }
      } else if t.hasPrefix("#EXT-X-CUE-OUT") {
        hasCueOut = true
      } else if t.hasPrefix("#EXT-X-STREAM-INF") {
        variantCount += 1
        if let res = parseResolution(from: t) {
          maxResolution = max(maxResolution ?? 0, res)
        }
      } else if t.hasPrefix("#EXTINF:") {
        sawExtInf = true
        // "#EXTINF:6.000,Title" → 6.000
        let after = t.dropFirst("#EXTINF:".count)
        let numStr = after.split(separator: ",").first.map(String.init) ?? String(after)
        if let d = Double(numStr) { vodDuration += d }
      }
    }

    let kind: ManifestScore.Kind
    if hasEndlist || hasVODType {
      kind = .vod
    } else if variantCount > 0 || sawExtInf {
      kind = .live
    } else {
      kind = .unknown
    }

    var value = 0
    var reasons: [String] = []

    switch kind {
    case .live:
      value += 20
      reasons.append("+20 live (no ENDLIST)")
    case .vod:
      // Short VOD is almost certainly an ad / placeholder.
      if sawExtInf, vodDuration > 0, vodDuration < 300 {
        value -= 30
        reasons.append("-30 short VOD (\(Int(vodDuration))s)")
      } else {
        // Long VOD (replays, archived games) is plausible content.
        value -= 5
        reasons.append("-5 VOD")
      }
    case .unknown:
      break
    }

    if hasCueOut {
      value -= 50
      reasons.append("-50 ad markers (CUE-OUT)")
    }

    if variantCount > 0 {
      // +5 per variant up to a cap, reflecting "real master playlist".
      let bonus = min(variantCount, 6) * 5
      value += bonus
      reasons.append("+\(bonus) variants (\(variantCount))")
    }

    if let res = maxResolution, res >= 720 {
      value += 10
      reasons.append("+10 ≥720p")
    }

    return ManifestScore(
      value: value,
      kind: kind,
      hasAdMarkers: hasCueOut,
      variantCount: variantCount,
      maxResolution: maxResolution,
      vodDurationSec: sawExtInf ? vodDuration : nil,
      reasons: reasons
    )
  }

  // MARK: - Helpers

  private static func parseResolution(from line: String) -> Int? {
    // "#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS=..."
    guard let range = line.range(of: "RESOLUTION=", options: .caseInsensitive)
    else { return nil }
    let tail = line[range.upperBound...]
    let value = tail.prefix { !$0.isWhitespace && $0 != "," }
    let parts = value.split(separator: "x")
    guard parts.count == 2, let h = Int(parts[1]) else { return nil }
    return h
  }

  private static func fetch(_ url: URL,
                            headers: [String: String],
                            timeout: TimeInterval) async -> String? {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    // Pretend to be a normal browser; some CDNs reject curl-like UAs.
    if req.value(forHTTPHeaderField: "User-Agent") == nil {
      req.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
      )
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        return nil
      }
      // HLS playlists are UTF-8 text. Reject non-text payloads quickly.
      if let mime = http.mimeType?.lowercased(),
         !mime.contains("mpegurl"), !mime.contains("text"), !mime.contains("octet-stream") {
        return nil
      }
      return String(data: data, encoding: .utf8)
    } catch {
      return nil
    }
  }
}
