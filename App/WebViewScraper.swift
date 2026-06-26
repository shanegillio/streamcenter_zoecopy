import Foundation
import WebKit
import UIKit

struct ScrapedLink {
  let href: String
  let text: String
  /// Text scraped from a nearby status/score/badge element in the DOM (e.g. "Bottom 6th", "3-1")
  let status: String
}

/// Why a scrape finished. Surfaced via `ScrapeDiagnostic` so the in-app
/// Diagnostics view (Settings → Source Diagnostics) can explain failures.
enum ScrapeFinishReason: String {
  case success
  case timeout
  case navError
  case provisionalError
  case jsError
  case noLinks       // success but extracted 0 links — usually means Cloudflare/empty page
}

struct ScrapeDiagnostic {
  let url: URL
  let timestamp: Date
  let durationMs: Int
  let linkCount: Int
  let reason: ScrapeFinishReason
  let errorMessage: String?
  /// Document title at extraction time. Used by `fetchAvailableLeagues` to
  /// detect parking / Cloudflare / sinkhole pages and bail fast.
  let pageTitle: String?
  /// `<meta name="description">` at extraction time. Feeds the LLM classifier
  /// and the league-hint parser.
  let metaDescription: String?
  /// Final URL after redirects settle. Different host than the original
  /// indicates a redirect (MPAA takedown, mirror, …).
  let finalURL: URL?
  /// URLs the page's own JS fetched via `fetch()` / `XMLHttpRequest` during
  /// the scrape, captured by a JS shim injected at document-start. For
  /// aggregator sites (bintv.net, similar) the games live in these JSON
  /// endpoints — `APIDiscovery` consumes them directly with its shape
  /// parsers, bypassing the WebView's slow render path.
  let observedAPIUrls: [URL]
}

/// Loads a URL in a WKWebView attached to an off-screen UIWindow, then
/// extracts game-shaped content the moment it appears in the DOM via an
/// injected MutationObserver — *not* on a fixed timer. Fast sites are
/// instant; slow sites (lazy-loaded aggregators, Cloudflare interactive
/// challenges) are patient automatically. A top-level Task timeout serves
/// as the only hard ceiling.
@MainActor
final class WebViewScraper: NSObject {
  // MARK: - Shared resources

  /// Persistent (disk-backed) data store so cf_clearance / cf_bm cookies —
  /// especially Cloudflare's `cf_clearance` set after a successful challenge —
  /// persist between probes and survive app relaunches. (A shared
  /// `WKProcessPool` used to back this; it's a no-op since iOS 15, so the
  /// data store alone now handles cookie sharing.)
  private static let sharedDataStore: WKWebsiteDataStore = .default()
  /// Compiled WKContentRuleList from `AdBlockRules`. Compiled once on first
  /// access and reused across every scraper instance. Drops ad-network
  /// sub-resources at the URL-loader layer so the JS that performs popup /
  /// `location.href = "https://ad-host..."` redirects often doesn't even run.
  private static let adBlockListTask: Task<WKContentRuleList?, Never> = Task { @MainActor in
    await AdBlockRules.compile()
  }

  // MARK: - Instance state

  private var webView: WKWebView?
  private var hostWindow: UIWindow?
  private var continuation: CheckedContinuation<(links: [ScrapedLink], diagnostic: ScrapeDiagnostic), Never>?
  private var hasResumed = false
  private var timeoutTask: Task<Void, Never>?
  private var scrapeStartedAt: Date = Date()
  private var scrapeURL: URL = URL(string: "about:blank")!
  /// First non-empty title observed across the page's lifecycle (captured at
  /// `didCommit` and `didFinish`). Preserves a parking title like
  /// "Redirecting..." that page JS clears 2 s later by rewriting the DOM —
  /// the title becomes the parked classifier's primary signal.
  private var earliestObservedTitle: String?
  /// Proxy installed on `WKUserContentController` to receive `sc_result`
  /// and `sc_xhr` messages from the injected script without retaining `self`.
  private var messageProxy: ScraperMessageHandlerProxy?
  /// URLs observed via the injected `fetch`/`XHR` wrappers during this scrape.
  /// Forwarded to the upstream classifier on `finish()` so it can decode
  /// JSON aggregator endpoints directly via `APIDiscovery`'s shape parsers.
  private var observedAPIUrls: [URL] = []
  private var observedAPIUrlSet: Set<String> = []

  // MARK: - Public API

  /// Convenience: returns just the links. Callers that need diagnostics should
  /// use `scrapeWithDiagnostic` directly.
  func scrape(url: URL, timeout: TimeInterval = 30) async -> [ScrapedLink] {
    await scrapeWithDiagnostic(url: url, timeout: timeout).links
  }

  func scrapeWithDiagnostic(url: URL, timeout: TimeInterval = 30) async -> (links: [ScrapedLink], diagnostic: ScrapeDiagnostic) {
    // Resolve the compiled ad-block rule list before entering the continuation
    // so we can attach it to the WKWebViewConfiguration synchronously.
    let adBlockList = await Self.adBlockListTask.value
    return await withCheckedContinuation { cont in
      self.continuation = cont
      self.hasResumed = false
      self.scrapeStartedAt = Date()
      self.scrapeURL = url
      self.earliestObservedTitle = nil

      let config = WKWebViewConfiguration()
      config.allowsInlineMediaPlayback = false
      config.websiteDataStore = Self.sharedDataStore
      if let adBlockList {
        config.userContentController.add(adBlockList)
      }
      // Install the message-handler proxy (weak-owner) and the extraction
      // user script. The proxy receives `sc_result` posts from the injected
      // JS; the user script sets up the MutationObserver + readiness check
      // and posts when content settles.
      let proxy = ScraperMessageHandlerProxy(owner: self)
      self.messageProxy = proxy
      config.userContentController.add(proxy, name: "sc_result")
      config.userContentController.add(proxy, name: "sc_xhr")
      config.userContentController.addUserScript(Self.extractionUserScript)
      self.observedAPIUrls = []
      self.observedAPIUrlSet = []

      let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
      wv.navigationDelegate = self
      self.webView = wv

      // Attach to a real (but invisible) UIWindow so Cloudflare's JS challenge
      // runs in a full browser context rather than an orphaned WebView.
      if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
        let win = UIWindow(windowScene: scene)
        win.frame = CGRect(x: -1400, y: -1400, width: 1280, height: 800)
        win.windowLevel = UIWindow.Level(rawValue: -9999)
        win.addSubview(wv)
        win.isHidden = false
        self.hostWindow = win
      }

      var request = URLRequest(url: url, timeoutInterval: timeout)
      // Desktop Safari UA: Cloudflare's desktop heuristics are friendlier than
      // its mobile heuristics. Sites that don't UA-sniff serve identical HTML
      // either way.
      request.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent"
      )
      request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
      request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
      wv.load(request)

      // Top-level safety timeout. The injected JS normally fires `sc_result`
      // long before this — on readiness or DOM quiescence — so the timeout
      // is a backstop for pages that never load or never settle.
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        await self?.forceExtractOnTimeout()
      }
    }
  }

  // MARK: - Result handling

  /// Called by `ScraperMessageHandlerProxy` when the injected fetch/XHR
  /// shim observes a network request from the page's JS. Filters obvious
  /// noise (images, fonts, analytics) and accumulates the URL for the
  /// upstream classifier to query via `APIDiscovery`.
  fileprivate func handleObservedURL(_ urlString: String) {
    guard !hasResumed else { return }
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host?.lowercased() else { return }
    // Filter: don't capture the scrape URL itself, image/font/CSS asset
    // requests, or known telemetry endpoints. We only want endpoints that
    // could plausibly carry JSON game data.
    let path = url.path.lowercased()
    let assetExts = [".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".ico",
                     ".css", ".js", ".mjs", ".woff", ".woff2", ".ttf", ".otf",
                     ".mp4", ".m4s", ".webm", ".m3u8", ".ts"]
    if assetExts.contains(where: { path.hasSuffix($0) }) { return }
    let telemetryHosts = [
      "google-analytics.com", "googletagmanager.com", "doubleclick.net",
      "sentry.io", "googleapis.com", "gstatic.com", "fontawesome.com",
      "cdnjs.cloudflare.com", "facebook.net", "twitter.com", "discord.com",
      "discord.gg", "amazonaws.com/cloudwatch",
    ]
    if telemetryHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return }
    // Dedupe (sometimes the same URL is fetched many times).
    if !observedAPIUrlSet.insert(url.absoluteString).inserted { return }
    // Cap at 50 captures per scrape to keep memory bounded.
    if observedAPIUrls.count >= 50 { return }
    observedAPIUrls.append(url)
  }

  /// Called by `ScraperMessageHandlerProxy` when the injected script posts
  /// its extraction payload. Parses the JSON, resolves it into our usual
  /// `ScrapedLink`/`ScrapeDiagnostic` shapes, and finishes the scrape.
  fileprivate func handleScriptResult(_ json: String) {
    guard !hasResumed else { return }
    guard let data = json.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      finish(
        with: [],
        title: webView?.title,
        metaDescription: nil,
        finalURL: webView?.url,
        reason: .jsError,
        errorMessage: "Bad JSON from extraction script"
      )
      return
    }
    let rawLinks = (raw["links"] as? [[String: String]]) ?? []
    let title = raw["title"] as? String
    let metaDesc = raw["metaDesc"] as? String
    let finalURLStr = raw["finalURL"] as? String
    let finalURL = finalURLStr.flatMap { URL(string: $0) }
    let links = rawLinks.compactMap { d -> ScrapedLink? in
      guard let href = d["href"], let text = d["text"] else { return nil }
      return ScrapedLink(href: href, text: text, status: d["status"] ?? "")
    }
    let reason: ScrapeFinishReason = links.isEmpty ? .noLinks : .success
    let msg = links.isEmpty
      ? "Page loaded but no anchors or cards were extracted (likely Cloudflare challenge or JS-only rendering)."
      : nil
    finish(
      with: links,
      title: title,
      metaDescription: metaDesc,
      finalURL: finalURL,
      reason: reason,
      errorMessage: msg
    )
  }

  /// Called by the top-level timeout. Synchronously reads `WKWebView.title`
  /// and `.url` (no JS eval — that would queue behind ongoing navigations and
  /// never run on a perpetually-redirecting page). Critical for sites like
  /// crackstreams.net (ParkLogic) that re-navigate continuously — `wv.title`
  /// is still "Redirecting..." from the first commit, which is what the
  /// upstream classifier needs.
  @MainActor
  private func forceExtractOnTimeout() async {
    guard !hasResumed else { return }
    finish(
      with: [],
      title: webView?.title,
      metaDescription: nil,
      finalURL: webView?.url,
      reason: .timeout,
      errorMessage: "Scrape exceeded timeout (page never settled — likely JS-redirect loop)"
    )
  }

  private func finish(
    with links: [ScrapedLink],
    title: String? = nil,
    metaDescription: String? = nil,
    finalURL: URL? = nil,
    reason: ScrapeFinishReason,
    errorMessage: String?
  ) {
    guard !hasResumed else { return }
    hasResumed = true
    timeoutTask?.cancel()
    timeoutTask = nil
    // Fall back to the earliest observed title when the JS payload's title
    // is empty because the page mutated itself after first paint (ParkLogic
    // wipes `<title>` along with the DOM body).
    let resolvedTitle: String? = {
      if let t = title, !t.isEmpty { return t }
      return earliestObservedTitle
    }()
    let diag = ScrapeDiagnostic(
      url: scrapeURL,
      timestamp: Date(),
      durationMs: Int(Date().timeIntervalSince(scrapeStartedAt) * 1000),
      linkCount: links.count,
      reason: reason,
      errorMessage: errorMessage,
      pageTitle: (resolvedTitle?.isEmpty == true) ? nil : resolvedTitle,
      metaDescription: (metaDescription?.isEmpty == true) ? nil : metaDescription,
      finalURL: finalURL,
      observedAPIUrls: observedAPIUrls
    )
    continuation?.resume(returning: (links, diag))
    continuation = nil
    // Tear down the WebView + UIWindow + message handlers. Removing the
    // script-message handlers explicitly breaks the (weak) proxy reference
    // and avoids dangling handlers if the WebView outlives the scraper.
    let ucc = webView?.configuration.userContentController
    ucc?.removeScriptMessageHandler(forName: "sc_result")
    ucc?.removeScriptMessageHandler(forName: "sc_xhr")
    webView?.navigationDelegate = nil
    webView = nil
    hostWindow?.isHidden = true
    hostWindow = nil
    messageProxy = nil
  }

  /// Records the first non-empty title we ever see during this scrape.
  private func captureEarliestTitle(from webView: WKWebView) {
    if earliestObservedTitle == nil, let t = webView.title, !t.isEmpty {
      earliestObservedTitle = t
    }
  }

  // MARK: - Injected user script

  /// Compiled once. Installed at `.atDocumentStart` on every scrape — re-runs
  /// on each main-frame navigation so SPA route changes / 301-redirects pick
  /// up a fresh observer.
  private static let extractionUserScript: WKUserScript = WKUserScript(
    source: extractionUserScriptSource,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
  )

  /// JS source. Sets up a MutationObserver on `documentElement`, waits for
  /// either game-shaped content to appear (`__sc_isReady`) OR for the DOM to
  /// stop changing for 2 seconds (quiescence), then runs the extraction
  /// passes (`__sc_extract`) and posts the result to native via
  /// `webkit.messageHandlers.sc_result`. Idempotent — guarded by an
  /// `__sc_installed` flag and a `done` flag inside the closure.
  private static let extractionUserScriptSource: String = #"""
    (function () {
      if (window.__sc_installed) return;
      window.__sc_installed = true;

      // ---------------------------------------------------------------
      // Network observation shim — wraps fetch / XHR so we can capture
      // the JSON endpoints aggregator sites (bintv.net etc.) fetch from.
      // Captured URLs are posted to native via sc_xhr; native attempts to
      // decode each one with the existing APIDiscovery shape parsers.
      // ---------------------------------------------------------------
      try {
        var __post = function (u) {
          try {
            if (window.webkit && window.webkit.messageHandlers &&
                window.webkit.messageHandlers.sc_xhr && typeof u === 'string') {
              window.webkit.messageHandlers.sc_xhr.postMessage(u);
            }
          } catch (e) {}
        };
        if (window.fetch) {
          var __origFetch = window.fetch.bind(window);
          window.fetch = function (input, init) {
            try {
              var u = (typeof input === 'string') ? input
                    : (input && input.url) ? input.url : null;
              if (u) __post(u);
            } catch (e) {}
            return __origFetch(input, init);
          };
        }
        if (window.XMLHttpRequest) {
          var __origOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            try { if (typeof url === 'string') __post(url); } catch (e) {}
            return __origOpen.apply(this, arguments);
          };
        }
      } catch (e) {}

      var QUIESCENCE_MS = 4000;
      var done = false;
      var quiescenceTimer = null;
      var observer = null;

      function abs(raw) {
        if (!raw) return null;
        try { return new URL(raw, window.location.href).href; }
        catch (e) { return null; }
      }

      function findStatus(el) {
        var statusText = '';
        var p = el.parentElement;
        for (var i = 0; i < 4 && p && !statusText; i++) {
          var children = p.children;
          for (var j = 0; j < children.length && !statusText; j++) {
            var child = children[j];
            if (!child.contains(el)) {
              var cls = (child.className || '').toLowerCase();
              if (cls.indexOf('status') !== -1 || cls.indexOf('score') !== -1 ||
                  cls.indexOf('badge') !== -1 || cls.indexOf('live-label') !== -1 ||
                  cls.indexOf('premium') !== -1 || cls.indexOf('vip') !== -1 ||
                  cls.indexOf('lock') !== -1 || cls.indexOf('crown') !== -1 ||
                  cls.indexOf('countdown') !== -1 || cls.indexOf('timer') !== -1 ||
                  cls.indexOf('time') !== -1) {
                var t = (child.innerText || child.textContent || '').replace(/\s+/g, ' ').trim();
                if (t && t.length < 60) statusText = t;
              }
            }
          }
          p = p.parentElement;
        }
        return statusText;
      }

      function isReady() {
        var tl = (document.title || '').toLowerCase().trim();
        if (tl === 'page not found' ||
            tl.indexOf('redirecting') === 0 ||
            tl === 'rebrandly' ||
            tl.indexOf('attention required') !== -1 ||
            tl.indexOf('access denied') !== -1 ||
            tl.indexOf('service unavailable') !== -1 ||
            tl.indexOf('bad gateway') !== -1 ||
            tl.indexOf('gateway timeout') !== -1 ||
            (tl.indexOf('not found') !== -1 && tl.length < 30) ||
            tl.indexOf('domain parking') !== -1) {
          return true;
        }

        // Game-shape predicates. Any of:
        //   - 3+ anchors whose text OR aria-label OR title mentions vs / @
        //   - 3+ anchors whose href looks game-shaped
        //   - 3+ card containers with substantive inner text
        //   - any JSON-LD SportsEvent / BroadcastEvent script (instant ready)
        // v2.34: aria-label fallback — image-only `<a>` cards have empty
        //         textContent but the team-pair lives in aria-label.
        if (document.querySelector('script[type="application/ld+json"]')) {
          // Cheap heuristic: any LD-JSON block makes the page "ready
          // enough" to extract — Pass 1.8 will decide what's useful.
          return true;
        }
        var anchors = document.querySelectorAll('a[href]');
        var vsCount = 0, dateCount = 0;
        var vsRE = /\bvs\.?\b|\s+@\s+/i;
        var dateRE = /\d{4}-\d{2}-\d{2}|-vs-|-at-/;
        var cap = Math.min(anchors.length, 600);
        for (var i = 0; i < cap; i++) {
          var a = anchors[i];
          var text = (a.textContent || '').trim();
          var aria = a.getAttribute && (a.getAttribute('aria-label') || a.getAttribute('title') || '');
          if ((text && vsRE.test(text)) || (aria && vsRE.test(aria))) vsCount++;
          if (a.href && dateRE.test(a.href)) dateCount++;
          if (vsCount >= 3 || dateCount >= 3) return true;
        }
        var cards = document.querySelectorAll('[class*="match" i],[class*="game" i],[class*="event" i],[class*="fixture" i]');
        var cardCount = 0;
        var cardCap = Math.min(cards.length, 200);
        for (var j = 0; j < cardCap; j++) {
          var txt = (cards[j].innerText || '').trim();
          if (txt && txt.length > 12) cardCount++;
          if (cardCount >= 3) return true;
        }
        return false;
      }

      // v2.34: build a "search blob" combining every readable signal a
      // page exposes for an element — innerText, accessibility
      // attributes (aria-label, aria-description, title), child <img alt>,
      // select data-* attributes, and 3 ancestor levels of card context.
      // This is what a screen reader actually surfaces; capturing it
      // means image-only cards (the m-card pattern with empty innerText
      // and aria-label only) match cleanly against canonical team names.
      function readableTextFor(el) {
        if (!el) return '';
        var parts = [];
        var seenParts = {};
        function pushText(s) {
          if (!s) return;
          var t = String(s).replace(/\s+/g, ' ').trim();
          if (!t || t.length > 500 || seenParts[t]) return;
          seenParts[t] = 1;
          parts.push(t);
        }
        pushText(el.innerText || el.textContent);
        if (el.getAttribute) {
          pushText(el.getAttribute('aria-label'));
          pushText(el.getAttribute('aria-description'));
          pushText(el.getAttribute('title'));
          var dataAttrs = ['data-game', 'data-event', 'data-match',
                           'data-teams', 'data-title',
                           'data-home', 'data-away'];
          for (var di = 0; di < dataAttrs.length; di++) {
            pushText(el.getAttribute(dataAttrs[di]));
          }
        }
        if (el.querySelectorAll) {
          var imgs = el.querySelectorAll('img[alt]');
          for (var ii = 0; ii < imgs.length && ii < 4; ii++) {
            pushText(imgs[ii].getAttribute('alt'));
          }
        }
        var anc = el.parentElement;
        for (var ai = 0; ai < 3 && anc; ai++) {
          pushText(anc.innerText || anc.textContent);
          anc = anc.parentElement;
        }
        var out = parts.join(' | ');
        if (out.length > 800) out = out.slice(0, 800);
        return out;
      }

      function extract() {
        var links = [], seen = {};

        // Pass 1: anchors with http(s) href.
        var anchors = document.querySelectorAll('a[href]');
        for (var i = 0; i < anchors.length; i++) {
          var a = anchors[i];
          var href = a.href;
          if (href && !seen[href] && href.indexOf('http') === 0) {
            seen[href] = 1;
            links.push({ href: href, text: readableTextFor(a), status: findStatus(a) });
          }
        }

        // Pass 1.5: data-href / data-url / data-link / data-stream attributes.
        var dataNavAttrs = ['data-href', 'data-url', 'data-link', 'data-stream'];
        for (var di2 = 0; di2 < dataNavAttrs.length; di2++) {
          var attr = dataNavAttrs[di2];
          var nodes = document.querySelectorAll('[' + attr + ']');
          for (var ni = 0; ni < nodes.length; ni++) {
            var el = nodes[ni];
            var resolved = abs(el.getAttribute(attr));
            if (!resolved || resolved.indexOf('http') !== 0 || seen[resolved]) continue;
            seen[resolved] = 1;
            links.push({ href: resolved, text: readableTextFor(el), status: findStatus(el) });
          }
        }

        // Pass 1.6: inline onclick="location.href='/x'" handlers.
        var onclickRE = /(?:location\.href|window\.location(?:\.href)?|location)\s*=\s*['"]([^'"]+)['"]/i;
        var clickNodes = document.querySelectorAll('[onclick]');
        for (var ci = 0; ci < clickNodes.length; ci++) {
          var el2 = clickNodes[ci];
          var oc = el2.getAttribute('onclick') || '';
          var m = oc.match(onclickRE);
          if (!m) continue;
          var resolved2 = abs(m[1]);
          if (!resolved2 || resolved2.indexOf('http') !== 0 || seen[resolved2]) continue;
          seen[resolved2] = 1;
          links.push({ href: resolved2, text: readableTextFor(el2), status: findStatus(el2) });
        }

        // Pass 1.7 (v2.35): card containers — with OR without inner <a href>.
        // SPA aggregators (bintv-style) render `<div class="match-card"
        // data-match='...' onclick='handleMatchClick(...)'>` with no inner
        // anchor at all. Capture those as ScrapedLinks too — synthesize
        // a per-card pseudo-URL so each game gets a unique entry in
        // game.streamURLs. The shim's walk routine then re-finds and
        // clicks the matching card when the user taps.
        function simpleCardHash(s) {
          var h = 0;
          for (var hi = 0; hi < s.length; hi++) {
            h = ((h << 5) - h + s.charCodeAt(hi)) | 0;
          }
          return Math.abs(h).toString(36);
        }
        var cardEls = document.querySelectorAll('[class*="match" i],[class*="game" i],[class*="event" i],[class*="fixture" i],[class*="card" i]');
        for (var ki = 0; ki < cardEls.length; ki++) {
          var card = cardEls[ki];
          var inner = card.querySelector('a[href]');
          var href2;
          if (inner && inner.href && inner.href.indexOf('http') === 0) {
            if (seen[inner.href]) continue;
            href2 = inner.href;
          } else {
            // Anchor-less card — only accept if it's actually clickable.
            var clickable = card.hasAttribute('onclick')
                         || card.hasAttribute('data-match')
                         || card.hasAttribute('data-event')
                         || card.hasAttribute('data-game')
                         || card.hasAttribute('data-id')
                         || card.getAttribute('role') === 'button';
            if (!clickable) continue;
            var blob = readableTextFor(card);
            if (!blob || blob.length < 8 || blob.length > 1200) continue;
            href2 = location.href.split('#')[0] + '#sc-card-' + simpleCardHash(blob);
            if (seen[href2]) continue;
          }
          seen[href2] = 1;
          links.push({ href: href2, text: readableTextFor(card), status: findStatus(card) });
        }

        // Pass 1.8 (v2.34): JSON-LD SportsEvent / BroadcastEvent / Event.
        // Many modern sports sites publish structured data for SEO; when
        // present this is the authoritative game-to-URL mapping. The
        // resulting ScrapedLink carries fully canonical team names so
        // findLink's substring matcher hits cleanly.
        function visitLD(item) {
          if (!item || typeof item !== 'object') return;
          if (item['@graph'] && Array.isArray(item['@graph'])) {
            item['@graph'].forEach(visitLD);
          }
          var type = item['@type'];
          if (Array.isArray(type)) type = type[0];
          if (type !== 'SportsEvent' && type !== 'BroadcastEvent' &&
              type !== 'Event' && type !== 'EventSeries') return;
          var url = item.url
                 || (item.mainEntityOfPage && item.mainEntityOfPage.url);
          if (!url || typeof url !== 'string' || url.indexOf('http') !== 0) return;
          if (seen[url]) return;
          seen[url] = 1;
          var name = item.name || '';
          var home = (item.homeTeam && (item.homeTeam.name || item.homeTeam)) || '';
          var away = (item.awayTeam && (item.awayTeam.name || item.awayTeam)) || '';
          if (typeof home !== 'string') home = '';
          if (typeof away !== 'string') away = '';
          var parts = [];
          if (name) parts.push(String(name));
          if (home) parts.push(String(home));
          if (away) parts.push(String(away));
          if (home && away) parts.push(home + ' vs ' + away);
          var text = parts.join(' | ').slice(0, 500);
          links.push({ href: url, text: text, status: '' });
        }
        var ldScripts = document.querySelectorAll('script[type="application/ld+json"]');
        for (var ls = 0; ls < ldScripts.length; ls++) {
          try {
            var raw = ldScripts[ls].innerHTML || ldScripts[ls].textContent || '';
            var parsed = JSON.parse(raw);
            if (Array.isArray(parsed)) parsed.forEach(visitLD);
            else visitLD(parsed);
          } catch(e){}
        }

        // Pass 2: countdown / timer cards (upcoming games whose anchor is a
        // dead "#" placeholder).
        var timerEls = document.querySelectorAll('[class*="countdown" i],[class*="timer" i]');
        for (var ti = 0; ti < timerEls.length; ti++) {
          var timerEl = timerEls[ti];
          var card3 = timerEl;
          for (var k = 0; k < 5 && card3.parentElement; k++) {
            card3 = card3.parentElement;
            var ccls = (card3.className || '').toLowerCase();
            if (ccls.indexOf('card') !== -1 || ccls.indexOf('item') !== -1 ||
                ccls.indexOf('match') !== -1 || ccls.indexOf('game') !== -1 ||
                ccls.indexOf('event') !== -1 || ccls.indexOf('fixture') !== -1) {
              break;
            }
          }
          var text3 = (card3.innerText || '').replace(/\s+/g, ' ').trim();
          if (!text3 || text3.length > 250 || text3.length < 8) continue;
          var teamEls = card3.querySelectorAll('[class*="team" i],[class*="home" i],[class*="away" i],[class*="competitor" i]');
          if (teamEls.length >= 2) {
            var names = [];
            for (var tj = 0; tj < teamEls.length; tj++) {
              var tname = (teamEls[tj].innerText || '').replace(/\s+/g, ' ').trim();
              if (tname && tname.length < 60 && names.indexOf(tname) === -1) names.push(tname);
              if (names.length >= 2) break;
            }
            if (names.length >= 2) text3 = names[0] + ' vs ' + names[1];
          }
          var inner2 = card3.querySelector('a[href]');
          var href3;
          if (inner2 && inner2.href && inner2.href.indexOf('http') === 0) {
            if (seen[inner2.href]) continue;
            href3 = inner2.href;
          } else {
            href3 = window.location.href + '#upcoming-' + links.length;
          }
          if (seen[href3]) continue;
          seen[href3] = 1;
          var statusText3 = (timerEl.innerText || '').replace(/\s+/g, ' ').trim();
          if (statusText3.length > 60) statusText3 = statusText3.slice(0, 60);
          links.push({ href: href3, text: text3, status: statusText3 });
        }

        var metaDesc = '';
        var metaEl = document.querySelector('meta[name="description"]')
                  || document.querySelector('meta[property="og:description"]');
        if (metaEl) metaDesc = (metaEl.getAttribute('content') || '').trim();

        return {
          links: links,
          title: (document.title || '').replace(/\s+/g, ' ').trim(),
          metaDesc: metaDesc,
          finalURL: window.location.href
        };
      }

      function finalize() {
        if (done) return;
        done = true;
        try { if (observer) observer.disconnect(); } catch (e) {}
        try { if (quiescenceTimer) clearTimeout(quiescenceTimer); } catch (e) {}
        observer = null;
        quiescenceTimer = null;
        var payload;
        try { payload = extract(); }
        catch (e) {
          payload = {
            links: [],
            title: (document.title || '').replace(/\s+/g, ' ').trim(),
            metaDesc: '',
            finalURL: window.location.href
          };
        }
        try {
          if (window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.sc_result) {
            window.webkit.messageHandlers.sc_result.postMessage(JSON.stringify(payload));
          }
        } catch (e) {}
      }

      function resetQuiescence() {
        if (quiescenceTimer) clearTimeout(quiescenceTimer);
        quiescenceTimer = setTimeout(finalize, QUIESCENCE_MS);
      }

      function onMutation() {
        if (done) return;
        if (isReady()) { finalize(); return; }
        resetQuiescence();
      }

      function start() {
        var root = document.documentElement;
        if (!root) { setTimeout(start, 50); return; }
        // Initial readiness pass for already-rendered (SSR) pages.
        if (isReady()) { finalize(); return; }
        // Schedule the first quiescence timer so we eventually fire even if
        // the DOM never mutates after load.
        resetQuiescence();
        try {
          observer = new MutationObserver(onMutation);
          observer.observe(root, { childList: true, subtree: true });
        } catch (e) {
          // If MutationObserver fails for some reason, just let the
          // quiescence timer fire.
        }
      }

      start();
    })();
    """#
}

// MARK: - WKScriptMessageHandler proxy

/// Tiny proxy that forwards `sc_result` messages to `WebViewScraper` without
/// retaining it. `WKUserContentController.add(handler:name:)` keeps a strong
/// reference to whatever it's given; using `self` directly would create a
/// cycle that lives until the WKWebView is fully torn down.
private final class ScraperMessageHandlerProxy: NSObject, WKScriptMessageHandler {
  weak var owner: WebViewScraper?

  init(owner: WebViewScraper) {
    self.owner = owner
    super.init()
  }

  func userContentController(_ controller: WKUserContentController,
                             didReceive message: WKScriptMessage) {
    guard let body = message.body as? String else { return }
    let name = message.name
    Task { @MainActor [weak owner] in
      switch name {
      case "sc_result": owner?.handleScriptResult(body)
      case "sc_xhr":    owner?.handleObservedURL(body)
      default: break
      }
    }
  }
}

// MARK: - WKNavigationDelegate

extension WebViewScraper: WKNavigationDelegate {
  func webView(_ webView: WKWebView,
               decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    // Sub-frames (iframes, ad slots) are filtered separately by the content
    // rule list. Only police main-frame navigations here, where ad sites
    // redirect us via `location.href = "https://devylora.com/..."`.
    guard navigationAction.targetFrame?.isMainFrame == true else {
      decisionHandler(.allow); return
    }
    let sourceURL = navigationAction.sourceFrame.request.url
    let target = navigationAction.request.url
    // The first navigation has no source-frame URL — always allow it.
    guard sourceURL != nil else {
      decisionHandler(.allow); return
    }
    let scrapeHost = scrapeURL.host?.lowercased() ?? ""
    let targetHost = target?.host?.lowercased() ?? ""
    if targetHost.isEmpty || Self.sameRegistrableDomain(targetHost, scrapeHost) {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
    }
  }

  /// Conservative same-registrable-domain check. Strips a leading `www.`,
  /// then checks for either equality or dotted-suffix match in either
  /// direction. Catches obvious mirror-subdomain redirects without needing
  /// a full Public Suffix List dependency.
  fileprivate static func sameRegistrableDomain(_ a: String, _ b: String) -> Bool {
    let strip: (String) -> String = { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    let ax = strip(a), bx = strip(b)
    if ax == bx { return true }
    if ax.hasSuffix("." + bx) || bx.hasSuffix("." + ax) { return true }
    return false
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    captureEarliestTitle(from: webView)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    captureEarliestTitle(from: webView)
    // SPA tab-fragment URLs (e.g. `https://ppv.to/#36`) load the homepage
    // HTML; the per-tab content only renders after the page's JS clicks the
    // matching tab. Nudge that click here — the observer in the injected
    // user script picks up the resulting DOM changes and extracts when they
    // settle.
    if let url = webView.url, !(url.fragment ?? "").isEmpty {
      Task { @MainActor [weak self] in await self?.clickSPATabIfFragment() }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(with: [], reason: .navError, errorMessage: error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    let nsErr = error as NSError
    // Cloudflare and similar may cancel the initial navigation as part of a
    // redirect chain; ignore. Same for our own `decidePolicyFor` cancels.
    if nsErr.code == NSURLErrorCancelled { return }
    finish(with: [], reason: .provisionalError, errorMessage: error.localizedDescription)
  }

  /// If the scrape URL has a hash fragment, look for the matching tab element
  /// on the page and click it. The injected user script's MutationObserver
  /// then sees the rendered tab content. No `setTimeout` afterwards — the
  /// observer handles waiting.
  fileprivate func clickSPATabIfFragment() async {
    guard let wv = webView, let url = wv.url,
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
          if (el && typeof el.click === 'function') { el.click(); return 'clicked'; }
        }
        return 'not_found';
      })()
    """
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      wv.evaluateJavaScript(js) { _, _ in cont.resume() }
    }
  }
}
