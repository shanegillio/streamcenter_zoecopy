import SwiftUI

// MARK: - Theme
//
// The redesign themes the whole app around a dark "TV guide" look: a slate
// background with periwinkle/indigo panels and rows. Colors are centralized
// here so the home screen, guide grid, and settings all match.

enum GuideTheme {
  /// App background — dark slate.
  static let background = Color(red: 0.16, green: 0.20, blue: 0.27)
  /// Slightly lifted slate for the guide body.
  static let surface = Color(red: 0.19, green: 0.24, blue: 0.32)
  /// Periwinkle/indigo panel used for cards, rows, and the channel column.
  static let panel = Color(red: 0.29, green: 0.34, blue: 0.53)
  /// Brighter panel for selected / interactive cells.
  static let panelBright = Color(red: 0.36, green: 0.42, blue: 0.66)
  /// Header bars (date row, time row).
  static let headerBar = Color(red: 0.23, green: 0.28, blue: 0.40)
  /// Live game block tint.
  static let live = Color(red: 0.78, green: 0.20, blue: 0.22)
  static let text = Color.white
  static let textDim = Color.white.opacity(0.6)

  /// Points per minute on the timeline. Tuned so ~2 hours of programming
  /// fills the timeline width on a phone (≈300 pt ÷ 120 min), giving the
  /// half-hour tick labels room to breathe.
  static let pointsPerMinute: CGFloat = 2.5
  static let rowHeight: CGFloat = 72
  static let channelColumnWidth: CGFloat = 64
  static let headerHeight: CGFloat = 34
  /// Minimum rendered width for a very short event block.
  static let minBlockWidth: CGFloat = 90
}

// MARK: - Liquid glass helper

/// Applies an iOS 26 liquid-glass background in the given shape, falling back
/// to an ultra-thin material on the iOS 17 deployment floor. Used for the
/// home-screen controls so they match the system nav buttons in Settings.
private struct GlassBackground<S: Shape>: ViewModifier {
  let shape: S
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content.background(.ultraThinMaterial, in: shape)
    }
  }
}

extension View {
  /// Liquid-glass (iOS 26) / material (earlier) background clipped to `shape`.
  func glassBackground<S: Shape>(in shape: S) -> some View {
    modifier(GlassBackground(shape: shape))
  }
}

// MARK: - Channel model

/// One row in the TV guide. A league with several concurrent live games is
/// split into multiple channels (MLB 1, MLB 2, …) so overlapping games never
/// share a row.
struct GuideChannel: Identifiable {
  let id: String
  let league: SportLeague
  /// 1-based index within the league. `nil` when the league has only one row.
  let number: Int?
  /// Games on this row, sorted by start time, guaranteed non-overlapping.
  let games: [Game]

  var displayNumber: String { number.map(String.init) ?? "" }
}

/// Pure layout engine: turns a flat games list into guide channels plus the
/// shared time axis used to position blocks.
enum TVGuideLayout {
  struct Axis {
    let start: Date
    let end: Date
    var totalMinutes: CGFloat { CGFloat(end.timeIntervalSince(start) / 60) }
    var totalWidth: CGFloat { max(totalMinutes * GuideTheme.pointsPerMinute, 320) }

    /// Half-hour tick marks across the window, for the time header.
    var ticks: [Date] {
      var out: [Date] = []
      var t = start
      while t <= end {
        out.append(t)
        t = t.addingTimeInterval(30 * 60)
      }
      return out
    }

    func x(for date: Date) -> CGFloat {
      CGFloat(date.timeIntervalSince(start) / 60) * GuideTheme.pointsPerMinute
    }
  }

  /// Effective start time used for positioning: live games with no/elapsed
  /// time anchor to "now"; everything else uses scheduledTime.
  static func startTime(for game: Game, now: Date) -> Date {
    if let t = game.scheduledTime, game.timeIsKnown { return t }
    return now
  }

  static func endTime(for game: Game, now: Date) -> Date {
    let s = startTime(for: game, now: now)
    let dur = TimeInterval(game.league.typicalDurationMinutes * 60)
    let natural = s.addingTimeInterval(dur)
    // A live game that has already run past its typical length keeps growing
    // until "now" so the block reflects that it's still on the air.
    if game.isLive, now > natural { return now.addingTimeInterval(30 * 60) }
    return natural
  }

  /// Calendar pinned to ET so the timeline's half-hour grid lines up with the
  /// ET game-time labels used throughout the app.
  private static var etCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York") ?? c.timeZone
    return c
  }

  static func axis(for games: [Game], now: Date) -> Axis {
    let cal = etCalendar
    // The timeline always starts at the current half hour, so "now" sits at
    // the left edge and live games (which began earlier) are clamped to start
    // flush against the channel column — no empty pre-now gap.
    let start = floorToHalfHour(now, cal: cal)
    var maxEnd = now.addingTimeInterval(2 * 60 * 60)
    for g in games {
      let e = endTime(for: g, now: now)
      if e > maxEnd { maxEnd = e }
    }
    return Axis(start: start, end: maxEnd)
  }

  private static func floorToHalfHour(_ date: Date, cal: Calendar) -> Date {
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    var c = comps
    c.minute = (comps.minute ?? 0) >= 30 ? 30 : 0
    c.second = 0
    return cal.date(from: c) ?? date
  }

  /// Build the channel rows. Leagues are ordered by popularity; within a
  /// league, games are greedily packed into the fewest non-overlapping rows.
  static func channels(live: [Game], upcoming: [Game], now: Date) -> [GuideChannel] {
    let all = live + upcoming
    let byLeague = Dictionary(grouping: all, by: { $0.league })
    let orderedLeagues = byLeague.keys.sorted {
      if $0.popularityRank != $1.popularityRank {
        return $0.popularityRank < $1.popularityRank
      }
      return $0.displayName < $1.displayName
    }

    var channels: [GuideChannel] = []
    for league in orderedLeagues {
      let games = (byLeague[league] ?? []).sorted {
        startTime(for: $0, now: now) < startTime(for: $1, now: now)
      }
      // Greedy row packing: place each game in the first row whose last
      // block ends before this one starts.
      var rows: [[Game]] = []
      var rowEnds: [Date] = []
      for g in games {
        let s = startTime(for: g, now: now)
        if let idx = rowEnds.firstIndex(where: { $0 <= s }) {
          rows[idx].append(g)
          rowEnds[idx] = endTime(for: g, now: now)
        } else {
          rows.append([g])
          rowEnds.append(endTime(for: g, now: now))
        }
      }
      let multi = rows.count > 1
      for (i, row) in rows.enumerated() {
        channels.append(GuideChannel(
          id: "\(league.rawValue)-\(i)",
          league: league,
          number: multi ? i + 1 : nil,
          games: row
        ))
      }
    }
    // Channels with a live game always sit at the top. Within each group
    // (live, then upcoming) order chronologically by the next game on the
    // channel, so what's on now / up next leads. Ties break on popularity
    // then name for stable ordering.
    return channels.sorted { a, b in
      let aLive = a.games.contains { $0.isLive }
      let bLive = b.games.contains { $0.isLive }
      if aLive != bLive { return aLive }
      let sa = a.games.map { startTime(for: $0, now: now) }.min() ?? .distantFuture
      let sb = b.games.map { startTime(for: $0, now: now) }.min() ?? .distantFuture
      if sa != sb { return sa < sb }
      if a.league.popularityRank != b.league.popularityRank {
        return a.league.popularityRank < b.league.popularityRank
      }
      return a.league.displayName < b.league.displayName
    }
  }
}

// MARK: - TV guide grid

/// The scrollable TV-guide grid: a sticky channel column on the left and a
/// horizontally scrollable timeline of game blocks on the right. The whole
/// thing scrolls vertically.
struct TVGuideView: View {
  let live: [Game]
  let upcoming: [Game]
  let selectedGameID: String?
  /// Width available to the whole guide (card width). Used to give the inner
  /// horizontal ScrollView a definite width so it doesn't report an oversized
  /// ideal width and get centered, which used to inset the channel column.
  var availableWidth: CGFloat = 0
  let onSelect: (Game) -> Void

  private var now: Date { Date() }
  private var channels: [GuideChannel] {
    TVGuideLayout.channels(live: live, upcoming: upcoming, now: now)
  }
  private var axis: TVGuideLayout.Axis {
    TVGuideLayout.axis(for: live + upcoming, now: now)
  }

  var body: some View {
    VStack(spacing: 0) {
      dateBar
      HStack(alignment: .top, spacing: 0) {
        channelColumn
        ScrollView(.horizontal, showsIndicators: false) {
          VStack(spacing: 0) {
            GuideTimeHeader(axis: axis)
            ForEach(channels) { channel in
              GuideTimelineRow(
                channel: channel,
                axis: axis,
                now: now,
                selectedGameID: selectedGameID,
                onSelect: onSelect
              )
              Divider().overlay(Color.black.opacity(0.25))
            }
          }
          // Red "now" line spanning the header + all rows (visual only).
          .overlay(alignment: .topLeading) {
            Rectangle()
              .fill(Color.red)
              .frame(width: 2)
              .offset(x: axis.x(for: now))
              .allowsHitTesting(false)
          }
        }
        .frame(width: max(0, availableWidth - GuideTheme.channelColumnWidth))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(GuideTheme.surface)
  }

  private var dateBar: some View {
    Text(Self.dateFormatter.string(from: now))
      .font(.headline.weight(.semibold))
      .foregroundStyle(GuideTheme.text)
      .frame(maxWidth: .infinity, alignment: .center)
      .multilineTextAlignment(.center)
      .padding(.vertical, 9)
      .background(GuideTheme.headerBar)
  }

  private var channelColumn: some View {
    VStack(spacing: 0) {
      // Spacer cell that aligns with the time header.
      HStack(spacing: 3) {
        Image(systemName: "tv")
          .font(.system(size: 9, weight: .semibold))
        Text("Ch.")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundStyle(GuideTheme.textDim)
      .padding(.leading, 8)
      .frame(width: GuideTheme.channelColumnWidth, height: GuideTheme.headerHeight, alignment: .leading)
      .background(GuideTheme.headerBar)

      ForEach(channels) { channel in
        GuideChannelCell(channel: channel)
        Divider().overlay(Color.black.opacity(0.25))
      }
    }
  }

  static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "America/New_York")
    f.dateFormat = "EEEE, MMMM d, yyyy"
    return f
  }()
}

/// Left-column cell: league logo + optional channel number.
struct GuideChannelCell: View {
  let channel: GuideChannel

  var body: some View {
    HStack(spacing: 4) {
      LeagueIcon(league: channel.league, size: 28)
      if let n = channel.number {
        Text("\(n)")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(GuideTheme.text)
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, 8)
    .frame(width: GuideTheme.channelColumnWidth, height: GuideTheme.rowHeight, alignment: .leading)
    .background(GuideTheme.panel)
  }
}

/// Time header showing half-hour tick labels across the window.
struct GuideTimeHeader: View {
  let axis: TVGuideLayout.Axis

  var body: some View {
    ZStack(alignment: .leading) {
      Color.clear
      ForEach(axis.ticks, id: \.self) { tick in
        Text(Self.timeFormatter.string(from: tick))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(GuideTheme.textDim)
          .fixedSize()
          .offset(x: axis.x(for: tick) + 6)
      }
    }
    .frame(width: axis.totalWidth, height: GuideTheme.headerHeight, alignment: .leading)
    .background(GuideTheme.headerBar)
  }

  static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    // Game blocks are labeled in ET (Game.displayTime), so the axis must
    // match or the timeline reads inconsistently.
    f.timeZone = TimeZone(identifier: "America/New_York")
    f.dateFormat = "h:mm a"
    return f
  }()
}

/// One channel's timeline: game blocks positioned by start time.
struct GuideTimelineRow: View {
  let channel: GuideChannel
  let axis: TVGuideLayout.Axis
  let now: Date
  let selectedGameID: String?
  let onSelect: (Game) -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear
      ForEach(channel.games) { game in
        let start = TVGuideLayout.startTime(for: game, now: now)
        let end = TVGuideLayout.endTime(for: game, now: now)
        let x = max(0, axis.x(for: start))
        let w = max(GuideTheme.minBlockWidth, axis.x(for: end) - axis.x(for: start))
        GuideGameBlock(game: game, isSelected: game.id == selectedGameID)
          .frame(width: w, height: GuideTheme.rowHeight - 10)
          .offset(x: x, y: 5)
          .onTapGesture { onSelect(game) }
      }
    }
    .frame(width: axis.totalWidth, height: GuideTheme.rowHeight, alignment: .leading)
    .background(GuideTheme.surface)
  }
}

/// A single game block in the guide timeline.
struct GuideGameBlock: View {
  let game: Game
  let isSelected: Bool
  @Environment(FavoritesStore.self) private var favorites

  private var usesLeagueFallback: Bool {
    ESPNScoreboardService.apiPath(for: game.league) == nil
  }
  private var isSingle: Bool {
    game.isEvent || game.awayTeam.isEmpty || game.awayTeam == "TBD"
  }
  private var isFavorited: Bool { favorites.isFavoriteGame(game) }

  var body: some View {
    HStack(spacing: 9) {
      logos
      teamNames
      Spacer(minLength: 4)
      status
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 11)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(game.isLive ? GuideTheme.live : GuideTheme.panelBright)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2.5)
    )
    .overlay(alignment: .topLeading) {
      if isFavorited {
        Image(systemName: "star.fill")
          .font(.system(size: 11))
          .foregroundStyle(.yellow)
          .padding(5)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private var teamNames: some View {
    if isSingle {
      Text(game.homeTeam)
        .font(.system(size: 13, weight: .bold))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .center, spacing: 1) {
        Text(game.homeTeam)
          .font(.system(size: 13, weight: .bold))
          .lineLimit(1)
        Text("vs")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.white.opacity(0.6))
        Text(game.awayTeam)
          .font(.system(size: 13, weight: .bold))
          .lineLimit(1)
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    if game.isLive {
      HStack(spacing: 4) {
        Circle().fill(.white).frame(width: 6, height: 6)
        Text("LIVE").font(.system(size: 13, weight: .heavy))
      }
    } else {
      Text(game.displayTime)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
        .fixedSize()
    }
  }

  @ViewBuilder
  private var logos: some View {
    if game.isEvent || usesLeagueFallback {
      LeagueIcon(league: game.league, size: 30)
    } else {
      VStack(spacing: 3) {
        TeamLogo(teamName: game.homeTeam, league: game.league, size: 20)
        TeamLogo(teamName: game.awayTeam, league: game.league, size: 20)
      }
    }
  }
}
