import Foundation
import SwiftUI

// MARK: - Sport (broad sport categories that each map to one or more SportLeague cases)

enum Sport: String, CaseIterable, Identifiable, Codable, Hashable {
  case soccer
  case basketball
  case americanFootball
  case baseball
  case hockey
  case combat
  case racing
  case tennis
  case golf
  case wrestling

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .soccer:           return "Soccer"
    case .basketball:       return "Basketball"
    case .americanFootball: return "American Football"
    case .baseball:         return "Baseball"
    case .hockey:           return "Hockey"
    case .combat:           return "Combat Sports"
    case .racing:           return "Racing"
    case .tennis:           return "Tennis"
    case .golf:             return "Golf"
    case .wrestling:        return "Wrestling"
    }
  }

  var sfSymbol: String {
    switch self {
    case .soccer:           return "soccerball"
    case .basketball:       return "basketball.fill"
    case .americanFootball: return "football.fill"
    case .baseball:         return "baseball.fill"
    case .hockey:           return "hockey.puck.fill"
    case .combat:           return "figure.martial.arts"
    case .racing:           return "car.fill"
    case .tennis:           return "tennisball.fill"
    case .golf:             return "figure.golf"
    case .wrestling:        return "figure.wrestling"
    }
  }

  // All SportLeague cases that belong to this sport
  var leagues: [SportLeague] {
    switch self {
    case .soccer:           return [.soccer, .premierLeague, .laLiga, .serieA, .bundesliga]
    case .basketball:       return [.nba, .wnba, .ncaab]
    case .americanFootball: return [.nfl, .ncaaf]
    case .baseball:         return [.mlb]
    case .hockey:           return [.nhl]
    case .combat:           return [.mma, .ufc, .boxing]
    case .racing:           return [.f1, .nascar]
    case .tennis:           return [.tennis]
    case .golf:             return [.golf]
    case .wrestling:        return [.wwe]
    }
  }

  var accentColor: Color {
    switch self {
    case .soccer:           return Color(red: 0.15, green: 0.65, blue: 0.30)
    case .basketball:       return Color(red: 0.85, green: 0.40, blue: 0.10)
    case .americanFootball: return Color(red: 0.17, green: 0.45, blue: 0.75)
    case .baseball:         return Color(red: 0.85, green: 0.15, blue: 0.15)
    case .hockey:           return Color(red: 0.10, green: 0.60, blue: 0.85)
    case .combat:           return Color(red: 0.90, green: 0.25, blue: 0.10)
    case .racing:           return Color(red: 0.90, green: 0.10, blue: 0.10)
    case .tennis:           return Color(red: 0.60, green: 0.80, blue: 0.10)
    case .golf:             return Color(red: 0.20, green: 0.60, blue: 0.20)
    case .wrestling:        return Color(red: 0.90, green: 0.10, blue: 0.10)
    }
  }
}

// MARK: - FavoritesStore

@Observable
final class FavoritesStore {
  static let shared = FavoritesStore()

  private(set) var favoriteLeagues: Set<SportLeague> = []
  private(set) var favoriteTeams: Set<String> = []    // stored lowercased
  private(set) var favoriteSports: Set<Sport> = []

  private static let leaguesKey = "favorites_leagues"
  private static let teamsKey   = "favorites_teams"
  private static let sportsKey  = "favorites_sports"

  private init() {
    if let raw = UserDefaults.standard.array(forKey: Self.leaguesKey) as? [String] {
      favoriteLeagues = Set(raw.compactMap { SportLeague(rawValue: $0) })
    }
    if let raw = UserDefaults.standard.array(forKey: Self.teamsKey) as? [String] {
      favoriteTeams = Set(raw)
    }
    if let raw = UserDefaults.standard.array(forKey: Self.sportsKey) as? [String] {
      favoriteSports = Set(raw.compactMap { Sport(rawValue: $0) })
    }
  }

  func toggleLeague(_ league: SportLeague) {
    if favoriteLeagues.contains(league) { favoriteLeagues.remove(league) }
    else { favoriteLeagues.insert(league) }
    UserDefaults.standard.set(favoriteLeagues.map(\.rawValue), forKey: Self.leaguesKey)
  }

  func isLeagueFavorite(_ league: SportLeague) -> Bool {
    if favoriteLeagues.contains(league) { return true }
    // v2.27: also treat a league as favorited when its parent sport is.
    // Favoriting "Basketball" as a sport should star the NBA / WNBA /
    // NCAAB chips too — previously only direct league favorites lit up
    // the star, so the UI never reflected sport-level favorites.
    for sport in favoriteSports where sport.leagues.contains(league) {
      return true
    }
    return false
  }

  func toggleTeam(_ name: String) {
    let key = name.lowercased()
    if favoriteTeams.contains(key) { favoriteTeams.remove(key) }
    else { favoriteTeams.insert(key) }
    UserDefaults.standard.set(Array(favoriteTeams), forKey: Self.teamsKey)
  }

  func isTeamFavorite(_ name: String) -> Bool {
    let lower = name.lowercased()
    return favoriteTeams.contains { lower.contains($0) || $0.contains(lower) }
  }

  func toggleSport(_ sport: Sport) {
    if favoriteSports.contains(sport) { favoriteSports.remove(sport) }
    else { favoriteSports.insert(sport) }
    UserDefaults.standard.set(favoriteSports.map(\.rawValue), forKey: Self.sportsKey)
  }

  func isSportFavorite(_ sport: Sport) -> Bool {
    favoriteSports.contains(sport)
  }

  func isFavoriteGame(_ game: Game) -> Bool {
    isTeamFavorite(game.homeTeam) || isTeamFavorite(game.awayTeam)
  }

  // All known teams grouped by league, drawn from the static ESPN table
  static let knownTeams: [(league: SportLeague, teams: [String])] = [
    (.nfl, ["Cardinals","Falcons","Ravens","Bills","Panthers","Bears","Bengals","Browns",
            "Cowboys","Broncos","Lions","Packers","Texans","Colts","Jaguars","Chiefs",
            "Raiders","Chargers","Rams","Dolphins","Vikings","Patriots","Saints","Giants",
            "Jets","Eagles","Steelers","49ers","Seahawks","Buccaneers","Titans","Commanders"]),
    (.nba, ["Hawks","Celtics","Nets","Hornets","Bulls","Cavaliers","Mavericks","Nuggets",
            "Pistons","Warriors","Rockets","Pacers","Clippers","Lakers","Grizzlies","Heat",
            "Bucks","Timberwolves","Pelicans","Knicks","Thunder","Magic","76ers","Suns",
            "Trail Blazers","Kings","Spurs","Raptors","Jazz","Wizards"]),
    (.wnba, ["Dream","Sky","Sun","Wings","Fever","Aces","Sparks","Lynx",
             "Liberty","Mercury","Storm","Mystics","Valkyries"]),
    (.mlb, ["Diamondbacks","Braves","Orioles","Red Sox","Cubs","White Sox","Reds",
            "Guardians","Rockies","Tigers","Astros","Royals","Angels","Dodgers","Marlins",
            "Brewers","Twins","Mets","Yankees","Athletics","Phillies","Pirates","Padres",
            "Giants","Mariners","Cardinals","Rays","Rangers","Blue Jays","Nationals"]),
    (.nhl, ["Ducks","Bruins","Sabres","Flames","Hurricanes","Blackhawks","Avalanche",
            "Blue Jackets","Stars","Red Wings","Oilers","Panthers","Kings","Wild",
            "Canadiens","Predators","Devils","Islanders","Rangers","Senators","Flyers",
            "Penguins","Sharks","Kraken","Blues","Lightning","Maple Leafs","Canucks",
            "Golden Knights","Capitals","Jets"]),
    (.premierLeague, ["Arsenal","Aston Villa","Bournemouth","Brentford","Brighton",
                      "Chelsea","Crystal Palace","Everton","Fulham","Ipswich Town",
                      "Leicester City","Liverpool","Manchester City","Manchester United",
                      "Newcastle United","Nottingham Forest","Southampton",
                      "Tottenham Hotspur","West Ham United","Wolverhampton Wanderers"]),
    (.laLiga, ["Athletic Bilbao","Atletico Madrid","Barcelona","Real Betis","Celta Vigo",
               "Alaves","Espanyol","Getafe","Girona","Las Palmas","Leganes","Mallorca",
               "Osasuna","Rayo Vallecano","Real Madrid","Real Sociedad","Sevilla",
               "Valencia","Valladolid","Villarreal"]),
    (.serieA, ["AC Milan","Atalanta","Bologna","Cagliari","Como","Empoli","Fiorentina",
               "Genoa","Inter Milan","Juventus","Lazio","Lecce","Monza","Napoli","Parma",
               "Roma","Torino","Udinese","Venezia","Hellas Verona"]),
    (.bundesliga, ["Augsburg","Bayer Leverkusen","Bayern Munich","Bochum","Borussia Dortmund",
                   "Borussia Monchengladbach","Eintracht Frankfurt","Freiburg","Heidenheim",
                   "Hoffenheim","FC Koln","Mainz","RB Leipzig","Stuttgart","Union Berlin",
                   "Werder Bremen","Wolfsburg","Holstein Kiel"]),
  ]
}
