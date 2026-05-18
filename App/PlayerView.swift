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
            StreamWebView(url: current.pageURL, ruleList: ruleList) { streamURL, cookies in
              Task { @MainActor in
                let p = makePlayer(url: streamURL, cookies: cookies, referer: current.pageURL)
                avPlayer = p
                p.play()
                // v2.30: success recording. The source that produced this
                // stream gets credit in SourceHealth, becomes the league's
                // last-successful preference, teaches SourceLearningStore
                // about its URL pattern, and clears any prior failures.
                recordSuccess(attempt: current)
              }
            }
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

  /// v2.30: record success across all relevant stores when the WebView
  /// JS-intercept successfully hands AVPlayer a playable URL. Called
  /// from the StreamWebView callback once on first successful stream.
  private func recordSuccess(attempt: SourceAttempt) {
    let gameKey = GameKey.make(for: game)
    let sid = attempt.sourceID
    SourceHealth.shared.recordSuccess(sourceID: sid)
    SourcePreference.shared.recordSuccess(league: game.league, sourceID: sid)
    SourceLearningStore.shared.recordSuccess(
      sourceID: sid, gamePageURL: attempt.pageURL, game: game
    )
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

  func makeCoordinator() -> Coordinator { Coordinator(onStreamURLFound: onStreamURLFound, browseMode: browseMode) }

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

  static let autoPlayAndInterceptJS = """
    (function(){
      'use strict';
      var _r = {};

      // ---------- URL matching ----------
      function isStreamURL(u) {
        if (!u || typeof u !== 'string') return false;
        if (u.indexOf('blob:') === 0) return false;         // blob URLs are opaque MSE buffers
        var l = u.toLowerCase().split('?')[0];               // strip query string for extension check
        if (l.indexOf('.m3u8') !== -1) return true;
        if (l.indexOf('.mpd')  !== -1) return true;
        // Common HLS/DASH manifest path segments without extension
        var pathPatterns = ['/hls/', '/live/', '/stream/', '/chunklist', '/playlist',
                            '/manifest', '/index.m3u', '/master.m3u'];
        for (var i = 0; i < pathPatterns.length; i++) {
          if (l.indexOf(pathPatterns[i]) !== -1) return true;
        }
        return false;
      }

      function report(url) {
        if (!url || typeof url !== 'string') return;
        var clean = url.trim();
        if (!clean || _r[clean] || !isStreamURL(clean)) return;
        _r[clean] = 1;
        try { window.webkit.messageHandlers.streamURL.postMessage(clean); } catch(e){}
      }

      // ---------- Network interception ----------

      // XHR — intercept both open() URL and the final responseURL after redirects
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

      // fetch — intercept request URL and resolved response URL
      if (window.fetch) {
        var _f = window.fetch;
        window.fetch = function() {
          var arg = arguments[0];
          if (typeof arg === 'string') report(arg);
          else if (arg && typeof arg.url === 'string') report(arg.url);
          var p = _f.apply(this, arguments);
          if (p && typeof p.then === 'function') {
            p.then(function(resp) {
              if (resp && resp.url) report(resp.url);
            }).catch(function(){});
          }
          return p;
        };
      }

      // WebSocket — some sites deliver the stream URL or auth token via WS;
      // watch both the WS endpoint URL and any text messages that look like stream URLs.
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

      // ---------- DOM element interception ----------

      // HTMLVideoElement.src setter
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

      // HTMLSourceElement.src setter — catches <source src="...m3u8"> added dynamically
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

      // setAttribute — catches el.setAttribute('src', '...') on video/source
      var origSetAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(name, val) {
        if ((name === 'src' || name === 'data-src') &&
            (this.tagName === 'VIDEO' || this.tagName === 'SOURCE')) {
          report(val);
        }
        return origSetAttr.apply(this, arguments);
      };

      // ---------- Inline script scanning (yt-dlp-style extractors) ----------

      function decodeAtob(str) {
        try { var d = atob(str); if (d.indexOf('http') === 0) return d; } catch(e){}
        return null;
      }

      function scanScripts() {
        document.querySelectorAll('script:not([src])').forEach(function(s) {
          var c = s.innerHTML.replace(/[\\r\\n\\t]+/g, ' ');

          // 1. Quoted stream URL anywhere in script text
          var urlMatches = c.match(/['"`]([^'"`\\s]{10,}(?:\\.m3u8|\\.mpd)[^'"`\\s]*?)['"`]/g) || [];
          urlMatches.forEach(function(m) {
            var url = m.replace(/^['"`]|['"`]$/g, '');
            if (url.indexOf('http') !== -1) report(url);
          });

          // 2. JW Player — jwplayer().setup({file:'url'}) or sources:[{file:'url'}]
          //    Also catches the common {src:'...'} variant.
          var jwPatterns = [
            /['"]?(?:file|src)['"]?\\s*:\\s*['"]([^'"]{10,})['"]/g
          ];
          jwPatterns.forEach(function(rx) {
            var m;
            while ((m = rx.exec(c)) !== null) { report(m[1]); }
          });

          // 3. Video.js / hls.js — Hls.loadSource('url') or videojs setup sources
          var hlsLoad = c.match(/(?:loadSource|attachMedia|src)\\s*\\(\\s*['"]([^'"]{10,})['"]/g) || [];
          hlsLoad.forEach(function(m) {
            var url = m.replace(/.*['"]([^'"]+)['"].*/, '$1');
            report(url);
          });

          // 4. Generic JSON-like {url:'...', source:'...', stream:'...'} patterns
          var jsonPatterns = /['"](?:url|source|stream|hls|hlsUrl|streamUrl|m3u8|manifestUrl)['"]\\s*:\\s*['"]([^'"]{10,})['"]/g;
          var m2;
          while ((m2 = jsonPatterns.exec(c)) !== null) { report(m2[1]); }

          // 5. atob() encoded URLs
          var b64 = c.match(/atob\\s*\\(\\s*['"]([A-Za-z0-9+\\/=]{20,})['"]\\s*\\)/g) || [];
          b64.forEach(function(match) {
            var inner = match.replace(/^atob\\s*\\(\\s*['"]/, '').replace(/['"]\\s*\\)$/, '');
            var d = decodeAtob(inner);
            if (d) report(d);
          });

          // 6. Escaped Unicode URLs (some obfuscated scripts use \\u0068ttp...)
          var unescaped = c.replace(/\\\\u([0-9a-fA-F]{4})/g, function(_, h) {
            return String.fromCharCode(parseInt(h, 16));
          });
          if (unescaped !== c) {
            var escMatches = unescaped.match(/https?:\\/\\/[^\\s'"<>]{10,}/g) || [];
            escMatches.forEach(function(u) { report(u); });
          }
        });

        // Also check <meta> og:video and twitter:player content attributes
        document.querySelectorAll('meta[property="og:video"], meta[name="twitter:player:stream"]')
          .forEach(function(m) { var c = m.getAttribute('content'); if (c) report(c); });
      }

      // ---------- DOM scan + interaction ----------

      function scan() {
        // video/source elements already in DOM
        document.querySelectorAll('video, source').forEach(function(el) {
          [el.src, el.currentSrc, el.getAttribute('src'), el.dataset && el.dataset.src].forEach(function(s) {
            if (s) report(s);
          });
        });

        // Inline script extraction (yt-dlp-style)
        scanScripts();

        // Auto-play paused videos
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });

        // Click play / mirror buttons — extended selector list covering JW,
        // Video.js, Plyr, Flowplayer, and aggregator mirror lists. Aggregator
        // sites (bintv → sources.bintvs.fun) expose multiple mirrors per
        // match, some labeled "NO IOS" because they serve codecs/DRM that
        // AVPlayer can't play. Skip those (their ancestor text contains the
        // marker) and click the remainder sequentially with a 2.5s stagger
        // so each iframe has time to yield a stream URL before the next
        // overwrites it. Native runs an AVURLAsset playability probe on each
        // observed URL and keeps the first that actually plays.
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
        var candidates = [];
        var seenEls = [];
        mirrorSelectors.forEach(function(sel) {
          try {
            document.querySelectorAll(sel).forEach(function(el) {
              if (el._sc_clicked || seenEls.indexOf(el) !== -1) return;
              // Walk up to 6 ancestors looking for a "NO IOS" / "NO-IOS"
              // marker. The label can appear on the button itself, its row
              // container, or an explanatory chip nearby.
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
              if (noIOS) { el._sc_clicked = 1; return; }  // skip
              candidates.push(el);
            });
          } catch(e){}
        });
        candidates.forEach(function(el, i) {
          setTimeout(function() {
            if (!el._sc_clicked) { el._sc_clicked = 1; try { el.click(); } catch(e){} }
          }, i * 2500);
        });

        // Remove ad overlays — fixed/absolute elements with z-index > 999 that aren't video
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

      // Watch DOM mutations for dynamically injected players/iframes/scripts
      new MutationObserver(function(mutations) {
        scan();
        // Also watch for iframes being added — if the iframe src itself is a stream URL, grab it
        mutations.forEach(function(mut) {
          mut.addedNodes.forEach(function(node) {
            if (node.tagName === 'IFRAME') {
              var src = node.src || node.getAttribute('src') || '';
              report(src);  // catches rare cases where iframe src IS the stream
            }
            if (node.tagName === 'SCRIPT' && !node.src) {
              // New inline script added — scan after it executes
              setTimeout(scanScripts, 200);
            }
          });
        });
      }).observe(document.documentElement || document, {childList: true, subtree: true, attributes: true});

      // Extended timeout ladder — sports sites often load in 10-15 s bursts
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

  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?
    let browseMode: Bool
    private var found = false
    /// Stream URLs already observed this session, so duplicate `report()`
    /// calls from multiple intercept paths (XHR, fetch, navigation policy,
    /// MIME sniff, DOM scrape) don't queue redundant playability probes.
    private var seenURLs = Set<String>()
    /// First observed URL — used as a last-resort fallback if every probe
    /// rejects playability (better to attempt playback than to leave the
    /// user staring at the loading spinner for 22 s).
    private var firstObservedURL: URL?
    weak var webView: WKWebView?

    init(onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?, browseMode: Bool) {
      self.onStreamURLFound = onStreamURLFound
      self.browseMode = browseMode
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard let urlString = message.body as? String,
            let url = URL(string: urlString) else { return }
      report(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      // In browse mode, load popup URLs in the same WebView instead of suppressing.
      if browseMode, let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if let url = action.request.url {
        // If the page is navigating directly TO a stream URL (e.g. a redirect chain
        // that ends at an .m3u8), intercept it before the WebView tries to load it.
        let u = url.absoluteString.lowercased()
        if u.contains(".m3u8") || u.contains(".mpd") {
          if !found { report(url) }
          decisionHandler(.cancel)
          return
        }
      }
      // In browse mode allow everything so users can navigate naturally through the site.
      // In standard mode, block cross-domain link taps (these are almost always ad redirects).
      if !browseMode,
         action.navigationType == .linkActivated,
         let host = action.request.url?.host,
         host != webView.url?.host {
        decisionHandler(.cancel); return
      }
      decisionHandler(.allow)
    }

    // Intercept responses whose MIME type identifies them as HLS/DASH manifests,
    // even when the URL itself has no recognisable extension (e.g. /manifest or /stream).
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
      let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
      let streamMimes = ["application/x-mpegurl", "application/vnd.apple.mpegurl",
                         "application/dash+xml", "video/mp2t", "application/octet-stream"]
      // Only treat octet-stream as a stream if the URL also looks like one
      let isStreamMime = streamMimes.dropLast().contains(where: { mime.contains($0) })
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
        // Fallback safety net: 10s after the first URL is observed, commit
        // it even if no probe has passed. AVURLAsset.isPlayable can return
        // false for transient reasons (CORS preflight, slow response, etc.)
        // — better to attempt playback than to leave the user on the
        // spinner waiting for the 22s outer timeout to reveal the raw page.
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: 10_000_000_000)
          await MainActor.run { self?.commitFallbackIfNeeded() }
        }
      }
      // Probe playability before committing. Aggregator pages (bintv.net via
      // sources.bintvs.fun) expose multiple mirrors per match; AVPlayer can
      // only play a subset on iOS. Without this probe we'd hand AVPlayer the
      // first observed `.m3u8`, which is a coin flip when several arrive in
      // rapid succession. Probes run concurrently — first to pass wins.
      Task { [weak self] in
        let playable = await Self.probePlayability(url)
        await MainActor.run {
          guard let self, !self.found else { return }
          // Reject only if explicitly unplayable. AVURLAsset.load(.isPlayable)
          // also returns false for transient network errors mid-probe — in
          // those cases we'd rather attempt playback than leave the user
          // stranded, so the 22s timeout's fallback URL handles that case.
          guard playable else { return }
          self.commitURL(url)
        }
      }
    }

    /// Called from `PlayerView.task` after the 22s no-stream timeout if no
    /// probe-passing URL was committed. Hands AVPlayer the first observed
    /// `.m3u8` even if its playability probe failed/timed out — strictly
    /// better than leaving the user on the spinner since AVPlayer may
    /// succeed where the probe didn't (e.g. transient probe network error).
    func commitFallbackIfNeeded() {
      guard !found, let url = firstObservedURL else { return }
      commitURL(url)
    }

    private func commitURL(_ url: URL) {
      found = true
      // Harvest cookies from the WebView session so AVPlayer can authenticate
      if let store = webView?.configuration.websiteDataStore.httpCookieStore {
        store.getAllCookies { cookies in
          DispatchQueue.main.async { self.onStreamURLFound?(url, cookies) }
        }
      } else {
        DispatchQueue.main.async { self.onStreamURLFound?(url, []) }
      }
    }

    /// Quick playability probe via `AVURLAsset.load(.isPlayable)`. Capped at
    /// 4 s so a non-responsive mirror doesn't hold up trying the next one.
    /// Skips probing for non-HLS/DASH URLs (the matcher's path-pattern
    /// branch can yield URLs that aren't actually manifests).
    private static func probePlayability(_ url: URL) async -> Bool {
      let lower = url.absoluteString.lowercased()
      // Only probe what AVURLAsset can actually evaluate. For pattern-only
      // matches (e.g. `/manifest`) without an explicit extension, accept
      // optimistically — probe would likely fail on a redirect anyway.
      let isManifest = lower.contains(".m3u8") || lower.contains(".mpd")
      guard isManifest else { return true }
      var headers: [String: String] = [:]
      headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
      let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          (try? await asset.load(.isPlayable)) ?? false
        }
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

// Breaks the WKUserContentController → Coordinator retain cycle
final class WeakScriptProxy: NSObject, WKScriptMessageHandler {
  weak var delegate: WKScriptMessageHandler?
  init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    delegate?.userContentController(controller, didReceive: message)
  }
}
