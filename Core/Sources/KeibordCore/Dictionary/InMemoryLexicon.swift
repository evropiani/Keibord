import Foundation

/// A lexicon built in memory with the same structure and semantics as a `.kbdl` file (frequencies and
/// bigram probabilities are quantised exactly like the file format). Used for the user's learned
/// words (languageID "user") and in tests.
public final class InMemoryLexicon: WordLexicon, Sendable {
    public let languageID: String
    private let tables: LexiconTables

    /// See `LexiconBuilder.build` for how entries and bigrams are normalised.
    public init(languageID: String, entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)] = []) {
        self.languageID = languageID
        tables = LexiconTables(languageID: languageID, entries: entries, bigrams: bigrams)
    }

    /// The lexicon serialised in the `.kbdl` format.
    public func serialized() -> Data {
        LexiconBuilder.serialize(tables)
    }

    public var wordCount: Int { tables.words.count }

    public func word(_ id: Int) -> String {
        guard id >= 0, id < wordCount else { return "" }
        return tables.words[id]
    }

    public func zipf(_ id: Int) -> Double {
        guard id >= 0, id < wordCount else { return 0 }
        return LexiconFormat.zipf(fromByte: tables.zipf[id])
    }

    public func lookup(key: String) -> [Int] {
        TrieSearch.lookup(tables, key: key)
    }

    public func completions(prefix: String, limit: Int) -> [Int] {
        TrieSearch.completions(tables, prefix: prefix, limit: limit)
    }

    public func fuzzySearch(taps: [TapInput], costs: FuzzyCostModel, maxCost: Double, limit: Int) -> [FuzzyMatch] {
        TrieSearch.fuzzySearch(tables, taps: taps, costs: costs, maxCost: maxCost, limit: limit)
    }

    /// Bigram successors of `id`; other casings resolve to the key's most frequent form (see `BinaryLexicon`).
    public func successors(of id: Int, limit: Int) -> [(id: Int, log2Prob: Double)] {
        let direct = TrieSearch.successors(tables, of: id, limit: limit)
        guard direct.isEmpty, id >= 0, id < wordCount,
              let main = TrieSearch.lookup(tables, key: tables.words[id]).first, main != id else { return direct }
        return TrieSearch.successors(tables, of: main, limit: limit)
    }

    public func topWords(limit: Int) -> [Int] {
        TrieSearch.topWords(tables, limit: limit)
    }
}
