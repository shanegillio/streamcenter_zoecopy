import Foundation

struct Game: Identifiable, Equatable, Hashable {
  let id: String
  let homeTeam: String
  let awayTeam: String
  let scheduledTime: Date?
  let isLive: Bool
  let pageURL: URL
  let league: SportLeague

  var title: String { "\(homeTeam) vs \(awayTeam)" }

  var displayTime: String {
    if isLive { return "LIVE NOW" }
    guard let time = scheduledTime else { return "Today" }
    let formatter = DateFormatter()
    let calendar = Calendar.current
    if calendar.isDateInToday(time) {
      formatter.dateFormat = "h:mm a"
    } else if calendar.isDateInTomorrow(time) {
      formatter.dateFormat = "'Tomorrow' h:mm a"
    } else {
      formatter.dateFormat = "EEE, h:mm a"
    }
    formatter.amSymbol = "AM"
    formatter.pmSymbol = "PM"
    return formatter.string(from: time)
  }

  static func == (lhs: Game, rhs: Game) -> Bool { lhs.id == rhs.id }

  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
