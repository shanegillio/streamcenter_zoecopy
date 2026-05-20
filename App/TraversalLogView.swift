import SwiftUI
import AVKit

/// v2.46: read-only browse + detail surface for the TraversalLog
/// captured during normal use. Shows aggregate stats at the top and a
/// newest-first list of past tap-to-play sessions. Each row chips
/// summarize the outcome at a glance (hop count, stream captured,
/// playback marked). Tap into a row for the full event timeline +
/// manual outcome marking.
struct TraversalLogView: View {
  @StateObject private var log = TraversalLog.shared

  var body: some View {
    List {
      Section {
        statsBand
      }
      Section("Sessions") {
        if log.sessions.isEmpty {
          Text("Tap a game to start logging. Each tap records a session here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } else {
          ForEach(log.sessions) { session in
            NavigationLink(value: session.id) {
              row(for: session)
            }
          }
        }
      }
    }
    .navigationTitle("Traversal Log")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(for: UUID.self) { id in
      if let session = log.sessions.first(where: { $0.id == id }) {
        TraversalSessionDetailView(session: session)
      } else {
        Text("Session not found").foregroundStyle(.secondary)
      }
    }
    .toolbar {
      if !log.sessions.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button(role: .destructive) {
              log.clearAll()
            } label: {
              Label("Clear all sessions", systemImage: "trash")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
    }
  }

  // MARK: Aggregate stats

  private var statsBand: some View {
    let s = log.aggregateStats(windowDays: 7)
    return VStack(alignment: .leading, spacing: 8) {
      Text("Last 7 days")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        statChip(label: "Attempts", value: "\(s.totalSessions)")
        statChip(label: "Hop ≥ 2", value: "\(s.reachedHop2)",
                 color: s.reachedHop2 > 0 ? .green : .secondary)
        statChip(label: "Streams", value: "\(s.capturedStreams)",
                 color: s.capturedStreams > 0 ? .blue : .secondary)
        statChip(label: "Worked", value: "\(s.outcomeWorked)",
                 color: s.outcomeWorked > 0 ? .green : .secondary)
      }
      if !s.perSource.isEmpty {
        Divider().padding(.vertical, 2)
        Text("Per source").font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(Array(s.perSource.enumerated()), id: \.offset) { _, e in
          HStack(spacing: 8) {
            Text(e.name)
              .font(.caption.weight(.medium))
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(e.attempts)").font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
            Text("→ \(e.hop2)").font(.caption2.monospacedDigit())
              .foregroundStyle(e.hop2 > 0 ? .green : .secondary)
            Text("📡 \(e.captured)").font(.caption2.monospacedDigit())
              .foregroundStyle(e.captured > 0 ? .blue : .secondary)
            Text("✓ \(e.worked)").font(.caption2.monospacedDigit())
              .foregroundStyle(e.worked > 0 ? .green : .secondary)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func statChip(label: String, value: String, color: Color = .blue) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title3.monospacedDigit().weight(.semibold))
        .foregroundStyle(color)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: List row

  @ViewBuilder
  private func row(for session: TraversalSession) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(session.sourceName)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text("•").foregroundStyle(.secondary)
        Text(session.gameTitle)
          .font(.subheadline)
          .lineLimit(1)
        Spacer()
        Text(session.startedAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        // v2.47: meaningful hop count (collapses TLD/trailing-slash
        // redirects so the chip matches user perception of "different page").
        hopChip(session.meaningfulHopCount)
        streamChip(session)
        outcomeChip(session)
      }
      // v2.49: surface why a session stalled at Hop 1 right in the row.
      // Without this, diagnosing 5-of-6-sources-stuck-at-homepage means
      // opening every session detail. Shows the most recent walk verdict.
      if let summary = walkSummary(for: session) {
        Text(summary)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.vertical, 2)
  }

  /// v2.49: compact one-line summary of the walk's most recent verdict.
  /// Reads the session's events in reverse — prefers "clicked"/"category_click"
  /// (proof we navigated) over "scan"/"cat_scan" (proof we tried).
  private func walkSummary(for session: TraversalSession) -> String? {
    for ev in session.events.reversed() {
      switch ev.kind {
      case "clicked":         return "walk: clicked \(shortInfo(ev.info))"
      case "category_click":  return "walk: category → \(shortInfo(ev.info))"
      case "click_failed":    return "walk: click failed (\(shortInfo(ev.info)))"
      case "auth_wall":       return "auth wall (\(shortInfo(ev.info)))"
      case "load_failure":    return "load failed (\(shortInfo(ev.info)))"
      case "cat_scan":        return "cat \(shortInfo(ev.info))"
      case "scan":            return "scan \(shortInfo(ev.info))"
      default: continue
      }
    }
    return nil
  }

  private func shortInfo(_ s: String) -> String {
    s.count > 60 ? String(s.prefix(60)) + "…" : s
  }

  private func hopChip(_ hop: Int) -> some View {
    let color: Color = hop >= 2 ? .green : (hop == 1 ? .yellow : .gray)
    return Text("Hop \(hop)")
      .font(.caption2.weight(.semibold).monospacedDigit())
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(color.opacity(0.18), in: Capsule())
      .foregroundStyle(color)
  }

  private func streamChip(_ session: TraversalSession) -> some View {
    let n = session.capturedStreams.count
    let color: Color = n > 0 ? .blue : .gray
    return Text(n > 0 ? "📡 \(n)" : "no stream")
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(color.opacity(0.18), in: Capsule())
      .foregroundStyle(color)
  }

  @ViewBuilder
  private func outcomeChip(_ session: TraversalSession) -> some View {
    if let o = session.playbackOutcome {
      let (label, color): (String, Color) = {
        switch o {
        case .worked: return ("✓ worked", .green)
        case .failed: return ("✗ failed", .red)
        case .unsure: return ("? unsure", .orange)
        }
      }()
      Text(label)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
  }
}

// MARK: - Session detail

struct TraversalSessionDetailView: View {
  let session: TraversalSession
  @State private var avPlayer: AVPlayer? = nil
  @State private var outcomeJustMarked: TraversalSession.PlaybackOutcome? = nil

  var body: some View {
    List {
      // Header
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text(session.gameTitle).font(.headline)
          Text("\(session.sourceName) — \(session.gameLeague.uppercased())")
            .font(.caption).foregroundStyle(.secondary)
          Text(session.sourceURL)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
          if let durationMs = session.durationMs {
            Text("Duration: \(durationMs) ms")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      // Navigation hops — show both meaningful and raw so user sees
      // whether trivial redirects inflated the raw count.
      Section("Navigation (\(session.meaningfulHopCount) meaningful, \(session.maxHopReached) raw)") {
        ForEach(Array(session.navigationHops.enumerated()), id: \.offset) { idx, hop in
          HStack(alignment: .top, spacing: 8) {
            Text("\(idx + 1).")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 18, alignment: .trailing)
            Text(hop)
              .font(.caption.monospaced())
              .foregroundStyle(idx == 0 ? .secondary : .primary)
              .lineLimit(2).truncationMode(.middle)
          }
        }
      }
      // Captured streams
      if !session.capturedStreams.isEmpty {
        Section("Captured streams (\(session.capturedStreams.count))") {
          ForEach(session.capturedStreams, id: \.self) { urlStr in
            HStack(spacing: 8) {
              Image(systemName: "play.circle.fill")
                .foregroundStyle(.green)
              Text(urlStr)
                .font(.caption.monospaced())
                .lineLimit(2).truncationMode(.middle)
              Spacer()
              Button("Play") {
                playURL(urlStr)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.mini)
            }
          }
        }
      }
      // Event timeline
      Section("Events (\(session.events.count))") {
        if session.events.isEmpty {
          Text("No events recorded").font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(session.events) { ev in
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Image(systemName: eventIcon(ev.kind))
                  .font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(eventColor(ev.kind))
                Text(ev.kind).font(.caption.weight(.semibold))
                Spacer()
                Text(ev.at, format: .dateTime.hour().minute().second())
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
              }
              Text(ev.info)
                .font(.caption2.monospaced())
                .lineLimit(3)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }
      }
      // Outcome marking
      Section("Did playback work?") {
        HStack(spacing: 12) {
          outcomeButton(.worked, label: "Worked", icon: "checkmark.circle.fill", color: .green)
          outcomeButton(.failed, label: "Didn't",  icon: "xmark.circle.fill",     color: .red)
          outcomeButton(.unsure, label: "Unsure",  icon: "questionmark.circle.fill", color: .orange)
        }
        .frame(maxWidth: .infinity)
      }
    }
    .navigationTitle("Session")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: Binding(get: { avPlayer != nil }, set: { if !$0 { avPlayer = nil } })) {
      if let p = avPlayer {
        VideoPlayer(player: p)
          .ignoresSafeArea()
          .onAppear { p.play() }
      }
    }
  }

  private func playURL(_ urlStr: String) {
    guard let url = URL(string: urlStr) else { return }
    // We don't have cookies / referer saved per stream in TraversalLog
    // (only the URL); attempt a bare play with a mobile UA. If the
    // stream needs auth, the user can retry from PlayerView's strip.
    var headers: [String: String] = [:]
    headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    if let host = URL(string: session.sourceURL)?.host {
      headers["Referer"] = "https://\(host)"
      headers["Origin"]  = "https://\(host)"
    }
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    avPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
  }

  private func outcomeButton(_ outcome: TraversalSession.PlaybackOutcome,
                             label: String, icon: String, color: Color) -> some View {
    let isCurrent = (outcomeJustMarked ?? session.playbackOutcome) == outcome
    return Button {
      TraversalLog.shared.markOutcome(session.id, outcome)
      outcomeJustMarked = outcome
    } label: {
      VStack(spacing: 4) {
        Image(systemName: icon).font(.title3)
        Text(label).font(.caption.weight(.semibold))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .background(isCurrent ? color.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
      .foregroundStyle(isCurrent ? color : .secondary)
    }
    .buttonStyle(.plain)
  }

  private func eventIcon(_ kind: String) -> String {
    switch kind {
    case "clicked":         return "hand.tap.fill"
    case "category_click":  return "folder.fill"
    case "click_failed":    return "xmark.octagon.fill"
    case "scan":            return "magnifyingglass"
    case "cat_scan":        return "magnifyingglass.circle"
    case "navigation":      return "arrow.right.circle.fill"
    case "stream_url":      return "antenna.radiowaves.left.and.right"
    case "iframe_drill":    return "arrow.down.right.circle"
    case "auth_wall":       return "lock.fill"
    case "load_failure":    return "exclamationmark.triangle.fill"
    case "user_play":       return "play.circle.fill"
    case "auto_play":       return "play.fill"
    case "stream_probed":   return "checkmark.shield"
    default: return "circle"
    }
  }
  private func eventColor(_ kind: String) -> Color {
    switch kind {
    case "clicked", "category_click", "navigation", "stream_url", "user_play", "auto_play": return .green
    case "click_failed", "load_failure": return .red
    case "scan", "cat_scan": return .yellow
    case "iframe_drill": return .cyan
    case "auth_wall": return .orange
    case "stream_probed": return .blue
    default: return .secondary
    }
  }
}
