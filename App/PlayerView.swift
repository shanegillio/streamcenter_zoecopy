import SwiftUI
import WebKit
import AVKit

struct PlayerView: View {
  let game: Game
  @Environment(SourceRegistry.self) private var registry
  @State private var ruleList: WKContentRuleList? = nil
  @State private var avPlayer: AVPlayer? = nil
  @State private var rulesReady = false
  /// v2.24: sequential attempts across `game.streamURLs`. Each entry is
  /// `.pending` until tried, then `.failed` if the per-source budget
  /// elapses without finding an m3u8. The first to succeed promotes us
  /// to AVPlayer; if every candidate fails we show the retry UI.
  @State private var attempts: [SourceAttempt] = []
  @State private var currentAttemptIdx: Int = 0
  @State private var allFailed: Bool = false
  /// Per-source budget in seconds. Tight enough to fail-fast through dead
  /// sources, loose enough to give a flaky-but-working source time to
  /// load + intercept its m3u8.
  private static let perSourceBudget: TimeInterval = 10
  /// Becomes true after the user explicitly hits "Browse manually" on the
  /// retry UI — reveals the raw WebView for the failing source.
  @State private var showWebFallback = false
  /// v2.29: true while parallel per-source LLM page search runs before
  /// the sequential attempt loop. Overlay reads "Searching sources…"
  /// during this phase and "Checking sources…" afterwards.
  @State private var isSearchingSources = false
  @State private var searchSourcesRemaining = 0

  struct SourceAttempt: Identifiable {
    let id = UUID()
    let sourceID: String
    let pageURL: URL
    var status: Status = .pending

    enum Status { case pending, trying, failed }
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if rulesReady {
        if avPlayer == nil {
          if allFailed {
            // All candidates exhausted — show per-source retry UI.
            retryUI
          } else if !attempts.isEmpty, currentAttemptIdx < attempts.count {
            let current = attempts[currentAttemptIdx]
            // WebView is removed from the hierarchy once AVPlayer starts.
            // Re-keying on `current.id` means SwiftUI rebuilds StreamWebView
            // when we advance to the next attempt — discarding the previous
            // WKWebContent process cleanly.
            StreamWebView(
              url: current.pageURL,
              ruleList: ruleList,
              onStreamURLFound: { streamURL, cookies in
                Task { @MainActor in
                  let p = makePlayer(url: streamURL, cookies: cookies, referer: current.pageURL)
                  avPlayer = p
                  p.play()
                  // v2.30: success recording. The source that produced this
                  // stream gets credit in SourceHealth, becomes the league's
                  // last-successful preference, teaches SourceLearningStore
                  // about its URL pattern, and clears any prior failures.
                  // v2.31: also record the stream URL's hostname so future
                  // candidates from the same host get an L1 +10 boost.
                  recordSuccess(attempt: current, streamURL: streamURL)
                }
              },
              targetGame: game,           // v2.31: drives L1+L3+L4 scoring
              sourceID: current.sourceID  // v2.31: known-good-hosts + future fingerprint recording
            )
            .id(current.id)
            .ignoresSafeArea()
            .opacity(showWebFallback ? 1 : 0)

            if !showWebFallback {
              if isSearchingSources {
                StreamSearchingOverlay(
                  attemptIndex: 0,
                  totalAttempts: 0,
                  sourceName: "",
                  searchingCount: searchSourcesRemaining
                )
              } else {
                StreamSearchingOverlay(
                  attemptIndex: currentAttemptIdx,
                  totalAttempts: attempts.count,
                  sourceName: sourceName(for: current.sourceID),
                  searchingCount: 0
                )
              }
            }
          } else {
            if isSearchingSources {
              StreamSearchingOverlay(
                attemptIndex: 0,
                totalAttempts: 0,
                sourceName: "",
                searchingCount: searchSourcesRemaining
              )
            } else {
              StreamLoadingView()
            }
          }
        }

        if let avPlayer {
          VideoPlayerView(player: avPlayer)
            .ignoresSafeArea()
        }
      } else {
        StreamLoadingView()
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
      // v2.29: enrich attempts with LLM-discovered per-game pages from
      // every enabled source the orchestrator didn't pre-match. This
      // runs in parallel before the sequential attempt loop.
      await searchSourcesForGamePage()
      // Each candidate gets its budget; if it doesn't resolve, advance.
      while currentAttemptIdx < attempts.count {
        let startedIdx = currentAttemptIdx
        attempts[startedIdx].status = .trying
        // v2.30: count this as an attempt so SourceHealth's success-rate
        // denominator reflects what we actually tried.
        SourceHealth.shared.recordAttempt(sourceID: attempts[startedIdx].sourceID)
        try? await Task.sleep(nanoseconds: UInt64(Self.perSourceBudget * 1_000_000_000))
        if avPlayer != nil { return }
        if currentAttemptIdx == startedIdx {
          attempts[startedIdx].status = .failed
          currentAttemptIdx += 1
        }
      }
      // Exhausted all candidates without a stream.
      if avPlayer == nil {
        allFailed = true
        // v2.30: record each tried source as a failure for this game so
        // a subsequent tap-and-retry on the same game skips them.
        recordAllFailures()
      }
    }
  }

  /// v2.29: kick off per-source `findStreamPage` in parallel for every
  /// enabled source that doesn't already have a pre-resolved URL in
  /// `attempts`. Each task has a 12 s budget. Resolved URLs are inserted
  /// AHEAD of the source's existing baseURL-homepage fallback so the
  /// per-game page gets tried first (higher confidence). Cleaned-up
  /// `attempts` is what the sequential loop walks.
  private func searchSourcesForGamePage() async {
    // Source IDs already represented by a per-game URL (orchestrator
    // pre-match). Sources currently in attempts via their baseURL
    // (the v2.28 fallback) still count as "needs search" — the LLM
    // page might find something better than the homepage.
    let preResolvedIDs = Set(
      game.streamURLs.map(\.sourceID)
    )
    let gameKey = GameKey.make(for: game)
    let failureStore = FailureStore.shared
    let health = SourceHealth.shared
    let toSearch = registry.enabledSources
      .filter { !preResolvedIDs.contains($0.id) }
      // v2.30: skip sources that recently failed for this exact game
      // (1h memory in FailureStore). Avoids re-burning 12 s on a known
      // dead end during tap-and-retry.
      .filter { !failureStore.isFailedRecently(gameKey: gameKey, sourceID: $0.id) }
      // v2.30: skip sources currently in a parking cooldown (≥3
      // parking detections within the past hour). They're not going to
      // resolve and they slow the race down.
      .filter { !health.isInParkingCooldown($0.id) }
    guard !toSearch.isEmpty else { return }

    isSearchingSources = true
    searchSourcesRemaining = toSearch.count
    let discovered = await withTaskGroup(of: (String, URL?).self) { group in
      for source in toSearch {
        group.addTask {
          // 12 s per source — enough for the WKWebView homepage load,
          // CF clearance (if needed), the JS-rendered link extraction,
          // and one Foundation Models pass.
          let work = Task { await source.findStreamPage(for: game) }
          let timer = Task<URL?, Never> {
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            work.cancel()
            return nil
          }
          let url = await work.value
          timer.cancel()
          return (source.id, url)
        }
      }
      var results: [(String, URL?)] = []
      for await pair in group {
        results.append(pair)
        await MainActor.run { searchSourcesRemaining -= 1 }
      }
      return results
    }
    isSearchingSources = false

    // Splice newly-discovered URLs into `attempts`. For each match,
    // insert before any existing baseURL-homepage fallback for the
    // same source.
    for (sourceID, maybeURL) in discovered {
      guard let url = maybeURL else { continue }
      let baseURL = registry.sources.first(where: { $0.id == sourceID })?.baseURL
      let insertAt = attempts.firstIndex(where: {
        $0.sourceID == sourceID && $0.pageURL == baseURL
      }) ?? attempts.count
      attempts.insert(
        SourceAttempt(sourceID: sourceID, pageURL: url),
        at: insertAt
      )
    }
  }

  /// Map `game.streamURLs` (orchestrator-resolved aggregator URLs) into
  /// the sequential attempt list. v2.28 then APPENDS every enabled
  /// source not already represented as a fallback "check this source's
  /// homepage for the game" attempt — so a Boxing fixture (no
  /// orchestrator match) still walks through the user's pool instead
  /// of falling back to a misleading "Trying ESPN page" message.
  private func buildAttempts() {
    let gameKey = GameKey.make(for: game)
    let failureStore = FailureStore.shared
    let health = SourceHealth.shared
    let preference = SourcePreference.shared

    var built: [SourceAttempt] = []
    // 1. Aggregator URLs the orchestrator pre-matched at listing time.
    //    Highest-confidence candidates — the aggregator's own per-game
    //    page, JS-intercept layer is most likely to find a stream here.
    //    v2.30: drop pre-matched candidates whose source is in
    //    failure-memory or parking-cooldown for this game.
    for c in game.streamURLs {
      if failureStore.isFailedRecently(gameKey: gameKey, sourceID: c.sourceID) { continue }
      if health.isInParkingCooldown(c.sourceID) { continue }
      built.append(SourceAttempt(sourceID: c.sourceID, pageURL: c.pageURL))
    }
    // 2. v2.28: every other enabled source as a "check this source"
    //    fallback. We load the source's homepage in the StreamWebView
    //    and let the JS-intercept layer catch any stream the user's
    //    view of the site happens to surface. Even without auto-resolve
    //    the per-source retry UI gives the user a clear "Browse Manually"
    //    on the last attempt.
    //
    //    v2.30: order the fallback pool by recent success rate
    //    (SourceHealth), then bias the league's last-successful source
    //    to the front. Sources demoted by health (< 10% success after
    //    ≥5 attempts) get pushed to the back so they only try if every
    //    healthier source has failed.
    let preResolvedIDs = Set(game.streamURLs.map(\.sourceID))
    let fallbackSources = registry.enabledSources
      .filter { !preResolvedIDs.contains($0.id) }
      .filter { !failureStore.isFailedRecently(gameKey: gameKey, sourceID: $0.id) }
      .filter { !health.isInParkingCooldown($0.id) }
    let fallbackIDs = fallbackSources.map(\.id)
    let demotedIDs = Set(fallbackIDs.filter { health.isDemoted($0) })
    let healthyIDs = fallbackIDs.filter { !demotedIDs.contains($0) }

    // Order healthy fallbacks by health.
    var orderedHealthy = health.orderedByHealth(healthyIDs)
    // Bias league's last-successful source to attempt-first within healthy.
    if let preferred = preference.lastSuccessfulSource(for: game.league),
       let idx = orderedHealthy.firstIndex(of: preferred), idx > 0 {
      orderedHealthy.remove(at: idx)
      orderedHealthy.insert(preferred, at: 0)
    }
    // Demoted sources go to the back, themselves ordered by health.
    let orderedDemoted = health.orderedByHealth(Array(demotedIDs))
    let orderedFallbackIDs = orderedHealthy + orderedDemoted

    for sourceID in orderedFallbackIDs {
      guard let source = fallbackSources.first(where: { $0.id == sourceID }) else { continue }
      built.append(SourceAttempt(sourceID: source.id, pageURL: source.baseURL))
    }

    // 3. Absolute last resort: no enabled sources at all → one ESPN-
    //    page attempt so the retry UI still has something to show
    //    (clearly labelled "ESPN page" — not a misleading default).
    if built.isEmpty {
      built.append(SourceAttempt(sourceID: "espn", pageURL: game.pageURL))
    }
    attempts = built
    currentAttemptIdx = 0
    allFailed = false
  }

  /// v2.30/v2.31: record success across all relevant stores when the
  /// WebView JS-intercept successfully hands AVPlayer a playable URL.
  /// Called from the StreamWebView callback once on first successful
  /// stream. v2.31 adds `streamURL` so we can record the stream-host
  /// for future L1 known-good-host boosts.
  private func recordSuccess(attempt: SourceAttempt, streamURL: URL? = nil) {
    let gameKey = GameKey.make(for: game)
    let sid = attempt.sourceID
    SourceHealth.shared.recordSuccess(sourceID: sid)
    SourcePreference.shared.recordSuccess(league: game.league, sourceID: sid)
    SourceLearningStore.shared.recordSuccess(
      sourceID: sid, gamePageURL: attempt.pageURL, game: game
    )
    if let host = streamURL?.host {
      SourceLearningStore.shared.recordPlaybackHost(host, sourceID: sid)
    }
    FailureStore.shared.clearForGame(gameKey: gameKey)
  }

  /// v2.30: called when every attempt failed without producing a stream.
  /// Records each tried source's pair in FailureStore so the next tap-and-
  /// retry on this game skips them for the next hour. We don't record
  /// health-failures here — SourceHealth.attempt was already recorded at
  /// the top of each loop iteration; "attempt without success" is exactly
  /// what its denominator reflects.
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

  /// Retry UI when every candidate has been exhausted. Shows per-source
  /// status + actions to retry (re-run the whole sequence) or browse
  /// the most-recently-tried URL manually.
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
      // Per-source attempt status
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
          // Retry all candidates from scratch.
          buildAttempts()
          allFailed = false
          Task {
            while currentAttemptIdx < attempts.count {
              let startedIdx = currentAttemptIdx
              attempts[startedIdx].status = .trying
              try? await Task.sleep(nanoseconds: UInt64(Self.perSourceBudget * 1_000_000_000))
              if avPlayer != nil { return }
              if currentAttemptIdx == startedIdx {
                attempts[startedIdx].status = .failed
                currentAttemptIdx += 1
              }
            }
            if avPlayer == nil { allFailed = true }
          }
        } label: {
          Label("Try Again", systemImage: "arrow.clockwise")
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(.white)
        }
        if !attempts.isEmpty {
          Button {
            showWebFallback = true
            allFailed = false
            currentAttemptIdx = max(0, attempts.count - 1)
          } label: {
            Label("Browse Manually", systemImage: "safari")
              .padding(.horizontal, 16).padding(.vertical, 10)
              .background(Color.white.opacity(0.08), in: Capsule())
              .foregroundStyle(.white.opacity(0.8))
          }
        }
      }
      .padding(.top, 4)
    }
    .padding(.horizontal, 24)
  }

  // Build an AVPlayer that carries the WebView's cookies + UA/Referer so auth
  // tokens established during scraping are forwarded on every segment request.
  private func makePlayer(url: URL, cookies: [HTTPCookie], referer: URL) -> AVPlayer {
    var headers = HTTPCookie.requestHeaderFields(with: cookies)
    headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    headers["Referer"]    = referer.absoluteString
    headers["Origin"]     = (referer.scheme ?? "https") + "://" + (referer.host ?? "")
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    return AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }
}

// MARK: - Multi-source searching overlay

/// v2.24: shown while PlayerView is iterating through `game.streamURLs`
/// candidates. Replaces the v2.21–v2.23 single-source spinner. Updates
/// per attempt so the user understands work is happening.
private struct StreamSearchingOverlay: View {
  let attemptIndex: Int
  let totalAttempts: Int
  let sourceName: String
  /// v2.29: when > 0, overlay is in the parallel-search phase
  /// ("Searching sources… looking through N sources"). When 0,
  /// it's the sequential-attempt phase.
  let searchingCount: Int
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
        Image(systemName: searchingCount > 0
              ? "magnifyingglass"
              : "antenna.radiowaves.left.and.right")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(.white.opacity(0.85))
      }
      Text(searchingCount > 0 ? "Searching sources…" : "Checking sources…")
        .font(.headline)
        .foregroundStyle(.white)
      Text(searchingCount > 0
           ? "Looking through \(searchingCount) source\(searchingCount == 1 ? "" : "s") for this game"
           : (totalAttempts > 1
              ? "\(sourceName) (\(attemptIndex + 1) of \(totalAttempts))"
              : sourceName))
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.6))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
    }
    .onAppear { pulse = true }
  }
}

// MARK: - Loading overlay

private struct StreamLoadingView: View {
  @State private var pulse = false

  var body: some View {
    VStack(spacing: 20) {
      ZStack {
        Circle()
          .fill(Color.white.opacity(0.06))
          .frame(width: 80, height: 80)
          .scaleEffect(pulse ? 1.25 : 1.0)
          .opacity(pulse ? 0 : 0.6)
          .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
        Image(systemName: "play.tv")
          .font(.system(size: 32, weight: .medium))
          .foregroundStyle(.white.opacity(0.85))
      }
      Text("Finding stream…")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.5))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
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

// MARK: - WebKit stream view with auto-play + m3u8 interception

struct StreamWebView: UIViewRepresentable {
  let url: URL
  let ruleList: WKContentRuleList?
  var onStreamURLFound: ((URL, [HTTPCookie]) -> Void)? = nil
  /// Browse mode: allows cross-domain link navigation and redirects window.open() into
  /// the same WebView instead of suppressing it. Used by BrowseView for custom sources.
  var browseMode: Bool = false
  /// v2.31: target Game when this WebView is auto-resolving a stream
  /// for a specific tap. Drives URL fingerprint scoring (team slugs in
  /// path), DOM scoring (team names in parent text), and target-game-
  /// aware click steering (only click mirrors inside the matched card).
  /// nil for BrowseView's exploration mode.
  var targetGame: Game? = nil
  /// v2.31: sourceID for the source whose pages we're loading. Lets
  /// the Coordinator look up known-good hosts from the learning store
  /// (boosts L1) and record successful contextFingerprints on commit.
  var sourceID: String? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onStreamURLFound: onStreamURLFound,
      browseMode: browseMode,
      targetGame: targetGame,
      sourceID: sourceID,
      baseURL: url
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []

    if let ruleList { config.userContentController.add(ruleList) }

    let proxy = WeakScriptProxy(delegate: context.coordinator)
    config.userContentController.add(proxy, name: "streamURL")

    let popupJS = browseMode ? Self.popupRedirectJS : Self.popupSuppressJS
    config.userContentController.addUserScript(WKUserScript(
      source: popupJS, injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))
    // v2.31: target-game slug config — read by the shim's
    // selectTargetGameCard() to scope mirror-clicking to the card
    // matching the user's tap. nil game produces an empty config that
    // the shim treats as "no target — fall back to generic clicking".
    let slugScript = Self.slugConfigJS(for: targetGame)
    config.userContentController.addUserScript(WKUserScript(
      source: slugScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))
    config.userContentController.addUserScript(WKUserScript(
      source: Self.autoPlayAndInterceptJS, injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))

    // Inject stored credentials if available for this domain
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

    var request = URLRequest(url: url)
    request.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent"
    )
    let referer = url.scheme.map { "\($0)://\(url.host ?? "")" } ?? "https://buffstreams.plus"
    request.setValue(referer, forHTTPHeaderField: "Referer")
    webView.load(request)
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  // MARK: JS Payloads

  // Standard mode: suppress all popups (used for BuffStreams / PPV.to where popups are ads)
  static let popupSuppressJS = """
    window.open = function(){return null;};
    window.alert = function(){};
    window.confirm = function(){return false;};
    window.prompt = function(){return '';};
  """

  // Browse mode: redirect window.open() into the same WebView so stream popups work,
  // while still silencing alert/confirm/prompt spam.
  static let popupRedirectJS = """
    window.alert = function(){};
    window.confirm = function(){return false;};
    window.prompt = function(){return '';};
    window.open = function(url){
      if (url && typeof url === 'string' && url.indexOf('http') === 0) {
        window.location.href = url;
      }
      return null;
    };
  """

  // v2.31: builds the slug-config snippet injected before the main shim.
  // The shim reads `window.__sc_target` to scope mirror clicking to the
  // card whose innerText matches the user's tapped Game. nil → empty
  // target, shim falls back to generic clicking unchanged.
  static func slugConfigJS(for game: Game?) -> String {
    func slug(_ s: String) -> String {
      let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                             locale: .current)
      let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789- ")
      let scalars = folded.unicodeScalars.filter { allowed.contains($0) }
      let stripped = String(String.UnicodeScalarView(scalars))
      let collapsed = stripped.replacingOccurrences(
        of: "[ ]+", with: "-", options: .regularExpression
      )
      return collapsed
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .replacingOccurrences(of: "'", with: "\\'")
    }
    guard let g = game else { return "window.__sc_target = null;" }
    return "window.__sc_target = {home: '\(slug(g.homeTeam))', away: '\(slug(g.awayTeam))'};"
  }

  // v2.31 shim. Every URL the page surfaces now posts a structured
  // JSON payload: {url, kind, originHost, parentText, iframeSrc,
  // hasLiveBadge, viewerCount}. Native side decodes, scores, and
  // accumulates into a CandidatePool (see CandidateScorer.swift)
  // rather than committing first-playable. Source-agnostic — no
  // site-specific knowledge in here.
  static let autoPlayAndInterceptJS = """
    (function(){
      'use strict';
      var _r = {};
      var _currentMirrorEl = null;
      var _mirrorClickAt = 0;

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

      // ---------- DOM context harvest (L3) ----------
      function harvestContext(element) {
        var ctx = { parentText: '', iframeSrc: null, hasLiveBadge: false, viewerCount: null };
        if (!element || typeof element.parentElement === 'undefined') return ctx;
        var anc = element;
        var texts = [];
        for (var i = 0; i < 6 && anc; i++) {
          var raw = '';
          try { raw = (anc.innerText || anc.textContent || ''); } catch(e){}
          if (raw && raw.length < 2000) texts.push(raw.toLowerCase().slice(0, 300));
          var cls = '';
          try { cls = (anc.className || '').toString().toLowerCase(); } catch(e){}
          if (cls.indexOf('live') !== -1 || /\\blive\\b/i.test(raw)) ctx.hasLiveBadge = true;
          if (ctx.viewerCount === null) {
            var v = raw.match(/(\\d+(?:\\.\\d+)?)([Kk]?)\\s*(viewers?|watching|online)/i);
            if (v) {
              var n = parseFloat(v[1]);
              if (v[2]) n *= 1000;
              ctx.viewerCount = Math.floor(n);
            }
          }
          if (anc.tagName === 'IFRAME') {
            try { ctx.iframeSrc = anc.src || null; } catch(e){}
          }
          anc = anc.parentElement;
        }
        ctx.parentText = texts.join(' | ').slice(0, 500);
        return ctx;
      }

      // ---------- Report (structured payload) ----------
      function report(url, kind, element) {
        if (!url || typeof url !== 'string') return;
        var clean = url.trim();
        if (!clean || _r[clean] || !isStreamURL(clean)) return;
        _r[clean] = 1;
        var k = kind || 'unknown';
        // Attribute URLs to recent mirror click when shim has no specific element.
        if (!element && _currentMirrorEl && (Date.now() - _mirrorClickAt) < 4000) {
          element = _currentMirrorEl;
          if (k === 'xhr' || k === 'fetch' || k === 'iframeSrc' || k === 'unknown') {
            k = 'mirrorClick';
          }
        }
        var ctx = harvestContext(element);
        ctx.url = clean;
        ctx.kind = k;
        ctx.originHost = location.host || '';
        try { window.webkit.messageHandlers.streamURL.postMessage(JSON.stringify(ctx)); } catch(e){}
      }

      // ---------- Network interception ----------
      var xhrOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        if (typeof u === 'string') report(u, 'xhr', null);
        var self = this;
        var origOnRS = null;
        Object.defineProperty(self, 'onreadystatechange', {
          get: function() { return origOnRS; },
          set: function(fn) {
            origOnRS = function() {
              if (self.readyState === 4 && self.responseURL) report(self.responseURL, 'xhr', null);
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
          if (typeof arg === 'string') report(arg, 'fetch', null);
          else if (arg && typeof arg.url === 'string') report(arg.url, 'fetch', null);
          var p = _f.apply(this, arguments);
          if (p && typeof p.then === 'function') {
            p.then(function(resp) {
              if (resp && resp.url) report(resp.url, 'fetch', null);
            }).catch(function(){});
          }
          return p;
        };
      }

      var OrigWS = window.WebSocket;
      if (OrigWS) {
        window.WebSocket = function(url, proto) {
          report(url, 'websocket', null);
          var ws = proto ? new OrigWS(url, proto) : new OrigWS(url);
          var origOnMsg = null;
          Object.defineProperty(ws, 'onmessage', {
            get: function() { return origOnMsg; },
            set: function(fn) {
              origOnMsg = function(evt) {
                if (evt && typeof evt.data === 'string') report(evt.data, 'websocket', null);
                if (fn) fn.apply(ws, arguments);
              };
            },
            configurable: true
          });
          ws.addEventListener('message', function(evt) {
            if (evt && typeof evt.data === 'string') report(evt.data, 'websocket', null);
          });
          return ws;
        };
        window.WebSocket.prototype = OrigWS.prototype;
        window.WebSocket.CONNECTING = OrigWS.CONNECTING;
        window.WebSocket.OPEN = OrigWS.OPEN;
        window.WebSocket.CLOSING = OrigWS.CLOSING;
        window.WebSocket.CLOSED = OrigWS.CLOSED;
      }

      // ---------- DOM element interception ----------
      (function(){
        var desc = Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'src');
        if (desc && desc.set) {
          Object.defineProperty(HTMLVideoElement.prototype, 'src', {
            enumerable: desc.enumerable, configurable: desc.configurable,
            get: desc.get,
            set: function(val) { report(val, 'videoElement', this); desc.set.call(this, val); }
          });
        }
      })();
      (function(){
        var desc = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
        if (desc && desc.set) {
          Object.defineProperty(HTMLSourceElement.prototype, 'src', {
            enumerable: desc.enumerable, configurable: desc.configurable,
            get: desc.get,
            set: function(val) { report(val, 'videoElement', this); desc.set.call(this, val); }
          });
        }
      })();
      var origSetAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(name, val) {
        if ((name === 'src' || name === 'data-src') &&
            (this.tagName === 'VIDEO' || this.tagName === 'SOURCE')) {
          report(val, 'videoElement', this);
        }
        return origSetAttr.apply(this, arguments);
      };

      // ---------- Inline script + meta scanning ----------
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
            if (url.indexOf('http') !== -1) report(url, 'scriptRegex', null);
          });
          var jwPatterns = [/['"]?(?:file|src)['"]?\\s*:\\s*['"]([^'"]{10,})['"]/g];
          jwPatterns.forEach(function(rx) {
            var m;
            while ((m = rx.exec(c)) !== null) { report(m[1], 'scriptRegex', null); }
          });
          var hlsLoad = c.match(/(?:loadSource|attachMedia|src)\\s*\\(\\s*['"]([^'"]{10,})['"]/g) || [];
          hlsLoad.forEach(function(m) {
            var url = m.replace(/.*['"]([^'"]+)['"].*/, '$1');
            report(url, 'scriptRegex', null);
          });
          var jsonPatterns = /['"](?:url|source|stream|hls|hlsUrl|streamUrl|m3u8|manifestUrl)['"]\\s*:\\s*['"]([^'"]{10,})['"]/g;
          var m2;
          while ((m2 = jsonPatterns.exec(c)) !== null) { report(m2[1], 'scriptRegex', null); }
          var b64 = c.match(/atob\\s*\\(\\s*['"]([A-Za-z0-9+\\/=]{20,})['"]\\s*\\)/g) || [];
          b64.forEach(function(match) {
            var inner = match.replace(/^atob\\s*\\(\\s*['"]/, '').replace(/['"]\\s*\\)$/, '');
            var d = decodeAtob(inner);
            if (d) report(d, 'scriptRegex', null);
          });
          var unescaped = c.replace(/\\\\u([0-9a-fA-F]{4})/g, function(_, h) {
            return String.fromCharCode(parseInt(h, 16));
          });
          if (unescaped !== c) {
            var escMatches = unescaped.match(/https?:\\/\\/[^\\s'"<>]{10,}/g) || [];
            escMatches.forEach(function(u) { report(u, 'scriptRegex', null); });
          }
        });
        document.querySelectorAll('meta[property="og:video"], meta[name="twitter:player:stream"]')
          .forEach(function(m) {
            var c = m.getAttribute('content');
            if (c) report(c, 'metaTag', m);
          });
      }

      // ---------- Target-game card selection (L4) ----------
      function selectTargetGameCard() {
        if (!window.__sc_target) return null;
        var home = (window.__sc_target.home || '').toLowerCase();
        var away = (window.__sc_target.away || '').toLowerCase();
        if (!home || !away) return null;
        function tokens(slug) {
          var t = [];
          if (slug.length >= 4) t.push(slug);
          slug.split('-').forEach(function(w) { if (w.length >= 4) t.push(w); });
          return t;
        }
        var ht = tokens(home);
        var at = tokens(away);
        if (!ht.length || !at.length) return null;
        function matches(text) {
          var lower = text.toLowerCase();
          var h = ht.some(function(t) { return lower.indexOf(t) !== -1; });
          var a = at.some(function(t) { return lower.indexOf(t) !== -1; });
          return h && a;
        }
        var selectors = [
          '[class*="game"]', '[class*="card"]', '[class*="match"]',
          '[class*="event"]', '[class*="fixture"]', '[class*="row"]',
          'article', 'li'
        ];
        var seen = [];
        for (var s = 0; s < selectors.length; s++) {
          var els;
          try { els = document.querySelectorAll(selectors[s]); } catch(e){ continue; }
          for (var i = 0; i < els.length; i++) {
            var el = els[i];
            if (seen.indexOf(el) !== -1) continue;
            seen.push(el);
            var t = '';
            try { t = (el.innerText || el.textContent || ''); } catch(e){}
            if (t.length < 4 || t.length > 1500) continue;
            if (matches(t)) return el;
          }
        }
        return null;
      }

      // ---------- DOM scan + interaction ----------
      function scan() {
        document.querySelectorAll('video, source').forEach(function(el) {
          [el.src, el.currentSrc, el.getAttribute('src'), el.dataset && el.dataset.src].forEach(function(s) {
            if (s) report(s, 'videoElement', el);
          });
        });
        scanScripts();
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });

        // Mirror clicker — v2.31 scopes to the target-game card when found,
        // so we don't click ad mirrors that belong to other games on the page.
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
        var targetCard = selectTargetGameCard();
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
                if (t.indexOf('NOIOS') !== -1 || t.indexOf('NO-IOS') !== -1) {
                  noIOS = true; break;
                }
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
            if (!el._sc_clicked) {
              el._sc_clicked = 1;
              _currentMirrorEl = el;
              _mirrorClickAt = Date.now();
              try { el.click(); } catch(e){}
            }
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
              if (src) report(src, 'iframeSrc', node);
            }
            if (node.tagName === 'SCRIPT' && !node.src) {
              setTimeout(scanScripts, 200);
            }
          });
        });
      }).observe(document.documentElement || document, {childList: true, subtree: true, attributes: true});

      [100, 500, 1000, 2000, 3000, 5000, 8000, 12000, 18000].forEach(function(t) {
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

  // MARK: Coordinator

  /// v2.31 Coordinator. Replaces the v2.30 "first URL that passes
  /// AVURLAsset.isPlayable wins" decision with a structured payload +
  /// CandidatePool flow:
  /// 1. JS-shim posts JSON for every observed URL with DOM context.
  /// 2. Coordinator decodes, builds a `Candidate`, and ingests into
  ///    its `CandidatePool` (lazily initialized on first message).
  /// 3. Pool runs L1 fingerprint + L2 manifest fetch + L5 segment
  ///    probe in parallel for each non-rejected candidate, accumulates
  ///    for up to 6 s, then commits the highest-scored playable one.
  /// 4. When the pool fires its commit callback, we harvest WebView
  ///    cookies and hand the URL to `onStreamURLFound`.
  ///
  /// BrowseView (which passes targetGame=nil and browseMode=true) uses
  /// a short accumulation window so playback feels snappy; PlayerView's
  /// auto-resolve uses the full 6 s window for better selection.
  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?
    let browseMode: Bool
    let targetGame: Game?
    let sourceID: String?
    let baseURL: URL

    private var found = false
    private var pool: CandidatePool?
    weak var webView: WKWebView?

    init(onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?,
         browseMode: Bool,
         targetGame: Game?,
         sourceID: String?,
         baseURL: URL) {
      self.onStreamURLFound = onStreamURLFound
      self.browseMode = browseMode
      self.targetGame = targetGame
      self.sourceID = sourceID
      self.baseURL = baseURL
    }

    // MARK: - Pool lifecycle

    @MainActor
    private func ensurePool() -> CandidatePool {
      if let pool { return pool }
      // Build the headers that AVPlayer will use, so probe pass == play pass.
      let scheme = baseURL.scheme ?? "https"
      let host = baseURL.host ?? ""
      let referer = "\(scheme)://\(host)"
      let headers: [String: String] = [
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Referer": referer,
        "Origin": referer,
      ]
      // Known-good hosts: union of the source's baseURL host (implicit)
      // and any stream-host that has actually played for this source
      // before (recorded by SourceLearningStore.recordPlaybackHost on
      // each successful first-frame). Self-populating — no hardcoded
      // CDN lists.
      let knownGoodHosts: Set<String> = {
        var s: Set<String> = []
        if let bh = baseURL.host?.lowercased() { s.insert(bh) }
        if let sid = sourceID {
          s.formUnion(SourceLearningStore.shared.playbackHosts(for: sid))
        }
        return s
      }()
      let window: TimeInterval = browseMode ? 1.5 : 6.0
      let hardDeadline: TimeInterval = browseMode ? 4.0 : 10.0
      let p = CandidatePool(
        targetGame: targetGame,
        sourceID: sourceID ?? "",
        probeHeaders: headers,
        knownGoodHosts: knownGoodHosts,
        accumulationWindow: window,
        hardDeadline: hardDeadline
      ) { [weak self] candidate in
        guard let self else { return }
        guard let cand = candidate else {
          // No playable candidate within budget. Don't fire callback —
          // the outer PlayerView per-source timer will advance to the
          // next attempt naturally.
          return
        }
        self.commitURL(cand.url)
      }
      self.pool = p
      return p
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
      guard !found else { return }
      // Two payload formats supported for forward-compat: structured
      // JSON (v2.31) and bare URL string (legacy — should not occur
      // since we shipped the new shim, but defensively handled).
      var url: URL?
      var context = DOMContext.unknown
      if let s = message.body as? String {
        if let data = s.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ShimPayload.self, from: data) {
          url = URL(string: payload.url)
          context = DOMContext(
            kind: DOMContext.Kind(rawValue: payload.kind) ?? .unknown,
            originHost: payload.originHost,
            parentText: payload.parentText ?? "",
            iframeSrc: payload.iframeSrc,
            hasLiveBadge: payload.hasLiveBadge ?? false,
            viewerCount: payload.viewerCount
          )
        } else {
          url = URL(string: s)
        }
      }
      guard let u = url else { return }
      Task { @MainActor in
        guard !self.found else { return }
        _ = self.ensurePool().ingest(url: u, context: context)
      }
    }

    /// Minimal shape mirroring what the JS-shim posts. Optional fields
    /// degrade gracefully when older shims (or other call sites) post
    /// less data.
    private struct ShimPayload: Decodable {
      let url: String
      let kind: String
      let originHost: String?
      let parentText: String?
      let iframeSrc: String?
      let hasLiveBadge: Bool?
      let viewerCount: Int?
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
      if browseMode, let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if let url = action.request.url {
        let u = url.absoluteString.lowercased()
        if u.contains(".m3u8") || u.contains(".mpd") {
          ingestFromNavigation(url, kind: .navigation)
          decisionHandler(.cancel)
          return
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

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
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
        ingestFromNavigation(url, kind: .mimeSniff)
        return
      }
      decisionHandler(.allow)
    }

    /// Funnel for URLs surfaced by native navigation hooks (not the JS
    /// shim). These have no DOM context — we mark the kind and let L1/L2
    /// scoring do the rest.
    private func ingestFromNavigation(_ url: URL, kind: DOMContext.Kind) {
      let host = baseURL.host
      let ctx = DOMContext(
        kind: kind, originHost: host, parentText: "",
        iframeSrc: nil, hasLiveBadge: false, viewerCount: nil
      )
      Task { @MainActor in
        guard !self.found else { return }
        _ = self.ensurePool().ingest(url: url, context: ctx)
      }
    }

    // MARK: - Commit

    private func commitURL(_ url: URL) {
      guard !found else { return }
      found = true
      if let store = webView?.configuration.websiteDataStore.httpCookieStore {
        store.getAllCookies { cookies in
          DispatchQueue.main.async { self.onStreamURLFound?(url, cookies) }
        }
      } else {
        DispatchQueue.main.async { self.onStreamURLFound?(url, []) }
      }
    }
  }
}

// Breaks the WKUserContentController → Coordinator retain cycle
final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
  weak var delegate: WKScriptMessageHandler?
  init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    delegate?.userContentController(controller, didReceive: message)
  }
}
