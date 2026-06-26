import SwiftUI

enum SportLeague: String, CaseIterable, Identifiable, Codable, Hashable {
  case nfl
  case nba
  case mlb
  case nhl
  case mma
  case ufc
  case boxing
  case soccer
  case premierLeague
  case laLiga
  case serieA
  case bundesliga
  case ligue1
  case eredivisie
  case mls
  case ligaMx
  case championsLeague
  case europaLeague
  // International tournaments. Each is just an ESPN competition slug
  // (see ESPNScoreboardService.apiPath); they only produce listings while
  // the tournament is actually on ESPN's schedule, off-season otherwise.
  case worldCup
  case clubWorldCup
  case euros
  case copaAmerica
  case nationsLeague
  case f1
  case ncaaf
  case ncaab
  case wnba
  case wwe
  case tennis
  case golf
  case nascar
  case cricket
  case iihf
  /// Catch-all bucket for game listings that don't match any known league.
  /// International events, niche sports, etc. surface here instead of being dropped.
  case other

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .nfl: return "NFL"
    case .nba: return "NBA"
    case .mlb: return "MLB"
    case .nhl: return "NHL"
    case .mma: return "MMA"
    case .ufc: return "UFC"
    case .boxing: return "Boxing"
    case .soccer: return "Soccer"
    case .premierLeague: return "Premier League"
    case .laLiga: return "La Liga"
    case .serieA: return "Serie A"
    case .bundesliga: return "Bundesliga"
    case .ligue1: return "Ligue 1"
    case .eredivisie: return "Eredivisie"
    case .mls: return "MLS"
    case .ligaMx: return "Liga MX"
    case .championsLeague: return "Champions League"
    case .europaLeague: return "Europa League"
    case .worldCup: return "World Cup"
    case .clubWorldCup: return "Club World Cup"
    case .euros: return "Euros"
    case .copaAmerica: return "Copa América"
    case .nationsLeague: return "Nations League"
    case .f1: return "Formula 1"
    case .ncaaf: return "College Football"
    case .ncaab: return "College Basketball"
    case .wnba: return "WNBA"
    case .wwe: return "WWE"
    case .tennis: return "Tennis"
    case .golf: return "Golf"
    case .nascar: return "NASCAR"
    case .cricket: return "Cricket"
    case .iihf: return "IIHF"
    case .other: return "Other"
    }
  }

  /// Short, channel-style code (≤4 letters) shown in the guide's channel
  /// column, e.g. "MLB", "EPL".
  var channelCode: String {
    switch self {
    case .nfl:             return "NFL"
    case .nba:             return "NBA"
    case .mlb:             return "MLB"
    case .nhl:             return "NHL"
    case .mma:             return "MMA"
    case .ufc:             return "UFC"
    case .boxing:          return "BOX"
    case .soccer:          return "SOC"
    case .premierLeague:   return "EPL"
    case .laLiga:          return "LIGA"
    case .serieA:          return "SERA"
    case .bundesliga:      return "BUND"
    case .ligue1:          return "LIG1"
    case .eredivisie:      return "ERE"
    case .mls:             return "MLS"
    case .ligaMx:          return "LMX"
    case .championsLeague: return "UCL"
    case .europaLeague:    return "UEL"
    case .worldCup:        return "WC"
    case .clubWorldCup:    return "CWC"
    case .euros:           return "EURO"
    case .copaAmerica:     return "COPA"
    case .nationsLeague:   return "UNL"
    case .f1:              return "F1"
    case .ncaaf:           return "NCAF"
    case .ncaab:           return "NCAB"
    case .wnba:            return "WNBA"
    case .wwe:             return "WWE"
    case .tennis:          return "TEN"
    case .golf:            return "GOLF"
    case .nascar:          return "NAS"
    case .cricket:         return "CRIC"
    case .iihf:            return "IIHF"
    case .other:           return "OTH"
    }
  }

  /// Lower = more popular in the United States. Used to order the Live Now feed.
  var popularityRank: Int {
    switch self {
    case .nfl:          return 1
    case .nba:          return 2
    case .mlb:          return 3
    case .nhl:          return 4
    case .ncaaf:        return 5
    case .ncaab:        return 6
    case .ufc:          return 7
    case .mma:          return 8
    case .boxing:       return 9
    case .worldCup:     return 10
    case .premierLeague:return 11
    case .mls:          return 12
    case .laLiga:       return 13
    case .serieA:       return 14
    case .bundesliga:   return 15
    case .ligue1:       return 16
    case .championsLeague: return 17
    case .europaLeague: return 18
    case .euros:        return 19
    case .copaAmerica:  return 20
    case .clubWorldCup: return 21
    case .nationsLeague: return 22
    case .ligaMx:       return 23
    case .eredivisie:   return 24
    case .soccer:       return 25
    case .tennis:       return 26
    case .nascar:       return 27
    case .golf:         return 28
    case .wwe:          return 29
    case .wnba:         return 30
    case .f1:           return 31
    case .cricket:      return 32
    case .iihf:         return 33
    case .other:        return 99
    }
  }

  var sfSymbol: String {
    switch self {
    case .nfl, .ncaaf: return "football.fill"
    case .nba, .ncaab, .wnba: return "basketball.fill"
    case .mlb: return "baseball.fill"
    case .nhl: return "hockey.puck.fill"
    case .mma, .ufc: return "figure.martial.arts"
    case .boxing: return "figure.boxing"
    case .soccer, .premierLeague, .laLiga, .serieA, .bundesliga,
         .ligue1, .eredivisie, .mls, .ligaMx, .championsLeague, .europaLeague,
         .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague: return "soccerball"
    case .f1, .nascar: return "car.fill"
    case .wwe: return "figure.wrestling"
    case .tennis: return "tennisball.fill"
    case .golf: return "figure.golf"
    case .cricket: return "figure.cricket"
    case .iihf: return "hockey.puck.fill"
    case .other: return "sportscourt"
    }
  }

  /// v2.26: native sport emojis used as the visual icon when a league
  /// has no logo PNG to fetch and no team logos to stack. Emojis are
  /// always colourful, render uniformly across iOS versions, and look
  /// more native than monochrome SF Symbols in the streams feed.
  var emoji: String {
    switch self {
    case .nfl, .ncaaf: return "🏈"
    case .nba, .ncaab, .wnba: return "🏀"
    case .mlb: return "⚾"
    case .nhl: return "🏒"
    case .mma, .ufc: return "🥋"
    case .boxing: return "🥊"
    case .soccer, .premierLeague, .laLiga, .serieA, .bundesliga,
         .ligue1, .eredivisie, .mls, .ligaMx,
         .championsLeague, .europaLeague,
         .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague: return "⚽"
    case .f1: return "🏎️"
    case .nascar: return "🏁"
    case .wwe: return "🤼"
    case .tennis: return "🎾"
    case .golf: return "⛳"
    case .cricket: return "🏏"
    case .iihf: return "🏒"
    case .other: return "🏟️"
    }
  }

  var leagueLogoURL: URL? {
    switch self {
    case .nfl:          return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/nfl.png")
    case .nba:          return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/nba.png")
    case .mlb:          return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/mlb.png")
    case .nhl:          return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/nhl.png")
    case .wnba:         return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/wnba.png")
    case .premierLeague: return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/23.png")
    case .laLiga:       return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/15.png")
    case .serieA:       return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/12.png")
    case .bundesliga:   return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/10.png")
    case .mls:          return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/19.png")
    case .ligaMx:       return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/11.png")
    case .ligue1:       return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/9.png")
    case .championsLeague: return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/2.png")
    case .europaLeague: return URL(string: "https://a.espncdn.com/i/leaguelogos/soccer/500/2310.png")
    case .eredivisie:   return nil
    default:            return nil
    }
  }

  /// Typical broadcast length for one game in this league, in minutes.
  /// Drives the default width of a game block on the TV-guide timeline.
  /// Live games that run past this are stretched to their real end time.
  var typicalDurationMinutes: Int {
    switch self {
    case .nfl, .ncaaf: return 210
    case .mlb: return 180
    case .nba, .ncaab, .wnba: return 150
    case .nhl, .iihf: return 150
    case .mma, .ufc, .boxing, .wwe: return 180
    case .tennis: return 150
    case .golf, .cricket: return 240
    case .f1, .nascar: return 120
    case .soccer, .premierLeague, .laLiga, .serieA, .bundesliga,
         .ligue1, .eredivisie, .mls, .ligaMx, .championsLeague, .europaLeague,
         .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague:
      return 120
    case .other: return 120
    }
  }

  var accentColor: Color {
    switch self {
    case .nfl: return Color(red: 0.17, green: 0.45, blue: 0.75)
    case .nba: return Color(red: 0.85, green: 0.40, blue: 0.10)
    case .mlb: return Color(red: 0.85, green: 0.15, blue: 0.15)
    case .nhl: return Color(red: 0.10, green: 0.60, blue: 0.85)
    case .mma, .ufc: return Color(red: 0.90, green: 0.25, blue: 0.10)
    case .boxing: return Color(red: 0.85, green: 0.10, blue: 0.10)
    case .soccer, .premierLeague, .laLiga, .serieA, .bundesliga,
         .ligue1, .eredivisie, .mls, .ligaMx, .championsLeague, .europaLeague,
         .worldCup, .clubWorldCup, .euros, .copaAmerica, .nationsLeague:
      return Color(red: 0.15, green: 0.65, blue: 0.30)
    case .f1: return Color(red: 0.90, green: 0.10, blue: 0.10)
    case .ncaaf: return Color(red: 0.80, green: 0.50, blue: 0.10)
    case .ncaab: return Color(red: 0.80, green: 0.35, blue: 0.10)
    case .wnba: return Color(red: 0.80, green: 0.30, blue: 0.50)
    case .wwe: return Color(red: 0.90, green: 0.10, blue: 0.10)
    case .tennis: return Color(red: 0.60, green: 0.80, blue: 0.10)
    case .golf: return Color(red: 0.20, green: 0.60, blue: 0.20)
    case .nascar: return Color(red: 0.90, green: 0.65, blue: 0.10)
    case .cricket: return Color(red: 0.10, green: 0.45, blue: 0.20)
    case .iihf: return Color(red: 0.20, green: 0.30, blue: 0.65)
    case .other:  return Color(red: 0.50, green: 0.50, blue: 0.55)
    }
  }
}
