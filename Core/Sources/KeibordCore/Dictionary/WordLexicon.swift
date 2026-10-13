import Foundation

/// Result of a fuzzy dictionary search.
public struct FuzzyMatch: Hashable, Sendable {
    public var id: Int
    /// Edit cost in bits (see `FuzzyCostModel`). 0 = exact match of the primary taps.
    public var cost: Double
    public init(id: Int, cost: Double) {
        self.id = id
        self.cost = cost
    }
}

/// Costs (in bits ≈ −log2 probability) used by the weighted Damerau–Levenshtein trie search.
/// For typed position i and dictionary letter L:
///   * L equals a tap candidate → that candidate's cost (0 for the hit key)
///   * base(L) equals a tap candidate (L has a diacritic the user did not type) → candidate cost + `diacritic`
///   * L equals base(typed) (user typed a diacritic the word lacks) → `diacritic`
///   * otherwise → `substitution`
/// Insertions (dictionary letter with no tap) cost `insertion`, or `apostropheInsertion` for "'" and "-".
/// Deletions (tap with no dictionary letter) cost `deletion`. Adjacent swaps cost `transposition`.
public struct FuzzyCostModel: Hashable, Sendable {
    public var substitution: Double
    public var insertion: Double
    public var deletion: Double
    public var transposition: Double
    public var diacritic: Double
    public var apostropheInsertion: Double

    public init(substitution: Double = 9, insertion: Double = 7, deletion: Double = 7, transposition: Double = 6, diacritic: Double = 2, apostropheInsertion: Double = 1.5) {
        self.substitution = substitution
        self.insertion = insertion
        self.deletion = deletion
        self.transposition = transposition
        self.diacritic = diacritic
        self.apostropheInsertion = apostropheInsertion
    }

    public static let standard = FuzzyCostModel()
}

/// Read-only word list with frequencies, a lower-cased lookup trie and next-word statistics.
/// Implemented by `BinaryLexicon` (memory-mapped `.kbdl` files) and `InMemoryLexicon` (user words, tests).
///
/// Frequencies use the *Zipf scale*: log10(occurrences per billion words), roughly 0…8
/// ("der"/"the" ≈ 7.5, a rare word ≈ 1.5). P(word) = 10^(zipf − 9).
public protocol WordLexicon: AnyObject {
    /// Dictionary id ("de-AT", "en-GB", "en-US", "sq", "it", or "user").
    var languageID: String { get }
    var wordCount: Int { get }
    /// The word with its dictionary casing (e.g. "Haus", "London", "I").
    func word(_ id: Int) -> String
    func zipf(_ id: Int) -> Double
    /// Ids of all words whose lookup key (`TextUnits.lookupKey`) equals `key`, most frequent first.
    func lookup(key: String) -> [Int]
    /// Completions of `prefix` (a lookup key, may be ""), most frequent first. Includes exact matches.
    func completions(prefix: String, limit: Int) -> [Int]
    /// Weighted Damerau–Levenshtein search over the trie. Results sorted by cost ascending.
    func fuzzySearch(taps: [TapInput], costs: FuzzyCostModel, maxCost: Double, limit: Int) -> [FuzzyMatch]
    /// Most likely next words after word `id`, with log2 P(next | id), most likely first.
    func successors(of id: Int, limit: Int) -> [(id: Int, log2Prob: Double)]
    /// Most frequent words overall (fallback predictions).
    func topWords(limit: Int) -> [Int]
}

public extension WordLexicon {
    /// log2 P(word) derived from the Zipf frequency.
    func log2Prob(_ id: Int) -> Double {
        (zipf(id) - 9) * 3.321928094887362
    }
}
