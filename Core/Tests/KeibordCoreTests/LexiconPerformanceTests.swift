import XCTest
@testable import KeibordCore

/// Deterministic German-like vocabulary: words are built from weighted syllables, prefixes and suffixes
/// (realistic letter statistics and shared prefixes); shorter words get higher Zipf frequencies.
enum LexiconSyntheticCorpus {
    private static let prefixes = ["ver", "be", "ge", "ent", "er", "zer", "un", "vor", "nach", "aus", "ein", "auf", "an", "ab", "mit", "über", "unter", "durch"]
    private static let onsets = weighted(["": 3, "b": 3, "d": 3, "f": 2, "g": 3, "h": 3, "k": 3, "l": 3, "m": 3, "n": 2, "p": 1, "r": 3, "s": 3, "t": 3, "w": 2, "z": 1,
                                          "sch": 2, "st": 2, "sp": 1, "ch": 1, "br": 1, "tr": 1, "gr": 1, "fr": 1, "kl": 1, "pf": 1, "bl": 1, "dr": 1, "kr": 1, "fl": 1, "j": 1, "v": 1, "schw": 1, "str": 1])
    private static let nuclei = weighted(["e": 6, "a": 4, "i": 4, "o": 2, "u": 2, "ei": 2, "ie": 2, "au": 1, "ä": 1, "ö": 1, "ü": 1, "eu": 1])
    private static let codas = weighted(["": 6, "n": 4, "r": 3, "s": 2, "t": 3, "l": 2, "m": 1, "ch": 2, "ng": 1, "nd": 2, "st": 1, "ck": 1, "tz": 1, "rt": 1, "ss": 1, "lt": 1, "nk": 1, "ft": 1, "cht": 1])
    private static let suffixes = ["en", "er", "ung", "lich", "keit", "heit", "chen", "ig", "isch", "te", "ten", "est", "e", "es", "em", "ern"]

    private static func weighted(_ table: [String: Int]) -> [String] {
        table.sorted { $0.key < $1.key }.flatMap { Array(repeating: $0.key, count: $0.value) }
    }

    static func entries(count: Int, seed: UInt64) -> [(word: String, zipf: Double)] {
        var rng = LexiconTestRandom(seed: seed)
        var seen = Set<String>()
        var words: [(word: String, rankScore: Double)] = []
        while words.count < count {
            var word = Int.random(in: 0..<4, using: &rng) == 0 ? prefixes.randomElement(using: &rng)! : ""
            let syllables = [1, 2, 2, 3, 3, 3, 4].randomElement(using: &rng)!
            for _ in 0..<syllables {
                word += onsets.randomElement(using: &rng)! + nuclei.randomElement(using: &rng)! + codas.randomElement(using: &rng)!
            }
            if Int.random(in: 0..<5, using: &rng) < 2 { word += suffixes.randomElement(using: &rng)! }
            guard word.count >= 2, word.count <= 20 else { continue }
            if Int.random(in: 0..<10, using: &rng) < 3 { word = word.prefix(1).uppercased() + word.dropFirst() }
            guard seen.insert(word).inserted else { continue }
            words.append((word, Double(word.count) + Double.random(in: 0...6, using: &rng)))
        }
        words.sort { $0.rankScore < $1.rankScore }
        return words.enumerated().map { (word: $0.element.word, zipf: 7.6 - 1.15 * log10(Double($0.offset + 1))) }
    }

    private static let rows = ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"].map(Array.init)

    /// Taps for `key` with QWERTZ neighbours as candidates (≈ the touch resolver's costs).
    static func taps(for key: [Character]) -> [TapInput] {
        key.map { letter in
            var candidates = [TapCandidate(character: String(letter), cost: 0)]
            guard let r = rows.firstIndex(where: { $0.contains(letter) }), let c = rows[r].firstIndex(of: letter) else {
                return TapInput(candidates: candidates)
            }
            let neighbours: [(Int, Int, Double)] = [(r, c - 1, 3.6), (r, c + 1, 3.6), (r - 1, c, 4.4), (r - 1, c + 1, 4.4), (r + 1, c - 1, 4.4), (r + 1, c, 4.4)]
            for (nr, nc, cost) in neighbours where rows.indices.contains(nr) && rows[nr].indices.contains(nc) {
                candidates.append(TapCandidate(character: String(rows[nr][nc]), cost: cost))
            }
            return TapInput(candidates: candidates)
        }
    }

    /// Eight-letter inputs derived from lexicon words with 0–2 typos.
    static func typedInputs(_ entries: [(word: String, zipf: Double)], count: Int, seed: UInt64) -> [[Character]] {
        var rng = LexiconTestRandom(seed: seed)
        let pool = entries.map { Array(TextUnits.lookupKey($0.word)) }.filter { (7...9).contains($0.count) }
        var inputs: [[Character]] = []
        while inputs.count < count {
            var key = pool.randomElement(using: &rng)!
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                let i = Int.random(in: 0..<key.count, using: &rng)
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: key[i] = rows.flatMap { $0 }.randomElement(using: &rng)!
                case 1 where i + 1 < key.count: key.swapAt(i, i + 1)
                case 2: key.remove(at: i)
                case 3: key.insert(rows[1].randomElement(using: &rng)!, at: i)
                default: key[i] = Diacritics.base(of: key[i])
                }
            }
            if key.count == 8 { inputs.append(key) }
        }
        return inputs
    }
}

final class LexiconPerformanceTests: XCTestCase {
    #if DEBUG
    private let isRelease = false
    #else
    private let isRelease = true
    #endif

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    func testInMemoryBuildOf20kWords() {
        let entries = LexiconSyntheticCorpus.entries(count: 20_000, seed: 11)
        var lexicon: InMemoryLexicon?
        let best = (0..<3).map { _ in milliseconds { lexicon = InMemoryLexicon(languageID: "user", entries: entries) } }.min()!
        print("[lexicon perf] InMemoryLexicon build, 20k words: \(String(format: "%.1f", best)) ms\(isRelease ? "" : " (debug)")")
        XCTAssertEqual(lexicon?.wordCount, 20_000)
        if isRelease { XCTAssertLessThan(best, 50) }
    }

    func testLargeLexiconSearchPerformance() throws {
        var entries: [(word: String, zipf: Double)] = []
        let generation = milliseconds { entries = LexiconSyntheticCorpus.entries(count: 200_000, seed: 5) }
        var data = Data()
        let build = milliseconds { data = LexiconBuilder.build(languageID: "de-AT", entries: entries) }
        let lexicon = try BinaryLexicon(data: data)
        let stats = try LexiconFormat.validate(data, checkWordKeys: false)
        print("[lexicon perf] synthetic corpus: \(stats.wordCount) words, \(stats.nodeCount) nodes, \(stats.fileSize / 1024) KiB; generated in \(Int(generation)) ms, built in \(Int(build)) ms")
        XCTAssertEqual(lexicon.wordCount, 200_000)

        let inputs = LexiconSyntheticCorpus.typedInputs(entries, count: isRelease ? 200 : 20, seed: 8)
        let tapInputs = inputs.map(LexiconSyntheticCorpus.taps)
        var found = 0
        let fuzzyTotal = milliseconds {
            for taps in tapInputs {
                found += lexicon.fuzzySearch(taps: taps, costs: .standard, maxCost: 18, limit: 50).count
            }
        }
        let fuzzyAverage = fuzzyTotal / Double(tapInputs.count)
        var exhaustiveFound = 0
        let exhaustiveAverage = milliseconds {
            for taps in tapInputs.prefix(20) {
                exhaustiveFound += lexicon.fuzzySearch(taps: taps, costs: .standard, maxCost: 18, limit: .max).count
            }
        } / Double(min(20, tapInputs.count))

        var rng = LexiconTestRandom(seed: 13)
        let keys = (0..<2000).map { _ in TextUnits.lookupKey(entries.randomElement(using: &rng)!.word) }
        let prefixes = keys.map { String($0.prefix(Int.random(in: 1...3, using: &rng))) }
        var completed = 0
        let completionAverage = milliseconds {
            for prefix in prefixes { completed += lexicon.completions(prefix: prefix, limit: 10).count }
        } / Double(prefixes.count)
        var lookedUp = 0
        let lookupAverage = milliseconds {
            for key in keys { lookedUp += lexicon.lookup(key: key).count }
        } / Double(keys.count)

        print(String(format: "[lexicon perf] fuzzySearch (8 taps, maxCost 18, limit 50): %.3f ms avg, %.1f results; unlimited: %.3f ms avg, %.1f results",
                     fuzzyAverage, Double(found) / Double(tapInputs.count), exhaustiveAverage, Double(exhaustiveFound) / Double(min(20, tapInputs.count))))
        print(String(format: "[lexicon perf] completions (limit 10): %.4f ms avg; lookup: %.5f ms avg%@", completionAverage, lookupAverage, isRelease ? "" : " (debug build: not asserted)"))
        XCTAssertGreaterThan(found, 0)
        XCTAssertGreaterThanOrEqual(lookedUp, keys.count)
        XCTAssertTrue(keys.allSatisfy { !lexicon.lookup(key: $0).isEmpty })
        XCTAssertGreaterThan(completed, 0)
        if isRelease {
            XCTAssertLessThan(fuzzyAverage, 8)
            XCTAssertLessThan(completionAverage, 1)
            XCTAssertLessThan(lookupAverage, 0.05)
        }
    }
}
