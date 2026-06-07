import SwiftUI
import WebKit
import AVKit

/// v2.38 verification mode: the WebView is visible from the start, the
/// walk + iframe drill-down still run automatically (driving navigation
/// toward the discovered destination), every detected stream URL is
/// surfaced in a bottom strip the user can tap to manually play, and
/// the navigation history is shown so the user can verify we landed on
/// the right page. AVPlayer auto-commit is OFF — once we confirm
/// navigation works on real sites, v2.39 brings auto-play back.
struct PlayerView: View {
  let game: Game
  @Environment(SourceRegistry.self) private var registry
  @State private var ruleList: WKContentRuleList? = nil
  @State private var avPlayer: AVPlayer? = nil
  @State private var rulesReady = false
  @State private var attempts: [SourceAttempt] = []
  @State private var currentAttemptIdx: Int = 0
  /// When on, shows the live scraping WebView + diagnostics. When off
  /// (default), the user sees only a loading screen until playback starts.
  @AppStorage("debugScrapingView") private var debugScraping = false
  /// v2.64: true while we're reading the source site to find the exact
  /// game-page URL before loading it. Shows the loading overlay so the
  /// WebView never briefly loads (and walks) the homepage first.
  @State private var resolving = false
  @State private var allFailed: Bool = false
  /// Per-source budget. v2.38: relaxed to 20 s because we no longer
  /// auto-advance — the user manually picks "Try next source" if they
  /// want to abandon. 20 s gives the walk + iframe drill-down time to
  /// reach the discovered destination on slow sites.
  private static let perSourceBudget: TimeInterval = 20
  /// v2.38: WebView is visible by default in verification mode. Was
  /// previously gated on "Browse Manually" from the retry UI.
  @State private var showWebFallback = true

  struct SourceAttempt: Identifiable {
    let id = UUID()
    let sourceID: String
    var pageURL: URL
    var status: Status = .pending
    enum Status { case pending, trying, failed }
  }

  /// v2.38: a stream URL the JS-shim detected. User taps "Play" in the
  /// bottom strip to commit one to AVPlayer.
  struct StreamCandidate: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let cookies: [HTTPCookie]
    let referer: URL
    static func == (lhs: StreamCandidate, rhs: StreamCandidate) -> Bool {
      lhs.url == rhs.url
    }
  }
  /// v2.38: stream URLs the shim caught on the current attempt. Reset
  /// whenever currentAttemptIdx changes.
  @State private var capturedStreams: [StreamCandidate] = []
  /// v2.38: every URL the WebView has navigated to during this attempt,
  /// in order. Surfaced as a "via X → Y → Z" breadcrumb. Coordinator
  /// appends here on each `webView(_:didCommit:)`.
  @State private var navigationHistory: [URL] = []
  /// v2.39: most-recent walk activity event from the JS-shim. Shown
  /// in navStrip so the user can see whether the walk fired, what it
  /// clicked, or that it gave up.
  @State private var lastWalkEvent: StreamWebView.WalkEvent? = nil
  /// v2.39: load-failure surfaced when WebView's provisional navigation
  /// fails AND host-fallback couldn't recover.
  @State private var loadFailure: String? = nil
  /// v2.40: latest game-shaped cards the shim spotted on the page.
  /// Lets the user see whether their target IS on this source. Tap
  /// to dispatch a click via evaluateJavaScript.
  @State private var detectedCards: [StreamWebView.DetectedCard] = []
  /// v2.40: set when the shim recognized an auth/login wall on the
  /// current page.
  @State private var authWallReason: String? = nil
  /// v2.40: small bridge that holds a weak ref to the WKWebView so the
  /// detected-cards UI can dispatch a `click()` via evaluateJavaScript
  /// when the user taps an alternative game.
  @StateObject private var webBridge = StreamWebViewBridge()
  /// v2.46: per-tap session id in the traversal log. Updated when the
  /// user advances to a different attempt. Used by all callbacks to
  /// route their events into the right TraversalSession.
  @State private var traversalSessionID: UUID? = nil
  /// v2.61: pairs we've already auto-followed (via the gesture-carrying
  /// clickFirstMatching path) on the current page. Reset on navigation so
  /// each page gets one auto-follow attempt per matched pair.
  @State private var autoFollowedPairs: Set<String> = []
  /// v2.66: consecutive "found the card but clicking it goes nowhere"
  /// (CLICKED-BUT-NO-NAV) reports on the current page. When the walk keeps
  /// re-identifying the target but can never open it — a dead-end link, or a
  /// game with no stream on this source — we stop after a few strikes and
  /// move on instead of looping forever. Reset on any real navigation, stream
  /// capture, or page change.
  @State private var noNavStrikes = 0
  private static let maxNoNavStrikes = 4

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if rulesReady {
        if avPlayer == nil {
          if registry.enabledSources.isEmpty && game.streamURLs.isEmpty {
            noSourcesEnabledView
          } else if allFailed {
            retryUI
          } else if resolving {
            StreamLoadingOverlay(
              attemptIndex: currentAttemptIdx,
              totalAttempts: attempts.count,
              sourceName: currentAttemptIdx < attempts.count
                ? sourceName(for: attempts[currentAttemptIdx].sourceID) : ""
            )
          } else if !attempts.isEmpty, currentAttemptIdx < attempts.count {
            let current = attempts[currentAttemptIdx]
            if debugScraping {
              // Debug Mode: verification layout — top URL strip, visible
              // WebView in the middle, captured-streams strip at bottom.
              VStack(spacing: 0) {
                navStrip(sourceName: sourceName(for: current.sourceID))
                scrapeWebView(current)
                if !capturedStreams.isEmpty {
                  capturedStreamsStrip(referer: current.pageURL)
                }
              }
              .ignoresSafeArea(edges: .bottom)
            } else {
              // Normal mode: keep the WebView alive AND on-screen so scraping
              // runs, but cover it with an opaque loading screen. v2.67: we
              // render it at full opacity behind a solid black layer rather
              // than `.opacity(0)`. A zero-opacity WKWebView is treated by
              // WebKit as not visible, which throttles timers and blocks media
              // autoplay/visibility observers — so some sites (crackstreams.ms)
              // never started their player and never emitted the stream until
              // Debug Mode showed the WebView. Keeping it laid out and visible
              // (just occluded) lets the player initialize as it does in Debug.
              ZStack {
                scrapeWebView(current)
                  .allowsHitTesting(false)
                Color.black.ignoresSafeArea()
                StreamLoadingOverlay(
                  attemptIndex: currentAttemptIdx,
                  totalAttempts: attempts.count,
                  sourceName: sourceName(for: current.sourceID)
                )
              }
            }
          } else {
            StreamLoadingOverlay(attemptIndex: 0, totalAttempts: 0, sourceName: "")
          }
        }
        if let avPlayer {
          VideoPlayerView(player: avPlayer).ignoresSafeArea()
        }
      } else {
        StreamLoadingOverlay(attemptIndex: 0, totalAttempts: 0, sourceName: "")
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 2) {
          Text(game.title)
            .font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .foregroundStyle(.white)
          Text(game.league.displayName)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 240)
      }
    }
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
    .task {
      ruleList = await AdBlockRules.compile()
      rulesReady = true
      buildAttempts()
      // v2.38: no auto-advance. We just record an attempt for the
      // current source and let the WebView load. The user decides
      // when to advance via the "Try next" button in navStrip.
      if !attempts.isEmpty {
        attempts[currentAttemptIdx].status = .trying
        SourceHealth.shared.recordAttempt(
          sourceID: attempts[currentAttemptIdx].sourceID
        )
        await startCurrentAttempt()
      }
    }
    .onDisappear {
      if let sid = traversalSessionID {
        TraversalLog.shared.endSession(sid)
        traversalSessionID = nil
      }
    }
  }

  /// v2.46: open a TraversalSession for the current attempt. Sessions
  /// hold the full event timeline for the tap — used by
  /// Settings → Traversal Log to evaluate how reliably we navigate.
  private func startTraversalSession() {
    guard currentAttemptIdx < attempts.count else { return }
    let current = attempts[currentAttemptIdx]
    let sourceName = self.sourceName(for: current.sourceID)
    let sid = TraversalLog.shared.startSession(
      sourceID: current.sourceID,
      sourceName: sourceName,
      sourceURL: current.pageURL,
      gameHome: game.homeTeam,
      gameAway: game.awayTeam,
      gameLeague: game.league.rawValue
    )
    traversalSessionID = sid
  }

  /// Builds the sequential attempt list. Pre-matched per-source URLs
  /// first (from `Game.streamURLs`, populated at listing time), then each
  /// remaining enabled source's homepage as a fallback. Health/failure/
  /// preference filters and ordering applied to keep snappy.
  private func buildAttempts() {
    let gameKey = GameKey.make(for: game)
    let failureStore = FailureStore.shared
    let health = SourceHealth.shared
    let preference = SourcePreference.shared

    // v2.33 fix: respect the user's source toggles at tap time. The
    // game's `streamURLs` may carry URLs from sources that were
    // enabled at listing-scrape time but have since been toggled off.
    // Filter both the pre-matched list and the `preResolvedIDs` set
    // by the CURRENT enabled set so disabled sources are never tried.
    let enabledIDs = Set(registry.enabledSources.map(\.id))

    var built: [SourceAttempt] = []
    for c in game.streamURLs {
      if !enabledIDs.contains(c.sourceID) { continue }
      if failureStore.isFailedRecently(gameKey: gameKey, sourceID: c.sourceID) { continue }
      built.append(SourceAttempt(sourceID: c.sourceID, pageURL: c.pageURL))
    }
    let preResolvedIDs = Set(built.map(\.sourceID))
    let fallbackSources = registry.enabledSources
      .filter { !preResolvedIDs.contains($0.id) }
      .filter { !failureStore.isFailedRecently(gameKey: gameKey, sourceID: $0.id) }
    let fallbackIDs = fallbackSources.map(\.id)
    let demotedIDs = Set(fallbackIDs.filter { health.isDemoted($0) })
    let healthyIDs = fallbackIDs.filter { !demotedIDs.contains($0) }
    var orderedHealthy = health.orderedByHealth(healthyIDs)
    if let preferred = preference.lastSuccessfulSource(for: game.league),
       let idx = orderedHealthy.firstIndex(of: preferred), idx > 0 {
      orderedHealthy.remove(at: idx)
      orderedHealthy.insert(preferred, at: 0)
    }
    let orderedDemoted = health.orderedByHealth(Array(demotedIDs))
    for sourceID in orderedHealthy + orderedDemoted {
      guard let source = fallbackSources.first(where: { $0.id == sourceID }) else { continue }
      built.append(SourceAttempt(sourceID: source.id, pageURL: source.baseURL))
    }
    // v2.34: when this list ends up empty, the body branch on
    // `registry.enabledSources.isEmpty` shows the dedicated empty
    // state. No more synthetic ESPN-page fallback that loads forever.
    attempts = built
    currentAttemptIdx = 0
    allFailed = false
  }

  // MARK: v2.38 verification UI

  /// The scraping WebView for an attempt, wired to all of PlayerView's
  /// callbacks. Shown directly in Debug Mode; rendered hidden (still
  /// scraping) in normal mode behind the loading overlay.
  @ViewBuilder
  private func scrapeWebView(_ current: SourceAttempt) -> some View {
    StreamWebView(
      url: current.pageURL,
      ruleList: ruleList,
      onStreamURLFound: { streamURL, cookies in
        Task { @MainActor in
          appendCandidate(
            url: streamURL,
            cookies: cookies,
            referer: current.pageURL
          )
          if let sid = traversalSessionID {
            TraversalLog.shared.recordStream(sid, url: streamURL)
          }
          // v2.47: auto-play return, gated on meaningful Hop ≥ 2.
          // We only auto-commit when navigation actually advanced past
          // the source's homepage — protects against committing a stream
          // URL that surfaced from an ad iframe before the user-targeted
          // nav happened. Stays off for the initial Hop 1 captures; in
          // Debug Mode the user can still tap the strip pill manually,
          // and normal mode auto-commits via the playable probe below.
          if avPlayer == nil {
            let hops = URLNormalization.meaningfulHopCount(
              navigationHistory.map { $0.absoluteString }
            )
            if hops >= 2 {
              autoPlayCapturedStream(
                url: streamURL,
                cookies: cookies,
                referer: current.pageURL
              )
            }
          }
        }
      },
      onStreamProbed: { url, playable, cookies, referer in
        Task { @MainActor in
          if let sid = traversalSessionID {
            TraversalLog.shared.recordEvent(
              sid, kind: "stream_probed",
              info: "\(playable ? "ok" : "fail"): \(url.absoluteString)"
            )
          }
          // Normal mode has no visible strip to tap, so auto-commit the
          // first stream that probes playable. v2.67: play it directly from
          // the probe's own cookies/referer instead of looking it up in
          // `capturedStreams` — that list is populated later (via commitURL →
          // onStreamURLFound), so the lookup was always empty here and normal
          // mode could get stuck on the loading screen for flat sites
          // (crackstreams.ms) whose real stream surfaces before Hop 2. The
          // probe already filters out non-video ad captures.
          if !debugScraping, playable, avPlayer == nil {
            appendCandidate(url: url, cookies: cookies, referer: referer ?? current.pageURL)
            autoPlayCapturedStream(
              url: url, cookies: cookies, referer: referer ?? current.pageURL
            )
          }
        }
      },
      onNavigation: { navURL in
        Task { @MainActor in
          appendNavigation(navURL)
          if let sid = traversalSessionID {
            TraversalLog.shared.recordNavigation(sid, url: navURL)
          }
        }
      },
      onWalkEvent: { event in
        Task { @MainActor in
          handleWalkEvent(event)
          if let sid = traversalSessionID {
            TraversalLog.shared.recordEvent(
              sid, kind: event.kind, info: event.info
            )
          }
        }
      },
      onLoadFailed: { url, message in
        Task { @MainActor in
          loadFailure = message
          if let sid = traversalSessionID {
            TraversalLog.shared.recordEvent(
              sid, kind: "load_failure",
              info: "\(url.absoluteString): \(message)"
            )
          }
        }
      },
      onPageChanged: { _ in
        Task { @MainActor in
          resetPerPageState()
        }
      },
      bridge: webBridge,
      targetGame: game
    )
    .id(current.id)
  }

  /// Top strip: source name, current page URL, "via" breadcrumb of the
  /// path our walk/drill-down navigated through, and a "Try next source"
  /// button when more attempts exist.
  private func navStrip(sourceName: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.55))
        Text(sourceName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.85))
        // v2.45 + v2.47: meaningful hop counter — TLD/trailing-slash
        // redirects collapse into a single hop so the chip matches
        // user perception of "different page."
        let hopCount = URLNormalization.meaningfulHopCount(
          navigationHistory.map { $0.absoluteString }
        )
        if hopCount >= 1 {
          Text("Hop \(hopCount)")
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .foregroundStyle(.cyan.opacity(0.95))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.cyan.opacity(0.18), in: Capsule())
        }
        Spacer()
        if currentAttemptIdx + 1 < attempts.count {
          Button {
            advanceAttempt()
          } label: {
            HStack(spacing: 4) {
              Text("Try next").font(.caption2)
              Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white.opacity(0.85))
          }
        }
      }
      if let last = navigationHistory.last {
        Text(displayURL(last))
          .font(.caption2.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.white)
      }
      if navigationHistory.count > 1 {
        Text(breadcrumbText)
          .font(.system(size: 9))
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.white.opacity(0.5))
      }
      // v2.39: walk activity + load failure surfaced inline.
      if let event = lastWalkEvent {
        HStack(spacing: 4) {
          Image(systemName: walkIcon(for: event.kind))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(walkColor(for: event.kind))
          Text(walkLabel(for: event))
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.white.opacity(0.85))
        }
      }
      if let failure = loadFailure {
        HStack(spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.red)
          Text("Load failed: \(failure)")
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.red.opacity(0.9))
        }
      }
      // v2.40: auth-wall warning (streameast SSO, etc.)
      if let auth = authWallReason {
        HStack(spacing: 4) {
          Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.orange)
          Text("This source requires login (\(auth))")
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.orange.opacity(0.9))
        }
      }
      // v2.40: detected cards — what's actually on the page. Tappable
      // so user can navigate to an alternative if our target matcher
      // missed (or if their game just isn't on this source).
      if !detectedCards.isEmpty {
        Text("Found on this page (\(detectedCards.count))")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.white.opacity(0.6))
          .padding(.top, 2)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(detectedCards) { card in
              Button {
                webBridge.clickFirstMatching(card.text)
              } label: {
                Text(card.text)
                  .font(.system(size: 11, weight: .medium))
                  .lineLimit(1)
                  .padding(.horizontal, 8).padding(.vertical, 4)
                  .background(Color.white.opacity(0.12), in: Capsule())
                  .foregroundStyle(.white)
              }
            }
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.85))
  }

  private func walkIcon(for kind: String) -> String {
    switch kind {
    case "clicked": return "hand.tap.fill"
    case "category_click": return "folder.fill"
    case "auto_nav": return "arrow.uturn.right.circle.fill"
    case "backtrack": return "arrow.uturn.backward.circle.fill"
    case "league_block": return "sportscourt"
    case "popup_blocked": return "hand.raised.fill"
    case "click_failed": return "xmark.octagon.fill"
    case "dead_end": return "nosign"
    case "scan", "no_match", "cat_scan": return "magnifyingglass"
    default: return "circle"
    }
  }
  private func walkColor(for kind: String) -> Color {
    switch kind {
    case "clicked", "category_click", "auto_nav": return .green
    case "backtrack": return .cyan
    case "league_block": return .orange
    case "popup_blocked": return .orange
    case "click_failed", "dead_end": return .red
    case "scan", "no_match", "cat_scan": return .yellow
    default: return .white.opacity(0.6)
    }
  }
  private func walkLabel(for event: StreamWebView.WalkEvent) -> String {
    switch event.kind {
    case "clicked": return "Walk clicked: \(event.info.replacingOccurrences(of: "card: ", with: ""))"
    case "category_click": return "Walk → category: \(event.info)"
    case "auto_nav": return "Auto-tap: \(event.info)"
    case "backtrack": return "Backtracked — dead end, returning to game page"
    case "league_block": return "Blocked wrong-league jump: \(event.info)"
    case "popup_blocked": return "Blocked pop-up: \(event.info)"
    case "click_failed": return "Walk click error: \(event.info)"
    case "scan": return "Walk: \(event.info)"
    case "cat_scan": return "CategoryLink: \(event.info)"
    case "dead_end": return "Couldn't open on this source — moving on"
    case "no_match": return "Walk: no matching card yet (\(event.info))"
    default: return "Walk: \(event.kind) — \(event.info)"
    }
  }

  /// Bottom strip: every stream URL the shim has caught on this
  /// attempt, with a Play button each.
  private func capturedStreamsStrip(referer: URL) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "waveform")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.green.opacity(0.9))
        Text("Detected streams (\(capturedStreams.count))")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.85))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(capturedStreams) { cand in
            Button {
              playCandidate(cand)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                Text(displayURL(cand.url))
                  .font(.system(size: 11, weight: .medium).monospaced())
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(Color.green.opacity(0.18), in: Capsule())
              .foregroundStyle(.white)
            }
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.92))
  }

  /// Compact URL for display: host + last path segment.
  private func displayURL(_ url: URL) -> String {
    let host = url.host ?? ""
    let lastPath = url.pathComponents.last(where: { $0 != "/" }) ?? ""
    if lastPath.isEmpty { return host }
    return "\(host)/…/\(lastPath)"
  }

  private var breadcrumbText: String {
    let hops = navigationHistory.dropLast().suffix(4)
    if hops.isEmpty { return "" }
    let parts = hops.map { $0.host ?? "?" }
    return "via " + parts.joined(separator: " → ")
  }

  private func appendCandidate(url: URL, cookies: [HTTPCookie], referer: URL) {
    if capturedStreams.contains(where: { $0.url == url }) { return }
    noNavStrikes = 0  // we're capturing streams — making progress
    capturedStreams.append(StreamCandidate(url: url, cookies: cookies, referer: referer))
  }

  /// v2.40: dispatch incoming walk events. detected_cards updates the
  /// alternative-cards list; auth_wall sets the inline warning. Everything
  /// else falls through to the latest-walk-event display.
  private func handleWalkEvent(_ event: StreamWebView.WalkEvent) {
    switch event.kind {
    case "detected_cards":
      detectedCards = event.detectedCards
    case "auth_wall":
      authWallReason = event.info
      lastWalkEvent = event
    case "target":
      lastWalkEvent = event
      autoFollowTarget(event.info)
      trackTargetProgress(event.info)
    case "cat_scan":
      lastWalkEvent = event
      autoFollowCategory(event.info)
    default:
      lastWalkEvent = event
    }
  }

  /// v2.61: the in-page walk reliably *identifies* the target card but its
  /// synthetic click frequently fails to navigate (CLICKED-BUT-NO-NAV) —
  /// the site's onclick needs WebKit user activation, which timer-driven
  /// page script doesn't carry. Tapping the chip worked because it routes
  /// through `evaluateJavaScript`, which DOES carry activation. So when the
  /// shim posts a `target` event naming the matched pair, we fire that exact
  /// same path automatically — reproducing the manual chip tap. Debounced to
  /// once per pair per page (reset on navigation) so we never click-loop.
  private func autoFollowTarget(_ info: String) {
    guard let open = info.range(of: "pair=\"") else { return }
    let rest = info[open.upperBound...]
    guard let close = rest.range(of: "\"") else { return }
    let pair = String(rest[..<close.lowerBound])
    guard !pair.isEmpty, !autoFollowedPairs.contains(pair) else { return }
    autoFollowedPairs.insert(pair)
    webBridge.clickFirstMatching(pair)
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(sid, kind: "auto_follow", info: pair)
    }
  }

  /// v2.62: same gesture-carrying auto-tap as autoFollowTarget, but for the
  /// league category card (e.g. "MLB Streams") the shim picked when the
  /// exact game isn't listed on the landing page. The in-page click on that
  /// card hits the same CLICKED-BUT-NO-NAV wall, so we re-fire it through
  /// `clickFirstMatching` (carries WebKit user activation). The label comes
  /// from the cat_scan event's `clk="..."`. Debounced via autoFollowedPairs.
  private func autoFollowCategory(_ info: String) {
    guard let open = info.range(of: "clk=\"") else { return }
    let rest = info[open.upperBound...]
    guard let close = rest.range(of: "\"") else { return }
    let label = String(rest[..<close.lowerBound])
    guard !label.isEmpty, !autoFollowedPairs.contains(label) else { return }
    autoFollowedPairs.insert(label)
    webBridge.clickFirstMatching(label)
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(sid, kind: "auto_follow", info: label)
    }
  }

  /// v2.66: watch the shim's `target` verdicts to break the dead-end loop.
  /// `CLICKED-BUT-NO-NAV` means we found the right card but clicking it didn't
  /// move the page — a non-navigable card (e.g. a game with no stream on this
  /// source). After a few in a row with no progress, give up on this source.
  private func trackTargetProgress(_ info: String) {
    if info.hasPrefix("CLICKED-BUT-NO-NAV") {
      noNavStrikes += 1
      if noNavStrikes >= Self.maxNoNavStrikes { handleDeadEnd() }
    } else if info.hasPrefix("MATCH") || info.hasPrefix("ON-PAGE-NO-CARD") {
      // A fresh match attempt or an arrival — not a dead end.
      noNavStrikes = 0
    }
  }

  /// The current source can identify the game but can't open it. Mark it
  /// failed and move to the next source, or surface the retry UI when this
  /// was the last one.
  private func handleDeadEnd() {
    guard currentAttemptIdx < attempts.count else { return }
    noNavStrikes = 0
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(
        sid, kind: "dead_end",
        info: "card found but not openable on this source"
      )
    }
    attempts[currentAttemptIdx].status = .failed
    if currentAttemptIdx + 1 < attempts.count {
      advanceAttempt()
    } else {
      if let sid = traversalSessionID {
        TraversalLog.shared.endSession(sid)
        traversalSessionID = nil
      }
      allFailed = true
    }
  }

  /// v2.41: clear per-page diagnostic state when the WebView commits
  /// a navigation to a different host or path. Prevents two pages'
  /// data from overlapping on screen (the v2.40 streameast case where
  /// stale detected-cards from v2.streameast.ga hung over the new
  /// auth.streamea.st landing). A "Walk clicked" event in the last
  /// 1.5s is preserved — it's user-facing feedback we just gave them.
  private func resetPerPageState() {
    detectedCards = []
    authWallReason = nil
    autoFollowedPairs = []
    noNavStrikes = 0
    if let event = lastWalkEvent {
      let isFreshClick = (event.kind == "clicked" || event.kind == "category_click")
                       && Date().timeIntervalSince(event.at) < 1.5
      if !isFreshClick { lastWalkEvent = nil }
    }
  }

  private func appendNavigation(_ url: URL) {
    if navigationHistory.last == url { return }
    noNavStrikes = 0  // the page actually moved — not a dead end
    navigationHistory.append(url)
    if navigationHistory.count > 8 {
      navigationHistory.removeFirst(navigationHistory.count - 8)
    }
  }

  private func playCandidate(_ cand: StreamCandidate) {
    let p = makePlayer(url: cand.url, cookies: cand.cookies, referer: cand.referer)
    avPlayer = p
    p.play()
    // Record success for the source that yielded this candidate. We
    // don't know which attempt index it was from precisely, but for
    // health-stats purposes the current attempt is a reasonable proxy.
    if currentAttemptIdx < attempts.count {
      recordSuccess(attempt: attempts[currentAttemptIdx])
    }
    // v2.46: log that the user explicitly chose to play this captured
    // URL — gives us a hint that AVPlayer was at least attempted.
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(
        sid, kind: "user_play",
        info: cand.url.absoluteString
      )
    }
  }

  /// v2.47: auto-commit a captured stream when meaningful navigation
  /// has happened past the source's homepage. Mirrors playCandidate
  /// but logs a different event kind so we can distinguish auto-play
  /// from user-tap-play in the timeline.
  private func autoPlayCapturedStream(url: URL, cookies: [HTTPCookie], referer: URL) {
    let p = makePlayer(url: url, cookies: cookies, referer: referer)
    avPlayer = p
    p.play()
    if currentAttemptIdx < attempts.count {
      recordSuccess(attempt: attempts[currentAttemptIdx])
    }
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(
        sid, kind: "auto_play",
        info: url.absoluteString
      )
    }
  }

  /// v2.64: read the source site and find this game's exact page URL, then
  /// point the current attempt at it so the WebView loads it directly —
  /// instead of loading the homepage and relying on the synthetic-click
  /// walk. No-op when the attempt already targets a deep link (a
  /// listing-time match) or when reading the site finds no confident URL
  /// (the walk then handles it as before).
  @MainActor
  private func resolveCurrentAttemptIfNeeded() async {
    guard currentAttemptIdx < attempts.count else { return }
    let url = attempts[currentAttemptIdx].pageURL
    let path = url.path
    guard path.isEmpty || path == "/" else { return }
    resolving = true
    defer { resolving = false }
    // v2.66: if this source has never been initialized, learn its URL
    // template now (bounded) so we can jump straight to the game instead of
    // walking the homepage. Once learned it's cached, so this only blocks the
    // very first tap on a new source. Failure leaves no template → the walk.
    if let host = url.host, SourceTemplateStore.shared.template(forHost: host) == nil,
       SourceTemplateStore.shared.status(forHost: host) == nil {
      let result = await SourceProbe.probeWithStatus(root: url)
      SourceTemplateStore.shared.setStatus(result.status, forHost: host)
      if let template = result.template {
        SourceTemplateStore.shared.set(template, forHost: host)
      }
    }
    guard let resolved = await GameURLResolver.resolve(game: game, sourceRoot: url),
          resolved.absoluteString != url.absoluteString else { return }
    guard currentAttemptIdx < attempts.count else { return }
    attempts[currentAttemptIdx].pageURL = resolved
  }

  /// Resolve the current attempt's direct URL, then open its traversal
  /// session. Used on first load and on every advance so the session's
  /// recorded URL reflects what we actually load.
  @MainActor
  private func startCurrentAttempt() async {
    await resolveCurrentAttemptIfNeeded()
    startTraversalSession()
    if let sid = traversalSessionID, currentAttemptIdx < attempts.count {
      TraversalLog.shared.recordEvent(
        sid, kind: "resolved", info: attempts[currentAttemptIdx].pageURL.absoluteString
      )
    }
  }

  /// User-driven advance to next attempt. Resets per-attempt state.
  private func advanceAttempt() {
    guard currentAttemptIdx + 1 < attempts.count else { return }
    SourceHealth.shared.recordAttempt(sourceID: attempts[currentAttemptIdx].sourceID)
    // v2.46: close out the prior attempt's traversal session before
    // starting a new one for the next source.
    if let sid = traversalSessionID {
      TraversalLog.shared.endSession(sid)
      traversalSessionID = nil
    }
    capturedStreams = []
    navigationHistory = []
    lastWalkEvent = nil
    loadFailure = nil
    detectedCards = []
    authWallReason = nil
    noNavStrikes = 0
    currentAttemptIdx += 1
    Task { await startCurrentAttempt() }
  }

  // v2.34: shown when the user has no sources toggled on AND the game
  // has no pre-matched URLs. Directs them to Settings instead of
  // staring at a loading spinner that will never resolve.
  @Environment(\.dismiss) private var dismissPlayer
  private var noSourcesEnabledView: some View {
    VStack(spacing: 18) {
      Image(systemName: "antenna.radiowaves.left.and.right.slash")
        .font(.system(size: 44))
        .foregroundStyle(.white.opacity(0.7))
      Text("No sources enabled")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
      Text("Enable a source in Settings to find streams for this game. You can add custom streaming sites under Settings → Source Site.")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.65))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 36)
      Button {
        dismissPlayer()
      } label: {
        Label("Back to Streams", systemImage: "chevron.backward")
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(Color.white.opacity(0.15), in: Capsule())
          .foregroundStyle(.white)
      }
    }
    .padding(.horizontal, 24)
  }

  private func recordSuccess(attempt: SourceAttempt) {
    let gameKey = GameKey.make(for: game)
    let sid = attempt.sourceID
    SourceHealth.shared.recordSuccess(sourceID: sid)
    SourcePreference.shared.recordSuccess(league: game.league, sourceID: sid)
    FailureStore.shared.clearForGame(gameKey: gameKey)
  }

  private func recordAllFailures() {
    let gameKey = GameKey.make(for: game)
    for a in attempts {
      FailureStore.shared.markFailed(gameKey: gameKey, sourceID: a.sourceID)
    }
  }

  private func sourceName(for sourceID: String) -> String {
    if sourceID == "espn" { return "ESPN page" }
    return registry.sources.first(where: { $0.id == sourceID })?.name ?? "Source"
  }

  private var retryUI: some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 44))
        .foregroundStyle(.white.opacity(0.7))
      Text("No stream found")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
      Text(attempts.isEmpty
           ? "No sources are enabled for this game."
           : "Tried \(attempts.count) source\(attempts.count == 1 ? "" : "s") without finding a playable stream.")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.6))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(attempts) { att in
          HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.red.opacity(0.7))
            Text(sourceName(for: att.sourceID))
              .font(.subheadline)
              .foregroundStyle(.white.opacity(0.85))
          }
        }
      }
      .padding(.vertical, 8)
      HStack(spacing: 14) {
        Button {
          // v2.38: just rebuild attempts and let verification mode
          // re-load the first attempt's page from scratch.
          buildAttempts()
          capturedStreams = []
          navigationHistory = []
          lastWalkEvent = nil
          loadFailure = nil
          detectedCards = []
          authWallReason = nil
          noNavStrikes = 0
          allFailed = false
          if !attempts.isEmpty {
            SourceHealth.shared.recordAttempt(
              sourceID: attempts[currentAttemptIdx].sourceID
            )
            Task { await startCurrentAttempt() }
          }
        } label: {
          Label("Try Again", systemImage: "arrow.clockwise")
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(.white)
        }
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 24)
  }

  private func makePlayer(url: URL, cookies: [HTTPCookie], referer: URL) -> AVPlayer {
    var headers = HTTPCookie.requestHeaderFields(with: cookies)
    headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    headers["Referer"] = referer.absoluteString
    headers["Origin"]  = (referer.scheme ?? "https") + "://" + (referer.host ?? "")
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    return AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }
}

// MARK: - Loading overlay (single mode, replaces v2.29's StreamSearchingOverlay)

private struct StreamLoadingOverlay: View {
  let attemptIndex: Int
  let totalAttempts: Int
  let sourceName: String
  @State private var pulse = false

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        Circle()
          .fill(Color.white.opacity(0.06))
          .frame(width: 80, height: 80)
          .scaleEffect(pulse ? 1.25 : 1.0)
          .opacity(pulse ? 0 : 0.6)
          .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(.white.opacity(0.85))
      }
      Text("Loading…")
        .font(.headline)
        .foregroundStyle(.white)
      if totalAttempts > 0 {
        Text(totalAttempts > 1
             ? "\(sourceName) (\(attemptIndex + 1) of \(totalAttempts))"
             : sourceName)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.6))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
      }
    }
    .onAppear { pulse = true }
  }
}

// MARK: - AVKit wrapper

struct VideoPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let vc = AVPlayerViewController()
    vc.player = player
    vc.showsPlaybackControls = true
    vc.videoGravity = .resizeAspect
    vc.entersFullScreenWhenPlaybackBegins = true
    vc.exitsFullScreenWhenPlaybackEnds = true
    return vc
  }
  func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
    vc.player = player
  }
}

// MARK: - WebKit stream view with m3u8 interception

/// v2.40: thin bridge so PlayerView can drive the underlying WKWebView
/// (e.g. dispatch a click via evaluateJavaScript when the user taps a
/// detected card). Holds the WKWebView weakly so the proxy doesn't
/// extend its lifetime.
final class StreamWebViewBridge: ObservableObject {
  weak var webView: WKWebView?

  /// Find a clickable element on the page whose readable text contains
  /// `pair` and navigate to it. Used both when the user taps an alternative
  /// game in the "Detected on this page" strip and (auto-follow) when the
  /// shim names a matched card/category. This call runs via
  /// evaluateJavaScript, so it carries WebKit user activation that the
  /// in-page timer walk lacks.
  ///
  /// v2.63: this path used to ONLY synthesize a click and hope the site's
  /// handler navigated. On sites whose card click is a same-page JS action
  /// with no reachable <a href> (ntv.cx), that produced CLICKED-BUT-NO-NAV
  /// forever. Now it mirrors the in-page `clickOrNavigate`: first dig out a
  /// real destination URL (the element, a descendant <a>, a data-url/href
  /// attribute, or a sibling <a> in the card container) and drive
  /// `location.href` straight to it — a guaranteed navigation regardless of
  /// framework or popup-blocking — and only fall back to a synthetic click
  /// when no usable href exists anywhere near the match. Posts an
  /// `auto_nav` diagnostic naming what it found so failures are visible in
  /// the traversal log instead of silent.
  func clickFirstMatching(_ pair: String) {
    guard let webView else { return }
    let escaped = pair
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
    let js = """
    (function(){
      function report(info){
        try { window.webkit.messageHandlers.streamWalk.postMessage(JSON.stringify({
          kind: 'auto_nav', info: ('' + info).slice(0,160), time: Date.now()
        })); } catch(e){}
      }
      var t = '\(escaped)'.toLowerCase();
      // v2.73: per-side EXCLUSIVE tokens from the pair. The walk used to
      // follow the first usable same-site href near the matched card, which
      // on ntv.cx grabbed a generic "/matches/kobra" server link beside the
      // game — so we detoured there instead of the one-hop "/watch/kobra/
      // <teams>-<id>" the card's own click produces. We now only auto-navigate
      // to a URL that NAMES THE GAME (a distinctive token from BOTH teams);
      // anything else falls through to running the card's own handler.
      var toks = [];
      t.replace(/\\bvs\\b|@|—|–/g, ' ').split(/\\s+/).forEach(function(w){
        if (w.length >= 4) toks.push(w);
      });
      var _sides = t.split(/\\bvs\\b|@|—|–/);
      function _words(s){ var w = []; ('' + (s || '')).split(/\\s+/).forEach(function(x){ if (x.length >= 4) w.push(x); }); return w; }
      function _excl(a, b){ return a.filter(function(w){ return b.indexOf(w) === -1; }); }
      var _s0 = _words(_sides[0]), _s1 = _words(_sides[1] || '');
      var _homeEx = _excl(_s0, _s1), _awayEx = _excl(_s1, _s0);
      function hrefNamesGame(h){
        if (!h || !_homeEx.length || !_awayEx.length) return false;
        var low = ('' + h).toLowerCase();
        var hh = _homeEx.some(function(w){ return low.indexOf(w) !== -1; });
        var aa = _awayEx.some(function(w){ return low.indexOf(w) !== -1; });
        return hh && aa;
      }
      // Cross-origin ad guard (kept for the skip-ad check below): an off-site
      // link is only worth touching if it carries a team token.
      function navHrefOK(href){
        if (!href) return false;
        var u; try { u = new URL(href, location.href); } catch(e){ return true; }
        if (u.host === location.host) return true;
        var low = u.href.toLowerCase();
        for (var i = 0; i < toks.length; i++){ if (low.indexOf(toks[i]) !== -1) return true; }
        return false;
      }
      function usableHref(h){
        if (!h) return false;
        h = ('' + h).trim();
        if (!h || h === '#' || h === '/') return false;
        var low = h.toLowerCase();
        if (low.indexOf('javascript:') === 0 || low.indexOf('mailto:') === 0 ||
            low.indexOf('tel:') === 0 || low.indexOf('#') === 0) return false;
        return true;
      }
      // A game-naming URL from this element's href, onclick text, or data-*.
      function gameHref(el){
        if (!el || !el.getAttribute) return '';
        var direct = el.getAttribute('href');
        if (usableHref(direct) && hrefNamesGame(direct)) return direct;
        var keys = ['data-href','data-url','data-link','data-src','data-watch','data-play','data-stream'];
        // data-* may be a plain URL → accept directly.
        for (var k = 0; k < keys.length; k++){
          var dv = el.getAttribute(keys[k]);
          if (dv && usableHref(dv) && hrefNamesGame(dv)) return dv;
        }
        // onclick is JS code — only regex-extract a quoted URL from it.
        var srcs = [];
        var oc = el.getAttribute('onclick'); if (oc) srcs.push(oc);
        for (var k2 = 0; k2 < keys.length; k2++){ var v = el.getAttribute(keys[k2]); if (v) srcs.push(v); }
        for (var s = 0; s < srcs.length; s++){
          var re = /['"]((?:https?:\\/\\/|\\/)[^'"]+)['"]/g, m;
          while ((m = re.exec(srcs[s])) !== null){ if (usableHref(m[1]) && hrefNamesGame(m[1])) return m[1]; }
        }
        return '';
      }
      // Self → climb ancestors, also searching each subtree, for a URL that
      // names the game. Never returns a generic nearby link.
      function findNavHref(el){
        if (!el) return '';
        var n = el, lvl = 0;
        while (n && lvl < 6){
          var hg = gameHref(n); if (hg) return hg;
          try {
            var as = n.querySelectorAll && n.querySelectorAll(
              'a[href],[data-href],[data-url],[data-link]');
            if (as) for (var i = 0; i < as.length; i++){ var h = gameHref(as[i]); if (h) return h; }
          } catch(e){}
          n = n.parentElement; lvl++;
        }
        return '';
      }
      function findClickableAncestor(el) {
        if (!el) return null;
        var n = el;
        for (var lvl = 0; lvl < 6 && n; lvl++) {
          if (n.tagName === 'A' || n.tagName === 'BUTTON') return n;
          if (n.hasAttribute && (
                n.hasAttribute('onclick') ||
                n.hasAttribute('data-match') ||
                n.hasAttribute('data-event') ||
                n.hasAttribute('data-game') ||
                n.hasAttribute('data-id') ||
                n.getAttribute('role') === 'button'
              )) return n;
          n = n.parentElement;
        }
        return el;
      }
      // v2.45: dispatch full pointer+mouse sequence — frameworks listening
      // via addEventListener catch these where .click() alone misses.
      function robustClick(el) {
        if (!el) return;
        try { el.click(); } catch(e) {}
        try {
          var rect = el.getBoundingClientRect();
          var x = rect.left + Math.max(1, rect.width / 2);
          var y = rect.top + Math.max(1, rect.height / 2);
          var seq = ['pointerdown','mousedown','pointerup','mouseup','click'];
          for (var i = 0; i < seq.length; i++) {
            var type = seq[i];
            try {
              var ev;
              if (type.indexOf('pointer') === 0 && typeof PointerEvent === 'function') {
                ev = new PointerEvent(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, pointerType:'mouse'});
              } else if (type.indexOf('pointer') !== 0) {
                ev = new MouseEvent(type, {bubbles:true, cancelable:true, view:window, clientX:x, clientY:y});
              }
              if (ev) el.dispatchEvent(ev);
            } catch(e){}
          }
        } catch(e){}
      }
      var sel = 'a[href],button,[onclick],[data-match],[data-event],[data-game],' +
                '[role="button"],[class*="card" i],[class*="match" i],[class*="game" i]';
      var els = document.querySelectorAll(sel);
      for (var i = 0; i < els.length && i < 2000; i++) {
        var e = els[i];
        var b = ((e.innerText || e.textContent || '') + ' ' +
                 (e.getAttribute && (e.getAttribute('aria-label') || '')) + ' ' +
                 (e.getAttribute && (e.getAttribute('title') || ''))).toLowerCase();
        if (b.indexOf(t) === -1) continue;
        // Prefer a real destination URL — always navigates.
        var href = findNavHref(e);
        if (href) {
          var abs = href;
          try { abs = new URL(href, location.href).href; } catch(err){}
          if (abs && abs.split('#')[0] !== location.href.split('#')[0]) {
            report('nav→ ' + abs);
            try { location.href = abs; return true; } catch(err){}
          }
        }
        // No reachable href — fall back to a synthetic click on the
        // nearest clickable ancestor (handles pure-JS onclick cards). But
        // if that ancestor is an <a> pointing off-site to an ad (its href
        // failed navHrefOK), clicking it would just open the ad — skip it.
        var target = findClickableAncestor(e);
        if (target && target.tagName === 'A') {
          var rawHref = target.getAttribute('href');
          if (rawHref && !navHrefOK(rawHref)) {
            report('skip-ad ' + ('' + rawHref).slice(0,60));
            return false;
          }
        }
        // v2.72: before a synthetic click (which JS-router cards ignore as
        // untrusted), try executing an inline onclick handler directly so a
        // runtime router call like goWatch('kobra', 2387854) actually fires.
        var ocText = '';
        var hn = target, hlvl = 0;
        while (hn && hlvl < 6) {
          var oc = hn.getAttribute && hn.getAttribute('onclick');
          if (oc) { ocText = oc; break; }
          hn = hn.parentElement; hlvl++;
        }
        report('click ' + (target && target.tagName ? target.tagName : '?') +
               ' no-href' + (ocText ? ' oc="' + ocText.slice(0, 90) + '"' : ''));
        if (ocText) {
          try { (new Function(ocText)).call(hn); return true; } catch(e){}
        }
        robustClick(target);
        return true;
      }
      report('no-match "' + t.slice(0,60) + '"');
      return false;
    })();
    """
    webView.evaluateJavaScript(js, completionHandler: nil)
  }
}

struct StreamWebView: UIViewRepresentable {
  let url: URL
  let ruleList: WKContentRuleList?
  var onStreamURLFound: ((URL, [HTTPCookie]) -> Void)? = nil
  /// v2.48: fires for every captured stream URL after AVPlayer's
  /// isPlayable probe finishes, regardless of outcome. PlayerView
  /// records this in the TraversalLog so probe failures are visible
  /// in Settings → Traversal Log during iterative testing.
  /// v2.67: carries the cookies + referer used for the probe so normal mode
  /// can auto-commit a playable stream directly, without waiting for the
  /// candidate to land in `capturedStreams`.
  var onStreamProbed: ((URL, Bool, [HTTPCookie], URL?) -> Void)? = nil
  /// v2.38: fired on every top-frame navigation commit (initial load,
  /// iframe-drill navigations, redirect chains). Used by PlayerView to
  /// build the breadcrumb the user sees in verification mode.
  var onNavigation: ((URL) -> Void)? = nil
  /// v2.39: walk activity from the JS-shim — clicked element text,
  /// "no match" notices, category-link picks. PlayerView surfaces the
  /// most recent in the navStrip so the user can see what the walk is
  /// actually doing.
  var onWalkEvent: ((WalkEvent) -> Void)? = nil
  /// v2.39: fired when the WebView's provisional navigation is cancelled
  /// (frame load interrupted, sinkhole MIME, etc.) and host-fallback
  /// couldn't find a working variant. PlayerView shows this inline.
  var onLoadFailed: ((URL, String) -> Void)? = nil
  /// v2.41: fired when the WebView commits a top-frame navigation
  /// where the host or path *changed* — distinct from onNavigation
  /// which fires on every commit including redirects to the same
  /// effective page. PlayerView uses this to reset per-page state
  /// (detected cards, auth-wall warnings, stale walk events).
  var onPageChanged: ((URL) -> Void)? = nil
  var browseMode: Bool = false
  /// v2.40: optional proxy that gets assigned the WKWebView in
  /// makeUIView so callers (PlayerView) can dispatch follow-up
  /// commands like clicking an alternative card the user tapped.
  var bridge: StreamWebViewBridge? = nil
  /// v2.31 retained: when set, the JS-shim scopes mirror-clicking to the
  /// card whose innerText matches both team slugs. The one v2.31 idea
  /// kept because it directly matches the user's mental model and is tiny.
  var targetGame: Game? = nil

  /// v2.39: parsed walk event from the JS-shim's streamWalk channel.
  struct WalkEvent: Equatable {
    let kind: String   // "clicked" | "category_click" | "no_match" | "click_failed"
                       // | "auth_wall" | "detected_cards" (payload version)
    let info: String
    let at: Date
    /// v2.40: parsed payload for detected_cards events (one entry per
    /// game-shaped card the shim spotted on the current page).
    let detectedCards: [DetectedCard]
    init(kind: String, info: String, at: Date,
         detectedCards: [DetectedCard] = []) {
      self.kind = kind
      self.info = info
      self.at = at
      self.detectedCards = detectedCards
    }
  }

  /// v2.40: a single card we detected on the page. `text` is the
  /// canonical "Home vs Away" pair; `blob` is the readable text we
  /// pulled from the element (truncated). PlayerView lets the user
  /// tap one to dispatch a click through evaluateJavaScript.
  struct DetectedCard: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let blob: String
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onStreamURLFound: onStreamURLFound,
      onStreamProbed: onStreamProbed,
      onNavigation: onNavigation,
      onWalkEvent: onWalkEvent,
      onLoadFailed: onLoadFailed,
      onPageChanged: onPageChanged,
      browseMode: browseMode
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    if let ruleList { config.userContentController.add(ruleList) }

    let proxy = WeakScriptProxy(delegate: context.coordinator)
    config.userContentController.add(proxy, name: "streamURL")
    // v2.37: cross-origin iframes get a separate channel so the
    // Coordinator can decide to drill into them (navigate top-level)
    // instead of treating their URL as a stream URL.
    let iframeProxy = WeakScriptProxy(delegate: context.coordinator)
    config.userContentController.add(iframeProxy, name: "streamIframe")
    // v2.39: walk-activity events for verification-mode visibility.
    let walkProxy = WeakScriptProxy(delegate: context.coordinator)
    config.userContentController.add(walkProxy, name: "streamWalk")

    // v2.57: the walk needs popups REDIRECTED, not suppressed. Many
    // stream-site game cards have no <a href> — their onclick calls
    // window.open(gameURL). Suppressing window.open turned that into a
    // no-op, so we clicked the right card and went nowhere
    // (CLICKED-BUT-NO-NAV). Redirecting window.open into a same-frame
    // navigation lets the walk follow those cards. (The risk is an ad popup
    // hijacking the frame, but a dropped navigation guarantees failure, so
    // redirect wins.)
    let popupJS = Self.popupRedirectJS
    config.userContentController.addUserScript(WKUserScript(
      source: popupJS, injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))
    config.userContentController.addUserScript(WKUserScript(
      source: Self.slugConfigJS(for: targetGame),
      injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))
    config.userContentController.addUserScript(WKUserScript(
      source: Self.autoPlayAndInterceptJS,
      injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))

    if let host = url.host,
       let creds = CredentialStore.credentials(for: host) {
      let js = Self.credentialInjectionJS(username: creds.username, password: creds.password)
      config.userContentController.addUserScript(
        WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
      )
    }

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.uiDelegate = context.coordinator
    webView.navigationDelegate = context.coordinator
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.backgroundColor = .black
    webView.isOpaque = false
    context.coordinator.webView = webView
    context.coordinator.sourceHost = url.host
    context.coordinator.targetTokens = Self.slugTokens(for: targetGame)
    context.coordinator.targetLeague = targetGame?.league
    // v2.40: expose the WebView to the bridge so PlayerView can
    // dispatch evaluateJavaScript commands (detected-card taps).
    bridge?.webView = webView

    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    let referer = url.scheme.map { "\($0)://\(url.host ?? "")" } ?? "https://example.com"
    request.setValue(referer, forHTTPHeaderField: "Referer")
    webView.load(request)
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  // MARK: JS Payloads

  // v2.63: window.open is used two ways on these sites: (1) legit game
  // cards whose onclick calls window.open(gameURL) — we WANT to follow
  // those — and (2) ad/scam popups (buffstreams' game page opens
  // therestgroup.com → awarnets.com "Hacker is tracking you"). The old
  // version redirected the main frame to BOTH, so ads hijacked playback.
  // Now we only redirect to a destination that stays on the same site OR
  // carries a team token (a real deep link); cross-site, token-less
  // popups are dropped, keeping us on the source page. alert/confirm/
  // prompt are neutralized so scam dialogs can't block the walk.
  static let popupRedirectJS = """
    window.alert = function(){};
    window.confirm = function(){return false;};
    window.prompt = function(){return '';};
    window.open = function(url){
      if (!url || typeof url !== 'string') return null;
      var abs;
      try { abs = new URL(url, window.location.href).href; } catch(e){ abs = url; }
      if (abs.indexOf('http') !== 0) return null;
      var ok = false;
      try {
        var u = new URL(abs);
        if (u.host === location.host) ok = true;
        else {
          var tg = window.__sc_target, toks = [], low = abs.toLowerCase();
          if (tg) [tg.home, tg.away].forEach(function(s){
            (s || '').toLowerCase().split('-').forEach(function(w){ if (w.length >= 4) toks.push(w); });
          });
          for (var i = 0; i < toks.length; i++){ if (low.indexOf(toks[i]) !== -1) { ok = true; break; } }
        }
      } catch(e){ ok = false; }
      if (ok) window.location.href = abs;
      return null;
    };
  """

  /// Sets `window.__sc_target` for the shim's walk routine.
  /// v2.35: carries `league` raw value too so findCategoryLink can pick
  /// the right league-named category link when the user-target game
  /// isn't on the homepage. nil game → __sc_target=null → shim falls
  /// back to generic clicking.
  static func teamSlug(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                           locale: .current)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789- ")
    let scalars = folded.unicodeScalars.filter { allowed.contains($0) }
    let stripped = String(String.UnicodeScalarView(scalars))
    let collapsed = stripped.replacingOccurrences(of: "[ ]+", with: "-",
                                                  options: .regularExpression)
    return collapsed
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
      .replacingOccurrences(of: "'", with: "\\'")
  }

  /// Team-name tokens (≥4 chars) used natively to recognize cross-site
  /// deep links to the tapped game (vs. cross-site ad redirects). v2.65:
  /// includes alias-derived long tokens (nicknames like "nationals") so
  /// abbreviation/nickname-routed deep links count as the target too.
  static func slugTokens(for game: Game?) -> [String] {
    guard let g = game else { return [] }
    var toks = Set<String>()
    for name in [teamSlug(g.homeTeam), teamSlug(g.awayTeam)] {
      for w in name.split(separator: "-") where w.count >= 4 { toks.insert(String(w).lowercased()) }
    }
    for team in [g.homeTeam, g.awayTeam] {
      for t in TeamAliasIndex.shared.tokens(forTeam: team).long { toks.insert(t) }
    }
    return Array(toks)
  }

  /// Renders a `[String]` as a JS array literal with single-quoted, escaped
  /// elements: `["a","b'c"]` → `['a','b\'c']`.
  private static func jsArray(_ items: [String]) -> String {
    let inner = items
      .map { "'" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "'", with: "\\'") + "'" }
      .joined(separator: ",")
    return "[\(inner)]"
  }

  /// v2.65: the shim's `__sc_target` now carries, per side, the canonical
  /// slug PLUS alias-derived match tokens. `homeTok`/`awayTok` are long
  /// (≥4) tokens matched as substrings (nicknames); `homeAbbr`/`awayAbbr`
  /// are 2–3 char abbreviations (e.g. "wsh"/"ari") that abbreviation-routed
  /// sites use in their URLs — these are matched only as bounded slug
  /// segments. This is what lets the walk recognize `…/wsh-ari` as the
  /// Nationals-vs-Diamondbacks game instead of falling back to a wrong-game
  /// category guess.
  static func slugConfigJS(for game: Game?) -> String {
    guard let g = game else { return "window.__sc_target = null;" }
    let h = teamSlug(g.homeTeam)
    let a = teamSlug(g.awayTeam)
    let l = g.league.rawValue.replacingOccurrences(of: "'", with: "\\'")
    let homeTokens = TeamAliasIndex.shared.tokens(forTeam: g.homeTeam)
    let awayTokens = TeamAliasIndex.shared.tokens(forTeam: g.awayTeam)
    return """
    window.__sc_target = {home: '\(h)', away: '\(a)', league: '\(l)', \
    homeTok: \(jsArray(homeTokens.long)), awayTok: \(jsArray(awayTokens.long)), \
    homeAbbr: \(jsArray(homeTokens.abbr)), awayAbbr: \(jsArray(awayTokens.abbr))};
    """
  }

  /// v2.32 shim: simple URL string posting (no structured payload),
  /// yt-dlp-style extraction patterns (og:video / JSON-LD VideoObject /
  /// JW Player flashvars), inline ad-host reject, mirror-click stagger
  /// scoped to target-game card when possible.
  static let autoPlayAndInterceptJS = """
    (function(){
      'use strict';
      var _r = {};

      function isStreamURL(u) {
        if (!u || typeof u !== 'string') return false;
        if (u.indexOf('blob:') === 0) return false;
        var l = u.toLowerCase().split('?')[0];
        if (l.indexOf('.m3u8') !== -1) return true;
        if (l.indexOf('.mpd')  !== -1) return true;
        var pathPatterns = ['/hls/', '/live/', '/stream/', '/chunklist', '/playlist',
                            '/manifest', '/index.m3u', '/master.m3u'];
        for (var i = 0; i < pathPatterns.length; i++) {
          if (l.indexOf(pathPatterns[i]) !== -1) return true;
        }
        return false;
      }

      function isAdHost(u) {
        try {
          var h = new URL(u, location.href).hostname.toLowerCase();
          var bad = ['doubleclick.net','googlesyndication.com','googleadservices.com',
                     'adservice.google.com','serving-sys.com','adnxs.com','criteo.com',
                     'scorecardresearch.com','pubmatic.com','openx.net'];
          for (var i = 0; i < bad.length; i++) {
            if (h === bad[i] || h.indexOf('.' + bad[i]) !== -1) return true;
          }
        } catch(e){}
        return false;
      }

      function report(url) {
        if (!url || typeof url !== 'string') return;
        var clean = url.trim();
        if (!clean || _r[clean] || !isStreamURL(clean) || isAdHost(clean)) return;
        _r[clean] = 1;
        try { window.webkit.messageHandlers.streamURL.postMessage(clean); } catch(e){}
      }

      // v2.37: cross-origin iframe drill-down.
      // WKWebView's JS injection is blocked in cross-origin subframes, so
      // m3u8s born inside embed-host iframes (FileMoon, Doodstream, etc.)
      // are invisible to this shim. Surface those iframe URLs to native
      // through a separate channel; Coordinator navigates the top frame
      // into them so the shim runs same-origin and catches the stream.
      var _seenIframes = {};
      // Known embed/player hosts — used ONLY as a priority hint for which
      // iframe to drill into when there are multiple. Not a parser list.
      var _knownEmbedHosts = [
        'filemoon', 'doodstream', 'dood.', 'vidcloud', 'embed.tube',
        'watchsb', 'streamtape', 'vidsrc', 'vidplay', 'mixdrop',
        'streamwish', 'streamhg', 'streamhide', 'voe.sx', 'upstream',
        'fileone', 'streamlare', 'embedsito'
      ];

      // v2.68: positively identify a video-player iframe instead of
      // drilling into whatever cross-origin frame happens to score "best".
      // Returns a priority score (lower = drill sooner) only when the iframe
      // shows at least one affirmative player signal; returns -1 to skip it.
      // The signals are structural and source-agnostic — landscape video
      // geometry, the standards-based media-permission attributes a player
      // advertises, a player/video/stream container, and (as a priority hint
      // only) a known embed host. Chat boxes, comment widgets, and sidebars
      // are portrait, carry no media perms, and live in non-player
      // containers, so they fail to qualify without being named anywhere.
      function _iframePlayerScore(el) {
        if (!el) return -1;
        var score = 500, hit = false;

        // Geometry: a portrait frame is a chat box / sidebar, never a video
        // player — disqualify outright. Landscape geometry only refines drill
        // priority; it does NOT qualify an iframe on its own (a 400x300 chat
        // box is "landscape and sizeable" too), so it never sets `hit`.
        var w = parseInt(el.getAttribute('width') || el.clientWidth || 0, 10) || 0;
        var h = parseInt(el.getAttribute('height') || el.clientHeight || 0, 10) || 0;
        if (w > 0 && h > 0 && h > w * 1.2) return -1;   // portrait → not a player

        // Media-permission attributes: the standards-based way an embed marks
        // itself a player (autoplay / fullscreen / encrypted-media).
        var allow = (el.getAttribute('allow') || '').toLowerCase();
        if (el.hasAttribute('allowfullscreen') || el.hasAttribute('webkitallowfullscreen') ||
            allow.indexOf('autoplay') !== -1 || allow.indexOf('fullscreen') !== -1 ||
            allow.indexOf('encrypted-media') !== -1) {
          hit = true; score = Math.min(score, 80);
        }

        // Player-ish container: the iframe lives inside an element whose
        // class/id names it a player / video / stream / embed surface.
        var anc = el.parentElement;
        for (var lvl = 0; lvl < 4 && anc; lvl++) {
          var sig = ((anc.className || '') + ' ' + (anc.id || '')).toLowerCase();
          if (/player|video|stream|embed/.test(sig)) { hit = true; score = Math.min(score, 120); break; }
          anc = anc.parentElement;
        }

        // Known embed/player host — a strong priority hint, not a requirement.
        try {
          var host = (new URL(el.src || el.getAttribute('src') || '', location.href)).host.toLowerCase();
          for (var i = 0; i < _knownEmbedHosts.length; i++) {
            if (host.indexOf(_knownEmbedHosts[i]) !== -1) { hit = true; score = Math.min(score, 100); break; }
          }
        } catch(e){}

        // Only now let landscape size sharpen priority among real candidates.
        if (hit && w >= 280 && w >= h) score = Math.min(score, Math.max(0, 1000 - w * h));

        return hit ? score : -1;
      }

      function reportIframe(srcRaw, el) {
        if (!srcRaw || typeof srcRaw !== 'string') return;
        var resolved;
        try {
          var parsed = new URL(srcRaw, location.href);
          resolved = parsed.href;
          if (!parsed.host || parsed.host === location.host) return;  // same-origin: shim already runs
          if (isAdHost(resolved)) return;
        } catch(e) { return; }
        if (_seenIframes[resolved]) return;
        // v2.68: only surface iframes that positively look like a video
        // player. Non-players (chat, comments, social) score -1 and are
        // never drilled into — so we stay on the game page.
        var score = _iframePlayerScore(el);
        if (score < 0) return;
        _seenIframes[resolved] = 1;
        try {
          window.webkit.messageHandlers.streamIframe.postMessage(
            JSON.stringify({ url: resolved, score: score })
          );
        } catch(e){}
      }

      function harvestIframes() {
        var iframes = document.querySelectorAll('iframe[src]');
        for (var i = 0; i < iframes.length && i < 25; i++) {
          var f = iframes[i];
          reportIframe(f.src || f.getAttribute('src'), f);
        }
      }

      // v2.59: structural ground truth for the "navigated to a near-empty
      // page" case (e.g. buffstreams.plus/index18: dom=16, no cards). Tells
      // us whether the player lives in an iframe to drill, behind a
      // play/watch button to click, or simply hasn't rendered yet —
      // instead of us guessing. Throttled; only fires once we've navigated
      // or when the page is suspiciously empty.
      var _lastPageStatePostedAt = 0;
      function probePageState() {
        if (window.top !== window) return;
        var now = Date.now();
        if (now - _lastPageStatePostedAt < 2500) return;
        var dom = 0;
        try { dom = document.querySelectorAll('*').length; } catch(e){}
        if (_walkClicks === 0 && dom >= 40) return;  // normal homepage — skip
        _lastPageStatePostedAt = now;
        var ifh = [];
        try {
          var fs = document.querySelectorAll('iframe[src]');
          for (var i = 0; i < fs.length && i < 6; i++) {
            var h = '';
            try { h = (new URL(fs[i].src || fs[i].getAttribute('src') || '', location.href)).host; } catch(e){}
            if (h) ifh.push(h);
          }
        } catch(e){}
        var vids = 0, btns = 0;
        try { vids = document.querySelectorAll('video').length; } catch(e){}
        try { btns = document.querySelectorAll('[class*="play" i],[class*="watch" i],[id*="play" i],[aria-label*="play" i]').length; } catch(e){}
        var info = 'rs=' + document.readyState + ' dom=' + dom
                 + ' iframes=' + ifh.length + ' vid=' + vids + ' playBtns=' + btns;
        if (ifh.length) info += ' ifh=' + ifh.join(',');
        postWalkEvent('page_state', info);
      }

      // Network intercepts
      var xhrOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        if (typeof u === 'string') report(u);
        var self = this;
        var origOnRS = null;
        Object.defineProperty(self, 'onreadystatechange', {
          get: function() { return origOnRS; },
          set: function(fn) {
            origOnRS = function() {
              if (self.readyState === 4 && self.responseURL) report(self.responseURL);
              if (fn) fn.apply(self, arguments);
            };
          },
          configurable: true
        });
        return xhrOpen.apply(this, arguments);
      };

      if (window.fetch) {
        var _f = window.fetch;
        window.fetch = function() {
          var arg = arguments[0];
          if (typeof arg === 'string') report(arg);
          else if (arg && typeof arg.url === 'string') report(arg.url);
          var p = _f.apply(this, arguments);
          if (p && typeof p.then === 'function') {
            p.then(function(resp) { if (resp && resp.url) report(resp.url); }).catch(function(){});
          }
          return p;
        };
      }

      var OrigWS = window.WebSocket;
      if (OrigWS) {
        window.WebSocket = function(url, proto) {
          report(url);
          var ws = proto ? new OrigWS(url, proto) : new OrigWS(url);
          var origOnMsg = null;
          Object.defineProperty(ws, 'onmessage', {
            get: function() { return origOnMsg; },
            set: function(fn) {
              origOnMsg = function(evt) {
                if (evt && typeof evt.data === 'string') report(evt.data);
                if (fn) fn.apply(ws, arguments);
              };
            },
            configurable: true
          });
          ws.addEventListener('message', function(evt) {
            if (evt && typeof evt.data === 'string') report(evt.data);
          });
          return ws;
        };
        window.WebSocket.prototype = OrigWS.prototype;
        window.WebSocket.CONNECTING = OrigWS.CONNECTING;
        window.WebSocket.OPEN = OrigWS.OPEN;
        window.WebSocket.CLOSING = OrigWS.CLOSING;
        window.WebSocket.CLOSED = OrigWS.CLOSED;
      }

      // DOM element intercepts
      (function(){
        var desc = Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'src');
        if (desc && desc.set) {
          Object.defineProperty(HTMLVideoElement.prototype, 'src', {
            enumerable: desc.enumerable, configurable: desc.configurable,
            get: desc.get,
            set: function(val) { report(val); desc.set.call(this, val); }
          });
        }
      })();
      (function(){
        var desc = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
        if (desc && desc.set) {
          Object.defineProperty(HTMLSourceElement.prototype, 'src', {
            enumerable: desc.enumerable, configurable: desc.configurable,
            get: desc.get,
            set: function(val) { report(val); desc.set.call(this, val); }
          });
        }
      })();
      var origSetAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(name, val) {
        if ((name === 'src' || name === 'data-src') &&
            (this.tagName === 'VIDEO' || this.tagName === 'SOURCE')) {
          report(val);
        }
        return origSetAttr.apply(this, arguments);
      };

      // Inline script + meta scanning (yt-dlp-style)
      function decodeAtob(str) {
        try { var d = atob(str); if (d.indexOf('http') === 0) return d; } catch(e){}
        return null;
      }
      function scanScripts() {
        document.querySelectorAll('script:not([src])').forEach(function(s) {
          var c = s.innerHTML.replace(/[\\r\\n\\t]+/g, ' ');
          var urlMatches = c.match(/['"`]([^'"`\\s]{10,}(?:\\.m3u8|\\.mpd)[^'"`\\s]*?)['"`]/g) || [];
          urlMatches.forEach(function(m) {
            var url = m.replace(/^['"`]|['"`]$/g, '');
            if (url.indexOf('http') !== -1) report(url);
          });
          var rx1 = /['"]?(?:file|src)['"]?\\s*:\\s*['"]([^'"]{10,})['"]/g;
          var m;
          while ((m = rx1.exec(c)) !== null) { report(m[1]); }
          // yt-dlp pattern: flashvars file= parameter
          var rx2 = /flashvars=['"][^'"]*[?&]file=([^'"&]+)/g;
          while ((m = rx2.exec(c)) !== null) {
            try { report(decodeURIComponent(m[1])); } catch(e) { report(m[1]); }
          }
          var hlsLoad = c.match(/(?:loadSource|attachMedia|src)\\s*\\(\\s*['"]([^'"]{10,})['"]/g) || [];
          hlsLoad.forEach(function(m) {
            var url = m.replace(/.*['"]([^'"]+)['"].*/, '$1');
            report(url);
          });
          var rx3 = /['"](?:url|source|stream|hls|hlsUrl|streamUrl|m3u8|manifestUrl|contentUrl)['"]\\s*:\\s*['"]([^'"]{10,})['"]/g;
          while ((m = rx3.exec(c)) !== null) { report(m[1]); }
          var b64 = c.match(/atob\\s*\\(\\s*['"]([A-Za-z0-9+\\/=]{20,})['"]\\s*\\)/g) || [];
          b64.forEach(function(match) {
            var inner = match.replace(/^atob\\s*\\(\\s*['"]/, '').replace(/['"]\\s*\\)$/, '');
            var d = decodeAtob(inner);
            if (d) report(d);
          });
          var unescaped = c.replace(/\\\\u([0-9a-fA-F]{4})/g, function(_, h) {
            return String.fromCharCode(parseInt(h, 16));
          });
          if (unescaped !== c) {
            var escMatches = unescaped.match(/https?:\\/\\/[^\\s'"<>]{10,}/g) || [];
            escMatches.forEach(function(u) { report(u); });
          }
        });

        // yt-dlp pattern: JSON-LD VideoObject schema
        document.querySelectorAll('script[type="application/ld+json"]').forEach(function(s) {
          try {
            var data = JSON.parse(s.innerHTML);
            var items = Array.isArray(data) ? data : [data];
            items.forEach(function(item) {
              if (!item) return;
              if (item['@type'] === 'VideoObject' || item['@type'] === 'BroadcastEvent') {
                if (item.contentUrl) report(item.contentUrl);
                if (item.embedUrl) report(item.embedUrl);
              }
            });
          } catch(e){}
        });

        // yt-dlp pattern: broadened og:video / twitter:player meta tags
        document.querySelectorAll(
          'meta[property="og:video"], meta[property="og:video:url"], ' +
          'meta[property="og:video:secure_url"], meta[name="twitter:player:stream"]'
        ).forEach(function(m) {
          var c = m.getAttribute('content');
          if (c) report(c);
        });
      }

      // v2.35: goal-directed traversal.
      // The walk works like a person browsing the site: at each page
      // load, find an element mentioning the target game (or — if not
      // found and we're at depth 0 — a league-named category link),
      // click it, and let the page navigate. Bounded by _maxWalkClicks
      // so we never loop forever. All the actual .m3u8 capture stays
      // in the existing intercept paths; the walk just drives the page
      // toward a state where streams emerge.
      var _walkClicks = 0;
      var _maxWalkClicks = 4;
      var _walkClickedEls = [];
      var _lastTargetPostedAt = 0;

      // v2.39: surface walk activity to native so PlayerView's verification
      // strip can show what's happening. Without this, walks are silent —
      // the user can't tell whether tryAdvance() fired, found a match,
      // clicked something, or struck out.
      var _lastNoMatchPosted = 0;
      function postWalkEvent(kind, info) {
        try {
          window.webkit.messageHandlers.streamWalk.postMessage(JSON.stringify({
            kind: kind,
            info: (info || '').slice(0, 160),
            time: Date.now()
          }));
        } catch(e){}
      }
      function postWalkPayload(kind, payload) {
        try {
          window.webkit.messageHandlers.streamWalk.postMessage(JSON.stringify({
            kind: kind,
            payload: payload,
            time: Date.now()
          }));
        } catch(e){}
      }

      // v2.40: harvest game-shaped cards from the current DOM so the user
      // can see what's actually on the page (rather than just "no match").
      // If their target game IS in the list but our exact matcher missed,
      // they can tap it manually. If it's NOT in the list, they know to
      // switch sources.
      var _gameLinePattern = /([A-Z][\\w'.\\-]+(?:\\s[A-Z][\\w'.\\-]+){0,3})\\s+(?:vs\\.?|@|—|–)\\s+([A-Z][\\w'.\\-]+(?:\\s[A-Z][\\w'.\\-]+){0,3})/;
      var _lastDetectedSerialized = '';
      var _lastDetectedPostedAt = 0;
      function harvestDetectedCards() {
        // v2.42: same-origin sub-frames have their own tiny documents
        // and would post their own (irrelevant) card lists. Only the
        // main frame should harvest.
        if (window.top !== window) return;
        var now = Date.now();
        var found = [];
        var seen = {};
        var candidates;
        try {
          candidates = document.querySelectorAll(
            'a[href], button, [onclick], [data-match], [data-event], [data-game], ' +
            '[role="button"], ' +
            '[class*="match" i],[class*="game" i],[class*="card" i],[class*="event" i],' +
            '[class*="fixture" i]'
          );
        } catch(e) { return; }
        // v2.54: target-token setup. The detector reliably finds real
        // "X vs Y" cards; if one matches the tapped game we CLICK it in
        // this same DOM pass — eliminating the stale-chip divergence
        // where tryAdvance's separate live scan missed a card the
        // (sticky) "Found on this page" strip still showed.
        var tgt = window.__sc_target;
        var haveToks = _hasAnyToks('home') && _hasAnyToks('away');
        var targetEl = null, targetSize = Infinity, targetPair = '';
        var nPairs = 0, firstPair = '';
        var cap = Math.min(candidates.length, 1200);
        for (var i = 0; i < cap; i++) {
          var el = candidates[i];
          var blob = readableTextFromElement(el);
          if (!blob || blob.length < 8 || blob.length > 600) continue;
          var m = blob.match(_gameLinePattern);
          if (!m) continue;
          var pair = (m[1] + ' vs ' + m[2]).trim();
          nPairs++;
          if (!firstPair) firstPair = pair;
          // Does this detected pair match the tapped game? (order-free)
          if (haveToks && blob.length < targetSize) {
            var pl = (m[1] + ' ' + m[2]).toLowerCase();
            if (_pairHit(pl)) {
              targetEl = el; targetSize = blob.length; targetPair = pair;
            }
          }
          var key = pair.toLowerCase();
          if (!seen[key] && found.length < 12) {
            seen[key] = 1;
            found.push({ text: pair, blob: blob.slice(0, 140) });
          }
        }
        // v2.55: one conclusive, short (won't-truncate) line every scan
        // saying exactly what the detector-driven clicker decided. This
        // is the ground truth we've been missing: whether a target card
        // was found, whether we already clicked it (and the page didn't
        // move), or whether the tokens simply don't match what's on page.
        var now2 = Date.now();
        if (now2 - _lastTargetPostedAt > 1500) {
          _lastTargetPostedAt = now2;
          var tgtStr = (tgt && tgt.home ? tgt.home : '?') + '|' + (tgt && tgt.away ? tgt.away : '?');
          if (targetEl) {
            var clkEl = findClickableAncestor(targetEl);
            if (!_isReallyClickable(clkEl)) {
              // The match is page text (title/heading), not a card — we've
              // likely ARRIVED at the game page. Don't click; look for the
              // player. probePageState() tells us iframe/video/button state.
              postWalkEvent('target', 'ON-PAGE-NO-CARD pair="' + targetPair + '"');
            } else {
              var alreadyClicked = _walkClickedEls.indexOf(clkEl) !== -1;
              postWalkEvent('target',
                (alreadyClicked ? 'CLICKED-BUT-NO-NAV pair="' : 'MATCH pair="')
                + targetPair + '"');
            }
          } else if (nPairs > 0) {
            postWalkEvent('target',
              'NO-MATCH tgt=' + tgtStr + ' pairs=' + nPairs + ' eg="' + firstPair + '"');
          } else {
            postWalkEvent('target', 'NO-PAIRS tgt=' + tgtStr + ' cands=' + candidates.length);
          }
        }
        // Click (or, better, navigate to) the matching card immediately —
        // same pass it was seen. v2.56: prefer following the card's real
        // href so the URL actually changes.
        // v2.59: prefer following the slug-href anchor — it carries both
        // team names in its URL and is a guaranteed real navigation. Only
        // fall back to clicking matched card text if there's no slug link.
        var slugAnchor = null;
        try { slugAnchor = findTargetByHrefSlug(); } catch(e){}
        if (slugAnchor && _walkClicks < _maxWalkClicks &&
            _walkClickedEls.indexOf(slugAnchor) === -1) {
          _walkClickedEls.push(slugAnchor);
          _walkClicks++;
          _currentMirrorEl = slugAnchor;
          _mirrorClickAt = Date.now();
          postWalkEvent('slug', 'href="' + _slugScanStats.href + '"');
          dumpCard(slugAnchor);
          clickOrNavigate(slugAnchor, 'clicked', 'slug: ' + _slugScanStats.href);
        } else if (targetEl && _walkClicks < _maxWalkClicks) {
          var node = findClickableAncestor(targetEl);
          if (node && _isReallyClickable(node) && _walkClickedEls.indexOf(node) === -1) {
            _walkClickedEls.push(node);
            _walkClicks++;
            _currentMirrorEl = node;
            _mirrorClickAt = Date.now();
            dumpCard(node);
            clickOrNavigate(node, 'clicked', 'detected: ' + targetPair);
          }
        }
        if (found.length === 0) return;
        var serialized = JSON.stringify(found);
        if (serialized === _lastDetectedSerialized) return;  // unchanged
        if (now - _lastDetectedPostedAt < 2000) return;       // throttle posting
        _lastDetectedSerialized = serialized;
        _lastDetectedPostedAt = now;
        postWalkPayload('detected_cards', found);
      }

      // v2.40: detect auth/login walls so the user knows why we can't
      // navigate further (streameast's SSO frame is the textbook case).
      var _authWallReported = false;
      function detectAuthWall() {
        // v2.42: only the main frame's URL/title/DOM should drive the
        // auth-wall warning. A same-origin sub-frame whose URL happens
        // to contain "/auth" or whose host starts with "auth." would
        // otherwise post a false-positive warning while the actual
        // main-frame page renders games fine.
        if (window.top !== window) return;
        if (_authWallReported) return;
        var url = location.href.toLowerCase();
        var title = (document.title || '').toLowerCase();
        var hostHints = ['/sso', '/signin', '/sign-in', '/login', '/log-in', '/auth', 'auth.', 'login.', 'sso-frame'];
        var titleHints = ['sign in', 'log in', 'login', 'authentication required', 'access denied'];
        var hostMatch = hostHints.some(function(h){ return url.indexOf(h) !== -1; });
        var titleMatch = titleHints.some(function(h){ return title.indexOf(h) !== -1; });
        // Also: very tiny DOM with no game-shaped content is suspicious.
        var domSize = 0;
        try { domSize = document.querySelectorAll('*').length; } catch(e){}
        var tinyAndEmpty = domSize < 50 && document.querySelectorAll('input[type="password"], input[name*="pass" i], input[id*="pass" i]').length > 0;
        if (hostMatch || titleMatch || tinyAndEmpty) {
          _authWallReported = true;
          var reason = hostMatch ? 'host: ' + (new URL(location.href)).host
                     : titleMatch ? 'title: ' + (document.title || '').slice(0, 60)
                     : 'password field detected';
          postWalkEvent('auth_wall', reason);
        }
      }

      // v2.45: many modern JS frameworks (React, Vue, Svelte) attach
      // their click handlers via addEventListener for pointer/mouse
      // events rather than the inline onclick that .click() synthesizes.
      // robustClick dispatches the full pointer+mouse sequence so
      // framework-attached handlers receive the event. Wrapped in
      // try/catch so older WebKit without PointerEvent doesn't break.
      function robustClick(el) {
        if (!el) return;
        try { el.click(); } catch(e) {}
        try {
          var rect = el.getBoundingClientRect();
          var x = rect.left + Math.max(1, rect.width / 2);
          var y = rect.top + Math.max(1, rect.height / 2);
          var seq = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
          for (var i = 0; i < seq.length; i++) {
            var type = seq[i];
            try {
              var ev;
              if (type.indexOf('pointer') === 0 && typeof PointerEvent === 'function') {
                ev = new PointerEvent(type, {
                  bubbles: true, cancelable: true,
                  clientX: x, clientY: y,
                  pointerType: 'mouse'
                });
              } else if (type.indexOf('pointer') !== 0) {
                ev = new MouseEvent(type, {
                  bubbles: true, cancelable: true, view: window,
                  clientX: x, clientY: y
                });
              }
              if (ev) el.dispatchEvent(ev);
            } catch(e) {}
          }
        } catch(e) {}
      }

      // v2.41: walk up from a text-matched element to the nearest
      // actually clickable ancestor. Many SPA frameworks wrap
      // clickable cards around an inner text node (e.g. bintv's
      // <div class="match-card" onclick="..."><h2>X vs Y</h2></div>) —
      // matching the smallest text node and clicking it does nothing
      // because the onclick lives on a parent. Walking up to that
      // parent fixes a whole class of "matched the right card but
      // didn't navigate" failures.
      function findClickableAncestor(el) {
        if (!el) return null;
        var n = el;
        for (var lvl = 0; lvl < 6 && n; lvl++) {
          if (n.tagName === 'A' || n.tagName === 'BUTTON') return n;
          if (n.hasAttribute && (
                n.hasAttribute('onclick') ||
                n.hasAttribute('data-match') ||
                n.hasAttribute('data-event') ||
                n.hasAttribute('data-game') ||
                n.hasAttribute('data-id') ||
                n.getAttribute('role') === 'button'
              )) return n;
          n = n.parentElement;
        }
        return el;  // fallback — original match
      }

      // v2.56: the click-but-no-nav fix. The walk reliably matches the
      // correct card, but robustClick on SPA cards / target="_blank"
      // anchors / window.open handlers frequently does NOT change the
      // URL — so we sit on Hop 1 forever. The cure: pull the real href
      // out of the matched element (self → descendant <a> → ancestor
      // <a>) and navigate straight to it with location.href, which
      // ALWAYS produces a real navigation regardless of framework or
      // popup-blocking. Only falls back to a synthetic click when there
      // is no usable href to follow.
      function _usableHref(h) {
        if (!h) return false;
        h = ('' + h).trim();
        if (!h || h === '#' || h === '/') return false;
        var low = h.toLowerCase();
        if (low.indexOf('javascript:') === 0 || low.indexOf('mailto:') === 0 ||
            low.indexOf('tel:') === 0 || low.indexOf('#') === 0) return false;
        return true;
      }
      // v2.63: team tokens from the tapped game, used to validate
      // cross-origin links so we follow real deep links but not ads.
      function _hrefTokens() {
        var t = [], tg = window.__sc_target;
        if (tg) [tg.home, tg.away].forEach(function(s){
          s = (s || '').toLowerCase();
          s.split('-').forEach(function(w){ if (w.length >= 4) t.push(w); });
        });
        return t;
      }
      // v2.63: a card href is only worth following if it stays on the same
      // site (the site's own watch/game page) OR is a cross-origin URL
      // carrying a team token (a genuine deep link). Cross-origin token-less
      // hrefs are betting/affiliate ads (ntv.cx cards wrap a playonrain →
      // rainbet link) that send the walk into a casino dead-end. Reject them.
      function _navHrefOK(href) {
        if (!href) return false;
        // v2.70: never follow a link into a different sport/league than the
        // one we want. An LA MLB game page links to other LA games (e.g. the
        // WNBA Sparks); the shared city token shouldn't carry us there.
        if (_urlLeagueConflicts(href)) return false;
        var u; try { u = new URL(href, location.href); } catch(e){ return true; }
        if (u.host === location.host) return true;
        var low = u.href.toLowerCase(), toks = _hrefTokens();
        for (var i = 0; i < toks.length; i++){ if (low.indexOf(toks[i]) !== -1) return true; }
        // v2.65: also accept cross-origin deep links routed by team
        // abbreviation (e.g. embedindia.st/embed/mlb/.../wsh-ari). v2.70:
        // require two DISTINCT team tokens so a shared city word (or a lone
        // 2-char abbr in an ad URL) can't satisfy both sides.
        if (_hasAnyToks('home') && _hasAnyToks('away') && _pairHit(low)) return true;
        return false;
      }
      // v2.73: a URL is only safe to auto-navigate to if it NAMES THE GAME —
      // i.e. it carries a distinctive token from BOTH teams (_pairHit). The
      // old code grabbed the first usable same-site href anywhere near the
      // card, which on ntv.cx meant a generic "/matches/kobra" server link
      // sitting beside the game card. We kept detouring there instead of the
      // one-hop "/watch/kobra/<teams>-<id>" the card's own click produces.
      // Requiring the game's tokens means we only shortcut to a true deep
      // link; for anything else we let the card's own handler run (below).
      function _hrefNamesGame(h) {
        if (!_usableHref(h) || !_navHrefOK(h)) return false;
        if (!(_hasAnyToks('home') && _hasAnyToks('away'))) return false;
        return _pairHit(('' + h).toLowerCase());
      }
      // Scan an element's onclick text + data-* attributes for a URL that
      // names the game. (We never extract a generic URL here — a non-game
      // URL in a handler is exactly the /matches/kobra trap.)
      function _gameHrefFromHandler(el) {
        if (!el || !el.getAttribute) return '';
        var dataAttrs = ['data-href','data-url','data-link','data-src','data-watch','data-play','data-stream'];
        // data-* attributes may hold a plain URL → accept directly.
        for (var a = 0; a < dataAttrs.length; a++) {
          var dv = el.getAttribute(dataAttrs[a]);
          if (dv && _hrefNamesGame(dv)) return dv;
        }
        // onclick is JS code, not a URL — only regex-extract a quoted URL from
        // it (the old code returned the raw "location.href='…'" string).
        var srcs = [];
        var oc = el.getAttribute('onclick'); if (oc) srcs.push(oc);
        for (var a2 = 0; a2 < dataAttrs.length; a2++) { var v = el.getAttribute(dataAttrs[a2]); if (v) srcs.push(v); }
        for (var s = 0; s < srcs.length; s++) {
          var re = /['"]((?:https?:\\/\\/|\\/)[^'"]+)['"]/g, m;
          while ((m = re.exec(srcs[s])) !== null) { if (_hrefNamesGame(m[1])) return m[1]; }
        }
        return '';
      }
      // v2.74: scan the page for ANY URL that names the game — in an <a href>,
      // an onclick handler (ntv.cx: <div class="match-card" onclick=
      // "location.href='/watch/kobra/<teams>-<id>'">), or a data-* attribute.
      // This is the most reliable advance on JS-rendered grids where the card
      // is a <div> with no anchor and a synthetic click is ignored: we read
      // the destination straight out of the markup and navigate to it.
      function findGameUrl() {
        if (!window.__sc_target) return '';
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return '';
        var els;
        try {
          els = document.querySelectorAll(
            'a[href],[onclick],[data-href],[data-url],[data-link],[data-src],[data-watch],[data-play],[data-stream]');
        } catch(e){ return ''; }
        var cap = Math.min(els.length, 3000);
        for (var i = 0; i < cap; i++) {
          var el = els[i];
          var cands = [];
          var href = el.getAttribute && el.getAttribute('href');
          if (href) cands.push(href);
          var dataAttrs = ['data-href','data-url','data-link','data-src','data-watch','data-play','data-stream'];
          for (var d = 0; d < dataAttrs.length; d++) { var dv = el.getAttribute && el.getAttribute(dataAttrs[d]); if (dv) cands.push(dv); }
          var oc = el.getAttribute && el.getAttribute('onclick');
          if (oc) { var re = /['"]((?:https?:\\/\\/|\\/)[^'"]+)['"]/g, m; while ((m = re.exec(oc)) !== null) cands.push(m[1]); }
          for (var c = 0; c < cands.length; c++) {
            var u = cands[c];
            if (_usableHref(u) && _navHrefOK(u) && _pairHit(('' + u).toLowerCase())) return u;
          }
        }
        return '';
      }
      // Returns a deep link that names the game (anchor href, descendant/
      // sibling anchor, or a URL embedded in a handler), or '' if none.
      function _findNavHref(el) {
        if (!el) return '';
        var n = el, lvl = 0;
        while (n && lvl < 6) {
          if (n.tagName === 'A') {
            var h = n.getAttribute('href');
            if (_hrefNamesGame(h)) return h;
          }
          try {
            var as = n.querySelectorAll && n.querySelectorAll('a[href]');
            if (as) for (var i = 0; i < as.length; i++) {
              var hh = as[i].getAttribute('href');
              if (_hrefNamesGame(hh)) return hh;
            }
          } catch(e){}
          var hm = _gameHrefFromHandler(n);
          if (hm) return hm;
          n = n.parentElement; lvl++;
        }
        return '';
      }
      // v2.58: one-time structural ground-truth dump of a card we're about
      // to act on, so we can SEE on-device what these sites actually use
      // (anchor? onclick? sibling link? nothing?) instead of guessing.
      var _dumpedCards = [];
      function dumpCard(node) {
        try {
          if (!node || _dumpedCards.indexOf(node) !== -1) return;
          _dumpedCards.push(node);
          var parts = [];
          parts.push('tag=' + node.tagName);
          var href = node.getAttribute && node.getAttribute('href');
          parts.push('href=' + (href ? ('' + href).slice(0, 40) : '-'));
          // v2.71: dump the actual onclick text + any data-* attrs so a
          // no-href card's navigation mechanism is visible in the log when
          // URL extraction can't recover it (function-arg routers etc.).
          var ocv = node.getAttribute && node.getAttribute('onclick');
          parts.push('onclick=' + (ocv ? ('"' + ('' + ocv).slice(0, 80) + '"') : 'N'));
          var dataAttrs = ['data-href','data-url','data-link','data-src','data-watch','data-play','data-stream','data-id','data-match'];
          for (var da = 0; da < dataAttrs.length; da++) {
            var dv = node.getAttribute && node.getAttribute(dataAttrs[da]);
            if (dv) parts.push(dataAttrs[da] + '="' + ('' + dv).slice(0, 50) + '"');
          }
          parts.push('role=' + ((node.getAttribute && node.getAttribute('role')) || '-'));
          var box = node;
          for (var u = 0; u < 3 && box.parentElement; u++) box = box.parentElement;
          var as = (box.querySelectorAll ? box.querySelectorAll('a[href]') : []);
          parts.push('aIn=' + as.length);
          var hs = [];
          for (var i = 0; i < as.length && i < 2; i++) {
            var hh = as[i].getAttribute('href');
            hs.push((hh || '').slice(0, 30));
          }
          if (hs.length) parts.push('a=' + hs.join('|'));
          postWalkEvent('card_dump', parts.join(' '));
        } catch(e){ postWalkEvent('card_dump', 'err ' + e); }
      }
      // v2.59: is this node something a click could actually act on? A
      // page's <h1>/<title> can contain "Atlanta Braves vs Toronto Blue
      // Jays" (because we're already ON the game page) — matching it as a
      // "card" and clicking it does nothing forever (CLICKED-BUT-NO-NAV).
      // Only treat a match as a clickable card if it's a real link/button
      // or carries a usable href; otherwise we've ARRIVED and should look
      // for the player instead of clicking text.
      function _isReallyClickable(node) {
        if (!node) return false;
        if (node.tagName === 'A' || node.tagName === 'BUTTON') return true;
        if (node.hasAttribute && (node.hasAttribute('onclick') || node.getAttribute('role') === 'button')) return true;
        if (_findNavHref(node)) return true;
        return false;
      }
      // v2.72: run an inline onclick handler's code directly. Sites like
      // ntv.cx route game cards through a JS handler — goWatch('kobra',
      // 2387854) — that builds /watch/kobra/<slug>-<id> at runtime. A
      // synthetic click is ignored (untrusted), and the URL is in no
      // attribute we can read, so the only way through is to execute the
      // handler itself. Walks up to the nearest element with an onclick
      // ATTRIBUTE (handlers bound via addEventListener aren't reachable this
      // way) and evaluates it with `this` bound to that element. Reports the
      // handler text so a routing scheme we still can't fire is visible.
      function _runInlineHandler(node) {
        var n = node, lvl = 0;
        while (n && lvl < 6) {
          var oc = n.getAttribute && n.getAttribute('onclick');
          if (oc) {
            postWalkEvent('handler', oc.slice(0, 120));
            try { (new Function(oc)).call(n); return true; }
            catch(e) { postWalkEvent('click_failed', 'handler: ' + String(e).slice(0, 60)); return false; }
          }
          n = n.parentElement; lvl++;
        }
        return false;
      }
      // Returns 'nav' when it forced a real URL change, else 'click'.
      function clickOrNavigate(node, kind, label) {
        var href = _findNavHref(node);
        if (href) {
          var abs = href;
          try { abs = new URL(href, location.href).href; } catch(e){}
          if (abs && abs.split('#')[0] !== location.href.split('#')[0]) {
            postWalkEvent(kind, 'nav→ ' + abs);
            try { location.href = abs; return 'nav'; } catch(e){}
          }
        }
        postWalkEvent(kind, label);
        // Try executing an inline handler first — for JS-router cards it's the
        // only thing that fires; for everything else robustClick is the path.
        var ran = false;
        try { ran = _runInlineHandler(node); } catch(e){}
        if (!ran) {
          try { robustClick(node); } catch(e){ postWalkEvent('click_failed', String(e)); }
        }
        return 'click';
      }

      function readableTextFromElement(el) {
        if (!el) return '';
        var parts = [];
        var t = '';
        try { t = (el.innerText || el.textContent || '').replace(/\\s+/g,' ').trim(); } catch(e){}
        if (t) parts.push(t);
        if (el.getAttribute) {
          var aria = el.getAttribute('aria-label');
          if (aria) parts.push(aria);
          var title = el.getAttribute('title');
          if (title) parts.push(title);
          var dm = el.getAttribute('data-match');
          if (dm) parts.push(dm);
          // v2.50: include href (and common JS-card equivalents) so team
          // names that live ONLY in the URL slug (e.g. <a href="/mlb/
          // milwaukee-brewers-vs-chicago-cubs/">MIL @ CHC</a>) get matched.
          // Sites that render with abbreviations but route via team-slug
          // URLs were stuck at Hop 1 because the shim's text-only blob
          // couldn't see "milwaukee-brewers"/"chicago-cubs" in the href.
          var hrefAttrs = ['href', 'data-href', 'data-url', 'data-link'];
          for (var hi = 0; hi < hrefAttrs.length; hi++) {
            var hv = el.getAttribute(hrefAttrs[hi]);
            if (hv) parts.push(hv);
          }
        }
        // v2.44: many sites render score cards with team LOGOS only —
        // full team names live in <img alt="…">. Without this we'd
        // miss "Cleveland Cavaliers" on streameast (visible text:
        // "Cavaliers 104 110 Knicks"). Mirrors what WebViewScraper's
        // listing-time readableTextFor does already.
        if (el.querySelectorAll) {
          try {
            var imgs = el.querySelectorAll('img[alt]');
            for (var ii = 0; ii < imgs.length && ii < 4; ii++) {
              var altTxt = imgs[ii].getAttribute('alt');
              if (altTxt) parts.push(altTxt);
            }
          } catch(e){}
        }
        var out = parts.join(' | ');
        if (out.length > 600) out = out.slice(0, 600);
        return out;
      }

      // v2.43: side-channel stats so tryAdvance can post a scan event.
      // v2.44: rejSample is the longest blob the matcher rejected — shown
      // to the user when matched=0 so we can see what we're scanning.
      // v2.53: nHome/nAway count elements containing ONLY one team's
      // tokens — distinguishes "team names not in DOM at all" from "both
      // teams in DOM but never co-located in the same wrapper element".
      // v2.65: shared team-token model. __sc_target carries, per side, long
      // tokens (homeTok/awayTok, ≥4 chars — full slug words + nicknames) and
      // short abbreviations (homeAbbr/awayAbbr, e.g. "wsh"/"ari"). Long tokens
      // match as plain substrings; abbreviations match ONLY as a bounded slug
      // segment (delimited by non-alphanumerics) so "ari" can't fire inside
      // "marina" or a date. This unifies what every matcher below considers a
      // "team hit", and is what lets abbreviation-routed URLs (ppv.to's
      // /live/mlb/2026-06-07/wsh-ari) resolve to the right game.
      function _longToks(side) {
        var tg = window.__sc_target; if (!tg) return [];
        var explicit = tg[side + 'Tok'] || [];
        var t = [];
        for (var i = 0; i < explicit.length; i++) {
          var e = ('' + explicit[i]).toLowerCase(); if (e.length >= 4) t.push(e);
        }
        // Fall back to slug-derived tokens so an older/empty Tok array still
        // matches the canonical name.
        var slug = (tg[side] || '').toLowerCase();
        if (slug.length >= 4 && t.indexOf(slug) === -1) t.push(slug);
        slug.split('-').forEach(function(w){ if (w.length >= 4 && t.indexOf(w) === -1) t.push(w); });
        return t;
      }
      function _abbrToks(side) {
        var tg = window.__sc_target; if (!tg) return [];
        var ab = tg[side + 'Abbr'] || [];
        var t = [];
        for (var i = 0; i < ab.length; i++) {
          var a = ('' + ab[i]).toLowerCase();
          if (a.length >= 2 && a.length <= 3) t.push(a);
        }
        return t;
      }
      function _isWordChar(c) { return c >= 'a' && c <= 'z' || c >= '0' && c <= '9'; }
      // Bounded substring search: true iff `needle` appears in `hay` delimited
      // by a non-word char (or string edge) on both sides.
      function _boundedHit(hay, needle) {
        var idx = hay.indexOf(needle);
        while (idx !== -1) {
          var before = idx === 0 ? '' : hay.charAt(idx - 1);
          var after = hay.charAt(idx + needle.length);
          if ((!before || !_isWordChar(before)) && (!after || !_isWordChar(after))) return true;
          idx = hay.indexOf(needle, idx + 1);
        }
        return false;
      }
      // Does `blob` (already lowercased or not) mention this side's team?
      function _sideHit(blob, side) {
        var low = ('' + blob).toLowerCase();
        var longs = _longToks(side);
        for (var i = 0; i < longs.length; i++) if (low.indexOf(longs[i]) !== -1) return true;
        var abbrs = _abbrToks(side);
        for (var j = 0; j < abbrs.length; j++) if (_boundedHit(low, abbrs[j])) return true;
        return false;
      }
      function _hasAnyToks(side) {
        return _longToks(side).length > 0 || _abbrToks(side).length > 0;
      }

      // v2.70: every distinct token from `side` that appears in `blob`.
      function _collectHits(blob, side) {
        var low = ('' + blob).toLowerCase(), hits = [];
        var longs = _longToks(side);
        for (var i = 0; i < longs.length; i++)
          if (low.indexOf(longs[i]) !== -1 && hits.indexOf(longs[i]) === -1) hits.push(longs[i]);
        var abbrs = _abbrToks(side);
        for (var j = 0; j < abbrs.length; j++)
          if (_boundedHit(low, abbrs[j]) && hits.indexOf(abbrs[j]) === -1) hits.push(abbrs[j]);
        return hits;
      }
      // v2.70: a token only identifies a side if it is EXCLUSIVE to that side
      // — i.e. not also a token of the other team. Two same-city teams share
      // the city words ("angeles", "los angeles"), so those can never
      // disambiguate them.
      function _tokExclusive(tok, otherSide) {
        var ol = _longToks(otherSide), oa = _abbrToks(otherSide);
        for (var i = 0; i < ol.length; i++) if (ol[i] === tok) return false;
        for (var j = 0; j < oa.length; j++) if (oa[j] === tok) return false;
        return true;
      }
      // v2.71: a true pair match requires home AND away to each be hit by a
      // token EXCLUSIVE to that side. The earlier "two different tokens" rule
      // was fooled by an LA-vs-LA game: it saw home-hit "angeles" ≠ away-hit
      // "los angeles" and called the WNBA "Portland Fire vs Los Angeles
      // Sparks" a match, since both are *different* shared city strings.
      // Filtering to exclusive tokens means only a genuinely distinctive
      // token (nickname/abbr — "dodgers" vs "angels") can satisfy a side.
      function _pairHit(blob) {
        var hh = _collectHits(blob, 'home').filter(function(t){ return _tokExclusive(t, 'away'); });
        if (!hh.length) return false;
        var aa = _collectHits(blob, 'away').filter(function(t){ return _tokExclusive(t, 'home'); });
        return aa.length > 0;
      }
      // v2.70: does this URL name a DIFFERENT sport/league than the target's?
      // Streameast routes by league segment (/mlb/…, /wnba/…); an MLB game
      // page links to same-site games in other leagues, and we must never
      // follow those. Returns true only when the path names some other
      // league and does NOT name ours. `_leagueHints` (defined below) is the
      // same league→keyword map the category finder already uses.
      function _urlLeagueConflicts(url) {
        var tg = window.__sc_target;
        if (!tg || !tg.league || typeof _leagueHints === 'undefined') return false;
        var path;
        try { path = new URL(url, location.href).pathname.toLowerCase(); }
        catch(e) { path = ('' + url).toLowerCase(); }
        var mine = _leagueHints[tg.league] || [];
        for (var i = 0; i < mine.length; i++) if (_boundedHit(path, mine[i])) return false;
        for (var lg in _leagueHints) {
          if (lg === tg.league) continue;
          var keys = _leagueHints[lg];
          for (var k = 0; k < keys.length; k++) if (_boundedHit(path, keys[k])) return true;
        }
        return false;
      }

      var _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };

      function selectTargetGameElement() {
        _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };
        if (!window.__sc_target) return null;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return null;
        function bothPresent(text) {
          return _pairHit(text);
        }
        var candidates;
        try {
          candidates = document.querySelectorAll(
            'a[href], button, [onclick], [data-match], [data-event], ' +
            '[data-game], [data-id], [role="button"], ' +
            '[class*="match" i],[class*="game" i],[class*="card" i],[class*="event" i]'
          );
        } catch(e) { return null; }
        _scanStats.candidates = candidates.length;
        var smallest = null, smallestSize = Infinity;
        var longestRej = 0;
        var cap = Math.min(candidates.length, 3000);
        for (var i = 0; i < cap; i++) {
          var el = candidates[i];
          var blob = readableTextFromElement(el);
          if (!blob || blob.length < 6 || blob.length > 1200) continue;
          if (!bothPresent(blob)) {
            // v2.44: track the longest rejected blob so the user can see
            // what content the matcher is rejecting. Diagnostic only —
            // does not affect matching logic.
            if (blob.length > longestRej) {
              longestRej = blob.length;
              _scanStats.rejSample = blob.slice(0, 80);
            }
            continue;
          }
          _scanStats.matched++;
          if (blob.length < smallestSize) {
            smallestSize = blob.length;
            smallest = el;
            // capture a short sample of the smallest matching blob
            _scanStats.sample = blob.slice(0, 80);
          }
        }
        // v2.41: clicking the smallest text-matched element often fails
        // because the onclick is on a wrapping ancestor. Walk up.
        return findClickableAncestor(smallest);
      }

      // v2.52: element-walk fallback for sites whose card text lives in
      // attributes (aria-label, img alt, title, data-match) rather than
      // textContent. Earlier v2.51's text-node tree-walk reported
      // cands=0 across Streameast/CrackStreams/bintv — proof the team
      // names weren't in text nodes at all. This walker visits every
      // element (capped) and uses the same `readableTextFromElement`
      // blob harvestDetectedCards uses, so anything visible to the
      // user-facing "Found on this page" detector is also visible here.
      // Smallest matching blob wins; findClickableAncestor handles the
      // common wrapping-onclick case.
      function findTargetByTreeWalk() {
        _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };
        if (!window.__sc_target) return null;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return null;
        var allEls;
        try { allEls = document.querySelectorAll('*'); } catch(e) { return null; }
        var cap = Math.min(allEls.length, 5000);
        _scanStats.candidates = cap;
        var bestEl = null, bestSize = Infinity;
        var longestRej = 0;
        for (var i = 0; i < cap; i++) {
          var el = allEls[i];
          // Skip elements that won't ever be clickable wrappers.
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'script' || tag === 'style' || tag === 'meta' ||
              tag === 'link' || tag === 'head' || tag === 'html' ||
              tag === 'body' || tag === 'svg' || tag === 'path') continue;
          var blob = readableTextFromElement(el).toLowerCase();
          if (blob.length < 6 || blob.length > 1200) continue;
          var hh = _sideHit(blob, 'home'), aa = _sideHit(blob, 'away');
          if (_pairHit(blob)) {
            _scanStats.matched++;
            if (blob.length < bestSize) {
              bestSize = blob.length;
              bestEl = el;
              _scanStats.sample = blob.slice(0, 80);
            }
          } else {
            // v2.53: track elements that mention exactly one team. Lets
            // us distinguish "team names absent from DOM" (both = 0)
            // from "teams present but never co-located" (one > 0, both = 0).
            if (hh && !aa) _scanStats.nHome++;
            if (aa && !hh) _scanStats.nAway++;
            if (blob.length > longestRej) {
              longestRej = blob.length;
              _scanStats.rejSample = blob.slice(0, 80);
            }
          }
        }
        return findClickableAncestor(bestEl);
      }

      // v2.59: slug-href matcher — the strongest, most reliable signal.
      // These sites route by team slug: the real game page is
      // /mlb/atlanta-braves-toronto-blue-jays/1310742, i.e. BOTH teams are
      // encoded in the URL. The text detector only matches visible "X vs Y"
      // strings, so on an interstitial (buffstreams' /index18) it latches
      // onto the page TITLE — a no-op link — and never follows the actual
      // anchor whose href carries the slug. This scans every <a href> and
      // returns the one whose URL contains tokens from BOTH teams. Because
      // it returns a real anchor, clickOrNavigate forces location.href = it,
      // which always produces a true navigation.
      var _slugScanStats = { anchors: 0, matched: 0, href: '' };
      function findTargetByHrefSlug() {
        _slugScanStats = { anchors: 0, matched: 0, href: '' };
        if (!window.__sc_target) return null;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return null;
        var as;
        try { as = document.querySelectorAll('a[href]'); } catch(e) { return null; }
        _slugScanStats.anchors = as.length;
        var best = null, bestScore = 0;
        var cap = Math.min(as.length, 2000);
        for (var i = 0; i < cap; i++) {
          var href = '';
          try { href = as[i].getAttribute('href') || ''; } catch(e){}
          if (!_usableHref(href)) continue;
          if (_urlLeagueConflicts(href)) continue;   // wrong sport/league
          var low = href.toLowerCase();
          // v2.65: match home + away via long tokens (substring) or
          // abbreviations (bounded). v2.70: require two DISTINCT tokens so a
          // shared city word ("angeles") can't match both teams of a
          // different LA game. Score prefers abbreviation hits since a URL
          // carrying both team abbreviations is an unambiguous deep link.
          if (_pairHit(low)) {
            var score = 2;
            if (_abbrToks('home').some(function(a){ return _boundedHit(low, a); })) score++;
            if (_abbrToks('away').some(function(a){ return _boundedHit(low, a); })) score++;
            if (score > bestScore) { bestScore = score; best = as[i]; }
          }
        }
        if (best) {
          _slugScanStats.matched = 1;
          try { _slugScanStats.href = (best.getAttribute('href') || '').slice(0, 80); } catch(e){}
        }
        return best;
      }

      // v2.54: unify the click path with the detector. harvestDetectedCards
      // (the "Found on this page" strip) reliably surfaces real game-pair
      // cards via _gameLinePattern, yet selectTargetGameElement /
      // findTargetByTreeWalk kept reporting matched=0 on the same DOM — the
      // detector and the clicker disagreed. This walks the SAME candidate
      // set harvest uses, applies the SAME regex to confirm a real "X vs Y"
      // card, then checks whether that pair matches the tapped game's
      // tokens (order-independent). Returns the clickable ancestor of the
      // first matching card. If harvest can see the game, this can click it.
      var _pairScanStats = { cands: 0, pairs: 0, matched: 0, sample: '', rejSample: '' };
      function findTargetByPairScan() {
        _pairScanStats = { cands: 0, pairs: 0, matched: 0, sample: '', rejSample: '' };
        if (!window.__sc_target) return null;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return null;
        var candidates;
        try {
          candidates = document.querySelectorAll(
            'a[href], button, [onclick], [data-match], [data-event], [data-game], ' +
            '[role="button"], ' +
            '[class*="match" i],[class*="game" i],[class*="card" i],[class*="event" i],' +
            '[class*="fixture" i]'
          );
        } catch(e) { return null; }
        _pairScanStats.cands = candidates.length;
        var cap = Math.min(candidates.length, 1200);
        var best = null, bestSize = Infinity;
        for (var i = 0; i < cap; i++) {
          var el = candidates[i];
          var blob = readableTextFromElement(el);
          if (!blob || blob.length < 8 || blob.length > 600) continue;
          var m = blob.match(_gameLinePattern);
          if (!m) continue;
          _pairScanStats.pairs++;
          // The detected pair, lowercased and order-independent: a card
          // matches if BOTH teams' tokens appear somewhere in the pair
          // (the regex already proved it's an "X vs Y" card).
          var pair = (m[1] + ' ' + m[2]).toLowerCase();
          if (_pairHit(pair)) {
            _pairScanStats.matched++;
            if (blob.length < bestSize) {
              bestSize = blob.length;
              best = el;
              _pairScanStats.sample = (m[1] + ' vs ' + m[2]).slice(0, 80);
            }
          } else if (!_pairScanStats.rejSample) {
            _pairScanStats.rejSample = (m[1] + ' vs ' + m[2]).slice(0, 80);
          }
        }
        return best ? findClickableAncestor(best) : null;
      }

      // League raw-value → URL/text hints for category-link traversal.
      // Used when no game match is found and we're still at depth 0.
      var _leagueHints = {
        nba: ['nba','basketball'], wnba: ['wnba'],
        ncaab: ['ncaab','college-basket','mens-college-basket'],
        nfl: ['nfl','football'], ncaaf: ['ncaaf','college-football'],
        mlb: ['mlb','baseball'], nhl: ['nhl','hockey'],
        premierLeague: ['premier','epl','soccer','football'],
        laLiga: ['laliga','la-liga','spanish','soccer'],
        serieA: ['serie','italian','soccer'],
        bundesliga: ['bundesliga','german','soccer'],
        ligue1: ['ligue','french','soccer'],
        eredivisie: ['eredivisie','dutch','soccer'],
        mls: ['mls','soccer','football'],
        ligaMx: ['liga-mx','ligamx','mexican','soccer'],
        championsLeague: ['champions','ucl','soccer'],
        europaLeague: ['europa','uel','soccer'],
        soccer: ['soccer','football'],
        f1: ['f1','formula','motor','racing'],
        nascar: ['nascar','motor','racing'],
        mma: ['mma','ufc','fight'],
        ufc: ['ufc','mma','fight'],
        boxing: ['boxing','fight'],
        cricket: ['cricket','ipl'],
        iihf: ['hockey','ice-hockey','iihf']
      };

      // v2.45: side-channel stats for the category-link branch so
      // tryAdvance can post a cat_scan event mirroring the page-1
      // scan event. Lets us see in real time whether findCategoryLink
      // is matching a card (and which one) — diagnosing the
      // "category landing never advances" failure mode.
      var _catScanStats = { cands: 0, matched: 0, clicked: '', rejSample: '' };

      // v2.62: every league keyword we recognize, used to detect (and
      // reject) multi-league nav/footer blobs. crackstreams' header text
      // "NFL NBA MLB NHL MMA Boxing NCAA WWE MethStreams" contains "mlb"
      // and is short — the old first-match category finder picked it and
      // clicked a menu that goes nowhere, instead of the dedicated "MLB
      // Streams" card. Counting distinct leagues lets us throw those out.
      var _allLeagueWords = ['nfl','nba','wnba','mlb','nhl','ncaab','ncaaf','ncaa',
        'ufc','mma','boxing','wwe','f1','formula','nascar','soccer','football',
        'baseball','basketball','hockey','cricket','premier','laliga','bundesliga',
        'ligue','eredivisie','mls','tennis','golf','rugby'];
      function _countLeagueWords(blob) {
        var c = 0;
        for (var i = 0; i < _allLeagueWords.length; i++) {
          if (blob.indexOf(_allLeagueWords[i]) !== -1) c++;
        }
        return c;
      }

      // v2.62: score-based category finder. Picks the single, specific
      // league card (e.g. "MLB Streams") rather than the first element
      // that merely contains the league name. Strongly prefers a usable
      // href whose URL carries the league key, rejects blobs mentioning
      // several leagues (nav bars / footers), and favors short labels.
      function findCategoryLink(leagueRawValue) {
        _catScanStats = { cands: 0, matched: 0, clicked: '', rejSample: '' };
        var keys = _leagueHints[leagueRawValue] || [];
        if (!keys.length) return null;
        var els;
        try {
          els = document.querySelectorAll(
            'a[href], button, [onclick], [data-href], [role="button"], ' +
            '[class*="card" i], [class*="link" i]'
          );
        } catch(e) { return null; }
        _catScanStats.cands = els.length;
        var cap = Math.min(els.length, 800);
        var longestRej = 0;
        var best = null, bestScore = -1, bestText = '';
        for (var i = 0; i < cap; i++) {
          var el = els[i];
          var href = '';
          try { href = (el.getAttribute && (el.getAttribute('href') || el.getAttribute('data-href'))) || ''; } catch(e){}
          var txt = (el.innerText || el.textContent || '');
          var blob = (txt + ' ' + href).toLowerCase();
          if (blob.length < 3 || blob.length > 200) continue;
          var hit = false;
          for (var k = 0; k < keys.length; k++) {
            if (blob.indexOf(keys[k]) !== -1) { hit = true; break; }
          }
          if (!hit) {
            if (blob.length > longestRej) { longestRej = blob.length; _catScanStats.rejSample = blob.slice(0, 80); }
            continue;
          }
          // Reject multi-league nav/footer blobs (lists many leagues).
          if (_countLeagueWords(blob) >= 3) continue;
          var hrefLow = href.toLowerCase();
          // v2.65: reject INDIVIDUAL GAME links. On abbreviation-routed sites
          // every game card's href carries the league key (/live/mlb/<date>/
          // <teams>), so the old finder happily scored a specific game (the
          // featured Red Sox–Yankees card) as the "MLB category" and followed
          // the wrong game. A real category/listing link is not a single game:
          // it has no "X vs Y" text and no date segment in its URL.
          if (_gameLinePattern.test(txt)) {
            _catScanStats.rejSample = 'game-text:' + txt.trim().slice(0, 60);
            continue;
          }
          if (/\\d{4}-\\d{2}-\\d{2}/.test(hrefLow) || /\\/\\d{8}(\\/|$)/.test(hrefLow)) {
            _catScanStats.rejSample = 'game-date:' + hrefLow.slice(0, 60);
            continue;
          }
          var score = 0;
          for (var k2 = 0; k2 < keys.length; k2++) {
            if (hrefLow.indexOf(keys[k2]) !== -1) { score += 100; break; }
          }
          score += Math.max(0, 60 - txt.trim().length);  // prefer short labels
          if (_usableHref(href)) score += 25;
          if (score > bestScore) {
            bestScore = score; best = el; bestText = (txt.trim() || href).slice(0, 80);
          }
        }
        if (best) {
          _catScanStats.matched = 1;
          _catScanStats.clicked = bestText;
          return findClickableAncestor(best);
        }
        return null;
      }

      function tryAdvance() {
        // v2.42: only the main frame drives the walk. The shim is injected
        // with forMainFrameOnly:false so it runs in same-origin sub-frames
        // too; without this guard those sub-frames each scan their own
        // tiny document, generate misleading "no_match (dom=6)" events,
        // and shadow the real main-frame walk.
        if (window.top !== window) return;
        if (_walkClicks >= _maxWalkClicks) return;
        // v2.74: strongest, most reliable advance — a URL anywhere on the page
        // (anchor href, onclick handler, or data-* attr) that names the game.
        // Handles JS-rendered grids (ntv.cx) whose cards are <div onclick=
        // "location.href='/watch/…'"> with no anchor: read the destination out
        // of the markup and navigate straight to it, no click required.
        try {
          var gurl = findGameUrl();
          if (gurl) {
            var gabs = gurl; try { gabs = new URL(gurl, location.href).href; } catch(e){}
            if (gabs && gabs.split('#')[0] !== location.href.split('#')[0]) {
              _walkClicks++;
              postWalkEvent('slug', 'url="' + gabs.slice(0, 120) + '"');
              try { location.href = gabs; return; } catch(e){}
            }
          }
        } catch(e){}
        // Step 3: element matching target game.
        // v2.54: pair-scan first — it mirrors the working "Found on this
        // page" detector exactly (same candidates, same regex), so if the
        // game is visible to the detector it is clickable here.
        var node = null;
        try { node = findTargetByHrefSlug(); } catch(e){}
        if (node) {
          if (_walkClickedEls.indexOf(node) !== -1) return;
          _walkClickedEls.push(node);
          _walkClicks++;
          _currentMirrorEl = node;
          _mirrorClickAt = Date.now();
          postWalkEvent('slug', 'href="' + _slugScanStats.href + '"');
          dumpCard(node);
          clickOrNavigate(node, 'clicked', 'slug: ' + _slugScanStats.href);
          return;
        }
        try { node = findTargetByPairScan(); } catch(e){}
        if (!node) node = selectTargetGameElement();
        // v2.51: selector-based matcher missed — try tree-walk fallback
        // that finds the smallest element whose textContent contains
        // tokens from BOTH teams, regardless of class. Catches wrappers
        // the class selector doesn't enumerate.
        if (!node) {
          try { node = findTargetByTreeWalk(); } catch(e){}
        }
        if (node) {
          if (_walkClickedEls.indexOf(node) !== -1) return;
          _walkClickedEls.push(node);
          _walkClicks++;
          _currentMirrorEl = node;
          _mirrorClickAt = Date.now();
          var blob = readableTextFromElement(node);
          clickOrNavigate(node, 'clicked', 'card: ' + blob);
          return;
        }
        // Step 4b: no game match — at depth 0 try a league-named category link.
        if (_walkClicks === 0 && window.__sc_target && window.__sc_target.league) {
          var catNode = findCategoryLink(window.__sc_target.league);
          // v2.45: always emit cat_scan after the lookup so the user
          // sees whether the category branch found anything, regardless
          // of whether the click eventually fires. Mirrors the per-page
          // scan event from v2.43.
          var catInfo = 'cat_cands=' + _catScanStats.cands
                      + ' cat_matched=' + _catScanStats.matched;
          if (_catScanStats.matched === 1 && _catScanStats.clicked) {
            catInfo += ' clk="' + _catScanStats.clicked + '"';
          } else if (_catScanStats.rejSample) {
            catInfo += ' rej="' + _catScanStats.rejSample + '"';
          }
          postWalkEvent('cat_scan', catInfo);

          if (catNode && _walkClickedEls.indexOf(catNode) === -1) {
            _walkClickedEls.push(catNode);
            _walkClicks++;
            _currentMirrorEl = catNode;
            _mirrorClickAt = Date.now();
            var catBlob = readableTextFromElement(catNode);
            dumpCard(catNode);
            clickOrNavigate(catNode, 'category_click', catBlob);
            return;
          }
        }
        // v2.43: per-scan diagnostic. Posted on every tryAdvance that
        // doesn't click anything, with the real counts: how many
        // candidate elements were queried, how many passed
        // bothPresent, what the smallest matched blob looked like,
        // and the main-frame doc element count. Replaces the
        // throttled no_match so the user sees REAL-TIME progress
        // instead of a single stale snapshot from the earliest scan.
        var domSize = 0;
        try { domSize = document.querySelectorAll('*').length; } catch(e){}
        var info = 'dom=' + domSize
                 + ' cands=' + _scanStats.candidates
                 + ' matched=' + _scanStats.matched
                 + ' main=' + (window.top === window ? '1' : '0');
        // v2.54: pair-scan diagnostics — pairs = real "X vs Y" cards seen
        // (same as the detector strip), pm = those matching the tapped
        // game. If pairs>0 but pm=0 the page lists games but not this one;
        // if pairs=0 the cards haven't rendered (or live in an iframe).
        info += ' pairs=' + _pairScanStats.pairs + ' pm=' + _pairScanStats.matched;
        if (_pairScanStats.matched === 0 && _pairScanStats.rejSample) {
          info += ' pr="' + _pairScanStats.rejSample + '"';
        }
        // v2.53: surface single-team counts so we can tell apart
        // "team names absent from DOM" from "teams present but split
        // across different wrapper elements".
        if (_scanStats.nHome || _scanStats.nAway) {
          info += ' h=' + _scanStats.nHome + ' a=' + _scanStats.nAway;
        }
        if (_scanStats.matched > 0 && _scanStats.sample) {
          info += ' sample="' + _scanStats.sample + '"';
        }
        // v2.44: when no candidate matched both teams, show the longest
        // rejected blob — most likely to be a real game card vs UI
        // chrome — so we can see exactly what content the matcher is
        // looking at and why it isn't matching.
        if (_scanStats.matched === 0 && _scanStats.rejSample) {
          info += ' rej="' + _scanStats.rejSample + '"';
        }
        postWalkEvent('scan', info);
      }

      function scan() {
        document.querySelectorAll('video, source').forEach(function(el) {
          [el.src, el.currentSrc, el.getAttribute('src'), el.dataset && el.dataset.src].forEach(function(s) {
            if (s) report(s);
          });
        });
        scanScripts();
        // v2.37: harvest cross-origin iframes for drill-down.
        try { harvestIframes(); } catch(e){}
        try { probePageState(); } catch(e){}
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });

        // v2.54: harvest first — it both surfaces page content for the
        // verification strip AND clicks the target card the instant it's
        // detected (same DOM pass), which is the most reliable advance.
        // tryAdvance runs after as a fallback (category links, token /
        // tree-walk matching) for sites whose cards aren't clean "X vs Y".
        try { harvestDetectedCards(); } catch(e){}
        // v2.35: drive page navigation toward the target game / category.
        // Bounded by _maxWalkClicks; no-op once we've clicked enough.
        try { tryAdvance(); } catch(e){}
        try { detectAuthWall(); } catch(e){}

        var mirrorSelectors = [
          '.vjs-big-play-button', '.jw-icon-display', '.jw-display-icon-display',
          '.plyr__control--overlaid', '[data-plyr="play"]',
          '.fp-play', '.fp-ui', '[class*="flowplayer"]',
          '.play-btn', '.play_btn', '.btn-play', '.btn-stream',
          '#play', '#playBtn', '#play-btn',
          '[class*="play-button"]', '[class*="PlayButton"]',
          'button[class*="play"]', '[aria-label*="Play"]',
          '[class*="watch"]', '[id*="watch"]',
          '[class*="source"]', '[class*="mirror"]', '[class*="stream-source"]'
        ];
        var targetCard = selectTargetGameElement();
        var scope = targetCard || document;
        var candidates = [];
        var seenEls = [];
        mirrorSelectors.forEach(function(sel) {
          try {
            scope.querySelectorAll(sel).forEach(function(el) {
              if (el._sc_clicked || seenEls.indexOf(el) !== -1) return;
              var anc = el;
              var noIOS = false;
              for (var i = 0; i < 6 && anc; i++) {
                var t = (anc.innerText || anc.textContent || '').toUpperCase().replace(/\\s+/g, '');
                if (t.indexOf('NOIOS') !== -1 || t.indexOf('NO-IOS') !== -1) { noIOS = true; break; }
                anc = anc.parentElement;
              }
              seenEls.push(el);
              if (noIOS) { el._sc_clicked = 1; return; }
              candidates.push(el);
            });
          } catch(e){}
        });
        candidates.forEach(function(el, i) {
          setTimeout(function() {
            if (!el._sc_clicked) { el._sc_clicked = 1; try { el.click(); } catch(e){} }
          }, i * 2500);
        });

        try {
          document.querySelectorAll('*').forEach(function(el) {
            var s = window.getComputedStyle(el);
            var z = parseInt(s.zIndex) || 0;
            if ((s.position === 'fixed' || s.position === 'absolute') && z > 999 &&
                el.tagName !== 'VIDEO' && el.tagName !== 'BUTTON') {
              el.style.display = 'none';
            }
          });
        } catch(e){}
      }

      new MutationObserver(function(mutations) {
        scan();
        mutations.forEach(function(mut) {
          mut.addedNodes.forEach(function(node) {
            if (node.tagName === 'IFRAME') {
              var src = node.src || node.getAttribute('src') || '';
              if (src) {
                // v2.37: cross-origin iframe → drill-down candidate.
                // Same-origin (and non-iframe stream URLs from the
                // existing intercept paths) keep flowing through report().
                reportIframe(src, node);
                report(src);  // also fall through in case the src is itself a stream URL
              }
            }
            if (node.tagName === 'SCRIPT' && !node.src) {
              setTimeout(scanScripts, 200);
            }
          });
        });
      }).observe(document.documentElement || document, {childList: true, subtree: true, attributes: true});

      // v2.53: late scans cover SPA hydration that lands after the
      // existing 18 s schedule and doesn't trigger a MutationObserver
      // event the shim catches (Shadow DOM, framework batched commits,
      // route-change-only renders). Cheap insurance since each scan is
      // bounded.
      [100, 500, 1000, 2000, 3000, 5000, 8000, 12000, 18000,
       25000, 40000, 60000].forEach(function(t) {
        setTimeout(scan, t);
      });
    })();
  """

  static func credentialInjectionJS(username: String, password: String) -> String {
    let u = username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    let p = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    return """
    (function(){
      var _u = '\(u)', _p = '\(p)';
      function fill() {
        var uFields = document.querySelectorAll(
          'input[type="email"], input[type="text"][name*="user"], input[type="text"][name*="email"], ' +
          'input[type="text"][id*="user"], input[type="text"][id*="email"], ' +
          'input[name*="login"], input[id*="login"]'
        );
        var pFields = document.querySelectorAll('input[type="password"]');
        if (!uFields.length || !pFields.length) return false;
        var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
        setter.call(uFields[0], _u);
        uFields[0].dispatchEvent(new Event('input', {bubbles: true}));
        setter.call(pFields[0], _p);
        pFields[0].dispatchEvent(new Event('input', {bubbles: true}));
        var form = pFields[0].closest('form');
        var submit = form && (form.querySelector('[type="submit"]') || form.querySelector('button'));
        if (submit) setTimeout(function(){ submit.click(); }, 400);
        return true;
      }
      [600, 1200, 2500, 4000].forEach(function(t){ setTimeout(fill, t); });
    })();
    """
  }

  // MARK: Coordinator (simple — first playable URL wins)

  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?
    /// v2.48: fires after each probePlayability finishes so PlayerView
    /// can log the result to the TraversalLog.
    let onStreamProbed: ((URL, Bool, [HTTPCookie], URL?) -> Void)?
    /// v2.38: invoked from `webView(_:didCommit:)` so PlayerView can
    /// render the navigation breadcrumb.
    let onNavigation: ((URL) -> Void)?
    /// v2.39: walk-activity events from the JS-shim.
    let onWalkEvent: ((StreamWebView.WalkEvent) -> Void)?
    /// v2.39: fired when provisional navigation fails AND host-fallback
    /// couldn't recover. PlayerView shows it inline in navStrip.
    let onLoadFailed: ((URL, String) -> Void)?
    /// v2.41: fires on each commit whose host or path differs from the
    /// previous commit — signals "the page actually changed" so per-
    /// page UI state (detected cards, auth-wall warning) can reset.
    let onPageChanged: ((URL) -> Void)?
    /// v2.41: last URL whose commit we forwarded as a page change.
    private var lastCommittedKey: String?
    let browseMode: Bool
    private var found = false
    private var seenURLs = Set<String>()
    private var firstObservedURL: URL?
    weak var webView: WKWebView?
    // v2.37: cross-origin iframe drill-down state. When the JS-shim
    // reports an iframe URL via the streamIframe channel, we navigate
    // the top WebView into it so the shim runs same-origin and catches
    // the m3u8 emitted by the embed-host player. Bounded by maxHops.
    private var iframeHops = 0
    private static let maxIframeHops = 2
    private var visitedIframeURLs = Set<String>()
    /// Best (lowest-score) iframe URL we've seen for the current page.
    private var pendingBestIframe: (url: URL, score: Int)?
    /// Deadline by which we'll commit to the best iframe candidate.
    /// Allows accumulating a few candidates before picking the smallest-
    /// scoring one. 750ms is enough for fast pages, short enough not
    /// to feel laggy.
    private var iframeCommitTask: Task<Void, Never>?

    // v2.69: relevance backtracking. The iframe drill is a *guess* — it
    // navigates the whole top frame into a cross-origin frame hoping it's the
    // player. When the guess is wrong (a chat/comment/social/ad widget like
    // st.chatango.com), we used to strand the user on a page with no relation
    // to the game. Instead we remember the last page that actually referenced
    // the target — a same-site source/game page or a token-bearing deep link
    // — and, if a drill produces no stream and the page it landed on has no
    // video/player, we navigate back there and skip that dead-end. This
    // generalizes past any one category: the test is "did it yield a stream
    // or at least look like a player," not "is this host a known chat widget."
    private var lastGoodPageURL: URL?
    private var drillWatchdog: Task<Void, Never>?
    /// Whether the most recent page_state the shim reported saw a <video>
    /// element. Lets a slow-but-real embed avoid being backtracked away.
    private var lastPageHasVideo = false

    // v2.63: navigation pinning. The streamer's own pages are the only
    // place we expect to legitimately land (the stream is an iframe on a
    // source-site game page). Page-initiated top-frame redirects/popups to
    // OTHER sites are ads/scams (therestgroup.com → awarnets.com). We pin
    // to `sourceHost`, allow cross-site loads only when WE initiate them
    // (iframe drill, host fallback) or the URL carries a team token, and
    // cancel everything else at the top frame.
    var sourceHost: String?
    var targetTokens: [String] = []
    /// v2.70: the league we're after, so the navigation layer can refuse a
    /// jump into a different sport. Source-site game pages routinely link (or
    /// redirect) to the currently-live featured game — e.g. an MLB page that
    /// bounces to the live WNBA game — and the shared-city token alone made
    /// that look acceptable. This is the chokepoint every navigation path
    /// (redirect, popup, link click) funnels through.
    var targetLeague: SportLeague?
    private var intendedLoadURLs = Set<String>()

    func noteIntendedLoad(_ url: URL) { intendedLoadURLs.insert(url.absoluteString) }

    private func registrableSuffix(_ host: String) -> String {
      let parts = host.lowercased().split(separator: ".")
      guard parts.count >= 2 else { return host.lowercased() }
      return parts.suffix(2).joined(separator: ".")
    }
    private func sameSite(_ a: String?, _ b: String?) -> Bool {
      guard let a, let b else { return false }
      return registrableSuffix(a) == registrableSuffix(b)
    }
    private func carriesTargetToken(_ url: URL) -> Bool {
      guard !targetTokens.isEmpty else { return false }
      let low = url.absoluteString.lowercased()
      return targetTokens.contains { low.contains($0) }
    }
    /// Should this top-frame destination be allowed? Same-site as the
    /// source (or the page we're currently on), a deep link carrying a
    /// team token, or a load we initiated ourselves.
    private func isAllowedTopNav(_ url: URL, current: URL?) -> Bool {
      if intendedLoadURLs.contains(url.absoluteString) { return true }
      // v2.70: a different sport/league is never our game — refuse it even
      // when it's same-site. This is what stops an MLB page's redirect to the
      // live WNBA game from being accepted just because it's on the same host.
      if urlLeagueConflicts(url) { return false }
      if sourceHost == nil { return true }  // not yet pinned
      if sameSite(url.host, sourceHost) { return true }
      if sameSite(url.host, current?.host) { return true }
      if carriesTargetToken(url) { return true }
      return false
    }

    /// v2.70: does this URL's path name a different sport/league than the
    /// target's? True only when the path names some other league's specific
    /// slug AND does not name ours. Skipped for soccer-family and `.other`
    /// targets, where generic routing makes the test unreliable.
    private func urlLeagueConflicts(_ url: URL) -> Bool {
      guard let target = targetLeague, target != .other, !target.isSoccerFamily else { return false }
      let path = url.path.lowercased()
      if target.urlSlugKeywords.contains(where: { Self.pathNamesLeague(path, $0) }) { return false }
      for league in SportLeague.allCases where league != target && league != .other {
        if league.urlSlugKeywords.contains(where: { Self.pathNamesLeague(path, $0) }) { return true }
      }
      return false
    }

    /// True iff `keyword` appears in `path` as a whole segment — bounded by a
    /// non-alphanumeric character (or the string edge) on both sides — so
    /// "nba" matches "/nba/…" but not "/wnba/…".
    private static func pathNamesLeague(_ path: String, _ keyword: String) -> Bool {
      guard !keyword.isEmpty else { return false }
      let chars = Array(path), k = Array(keyword)
      guard k.count <= chars.count else { return false }
      func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
      var i = 0
      while i + k.count <= chars.count {
        if Array(chars[i..<i + k.count]) == k {
          let beforeOK = i == 0 || !isWord(chars[i - 1])
          let afterOK = i + k.count == chars.count || !isWord(chars[i + k.count])
          if beforeOK && afterOK { return true }
        }
        i += 1
      }
      return false
    }

    init(onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?,
         onStreamProbed: ((URL, Bool, [HTTPCookie], URL?) -> Void)? = nil,
         onNavigation: ((URL) -> Void)? = nil,
         onWalkEvent: ((StreamWebView.WalkEvent) -> Void)? = nil,
         onLoadFailed: ((URL, String) -> Void)? = nil,
         onPageChanged: ((URL) -> Void)? = nil,
         browseMode: Bool) {
      self.onStreamURLFound = onStreamURLFound
      self.onStreamProbed = onStreamProbed
      self.onNavigation = onNavigation
      self.onWalkEvent = onWalkEvent
      self.onLoadFailed = onLoadFailed
      self.onPageChanged = onPageChanged
      self.browseMode = browseMode
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      switch message.name {
      case "streamIframe":
        // v2.37: JSON payload {url, score}. Coordinator decides
        // whether and when to navigate the top WebView into it.
        handleIframeCandidate(message.body)
      case "streamWalk":
        // v2.39: JSON payload {kind, info, time}. Coordinator forwards
        // to PlayerView for navStrip display.
        handleWalkEvent(message.body)
      case "streamURL":
        fallthrough
      default:
        guard let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }
        report(url)
      }
    }

    // v2.39/v2.40: parse + forward a walk event.
    private func handleWalkEvent(_ body: Any) {
      guard let s = body as? String,
            let data = s.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = json["kind"] as? String else { return }
      let info = (json["info"] as? String) ?? ""
      // v2.69: track whether the current page rendered a <video> so the
      // drill watchdog can spare a slow-but-real player from backtracking.
      // page_state info looks like "rs=… dom=N iframes=N vid=N playBtns=N".
      if kind == "page_state", let r = info.range(of: "vid=") {
        let digits = info[r.upperBound...].prefix { $0.isNumber }
        lastPageHasVideo = (Int(digits) ?? 0) > 0
      }
      var detected: [StreamWebView.DetectedCard] = []
      // v2.40: detected_cards events carry a payload array
      if kind == "detected_cards",
         let raw = json["payload"] as? [[String: Any]] {
        for entry in raw {
          guard let text = entry["text"] as? String, !text.isEmpty else { continue }
          let blob = (entry["blob"] as? String) ?? ""
          detected.append(StreamWebView.DetectedCard(text: text, blob: blob))
        }
      }
      let event = StreamWebView.WalkEvent(
        kind: kind, info: info, at: Date(), detectedCards: detected
      )
      DispatchQueue.main.async { self.onWalkEvent?(event) }
    }

    // v2.37: receive cross-origin iframe candidates. Collect for a
    // short window, then drill into the best (lowest-score) one by
    // navigating the top WebView there with parent as Referer.
    private func handleIframeCandidate(_ body: Any) {
      guard !found, iframeHops < Self.maxIframeHops else { return }
      guard let s = body as? String,
            let data = s.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlStr = json["url"] as? String,
            let url = URL(string: urlStr) else { return }
      // v2.41: skip auth/SSO iframes. v2.37's drill-down was navigating
      // INTO streameast's auth.streamea.st/sso-frame.php iframe and
      // abandoning the actual game listing on the parent page. An SSO
      // frame is never going to give us a stream.
      let host = (url.host ?? "").lowercased()
      let path = url.path.lowercased()
      let authHostPrefixes = ["auth.", "login.", "sso.", "accounts.", "id."]
      let authPathFragments = ["/sso", "/signin", "/sign-in", "/login",
                               "/log-in", "/auth", "/oauth"]
      if authHostPrefixes.contains(where: { host.hasPrefix($0) }) ||
         authPathFragments.contains(where: { path.contains($0) }) {
        return
      }
      let score = (json["score"] as? Int) ?? 500
      if visitedIframeURLs.contains(urlStr) { return }  // don't loop
      // Track best; if first candidate, schedule a commit after a
      // short window so we accumulate alternatives before deciding.
      if pendingBestIframe == nil || score < (pendingBestIframe?.score ?? Int.max) {
        pendingBestIframe = (url, score)
      }
      if iframeCommitTask == nil {
        iframeCommitTask = Task { [weak self] in
          try? await Task.sleep(nanoseconds: 750_000_000)
          await MainActor.run { self?.commitPendingIframe() }
        }
      }
    }

    private func commitPendingIframe() {
      defer { pendingBestIframe = nil; iframeCommitTask = nil }
      guard !found,
            iframeHops < Self.maxIframeHops,
            let pick = pendingBestIframe,
            let webView else { return }
      // Skip if we already navigated to this URL.
      if webView.url?.absoluteString == pick.url.absoluteString { return }
      iframeHops += 1
      visitedIframeURLs.insert(pick.url.absoluteString)
      var request = URLRequest(url: pick.url)
      request.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
      )
      if let parent = webView.url?.absoluteString {
        request.setValue(parent, forHTTPHeaderField: "Referer")
        // Many embed hosts gate on Origin too.
        if let scheme = webView.url?.scheme, let host = webView.url?.host {
          request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
        }
      }
      noteIntendedLoad(pick.url)  // cross-host embed drill is intentional
      lastPageHasVideo = false    // re-evaluated from the drilled page's state
      webView.load(request)
      startDrillWatchdog()
    }

    /// v2.69: arm the backtrack watchdog after a speculative drill. If the
    /// drilled page hasn't produced a stream — and doesn't even look like a
    /// player — by the deadline, we return to the last page that referenced
    /// the target. 6 s mirrors the firstObserved fallback: long enough for a
    /// real embed-host player to emit its manifest or render a <video>.
    private func startDrillWatchdog() {
      drillWatchdog?.cancel()
      drillWatchdog = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        await MainActor.run { self?.backtrackIfDrillFailed() }
      }
    }

    private func backtrackIfDrillFailed() {
      drillWatchdog = nil
      guard !found, let back = lastGoodPageURL, let webView else { return }
      // A real (if slow) player rendered a <video> — give it the benefit of
      // the doubt rather than abandoning a working embed.
      if lastPageHasVideo { return }
      // Already back on a page that references the target — nothing to undo.
      if let cur = webView.url,
         sameSite(cur.host, back.host) || carriesTargetToken(cur) { return }
      pendingBestIframe = nil
      iframeCommitTask?.cancel(); iframeCommitTask = nil
      noteIntendedLoad(back)
      let event = StreamWebView.WalkEvent(
        kind: "backtrack", info: back.absoluteString, at: Date(), detectedCards: []
      )
      DispatchQueue.main.async { self.onWalkEvent?(event) }
      webView.load(URLRequest(url: back))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      // v2.57: follow new-window / target="_blank" requests in the same
      // web view (many game cards' onclick is window.open(gameURL)).
      // v2.63: but ONLY when the destination stays on the source site or
      // carries a team token — a cross-site, token-less new window is an
      // ad/scam popup (buffstreams → therestgroup → awarnets), and loading
      // it would yank us off the game page. Drop those and stay put.
      if let url = navigationAction.request.url,
         isAllowedTopNav(url, current: webView.url) {
        noteIntendedLoad(url)
        webView.load(URLRequest(url: url))
      } else if let url = navigationAction.request.url {
        let event = StreamWebView.WalkEvent(
          kind: "popup_blocked", info: url.host ?? url.absoluteString,
          at: Date(), detectedCards: []
        )
        DispatchQueue.main.async { self.onWalkEvent?(event) }
      }
      return nil
    }

    // v2.63: auto-dismiss native JS dialogs. Scam ad frames spam
    // alert()/confirm()/prompt() ("(17) System notification") to coerce
    // taps; popupRedirectJS neutralizes the in-page ones, but anything
    // that still reaches WebKit's native panel we silently dismiss
    // (cancel/empty) so the user is never blocked or tricked.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
      completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
      completionHandler(false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
      completionHandler(nil)
    }

    // v2.38: fire onNavigation on every top-frame commit so the
    // breadcrumb in PlayerView reflects what we've navigated through
    // (initial load, iframe drill-down hops, redirects).
    // v2.41: additionally fire onPageChanged when the host or path
    // differs from the previous commit — used by PlayerView to reset
    // per-page state (detected cards, auth-wall flag, stale walk
    // events) so different pages' data don't overlap on one screen.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      guard let url = webView.url else { return }
      // v2.69: remember pages that reference the target so backtracking has
      // somewhere safe to return to. A same-site source/game page or a deep
      // link carrying a team token is "good"; speculative cross-site drills
      // (chat/ads/widgets) are not and never overwrite this.
      if (sameSite(url.host, sourceHost) || carriesTargetToken(url)),
         !urlLeagueConflicts(url) {
        lastGoodPageURL = url
      }
      DispatchQueue.main.async { self.onNavigation?(url) }
      let key = (url.host ?? "") + url.path
      if lastCommittedKey != key {
        lastCommittedKey = key
        DispatchQueue.main.async { self.onPageChanged?(url) }
      }
    }

    // v2.39: host-fallback retry when the WebView's provisional
    // navigation fails. Frame-load-interrupted (WebKitErrorDomain 102),
    // cancelled requests, and similar early-fail cases often mean the
    // host is unreachable (TLD seizure, sinkhole, etc.) and a sibling
    // domain (e.g. v2.streameast.gd, .net, .app) may be live. Reuses
    // the same HostFallback already powering WebViewScraper's listing-
    // time DNS-failure recovery.
    private var hostFallbackAttempted = false
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
      let nsErr = error as NSError
      guard !hostFallbackAttempted else {
        DispatchQueue.main.async {
          if let u = webView.url ?? URL(string: "about:blank") {
            self.onLoadFailed?(u, nsErr.localizedDescription)
          }
        }
        return
      }
      // Pull the URL from the failing request when available; the
      // userInfo NSErrorFailingURL key carries it even when webView.url
      // hasn't updated yet.
      let failingURL: URL? = (nsErr.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
                          ?? (nsErr.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
                          ?? webView.url
      guard let url = failingURL else {
        DispatchQueue.main.async {
          self.onLoadFailed?(URL(string: "about:blank")!, nsErr.localizedDescription)
        }
        return
      }
      hostFallbackAttempted = true
      Task { @MainActor in
        if let fallback = await HostFallback.shared.tryVariants(of: url) {
          var req = URLRequest(url: fallback)
          req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
          )
          // Persist replacement so subsequent attempts use it too.
          if let host = url.host {
            for src in SourceRegistry.shared.sources where src.baseURL.host == host {
              SourceRegistry.shared.replaceSourceURL(originalID: src.id, newURL: fallback)
              break
            }
          }
          self.sourceHost = fallback.host ?? self.sourceHost
          self.noteIntendedLoad(fallback)
          webView.load(req)
        } else {
          self.onLoadFailed?(url, nsErr.localizedDescription)
        }
      }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if let url = action.request.url {
        let u = url.absoluteString.lowercased()
        if u.contains(".m3u8") || u.contains(".mpd") {
          if !found { report(url) }
          decisionHandler(.cancel); return
        }
      }
      if !browseMode,
         action.navigationType == .linkActivated,
         let linkURL = action.request.url {
        // Cross-host link clicks are never followed in player mode.
        if linkURL.host != webView.url?.host {
          decisionHandler(.cancel); return
        }
        // v2.70: same-host link into a different league (an MLB page's link to
        // the live WNBA game) — refuse and stay put so we don't drift onto the
        // wrong game.
        if urlLeagueConflicts(linkURL) {
          let event = StreamWebView.WalkEvent(
            kind: "league_block", info: linkURL.path, at: Date(), detectedCards: []
          )
          DispatchQueue.main.async { self.onWalkEvent?(event) }
          decisionHandler(.cancel); return
        }
      }
      // v2.63: pin the top frame to the source site. Page-initiated
      // cross-site top-frame redirects (location.href, meta-refresh,
      // <a target=_top> ads) arrive here as .other/.redirect — these
      // are the popup/scam hijacks (therestgroup.com → awarnets.com).
      // popupRedirectJS only covers window.open; this catches the rest.
      // We never block self-initiated loads (intendedLoadURLs), same-site
      // hops, or token-bearing deep links.
      if !browseMode,
         let url = action.request.url,
         action.targetFrame?.isMainFrame == true,
         action.navigationType != .linkActivated,
         !isAllowedTopNav(url, current: webView.url) {
        let leagueConflict = urlLeagueConflicts(url)
        let event = StreamWebView.WalkEvent(
          kind: leagueConflict ? "league_block" : "popup_blocked",
          info: leagueConflict ? url.path : (url.host ?? url.absoluteString),
          at: Date(), detectedCards: []
        )
        DispatchQueue.main.async { self.onWalkEvent?(event) }
        decisionHandler(.cancel); return
      }
      decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
      let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
      let streamMimes = ["application/x-mpegurl", "application/vnd.apple.mpegurl",
                         "application/dash+xml", "video/mp2t"]
      let isStreamMime = streamMimes.contains(where: { mime.contains($0) })
      let url = navigationResponse.response.url
      let urlStr = url?.absoluteString.lowercased() ?? ""
      let isStreamURL = urlStr.contains(".m3u8") || urlStr.contains(".mpd")
      if (isStreamMime || (mime.contains("octet-stream") && isStreamURL)), let url {
        decisionHandler(.cancel)
        if !found { report(url) }
        return
      }
      decisionHandler(.allow)
    }

    private func report(_ url: URL) {
      guard !found else { return }
      let key = url.absoluteString
      guard seenURLs.insert(key).inserted else { return }
      if firstObservedURL == nil {
        firstObservedURL = url
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: 6_000_000_000)
          await MainActor.run { self?.commitFallbackIfNeeded() }
        }
      }
      // v2.48: capture referer + cookies up-front on the main thread,
      // hand them to probePlayability so the probe runs under the same
      // request conditions PlayerView's AVPlayer will use. Without this,
      // embed-host manifests that require Referer/cookies get falsely
      // rejected as unplayable, delaying playback to the 6 s fallback.
      let referer = webView?.url
      let cookieStore = webView?.configuration.websiteDataStore.httpCookieStore
      let onProbed = self.onStreamProbed
      Task { [weak self] in
        let cookies: [HTTPCookie] = await {
          guard let cookieStore else { return [] }
          return await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            DispatchQueue.main.async {
              cookieStore.getAllCookies { cont.resume(returning: $0) }
            }
          }
        }()
        let playable = await Self.probePlayability(url, referer: referer, cookies: cookies)
        await MainActor.run {
          onProbed?(url, playable, cookies, referer)
          guard let self, !self.found, playable else { return }
          self.commitURL(url)
        }
      }
    }

    private func commitFallbackIfNeeded() {
      guard !found, let url = firstObservedURL else { return }
      commitURL(url)
    }

    private func commitURL(_ url: URL) {
      found = true
      drillWatchdog?.cancel(); drillWatchdog = nil
      if let store = webView?.configuration.websiteDataStore.httpCookieStore {
        store.getAllCookies { cookies in
          DispatchQueue.main.async { self.onStreamURLFound?(url, cookies) }
        }
      } else {
        DispatchQueue.main.async { self.onStreamURLFound?(url, []) }
      }
    }

    private static func probePlayability(_ url: URL,
                                         referer: URL? = nil,
                                         cookies: [HTTPCookie] = []) async -> Bool {
      let lower = url.absoluteString.lowercased()
      let isManifest = lower.contains(".m3u8") || lower.contains(".mpd")
      guard isManifest else { return true }
      // v2.48: match the headers PlayerView.makePlayer sets on real
      // playback so the probe accurately predicts AVPlayer success.
      var headers = HTTPCookie.requestHeaderFields(with: cookies)
      headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
      if let referer {
        headers["Referer"] = referer.absoluteString
        headers["Origin"]  = (referer.scheme ?? "https") + "://" + (referer.host ?? "")
      }
      let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      return await withTaskGroup(of: Bool.self) { group in
        group.addTask { (try? await asset.load(.isPlayable)) ?? false }
        group.addTask {
          try? await Task.sleep(nanoseconds: 4_000_000_000)
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
      }
    }
  }
}

final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
  weak var delegate: WKScriptMessageHandler?
  init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    delegate?.userContentController(controller, didReceive: message)
  }
}
