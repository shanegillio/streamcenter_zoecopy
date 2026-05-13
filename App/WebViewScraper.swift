import Foundation
import WebKit
import UIKit

struct ScrapedLink {
  let href: String
  let text: String
  /// Text scraped from a nearby status/score/badge element in the DOM (e.g. "Bottom 6th", "3-1")
  let status: String
}

// Loads a URL in a WKWebView attached to an off-screen UIWindow so Cloudflare JS
// challenges and SSO redirects complete fully before link extraction runs.
// Debounces didFinish so multi-hop redirect chains (Cloudflare → SSO → real page)
// only trigger one extraction pass after the final page settles.
@MainActor
final class WebViewScraper: NSObject {
  private var webView: WKWebView?
  private var hostWindow: UIWindow?
  private var continuation: CheckedContinuation<[ScrapedLink], Never>?
  private var hasResumed = false
  private var timeoutTask: Task<Void, Never>?
  private var extractionTask: Task<Void, Never>?

  func scrape(url: URL, timeout: TimeInterval = 30) async -> [ScrapedLink] {
    await withCheckedContinuation { cont in
      self.continuation = cont
      self.hasResumed = false

      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = false

      let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
      wv.navigationDelegate = self
      self.webView = wv

      // Attach to a real (but invisible) UIWindow so Cloudflare's JS challenge runs
      // in a full browser context rather than an orphaned WebView.
      if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        let win = UIWindow(windowScene: scene)
        win.frame = CGRect(x: -400, y: -400, width: 390, height: 844)
        win.windowLevel = UIWindow.Level(rawValue: -9999)
        win.addSubview(wv)
        win.isHidden = false
        self.hostWindow = win
      }

      var request = URLRequest(url: url, timeoutInterval: timeout)
      request.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        forHTTPHeaderField: "User-Agent"
      )
      request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
      request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
      wv.load(request)

      timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        await self?.finish(with: [])
      }
    }
  }

  // Debounced: each didFinish resets the 3-second timer so we only extract
  // after the final page in a redirect chain fully settles.
  private func scheduleExtraction() {
    extractionTask?.cancel()
    extractionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled, let self else { return }
      self.extractLinks()
    }
  }

  private func extractLinks() {
    guard let wv = webView else { finish(with: []); return }
    let js = """
      (function() {
        var links = [], seen = {};
        document.querySelectorAll('a[href]').forEach(function(a) {
          var href = a.href;
          var text = (a.innerText || a.textContent || '').replace(/\\s+/g, ' ').trim();
          if (href && !seen[href] && href.startsWith('http')) {
            seen[href] = 1;
            // Walk up the DOM (up to 5 levels) to find a sibling status/score/badge element.
            // This captures elements like <div class="status status-live">Bottom 6th</div>
            // that are placed outside the <a> tag in many sports streaming site layouts.
            var statusText = '';
            var el = a.parentElement;
            for (var i = 0; i < 5 && el && !statusText; i++) {
              var found = el.querySelector('[class*="status"], [class*="score"], [class*="badge"], [class*="live-label"]');
              if (found && !found.contains(a)) {
                var t = (found.innerText || found.textContent || '').replace(/\\s+/g, ' ').trim();
                if (t) statusText = t;
              }
              el = el.parentElement;
            }
            links.push({href: href, text: text, status: statusText});
          }
        });
        return JSON.stringify(links);
      })()
    """
    wv.evaluateJavaScript(js) { [weak self] result, _ in
      Task { @MainActor in
        guard let self else { return }
        if let jsonStr = result as? String,
           let data = jsonStr.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
          let links = raw.compactMap { d -> ScrapedLink? in
            guard let href = d["href"], let text = d["text"] else { return nil }
            return ScrapedLink(href: href, text: text, status: d["status"] ?? "")
          }
          self.finish(with: links)
        } else {
          self.finish(with: [])
        }
      }
    }
  }

  private func finish(with links: [ScrapedLink]) {
    guard !hasResumed else { return }
    hasResumed = true
    timeoutTask?.cancel()
    extractionTask?.cancel()
    timeoutTask = nil
    extractionTask = nil
    continuation?.resume(returning: links)
    continuation = nil
    webView?.navigationDelegate = nil
    webView = nil
    hostWindow?.isHidden = true
    hostWindow = nil
  }
}

extension WebViewScraper: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    scheduleExtraction()
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(with: [])
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finish(with: [])
  }
}
