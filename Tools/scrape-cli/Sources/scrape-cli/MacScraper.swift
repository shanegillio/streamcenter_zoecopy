import Foundation
import WebKit
import AppKit

/// Output schema, mirrors `ScrapeDiagnostic` + `ScrapedLink` in
/// `App/WebViewScraper.swift`. Encoded to JSON on stdout.
struct ScrapeResult: Encodable {
  let url: String
  let loadedURL: String?
  let durationMs: Int
  let reason: String
  let errorMessage: String?
  let linkCount: Int
  let links: [Link]

  struct Link: Encodable {
    let href: String
    let text: String
    let status: String
  }
}

/// macOS port of the iOS app's WebViewScraper. Uses the same WKWebView engine,
/// the same desktop Safari User-Agent, and the **same extraction JS**.
/// Keeping the extraction JS in sync with `App/WebViewScraper.swift` is the
/// whole point of this tool — search for the `BEGIN EXTRACTION-JS` marker.
@MainActor
final class MacScraper: NSObject {
  private var webView: WKWebView?
  private var hostWindow: NSWindow?
  private var continuation: CheckedContinuation<ScrapeResult, Never>?
  private var hasResumed = false
  private var startedAt: Date = Date()
  private var scrapeURL: URL
  private var debounce: TimeInterval
  private var clickDelay: TimeInterval
  private var timeout: TimeInterval
  private var timeoutTask: Task<Void, Never>?
  private var extractionTask: Task<Void, Never>?

  init(url: URL, debounce: TimeInterval, clickDelay: TimeInterval, timeout: TimeInterval) {
    self.scrapeURL = url
    self.debounce = debounce
    self.clickDelay = clickDelay
    self.timeout = timeout
  }

  func scrape() async -> ScrapeResult {
    await withCheckedContinuation { cont in
      self.continuation = cont
      self.hasResumed = false
      self.startedAt = Date()

      let config = WKWebViewConfiguration()
      let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
      wv.navigationDelegate = self
      self.webView = wv

      // Real (but off-screen) NSWindow so the WebView has a full JS execution
      // context — equivalent to the iOS UIWindow trick in WebViewScraper.swift.
      let win = NSWindow(
        contentRect: CGRect(x: -2000, y: -2000, width: 1280, height: 800),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      win.contentView = wv
      win.orderBack(nil)
      self.hostWindow = win

      var request = URLRequest(url: scrapeURL, timeoutInterval: timeout)
      // Desktop Safari User-Agent — same as App/WebViewScraper.swift.
      request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
      )
      request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
      request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
      wv.load(request)

      timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(self?.timeout ?? 30) * 1_000_000_000)
        await self?.finish(links: [], reason: "timeout", errorMessage: "Scrape exceeded timeout")
      }
    }
  }

  private func scheduleExtraction() {
    extractionTask?.cancel()
    extractionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(nanoseconds: UInt64(self.debounce * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self.clickSPATabIfFragment()
      guard !Task.isCancelled else { return }
      self.extractLinks()
    }
  }

  private func clickSPATabIfFragment() async {
    guard let wv = webView,
          let url = wv.url,
          let frag = url.fragment, !frag.isEmpty else { return }
    let safeFrag = frag.replacingOccurrences(of: "'", with: "\\'")
    let js = """
      (function() {
        var hash = '#\(safeFrag)';
        var selectors = [
          'a[href="' + hash + '"]',
          'a[href$="' + hash + '"]',
          '[data-toggle="tab"][href="' + hash + '"]',
          '[data-target="' + hash + '"]',
          '[role="tab"][href="' + hash + '"]'
        ];
        for (var i = 0; i < selectors.length; i++) {
          var el = document.querySelector(selectors[i]);
          if (el && typeof el.click === 'function') {
            el.click();
            return 'clicked';
          }
        }
        return 'not_found';
      })()
    """
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      wv.evaluateJavaScript(js) { _, _ in cont.resume() }
    }
    try? await Task.sleep(nanoseconds: UInt64(clickDelay * 1_000_000_000))
  }

  private func extractLinks() {
    guard let wv = webView else {
      finish(links: [], reason: "navError", errorMessage: "WKWebView released")
      return
    }

    // === BEGIN EXTRACTION-JS — KEEP IN SYNC WITH App/WebViewScraper.swift ===
    let js = """
      (function() {
        var links = [], seen = {};

        function findStatus(anchor) {
          var statusText = '';
          var el = anchor.parentElement;
          for (var i = 0; i < 4 && el && !statusText; i++) {
            var children = el.children;
            for (var j = 0; j < children.length && !statusText; j++) {
              var child = children[j];
              if (!child.contains(anchor)) {
                var cls = (child.className || '').toLowerCase();
                if (cls.indexOf('status') !== -1 || cls.indexOf('score') !== -1 ||
                    cls.indexOf('badge') !== -1 || cls.indexOf('live-label') !== -1 ||
                    cls.indexOf('premium') !== -1 || cls.indexOf('vip') !== -1 ||
                    cls.indexOf('lock') !== -1 || cls.indexOf('crown') !== -1 ||
                    cls.indexOf('countdown') !== -1 || cls.indexOf('timer') !== -1 ||
                    cls.indexOf('time') !== -1) {
                  var t = (child.innerText || child.textContent || '').replace(/\\s+/g, ' ').trim();
                  if (t && t.length < 60) statusText = t;
                }
              }
            }
            el = el.parentElement;
          }
          return statusText;
        }

        document.querySelectorAll('a[href]').forEach(function(a) {
          var href = a.href;
          var text = (a.innerText || a.textContent || '').replace(/\\s+/g, ' ').trim();
          if (href && !seen[href] && href.startsWith('http')) {
            seen[href] = 1;
            links.push({href: href, text: text, status: findStatus(a)});
          }
        });

        var cardSelectors = '[class*="countdown" i],[class*="timer" i]';
        document.querySelectorAll(cardSelectors).forEach(function(timerEl) {
          var card = timerEl;
          for (var k = 0; k < 5 && card.parentElement; k++) {
            card = card.parentElement;
            var ccls = (card.className || '').toLowerCase();
            if (ccls.indexOf('card') !== -1 || ccls.indexOf('item') !== -1 ||
                ccls.indexOf('match') !== -1 || ccls.indexOf('game') !== -1 ||
                ccls.indexOf('event') !== -1 || ccls.indexOf('fixture') !== -1) {
              break;
            }
          }

          var text = (card.innerText || '').replace(/\\s+/g, ' ').trim();
          if (!text || text.length > 250 || text.length < 8) return;

          var teamEls = card.querySelectorAll('[class*="team" i],[class*="home" i],[class*="away" i],[class*="competitor" i]');
          if (teamEls.length >= 2) {
            var names = [];
            for (var ti = 0; ti < teamEls.length; ti++) {
              var tname = (teamEls[ti].innerText || '').replace(/\\s+/g, ' ').trim();
              if (tname && tname.length < 60 && names.indexOf(tname) === -1) names.push(tname);
              if (names.length >= 2) break;
            }
            if (names.length >= 2) text = names[0] + ' vs ' + names[1];
          }

          var inner = card.querySelector('a[href]');
          var href;
          if (inner && inner.href && inner.href.startsWith('http')) {
            if (seen[inner.href]) return;
            href = inner.href;
          } else {
            href = window.location.href + '#upcoming-' + links.length;
          }
          if (seen[href]) return;
          seen[href] = 1;

          var statusText = (timerEl.innerText || '').replace(/\\s+/g, ' ').trim();
          if (statusText.length > 60) statusText = statusText.slice(0, 60);

          links.push({href: href, text: text, status: statusText});
        });

        return JSON.stringify(links);
      })()
    """
    // === END EXTRACTION-JS ===

    wv.evaluateJavaScript(js) { [weak self] result, error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          self.finish(links: [], reason: "jsError", errorMessage: error.localizedDescription)
          return
        }
        if let jsonStr = result as? String,
           let data = jsonStr.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
          let parsed: [ScrapeResult.Link] = raw.compactMap { d -> ScrapeResult.Link? in
            guard let href = d["href"], let text = d["text"] else { return nil }
            return ScrapeResult.Link(href: href, text: text, status: d["status"] ?? "")
          }
          let reason = parsed.isEmpty ? "noLinks" : "success"
          let msg = parsed.isEmpty
            ? "Page loaded but no anchors or cards were extracted (likely Cloudflare challenge or JS-only rendering)."
            : nil
          self.finish(links: parsed, reason: reason, errorMessage: msg)
        } else {
          self.finish(links: [], reason: "jsError", errorMessage: "JS evaluation returned non-string result")
        }
      }
    }
  }

  private func finish(links: [ScrapeResult.Link], reason: String, errorMessage: String?) {
    guard !hasResumed else { return }
    hasResumed = true
    timeoutTask?.cancel()
    extractionTask?.cancel()
    timeoutTask = nil
    extractionTask = nil
    let loaded = webView?.url?.absoluteString
    let result = ScrapeResult(
      url: scrapeURL.absoluteString,
      loadedURL: loaded,
      durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
      reason: reason,
      errorMessage: errorMessage,
      linkCount: links.count,
      links: links
    )
    continuation?.resume(returning: result)
    continuation = nil
    webView?.navigationDelegate = nil
    webView = nil
    hostWindow?.orderOut(nil)
    hostWindow = nil
  }
}

extension MacScraper: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    scheduleExtraction()
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(links: [], reason: "navError", errorMessage: error.localizedDescription)
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let nsErr = error as NSError
    if nsErr.code == NSURLErrorCancelled { return }
    finish(links: [], reason: "provisionalError", errorMessage: error.localizedDescription)
  }
}
