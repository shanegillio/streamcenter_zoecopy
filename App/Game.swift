import Foundation

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
  let pageURL: URL
  let league: SportLeague

  init(id: String, homeTeam: String, awayTeam: String, scheduledTime: Date?,
       timeIsKnown: Bool = true,
       isLive: Bool, liveStatus: String?, isEvent: Bool = false, isPremium: Bool = false,
       pageURL: URL, league: SportLeague) {
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
    self.league = league
  }

  var title: String { isEvent || awayTeam.isEmpty ? homeTeam : "\(homeTeam) vs \(awayTeam)" }

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

  // Clock time only, e.g. "7:00 PM ET". Shows "LIVE" or "Upcoming" when no time is known.
  var displayTime: String {
    if isLive { return "LIVE" }
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
