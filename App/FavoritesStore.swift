import Foundation

@Observable
final class FavoritesStore {
  static let shared = FavoritesStore()

  private(set) var favoriteLeagues: Set<SportLeague> = []
  private(set) var favoriteTeams: Set<String> = []   // stored lowercased

  private static let leaguesKey = "favorites_leagues"
  private static let teamsKey   = "favorites_teams"

  private init() {
    if let raw = UserDefaults.standard.array(forKey: Self.leaguesKey) as? [String] {
      favoriteLeagues = Set(raw.compactMap { SportLeague(rawValue: $0) })
    }
    if let raw = UserDefaults.standard.array(forKey: Self.teamsKey) as? [String] {
      favoriteTeams = Set(raw)
    }
  }

  func toggleLeague(_ league: SportLeague) {
    if favoriteLeagues.contains(league) { favoriteLeagues.remove(league) }
    else { favoriteLeagues.insert(league) }
    UserDefaults.standard.set(favoriteLeagues.map(\.rawValue), forKey: Self.leaguesKey)
  }

  func isLeagueFavorite(_ league: SportLeague) -> Bool {
    favoriteLeagues.contains(league)
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
  ]
}
