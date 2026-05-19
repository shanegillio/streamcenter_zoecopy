import SwiftUI
import WebKit
import AVKit

/// v2.32 simplified: tap a game, walk the attempts list, first URL the
/// shim catches that AVURLAsset says is playable wins. No accumulator,
/// no scoring, no parallel pre-resolve race. ~v2.28 shape with the v2.31
/// target-game-aware card scoping retained because it's tiny and useful.
struct PlayerView: View {
  let game: Game
  @Environment(SourceRegistry.self) private var registry
  @State private var ruleList: WKContentRuleList? = nil
  @State private var avPlayer: AVPlayer? = nil
  @State private var rulesReady = false
  @State private var attempts: [SourceAttempt] = []
  @State private var currentAttemptIdx: Int = 0
  @State private var allFailed: Bool = false
  /// Per-source budget. 8s — long enough for a homepage + CF clearance
  /// + the JS-intercept layer to surface a stream URL; short enough that
  /// dead sources fail fast.
  private static let perSourceBudget: TimeInterval = 8
  /// Revealed when user hits "Browse Manually" on the retry UI.
  @State private var showWebFallback = false

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
            retryUI
          } else if !attempts.isEmpty, currentAttemptIdx < attempts.count {
            let current = attempts[currentAttemptIdx]
            StreamWebView(
              url: current.pageURL,
              ruleList: ruleList,
              onStreamURLFound: { streamURL, cookies in
                Task { @MainActor in
                  let p = makePlayer(url: streamURL, cookies: cookies, referer: current.pageURL)
                  avPlayer = p
                  p.play()
                  recordSuccess(attempt: current)
                }
              },
              targetGame: game
            )
            .id(current.id)
            .ignoresSafeArea()
            .opacity(showWebFallback ? 1 : 0)
            if !showWebFallback {
              StreamLoadingOverlay(
                attemptIndex: currentAttemptIdx,
                totalAttempts: attempts.count,
                sourceName: sourceName(for: current.sourceID)
              )
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
      while currentAttemptIdx < attempts.count {
        let startedIdx = currentAttemptIdx
        attempts[startedIdx].status = .trying
        SourceHealth.shared.recordAttempt(sourceID: attempts[startedIdx].sourceID)
        try? await Task.sleep(nanoseconds: UInt64(Self.perSourceBudget * 1_000_000_000))
        if avPlayer != nil { return }
        if currentAttemptIdx == startedIdx {
          attempts[startedIdx].status = .failed
          currentAttemptIdx += 1
        }
      }
      if avPlayer == nil {
        allFailed = true
        recordAllFailures()
      }
    }
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

    var built: [SourceAttempt] = []
    for c in game.streamURLs {
      if failureStore.isFailedRecently(gameKey: gameKey, sourceID: c.sourceID) { continue }
      if health.isInParkingCooldown(c.sourceID) { continue }
      built.append(SourceAttempt(sourceID: c.sourceID, pageURL: c.pageURL))
    }
    let preResolvedIDs = Set(game.streamURLs.map(\.sourceID))
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
    if built.isEmpty {
      built.append(SourceAttempt(sourceID: "espn", pageURL: game.pageURL))
    }
    attempts = built
    currentAttemptIdx = 0
    allFailed = false
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
          buildAttempts()
          allFailed = false
          Task {
            while currentAttemptIdx < attempts.count {
              let startedIdx = currentAttemptIdx
              attempts[startedIdx].status = .trying
              SourceHealth.shared.recordAttempt(sourceID: attempts[startedIdx].sourceID)
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

struct StreamWebView: UIViewRepresentable {
  let url: URL
  let ruleList: WKContentRuleList?
  var onStreamURLFound: ((URL, [HTTPCookie]) -> Void)? = nil
  var browseMode: Bool = false
  /// v2.31 retained: when set, the JS-shim scopes mirror-clicking to the
  /// card whose innerText matches both team slugs. The one v2.31 idea
  /// kept because it directly matches the user's mental model and is tiny.
  var targetGame: Game? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(onStreamURLFound: onStreamURLFound, browseMode: browseMode)
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
      if (url && typeof url === 'string' && url.indexOf('http') === 0) {
        window.location.href = url;
      }
      return null;
    };
  """

  /// Sets `window.__sc_target` for selectTargetGameCard in the shim.
  /// nil game → __sc_target=null → shim falls back to generic clicking.
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
    return "window.__sc_target = {home: '\(slug(g.homeTeam))', away: '\(slug(g.awayTeam))'};"
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

      // v2.31 retained: target-game card scoping
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
        var ht = tokens(home), at = tokens(away);
        if (!ht.length || !at.length) return null;
        function matches(text) {
          var lower = text.toLowerCase();
          return ht.some(function(t) { return lower.indexOf(t) !== -1; })
              && at.some(function(t) { return lower.indexOf(t) !== -1; });
        }
        var sels = ['[class*="game"]', '[class*="card"]', '[class*="match"]',
                    '[class*="event"]', '[class*="fixture"]', '[class*="row"]',
                    'article', 'li'];
        var seen = [];
        for (var s = 0; s < sels.length; s++) {
          var els;
          try { els = document.querySelectorAll(sels[s]); } catch(e){ continue; }
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

      function scan() {
        document.querySelectorAll('video, source').forEach(function(el) {
          [el.src, el.currentSrc, el.getAttribute('src'), el.dataset && el.dataset.src].forEach(function(s) {
            if (s) report(s);
          });
        });
        scanScripts();
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });

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
              if (src) report(src);
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

  // MARK: Coordinator (simple — first playable URL wins)

  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let onStreamURLFound: ((URL, [HTTPCookie]) -> Void)?
    let browseMode: Bool
    private var found = false
    private var seenURLs = Set<String>()
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
      if browseMode, let url = navigationAction.request.url {
        webView.load(URLRequest(url: url))
      }
      return nil
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
      Task { [weak self] in
        let playable = await Self.probePlayability(url)
        await MainActor.run {
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

    private static func probePlayability(_ url: URL) async -> Bool {
      let lower = url.absoluteString.lowercased()
      let isManifest = lower.contains(".m3u8") || lower.contains(".mpd")
      guard isManifest else { return true }
      var headers: [String: String] = [:]
      headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
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
