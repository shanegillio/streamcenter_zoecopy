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
    let pageURL: URL
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

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if rulesReady {
        if avPlayer == nil {
          if registry.enabledSources.isEmpty && game.streamURLs.isEmpty {
            noSourcesEnabledView
          } else if allFailed {
            retryUI
          } else if !attempts.isEmpty, currentAttemptIdx < attempts.count {
            let current = attempts[currentAttemptIdx]
            // v2.38: verification layout — top URL strip, visible
            // WebView in the middle, captured-streams strip at bottom.
            VStack(spacing: 0) {
              navStrip(sourceName: sourceName(for: current.sourceID))
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
                    // We only auto-commit when navigation actually
                    // advanced past the source's homepage — protects
                    // against committing a stream URL that surfaced from
                    // an ad iframe before the user-targeted nav happened.
                    // Stays off for the initial Hop 1 captures; user can
                    // still tap the strip pill manually in that case.
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
                onStreamProbed: { url, playable in
                  Task { @MainActor in
                    if let sid = traversalSessionID {
                      TraversalLog.shared.recordEvent(
                        sid, kind: "stream_probed",
                        info: "\(playable ? "ok" : "fail"): \(url.absoluteString)"
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
              if !capturedStreams.isEmpty {
                capturedStreamsStrip(referer: current.pageURL)
              }
            }
            .ignoresSafeArea(edges: .bottom)
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
        startTraversalSession()
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
      if health.isInParkingCooldown(c.sourceID) { continue }
      built.append(SourceAttempt(sourceID: c.sourceID, pageURL: c.pageURL))
    }
    let preResolvedIDs = Set(built.map(\.sourceID))
    let fallbackSources = registry.enabledSources
      .filter { !preResolvedIDs.contains($0.id) }
      .filter { !failureStore.isFailedRecently(gameKey: gameKey, sourceID: $0.id) }
      .filter { !health.isInParkingCooldown($0.id) }
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
    case "click_failed": return "xmark.octagon.fill"
    case "scan", "no_match", "cat_scan": return "magnifyingglass"
    default: return "circle"
    }
  }
  private func walkColor(for kind: String) -> Color {
    switch kind {
    case "clicked", "category_click": return .green
    case "click_failed": return .red
    case "scan", "no_match", "cat_scan": return .yellow
    default: return .white.opacity(0.6)
    }
  }
  private func walkLabel(for event: StreamWebView.WalkEvent) -> String {
    switch event.kind {
    case "clicked": return "Walk clicked: \(event.info.replacingOccurrences(of: "card: ", with: ""))"
    case "category_click": return "Walk → category: \(event.info)"
    case "click_failed": return "Walk click error: \(event.info)"
    case "scan": return "Walk: \(event.info)"
    case "cat_scan": return "CategoryLink: \(event.info)"
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
    default:
      lastWalkEvent = event
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
    if let event = lastWalkEvent {
      let isFreshClick = (event.kind == "clicked" || event.kind == "category_click")
                       && Date().timeIntervalSince(event.at) < 1.5
      if !isFreshClick { lastWalkEvent = nil }
    }
  }

  private func appendNavigation(_ url: URL) {
    if navigationHistory.last == url { return }
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
    currentAttemptIdx += 1
    startTraversalSession()
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
          allFailed = false
          if !attempts.isEmpty {
            SourceHealth.shared.recordAttempt(
              sourceID: attempts[currentAttemptIdx].sourceID
            )
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
  /// `pair` and click it. Used when the user taps an alternative game
  /// in the "Detected on this page" strip and our exact matcher missed.
  func clickFirstMatching(_ pair: String) {
    guard let webView else { return }
    let escaped = pair
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
    // v2.41: walk up to clickable ancestor before .click(). Without
    // this, tapping a detected-cards capsule often clicks the inner
    // <h2> / <span> whose parent <div> holds the actual onclick.
    let js = """
    (function(){
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
      var t = '\(escaped)'.toLowerCase();
      var sel = 'a[href],button,[onclick],[data-match],[data-event],[data-game],' +
                '[role="button"],[class*="card" i],[class*="match" i],[class*="game" i]';
      var els = document.querySelectorAll(sel);
      for (var i = 0; i < els.length && i < 2000; i++) {
        var e = els[i];
        var b = ((e.innerText || e.textContent || '') + ' ' +
                 (e.getAttribute && (e.getAttribute('aria-label') || '')) + ' ' +
                 (e.getAttribute && (e.getAttribute('title') || ''))).toLowerCase();
        if (b.indexOf(t) !== -1) {
          var target = findClickableAncestor(e);
          robustClick(target);
          return true;
        }
      }
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
  var onStreamProbed: ((URL, Bool) -> Void)? = nil
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

    // v2.57: the walk also needs popups REDIRECTED, not suppressed. Many
    // stream-site game cards have no <a href> — their onclick calls
    // window.open(gameURL). popupSuppressJS turned that into a no-op, so
    // we clicked the right card and went nowhere (CLICKED-BUT-NO-NAV).
    // Redirecting window.open into a same-frame navigation lets the walk
    // follow those cards. (The risk is an ad popup hijacking the frame,
    // but a dropped navigation guarantees failure, so redirect wins.)
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

  static let popupSuppressJS = """
    window.open = function(){return null;};
    window.alert = function(){};
    window.confirm = function(){return false;};
    window.prompt = function(){return '';};
  """

  static let popupRedirectJS = """
    window.alert = function(){};
    window.confirm = function(){return false;};
    window.prompt = function(){return '';};
    window.open = function(url){
      if (url && typeof url === 'string') {
        try {
          var abs = new URL(url, window.location.href).href;
          if (abs.indexOf('http') === 0) { window.location.href = abs; }
        } catch(e) {
          if (url.indexOf('http') === 0) { window.location.href = url; }
        }
      }
      return null;
    };
  """

  /// Sets `window.__sc_target` for the shim's walk routine.
  /// v2.35: carries `league` raw value too so findCategoryLink can pick
  /// the right league-named category link when the user-target game
  /// isn't on the homepage. nil game → __sc_target=null → shim falls
  /// back to generic clicking.
  static func slugConfigJS(for game: Game?) -> String {
    func slug(_ s: String) -> String {
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
    guard let g = game else { return "window.__sc_target = null;" }
    let h = slug(g.homeTeam)
    let a = slug(g.awayTeam)
    let l = g.league.rawValue.replacingOccurrences(of: "'", with: "\\'")
    return "window.__sc_target = {home: '\(h)', away: '\(a)', league: '\(l)'};"
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
        var ht = [], at = [];
        var tgt = window.__sc_target;
        if (tgt && tgt.home && tgt.away) {
          var mkTok = function(slug) {
            var t = []; slug = (slug || '').toLowerCase();
            if (slug.length >= 4) t.push(slug);
            slug.split('-').forEach(function(w){ if (w.length >= 4) t.push(w); });
            return t;
          };
          ht = mkTok(tgt.home); at = mkTok(tgt.away);
        }
        function hasTok(text, toks) {
          for (var k = 0; k < toks.length; k++) {
            if (text.indexOf(toks[k]) !== -1) return true;
          }
          return false;
        }
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
          if (ht.length && at.length && blob.length < targetSize) {
            var pl = (m[1] + ' ' + m[2]).toLowerCase();
            if (hasTok(pl, ht) && hasTok(pl, at)) {
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
        if (targetEl && _walkClicks < _maxWalkClicks) {
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
      function _firstUsableAnchorHref(scope) {
        try {
          var as = scope.querySelectorAll && scope.querySelectorAll('a[href]');
          if (as) for (var i = 0; i < as.length; i++) {
            var h = as[i].getAttribute('href'); if (_usableHref(h)) return h;
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
      function _findNavHref(el) {
        if (!el) return '';
        try { if (el.tagName === 'A') { var h0 = el.getAttribute('href'); if (_usableHref(h0)) return h0; } } catch(e){}
        var n = el, lvl = 0;
        while (n && lvl < 6) {
          if (n.tagName === 'A') { var h2 = n.getAttribute('href'); if (_usableHref(h2)) return h2; }
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
        return out;
      }

      // v2.43: side-channel stats so tryAdvance can post a scan event.
      // v2.44: rejSample is the longest blob the matcher rejected — shown
      // to the user when matched=0 so we can see what we're scanning.
      // v2.53: nHome/nAway count elements containing ONLY one team's
      // tokens — distinguishes "team names not in DOM at all" from "both
      // teams in DOM but never co-located in the same wrapper element".
      var _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };

      function selectTargetGameElement() {
        _scanStats = { candidates: 0, matched: 0, nHome: 0, nAway: 0, sample: '', rejSample: '' };
        if (!window.__sc_target) return null;
        var home = (window.__sc_target.home || '').toLowerCase();
        var away = (window.__sc_target.away || '').toLowerCase();
        if (!home || !away) return null;
        function tokens(slug) {
          var t = [];
          if (slug.length >= 4) t.push(slug);
          slug.split('-').forEach(function(w){ if (w.length >= 4) t.push(w); });
          return t;
        }
        var ht = tokens(home), at = tokens(away);
        if (!ht.length || !at.length) return null;
        function bothPresent(text) {
          var lower = text.toLowerCase();
          return ht.some(function(tok){ return lower.indexOf(tok) !== -1; })
              && at.some(function(tok){ return lower.indexOf(tok) !== -1; });
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
        var home = (window.__sc_target.home || '').toLowerCase();
        var away = (window.__sc_target.away || '').toLowerCase();
        if (!home || !away) return null;
        function tokens(slug) {
          var t = [];
          if (slug.length >= 4) t.push(slug);
          slug.split('-').forEach(function(w){ if (w.length >= 4) t.push(w); });
          return t;
        }
        var ht = tokens(home), at = tokens(away);
        if (!ht.length || !at.length) return null;
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
          var hh = false, aa = false;
          for (var k = 0; k < ht.length && !hh; k++) {
            if (blob.indexOf(ht[k]) !== -1) hh = true;
          }
          for (var m = 0; m < at.length && !aa; m++) {
            if (blob.indexOf(at[m]) !== -1) aa = true;
          }
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
        var home = (window.__sc_target.home || '').toLowerCase();
        var away = (window.__sc_target.away || '').toLowerCase();
        if (!home || !away) return null;
        function tokens(slug) {
          var t = [];
          if (slug.length >= 4) t.push(slug);
          slug.split('-').forEach(function(w){ if (w.length >= 4) t.push(w); });
          return t;
        }
        var ht = tokens(home), at = tokens(away);
        if (!ht.length || !at.length) return null;
        function hasTok(text, toks) {
          for (var k = 0; k < toks.length; k++) {
            if (text.indexOf(toks[k]) !== -1) return true;
          }
          return false;
        }
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
          if (hasTok(pair, ht) && hasTok(pair, at)) {
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

      function findCategoryLink(leagueRawValue) {
        _catScanStats = { cands: 0, matched: 0, clicked: '', rejSample: '' };
        var keys = _leagueHints[leagueRawValue] || [];
        if (!keys.length) return null;
        // v2.44: many category landing pages (crackstreams' "NBA Streams"
        // card, etc.) wrap their category in a styled <div onclick=> or
        // <button>, not a plain <a>. Broaden to all clickable shapes.
        var els;
        try {
          els = document.querySelectorAll(
            'a[href], button, [onclick], [data-href], [role="button"], ' +
            '[class*="card" i], [class*="link" i]'
          );
        } catch(e) { return null; }
        _catScanStats.cands = els.length;
        var cap = Math.min(els.length, 600);
        var longestRej = 0;
        for (var i = 0; i < cap; i++) {
          var el = els[i];
          var href = '';
          try { href = (el.getAttribute && (el.getAttribute('href') || el.getAttribute('data-href'))) || ''; } catch(e){}
          var txt = (el.innerText || el.textContent || '');
          var blob = (txt + ' ' + href).toLowerCase();
          if (blob.length < 3 || blob.length > 200) continue;
          var matched = false;
          for (var k = 0; k < keys.length; k++) {
            if (blob.indexOf(keys[k]) !== -1) {
              matched = true;
              break;
            }
          }
          if (matched) {
            _catScanStats.matched = 1;
            _catScanStats.clicked = (txt || href).slice(0, 80);
            // Walk up to the clickable ancestor (same fix as v2.41
            // for selectTargetGameElement) — the matched element may
            // be an inner text node whose parent has the onclick.
            return findClickableAncestor(el);
          } else if (blob.length > longestRej) {
            longestRej = blob.length;
            _catScanStats.rejSample = blob.slice(0, 80);
          }
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
    let onStreamProbed: ((URL, Bool) -> Void)?
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

    init(onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?,
         onStreamProbed: ((URL, Bool) -> Void)? = nil,
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
      webView.load(request)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      // v2.57: always follow new-window / target="_blank" requests in the
      // same web view. Previously gated on browseMode, which meant the
      // auto-walk dropped every popup-style game link (CLICKED-BUT-NO-NAV).
      if let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
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
         let host = action.request.url?.host,
         host != webView.url?.host {
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
          onProbed?(url, playable)
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
