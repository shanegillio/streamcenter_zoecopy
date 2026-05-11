import SwiftUI
import WebKit
import AVKit

struct PlayerView: View {
  let game: Game
  @State private var streamURL: URL? = nil
  @State private var isExtracting = true
  @State private var player: AVPlayer? = nil
  @State private var ruleList: WKContentRuleList? = nil

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let player {
        VideoPlayerView(player: player)
          .ignoresSafeArea()
      } else if isExtracting {
        VStack(spacing: 16) {
          ProgressView()
            .tint(.white)
            .scaleEffect(1.5)
          Text("Loading stream…")
            .foregroundStyle(.white.opacity(0.6))
            .font(.subheadline)
        }
      } else {
        // Fallback: show in web view
        if let ruleList {
          StreamWebView(url: game.pageURL, ruleList: ruleList)
            .ignoresSafeArea()
        } else {
          StreamWebView(url: game.pageURL, ruleList: nil)
            .ignoresSafeArea()
        }
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
      async let rules = AdBlockRules.compile()
      async let stream = extractStreamURL()
      ruleList = await rules
      let url = await stream
      if let url {
        player = AVPlayer(url: url)
        player?.play()
      }
      isExtracting = false
    }
  }

  private func extractStreamURL() async -> URL? {
    guard let source = try? await BuffStreamsSource().fetchHTML(from: game.pageURL) else {
      return nil
    }
    return StreamExtractor.extractM3U8(from: source, baseURL: game.pageURL)
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
    return vc
  }

  func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
    uiViewController.player = player
  }
}

// MARK: - WebKit fallback

struct StreamWebView: UIViewRepresentable {
  let url: URL
  let ruleList: WKContentRuleList?

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []

    if let ruleList {
      config.userContentController.add(ruleList)
    }

    // JS to suppress popups and auto-dismiss overlay ads
    let suppressScript = WKUserScript(
      source: """
        window.open = function() { return null; };
        window.alert = function() {};
        window.confirm = function() { return false; };
        document.addEventListener('click', function(e) {
          var el = e.target;
          while (el) {
            var style = window.getComputedStyle(el);
            if (style.position === 'fixed' || style.position === 'absolute') {
              var z = parseInt(style.zIndex) || 0;
              if (z > 999 && el.tagName !== 'VIDEO') {
                el.remove();
                e.stopPropagation();
                e.preventDefault();
                return;
              }
            }
            el = el.parentElement;
          }
        }, true);
      """,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false
    )
    config.userContentController.addUserScript(suppressScript)

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
    webView.load(request)
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
    // Block popup windows
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      return nil
    }

    // Block navigating away from the stream page (ad redirects)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if action.navigationType == .linkActivated,
         let host = action.request.url?.host,
         host != webView.url?.host {
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }
  }
}
