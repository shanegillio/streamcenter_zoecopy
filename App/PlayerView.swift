import SwiftUI
import WebKit
import AVKit

struct PlayerView: View {
  let game: Game
  @State private var ruleList: WKContentRuleList? = nil
  @State private var avPlayer: AVPlayer? = nil
  @State private var rulesReady = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if rulesReady {
        StreamWebView(url: game.pageURL, ruleList: ruleList) { streamURL in
          let p = AVPlayer(url: streamURL)
          avPlayer = p
          p.play()
        }
        .ignoresSafeArea()
        .opacity(avPlayer == nil ? 1 : 0)

        if let avPlayer {
          VideoPlayerView(player: avPlayer)
            .ignoresSafeArea()
        }
      } else {
        ProgressView()
          .tint(.white)
          .scaleEffect(1.5)
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 2) {
          Text(game.title)
            .font(.headline)
            .foregroundStyle(.white)
          Text(game.league.displayName)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        }
      }
    }
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      ruleList = await AdBlockRules.compile()
      rulesReady = true
    }
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
  var onStreamURLFound: ((URL) -> Void)? = nil
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
      function isStreamURL(u) {
        if (!u || typeof u !== 'string') return false;
        var l = u.toLowerCase();
        return l.indexOf('.m3u8') !== -1 || l.indexOf('.mpd') !== -1;
      }
      function report(url) {
        if (!url || _r[url] || !isStreamURL(url)) return;
        _r[url] = 1;
        try { window.webkit.messageHandlers.streamURL.postMessage(url); } catch(e){}
      }

      // Intercept XHR
      var xhrOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        if (typeof u === 'string') report(u);
        return xhrOpen.apply(this, arguments);
      };

      // Intercept fetch
      if (window.fetch) {
        var _f = window.fetch;
        window.fetch = function() {
          var arg = arguments[0];
          if (typeof arg === 'string') report(arg);
          else if (arg && typeof arg === 'object' && arg.url) report(arg.url);
          return _f.apply(this, arguments);
        };
      }

      function scanScripts() {
        // Many sports sites embed the m3u8 URL as a string literal in an inline <script>
        // rather than fetching it via XHR/fetch, so XHR interception alone misses it.
        document.querySelectorAll('script:not([src])').forEach(function(s) {
          var c = s.innerHTML.replace(/[\\r\\n\\t]+/g, ' ');
          // Pattern 1: quoted .m3u8 or .mpd URL
          var m1 = c.match(/['"]([^'"]{8,}(?:\\.m3u8|\\.mpd)[^'"]*)['"]/);
          if (m1 && m1[1].indexOf('http') !== -1) { report(m1[1]); }
          // Pattern 2: base64-encoded URL via atob()
          var b64matches = c.match(/atob\\s*\\(\\s*['"]([A-Za-z0-9+\\/=]{20,})['"]\\s*\\)/g);
          if (b64matches) {
            b64matches.forEach(function(match) {
              try {
                var b64 = match.replace(/^atob\\s*\\(\\s*['"]/, '').replace(/['"]\\s*\\)$/, '');
                var decoded = atob(b64);
                if (decoded.indexOf('http') === 0) report(decoded);
              } catch(e) {}
            });
          }
        });
      }

      function scan() {
        // video / source elements
        document.querySelectorAll('video, source').forEach(function(el) {
          var src = el.src || el.getAttribute('src') || '';
          if (src) report(src);
        });
        // inline scripts (catches string-literal m3u8 URLs)
        scanScripts();
        // auto-play paused videos
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });
        // click common play buttons
        ['.vjs-big-play-button','.jw-icon-display','.jw-display-icon-display',
         '.plyr__control--overlaid','[data-plyr="play"]','.play-btn','.play_btn',
         '.btn-play','#play','[class*="play-button"]','button[class*="play"]'
        ].forEach(function(sel){
          var el = document.querySelector(sel);
          if (el && !el._az) { el._az = 1; el.click(); }
        });
        // remove fixed/absolute ad overlays above z-index 999
        document.querySelectorAll('*').forEach(function(el){
          try {
            var s = window.getComputedStyle(el);
            var z = parseInt(s.zIndex)||0;
            if ((s.position==='fixed'||s.position==='absolute') && z>999 && el.tagName!=='VIDEO'){
              el.style.display='none';
            }
          } catch(e){}
        });
      }

      new MutationObserver(scan).observe(
        document.documentElement || document,
        {childList:true, subtree:true, attributes:true}
      );
      [100,500,1000,2000,3000,5000,8000].forEach(function(t){ setTimeout(scan, t); });
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
    let onStreamURLFound: ((URL) -> Void)?
    let browseMode: Bool
    private var found = false

    init(onStreamURLFound: ((URL) -> Void)?, browseMode: Bool) {
      self.onStreamURLFound = onStreamURLFound
      self.browseMode = browseMode
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard !found,
            let urlString = message.body as? String,
            let url = URL(string: urlString) else { return }
      found = true
      DispatchQueue.main.async { self.onStreamURLFound?(url) }
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
