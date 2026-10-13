import XCTest
@testable import KeibordCore

/// Deterministic random numbers for reproducible test vocabularies (SplitMix64).
struct LexiconTestRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Shared helpers for the lexicon tests.
enum LexiconTestData {
    /// Small alphabet with diacritics, apostrophe and hyphen so random words share prefixes and the
    /// fuzzy rules are exercised.
    static let letters: [Character] = Array("aeinrstlouhdmkzäöüëçéß'-")

    static func randomVocabulary(count: Int, maxLength: Int = 7, rng: inout LexiconTestRandom) -> [(word: String, zipf: Double)] {
        var entries: [(word: String, zipf: Double)] = []
        for _ in 0..<count {
            let length = Int.random(in: 1...maxLength, using: &rng)
            var word = String((0..<length).map { _ in letters.randomElement(using: &rng)! })
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: word = word.capitalized
            case 1: word = word.uppercased()
            default: break
            }
            // Quarter steps produce plenty of exact frequency ties.
            let zipf = Double(Int.random(in: 2...30, using: &rng)) / 4
            entries.append((word, zipf))
            if Int.random(in: 0..<6, using: &rng) == 0 {
                // Another casing of the same key.
                entries.append((word.prefix(1).uppercased() + word.dropFirst(), zipf - Double(Int.random(in: 0...2, using: &rng)) / 4))
            }
        }
        return entries
    }

    static func randomBigrams(for entries: [(word: String, zipf: Double)], count: Int, rng: inout LexiconTestRandom) -> [(previous: String, next: String, log2Prob: Double)] {
        guard !entries.isEmpty else { return [] }
        return (0..<count).map { _ in
            let a = entries.randomElement(using: &rng)!.word
            let b = Int.random(in: 0..<20, using: &rng) == 0 ? "unknownword" : entries.randomElement(using: &rng)!.word
            return (a, b, -Double.random(in: 0...9, using: &rng))
        }
    }

    static func both(_ entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)] = [], languageID: String = "test") throws -> (InMemoryLexicon, BinaryLexicon) {
        let memory = InMemoryLexicon(languageID: languageID, entries: entries, bigrams: bigrams)
        let binary = try BinaryLexicon(data: LexiconBuilder.build(languageID: languageID, entries: entries, bigrams: bigrams))
        return (memory, binary)
    }

    static func words(_ lexicon: WordLexicon, _ ids: [Int]) -> [String] {
        ids.map { lexicon.word($0) }
    }

    static func id(of word: String, in lexicon: WordLexicon) -> Int? {
        lexicon.lookup(key: TextUnits.lookupKey(word)).first { lexicon.word($0) == word }
    }

    /// The repository root, derived from this file's location (Core/Tests/KeibordCoreTests/…).
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func u32(_ data: Data, _ offset: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
    }

    static func setU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self) }
    }
}

final class LexiconTests: XCTestCase {
    private let sample: [(word: String, zipf: Double)] = [
        ("the", 7.7), ("und", 7.4), ("Haus", 5.6), ("haus", 2.1), ("essen", 5.5), ("Essen", 4.9), ("ESSEN", 2.0),
        ("don't", 6.1), ("done", 5.0), ("don", 4.0), ("Hallo", 5.2), ("hallo", 4.6), ("halt", 5.1), ("hält", 4.8),
        ("është", 6.9), ("çfarë", 5.9), ("e-mail", 4.4), ("London", 5.3), ("I", 7.5),
    ]

    // MARK: Building and basic access

    func testWordsAreOrderedByFrequencyWithAlphabeticalTies() throws {
        let entries: [(word: String, zipf: Double)] = [("b", 3), ("c", 5), ("a", 3), ("B", 3), ("d", 4.99), ("é", 3)]
        for lexicon in try pair(entries) {
            XCTAssertEqual(LexiconTestData.words(lexicon, Array(0..<lexicon.wordCount)), ["c", "d", "B", "a", "b", "é"])
            XCTAssertEqual(lexicon.topWords(limit: 3), [0, 1, 2])
            XCTAssertEqual(lexicon.topWords(limit: 100), Array(0..<6))
            XCTAssertEqual(lexicon.topWords(limit: 0), [])
            XCTAssertEqual(lexicon.zipf(0), 5.0)
            // 4.99 × 32 = 159.68 → byte 160 → 5.0 (frequencies are quantised to 1/32).
            XCTAssertEqual(lexicon.zipf(1), 5.0)
        }
    }

    func testNormalisationDropsAndDeduplicates() throws {
        let entries: [(word: String, zipf: Double)] = [
            ("", 5), ("😀", 5), ("a😀b", 5), ("ok", 3), ("ok", 4.5), ("ok", 1),
            ("Cafe\u{301}", 3), ("Don’t", 2), ("x", .nan), ("big", 99), ("neg", -3),
        ]
        for lexicon in try pair(entries) {
            XCTAssertEqual(lexicon.wordCount, 6)
            XCTAssertEqual(lexicon.word(0), "big")
            XCTAssertEqual(lexicon.zipf(0), 255.0 / 32)
            XCTAssertEqual(lexicon.word(1), "ok")
            XCTAssertEqual(lexicon.zipf(1), 4.5)
            // Stored in NFC.
            let cafe = try XCTUnwrap(lexicon.lookup(key: "café").first)
            XCTAssertEqual(Array(lexicon.word(cafe).unicodeScalars), Array("Caf\u{E9}".unicodeScalars))
            // Typographic apostrophe: the word keeps it, its key uses "'".
            let dont = try XCTUnwrap(lexicon.lookup(key: "don't").first)
            XCTAssertEqual(lexicon.word(dont), "Don’t")
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "x")), ["x"])
            XCTAssertEqual(lexicon.zipf(try XCTUnwrap(LexiconTestData.id(of: "neg", in: lexicon))), 0)
            XCTAssertEqual(lexicon.lookup(key: ""), [])
            // Invalid ids are harmless.
            XCTAssertEqual(lexicon.word(-1), "")
            XCTAssertEqual(lexicon.word(lexicon.wordCount), "")
            XCTAssertEqual(lexicon.zipf(1000), 0)
            XCTAssertTrue(lexicon.successors(of: -5, limit: 3).isEmpty)
        }
    }

    func testNonASCIINormalisation() throws {
        // Decomposed input is stored in NFC and found by its precomposed key; upper-case diacritics fold.
        let entries: [(word: String, zipf: Double)] = [("O\u{308}sterreich", 5), ("Österreich", 4), ("ËSHTË", 3), ("İstanbul", 4), ("Straße", 4)]
        for lexicon in try pair(entries) {
            XCTAssertEqual(lexicon.wordCount, 4)
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "österreich")), ["Österreich"])
            XCTAssertEqual(lexicon.zipf(try XCTUnwrap(lexicon.lookup(key: "österreich").first)), 5)
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "ËSHTË")), ["ËSHTË"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "straße")), ["Straße"])
            // "İ" lower-cases to "i" + U+0307, exactly like `TextUnits.lookupKey`.
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: TextUnits.lookupKey("İstanbul"))), ["İstanbul"])
            XCTAssertEqual(lexicon.lookup(key: "istanbul"), [])
        }
    }

    func testLookupKeyFastPathMatchesTextUnits() {
        func expected(_ s: String) -> [UInt16]? {
            let units = Array(TextUnits.lookupKey(s).utf16)
            return units.contains { $0 & 0xF800 == 0xD800 } ? nil : units
        }
        for value in UInt32(0)..<0x300 {
            let s = String(Character(Unicode.Scalar(value)!))
            XCTAssertEqual(LexiconKey.units(s), expected(s), "U+\(String(value, radix: 16))")
            XCTAssertEqual(Array(LexiconKey.nfc(s).unicodeScalars), Array(s.precomposedStringWithCanonicalMapping.unicodeScalars))
        }
        let samples = ["", "Haus", "ÄRGER", "don’t", "DON’T", "O\u{308}l", "e\u{301}", "İstanbul", "ΟΔΟΣ", "Ǆemal", "ǅ", "Москва",
                       "a😀", "😀", "’", "\u{2019}s", "x\u{2018}y", "Ⓐ", "ﬁ", "ẞ", "Ω", "Å", "e\u{301}\u{2019}", "\u{1E9E}x"]
        var rng = LexiconTestRandom(seed: 21)
        let alphabet: [Character] = Array("aZäÄßëËçÇéÉıİœŒǅ’'-ΣσЖ😀ﬁÅ") + ["e\u{301}", "\u{2019}", "Ⅻ"]
        let random = (0..<400).map { _ in String((0..<Int.random(in: 1...6, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
        for s in samples + random {
            XCTAssertEqual(LexiconKey.units(s), expected(s), s)
            XCTAssertEqual(Array(LexiconKey.nfc(s).unicodeScalars), Array(s.precomposedStringWithCanonicalMapping.unicodeScalars), s)
        }
        XCTAssertEqual(LexiconKey.tapUnit("Ä"), 0xE4)
        XCTAssertEqual(LexiconKey.tapUnit("’"), 0x27)
        XCTAssertEqual(LexiconKey.tapUnit("-"), 0x2D)
        XCTAssertNil(LexiconKey.tapUnit("ab"))
        XCTAssertNil(LexiconKey.tapUnit(""))
        XCTAssertNil(LexiconKey.tapUnit("😀"))
        XCTAssertNil(LexiconKey.tapUnit("İ"))
    }

    func testBuildIsDeterministicAndIndependentOfInputOrder() {
        var rng = LexiconTestRandom(seed: 17)
        for _ in 0..<5 {
            let entries = LexiconTestData.randomVocabulary(count: 300, rng: &rng)
            let bigrams = LexiconTestData.randomBigrams(for: entries, count: 300, rng: &rng)
            let data = LexiconBuilder.build(languageID: "x", entries: entries, bigrams: bigrams)
            XCTAssertEqual(LexiconBuilder.build(languageID: "x", entries: entries, bigrams: bigrams), data)
            XCTAssertEqual(LexiconBuilder.build(languageID: "x", entries: entries.shuffled(using: &rng), bigrams: bigrams.shuffled(using: &rng)), data)
            XCTAssertEqual(InMemoryLexicon(languageID: "x", entries: entries.reversed(), bigrams: bigrams).serialized(), data)
        }
    }

    func testEmptyLexicon() throws {
        let data = LexiconBuilder.build(languageID: "empty", entries: [], bigrams: [])
        let stats = try LexiconFormat.validate(data)
        XCTAssertEqual(stats.wordCount, 0)
        XCTAssertEqual(stats.nodeCount, 1)
        for lexicon in try pair([]) {
            XCTAssertEqual(lexicon.wordCount, 0)
            XCTAssertEqual(lexicon.lookup(key: "a"), [])
            XCTAssertEqual(lexicon.completions(prefix: "", limit: 5), [])
            XCTAssertEqual(lexicon.fuzzySearch(taps: [.exact("a")], costs: .standard, maxCost: 20, limit: 5), [])
            XCTAssertEqual(lexicon.topWords(limit: 5), [])
        }
    }

    // MARK: Lookup

    func testLookupCasingVariantsMostFrequentFirst() throws {
        for lexicon in try pair(sample) {
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "essen")), ["essen", "Essen", "ESSEN"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "haus")), ["Haus", "haus"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "hallo")), ["Hallo", "hallo"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "i")), ["I"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "london")), ["London"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "është")), ["është"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "hält")), ["hält"])
            // Keys are normalised defensively.
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "HAUS")), ["Haus", "haus"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: "don’t")), ["don't"])
            XCTAssertEqual(lexicon.lookup(key: "hau"), [])
            XCTAssertEqual(lexicon.lookup(key: "hausboot"), [])
            XCTAssertEqual(lexicon.lookup(key: "😀"), [])
        }
    }

    func testLookupHausReturnsIDOfHaus() throws {
        for lexicon in try pair(sample) {
            let ids = lexicon.lookup(key: "haus")
            XCTAssertEqual(ids.first.map(lexicon.word), "Haus")
            XCTAssertGreaterThan(lexicon.zipf(ids[0]), lexicon.zipf(ids[1]))
        }
    }

    // MARK: Completions

    func testCompletions() throws {
        for lexicon in try pair(sample) {
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.completions(prefix: "ha", limit: 10)),
                           ["Haus", "Hallo", "halt", "hallo", "haus"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.completions(prefix: "ha", limit: 2)), ["Haus", "Hallo"])
            // The exact match is included.
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.completions(prefix: "don", limit: 5)), ["don't", "done", "don"])
            // A trailing apostrophe continues to the contraction.
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.completions(prefix: "don'", limit: 5)), ["don't"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.completions(prefix: "don’", limit: 5)), ["don't"])
            XCTAssertEqual(lexicon.completions(prefix: "", limit: 4), [0, 1, 2, 3])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.completions(prefix: "hä", limit: 5)), ["hält"])
            XCTAssertEqual(lexicon.completions(prefix: "zz", limit: 5), [])
            XCTAssertEqual(lexicon.completions(prefix: "ha", limit: 0), [])
        }
    }

    func testCompletionsMatchReferenceOnRandomVocabularies() throws {
        var rng = LexiconTestRandom(seed: 7)
        for _ in 0..<12 {
            let entries = LexiconTestData.randomVocabulary(count: 400, rng: &rng)
            for lexicon in try pair(entries) {
                let keys = (0..<lexicon.wordCount).map { Array(TextUnits.lookupKey(lexicon.word($0)).utf16) }
                for _ in 0..<40 {
                    let source = keys.randomElement(using: &rng)!
                    let prefix = Array(source.prefix(Int.random(in: 0...min(3, source.count), using: &rng)))
                    let limit = Int.random(in: 1...12, using: &rng)
                    let expected = (0..<keys.count).filter { keys[$0].starts(with: prefix) }.prefix(limit)
                    XCTAssertEqual(lexicon.completions(prefix: String(decoding: prefix, as: UTF16.self), limit: limit), Array(expected))
                }
            }
        }
    }

    // MARK: Bigrams

    func testSuccessors() throws {
        let entries: [(word: String, zipf: Double)] = [("ich", 7), ("bin", 6.5), ("habe", 6.4), ("Essen", 5), ("essen", 5.5), ("gern", 5), ("Hunger", 4.5)]
        let bigrams: [(previous: String, next: String, log2Prob: Double)] = [
            ("ich", "bin", -1), ("ich", "habe", -1.5), ("Ich", "habe", -1.2), ("ich", "Hunger", -8.5),
            ("ich", "gern", -8), ("ich", "unbekannt", -1), ("Essen", "gern", -2), ("habe", "hunger", 0.5),
            ("ich", "essen", .nan),
        ]
        for lexicon in try pair(entries, bigrams: bigrams) {
            let ich = try XCTUnwrap(LexiconTestData.id(of: "ich", in: lexicon))
            let next = lexicon.successors(of: ich, limit: 10)
            XCTAssertEqual(LexiconTestData.words(lexicon, next.map(\.id)), ["bin", "habe", "gern"])
            // Scores: round(255 + 32 × log2P), max over casings ("Ich habe" −1.2 → 217); −8 → 0.
            XCTAssertEqual(next.map(\.log2Prob), [-1, (217 - 255) / 32.0, -255 / 32.0])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.successors(of: ich, limit: 1).map(\.id)), ["bin"])
            XCTAssertTrue(lexicon.successors(of: ich, limit: 0).isEmpty)
            // "Essen" and "essen" share the key; bigrams live under the most frequent casing ("essen").
            let essen = try XCTUnwrap(LexiconTestData.id(of: "essen", in: lexicon))
            let capitalEssen = try XCTUnwrap(LexiconTestData.id(of: "Essen", in: lexicon))
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.successors(of: essen, limit: 5).map(\.id)), ["gern"])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.successors(of: capitalEssen, limit: 5).map(\.id)), ["gern"])
            // P > 1 is clamped to score 255 (log2P 0); the successor resolves to its main casing.
            let habe = try XCTUnwrap(LexiconTestData.id(of: "habe", in: lexicon))
            XCTAssertEqual(lexicon.successors(of: habe, limit: 5).map(\.log2Prob), [0])
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.successors(of: habe, limit: 5).map(\.id)), ["Hunger"])
            XCTAssertTrue(lexicon.successors(of: try XCTUnwrap(LexiconTestData.id(of: "gern", in: lexicon)), limit: 5).isEmpty)
        }
    }

    func testSuccessorsMatchReferenceOnRandomBigrams() throws {
        var rng = LexiconTestRandom(seed: 23)
        for _ in 0..<6 {
            let entries = LexiconTestData.randomVocabulary(count: 250, rng: &rng)
            let bigrams = LexiconTestData.randomBigrams(for: entries, count: 600, rng: &rng)
            for lexicon in try pair(entries, bigrams: bigrams) {
                // Reference: both sides map to their key's most frequent casing, the best score per pair wins.
                func canonical(_ word: String) -> Int? { lexicon.lookup(key: TextUnits.lookupKey(word)).first }
                var best: [Int: [Int: UInt8]] = [:]
                for b in bigrams {
                    guard let score = LexiconFormat.bigramScore(log2Prob: b.log2Prob),
                          let prev = canonical(b.previous), let next = canonical(b.next) else { continue }
                    best[prev, default: [:]][next] = max(best[prev]?[next] ?? 0, score)
                }
                for id in 0..<lexicon.wordCount {
                    let main = try XCTUnwrap(canonical(lexicon.word(id)))
                    let expected = (best[main] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    let actual = lexicon.successors(of: id, limit: .max)
                    XCTAssertEqual(actual.map(\.id), expected.map(\.key))
                    XCTAssertEqual(actual.map(\.log2Prob), expected.map { LexiconFormat.log2Prob(fromScore: $0.value) })
                    XCTAssertEqual(lexicon.successors(of: id, limit: 2).map(\.id), Array(expected.prefix(2).map(\.key)))
                }
            }
        }
    }

    // MARK: Binary format

    func testBinaryRoundTripMatchesInMemory() throws {
        var rng = LexiconTestRandom(seed: 42)
        for round in 0..<10 {
            let entries = LexiconTestData.randomVocabulary(count: 150 + round * 60, rng: &rng)
            let bigrams = LexiconTestData.randomBigrams(for: entries, count: 300, rng: &rng)
            let (memory, binary) = try LexiconTestData.both(entries, bigrams: bigrams)
            XCTAssertEqual(binary.wordCount, memory.wordCount)
            XCTAssertEqual(binary.languageID, "test")
            for id in 0..<memory.wordCount {
                XCTAssertEqual(binary.word(id), memory.word(id))
                XCTAssertEqual(binary.zipf(id), memory.zipf(id))
                let a = binary.successors(of: id, limit: 50), b = memory.successors(of: id, limit: 50)
                XCTAssertEqual(a.map(\.id), b.map(\.id))
                XCTAssertEqual(a.map(\.log2Prob), b.map(\.log2Prob))
            }
            XCTAssertEqual(binary.topWords(limit: 20), memory.topWords(limit: 20))
            for _ in 0..<60 {
                let word = entries.randomElement(using: &rng)!.word
                let key = TextUnits.lookupKey(word)
                XCTAssertEqual(binary.lookup(key: key), memory.lookup(key: key))
                XCTAssertTrue(binary.lookup(key: key).contains { binary.word($0) == word.precomposedStringWithCanonicalMapping })
                let prefix = String(key.prefix(Int.random(in: 0...3, using: &rng)))
                XCTAssertEqual(binary.completions(prefix: prefix, limit: 8), memory.completions(prefix: prefix, limit: 8))
                let taps = key.map { TapInput.exact(String($0)) }
                let maxCost = Double.random(in: 0...20, using: &rng)
                XCTAssertEqual(binary.fuzzySearch(taps: taps, costs: .standard, maxCost: maxCost, limit: 15),
                               memory.fuzzySearch(taps: taps, costs: .standard, maxCost: maxCost, limit: 15))
            }
            XCTAssertEqual(memory.serialized(), LexiconBuilder.build(languageID: "test", entries: entries, bigrams: bigrams))
        }
    }

    func testFileLayout() throws {
        let data = LexiconBuilder.build(languageID: "de-AT", entries: sample, bigrams: [("ich", "bin", -1)])
        XCTAssertEqual(Array(data.prefix(4)), Array("KBDL".utf8))
        XCTAssertEqual(LexiconTestData.u32(data, 4), 1)
        let wordCount = LexiconTestData.u32(data, 8)
        XCTAssertEqual(wordCount, sample.count)
        XCTAssertEqual(Array(data[56..<64]), Array("de-AT".utf8) + [0, 0, 0])
        for offset in stride(from: 24, through: 52, by: 4) where offset != 28 {
            XCTAssertEqual(LexiconTestData.u32(data, offset) % 4, 0, "section at header offset \(offset) is aligned")
        }
        // Root has the first letters as children, sorted, starting at node 1.
        let nodes = LexiconTestData.u32(data, 40)
        XCTAssertEqual(LexiconTestData.u32(data, nodes), 1)
        let rootChildren = Int(data[nodes + 6])
        let firstUnits = (1...rootChildren).map { LexiconTestData.u32(data, nodes + $0 * 12 + 4) & 0xFFFF }
        XCTAssertEqual(firstUnits, Array(Set(sample.map { TextUnits.lookupKey($0.word).utf16.first! })).sorted().map(Int.init))

        let stats = try LexiconFormat.validate(data)
        XCTAssertEqual(stats.languageID, "de-AT")
        XCTAssertEqual(stats.wordCount, sample.count)
        XCTAssertEqual(stats.valueCount, sample.count)
        XCTAssertEqual(stats.bigramCount, 0)
        XCTAssertEqual(stats.fileSize, data.count)
        XCTAssertEqual(stats.maxKeyLength, 6)
        XCTAssertEqual(stats.mismatchedKeys, 0)
        XCTAssertNil(try LexiconFormat.validate(data, checkWordKeys: false).mismatchedKeys)

        // Long language ids are truncated to 8 ASCII bytes.
        let long = LexiconBuilder.build(languageID: "abcdefghij", entries: [("a", 1)])
        XCTAssertEqual(try BinaryLexicon(data: long).languageID, "abcdefgh")
    }

    func testValidateAcceptsRandomFiles() throws {
        var rng = LexiconTestRandom(seed: 3)
        for _ in 0..<5 {
            let entries = LexiconTestData.randomVocabulary(count: 500, rng: &rng)
            let data = LexiconBuilder.build(languageID: "sq", entries: entries, bigrams: LexiconTestData.randomBigrams(for: entries, count: 500, rng: &rng))
            let stats = try LexiconFormat.validate(data)
            XCTAssertEqual(stats.mismatchedKeys, 0)
            XCTAssertEqual(stats.wordCount, try BinaryLexicon(data: data).wordCount)
        }
    }

    func testHeaderErrors() throws {
        let good = LexiconBuilder.build(languageID: "en-GB", entries: sample)
        XCTAssertThrowsError(try BinaryLexicon(data: good.prefix(40))) { XCTAssertEqual($0 as? LexiconError, .truncated) }
        XCTAssertThrowsError(try BinaryLexicon(data: Data())) { XCTAssertEqual($0 as? LexiconError, .truncated) }

        var bad = good
        bad[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try BinaryLexicon(data: bad)) { XCTAssertEqual($0 as? LexiconError, .badMagic) }

        bad = good
        LexiconTestData.setU32(&bad, 4, 2)
        XCTAssertThrowsError(try BinaryLexicon(data: bad)) { XCTAssertEqual($0 as? LexiconError, .unsupportedVersion(2)) }

        bad = good
        LexiconTestData.setU32(&bad, 40, UInt32(LexiconTestData.u32(good, 40) + 2))
        XCTAssertThrowsError(try BinaryLexicon(data: bad)) { error in
            guard case .invalidSection = error as? LexiconError else { return XCTFail("\(error)") }
        }

        // Truncated file: the last section no longer fits.
        XCTAssertThrowsError(try BinaryLexicon(data: good.prefix(good.count - 4))) { error in
            guard case .invalidSection = error as? LexiconError else { return XCTFail("\(error)") }
        }

        bad = good
        LexiconTestData.setU32(&bad, 12, 100_000)
        XCTAssertThrowsError(try BinaryLexicon(data: bad))

        bad = good
        LexiconTestData.setU32(&bad, 12, 0)
        XCTAssertThrowsError(try BinaryLexicon(data: bad)) { XCTAssertEqual($0 as? LexiconError, .corrupt("missing root node")) }

        bad = good
        LexiconTestData.setU32(&bad, 36, 8)
        XCTAssertThrowsError(try BinaryLexicon(data: bad)) { error in
            guard case .invalidSection = error as? LexiconError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(LexiconError.badMagic.description.isEmpty)
    }

    func testValidateDetectsStructuralDamage() throws {
        let good = LexiconBuilder.build(languageID: "it", entries: sample, bigrams: [("the", "und", -1), ("the", "Haus", -2)])
        XCTAssertNoThrow(try LexiconFormat.validate(good))
        let nodes = LexiconTestData.u32(good, 40)
        let values = LexiconTestData.u32(good, 44)
        let zipf = LexiconTestData.u32(good, 36)
        let bigrams = LexiconTestData.u32(good, 52)

        var damaged: [Data] = []
        var d = good
        d[nodes + 12 + 7] &+= 1 // maxZipf of node 1
        damaged.append(d)
        d = good
        d.withUnsafeMutableBytes { raw in // swap the units of the first two root children (unsorted)
            let a = raw.loadUnaligned(fromByteOffset: nodes + 12 + 4, as: UInt16.self)
            let b = raw.loadUnaligned(fromByteOffset: nodes + 24 + 4, as: UInt16.self)
            raw.storeBytes(of: b, toByteOffset: nodes + 12 + 4, as: UInt16.self)
            raw.storeBytes(of: a, toByteOffset: nodes + 24 + 4, as: UInt16.self)
        }
        damaged.append(d)
        d = good
        LexiconTestData.setU32(&d, nodes, 2) // root children no longer start at 1
        damaged.append(d)
        d = good
        LexiconTestData.setU32(&d, values, UInt32(LexiconTestData.u32(good, values + 4))) // a word stored twice
        damaged.append(d)
        d = good
        LexiconTestData.setU32(&d, values, 9999) // unknown word id
        damaged.append(d)
        d = good
        d[zipf + 3] = 255 // frequency order broken
        damaged.append(d)
        d = good
        LexiconTestData.setU32(&d, bigrams, 0xFF00_FFFF) // unknown successor
        damaged.append(d)
        d = good
        d[LexiconTestData.u32(good, 24)] = 0xFF // invalid UTF-8
        damaged.append(d)

        for (i, data) in damaged.enumerated() {
            XCTAssertThrowsError(try LexiconFormat.validate(data), "damage \(i)")
            // The header is intact, so the lexicon opens and stays usable without crashing.
            let lexicon = try BinaryLexicon(data: data)
            exercise(lexicon)
        }
    }

    func testRandomDamageNeverCrashes() throws {
        var rng = LexiconTestRandom(seed: 99)
        let entries = LexiconTestData.randomVocabulary(count: 300, rng: &rng)
        let good = LexiconBuilder.build(languageID: "x", entries: entries, bigrams: LexiconTestData.randomBigrams(for: entries, count: 200, rng: &rng))
        for _ in 0..<150 {
            var data = good
            for _ in 0..<Int.random(in: 1...40, using: &rng) {
                let offset = Int.random(in: LexiconFormat.headerSize..<data.count, using: &rng)
                data[offset] = UInt8.random(in: 0...255, using: &rng)
            }
            guard let lexicon = try? BinaryLexicon(data: data) else { continue }
            exercise(lexicon)
        }
    }

    func testOverlappingChildRangesStayBounded() throws {
        // Every node claims all following nodes as children: a naive traversal would take exponential time.
        var rng = LexiconTestRandom(seed: 31)
        let entries = LexiconTestData.randomVocabulary(count: 30, maxLength: 4, rng: &rng)
        var data = LexiconBuilder.build(languageID: "x", entries: entries)
        let nodeCount = LexiconTestData.u32(data, 12)
        let nodes = LexiconTestData.u32(data, 40)
        XCTAssertGreaterThan(nodeCount, 40)
        for i in 0..<nodeCount {
            LexiconTestData.setU32(&data, nodes + i * 12, UInt32(i + 1))
            data[nodes + i * 12 + 6] = UInt8(min(255, nodeCount - i - 1))
            data[nodes + i * 12 + 7] = 255
        }
        XCTAssertThrowsError(try LexiconFormat.validate(data))
        let lexicon = try BinaryLexicon(data: data)
        let costs = FuzzyCostModel(substitution: 0, insertion: 0, deletion: 0, transposition: 0, diacritic: 0, apostropheInsertion: 0)
        // At most `nodeCount` node visits, each offering at most 255 words.
        XCTAssertLessThanOrEqual(lexicon.fuzzySearch(taps: [.exact("a"), .exact("b")], costs: costs, maxCost: .infinity, limit: .max).count, nodeCount * 255)
        XCTAssertLessThanOrEqual(lexicon.completions(prefix: "", limit: .max).count, nodeCount * 255)
        exercise(lexicon)
    }

    func testMemoryMappedFileAndDataSlices() throws {
        let data = LexiconBuilder.build(languageID: "en-US", entries: sample)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lexicon-\(UUID().uuidString).kbdl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let mapped = try BinaryLexicon(url: url)
        XCTAssertEqual(mapped.byteCount, data.count)
        XCTAssertEqual(LexiconTestData.words(mapped, mapped.lookup(key: "haus")), ["Haus", "haus"])
        XCTAssertThrowsError(try BinaryLexicon(url: url.appendingPathExtension("missing")))

        // A slice whose indices do not start at 0.
        let padded = Data([1, 2, 3]) + data
        let slice = padded[3...]
        let sliced = try BinaryLexicon(data: slice)
        XCTAssertEqual(LexiconTestData.words(sliced, sliced.completions(prefix: "ha", limit: 2)), ["Haus", "Hallo"])
        XCTAssertEqual(try LexiconFormat.validate(slice).wordCount, sample.count)
    }

    func testOverflowingNodesDropTheRarestWords() throws {
        // 300 different first letters: the root keeps the 255 most frequent.
        let letters = (0..<300).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let entries = letters.enumerated().map { (word: $0.element + "x", zipf: 7 - Double($0.offset) / 100) }
        for lexicon in try pair(entries) {
            XCTAssertEqual(lexicon.wordCount, 255)
            XCTAssertEqual(lexicon.word(0), letters[0] + "x")
            XCTAssertEqual(lexicon.word(254), letters[254] + "x")
            XCTAssertEqual(lexicon.lookup(key: letters[260] + "x"), [])
        }
        XCTAssertNoThrow(try LexiconFormat.validate(LexiconBuilder.build(languageID: "x", entries: entries)))

        // 300 casings of one key: the 255 most frequent are kept, plus an unrelated word.
        let letterCount = 9
        var casings: [(word: String, zipf: Double)] = (0..<300).map { mask in
            let word = String("abcdefghi".enumerated().map { mask & (1 << $0.offset) != 0 ? Character($0.element.uppercased()) : $0.element })
            return (word, 6 - Double(mask) / 1000)
        }
        XCTAssertLessThan(300, 1 << letterCount)
        casings.append(("zebra", 1))
        for lexicon in try pair(casings) {
            XCTAssertEqual(lexicon.wordCount, 256)
            XCTAssertEqual(lexicon.lookup(key: "abcdefghi"), Array(0..<255))
            XCTAssertEqual(lexicon.word(0), "abcdefghi")
            XCTAssertEqual(lexicon.lookup(key: "zebra"), [255])
        }

        // Both overflows in one build: the root has "a" plus 300 other first letters (the rarest 46 go),
        // and "abcdefghi" has 300 casings (the rarest 45 go).
        let combined = Array(casings.dropLast()) + entries.map { (word: $0.word, zipf: $0.zipf - 2) }
        for lexicon in try pair(combined) {
            XCTAssertEqual(lexicon.wordCount, 255 + 254)
            XCTAssertEqual(lexicon.lookup(key: "abcdefghi"), Array(0..<255))
            XCTAssertEqual(LexiconTestData.words(lexicon, lexicon.lookup(key: letters[253] + "x")), [letters[253] + "x"])
            XCTAssertEqual(lexicon.lookup(key: letters[254] + "x"), [])
            XCTAssertEqual(lexicon.completions(prefix: "", limit: .max).count, 509)
        }
        XCTAssertNoThrow(try LexiconFormat.validate(LexiconBuilder.build(languageID: "x", entries: combined)))
    }

    // MARK: Bundled dictionaries

    func testBundledDictionariesLoad() throws {
        let directory = LexiconTestData.repositoryRoot.appendingPathComponent("Resources/Dictionaries")
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "kbdl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let expectations: [String: [String]] = [
            "de-AT": ["und", "haus"], "en-GB": ["the", "and"], "en-US": ["the", "and"],
            "it": ["che", "di"], "sq": ["është", "të"],
        ]
        for url in files {
            let id = url.deletingPathExtension().lastPathComponent
            let stats = try LexiconFormat.validate(Data(contentsOf: url, options: .alwaysMapped))
            let lexicon = try BinaryLexicon(url: url)
            print("[lexicon] \(url.lastPathComponent): \(stats.wordCount) words, \(stats.nodeCount) nodes, \(stats.bigramCount) bigrams, \(stats.fileSize / 1024) KiB, key mismatches \(stats.mismatchedKeys ?? -1)")
            XCTAssertEqual(lexicon.languageID, id, url.lastPathComponent)
            XCTAssertGreaterThan(lexicon.wordCount, 1000, url.lastPathComponent)
            XCTAssertLessThanOrEqual(lexicon.wordCount, 250_000, url.lastPathComponent)
            XCTAssertLessThanOrEqual(stats.fileSize, 12 << 20, url.lastPathComponent)
            XCTAssertLessThanOrEqual(stats.mismatchedKeys ?? 0, stats.wordCount / 1000, url.lastPathComponent)
            let top = lexicon.word(0)
            XCTAssertTrue(lexicon.lookup(key: TextUnits.lookupKey(top)).contains(0), url.lastPathComponent)
            XCTAssertEqual(lexicon.completions(prefix: "", limit: 3), [0, 1, 2], url.lastPathComponent)
            let taps = TextUnits.lookupKey(top).map { TapInput.exact(String($0)) }
            XCTAssertEqual(lexicon.fuzzySearch(taps: taps, costs: .standard, maxCost: 10, limit: 5).first?.cost, 0, url.lastPathComponent)
            for word in expectations[id] ?? [] {
                XCTAssertFalse(lexicon.lookup(key: word).isEmpty, "\(id) contains \(word)")
            }
            if id == "de-AT" {
                XCTAssertEqual(lexicon.lookup(key: "haus").first.map(lexicon.word), "Haus")
            }
        }
    }

    // MARK: Helpers

    private func pair(_ entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)] = []) throws -> [WordLexicon] {
        let (memory, binary) = try LexiconTestData.both(entries, bigrams: bigrams)
        return [memory, binary]
    }

    /// Calls every lexicon operation (used on damaged files: must not crash).
    private func exercise(_ lexicon: BinaryLexicon) {
        for id in [-1, 0, 1, 5, lexicon.wordCount - 1, lexicon.wordCount, Int.max] {
            _ = lexicon.word(id)
            _ = lexicon.zipf(id)
            _ = lexicon.successors(of: id, limit: 10)
        }
        _ = lexicon.topWords(limit: 10)
        for key in ["", "a", "ha", "haus", "e", "ës", "don'"] {
            _ = lexicon.lookup(key: key)
            _ = lexicon.completions(prefix: key, limit: 20)
        }
        let taps = "hause".map { TapInput.exact(String($0)) }
        _ = lexicon.fuzzySearch(taps: taps, costs: .standard, maxCost: 25, limit: 50)
    }
}
