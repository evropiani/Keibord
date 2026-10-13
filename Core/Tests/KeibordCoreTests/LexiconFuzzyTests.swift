import XCTest
@testable import KeibordCore

/// Independent brute-force implementation of the weighted distance documented on
/// `TrieSearch.fuzzySearch` / `FuzzyCostModel`, computed per word on Characters.
enum LexiconFuzzyReference {
    typealias Taps = [[(character: Character, cost: Double)]]

    static func matches(_ lexicon: WordLexicon, taps: Taps, costs: FuzzyCostModel, maxCost: Double) -> [FuzzyMatch] {
        // sub(i, letter) for every letter that occurs in the lexicon.
        var subRows: [Character: [Double]] = [:]
        func subRow(_ letter: Character) -> [Double] {
            if let row = subRows[letter] { return row }
            var row = [0.0]
            for tap in taps {
                var best = costs.substitution
                for c in tap {
                    if c.character == letter {
                        best = min(best, c.cost)
                    } else if Diacritics.base(of: c.character) == Diacritics.base(of: letter) {
                        best = min(best, c.cost + costs.diacritic)
                    }
                }
                row.append(best)
            }
            subRows[letter] = row
            return row
        }
        var result: [FuzzyMatch] = []
        for id in 0..<lexicon.wordCount {
            let key = Array(TextUnits.lookupKey(lexicon.word(id)))
            let cost = distance(taps.count, key, key.map(subRow), costs)
            if cost <= maxCost { result.append(FuzzyMatch(id: id, cost: cost)) }
        }
        return result.sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.id < $1.id }
    }

    /// d[j][i]: first j letters of `key` against the first i taps.
    private static func distance(_ n: Int, _ key: [Character], _ sub: [[Double]], _ costs: FuzzyCostModel) -> Double {
        func ins(_ letter: Character) -> Double { letter == "'" || letter == "-" ? costs.apostropheInsertion : costs.insertion }
        var d = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: key.count + 1)
        for i in stride(from: 1, through: n, by: 1) { d[0][i] = d[0][i - 1] + costs.deletion }
        for j in stride(from: 1, through: key.count, by: 1) {
            d[j][0] = d[j - 1][0] + ins(key[j - 1])
            for i in stride(from: 1, through: n, by: 1) {
                var v = d[j - 1][i - 1] + sub[j - 1][i]
                v = min(v, d[j - 1][i] + ins(key[j - 1]))
                v = min(v, d[j][i - 1] + costs.deletion)
                if i >= 2, j >= 2 {
                    v = min(v, d[j - 2][i - 2] + costs.transposition + sub[j - 2][i] + sub[j - 1][i - 1])
                }
                d[j][i] = v
            }
        }
        return d[key.count][n]
    }

    static func tapInputs(_ taps: Taps) -> [TapInput] {
        taps.map { TapInput(candidates: $0.map { TapCandidate(character: String($0.character), cost: $0.cost) }) }
    }
}

final class LexiconFuzzyTests: XCTestCase {
    // MARK: Concrete cases

    func testAccentRestoration() throws {
        let entries: [(word: String, zipf: Double)] = [("është", 6.9), ("ishte", 6.0), ("este", 4), ("çfarë", 5.9), ("farë", 3), ("fare", 2)]
        for lexicon in try pair(entries) {
            let eshte = search(lexicon, "eshte")
            XCTAssertEqual(eshte.first.map { lexicon.word($0.id) }, "është")
            XCTAssertEqual(eshte.first?.cost, 4) // two missing diacritics
            let cfare = search(lexicon, "cfare")
            XCTAssertEqual(cfare.first.map { lexicon.word($0.id) }, "çfarë")
            XCTAssertEqual(cfare.first?.cost, 4)
            // A typed variant of the same base letter (é for ë) also costs one diacritic step.
            XCTAssertEqual(search(lexicon, "éshte").first.map { lexicon.word($0.id) }, "është")
            XCTAssertEqual(search(lexicon, "éshte").first?.cost, 4)
        }
    }

    func testTypedDiacriticAgainstPlainWord() throws {
        for lexicon in try pair([("schon", 6), ("schön", 5.5), ("hält", 4)]) {
            XCTAssertEqual(result(lexicon, search(lexicon, "schön")), ["schön": 0, "schon": 2])
            XCTAssertEqual(result(lexicon, search(lexicon, "schon")), ["schon": 0, "schön": 2])
            // A plain letter typed for an umlaut.
            XCTAssertEqual(search(lexicon, "halt").first.map { lexicon.word($0.id) }, "hält")
            XCTAssertEqual(search(lexicon, "halt").first?.cost, 2)
        }
    }

    func testTransposition() throws {
        for lexicon in try pair([("the", 7.7), ("then", 5), ("tea", 5), ("ten", 5), ("eh", 4)]) {
            let matches = search(lexicon, "teh")
            XCTAssertEqual(matches.first.map { lexicon.word($0.id) }, "the")
            XCTAssertEqual(matches.first?.cost, 6)
            XCTAssertEqual(result(lexicon, matches)["ten"], 9)
            XCTAssertEqual(result(lexicon, matches)["eh"], 7)
            XCTAssertEqual(result(lexicon, matches)["then"], 13)
        }
    }

    func testApostropheAndHyphenInsertionIsCheap() throws {
        for lexicon in try pair([("don't", 6), ("done", 5), ("don", 4), ("e-mail", 4.4), ("Email", 2)]) {
            let dont = search(lexicon, "dont")
            XCTAssertEqual(dont.first.map { lexicon.word($0.id) }, "don't")
            XCTAssertEqual(dont.first?.cost, 1.5)
            XCTAssertEqual(result(lexicon, dont)["don"], 7)
            XCTAssertEqual(result(lexicon, dont)["done"], 9)
            XCTAssertEqual(result(lexicon, search(lexicon, "email")), ["Email": 0, "e-mail": 1.5])
            // A typed apostrophe (straight or typographic) matches exactly.
            XCTAssertEqual(search(lexicon, "don't").first?.cost, 0)
            XCTAssertEqual(search(lexicon, "don’t").first?.cost, 0)
            // An extra typed letter is a deletion.
            XCTAssertEqual(result(lexicon, search(lexicon, "donn"))["don"], 7)
        }
    }

    func testTapCandidates() throws {
        for lexicon in try pair([("hallo", 6), ("hello", 5), ("hält", 4), ("halt", 3)]) {
            let taps = [TapInput.exact("h"), tap(("a", 0), ("e", 1.5)), .exact("l"), .exact("l"), .exact("o")]
            XCTAssertEqual(result(lexicon, lexicon.fuzzySearch(taps: taps, costs: .standard, maxCost: 5, limit: 10)), ["hallo": 0, "hello": 1.5])
            // Candidate costs above a substitution are capped at the substitution cost.
            let far = [TapInput.exact("h"), tap(("a", 0), ("e", 20)), .exact("l"), .exact("l"), .exact("o")]
            XCTAssertEqual(result(lexicon, lexicon.fuzzySearch(taps: far, costs: .standard, maxCost: 9, limit: 10))["hello"], 9)
            // Upper-case, typographic, multi-character, emoji and negative-cost candidates.
            let odd = [tap(("H", 0)), tap(("😀", 0), (".com", 0), ("e", -4)), .exact("L"), .exact("l"), .exact("o")]
            XCTAssertEqual(result(lexicon, lexicon.fuzzySearch(taps: odd, costs: .standard, maxCost: 0, limit: 10)), ["hello": 0])
            // A diacritic candidate: the cheaper of the exact candidate and the diacritic rule wins.
            let umlaut = [TapInput.exact("h"), tap(("a", 0), ("ä", 3)), .exact("l"), .exact("t")]
            XCTAssertEqual(result(lexicon, lexicon.fuzzySearch(taps: umlaut, costs: .standard, maxCost: 2, limit: 10)), ["halt": 0, "hält": 2])
            let close = [TapInput.exact("h"), tap(("a", 0), ("ä", 1)), .exact("l"), .exact("t")]
            XCTAssertEqual(result(lexicon, lexicon.fuzzySearch(taps: close, costs: .standard, maxCost: 2, limit: 10)), ["halt": 0, "hält": 1])
        }
    }

    func testOrderingLimitsAndArguments() throws {
        let entries: [(word: String, zipf: Double)] = [("ab", 5), ("ac", 6), ("ad", 4), ("abc", 3), ("a", 2)]
        for lexicon in try pair(entries) {
            let all = search(lexicon, "ab", maxCost: 20, limit: 100)
            // Sorted by cost, ties by id (= frequency).
            XCTAssertEqual(all.map { lexicon.word($0.id) }, ["ab", "abc", "a", "ac", "ad"])
            XCTAssertEqual(all.map(\.cost), [0, 7, 7, 9, 9])
            XCTAssertEqual(search(lexicon, "ab", maxCost: 20, limit: 2), Array(all.prefix(2)))
            XCTAssertEqual(search(lexicon, "ab", maxCost: 8, limit: 100).map { lexicon.word($0.id) }, ["ab", "abc", "a"])
            XCTAssertEqual(search(lexicon, "ab", maxCost: 0, limit: 100).map { lexicon.word($0.id) }, ["ab"])
            XCTAssertEqual(search(lexicon, "ab", maxCost: 20, limit: 0), [])
            XCTAssertEqual(search(lexicon, "ab", maxCost: -1, limit: 10), [])
            XCTAssertEqual(search(lexicon, "ab", maxCost: .nan, limit: 10), [])
            XCTAssertEqual(search(lexicon, "ab", maxCost: .infinity, limit: .max).count, 5)
            // No taps: every word costs its insertions.
            XCTAssertEqual(lexicon.fuzzySearch(taps: [], costs: .standard, maxCost: 7, limit: 10).map { lexicon.word($0.id) }, ["a"])
        }
    }

    // MARK: Brute-force comparison

    func testMatchesBruteForceReference() throws {
        var rng = LexiconTestRandom(seed: 2024)
        for round in 0..<16 {
            let entries = LexiconTestData.randomVocabulary(count: 220, maxLength: 6, rng: &rng)
            let lexicons = try pair(entries)
            let costs = round == 0 ? FuzzyCostModel.standard : randomCosts(&rng)
            for _ in 0..<12 {
                let taps = randomTaps(from: entries.randomElement(using: &rng)!.word, rng: &rng)
                let maxCost = Double.random(in: 0...22, using: &rng)
                let expected = LexiconFuzzyReference.matches(lexicons[0], taps: taps, costs: costs, maxCost: maxCost)
                let inputs = LexiconFuzzyReference.tapInputs(taps)
                for lexicon in lexicons {
                    let actual = lexicon.fuzzySearch(taps: inputs, costs: costs, maxCost: maxCost, limit: .max)
                    XCTAssertEqual(actual.map(\.id), expected.map(\.id), "taps \(taps) costs \(costs) maxCost \(maxCost)")
                    for (a, e) in zip(actual, expected) {
                        XCTAssertEqual(a.cost, e.cost, accuracy: 1e-9)
                    }
                    // A small limit returns the best entries (branch-and-bound must not change them).
                    let limit = Int.random(in: 1...6, using: &rng)
                    XCTAssertEqual(lexicon.fuzzySearch(taps: inputs, costs: costs, maxCost: maxCost, limit: limit).map(\.id),
                                   expected.prefix(limit).map(\.id))
                }
            }
        }
    }

    func testPruningKeepsCheapTranspositionsBelowExpensiveRows() throws {
        // With a transposition far cheaper than every other edit, rows can exceed the bound while a
        // transposition two levels down is still within it.
        let costs = FuzzyCostModel(substitution: 10, insertion: 10, deletion: 10, transposition: 1, diacritic: 2, apostropheInsertion: 10)
        for lexicon in try pair([("abcd", 5), ("badc", 4), ("bacd", 3)]) {
            let taps: LexiconFuzzyReference.Taps = [[("b", 0)], [("a", 0)], [("d", 0)], [("c", 0)]]
            let expected = LexiconFuzzyReference.matches(lexicon, taps: taps, costs: costs, maxCost: 2)
            XCTAssertEqual(expected.map { lexicon.word($0.id) }, ["badc", "bacd", "abcd"])
            XCTAssertEqual(lexicon.fuzzySearch(taps: LexiconFuzzyReference.tapInputs(taps), costs: costs, maxCost: 2, limit: 10), expected)
        }
    }

    // MARK: Helpers

    private func pair(_ entries: [(word: String, zipf: Double)]) throws -> [WordLexicon] {
        let (memory, binary) = try LexiconTestData.both(entries)
        return [memory, binary]
    }

    private func search(_ lexicon: WordLexicon, _ typed: String, maxCost: Double = 14, limit: Int = 10) -> [FuzzyMatch] {
        lexicon.fuzzySearch(taps: typed.map { TapInput.exact(String($0)) }, costs: .standard, maxCost: maxCost, limit: limit)
    }

    private func result(_ lexicon: WordLexicon, _ matches: [FuzzyMatch]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: matches.map { (lexicon.word($0.id), $0.cost) })
    }

    private func tap(_ candidates: (String, Double)...) -> TapInput {
        TapInput(candidates: candidates.map { TapCandidate(character: $0.0, cost: $0.1) })
    }

    private func randomCosts(_ rng: inout LexiconTestRandom) -> FuzzyCostModel {
        FuzzyCostModel(substitution: .random(in: 3...12, using: &rng), insertion: .random(in: 1...10, using: &rng),
                       deletion: .random(in: 1...10, using: &rng), transposition: .random(in: 0.5...10, using: &rng),
                       diacritic: .random(in: 0.5...4, using: &rng), apostropheInsertion: .random(in: 0.2...3, using: &rng))
    }

    /// Taps for `word` after a few random typos, each with up to two extra candidate keys.
    private func randomTaps(from word: String, rng: inout LexiconTestRandom) -> LexiconFuzzyReference.Taps {
        var letters = Array(TextUnits.lookupKey(word))
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let position = Int.random(in: 0...letters.count, using: &rng)
            let letter = LexiconTestData.letters.randomElement(using: &rng)!
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: letters.insert(letter, at: position)
            case 1 where position < letters.count: letters[position] = letter
            case 2 where position < letters.count: letters.remove(at: position)
            case 3 where position + 1 < letters.count: letters.swapAt(position, position + 1)
            case 4 where position < letters.count: letters[position] = Diacritics.base(of: letters[position])
            default: break
            }
        }
        return letters.map { letter in
            var candidates = [(character: letter, cost: 0.0)]
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                candidates.append((LexiconTestData.letters.randomElement(using: &rng)!, Double.random(in: 0.5...8, using: &rng)))
            }
            return candidates
        }
    }
}
