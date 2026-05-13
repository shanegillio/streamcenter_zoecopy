import Foundation

struct Game: Identifiable, Equatable, Hashable {
  let id: String
  let homeTeam: String
  let awayTeam: String
  let scheduledTime: Date?
  let isLive: Bool
  /// Live game state scraped from the source, e.g. "3-1 • 2nd Half", "3rd Quarter", "Overtime"
  let liveStatus: String?
  let pageURL: URL
  let league: SportLeague

  var title: String { "\(homeTeam) vs \(awayTeam)" }

  var displayTime: String {
    if isLive { return "LIVE" }
    guard let time = scheduledTime else { return "Time TBD" }

    // Show time in ET to match what the source site displays
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
