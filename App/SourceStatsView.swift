import SwiftUI

/// v2.32 trimmed: read-only per-source health stats from SourceHealth.
/// Dropped the v2.30/v2.31 Templates / Team-slugs / Play-hosts chips
/// after the SourceLearningStore deletion.
struct SourceStatsView: View {
  @Environment(SourceRegistry.self) private var registry
  @StateObject private var health = SourceHealth.shared

  var body: some View {
    List {
      Section {
        if registry.enabledSources.isEmpty {
          Text("No enabled sources yet. Add one from Source Site.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } else {
          ForEach(rows, id: \.sourceID) { row in
            SourceStatsRow(row: row)
          }
        }
      } footer: {
        Text("Stats accumulate over the last 7 days as you tap games. " +
             "Sources with low success rate after a few attempts get " +
             "demoted in the player's attempt order.")
      }
    }
    .navigationTitle("Source Stats")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var rows: [Row] {
    registry.enabledSources.map { src in
      let s = health.stats[src.id]
      return Row(
        sourceID: src.id,
        name: src.name,
        attempts: s?.attempts ?? 0,
        successes: s?.successes ?? 0,
        parkingCount: s?.parkingDetections ?? 0,
        successRate: s?.successRate,
        lastSuccessAt: s?.lastSuccessAt
      )
    }
    .sorted { a, b in
      let ra = a.successRate ?? -1
      let rb = b.successRate ?? -1
      if ra != rb { return ra > rb }
      return a.attempts > b.attempts
    }
  }

  struct Row {
    let sourceID: String
    let name: String
    let attempts: Int
    let successes: Int
    let parkingCount: Int
    let successRate: Double?
    let lastSuccessAt: Date?
  }
}

private struct SourceStatsRow: View {
  let row: SourceStatsView.Row

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(row.name).font(.headline)
        Spacer()
        Text(rateLabel)
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(rateColor)
      }
      HStack(spacing: 14) {
        statChip(label: "Attempts", value: "\(row.attempts)")
        statChip(label: "Successes", value: "\(row.successes)")
        if row.parkingCount > 0 {
          statChip(label: "Parking", value: "\(row.parkingCount)", color: .orange)
        }
      }
      if let at = row.lastSuccessAt {
        Text("Last success: \(at.formatted(.relative(presentation: .named)))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var rateLabel: String {
    guard let rate = row.successRate else { return "—" }
    return String(format: "%.0f%%", rate * 100)
  }

  private var rateColor: Color {
    guard let rate = row.successRate, row.attempts >= 3 else { return .secondary }
    if rate >= 0.5 { return .green }
    if rate >= 0.2 { return .yellow }
    return .red
  }

  private func statChip(label: String, value: String, color: Color = .blue) -> some View {
    HStack(spacing: 4) {
      Text(value).font(.caption.weight(.semibold))
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(color.opacity(0.12), in: Capsule())
    .foregroundStyle(color)
  }
}
