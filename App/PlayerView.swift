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

  func makeCoordinator() -> Coordinator { Coordinator(onStreamURLFound: onStreamURLFound) }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []

    if let ruleList { config.userContentController.add(ruleList) }

    // Weak proxy avoids WKUserContentController retaining Coordinator
    let proxy = WeakScriptProxy(delegate: context.coordinator)
    config.userContentController.add(proxy, name: "streamURL")

    config.userContentController.addUserScript(WKUserScript(
      source: Self.popupSuppressJS, injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))
    config.userContentController.addUserScript(WKUserScript(
      source: Self.autoPlayAndInterceptJS, injectionTime: .atDocumentStart, forMainFrameOnly: false
    ))

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

  static let popupSuppressJS = """
    window.open = function(){return null;};
    window.alert = function(){};
    window.confirm = function(){return false;};
    window.prompt = function(){return '';};
  """

  static let autoPlayAndInterceptJS = """
    (function(){
      'use strict';
      var _r = {};
      function report(url) {
        if (!url || _r[url] || url.indexOf('.m3u8') === -1) return;
        _r[url] = 1;
        try { window.webkit.messageHandlers.streamURL.postMessage(url); } catch(e){}
      }

      // Intercept XHR
      var xhrOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u) {
        if (typeof u === 'string') report(u); return xhrOpen.apply(this, arguments);
      };

      // Intercept fetch
      if (window.fetch) {
        var _f = window.fetch;
        window.fetch = function() {
          if (typeof arguments[0] === 'string') report(arguments[0]);
          return _f.apply(this, arguments);
        };
      }

      function scan() {
        // Check existing video/source elements
        document.querySelectorAll('video, source').forEach(function(el) {
          report(el.src || el.getAttribute('src') || '');
        });
        // Auto-play any video
        document.querySelectorAll('video').forEach(function(v) {
          if (v.paused) v.play().catch(function(){});
        });
        // Click play buttons (common player selectors)
        ['.vjs-big-play-button','.jw-icon-display','.jw-display-icon-display',
         '.plyr__control--overlaid','[data-plyr="play"]','.play-btn','.play_btn',
         '.btn-play','#play','[class*="play-button"]','button[class*="play"]'
        ].forEach(function(sel){
          var el = document.querySelector(sel);
          if (el && !el._az) { el._az = 1; el.click(); }
        });
        // Remove fixed/absolute ad overlays above z 999
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
      [100,500,1000,2000,3000,5000].forEach(function(t){ setTimeout(scan, t); });
    })();
  """

  // MARK: Coordinator

  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let onStreamURLFound: ((URL) -> Void)?
    private var found = false

    init(onStreamURLFound: ((URL) -> Void)?) { self.onStreamURLFound = onStreamURLFound }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard !found,
            let urlString = message.body as? String,
            let url = URL(string: urlString) else { return }
      found = true
      DispatchQueue.main.async { self.onStreamURLFound?(url) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if action.navigationType == .linkActivated,
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
