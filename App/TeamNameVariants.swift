import Foundation

/// Cross-language / alternate-spelling name groups, mainly for national teams in
/// international competitions (volleyball, soccer, basketball, etc.) where a
/// source site may list a country under its endonym or a non-English name —
/// "Türkiye" for Turkey, "España" for Spain, "Deutschland" for Germany. The
/// app's matchers are substring/token based, so without these a foreign-language
/// rendering never matches and the right game can't be found.
///
/// Each inner array is a set of equivalent names. `variants(forNormalized:)`
/// returns the other names in a query's group so they can be folded into a
/// team's match tokens. Keys and values are matched after `TeamAliasIndex`
/// normalization (lowercased, diacritic-folded), so accents here are optional —
/// they're included for readability and folded automatically.
enum TeamNameVariants {
  /// Equivalence groups. Add freely; order within a group doesn't matter.
  private static let groups: [[String]] = [
    ["turkey", "turkiye", "türkiye"],
    ["united states", "usa", "us", "u.s.a.", "estados unidos", "america"],
    ["spain", "espana", "españa"],
    ["germany", "deutschland", "alemania", "allemagne"],
    ["italy", "italia", "italie"],
    ["france", "francia", "frankreich"],
    ["brazil", "brasil"],
    ["netherlands", "holland", "nederland", "países bajos", "paises bajos", "holanda"],
    ["belgium", "belgique", "belgie", "belgië", "belgica", "bélgica"],
    ["switzerland", "suisse", "schweiz", "suiza", "svizzera"],
    ["austria", "osterreich", "österreich"],
    ["poland", "polska", "polonia"],
    ["czechia", "czech republic", "cesko", "česko"],
    ["croatia", "hrvatska", "croacia"],
    ["serbia", "srbija"],
    ["slovenia", "slovenija", "eslovenia"],
    ["slovakia", "slovensko", "eslovaquia"],
    ["greece", "hellas", "ellada", "grecia"],
    ["portugal", "portogallo"],
    ["sweden", "sverige", "suecia"],
    ["norway", "norge", "noruega"],
    ["denmark", "danmark", "dinamarca"],
    ["finland", "suomi", "finlandia"],
    ["iceland", "island", "islandia"],
    ["ireland", "eire", "éire", "irlanda"],
    ["hungary", "magyarorszag", "magyarország", "hungria", "hungría"],
    ["romania", "rumania", "rumanía", "románia"],
    ["bulgaria"],
    ["ukraine", "ukraina", "ucrania"],
    ["russia", "rossiya", "rusia"],
    ["japan", "nippon", "nihon", "japon", "japón"],
    ["china", "prc", "zhongguo"],
    ["south korea", "korea republic", "republic of korea", "corea del sur", "korea"],
    ["egypt", "egypte", "egipto", "misr"],
    ["morocco", "maroc", "marruecos", "maghreb"],
    ["mexico", "méxico"],
    ["argentina"],
    ["canada", "canadá"],
    ["australia", "socceroos"],
    ["iran", "ir iran", "islamic republic of iran"],
    ["saudi arabia", "ksa", "arabia saudita"],
    ["cote divoire", "cote d ivoire", "ivory coast", "costa de marfil"],
    ["cape verde", "cabo verde"],
    ["north macedonia", "macedonia", "makedonija"],
    ["bosnia and herzegovina", "bosnia", "bih"],
    ["dominican republic", "republica dominicana", "república dominicana"],
    ["puerto rico"],
  ]

  /// normalized name → all other normalized names sharing its group.
  private static let index: [String: [String]] = {
    var map: [String: [String]] = [:]
    for group in groups {
      let normalized = group.map(TeamAliasIndex.normalize).filter { !$0.isEmpty }
      for name in normalized {
        map[name, default: []].append(contentsOf: normalized.filter { $0 != name })
      }
    }
    return map
  }()

  /// Alternate names for a team, given its already-normalized display name.
  /// Empty when the name isn't part of any known group.
  static func variants(forNormalized name: String) -> [String] {
    index[name] ?? []
  }
}
