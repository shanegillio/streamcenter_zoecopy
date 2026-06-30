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
  /// When true the player is hosted inside the home-screen TV box rather
  /// than pushed as a full-screen page: the nav toolbar is suppressed and
  /// AVPlayer plays inline instead of auto-entering full screen.
  var embedded: Bool = false
  @Environment(SourceRegistry.self) private var registry
  @State private var ruleList: WKContentRuleList? = nil
  @State private var avPlayer: AVPlayer? = nil
  @State private var rulesReady = false
  @State private var attempts: [SourceAttempt] = []
  @State private var currentAttemptIdx: Int = 0
  /// Per-attempt watchdog: if a source neither produces a playable stream nor
  /// trips an abort condition within `perSourceBudget`, it auto-advances to the
  /// next source (or surfaces the retry UI) so the loading screen can never hang
  /// forever. Cancelled the moment playback starts or the attempt changes.
  @State private var budgetTask: Task<Void, Never>? = nil
  /// When on, shows the live scraping WebView + diagnostics. When off
  /// (default), the user sees only a loading screen until playback starts.
  @AppStorage("debugScrapingView") private var debugScraping = false
  /// v2.64: true while we're reading the source site to find the exact
  /// game-page URL before loading it. Shows the loading overlay so the
  /// WebView never briefly loads (and walks) the homepage first.
  @State private var resolving = false
  @State private var allFailed: Bool = false
  /// Per-source budget. The walk + iframe drill-down get this long to reach a
  /// playable stream on slow sites (Cloudflare interstitials, lazy aggregators)
  /// before the attempt is abandoned. v2.57: this is now an enforced watchdog
  /// (`startBudgetTimer`) that auto-advances to the next source — previously it
  /// was advisory only, so a silently-stuck source could load forever.
  private static let perSourceBudget: TimeInterval = 30
  /// v2.38: WebView is visible by default in verification mode. Was
  /// previously gated on "Browse Manually" from the retry UI.
  @State private var showWebFallback = true
  /// Set when the probe explicitly rejects the first stream URL — the
  /// stream is playing inside the WebView's embedded player but AVPlayer
  /// can't fetch it (e.g. session-gated CDN). We lift the loading overlay
  /// so the WebView IS the player.
  @State private var webViewFallbackActivated = false
  /// v2.72: one-shot timer (per attempt) that reveals a play-button-gated embed
  /// for the user's real tap if nothing has started playing within the window.
  @State private var revealTask: Task<Void, Never>? = nil
  /// v2.74: guards one-time initialization. `.task` runs on appear and re-runs
  /// on every subsequent reappear; a transient disappear/reappear (e.g. a
  /// modal/full-screen presentation over the embedded player) would otherwise
  /// re-run `buildAttempts()` + `startCurrentAttempt()`, spawning a brand-new
  /// scrape/traversal session and reloading the WebView over a stream that's
  /// already playing. We only run the heavy init the first time this view
  /// instance appears; a true re-mount (new identity, e.g. a channel change via
  /// `.id(game.id)`) resets @State and initializes fresh as intended.
  @State private var didInitialize = false
  /// v2.74: true while AVKit is presenting this player full screen. Going full
  /// screen covers the underlying view, which fires `onDisappear`; without this
  /// flag that handler stopped the shared player (clearing its item), leaving a
  /// black full-screen player with a dead play button.
  @State private var isPlayerFullScreen = false

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
  /// v2.68: per-URL visit counts for the current source attempt. If the walk
  /// oscillates between the same pages (a redirect ping-pong), this lets us
  /// bail out instead of hanging. Reset on each new attempt.
  @State private var navVisitCounts: [String: Int] = [:]
  private static let maxRevisits = 4
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
  /// True when we already retried the current attempt from the source root
  /// after hitting an auth wall on a deep-link game URL. Prevents looping.
  @State private var authWallRootRetried: Bool = false
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
            // v2.72: the WebView the user can tap (reveal-on-arrival /
            // video_playing) — or the verification layout in Debug Mode.
            let interactive = debugScraping || webViewFallbackActivated
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
              // v2.72: keep the WebView in ONE stable tree position and toggle
              // interactivity + the cover overlay via state. Previously we
              // branch-swapped the WebView between an occluded layout (hit-
              // testing OFF) and a revealed one; SwiftUI carried the non-
              // interactive state across the swap, so the revealed player
              // couldn't be tapped. Now `interactive` flips true the moment we
              // reveal (play-button-gated embed) or detect the embed playing,
              // and the opaque loading cover is removed in the same pass.
              // v2.67: the WebView stays laid out at full opacity (not
              // `.opacity(0)`, which WebKit treats as not-visible and throttles)
              // even while occluded, so the embed player can initialize.
              ZStack {
                scrapeWebView(current)
                  .allowsHitTesting(interactive)
                if !interactive {
                  Color.black.ignoresSafeArea()
                  StreamLoadingOverlay(
                    attemptIndex: currentAttemptIdx,
                    totalAttempts: attempts.count,
                    sourceName: sourceName(for: current.sourceID)
                  )
                }
              }
            }
          } else {
            StreamLoadingOverlay(attemptIndex: 0, totalAttempts: 0, sourceName: "")
          }
        }
        if let avPlayer {
          VideoPlayerView(
            player: avPlayer,
            entersFullScreen: !embedded,
            onFullScreenChange: { isPlayerFullScreen = $0 }
          )
          .ignoresSafeArea()
        }
      } else {
        StreamLoadingOverlay(attemptIndex: 0, totalAttempts: 0, sourceName: "")
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !embedded {
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
    }
    .toolbarColorScheme(.dark, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
    .task {
      // v2.74: run heavy init exactly once per view instance. A transient
      // reappear (full-screen presentation over the embedded player) must not
      // restart the scrape — that was the "new resolved session on full screen"
      // bug. A real channel change re-mounts via `.id(game.id)`, resetting this.
      guard !didInitialize else { return }
      didInitialize = true
      // Configure the audio session so AVPlayer can AirPlay video (not just
      // audio) to an Apple TV, and start tracking the external route.
      AirPlayController.shared.configureAudioSession()
      // Claim the shared player for this channel so a previous channel's
      // late-finishing scrape can't load the wrong game over the top of ours.
      PlaybackEngine.shared.activate(game.id)
      // While casting, show the retro color-bars test pattern on the TV until
      // this channel's stream is found (the previous game would otherwise hang
      // on screen, or — worse — the TV would go blank).
      if AirPlayController.shared.isExternalActive {
        PlaybackEngine.shared.showFiller(for: game.id)
      }
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
      cancelBudgetTimer()
      revealTask?.cancel(); revealTask = nil
      if let sid = traversalSessionID {
        TraversalLog.shared.endSession(sid)
        traversalSessionID = nil
      }
      // When casting, leave the shared player running so the current game keeps
      // playing on the TV while the next channel's stream is scraped — the new
      // PlayerView will hot-swap the item in. When *not* casting, stop it so the
      // old channel's audio doesn't bleed into the next channel's loading screen.
      //
      // v2.74: but NOT while we're going full screen. AVKit's full-screen
      // presentation covers the underlying view, firing this onDisappear; the
      // player is still very much in use (it's the full-screen player), so
      // stopping it here clears the shared item and blacks out full screen.
      if !AirPlayController.shared.isExternalActive, !isPlayerFullScreen {
        PlaybackEngine.shared.stop()
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
      sourceID: current.sourceID,
      onStreamURLFound: { streamURL, cookies in
        Task { @MainActor in
          // v2.71: the captured stream's request context should reflect the
          // page that actually requested it (the embed we drilled into), not
          // the initial attempt URL — these CDNs gate the manifest AND segments
          // on Referer/Origin, so the referer must be the real embed page.
          let captureReferer = navigationHistory.last ?? current.pageURL
          appendCandidate(
            url: streamURL,
            cookies: cookies,
            referer: captureReferer
          )
          if let sid = traversalSessionID {
            TraversalLog.shared.recordStream(sid, url: streamURL)
          }
          // v2.47: auto-play return, gated on meaningful Hop ≥ 2.
          // We only auto-commit when navigation actually advanced past
          // the source's homepage — protects against committing a stream
          // URL that surfaced from an ad iframe before the user-targeted
          // nav happened. v2.71: also auto-commit at Hop 1 when the attempt
          // started from a DEEP link — discovery now sends us straight to an
          // embed/game URL (ppv.to → embedindia.st/embed/...), so the stream
          // surfaces on that first page and there's no homepage ad-iframe to
          // guard against. The Hop ≥ 2 rule stays for bare-homepage attempts.
          if avPlayer == nil, !webViewFallbackActivated {
            let hops = URLNormalization.meaningfulHopCount(
              navigationHistory.map { $0.absoluteString }
            )
            let p0 = current.pageURL.path
            let startedDeep = !(p0.isEmpty || p0 == "/")
            if hops >= 2 || startedDeep {
              autoPlayCapturedStream(
                url: streamURL,
                cookies: cookies,
                referer: captureReferer
              )
            }
          }
        }
      },
      onStreamProbed: { url, playable, live, cookies, referer in
        Task { @MainActor in
          if let sid = traversalSessionID {
            TraversalLog.shared.recordEvent(
              sid, kind: "stream_probed",
              info: "\(playable ? (live ? "live" : "ok-not-live") : "fail"): \(url.absoluteString)"
            )
          }
          // Normal mode has no visible strip to tap, so auto-commit the
          // first stream that probes playable. v2.67: play it directly from
          // the probe's own cookies/referer instead of looking it up in
          // `capturedStreams` — that list is populated later (via commitURL →
          // onStreamURLFound), so the lookup was always empty here and normal
          // mode could get stuck on the loading screen for flat sites
          // (crackstreams.ms) whose real stream surfaces before Hop 2.
          // v2.72: gate on `live` too — only auto-commit a verified LIVE stream,
          // never a filler/VOD/dead-endpoint capture that merely parsed.
          if !debugScraping, playable, live, avPlayer == nil, !webViewFallbackActivated {
            appendCandidate(url: url, cookies: cookies, referer: referer ?? current.pageURL)
            autoPlayCapturedStream(
              url: url, cookies: cookies, referer: referer ?? current.pageURL
            )
          }
        }
      },
      onProbeRejected: {
        Task { @MainActor in
          // The WebView's embedded player can serve this stream but
          // AVPlayer can't. Activate WebView-player mode so the user
          // sees the live video instead of a loading screen.
          cancelBudgetTimer()
          webViewFallbackActivated = true
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
      lastWalkEvent = event
      // If we loaded a deep-link game URL directly and hit an auth wall,
      // fall back to the source root and let the walk navigate there via
      // client-side routing (e.g. Vue Router). Client-side navigation
      // doesn't go through the server's auth check, so the game page may
      // be reachable without credentials this way. Only try once per attempt.
      if !authWallRootRetried,
         currentAttemptIdx < attempts.count {
        let url = attempts[currentAttemptIdx].pageURL
        if url.path != "/" && !url.path.isEmpty,
           let rootURL = URL(string: "/", relativeTo: url)?.absoluteURL {
          authWallRootRetried = true
          webBridge.webView?.load(URLRequest(url: rootURL))
          return
        }
      }
      authWallReason = event.info
      abortTerminal()
    case "dead_page":
      // v2.69: the page explicitly says the game/page is gone
      // (crackstreams.ms "…doesn't exist or the event has ended."). No point
      // re-scanning it; treat exactly like a dead end and move on.
      lastWalkEvent = event
      abortTerminal()
    case "rate_limited":
      // v2.71: Cloudflare error 1015 — the source is rate-limiting our IP
      // (aggravated by rapid re-tests / SSO popups). Surface it honestly and
      // stop; retrying immediately just deepens the block.
      lastWalkEvent = event
      loadFailure = "Source is rate-limiting (Cloudflare 1015) — wait a bit, then retry"
      abortTerminal()
    case "playback_dropped":
      // v2.73 (diagnostics): a <video> that had been playing stopped (pause/
      // ended/emptied/abort/stalled). Surface it so an on-device "goes black
      // after a few seconds" repro is explained by the log — without acting on
      // it (a buffering stall self-recovers; we must not reload/abort a player
      // that may resume).
      lastWalkEvent = event
      if let sid = traversalSessionID {
        TraversalLog.shared.recordEvent(sid, kind: "playback_dropped", info: event.info)
      }
    case "fullscreen":
      // v2.73 (diagnostics): correlate the "blacks out on fullscreen" symptom
      // with which element entered fullscreen and in which frame.
      lastWalkEvent = event
      if let sid = traversalSessionID {
        TraversalLog.shared.recordEvent(sid, kind: "fullscreen", info: event.info)
      }
    case "video_playing":
      // v2.72: the embed's own <video> is actually playing — the WebView IS the
      // working player. This is the primary success signal now (vs extracting a
      // URL). Reveal the player and stop the budget clock; no reload (it's
      // playing). AVPlayer stays opportunistic; WKWebView AirPlays natively.
      handleWebViewPlaybackStarted()
    case "page_state":
      lastWalkEvent = event
      // v2.72: a player iframe means we've arrived at the embed. If it doesn't
      // auto-start (play-button-gated — the playBtns=1 timeout class), reveal it
      // so the user's real tap can mint the token, instead of dying at the 30s
      // budget. Armed once per attempt.
      if event.info.contains("ifh=") || event.info.contains("playBtns=1") {
        armRevealOnArrival()
      }
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

  /// v2.69: a terminal page (auth wall, or an explicit "doesn't exist / event
  /// has ended" page) was detected. There's nothing to recover here, so stop
  /// the walk and move on. No-op once a stream is already playing or the
  /// WebView-player fallback is active — those mean we found something.
  private func abortTerminal() {
    guard avPlayer == nil, !webViewFallbackActivated else { return }
    handleDeadEnd()
  }

  /// v2.72: the embed's own <video> started playing — the WebView is the
  /// working player. Make it the visible player and record success; no AVPlayer
  /// required (WKWebView <video> AirPlays natively). No reload — it's playing.
  /// v2.62: stop the in-page walk once playback has started so it can't click a
  /// server-switcher / reload the player and kill the stream "after a few
  /// seconds." The embed subframe self-halts when it sees its own <video>; this
  /// sets the flag in the TOP frame (which can't see a cross-origin embed's
  /// video). `engagePlayerMode(reload:true)` later re-injects a fresh shim, so
  /// an AVPlayer-failure fallback still re-enables walking.
  private func haltWalk() {
    webBridge.webView?.evaluateJavaScript("window.__sc_stopWalk = true;", completionHandler: nil)
  }

  private func handleWebViewPlaybackStarted() {
    guard avPlayer == nil else { return }  // AVPlayer already owns playback
    cancelBudgetTimer()
    revealTask?.cancel(); revealTask = nil
    if !webViewFallbackActivated { webViewFallbackActivated = true }
    webBridge.coordinator?.engagePlayerMode(reload: false)
    haltWalk()
    noNavStrikes = 0
    if currentAttemptIdx < attempts.count {
      recordSuccess(attempt: attempts[currentAttemptIdx])
    }
    if let sid = traversalSessionID {
      TraversalLog.shared.markOutcome(sid, .worked)
    }
  }

  /// v2.72: once we've arrived at a player embed, arm a one-shot timer that
  /// reveals it for the user's REAL tap if nothing auto-starts within the
  /// window. This converts the play-button-gated `budget_timeout` cases (the
  /// embed mints the stream URL only on a trusted gesture) into a tappable
  /// player. Engages player mode WITHOUT reload so the tap's manifest loads.
  private func armRevealOnArrival() {
    guard revealTask == nil, avPlayer == nil, !webViewFallbackActivated else { return }
    revealTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 11_000_000_000)
      guard !Task.isCancelled, avPlayer == nil, !webViewFallbackActivated else { return }
      webBridge.coordinator?.engagePlayerMode(reload: false)
      webViewFallbackActivated = true
      cancelBudgetTimer()
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
      cancelBudgetTimer()
      PlaybackEngine.shared.stop()
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
    // v2.68: detect a navigation loop (e.g. sources.bintvs.fun ⇄ bintv.net/
    // ?cat=Baseball). Ignore the query so trivial param churn still counts as
    // the same page. If we keep landing back on the same URL, this source is
    // bouncing us in circles — give up and move on rather than hang.
    var key = url.absoluteString
    if let q = url.absoluteString.firstIndex(of: "?") { key = String(url.absoluteString[..<q]) }
    let count = (navVisitCounts[key] ?? 0) + 1
    navVisitCounts[key] = count
    if count >= Self.maxRevisits {
      if let sid = traversalSessionID {
        TraversalLog.shared.recordEvent(sid, kind: "nav_loop", info: key)
      }
      handleDeadEnd()
    }
  }

  private func playCandidate(_ cand: StreamCandidate) {
    guard let p = makePlayer(url: cand.url, cookies: cand.cookies, referer: cand.referer)
    else { return }  // stale channel — user surfed away
    cancelBudgetTimer()
    avPlayer = p
    p.play()
    haltWalk()  // v2.62: AVPlayer owns playback now — stop the WebView walk
    startAVPlayerWatchdog(p)
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
    guard let p = makePlayer(url: url, cookies: cookies, referer: referer)
    else { return }  // stale channel — user surfed away
    cancelBudgetTimer()
    avPlayer = p
    p.play()
    haltWalk()  // v2.62: AVPlayer owns playback now — stop the WebView walk
    startAVPlayerWatchdog(p)
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

  /// Watches AVPlayer health for the lifetime of the committed item — not just
  /// at startup. Two failure shapes both fall back to the WebView embed player
  /// (which plays these session-gated live streams the way a browser does):
  ///
  ///   1. Never-started (≤8 s): item failed, or still pinned at position 0.
  ///      The stream is session-gated and AVPlayer can't open it at all.
  ///   2. v2.74 — Started-then-stalled (the "plays 10–15 s then freezes" bug):
  ///      AVPlayer plays its initially-buffered window, then later segment /
  ///      manifest-reload requests fail (expiring tokens, or auth headers not
  ///      reliably applied to every sub-request), so playback freezes mid-stream
  ///      with no recovery. The old one-shot 8 s check had already returned
  ///      "worked" and nothing monitored afterward, so it stalled forever. We
  ///      now keep polling and, on a SUSTAINED no-progress stall (so a brief,
  ///      self-healing buffering hiccup doesn't trip it), hand off to the embed.
  private func startAVPlayerWatchdog(_ player: AVPlayer) {
    // The player is shared across channels, so identity can't tell us whether
    // this watchdog still owns the playback — compare the *item* it started on.
    // If a later channel already swapped in a new item, this watchdog is stale.
    let watchedItem = player.currentItem
    Task { @MainActor in
      // Phase 1: initial-start check. Position-0 stall / hard failure ⇒ the
      // stream never opened in AVPlayer; hand straight to the embed.
      try? await Task.sleep(nanoseconds: 8_000_000_000)
      guard avPlayer != nil, player.currentItem === watchedItem else { return }
      let item = player.currentItem
      let hasFailed  = item?.status == .failed || item?.error != nil
      let neverStarted = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                      && player.currentTime().seconds < 0.1
      if hasFailed || neverStarted {
        fallBackToEmbedPlayer(reason: hasFailed ? "item_failed" : "stalled_at_0")
        return
      }
      // Healthy start — record success once.
      if let sid = traversalSessionID {
        TraversalLog.shared.markOutcome(sid, .worked)
      }

      // Phase 2: continuous mid-playback stall monitor.
      let checkInterval: TimeInterval = 2
      let stallLimit: TimeInterval = 8   // sustained no-progress before handoff
      var lastTime = player.currentTime().seconds
      var stalledFor: TimeInterval = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        guard avPlayer != nil, player.currentItem === watchedItem else { return }
        let curItem = player.currentItem
        let now = player.currentTime().seconds
        if curItem?.status == .failed || curItem?.error != nil {
          fallBackToEmbedPlayer(reason: "item_failed_midstream@\(Int(now))s")
          return
        }
        // Count it as a stall only when the player WANTS to play but isn't making
        // progress — segment/manifest starvation, not a user pause.
        let wantsToPlay = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let progressed = now > lastTime + 0.05
        if wantsToPlay && !progressed {
          stalledFor += checkInterval
          if stalledFor >= stallLimit {
            fallBackToEmbedPlayer(reason: "stalled_midstream@\(Int(now))s")
            return
          }
        } else {
          stalledFor = 0
        }
        lastTime = now
      }
    }
  }

  /// Release the (dead/stalled) AVPlayer item and hand playback to the WebView
  /// embed player, which serves these gated streams the way a browser does.
  private func fallBackToEmbedPlayer(reason: String) {
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(sid, kind: "avplayer_fallback", info: reason)
    }
    // Release the item from the shared player so it doesn't keep buffering a
    // dead stream; the WebView becomes the player from here.
    PlaybackEngine.shared.stop()
    avPlayer = nil
    webViewFallbackActivated = true
    // v2.71: hand the stream to the embed's own player — stop cancelling its
    // manifest/segment loads and reload so it can fetch the gated stream the
    // browser (unlike AVPlayer) supplies the right Referer/Origin for.
    webBridge.coordinator?.engagePlayerMode()
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
    startBudgetTimer()
  }

  /// Arms the per-attempt watchdog for the current source. Cancels any prior
  /// timer first. In Debug Mode the user drives advancement manually, so we
  /// don't auto-advance there.
  private func startBudgetTimer() {
    budgetTask?.cancel()
    guard !debugScraping, currentAttemptIdx < attempts.count else { return }
    let attemptID = attempts[currentAttemptIdx].id
    budgetTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(Self.perSourceBudget * 1_000_000_000))
      guard !Task.isCancelled,
            avPlayer == nil, !webViewFallbackActivated, !allFailed,
            currentAttemptIdx < attempts.count,
            attempts[currentAttemptIdx].id == attemptID else { return }
      handleBudgetExpired()
    }
  }

  private func cancelBudgetTimer() {
    budgetTask?.cancel()
    budgetTask = nil
  }

  /// The current source ran out its budget without playing. Treat it like a
  /// dead end: mark it failed and move on, or surface retry if it was the last.
  private func handleBudgetExpired() {
    if let sid = traversalSessionID {
      TraversalLog.shared.recordEvent(
        sid, kind: "budget_timeout",
        info: "no playable stream within \(Int(Self.perSourceBudget))s"
      )
    }
    guard currentAttemptIdx < attempts.count else { return }
    attempts[currentAttemptIdx].status = .failed
    if currentAttemptIdx + 1 < attempts.count {
      advanceAttempt()
    } else {
      if let sid = traversalSessionID {
        TraversalLog.shared.endSession(sid)
        traversalSessionID = nil
      }
      PlaybackEngine.shared.stop()
      allFailed = true
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
    navVisitCounts = [:]
    lastWalkEvent = nil
    loadFailure = nil
    detectedCards = []
    authWallReason = nil
    authWallRootRetried = false
    noNavStrikes = 0
    webViewFallbackActivated = false
    revealTask?.cancel(); revealTask = nil  // v2.72: re-arm reveal for the new source
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
    ZStack {
      // "Lost signal" TV static behind the error slate. The slate is kept
      // small (just the error line + Try Again) so the static reads clearly
      // around it rather than being covered by a large panel.
      TVStaticView()
      VStack(spacing: 10) {
        Text("Error: could not load stream")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          // v2.38: just rebuild attempts and let verification mode
          // re-load the first attempt's page from scratch.
          buildAttempts()
          capturedStreams = []
          navigationHistory = []
          navVisitCounts = [:]
          lastWalkEvent = nil
          loadFailure = nil
          detectedCards = []
          authWallReason = nil
          authWallRootRetried = false
          noNavStrikes = 0
          webViewFallbackActivated = false
          allFailed = false
          if !attempts.isEmpty {
            SourceHealth.shared.recordAttempt(
              sourceID: attempts[currentAttemptIdx].sourceID
            )
            Task { await startCurrentAttempt() }
          }
        } label: {
          Label("Try Again", systemImage: "arrow.clockwise")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white.opacity(0.18), in: Capsule())
            .foregroundStyle(.white)
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
      .padding(.horizontal, 24)
    }
  }

  private func makePlayer(url: URL, cookies: [HTTPCookie], referer: URL) -> AVPlayer? {
    var headers = HTTPCookie.requestHeaderFields(with: cookies)
    headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    headers["Referer"] = referer.absoluteString
    headers["Origin"]  = (referer.scheme ?? "https") + "://" + (referer.host ?? "")
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    // Reuse the one long-lived player so switching channels swaps the item
    // in place instead of tearing down the player (which would drop AirPlay).
    // Returns nil when this channel is no longer active — a stale scrape that
    // finished after the user surfed away must not hijack the screen.
    let item = AVPlayerItem(asset: asset)
    guard PlaybackEngine.shared.load(item, for: game.id) else { return nil }
    return PlaybackEngine.shared.player
  }
}

// MARK: - Loading overlay (single mode, replaces v2.29's StreamSearchingOverlay)

private struct StreamLoadingOverlay: View {
  let attemptIndex: Int
  let totalAttempts: Int
  let sourceName: String

  var body: some View {
    ZStack {
      TVColorBarsView()
      // Black broadcast band with the loading label, like a channel slate.
      VStack(spacing: 3) {
        Text("Loading…")
          .font(.system(size: 22, weight: .bold))
          .foregroundStyle(.white)
        if totalAttempts > 0 {
          Text(totalAttempts > 1
               ? "\(sourceName) (\(attemptIndex + 1) of \(totalAttempts))"
               : sourceName)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(Color.black.opacity(0.88))
    }
  }
}

// MARK: - AVKit wrapper

struct VideoPlayerView: UIViewControllerRepresentable {
  let player: AVPlayer
  /// Embedded TV playback stays inline; full-screen pushes go full screen.
  var entersFullScreen: Bool = true
  /// v2.74: reports when AVKit's own full-screen presentation begins/ends.
  /// PlayerView uses this so its `onDisappear` (which fires because the
  /// full-screen modal covers the underlying view) does NOT stop the shared
  /// player while we're merely going full screen — that teardown is what left a
  /// dead, black full-screen player with a non-working play button.
  var onFullScreenChange: (Bool) -> Void = { _ in }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let vc = AVPlayerViewController()
    vc.player = player
    vc.showsPlaybackControls = true
    vc.videoGravity = .resizeAspect
    vc.entersFullScreenWhenPlaybackBegins = entersFullScreen
    vc.exitsFullScreenWhenPlaybackEnds = entersFullScreen
    vc.delegate = context.coordinator
    return vc
  }
  func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
    // Only reassign when the player instance actually changed. SwiftUI calls
    // this on every body update (walk/scan events, timers fire several times a
    // second during playback); reassigning `vc.player` — even to the same
    // object — interrupts an in-progress fullscreen presentation and blacks it
    // out. This guard is the fix for "fullscreen goes black on every source."
    if vc.player !== player { vc.player = player }
  }

  func makeCoordinator() -> Coordinator { Coordinator(onFullScreenChange: onFullScreenChange) }

  // NOTE: We deliberately do NOT force a scene rotation when the player enters
  // full screen. AVPlayerViewController rotates its own full-screen presentation
  // natively (the app supports all orientations), exactly like the in-WebView
  // player's full-screen button — which works perfectly. Forcing the scene to
  // landscape via `requestGeometryUpdate` flipped the host's verticalSizeClass
  // to `.compact`, which transiently tore down / reappeared the embedding
  // PlayerView. Letting AVKit own the rotation leaves the SwiftUI tree
  // undisturbed.
  //
  // The delegate exists ONLY to observe the full-screen transition (no
  // rotation), so PlayerView can avoid stopping the shared player while
  // full screen.
  final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
    let onFullScreenChange: (Bool) -> Void
    init(onFullScreenChange: @escaping (Bool) -> Void) {
      self.onFullScreenChange = onFullScreenChange
    }
    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
      onFullScreenChange(true)
    }
    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
      // Cleared after the transition completes so an onDisappear that fires
      // during the dismissal animation is still treated as "full screen".
      coordinator.animate(alongsideTransition: nil) { [weak self] _ in
        self?.onFullScreenChange(false)
      }
    }
  }
}

// MARK: - WebKit stream view with m3u8 interception

/// v2.40: thin bridge so PlayerView can drive the underlying WKWebView
/// (e.g. dispatch a click via evaluateJavaScript when the user taps a
/// detected card). Holds the WKWebView weakly so the proxy doesn't
/// extend its lifetime.
final class StreamWebViewBridge: ObservableObject {
  weak var webView: WKWebView?
  /// v2.71: lets PlayerView's AVPlayer watchdog tell the coordinator to hand
  /// playback to the in-WebView player when a committed stream fails/stalls.
  weak var coordinator: StreamWebView.Coordinator?

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
    // v2.68: collapse interior whitespace to single spaces BEFORE escaping.
    // Category labels arrive as multi-line text ("WNBA Streams\nClick to view
    // all games"); a raw newline inside the single-quoted JS string literal
    // below is a syntax error that silently aborts the whole click — which is
    // exactly why the WNBA-streams card was identified but never followed.
    let normalized = pair
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let escaped = normalized
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
      // Team tokens from the pair we're following, used to validate
      // cross-origin deep links (real game URLs carry the slug). Must be
      // built AFTER `t` is assigned — referencing it earlier hit the
      // hoisted-but-undefined `t` and threw, aborting the whole click.
      var toks = [];
      t.replace(/\\bvs\\b|@|—|–/g, ' ').split(/\\s+/).forEach(function(w){
        if (w.length >= 4) toks.push(w);
      });
      // A homepage card link is only worth following if it stays on the
      // same site (the site's own watch/game page) OR it's a cross-origin
      // URL that carries a team token (a genuine deep link). Cross-origin,
      // token-less links are betting/affiliate ads (playonrain → rainbet)
      // that derail the walk into a casino. Reject those.
      function baseName(host){
        var p = ('' + host).toLowerCase().split('.');
        return p.length >= 2 ? p[p.length - 2] : (p[0] || '');
      }
      function navHrefOK(href){
        if (!href) return false;
        var u; try { u = new URL(href, location.href); } catch(e){ return true; }
        if (u.host === location.host) return true;
        // v2.68: a sibling mirror domain (same brand base) is the site's
        // own listing/game page — follow it, don't treat it as an ad.
        var hbase = baseName(location.host);
        if (hbase.length >= 5 && hbase === baseName(u.host)) return true;
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
        return navHrefOK(h);
      }
      // Pull a navigable URL from common attributes on a single element.
      function hrefAttr(el){
        if (!el || !el.getAttribute) return '';
        var keys = ['href','data-href','data-url','data-link'];
        for (var i = 0; i < keys.length; i++){
          var v = el.getAttribute(keys[i]);
          if (usableHref(v)) return v;
        }
        return '';
      }
      // v2.68: does this href carry a team token (i.e. it's the actual game
      // deep link, not a generic nav link)?
      function hrefHasToken(h){
        if (!h) return false;
        var low = ('' + h).toLowerCase();
        for (var i = 0; i < toks.length; i++){ if (low.indexOf(toks[i]) !== -1) return true; }
        return false;
      }
      // Best usable href in a subtree. v2.68: prefer one carrying a team
      // token (the real game deep link, e.g. /watch/kobra/los-angeles-sparks-
      // vs-portland-fire-2469363) over a generic same-site link (the "kobra
      // server" selector → /matches/kobra). Returning the first usable anchor
      // is what sent us to the server-list page instead of the game.
      function bestHrefIn(scope){
        try {
          var as = scope.querySelectorAll && scope.querySelectorAll(
            'a[href],[data-href],[data-url],[data-link]');
          if (as){
            var fallback = '';
            for (var i = 0; i < as.length; i++){
              var h = hrefAttr(as[i]); if (!h) continue;
              if (hrefHasToken(h)) return h;
              if (!fallback) fallback = h;
            }
            return fallback;
          }
        } catch(e){}
        return '';
      }
      // Self → climb ancestors, searching each subtree (catches sibling
      // "Watch" links inside the same card container). v2.68: a first pass
      // prefers a team-token deep link anywhere in scope before falling back
      // to the first usable href.
      function findNavHref(el){
        if (!el) return '';
        var n = el, lvl = 0;
        while (n && lvl < 6){
          var ht = hrefAttr(n); if (ht && hrefHasToken(ht)) return ht;
          var hst = bestHrefIn(n); if (hst && hrefHasToken(hst)) return hst;
          n = n.parentElement; lvl++;
        }
        var h0 = hrefAttr(el); if (h0) return h0;
        n = el; lvl = 0;
        while (n && lvl < 6){
          var ha = hrefAttr(n); if (ha) return ha;
          var hs = bestHrefIn(n); if (hs) return hs;
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
      // v2.68: is the label a game pair ("X vs Y") rather than a category
      // ("WNBA Streams")? For a game we must NOT force-navigate to a link
      // that doesn't carry the team slug.
      var isPair = /(^|\\s)vs(\\s|$)|@|—|–/.test(t);
      // v2.69: does the element's text identify the target? The exact
      // contiguous phrase ("france vs iraq") is the strongest signal, but a
      // source frequently lists the same game in the OTHER order ("Iraq vs
      // France") or with a different separator ("France - Iraq", "France @
      // Iraq"). Our canonical pair string then never appears verbatim, so the
      // in-page walk identifies the card (it matches teams as independent
      // tokens) yet this click executor couldn't re-find it — the
      // CLICKED-BUT-NO-NAV / no-match dead-end. For a pair, fall back to an
      // order-independent match requiring every team token to be present.
      // The length cap keeps the order-independent path scoped to a single
      // game card: a card's text is short ("Iraq vs France 0-0 8' LIVE"),
      // whereas a multi-game container would collect both tokens from
      // different cards and match falsely.
      function labelMatches(b){
        if (b.indexOf(t) !== -1) return true;
        if (isPair && toks.length >= 2 && b.length <= 160){
          for (var k = 0; k < toks.length; k++){
            if (b.indexOf(toks[k]) === -1) return false;
          }
          return true;
        }
        return false;
      }
      var sel = 'a[href],button,[onclick],[data-match],[data-event],[data-game],' +
                '[role="button"],[class*="card" i],[class*="match" i],[class*="game" i]';
      var els = document.querySelectorAll(sel);
      var firstMatch = null;
      for (var i = 0; i < els.length && i < 2000; i++) {
        var e = els[i];
        var b = ((e.innerText || e.textContent || '') + ' ' +
                 (e.getAttribute && (e.getAttribute('aria-label') || '')) + ' ' +
                 (e.getAttribute && (e.getAttribute('title') || '')))
                .replace(/\\s+/g, ' ').toLowerCase();
        if (!labelMatches(b)) continue;
        if (!firstMatch) firstMatch = e;
        // Prefer a real destination URL. v2.68: but for a game card, only
        // FOLLOW a link that carries the team slug (the real /watch/<server>/
        // <home-vs-away> URL). Forcing location.href to the first generic
        // same-site link — a "kobra server" tile → /matches/kobra — hijacks
        // the page before the card's own onclick can route to the game, and
        // strands us on a server-list page. A non-pair (category) follow may
        // use any same-site link.
        var href = findNavHref(e);
        if (href && (!isPair || hrefHasToken(href))) {
          var abs = href;
          try { abs = new URL(href, location.href).href; } catch(err){}
          if (abs && abs.split('#')[0] !== location.href.split('#')[0]) {
            report('nav→ ' + abs);
            try { location.href = abs; return true; } catch(err){}
          }
        }
      }
      // No team-token deep link found. Click the matched card and let the
      // site's own handler route to the game, rather than jumping to a
      // generic link. Skip an <a> whose href is an off-site ad.
      if (firstMatch) {
        var target = findClickableAncestor(firstMatch);
        if (target && target.tagName === 'A') {
          var rawHref = target.getAttribute('href');
          if (rawHref && !navHrefOK(rawHref)) {
            report('skip-ad ' + ('' + rawHref).slice(0,60));
            return false;
          }
        }
        // v2.68: dump the card's structure so a JS-routed card (no <a href>
        // for the game) shows us how it encodes the link instead of leaving
        // us guessing after a silent CLICKED-BUT-NO-NAV.
        try {
          var parts = ['tag=' + (target && target.tagName)];
          if (target && target.className) parts.push('cls=' + ('' + target.className).slice(0, 50));
          ['onclick','data-href','data-url','data-link','data-slug','data-id'].forEach(function(k){
            var dv = target && target.getAttribute && target.getAttribute(k);
            if (dv) parts.push(k + '=' + ('' + dv).slice(0, 50));
          });
          var inner = target && target.querySelectorAll && target.querySelectorAll('a[href]');
          if (inner && inner.length) {
            var hh = [];
            for (var z = 0; z < inner.length && z < 4; z++) hh.push((inner[z].getAttribute('href') || '').slice(0, 40));
            parts.push('a=' + hh.join('|'));
          }
          report('click ' + parts.join(' '));
        } catch(e){ report('click ' + (target && target.tagName ? target.tagName : '?') + ' no-token-href'); }
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
  /// v2.71: the source this attempt belongs to, so the coordinator can apply
  /// (and the app can learn) this source's real-stream host "style".
  var sourceID: String = ""
  var onStreamURLFound: ((URL, [HTTPCookie]) -> Void)? = nil
  /// v2.48: fires for every captured stream URL after AVPlayer's
  /// isPlayable probe finishes, regardless of outcome. PlayerView
  /// records this in the TraversalLog so probe failures are visible
  /// in Settings → Traversal Log during iterative testing.
  /// v2.67: carries the cookies + referer used for the probe so normal mode
  /// can auto-commit a playable stream directly, without waiting for the
  /// candidate to land in `capturedStreams`.
  var onStreamProbed: ((URL, Bool, Bool, [HTTPCookie], URL?) -> Void)? = nil
  /// Fired when the probe explicitly rejects the first-seen stream URL
  /// (probe returns false). PlayerView uses this to switch to WebView-
  /// player mode instead of waiting for the 6 s fallback to commit a
  /// URL that AVPlayer can't play (e.g. session-gated CDN streams).
  var onProbeRejected: (() -> Void)? = nil
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
      onProbeRejected: onProbeRejected,
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
    // v2.71: embed players (buffstreams) use the JS Fullscreen API
    // (element.requestFullscreen()), which WKWebView gates behind this
    // preference — it defaults to false, so the full-screen button blacked
    // out. Enabling it lets WebKit present the player full screen.
    config.preferences.isElementFullscreenEnabled = true
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
    // v2.71: embed players live in nested iframes; when one lacks
    // `allowfullscreen`/`allow="fullscreen"`, tapping the video's full-screen
    // button blacks out in WKWebView (buffstreams symptom). Grant fullscreen to
    // every iframe and re-apply as the DOM mutates. Runs in sub-frames too.
    config.userContentController.addUserScript(WKUserScript(
      source: Self.iframeFullscreenJS,
      injectionTime: .atDocumentEnd, forMainFrameOnly: false
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
    // v2.71: snapshot this source's learned real-stream host "style" so the
    // coordinator can reject hosts confirmed wrong and prefer hosts that played.
    context.coordinator.sourceID = sourceID
    context.coordinator.knownGoodDomains = StreamHostMemory.shared.goodDomains(for: sourceID)
    let mt = Self.matchTokens(for: targetGame)
    context.coordinator.targetLongTokens = mt.long
    context.coordinator.targetAbbrTokens = mt.abbr
    // v2.40: expose the WebView to the bridge so PlayerView can
    // dispatch evaluateJavaScript commands (detected-card taps).
    bridge?.webView = webView
    // v2.71: expose the coordinator so the AVPlayer watchdog can engage
    // WebView-player mode for gated streams AVPlayer can't play.
    bridge?.coordinator = context.coordinator

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
        // v2.68: same host OR a sibling mirror domain sharing the brand
        // base (crackstreams.ms ↔ crackstreams.ws) is the site's own page.
        var hb = location.host.toLowerCase().split('.');
        var ub = u.host.toLowerCase().split('.');
        var hbase = hb.length >= 2 ? hb[hb.length - 2] : (hb[0] || '');
        var ubase = ub.length >= 2 ? ub[ub.length - 2] : (ub[0] || '');
        if (u.host === location.host || (hbase.length >= 5 && hbase === ubase)) ok = true;
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
  /// v2.71: grant fullscreen to every iframe so a nested embed player's
  /// full-screen button works instead of blacking out (buffstreams).
  static let iframeFullscreenJS = """
    (function(){
      function grant(){
        try {
          var f = document.querySelectorAll('iframe');
          for (var i = 0; i < f.length; i++) {
            try {
              f[i].setAttribute('allowfullscreen', '');
              f[i].setAttribute('webkitallowfullscreen', '');
              var a = f[i].getAttribute('allow') || '';
              if (a.indexOf('fullscreen') === -1) f[i].setAttribute('allow', a ? (a + '; fullscreen') : 'fullscreen');
            } catch(e){}
          }
        } catch(e){}
      }
      grant();
      try { new MutationObserver(grant).observe(document.documentElement || document, { childList: true, subtree: true }); } catch(e){}
    })();
    """

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

  /// v2.71: tokens used to judge whether a captured stream URL has anything in
  /// common with the game the user tapped. `long` (≥4 char team words +
  /// nicknames) match as substrings; `abbr` (2–3 char codes like "ger"/"par")
  /// match only as bounded slug segments so they can't false-positive inside an
  /// unrelated URL. A stream URL carrying one of these is almost certainly the
  /// right game's; one carrying NONE (ppv.to's `netanyahu…/index.m3u8`) is
  /// suspect and shouldn't be committed eagerly over a token-bearing capture.
  static func matchTokens(for game: Game?) -> (long: [String], abbr: [String]) {
    guard let g = game else { return ([], []) }
    var long = Set<String>(), abbr = Set<String>()
    for name in [teamSlug(g.homeTeam), teamSlug(g.awayTeam)] {
      for w in name.split(separator: "-") where w.count >= 4 { long.insert(String(w).lowercased()) }
    }
    for team in [g.homeTeam, g.awayTeam] {
      let t = TeamAliasIndex.shared.tokens(forTeam: team)
      for x in t.long { long.insert(x.lowercased()) }
      for x in t.abbr where x.count >= 2 { abbr.insert(x.lowercased()) }
    }
    return (Array(long), Array(abbr))
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
        // A real manifest extension is conclusive regardless of path.
        if (l.indexOf('.m3u8') !== -1) return true;
        if (l.indexOf('.mpd')  !== -1) return true;
        // v2.68: the weak path words below (/live/, /stream/, …) also appear
        // in JSON/data endpoints — bintv.net's homepage calls streamed.pk/api/
        // matches/live/popular-viewcount, which we mis-captured and autoplayed
        // as the stream. Reject anything that looks like an API/data/asset
        // request before applying the weak path heuristics.
        if (/\\/api\\/|\\/ajax\\/|viewcount|\\.(?:json|js|css|png|jpe?g|gif|svg|webp|woff2?|ico|txt|xml)$/.test(l)) {
          return false;
        }
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

      function _iframePriorityScore(el) {
        // Lower = more eager. Heuristic order matches the plan.
        var hostMatch = 9999;
        try {
          var host = (new URL(el.src || el.getAttribute('src') || '', location.href)).host.toLowerCase();
          for (var i = 0; i < _knownEmbedHosts.length; i++) {
            if (host.indexOf(_knownEmbedHosts[i]) !== -1) { hostMatch = 100; break; }
          }
        } catch(e){}
        var ancestorBoost = 9999;
        var anc = el.parentElement;
        for (var lvl = 0; lvl < 4 && anc; lvl++) {
          var sig = ((anc.className || '') + ' ' + (anc.id || '')).toLowerCase();
          if (/player|video|stream|embed|frame/.test(sig)) { ancestorBoost = 50; break; }
          anc = anc.parentElement;
        }
        // Larger iframes are more likely to be the actual player.
        var sizePenalty = 9999;
        var w = parseInt(el.getAttribute('width') || el.clientWidth || 0, 10) || 0;
        var h = parseInt(el.getAttribute('height') || el.clientHeight || 0, 10) || 0;
        if (w * h > 0) sizePenalty = Math.max(0, 1000 - (w * h));
        return Math.min(hostMatch, ancestorBoost, sizePenalty, 500);
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
        _seenIframes[resolved] = 1;
        var score = el ? _iframePriorityScore(el) : 500;
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
      var _routedNavedTo = '';
      var _lastTargetPostedAt = 0;
      var _lastSlugDbgAt = 0;
      var _slugNavedURLs = [];

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
            if (_sideHit(pl, 'home') && _sideHit(pl, 'away')) {
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
        // Diagnostic (debug-mode only): surface what the slug-href scanner saw
        // this pass — anchor count, home/away hits, whether it matched, and a
        // sample — so a "found the game but never opened it" failure is visible.
        if (now2 - _lastSlugDbgAt > 1500) {
          _lastSlugDbgAt = now2;
          postWalkEvent('scan', 'SLUG a=' + _slugScanStats.anchors +
            ' nH=' + _slugScanStats.nHome + ' nA=' + _slugScanStats.nAway +
            ' m=' + _slugScanStats.matched + ' s="' + _slugScanStats.sample + '"');
        }
        // v2.70: an anchor carrying BOTH team names in its URL is the single
        // most reliable "this is the game" signal. Jump to it directly via
        // location.href — a guaranteed real navigation — instead of routing it
        // through the synthetic-click path. The click path was gated by
        // per-element "already clicked" / click-budget bookkeeping, so when the
        // matched card and the slug anchor were the same element (already
        // clicked once with no nav), the guaranteed deep-link jump never fired
        // and we looped on CLICKED-BUT-NO-NAV. A loop guard (_slugNavedURLs)
        // and the self-URL skip in findTargetByHrefSlug keep this from
        // ping-ponging.
        var _slugJumped = false;
        if (slugAnchor) {
          var _sHref = '';
          try { _sHref = slugAnchor.getAttribute('href') || ''; } catch(e){}
          // v2.71: navigate to the EFFECTIVE href — a …/auth/login?to=/live/…
          // wrapper becomes its inner game URL, so the slug jump lands on the
          // game page instead of the login wall.
          var _sEff = _effectiveHref(_sHref);
          var _sAbs = _sEff;
          try { _sAbs = new URL(_sEff, location.href).href; } catch(e){}
          if (_sAbs && _sAbs.split('#')[0] !== location.href.split('#')[0] &&
              _slugNavedURLs.indexOf(_sAbs) === -1 && _navHrefOK(_sHref)) {
            _slugNavedURLs.push(_sAbs);
            postWalkEvent('slug', 'nav→ ' + _sAbs);
            try { location.href = _sAbs; _slugJumped = true; } catch(e){}
          }
        }
        if (_slugJumped) {
          // navigation in flight — stop processing this pass
        } else if (slugAnchor && _walkClicks < _maxWalkClicks &&
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
        // v2.71: don't judge a page mid-render — an SPA whose game cards
        // haven't painted yet looks empty/auth-ish. Wait for load to settle
        // (mirrors detectDeadPage) so a browsable SPA is never killed early.
        if (document.readyState !== 'complete') return;
        // v2.71: a /auth/login?to=/live/… wrapper is transitional, not a wall —
        // the walk unwraps it and navigates to the inner game URL, so don't
        // flag it terminal.
        if (_isAuthURL(location.href) && _unwrapAuthRedirect(location.href)) return;
        var title = (document.title || '').toLowerCase();
        var titleHints = ['sign in', 'log in', 'login', 'authentication required', 'access denied'];
        // v2.71: host/path-based auth detection (pathname only, via _isAuthURL)
        // so a benign ?redirect=/login or ?to=/live in the QUERY can't trip it —
        // that loose substring match was flagging browsable pages as login walls.
        var hostMatch = _isAuthURL(location.href);
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

      // v2.69: detect terminal "this game/page is gone" pages so the walk
      // can abort fast instead of re-scanning a dead page until the budget
      // expires (crackstreams.ms returns "the page you're looking for
      // doesn't exist or the event has ended."). Mirrors detectAuthWall:
      // main frame only, fire once per page, gate on document.readyState
      // complete (so a mid-load empty body never trips it), and require a
      // SMALL DOM so the phrase appearing in a footer/FAQ of a real content
      // page can never be mistaken for a dead page.
      var _deadPageReported = false;
      function detectDeadPage() {
        if (window.top !== window) return;
        if (_deadPageReported) return;
        if (document.readyState !== 'complete') return;
        var domSize = 0;
        try { domSize = document.querySelectorAll('*').length; } catch(e){}
        if (domSize > 800) return;
        var body = '';
        try { body = (document.body && (document.body.innerText || document.body.textContent) || ''); } catch(e){}
        body = body.toLowerCase().replace(/[‘’]/g, "'");
        if (!body) return;
        // v2.71: Cloudflare rate-limit (error 1015 "you are being rate
        // limited") — we hammered the host (rapid re-tests / SSO popups).
        // Report it distinctly so it reads as "back off & retry," not a dead
        // page or a missing stream.
        var rlPhrases = ["you are being rate limited", "error 1015"];
        for (var r = 0; r < rlPhrases.length; r++) {
          if (body.indexOf(rlPhrases[r]) !== -1) {
            _deadPageReported = true;
            postWalkEvent('rate_limited', rlPhrases[r]);
            return;
          }
        }
        var phrases = [
          "page you're looking for doesn't exist",
          "page you are looking for doesn't exist",
          "the event has ended",
          "event has ended",
          "stream has ended",
          "page not found",
          "404 not found",
          "no longer available"
        ];
        for (var i = 0; i < phrases.length; i++) {
          if (body.indexOf(phrases[i]) !== -1) {
            _deadPageReported = true;
            postWalkEvent('dead_page', phrases[i]);
            return;
          }
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
      // v2.71: auth/login URL detection + redirect-target unwrapping. Mirrors
      // Swift's URLClassifier. A login wrapper like
      // ppv.to/auth/login?to=/live/mlb/2026-06-27/sea-cle (or StreamEast's
      // auth.streamea.st/sso-frame.php?redirect=%2Fmlb%2F<slug>) carries the
      // game slug INSIDE a redirect param; without unwrapping, the team-token
      // matchers saw both teams in the href and navigated into the auth wall.
      var _AUTH_HOST_PREFIXES = ['auth.','login.','signin.','sso.','accounts.','id.'];
      var _AUTH_PATH_FRAGS = ['/sso','/signin','/sign-in','/login','/log-in','/auth','/oauth'];
      var _REDIRECT_PARAMS = ['to','redirect','redirect_uri','redirect_url','return','return_to','returnurl','next','url','continue','dest','destination','r'];
      function _isAuthURL(urlStr) {
        if (!urlStr) return false;
        var u;
        try { u = new URL(urlStr, location.href); }
        catch(e){
          var low = ('' + urlStr).toLowerCase();
          for (var i = 0; i < _AUTH_PATH_FRAGS.length; i++) if (low.indexOf(_AUTH_PATH_FRAGS[i]) !== -1) return true;
          return false;
        }
        var host = u.host.toLowerCase(), path = u.pathname.toLowerCase();
        for (var j = 0; j < _AUTH_HOST_PREFIXES.length; j++) if (host.indexOf(_AUTH_HOST_PREFIXES[j]) === 0) return true;
        for (var k = 0; k < _AUTH_PATH_FRAGS.length; k++) if (path.indexOf(_AUTH_PATH_FRAGS[k]) !== -1) return true;
        return false;
      }
      // If urlStr is an auth URL with a redirect param pointing at a non-auth
      // target, return that decoded inner URL (absolute). Else ''.
      function _unwrapAuthRedirect(urlStr) {
        var u;
        try { u = new URL(urlStr, location.href); } catch(e){ return ''; }
        if (!_isAuthURL(u.href)) return '';
        for (var i = 0; i < _REDIRECT_PARAMS.length; i++) {
          var v = null;
          try { v = u.searchParams.get(_REDIRECT_PARAMS[i]); } catch(e){}
          if (!v) continue;
          var inner;
          try { inner = new URL(v, location.href).href; } catch(e){ continue; }
          if (inner && !_isAuthURL(inner)) return inner;
        }
        return '';
      }
      // v2.72: a redirect-gateway wrapper carries the real game URL in a
      // redirect param — StreamEast's connect.php?redirect=%2Fmlb%2F<game>,
      // sso-frame.php?redirect=…, login?to=… . The GATEWAY is never the
      // destination (navigating into it hits Cloudflare 1015 / "Access denied"
      // and looks like a paywall); the inner value is. Return that inner ONLY
      // when it carries BOTH team tokens — so this is host/path-agnostic (any
      // gateway filename) yet can't unwrap a legit deep link that merely has an
      // unrelated url=/r= param. Token-aware, unlike _unwrapAuthRedirect.
      function _redirectInner(urlStr) {
        var u;
        try { u = new URL(urlStr, location.href); } catch(e){ return ''; }
        for (var i = 0; i < _REDIRECT_PARAMS.length; i++) {
          var v = null;
          try { v = u.searchParams.get(_REDIRECT_PARAMS[i]); } catch(e){}
          if (!v) continue;
          var inner;
          try { inner = new URL(v, location.href).href; } catch(e){ continue; }
          if (inner && !_isAuthURL(inner) && _sideHit(inner, 'home') && _sideHit(inner, 'away')) return inner;
        }
        return '';
      }
      // The URL we'd actually navigate to for this href: a redirect-gateway or
      // auth wrapper is unwrapped to its inner game URL; everything else
      // returned unchanged.
      function _effectiveHref(href) {
        var inner = '';
        try { inner = _redirectInner(href); } catch(e){}
        if (inner) return inner;
        try { inner = _unwrapAuthRedirect(href); } catch(e){}
        return inner || href;
      }
      // The string to run team-token tests against. A redirect-gateway wrapper
      // resolves to its inner game URL (slug in the PATH). For an auth URL: the
      // inner redirect target or '' for a bare auth URL — so tokens hidden in a
      // login URL's query never count. For a normal URL: the full href unchanged
      // (preserves sites that legitimately carry the slug in a query, e.g.
      // sources.bintvs.fun/?match=chicago-cubs-vs-...).
      function _hrefForTokenTest(href) {
        try {
          var gw = _redirectInner(href);
          if (gw) return gw.toLowerCase();
          var u = new URL(href, location.href);
          if (_isAuthURL(u.href)) {
            var inner = _unwrapAuthRedirect(u.href);
            return inner ? inner.toLowerCase() : '';
          }
          return u.href.toLowerCase();
        } catch(e) {
          return _isAuthURL(href) ? '' : ('' + href).toLowerCase();
        }
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
      // v2.68: brand-base of a host ("crackstreams.ms"/"crackstreams.ws" →
      // "crackstreams"). Lets us recognize a site's own sibling mirror
      // domains as same-site instead of mistaking the hop for an ad.
      function _baseName(host) {
        var p = ('' + host).toLowerCase().split('.');
        return p.length >= 2 ? p[p.length - 2] : (p[0] || '');
      }
      function _sameBrand(a, b) {
        if (a === b) return true;
        var ba = _baseName(a);
        return ba.length >= 5 && ba === _baseName(b);
      }
      // v2.63: a card href is only worth following if it stays on the same
      // site (the site's own watch/game page) OR is a cross-origin URL
      // carrying a team token (a genuine deep link). Cross-origin token-less
      // hrefs are betting/affiliate ads (ntv.cx cards wrap a playonrain →
      // rainbet link) that send the walk into a casino dead-end. Reject them.
      // v2.68: a sibling mirror domain (same brand base) is the site's own
      // listing, not an ad — follow it so the category/game hop lands.
      function _navHrefOK(href) {
        if (!href) return false;
        var u; try { u = new URL(href, location.href); } catch(e){ return true; }
        // v2.71: an auth/login URL is never a valid nav target on its own. If it
        // wraps a redirect to a real game path we'll have unwrapped it at the
        // navigation site; a bare auth URL is rejected here so a same-site
        // /auth/login can't slip through the _sameBrand gate below.
        if (_isAuthURL(u.href) && !_unwrapAuthRedirect(u.href)) return false;
        if (_sameBrand(u.host, location.host)) return true;
        var low = _hrefForTokenTest(href), toks = _hrefTokens();
        for (var i = 0; i < toks.length; i++){ if (low && low.indexOf(toks[i]) !== -1) return true; }
        // v2.65: also accept cross-origin deep links routed by team
        // abbreviation (e.g. embedindia.st/embed/mlb/.../wsh-ari) — require
        // BOTH sides so a lone 2-char abbr in an ad URL can't sneak through.
        if (low && _hasAnyToks('home') && _hasAnyToks('away') &&
            _sideHit(low, 'home') && _sideHit(low, 'away')) return true;
        return false;
      }
      // v2.68: an href that carries BOTH teams is the real game deep link
      // (e.g. /watch/kobra/los-angeles-sparks-vs-portland-fire-…), not a
      // generic same-site nav link (a "kobra server" tile → /matches/kobra).
      function _hrefHasTeamToken(h) {
        if (!h) return false;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return false;
        var low = _hrefForTokenTest(h);  // v2.71: auth wrappers → inner game URL / ''
        return !!low && _sideHit(low, 'home') && _sideHit(low, 'away');
      }
      // v2.68: best usable href in a subtree — prefer a team-token deep link
      // over the first generic same-site anchor.
      function _firstUsableAnchorHref(scope) {
        try {
          var as = scope.querySelectorAll && scope.querySelectorAll('a[href]');
          if (as) {
            var fallback = '';
            for (var i = 0; i < as.length; i++) {
              var h = as[i].getAttribute('href');
              if (!_usableHref(h) || !_navHrefOK(h)) continue;
              if (_hrefHasTeamToken(h)) return h;
              if (!fallback) fallback = h;
            }
            return fallback;
          }
        } catch(e){}
        return '';
      }
      // v2.58: search the matched element, then climb its ancestors and at
      // EACH level search that ancestor's whole subtree for a usable <a>.
      // This catches the common card layout where the "X vs Y" text and the
      // real "Watch" link are SIBLINGS inside a card container (the old
      // version only saw self / descendant / direct-ancestor anchors and so
      // returned '' → CLICKED-BUT-NO-NAV).
      // v2.68: a first pass prefers a team-token deep link anywhere in scope
      // before falling back to the first usable href, so a card's "server"
      // selector links don't win over the actual game URL.
      function _findNavHref(el) {
        if (!el) return '';
        var n = el, lvl = 0;
        while (n && lvl < 6) {
          if (n.tagName === 'A') { var ht = n.getAttribute('href'); if (_usableHref(ht) && _navHrefOK(ht) && _hrefHasTeamToken(ht)) return ht; }
          var hst = _firstUsableAnchorHref(n);
          if (hst && _hrefHasTeamToken(hst)) return hst;
          n = n.parentElement; lvl++;
        }
        try { if (el.tagName === 'A') { var h0 = el.getAttribute('href'); if (_usableHref(h0) && _navHrefOK(h0)) return h0; } } catch(e){}
        n = el; lvl = 0;
        while (n && lvl < 6) {
          if (n.tagName === 'A') { var h2 = n.getAttribute('href'); if (_usableHref(h2) && _navHrefOK(h2)) return h2; }
          var h3 = _firstUsableAnchorHref(n);
          if (h3) return h3;
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
          parts.push('onclick=' + (node.hasAttribute && node.hasAttribute('onclick') ? 'Y' : 'N'));
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
      // Returns 'nav' when it forced a real URL change, else 'click'.
      // v2.68: for a game click (every kind except 'category_click') only
      // force-navigate to a link carrying the team slug. A game card's
      // nearest generic link is often a "server" tile (/matches/kobra) that
      // hijacks the page off the game; if there's no slug link we click the
      // card and let the site route to /watch/<server>/<slug> itself.
      function clickOrNavigate(node, kind, label) {
        var href = _findNavHref(node);
        if (href && (kind === 'category_click' || _hrefHasTeamToken(href))) {
          var abs = _effectiveHref(href);  // v2.71: unwrap auth wrappers to the game URL
          try { abs = new URL(abs, location.href).href; } catch(e){}
          if (abs && abs.split('#')[0] !== location.href.split('#')[0]) {
            postWalkEvent(kind, 'nav→ ' + abs);
            try { location.href = abs; return 'nav'; } catch(e){}
          }
        }
        postWalkEvent(kind, label);
        try { robustClick(node); } catch(e){ postWalkEvent('click_failed', String(e)); }
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
        // Strip diacritics (preserving case so the capital-letter game-line
        // regex still fires): "Türkiye"→"Turkiye", "Atlético"→"Atletico". The
        // `_gameLinePattern` token class is ascii-only ([A-Z][\\w…]), so an
        // accented name would never parse as a team and the card would be
        // dropped before matching ran.
        try { out = out.normalize('NFD').replace(/[\\u0300-\\u036f]/g, ''); } catch(e){}
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
      // Lowercase AND strip diacritics so on-page text like "Türkiye",
      // "Atlético", or "São Paulo" matches the ascii-folded target tokens the
      // Swift side ships ("turkiye", "atletico", "sao paulo"). Without this the
      // text matchers silently miss every accented team name.
      function _fold(s) {
        s = '' + s;
        try { s = s.normalize('NFD').replace(/[\\u0300-\\u036f]/g, ''); } catch(e){}
        return s.toLowerCase();
      }
      // Does `blob` (already lowercased or not) mention this side's team?
      function _sideHit(blob, side) {
        var low = _fold(blob);
        var longs = _longToks(side);
        for (var i = 0; i < longs.length; i++) if (low.indexOf(longs[i]) !== -1) return true;
        var abbrs = _abbrToks(side);
        for (var j = 0; j < abbrs.length; j++) if (_boundedHit(low, abbrs[j])) return true;
        return false;
      }
      function _hasAnyToks(side) {
        return _longToks(side).length > 0 || _abbrToks(side).length > 0;
      }

      var _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };

      function selectTargetGameElement() {
        _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };
        if (!window.__sc_target) return null;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return null;
        function bothPresent(text) {
          return _sideHit(text, 'home') && _sideHit(text, 'away');
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
          if (hh && aa) {
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
      var _slugScanStats = { anchors: 0, matched: 0, href: '', nHome: 0, nAway: 0, sample: '' };
      function findTargetByHrefSlug() {
        _slugScanStats = { anchors: 0, matched: 0, href: '', nHome: 0, nAway: 0, sample: '' };
        if (!window.__sc_target) return null;
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return null;
        var as;
        try { as = document.querySelectorAll('a[href]'); } catch(e) { return null; }
        _slugScanStats.anchors = as.length;
        var best = null, bestScore = 0;
        var _curNoHash = location.href.split('#')[0];
        var cap = Math.min(as.length, 2000);
        for (var i = 0; i < cap; i++) {
          var href = '';
          try { href = as[i].getAttribute('href') || ''; } catch(e){}
          if (!_usableHref(href)) continue;
          // Skip anchors that resolve to the page we're already on. On a game
          // page that's an interstitial of "Watch on X" links, the self-link
          // carries both team slugs too — picking it would no-op the nav and
          // strand us here instead of following a real next-hop (the embed).
          var _abs = href;
          try { _abs = new URL(href, location.href).href; } catch(e){}
          if (_abs.split('#')[0] === _curNoHash) continue;
          // v2.71: test tokens against the EFFECTIVE href — an auth wrapper
          // resolves to its inner game URL (slug in the path), and a bare auth
          // URL yields '' so a login link's redirect param can't score as a hit.
          var low = _hrefForTokenTest(href);
          if (!low) continue;
          // v2.65: match home + away via long tokens (substring) or
          // abbreviations (bounded). Score prefers abbreviation hits since a
          // URL carrying both team abbreviations is an unambiguous deep link.
          var hh = _sideHit(low, 'home'), aa = _sideHit(low, 'away');
          if (hh) _slugScanStats.nHome++;
          if (aa) _slugScanStats.nAway++;
          // Capture a sample of an anchor that hit at least one side, so the
          // diagnostic can show what the slug scanner is actually seeing.
          if ((hh || aa) && !_slugScanStats.sample) {
            _slugScanStats.sample = (hh ? 'H' : '') + (aa ? 'A' : '') + ':' + low.slice(0, 70);
          }
          if (hh && aa) {
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

      // v2.68: ntv.cx-style SPA cards route via JS, so the real game URL
      // (/watch/kobra/chicago-cubs-vs-san-francisco-giants-2469363) is NOT a
      // plain <a href> — the slug-anchor scan finds nothing and we end up
      // clicking a DIV that never navigates (CLICKED-BUT-NO-NAV → dead end).
      // This harvests any URL/path carrying BOTH team slugs out of element
      // attributes (href / data-* / onclick) AND the raw page HTML, so we can
      // navigate straight to the game even when it's only referenced in JS.
      var _routedScanStats = { source: '', url: '' };
      function _extractTargetURLFrom(text) {
        if (!text) return '';
        // Match on the ORIGINAL text (case-insensitive) so the returned URL
        // keeps its real casing — _sideHit lowercases internally for the test.
        var matches = ('' + text).match(/(https?:\\/\\/[^\\s"'`()<>]+|\\/[a-z0-9][a-z0-9._~\\/-]+)/gi);
        if (!matches) return '';
        var curr = location.href.split('#')[0].toLowerCase();
        for (var k = 0; k < matches.length; k++) {
          var cand = matches[k];
          // v2.71: unwrap a login wrapper (…/auth/login?to=/live/…/sea-cle) to
          // its inner game URL, and never return a bare auth URL — team tokens
          // in a redirect param must not pass as the game deep link.
          var eff = _effectiveHref(cand);
          if (_isAuthURL(eff)) continue;
          if (!(_sideHit(eff, 'home') && _sideHit(eff, 'away'))) continue;
          // v2.68: skip a self-referential match. The current page URL itself
          // carries both team slugs (sources.bintvs.fun/?match=chicago-cubs-
          // vs-san-francisco-giants); returning it would just no-op the nav
          // (same URL) and stall — keep scanning for the NEXT hop (the embed).
          var abs = eff;
          try { abs = new URL(eff, location.href).href.split('#')[0].toLowerCase(); } catch(e){}
          if (abs === curr) continue;
          return eff;
        }
        return '';
      }
      function findRoutedGameURL() {
        _routedScanStats = { source: '', url: '' };
        if (!window.__sc_target) return '';
        if (!_hasAnyToks('home') || !_hasAnyToks('away')) return '';
        var els;
        try { els = document.querySelectorAll('[href],[data-href],[data-url],[data-link],[data-slug],[onclick]'); }
        catch(e){ els = []; }
        var attrs = ['href','data-href','data-url','data-link','data-slug','onclick'];
        var cap = Math.min(els.length, 3000);
        for (var i = 0; i < cap; i++) {
          for (var j = 0; j < attrs.length; j++) {
            var v = els[i].getAttribute && els[i].getAttribute(attrs[j]);
            var hit = _extractTargetURLFrom(v);
            if (hit) { _routedScanStats = { source: attrs[j], url: hit }; return hit; }
          }
        }
        // Last resort: scan the serialized HTML (catches slugs only present
        // in inline JSON / script state used to build the route).
        try {
          var hit2 = _extractTargetURLFrom(document.body && document.body.innerHTML);
          if (hit2) { _routedScanStats = { source: 'html', url: hit2 }; return hit2; }
        } catch(e){}
        return '';
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
          if (_sideHit(pair, 'home') && _sideHit(pair, 'away')) {
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
        // v2.68: no slug anchor — try to recover a JS-routed game URL from
        // attributes/HTML and navigate to it directly. This is what reaches
        // ntv.cx's /watch/<server>/<home-vs-away> page (its cards have no
        // <a href> for the game, so clicking the DIV went nowhere).
        var routed = '';
        try { routed = findRoutedGameURL(); } catch(e){}
        if (routed && _walkClicks < _maxWalkClicks) {
          var rabs = routed;
          try { rabs = new URL(routed, location.href).href; } catch(e){}
          // v2.68: navigate ONCE per URL. Re-issuing location.href every scan
          // tick interrupts the in-flight load ("frame load interrupted"),
          // which never commits and trips host-fallback into switching/
          // disabling the source.
          if (rabs && rabs !== _routedNavedTo &&
              rabs.split('#')[0] !== location.href.split('#')[0]) {
            _routedNavedTo = rabs;
            _walkClicks++;
            postWalkEvent('routed', '(' + _routedScanStats.source + ') nav→ ' + rabs);
            try { location.href = rabs; return; } catch(e){}
          }
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
        // v2.68: but NOT when the current page URL already carries both team
        // names. That means we've already followed a game-specific link (e.g.
        // sources.bintvs.fun/?match=chicago-cubs-vs-san-francisco-giants) and
        // its stream options just haven't rendered yet — jumping to a league
        // category here navigates BACKWARDS (…/?cat=Baseball), which then
        // routes forward again into an endless ping-pong loop.
        var _here = location.href.toLowerCase();
        var _onGamePage = _hasAnyToks('home') && _hasAnyToks('away') &&
                          _sideHit(_here, 'home') && _sideHit(_here, 'away');
        if (_walkClicks === 0 && !_onGamePage &&
            window.__sc_target && window.__sc_target.league) {
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

      // v2.72: the truest success signal — the embed's OWN <video> is actually
      // playing. Runs in every frame (incl. the cross-origin embed), so when the
      // real player starts (auto, or after a real tap), its frame reports it.
      // This is what lets us treat the WebView as the player instead of needing
      // to extract a URL — immune to signed/expiring/gated tokens because the
      // real browser already did the work. Re-arms if it pauses.
      var _videoPlayingReported = false;
      // v2.62: once a real video is playing, the walk must STOP poking the page.
      // Continuing to run tryAdvance + the mirror/source/"watch" click loop on a
      // PLAYING page hits a server-switcher or reloads the player a few seconds
      // in — which is exactly why playback "stops after a few seconds" in-app but
      // never in a plain browser (a browser doesn't click anything). Sticky: a
      // buffering pause must not un-halt and resume the clicking.
      var _walkHalted = false;
      function _isWalkHalted() { return _walkHalted || window.__sc_stopWalk === true; }
      function _vIsPlaying(v) {
        return !v.paused && !v.ended && v.readyState >= 3 &&
               v.currentTime > 0.3 && (v.videoWidth || 0) > 0;
      }
      // v2.73 (diagnostics): wire each <video> for *event-driven* playback
      // detection (faster halt than the scan timer) and report when a video
      // that WAS playing drops out — so an on-device black-out tells us whether
      // the embed paused/emptied itself vs. something we did. Idempotent per el.
      function wireVideos() {
        var vs = document.querySelectorAll('video');
        for (var i = 0; i < vs.length; i++) {
          var v = vs[i];
          if (v.__sc_wired) continue;
          v.__sc_wired = true;
          ['playing', 'timeupdate', 'loadeddata'].forEach(function(ev) {
            v.addEventListener(ev, function(){ try { reportVideoPlayback(); } catch(e){} }, { passive: true });
          });
          ['pause', 'ended', 'emptied', 'abort', 'stalled'].forEach(function(ev) {
            v.addEventListener(ev, function(){
              if (v.__sc_wasPlaying) {
                postWalkEvent('playback_dropped', ev + ' rs=' + v.readyState +
                              ' ct=' + (v.currentTime | 0) + ' host=' + (location.host || ''));
                if (ev === 'ended' || ev === 'emptied' || ev === 'abort') v.__sc_wasPlaying = false;
              }
            }, { passive: true });
          });
        }
      }
      // v2.73 (diagnostics): report fullscreen transitions so we can correlate
      // the "blacks out on fullscreen" symptom with what element went FS. Once
      // per frame.
      function hookFullscreen() {
        if (window.__sc_fsHooked) return;
        window.__sc_fsHooked = true;
        function onFS() {
          try {
            var el = document.fullscreenElement || document.webkitFullscreenElement;
            postWalkEvent('fullscreen', (el ? ('enter ' + (el.tagName || '').toLowerCase()) : 'exit') +
                          ' main=' + (window.top === window ? '1' : '0') + ' host=' + (location.host || ''));
          } catch(e){}
        }
        document.addEventListener('fullscreenchange', onFS, { passive: true });
        document.addEventListener('webkitfullscreenchange', onFS, { passive: true });
      }
      function reportVideoPlayback() {
        var playing = false;
        try {
          var vs = document.querySelectorAll('video');
          for (var i = 0; i < vs.length; i++) {
            var v = vs[i];
            if (_vIsPlaying(v)) { playing = true; v.__sc_wasPlaying = true; break; }
          }
        } catch(e){}
        if (playing) _walkHalted = true;
        if (playing && !_videoPlayingReported) {
          _videoPlayingReported = true;
          postWalkEvent('video_playing', location.host || '');
        } else if (!playing) {
          _videoPlayingReported = false;
        }
      }

      function scan() {
        document.querySelectorAll('video, source').forEach(function(el) {
          [el.src, el.currentSrc, el.getAttribute('src'), el.dataset && el.dataset.src].forEach(function(s) {
            if (s) report(s);
          });
        });
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });
        try { wireVideos(); } catch(e){}
        try { hookFullscreen(); } catch(e){}
        try { reportVideoPlayback(); } catch(e){}
        // v2.72: subframes (the many ad iframes these pages spawn) do ONLY the
        // cheap capture/playback essentials above. Everything below — inline-
        // script regex scans, cross-origin iframe harvest, full-DOM card
        // matching, play-button sweeps, and a getComputedStyle-over-every-
        // element overlay hide — is heavy and main-frame-only. Running it per
        // ad iframe was accumulating into the whole-app main-thread freeze.
        // (Network intercepts + video/playback detection above still run in
        // every frame, so the embed subframe is still captured and observed.)
        if (window.top !== window) return;
        // v2.62: stream is playing (this frame saw its own <video>, or native
        // set window.__sc_stopWalk after a video_playing/commit elsewhere) —
        // stop ALL walking/clicking/navigation so we don't disrupt playback.
        // Passive capture + reportVideoPlayback above still run.
        if (_isWalkHalted()) return;
        scanScripts();
        // v2.37: harvest cross-origin iframes for drill-down.
        try { harvestIframes(); } catch(e){}
        try { probePageState(); } catch(e){}

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
        try { detectDeadPage(); } catch(e){}

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
            // v2.72: full pointer-event sequence, not a bare .click() — lazy
            // players that mint the stream URL only on a real press respond to
            // the gesture-shaped sequence more often (still synthetic, so a
            // strict isTrusted check needs the user's real tap, which the
            // reveal-on-arrival path provides).
            if (!el._sc_clicked) { el._sc_clicked = 1; try { robustClick(el); } catch(e){} }
          }, i * 2500);
        });

        try {
          // v2.72: narrowed from querySelectorAll('*'). getComputedStyle on
          // every element forces a synchronous style/layout flush per node — the
          // single biggest freeze contributor when run each scan. Limit to block
          // containers (where pop-over ad overlays live) and cap the count.
          var _ov = document.querySelectorAll('div,ins,aside,section');
          var _ovCap = Math.min(_ov.length, 400);
          for (var _i = 0; _i < _ovCap; _i++) {
            var _el = _ov[_i];
            var _s = window.getComputedStyle(_el);
            var _z = parseInt(_s.zIndex) || 0;
            if ((_s.position === 'fixed' || _s.position === 'absolute') && _z > 999) {
              _el.style.display = 'none';
            }
          }
        } catch(e){}
      }

      // v2.72: coalesce mutation storms. Live players and ad animations fire
      // DOM mutations many times/sec, in every frame; running the heavy scan()
      // synchronously per mutation flooded the main thread (via streamWalk
      // messages → @State churn + TraversalLog appends) and hung the WHOLE app
      // UI intermittently. Debounce to ≤1 scan / 600 ms, and drop attribute
      // observation — childList+subtree still catches new streams/iframes/cards;
      // attribute ticks (progress bars, timers) only cause churn.
      var _scanScheduled = false;
      function scheduleScan() {
        if (_scanScheduled) return;
        _scanScheduled = true;
        setTimeout(function() { _scanScheduled = false; try { scan(); } catch(e){} }, 600);
      }
      new MutationObserver(function(mutations) {
        scheduleScan();
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
      }).observe(document.documentElement || document, {childList: true, subtree: true});

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
    let onStreamProbed: ((URL, Bool, Bool, [HTTPCookie], URL?) -> Void)?
    let onProbeRejected: (() -> Void)?
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
    /// v2.72: URLs that passed live-stream verification — the only ones we'll
    /// ever commit, including via the 6 s fallback path.
    private var verifiedLiveURLs = Set<String>()
    // When the probe explicitly rejects the first-observed URL (returns
    // false), block the 6 s fallback commit — the stream isn't playable
    // in AVPlayer, and the WebView is already showing it.
    private var probeRejectedFirstURL = false
    /// v2.71: once AVPlayer has proven it can't play a captured stream (the
    /// probe rejected it, or PlayerView's watchdog saw it fail/stall), the
    /// embed's own in-WebView player takes over. We then stop cancelling the
    /// embed's manifest/segment loads (so its player can fetch the gated
    /// stream the browser handles the headers for) and reload once so a player
    /// whose manifest we already cancelled gets a clean start.
    var playerModeEngaged = false
    func engagePlayerMode(reload: Bool = true) {
      if playerModeEngaged { return }
      playerModeEngaged = true
      // v2.72: reload only when we're recovering from an AVPlayer failure (the
      // embed's manifest may have been cancelled). When the page is already
      // showing/playing (reveal-on-arrival, video_playing), DON'T reload —
      // that would restart a working player.
      if reload { DispatchQueue.main.async { [weak self] in self?.webView?.reload() } }
    }
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

    // v2.63: navigation pinning. The streamer's own pages are the only
    // place we expect to legitimately land (the stream is an iframe on a
    // source-site game page). Page-initiated top-frame redirects/popups to
    // OTHER sites are ads/scams (therestgroup.com → awarnets.com). We pin
    // to `sourceHost`, allow cross-site loads only when WE initiate them
    // (iframe drill, host fallback) or the URL carries a team token, and
    // cancel everything else at the top frame.
    var sourceHost: String?
    var targetTokens: [String] = []
    /// v2.71: this source's learned real-stream host "style" (registrable
    /// domains). Snapshot from StreamHostMemory at WebView creation.
    var sourceID: String = ""
    var knownGoodDomains: Set<String> = []
    /// v2.71: target-game tokens for judging stream-URL relatedness (see
    /// StreamWebView.matchTokens). A captured manifest carrying one of these is
    /// trusted as the right game's; one carrying none is held back.
    var targetLongTokens: [String] = []
    var targetAbbrTokens: [String] = []
    /// Does this stream URL carry any token of the game the user tapped?
    func streamCarriesToken(_ url: URL) -> Bool {
      let s = url.absoluteString.lowercased()
      for t in targetLongTokens where !t.isEmpty && s.contains(t) { return true }
      for a in targetAbbrTokens where boundedHit(s, a) { return true }
      return false
    }
    private func boundedHit(_ hay: String, _ needle: String) -> Bool {
      guard needle.count >= 2 else { return false }
      func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
      var from = hay.startIndex
      while let r = hay.range(of: needle, range: from..<hay.endIndex) {
        let beforeOK = r.lowerBound == hay.startIndex || !isWord(hay[hay.index(before: r.lowerBound)])
        let afterOK = r.upperBound == hay.endIndex || !isWord(hay[r.upperBound])
        if beforeOK && afterOK { return true }
        from = r.upperBound
      }
      return false
    }
    /// A playable manifest from an UNKNOWN host, held back briefly in case a
    /// known-good capture lands first (only when the source HAS known-good
    /// hosts). Committed by `deferTask` if nothing better arrives.
    private var deferredCandidate: URL?
    private var deferTask: Task<Void, Never>?
    private func registrableDomain(_ host: String?) -> String? {
      guard let host = host?.lowercased(), !host.isEmpty else { return nil }
      let parts = host.split(separator: ".")
      guard parts.count >= 2 else { return host }
      return parts.suffix(2).joined(separator: ".")
    }
    private func isKnownGoodHost(_ host: String?) -> Bool {
      guard let d = registrableDomain(host) else { return false }
      return knownGoodDomains.contains(d)
    }
    private func deferUnknownCandidate(_ url: URL) {
      if deferredCandidate == nil { deferredCandidate = url }
      guard deferTask == nil else { return }
      deferTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await MainActor.run {
          guard let self, !self.found, let u = self.deferredCandidate else { return }
          self.commitURL(u)
        }
      }
    }
    private var intendedLoadURLs = Set<String>()
    /// v2.71: short-lived auxiliary WebViews hosting an SSO popup (e.g.
    /// StreamEast's auth.streamea.st first-party cookie handshake). Retained so
    /// WebKit keeps loading them; auto-retired after the handshake window.
    private var ssoPopups: [WKWebView] = []
    /// v2.71: auth hosts we've already spawned an SSO popup for this attempt.
    /// A page that calls window.open(auth…) on a loop would otherwise spawn a
    /// popup per call and hammer the auth host into Cloudflare rate-limiting
    /// (error 1015). One handshake per host is all we ever need.
    private var ssoPopupHosts = Set<String>()

    func noteIntendedLoad(_ url: URL) { intendedLoadURLs.insert(url.absoluteString) }

    private func registrableSuffix(_ host: String) -> String {
      let parts = host.lowercased().split(separator: ".")
      guard parts.count >= 2 else { return host.lowercased() }
      return parts.suffix(2).joined(separator: ".")
    }
    /// The brand label immediately left of the TLD ("crackstreams.ms" and
    /// "crackstreams.ws" both → "crackstreams").
    private func brandBase(_ host: String) -> String {
      let parts = host.lowercased().split(separator: ".")
      guard parts.count >= 2 else { return host.lowercased() }
      return String(parts[parts.count - 2])
    }
    private func sameSite(_ a: String?, _ b: String?) -> Bool {
      guard let a, let b else { return false }
      if registrableSuffix(a) == registrableSuffix(b) { return true }
      // v2.68: these aggregators spread the same listing across sibling
      // mirror domains (crackstreams.ms ↔ crackstreams.ws) and link between
      // them. Treat a shared, distinctive brand base as the same site so the
      // mirror hop isn't rejected as a cross-site ad — which stranded the
      // walk on the landing page, never reaching the game listing.
      let base = brandBase(a)
      return base.count >= 5 && base == brandBase(b)
    }
    private func carriesTargetToken(_ url: URL) -> Bool {
      guard !targetTokens.isEmpty else { return false }
      let low = url.absoluteString.lowercased()
      return targetTokens.contains { low.contains($0) }
    }
    /// Should this top-frame destination be allowed? Same-site as the
    /// source (or the page we're currently on), or a load we initiated.
    /// `carriesTargetToken` was removed: team names appearing in a URL
    /// is not a reliable signal that the destination is the same streaming
    /// service — it was allowing navigation to entirely different sites
    /// (e.g. buffstreams.plus → thestreameast.one).
    private func isAllowedTopNav(_ url: URL, current: URL?) -> Bool {
      if intendedLoadURLs.contains(url.absoluteString) { return true }
      if sourceHost == nil { return true }  // not yet pinned
      if sameSite(url.host, sourceHost) { return true }
      if sameSite(url.host, current?.host) { return true }
      return false
    }

    /// v2.71: is this blocked popup actually the site's own SSO cookie
    /// bootstrap (not an ad)? True when it's an auth URL that bounces back to
    /// the source — a `redirect`/`to`/… param resolving to the source host, or
    /// a `domain=<sourceHost>` hint (StreamEast: auth.streamea.st/sso-frame.php
    /// ?domain=v2.streameast.ga&redirect=%2Fmlb%2F<game>). These popups exist
    /// to set a FIRST-PARTY cookie the embedded sso-frame iframe can't (ITP),
    /// so letting the popup run is the only way the handshake completes.
    private func isSSOPopup(_ url: URL, current: URL?) -> Bool {
      guard URLClassifier.isAuthURL(url) else { return false }
      let base = current ?? webView?.url
      if let inner = URLClassifier.unwrapRedirect(url, base: base),
         sameSite(inner.host, sourceHost) { return true }
      if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
         let domain = comps.queryItems?.first(where: { $0.name.lowercased() == "domain" })?.value,
         sameSite(domain, sourceHost) { return true }
      return false
    }

    init(onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?,
         onStreamProbed: ((URL, Bool, Bool, [HTTPCookie], URL?) -> Void)? = nil,
         onProbeRejected: (() -> Void)? = nil,
         onNavigation: ((URL) -> Void)? = nil,
         onWalkEvent: ((StreamWebView.WalkEvent) -> Void)? = nil,
         onLoadFailed: ((URL, String) -> Void)? = nil,
         onPageChanged: ((URL) -> Void)? = nil,
         browseMode: Bool) {
      self.onStreamURLFound = onStreamURLFound
      self.onStreamProbed = onStreamProbed
      self.onProbeRejected = onProbeRejected
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
      // v2.68: don't drill into ad iframes. After we've reached the real
      // embed (embed.st/.../ppv-san-francisco-giants-vs-chicago-cubs/1, which
      // carries both team names) its page is littered with cross-origin ad
      // frames (ndcertainlywhen.com/?tid=…, playonrain.com). Drilling the top
      // frame into one — via an "intended load" that bypasses the popup
      // guard — is exactly how we ended up stranded on an ad, searching
      // forever. A cross-origin iframe is only a real stream embed if it
      // carries a team token or is same-site as the page we're on now.
      let currentHost = webView?.url?.host
      if !sameSite(host, currentHost),
         !sameSite(host, sourceHost),
         !carriesTargetToken(url) {
        let event = StreamWebView.WalkEvent(
          kind: "iframe_skipped", info: host, at: Date(), detectedCards: []
        )
        DispatchQueue.main.async { self.onWalkEvent?(event) }
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
      webView.load(request)
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
      } else if let url = navigationAction.request.url, isSSOPopup(url, current: webView.url) {
        // v2.71: one SSO handshake per auth host. A page that loops
        // window.open(auth…) would otherwise spawn a popup per call and hammer
        // the auth host into Cloudflare rate-limiting (error 1015).
        let authHost = url.host ?? url.absoluteString
        guard ssoPopupHosts.insert(authHost).inserted else { return nil }
        // Let the site's own SSO popup run in a short-lived auxiliary WebView
        // that SHARES this one's data store (so the first-party auth cookie
        // lands in the shared jar and the embedded player can use it). WebKit
        // auto-loads navigationAction.request into the returned view; we don't
        // set our navigation delegate on it (that would pin it to the source
        // host and break the auth redirect). Retired after 12 s.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        ssoPopups.append(popup)
        let event = StreamWebView.WalkEvent(
          kind: "sso_popup", info: url.host ?? url.absoluteString,
          at: Date(), detectedCards: []
        )
        DispatchQueue.main.async { self.onWalkEvent?(event) }
        Task { [weak self, weak popup] in
          try? await Task.sleep(nanoseconds: 12_000_000_000)
          await MainActor.run {
            guard let self, let popup else { return }
            self.ssoPopups.removeAll { $0 === popup }
          }
        }
        return popup
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
      // v2.68: a cancelled/interrupted provisional load is almost always
      // self-inflicted — we started a new in-app navigation (e.g. to a
      // recovered /watch/<game> URL) while a prior load was still in flight,
      // or a redirect superseded it. It is NOT a host/DNS failure, so do not
      // run HostFallback (which rewrites the source URL to a sibling host and
      // can leave the source disabled). Just let the new load proceed.
      let isCancelled = nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled
      let isFrameInterrupted = nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102
      if isCancelled || isFrameInterrupted { return }
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
        // v2.69: only a DIRECT manifest request is the stream — match on the
        // path, not the whole URL. Embed/redirect wrappers carry the real
        // manifest inside their query string
        // (bintv-nett.blogspot.com/?src=…%2Fmaster.m3u8&title=…); the old
        // whole-URL `contains(".m3u8")` mistook that wrapper for the stream,
        // cancelled its load, and handed AVPlayer an HTML page (black screen).
        // Letting the wrapper load lets its player fetch the actual manifest,
        // whose own request — path ending in .m3u8/.mpd — we catch here next.
        let p = url.path.lowercased()
        if p.contains(".m3u8") || p.contains(".mpd") {
          // v2.71: in WebView-player mode let the embed's own player load the
          // manifest (and its segments) so it can play a stream AVPlayer can't.
          if playerModeEngaged { decisionHandler(.allow); return }
          if !found { report(url) }
          decisionHandler(.cancel); return
        }
        // v2.69 (unwrap): the wrapper carries the real manifest inside its
        // query (bintv-nett.blogspot.com/?src=…%2Fmaster.m3u8). Its nested
        // player frequently won't self-start headlessly, so the manifest
        // request never fires on its own. Pull the embedded manifest out and
        // report it directly. We don't cancel — the wrapper still loads as a
        // fallback in case the extracted URL is locked and its player ends up
        // fetching a playable variant we can catch above.
        if !found, let inner = Self.embeddedManifestURL(in: url) {
          report(inner)
        }
      }
      if !browseMode,
         action.navigationType == .linkActivated,
         let url = action.request.url,
         !isAllowedTopNav(url, current: webView.url) {
        decisionHandler(.cancel); return
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
        let event = StreamWebView.WalkEvent(
          kind: "popup_blocked", info: url.host ?? url.absoluteString,
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
        // v2.71: in WebView-player mode, let the embed player consume the
        // stream response instead of cancelling it to hand to AVPlayer.
        if playerModeEngaged { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if !found { report(url) }
        return
      }
      decisionHandler(.allow)
    }

    private func report(_ url: URL) {
      guard !found, !playerModeEngaged else { return }
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
      let onProbeRejected = self.onProbeRejected
      let isFirstURL = (firstObservedURL?.absoluteString == url.absoluteString)
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
        // v2.72: verify it's actually a LIVE, currently-reachable stream before
        // we'd ever commit it. This is host-agnostic — the core defense against
        // takedown-evading aggregators whose endpoints rotate/die constantly and
        // whose pages serve filler/ad/VOD loops we used to commit by mistake.
        let live = playable ? await StreamLiveness.isLive(url, referer: referer, cookies: cookies) : false
        await MainActor.run {
          onProbed?(url, playable, live, cookies, referer)
          guard let self else { return }
          // v2.72: NO host-identity rejection. These CDNs rotate to evade
          // takedowns, so a host is never reliably "bad" — and "Didn't" feedback
          // often meant wrong CONTENT, not a bad host, which poisoned the legit
          // ppv CDN (indianservers.st). Liveness verification below is the real,
          // host-agnostic trust signal; we lean on it instead.
          if !playable, isFirstURL {
            self.probeRejectedFirstURL = true
            self.engagePlayerMode()  // v2.71: hand playback to the embed's player
            onProbeRejected?()
            return
          }
          guard !self.found, playable else { return }
          // v2.72: strict live gate — these are all live games, so a finite/VOD
          // playlist, or one whose first segment won't load (dead/gated CDN), is
          // NOT the stream we want. Reject and keep scanning rather than commit.
          guard live else {
            self.onWalkEvent?(WalkEvent(
              kind: "stream_rejected", info: "not-live " + (url.host ?? ""),
              at: Date(), detectedCards: []
            ))
            return
          }
          self.verifiedLiveURLs.insert(url.absoluteString)
          // v2.71: among live candidates, prefer the one related to what the
          // user wanted. Commit immediately on a known-good host OR a URL
          // carrying a target-game token; otherwise hold an unknown host back
          // briefly so a related/known-good live capture can win the race.
          if self.isKnownGoodHost(url.host) || self.streamCarriesToken(url) {
            self.commitURL(url)
          } else {
            self.deferUnknownCandidate(url)
          }
        }
      }
    }

    private func commitFallbackIfNeeded() {
      guard !found, let url = firstObservedURL else { return }
      // Probe already determined this URL isn't playable by AVPlayer —
      // don't force-commit it. The WebView continues showing the stream.
      guard !probeRejectedFirstURL else { return }
      // v2.72: only ever commit a stream we verified is live + reachable.
      guard verifiedLiveURLs.contains(url.absoluteString) else { return }
      commitURL(url)
    }

    private func commitURL(_ url: URL) {
      found = true
      if let store = webView?.configuration.websiteDataStore.httpCookieStore {
        store.getAllCookies { cookies in
          DispatchQueue.main.async { self.onStreamURLFound?(url, cookies) }
        }
      } else {
        DispatchQueue.main.async { self.onStreamURLFound?(url, []) }
      }
    }

    /// v2.69: extract the real media manifest a wrapper/embed URL carries in
    /// its (often multiply percent-encoded) query string. Returns nil when the
    /// URL is itself a direct manifest, or when no embedded manifest is found.
    /// Players like bintv chain several redirect hops —
    /// `…blogspot.com/?src=…%2F%3Fq%3D…%2Fmaster.m3u8` — so we decode a few
    /// passes and take the innermost (last) manifest URL, which is the real one
    /// (the outer layers only contain ".m3u8" because they wrap it).
    static func embeddedManifestURL(in url: URL) -> URL? {
      let path = url.path.lowercased()
      if path.contains(".m3u8") || path.contains(".mpd") { return nil }
      let whole = url.absoluteString.lowercased()
      guard whole.contains(".m3u8") || whole.contains(".mpd") else { return nil }
      var s = url.absoluteString
      for _ in 0..<3 {
        guard let decoded = s.removingPercentEncoding, decoded != s else { break }
        s = decoded
      }
      let pattern = #"https?://[^\s"'<>&]+\.(?:m3u8|mpd)(?:\?[^\s"'<>&]*)?"#
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
      let range = NSRange(s.startIndex..., in: s)
      let matches = regex.matches(in: s, range: range)
      for m in matches.reversed() {
        guard let r = Range(m.range, in: s) else { continue }
        let candidate = String(s[r])
        guard let inner = URL(string: candidate),
              inner.absoluteString != url.absoluteString else { continue }
        let ip = inner.path.lowercased()
        if ip.contains(".m3u8") || ip.contains(".mpd") { return inner }
      }
      return nil
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
