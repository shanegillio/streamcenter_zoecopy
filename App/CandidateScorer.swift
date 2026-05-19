import Foundation

/// v2.31: candidate accumulator + total-score selection policy.
///
/// Replaces the v2.30 "first URL that passes AVURLAsset.isPlayable
/// wins" decision in `StreamWebView.Coordinator`. Now: every URL the
/// JS-shim reports becomes a `Candidate`. We compute L1 (URL
/// fingerprint), kick off L2 (manifest fetch) and L5 (segment probe)
/// async, accumulate for a short window, then pick the highest-scored
/// candidate that the probe says is actually playable.
///
/// All of this is source-agnostic. There's no list of "good sources"
/// or "this site's mirrors usually look like X." The signals
/// themselves (ad-server host? live manifest? team slugs in URL? LIVE
/// badge near the click that produced it?) carry all the discrimination
/// the system needs.

// MARK: - DOM context (mirror of the JS-shim payload)

struct DOMContext: Equatable, Codable {
  enum Kind: String, Codable {
    case navigation, xhr, fetch, videoElement, mirrorClick, scriptRegex,
         metaTag, iframeSrc, websocket, mimeSniff, unknown
  }
  var kind: Kind
  var originHost: String?
  /// innerText of up to 6 ancestors, lowercased, trimmed to ~500 chars.
  var parentText: String
  var iframeSrc: String?
  var hasLiveBadge: Bool
  /// Parsed integer when a viewer-count chip was nearby (12.4K → 12400).
  var viewerCount: Int?

  static let unknown = DOMContext(
    kind: .unknown, originHost: nil, parentText: "",
    iframeSrc: nil, hasLiveBadge: false, viewerCount: nil
  )
}

// MARK: - Candidate

struct Candidate: Equatable {
  let url: URL
  let context: DOMContext
  let observedAt: Date
  var urlScore: URLScore
  var manifestScore: ManifestScore?
  var domScoreValue: Int
  var domReasons: [String]
  var probeResult: ProbeResult?

  /// Total score. Hard-rejected URLs are pinned to a sentinel (-∞-ish)
  /// so they never bubble up regardless of other contributions.
  var total: Int {
    if urlScore.rejected { return Int.min / 2 }
    return urlScore.value
      + (manifestScore?.value ?? 0)
      + domScoreValue
  }

  /// Probe gate: only candidates that affirmatively passed the segment
  /// probe are commit-eligible at top-of-window. (When the window
  /// expires without any probe pass, we relax to "manifestOK+positive
  /// total" via the fallback path.)
  var probePassed: Bool { probeResult?.passed == true }

  /// Reasons assembled across L1+L2+L3 — surfaced in Source Stats.
  var reasonsCombined: [String] {
    var out = urlScore.reasons
    out.append(contentsOf: manifestScore?.reasons ?? [])
    out.append(contentsOf: domReasons)
    return out
  }
}

// MARK: - DOM scoring

enum DOMScorer {
  /// Returns (value, reasons). All signals are bounded and additive.
  static func score(_ ctx: DOMContext,
                    targetGame: Game?) -> (Int, [String]) {
    var value = 0
    var reasons: [String] = []

    if ctx.hasLiveBadge {
      value += 25
      reasons.append("+25 LIVE badge")
    }
    if let n = ctx.viewerCount, n > 0 {
      value += 10
      reasons.append("+10 viewers=\(n)")
    }
    if let game = targetGame {
      let text = ctx.parentText  // already lowercased by the JS-shim
      let homeKey = normalize(game.homeTeam)
      let awayKey = normalize(game.awayTeam)
      var matched = 0
      if !homeKey.isEmpty, text.contains(homeKey) { matched += 1 }
      if !awayKey.isEmpty, text.contains(awayKey) { matched += 1 }
      if matched == 2 {
        value += 15
        reasons.append("+15 both teams in DOM context")
      } else if matched == 1 {
        value += 6
        reasons.append("+6 one team in DOM context")
      }
    }
    if ctx.kind == .mirrorClick {
      value += 10
      reasons.append("+10 from mirror click")
    }
    if ctx.kind == .iframeSrc,
       let frame = ctx.iframeSrc.flatMap(URL.init(string:))?.host?.lowercased(),
       let origin = ctx.originHost?.lowercased(),
       !frame.isEmpty, !origin.isEmpty, !frame.hasSuffix(origin), !origin.hasSuffix(frame) {
      value -= 15
      reasons.append("-15 cross-domain iframe")
    }
    if ctx.parentText.range(
      of: #"sponsored|advertisement|\bad\b|promo|banner"#,
      options: .regularExpression
    ) != nil {
      value -= 20
      reasons.append("-20 ad-text near URL")
    }
    return (value, reasons)
  }

  private static func normalize(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
  }
}

// MARK: - Accumulator + selection policy

/// Holds the in-flight candidate set for one playback attempt. The
/// coordinator owns one instance per StreamWebView. After
/// `commit(...)` fires, no further work is processed.
@MainActor
final class CandidatePool {
  let targetGame: Game?
  let sourceID: String
  /// Headers to use for L2 manifest + L5 segment probes — should
  /// match what AVPlayer will use (Referer/Origin/User-Agent),
  /// otherwise a probe pass could mismatch the actual play.
  let probeHeaders: [String: String]
  /// Set of hostnames known to have produced working streams on this
  /// source (informs L1 +10 boost).
  let knownGoodHosts: Set<String>

  /// First URL observed regardless of score — used as a last-ditch
  /// commit if the accumulation window expires with no probe pass.
  private(set) var firstObserved: Candidate?
  private(set) var all: [Candidate] = []
  /// Set once we've committed; subsequent reports are ignored.
  private(set) var commitedURL: URL?

  /// Triggered once when a candidate passes commit-eligibility OR the
  /// window expires.
  private let onCommit: (Candidate?) -> Void
  /// Wall-clock deadline for the accumulation window.
  private(set) var deadline: Date?
  /// Maximum time we wait from first observation before forcing a
  /// commit decision.
  private let accumulationWindow: TimeInterval
  /// Hard ceiling — if even the fallback expires without anything
  /// playable, we hand `nil` to onCommit so the player surfaces "no
  /// playable stream".
  private let hardDeadline: TimeInterval
  private var didFinish = false

  init(targetGame: Game?,
       sourceID: String,
       probeHeaders: [String: String],
       knownGoodHosts: Set<String>,
       accumulationWindow: TimeInterval = 6.0,
       hardDeadline: TimeInterval = 10.0,
       onCommit: @escaping (Candidate?) -> Void) {
    self.targetGame = targetGame
    self.sourceID = sourceID
    self.probeHeaders = probeHeaders
    self.knownGoodHosts = knownGoodHosts
    self.accumulationWindow = accumulationWindow
    self.hardDeadline = hardDeadline
    self.onCommit = onCommit
  }

  /// Add a URL with DOM context. May trigger scoring tasks. Returns
  /// the added candidate (or nil if it was hard-rejected).
  @discardableResult
  func ingest(url: URL, context: DOMContext) -> Candidate? {
    guard commitedURL == nil, !didFinish else { return nil }
    // Dedupe.
    if all.contains(where: { $0.url == url }) { return nil }

    let l1 = URLFingerprint.score(
      url, targetGame: targetGame, knownGoodHosts: knownGoodHosts
    )
    let (l3, l3Reasons) = DOMScorer.score(context, targetGame: targetGame)
    let cand = Candidate(
      url: url, context: context, observedAt: Date(),
      urlScore: l1, manifestScore: nil,
      domScoreValue: l3, domReasons: l3Reasons,
      probeResult: nil
    )

    if l1.rejected {
      // Still track for diagnostics, but don't probe and don't admit
      // to the eligible set.
      all.append(cand)
      return nil
    }

    all.append(cand)

    // Start accumulation window on first non-rejected URL.
    if deadline == nil {
      let now = Date()
      deadline = now.addingTimeInterval(accumulationWindow)
      scheduleWindowExpiry(absolute: deadline!)
      scheduleHardDeadline(absolute: now.addingTimeInterval(hardDeadline))
    }

    // Kick off L2 + L5 in parallel for this candidate. Each updates
    // its own slot in `all`.
    let idx = all.count - 1
    let urlCopy = url
    Task { [probeHeaders] in
      async let manifest = M3U8Scorer.score(urlCopy, headers: probeHeaders)
      async let probe = SegmentProbe.probe(urlCopy, headers: probeHeaders)
      let (m, p) = await (manifest, probe)
      await self.updateCandidate(at: idx, manifest: m, probe: p)
    }

    if firstObserved == nil { firstObserved = cand }
    return cand
  }

  private func updateCandidate(at index: Int,
                               manifest: ManifestScore?,
                               probe: ProbeResult) {
    guard !didFinish, index < all.count else { return }
    all[index].manifestScore = manifest
    all[index].probeResult = probe
    // Early-commit: if a high-confidence candidate has come in well
    // before the window expires, commit immediately. "High
    // confidence" = probe passed AND total ≥ 40 (≈ LIVE + good
    // manifest + decent URL).
    let cand = all[index]
    if cand.probePassed, cand.total >= 40 {
      finish(committing: bestEligible() ?? cand)
    }
  }

  private func scheduleWindowExpiry(absolute: Date) {
    let delay = max(0, absolute.timeIntervalSinceNow)
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      await MainActor.run { self?.windowExpired() }
    }
  }

  private func scheduleHardDeadline(absolute: Date) {
    let delay = max(0, absolute.timeIntervalSinceNow)
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      await MainActor.run { self?.hardDeadlineExpired() }
    }
  }

  /// Called when the soft (accumulation) window ends. Commits the
  /// best probe-passing candidate. If none have passed yet, waits
  /// for the hard deadline.
  private func windowExpired() {
    guard !didFinish else { return }
    if let pick = bestEligible() {
      finish(committing: pick)
    }
    // else: keep waiting until hardDeadlineExpired() fires.
  }

  /// Called when the hard deadline expires. At this point, commit
  /// the best candidate we have regardless of probe status — better
  /// to attempt playback than to leave the user spinning.
  private func hardDeadlineExpired() {
    guard !didFinish else { return }
    let pick = bestEligible()
            ?? bestManifestOK()
            ?? firstObserved
    finish(committing: pick)
  }

  /// Highest-total candidate whose segment probe passed.
  private func bestEligible() -> Candidate? {
    all.filter { !$0.urlScore.rejected && $0.probePassed }
       .sorted { lhs, rhs in
         if lhs.total != rhs.total { return lhs.total > rhs.total }
         if lhs.context.hasLiveBadge != rhs.context.hasLiveBadge {
           return lhs.context.hasLiveBadge
         }
         return lhs.observedAt < rhs.observedAt
       }
       .first
  }

  /// Fallback: best non-rejected manifest-OK candidate (probe may
  /// have failed or not completed).
  private func bestManifestOK() -> Candidate? {
    all.filter { !$0.urlScore.rejected && $0.probeResult?.manifestOK == true }
       .sorted { $0.total > $1.total }
       .first
  }

  private func finish(committing cand: Candidate?) {
    guard !didFinish else { return }
    didFinish = true
    commitedURL = cand?.url
    onCommit(cand)
  }
}
