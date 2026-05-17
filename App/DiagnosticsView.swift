import SwiftUI

/// Read-only view that exposes the scraper's raw output for the selected source.
/// Lets us (and the user) diagnose why a source fails: are no links being
/// scraped (Cloudflare / JS-render issue)? Are links scraped but failing to
/// classify? Etc. Pushed from Settings → Source Diagnostics.
struct DiagnosticsView: View {
  @Environment(SourceRegistry.self) private var registry
  @State private var isRunning = false
  @State private var refreshKey = 0

  private var source: AnyStreamSource { registry.selectedSource }

  var body: some View {
    List {
      Section {
        sourceHeader
        Button {
          Task { await rerunScrape() }
        } label: {
          HStack {
            if isRunning {
              ProgressView().scaleEffect(0.8)
              Text("Re-running scrape…")
            } else {
              Image(systemName: "arrow.clockwise")
              Text("Re-run Scrape")
            }
          }
        }
        .disabled(isRunning)
      } header: {
        Text("Source")
      } footer: {
        Text("Re-running calls fetchAvailableLeagues, which scrapes the homepage plus per-league section probes. Each scrape is recorded below.")
      }

      let scrapes = registry.recentScrapes(for: source.id)
      if !scrapes.isEmpty {
        Section("Recent Scrapes") {
          ForEach(Array(scrapes.enumerated()), id: \.offset) { _, diag in
            scrapeRow(diag)
          }
        }
      }

      let links = registry.lastLinks(for: source.id)
      if !links.isEmpty {
        Section {
          ForEach(Array(links.enumerated()), id: \.offset) { _, link in
            linkRow(link)
          }
        } header: {
          HStack {
            Text("Last Extracted Links")
            Spacer()
            Text("\(links.count)").font(.caption).foregroundStyle(.secondary)
          }
        } footer: {
          Text("Every anchor + countdown card the scraper extracted from the most recent scrape. GAME badge = passes isGameLink. LEAGUE badge = detectLeague resolved.")
        }
      } else if !scrapes.isEmpty {
        Section {
          Label("No links extracted on the last successful scrape", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }

      // MARK: Logo Loading
      let logoEntries = TeamLogoDiagnostics.shared.entries
      let summary = TeamLogoDiagnostics.shared.summary
      if !logoEntries.isEmpty {
        Section {
          summaryRow(summary)
          ForEach(logoEntries.prefix(50)) { entry in
            logoRow(entry)
          }
        } header: {
          HStack {
            Text("Logo Loading")
            Spacer()
            Text("\(logoEntries.count)").font(.caption).foregroundStyle(.secondary)
          }
        } footer: {
          Text("Per-team logo resolution and image-fetch timings. resolve = TeamLogoCache → TeamLogoService lookup. fetch = URLSession PNG download (warmed by LogoPrefetcher). cacheHit = URLCache hit ⇒ instant render.")
        }
      }
    }
    .id(refreshKey)
    .listStyle(.insetGrouped)
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.large)
    .task {
      // First open: if we have no record yet for this source, run once.
      if registry.recentScrapes(for: source.id).isEmpty {
        await rerunScrape()
      }
    }
  }

  // MARK: - Subviews

  private var sourceHeader: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(source.name).font(.body.weight(.semibold))
      Text(source.baseURL.absoluteString)
        .font(.caption)
        .foregroundStyle(.blue)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func scrapeRow(_ diag: ScrapeDiagnostic) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        reasonBadge(diag.reason)
        Spacer()
        Text("\(diag.durationMs) ms")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(diag.url.absoluteString)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      if let title = diag.pageTitle, !title.isEmpty {
        Text("title: \(title)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      if let meta = diag.metaDescription, !meta.isEmpty {
        Text("meta: \(meta)")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      if let finalURL = diag.finalURL,
         finalURL.host?.lowercased() != diag.url.host?.lowercased() {
        Text("→ \(finalURL.absoluteString)")
          .font(.caption2.monospaced())
          .foregroundStyle(.orange)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      if !diag.observedAPIUrls.isEmpty {
        Text("observed \(diag.observedAPIUrls.count) API call\(diag.observedAPIUrls.count == 1 ? "" : "s")")
          .font(.caption2)
          .foregroundStyle(.purple)
      }
      HStack(spacing: 6) {
        Image(systemName: "link")
        Text("\(diag.linkCount) link\(diag.linkCount == 1 ? "" : "s")")
        Spacer()
        Text(Self.timeFmt.string(from: diag.timestamp))
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      if let msg = diag.errorMessage {
        Text(msg)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
    .padding(.vertical, 2)
  }

  private func reasonBadge(_ reason: ScrapeFinishReason) -> some View {
    let (label, color): (String, Color) = {
      switch reason {
      case .success:           return ("SUCCESS", .green)
      case .noLinks:           return ("NO LINKS", .orange)
      case .timeout:           return ("TIMEOUT", .red)
      case .navError:          return ("NAV ERROR", .red)
      case .provisionalError:  return ("PROV ERROR", .red)
      case .jsError:           return ("JS ERROR", .red)
      }
    }()
    return Text(label)
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  @ViewBuilder
  private func linkRow(_ link: ScrapedLink) -> some View {
    let isGame = passesIsGameLink(link)
    let league = CustomStreamSource.detectLeague(href: link.href, text: link.text)
    VStack(alignment: .leading, spacing: 4) {
      Text(link.href)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.blue)
      if !link.text.isEmpty {
        Text(link.text)
          .font(.caption)
          .lineLimit(2)
          .foregroundStyle(.primary)
      }
      if !link.status.isEmpty {
        Text("status: \(link.status)")
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(1)
      }
      if isGame || league != nil {
        HStack(spacing: 6) {
          if isGame {
            Text("GAME")
              .font(.caption2.weight(.bold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.green.opacity(0.15), in: Capsule())
              .foregroundStyle(.green)
          }
          if let l = league {
            Text("LEAGUE: \(l.displayName)")
              .font(.caption2.weight(.bold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(l.accentColor.opacity(0.15), in: Capsule())
              .foregroundStyle(l.accentColor)
          }
        }
      }
    }
    .padding(.vertical, 2)
  }

  /// Mirror of `CustomStreamSource.isGameLink`'s public contract — we can't
  /// call the private method, so the view re-implements a simplified version
  /// (URL pattern only) sufficient for the GAME badge.
  private func passesIsGameLink(_ link: ScrapedLink) -> Bool {
    guard let url = URL(string: link.href) else { return false }
    let segs = url.pathComponents.filter { $0 != "/" }
    if link.href.contains("#upcoming-") { return true }
    guard segs.count >= 2 else { return false }
    let path = url.path.lowercased()
    let text = link.text.lowercased()
    if text.contains(" vs ") || text.contains(" vs. ") || text.contains(" @ ") { return true }
    if path.contains("-vs-") || path.contains("-vs.") { return true }
    if !link.status.isEmpty && link.status.count < 60 { return true }
    if segs.contains(where: { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }) {
      return true
    }
    return false
  }

  // MARK: - Logo Loading subviews

  @ViewBuilder
  private func summaryRow(_ s: (total: Int, cached: Int, network: Int, failed: Int, pending: Int, unresolved: Int)) -> some View {
    HStack(spacing: 10) {
      summaryPill("TOTAL", value: s.total, color: .secondary)
      summaryPill("CACHE", value: s.cached, color: .green)
      summaryPill("NET", value: s.network, color: .blue)
      if s.failed > 0    { summaryPill("FAIL", value: s.failed, color: .red) }
      if s.pending > 0   { summaryPill("PEND", value: s.pending, color: .orange) }
      if s.unresolved > 0 { summaryPill("?", value: s.unresolved, color: .gray) }
    }
    .padding(.vertical, 2)
  }

  private func summaryPill(_ label: String, value: Int, color: Color) -> some View {
    VStack(spacing: 0) {
      Text("\(value)").font(.headline.monospacedDigit())
      Text(label).font(.caption2.weight(.bold)).foregroundStyle(color)
    }
    .frame(maxWidth: .infinity)
  }

  private func logoRow(_ entry: TeamLogoDiagnostics.Entry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(entry.team).font(.body.weight(.medium))
        Spacer()
        Text(entry.league.displayName)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(entry.league.accentColor)
      }
      if let url = entry.url {
        Text(url.absoluteString)
          .font(.caption.monospaced())
          .foregroundStyle(.blue)
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Text("no URL resolved")
          .font(.caption.monospaced())
          .foregroundStyle(.orange)
      }
      HStack(spacing: 6) {
        resolveBadge(entry.resolveSource)
        Text("resolve \(entry.resolveMs)ms")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
        fetchBadge(entry.fetchOutcome)
        if let ms = entry.fetchMs {
          Text("fetch \(ms)ms")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func resolveBadge(_ source: TeamLogoDiagnostics.ResolveSource) -> some View {
    let (label, color): (String, Color) = {
      switch source {
      case .staticTable:  return ("STATIC", .blue)
      case .espn:         return ("ESPN", .purple)
      case .unresolved:   return ("UNRESOLVED", .orange)
      }
    }()
    return Text(label)
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private func fetchBadge(_ outcome: TeamLogoDiagnostics.FetchOutcome) -> some View {
    let (label, color): (String, Color) = {
      switch outcome {
      case .pending:      return ("PENDING", .orange)
      case .cacheHit:     return ("CACHE", .green)
      case .networkOK:    return ("NET", .blue)
      case .failed:       return ("FAILED", .red)
      }
    }()
    return Text(label)
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  // MARK: - Actions

  private func rerunScrape() async {
    isRunning = true
    defer {
      isRunning = false
      refreshKey += 1
    }
    // v2.23: forceRefresh=true so the button actually re-scrapes the
    // network. Previously this would hit APIDiscovery's per-host cache
    // and return instantly without doing anything visible.
    _ = try? await source.fetchAvailableLeagues(forceRefresh: true)
  }

  private static let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()
}
