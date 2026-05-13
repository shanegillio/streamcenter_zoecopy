import Foundation

struct Game: Identifiable, Equatable, Hashable {
  let id: String
  let homeTeam: String
  let awayTeam: String
  let scheduledTime: Date?
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
       isLive: Bool, liveStatus: String?, isEvent: Bool = false, isPremium: Bool = false,
       pageURL: URL, league: SportLeague) {
    self.id = id
    self.homeTeam = homeTeam
    self.awayTeam = awayTeam
    self.scheduledTime = scheduledTime
    self.isLive = isLive
    self.liveStatus = liveStatus
    self.isEvent = isEvent
    self.isPremium = isPremium
    self.pageURL = pageURL
    self.league = league
  }

  var title: String { isEvent || awayTeam.isEmpty ? homeTeam : "\(homeTeam) vs \(awayTeam)" }

  var displayTime: String {
    if isLive { return "LIVE" }
    guard let time = scheduledTime else { return "Time TBD" }

    let etTZ = TimeZone(identifier: "America/New_York")!
    var etCal = Calendar(identifier: .gregorian)
    etCal.timeZone = etTZ
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = etTZ
    formatter.amSymbol = "AM"
    formatter.pmSymbol = "PM"

    if etCal.isDateInToday(time) {
      formatter.dateFormat = "h:mm a 'ET'"
    } else if etCal.isDateInTomorrow(time) {
      formatter.dateFormat = "'Tomorrow' h:mm a 'ET'"
    } else {
      formatter.dateFormat = "EEE h:mm a 'ET'"
    }
    return formatter.string(from: time)
  }

  static func == (lhs: Game, rhs: Game) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
