import Foundation

/// One aggregator's stream listing for a particular game. Multiple
/// aggregators can serve the same game; v2.23's HomeView orchestrator
/// collects every match into `Game.streamURLs` so on-tap resolution
/// can try each in turn (parallel try-all is planned for v2.24).
struct GameStreamCandidate: Equatable, Hashable, Codable {
  /// `AnyStreamSource.id` — the aggregator providing this URL.
  let sourceID: String
  /// Per-game landing page on the aggregator (`game.pageURL` equivalent).
  let pageURL: URL
}

struct Game: Identifiable, Equatable, Hashable {
  let id: String
  let homeTeam: String
  let awayTeam: String
  let scheduledTime: Date?
  /// False when we know the date (from a URL like /YYYY-MM-DD/) but couldn't
  /// parse a clock time. Used to suppress the misleading "12:00 AM ET" default.
  let timeIsKnown: Bool
  let isLive: Bool
  /// Live game state scraped from the source, e.g. "3-1 • 2nd Half", "3rd Quarter", "Overtime"
  let liveStatus: String?
  /// True for single-team events (drafts, combines, all-star games, etc.)
  let isEvent: Bool
  /// True when the source site indicates this stream requires a paid subscription.
  let isPremium: Bool
  /// Primary stream URL (legacy field). For ESPN-canonical games that
  /// matched at least one aggregator, this is `streamURLs.first?.pageURL`.
  /// For aggregator-only gap-fill games, this is the aggregator's URL.
  /// Kept for compatibility with `PlayerView`'s existing constructor.
  let pageURL: URL
  /// v2.23: every aggregator that produced a matching listing for this
  /// game gets an entry here. Empty for ESPN-canonical games where no
  /// enabled aggregator surfaced a listing — on-tap resolution would
  /// have to fall back to LLM-driven search (planned for v2.24).
  let streamURLs: [GameStreamCandidate]
  let league: SportLeague

  init(id: String, homeTeam: String, awayTeam: String, scheduledTime: Date?,
       timeIsKnown: Bool = true,
       isLive: Bool, liveStatus: String?, isEvent: Bool = false, isPremium: Bool = false,
       pageURL: URL,
       streamURLs: [GameStreamCandidate] = [],
       league: SportLeague) {
    self.id = id
    self.homeTeam = homeTeam
    self.awayTeam = awayTeam
    self.scheduledTime = scheduledTime
    self.timeIsKnown = timeIsKnown
    self.isLive = isLive
    self.liveStatus = liveStatus
    self.isEvent = isEvent
    self.isPremium = isPremium
    self.pageURL = pageURL
    self.streamURLs = streamURLs
    self.league = league
  }

  var title: String { isEvent || awayTeam.isEmpty ? homeTeam : "\(homeTeam) vs \(awayTeam)" }

  /// True when the source flagged the game live, or when its known start time
  /// has already passed but the game hasn't yet run past its league's typical
  /// duration. Some sources list an in-progress game with only a start time and
  /// never set `isLive`; this treats such a game as live so the guide shows it
  /// as on-the-air rather than as an upcoming start time.
  var isCurrentlyLive: Bool {
    if isLive { return true }
    guard let start = scheduledTime, timeIsKnown else { return false }
    let now = Date()
    guard start <= now else { return false }
    let dur = TimeInterval(league.typicalDurationMinutes * 60)
    return now < start.addingTimeInterval(dur)
  }

  // Day label: nil for today, "Tomorrow", or short weekday name for further out.
  var displayDay: String? {
    guard !isLive, let time = scheduledTime else { return nil }
    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    if etCal.isDateInToday(time) { return nil }
    if etCal.isDateInTomorrow(time) { return "Tomorrow" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = etTZ
    fmt.dateFormat = "EEE, MMM d"
    return fmt.string(from: time)
  }

  // Clock time only, e.g. "7:00 PM ET". Shows "LIVE", a final-score line for
  // completed ESPN-enriched games, or "Upcoming" when no time/state is known.
  var displayTime: String {
    if isLive { return "LIVE" }
    // Completed ESPN events come back with scheduledTime=nil + timeIsKnown=false
    // but with a populated liveStatus ("FT 2-1"). Surface that instead of the
    // generic "Upcoming" placeholder so the user sees "this game has happened
    // already" at a glance.
    if scheduledTime == nil || !timeIsKnown,
       let status = liveStatus, !status.isEmpty {
      return status
    }
    // v2.19: defensive past-time guard. When a source (ppv.to) lists a game
    // with a `starts_at` already in the past and ESPN didn't catch it, the
    // clock time below would render misleadingly as "8:00 PM ET" for a game
    // that finished hours ago. If we've crossed the typical game-duration
    // window (4 h), prefer liveStatus when present, otherwise return "Final".
    if let time = scheduledTime, timeIsKnown,
       time.timeIntervalSinceNow < -4 * 60 * 60 {
      if let status = liveStatus, !status.isEmpty { return status }
      return "Final"
    }
    guard let time = scheduledTime, timeIsKnown else { return "Upcoming" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/New_York")!
    fmt.amSymbol = "AM"
    fmt.pmSymbol = "PM"
    fmt.dateFormat = "h:mm a 'ET'"
    return fmt.string(from: time)
  }

  static func == (lhs: Game, rhs: Game) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
