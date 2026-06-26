import Foundation

/// Lightweight fuzzy string-similarity helpers used to match team names that
/// don't line up exactly — misspellings, transliterations, and cross-language
/// renderings the alias list doesn't cover (e.g. "barcellona" ≈ "barcelona").
enum StringSimilarity {
  /// Sørensen–Dice coefficient over character bigrams, in 0…1. Robust to small
  /// edits and word-order quirks, and cheap to compute.
  static func dice(_ a: String, _ b: String) -> Double {
    if a == b { return 1 }
    if a.count < 2 || b.count < 2 { return 0 }
    let aGrams = bigrams(a)
    let bGrams = bigrams(b)
    if aGrams.isEmpty || bGrams.isEmpty { return 0 }
    var counts: [String: Int] = [:]
    for g in bGrams { counts[g, default: 0] += 1 }
    var intersection = 0
    for g in aGrams {
      if let c = counts[g], c > 0 {
        counts[g] = c - 1
        intersection += 1
      }
    }
    return 2.0 * Double(intersection) / Double(aGrams.count + bGrams.count)
  }

  private static func bigrams(_ s: String) -> [String] {
    let chars = Array(s)
    guard chars.count >= 2 else { return [] }
    return (0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) }
  }
}
