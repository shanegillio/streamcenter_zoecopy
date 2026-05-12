import Foundation
import WebKit

struct ScrapedLink {
  let href: String
  let text: String
}

// Loads a URL in a hidden WKWebView, waits for JS to render, then extracts all anchor links.
@MainActor
final class WebViewScraper: NSObject {
  private var webView: WKWebView?
  private var continuation: CheckedContinuation<[ScrapedLink], Never>?
  private var hasResumed = false
  private var timeoutTask: Task<Void, Never>?

  func scrape(url: URL, timeout: TimeInterval = 18) async -> [ScrapedLink] {
    await withCheckedContinuation { cont in
      self.continuation = cont

      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = false
      let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
      wv.navigationDelegate = self
      self.webView = wv

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

  private func extractLinks() {
    guard let wv = webView else { finish(with: []); return }
    // Wait 2 s for SPA frameworks (React/Vue/Nuxt) to finish rendering
    Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      let js = """
        (function() {
          var links = [], seen = {};
          document.querySelectorAll('a[href]').forEach(function(a) {
            var href = a.href;
            var text = (a.innerText || a.textContent || '').replace(/\\s+/g, ' ').trim();
            if (href && !seen[href]) { seen[href] = 1; links.push({href:href, text:text}); }
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
              return ScrapedLink(href: href, text: text)
            }
            self.finish(with: links)
          } else {
            self.finish(with: [])
          }
        }
      }
    }
  }

  private func finish(with links: [ScrapedLink]) {
    guard !hasResumed else { return }
    hasResumed = true
    timeoutTask?.cancel()
    timeoutTask = nil
    continuation?.resume(returning: links)
    continuation = nil
    webView = nil
  }
}

extension WebViewScraper: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { extractLinks() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(with: []) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(with: []) }
}
