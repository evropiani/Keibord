import XCTest
@testable import KeibordCore

/// Consistency of the Swift lexicon implementations on samples of the real bundled dictionaries:
/// `InMemoryLexicon` and `BinaryLexicon(LexiconBuilder.build(…))` must agree on every operation, and
/// the Swift writer must reproduce what the Python writer stored (frequencies, casings, bigrams).
final class LexiconRealDataTests: XCTestCase {
    private static let directory = LexiconTestData.repositoryRoot.appendingPathComponent("Resources/Dictionaries")

    private func bundled(_ id: String) throws -> BinaryLexicon {
        let url = Self.directory.appendingPathComponent("\(id).kbdl")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no \(id) dictionary") }
        return try BinaryLexicon(url: url)
    }

    /// 5 000 words: the 1 000 most frequent and 4 000 spread over the rest, with the bigrams among them.
    private func sample(of lexicon: BinaryLexicon, count: Int = 5000) -> (entries: [(word: String, zipf: Double)], bigrams: [(previous: String, next: String, log2Prob: Double)]) {
        let head = min(1000, lexicon.wordCount)
        var ids = Array(0..<head)
        let rest = lexicon.wordCount - head
        let spread = count - head
        if rest > 0, spread > 0 {
            for i in 0..<spread { ids.append(head + i * rest / spread) }
        }
        let entries = ids.map { (word: lexicon.word($0), zipf: lexicon.zipf($0)) }
        let inSample = Set(ids)
        var bigrams: [(previous: String, next: String, log2Prob: Double)] = []
        for id in ids {
            for s in lexicon.successors(of: id, limit: 255) where inSample.contains(s.id) {
                bigrams.append((lexicon.word(id), lexicon.word(s.id), s.log2Prob))
            }
        }
        return (entries, bigrams)
    }

    /// Typing errors of a word: an adjacent swap, a missing letter, a wrong letter, accents dropped.
    private func typos(of key: String) -> [String] {
        let c = Array(key)
        guard c.count >= 4 else { return [key] }
        var result = [key, Diacritics.fold(key)]
        var swapped = c
        swapped.swapAt(1, 2)
        result.append(String(swapped))
        var dropped = c
        dropped.remove(at: c.count / 2)
        result.append(String(dropped))
        var replaced = c
        replaced[c.count - 2] = replaced[c.count - 2] == "x" ? "q" : "x"
        result.append(String(replaced))
        return result
    }

    private func checkConsistency(_ id: String) throws {
        let original = try bundled(id)
        let (entries, bigrams) = sample(of: original)
        let data = LexiconBuilder.build(languageID: id, entries: entries, bigrams: bigrams)
        let memory = InMemoryLexicon(languageID: id, entries: entries, bigrams: bigrams)
        let binary = try BinaryLexicon(data: data)
        let stats = try LexiconFormat.validate(data)

        XCTAssertEqual(memory.serialized(), data, "\(id): both writers produce the same bytes")
        XCTAssertEqual(stats.mismatchedKeys, 0)
        XCTAssertEqual(stats.languageID, id)
        XCTAssertEqual(Set(entries.map(\.word)).count, binary.wordCount, "\(id): no sample word was dropped")
        XCTAssertEqual(memory.wordCount, binary.wordCount)
        XCTAssertEqual(memory.languageID, binary.languageID)
        for i in 0..<binary.wordCount {
            XCTAssertEqual(memory.word(i), binary.word(i))
            XCTAssertEqual(memory.zipf(i), binary.zipf(i))
            if i > 0 { XCTAssertGreaterThanOrEqual(binary.zipf(i - 1), binary.zipf(i)) }
        }
        XCTAssertEqual(memory.topWords(limit: 100), binary.topWords(limit: 100))

        let sampleWords = Set(entries.map(\.word))
        var prefixes = Set<String>()
        for (n, entry) in entries.enumerated() {
            let key = TextUnits.lookupKey(entry.word)
            let ids = binary.lookup(key: key)
            XCTAssertEqual(memory.lookup(key: key), ids, "\(id) lookup \(key)")
            XCTAssertTrue(ids.map(binary.word).contains(entry.word), "\(id): \(entry.word) is found by its key")
            // Fidelity to the bundled file: same frequency, same casings among the sampled words.
            if let builtID = ids.first(where: { binary.word($0) == entry.word }) {
                XCTAssertEqual(binary.zipf(builtID), entry.zipf, "\(id) zipf of \(entry.word)")
            }
            let originalCasings = Set(original.lookup(key: key).map(original.word)).intersection(sampleWords)
            XCTAssertEqual(Set(ids.map(binary.word)), originalCasings, "\(id) casings of \(key)")
            if n % 10 == 0 {
                for length in 1...min(4, key.count) { prefixes.insert(String(key.prefix(length))) }
            }
        }
        prefixes.insert("")
        for prefix in prefixes {
            XCTAssertEqual(memory.completions(prefix: prefix, limit: 12), binary.completions(prefix: prefix, limit: 12), "\(id) completions \(prefix)")
        }

        var fuzzyQueries = 0
        for entry in entries.enumerated().filter({ $0.offset % 40 == 0 }).map(\.element) {
            for typed in typos(of: TextUnits.lookupKey(entry.word)) {
                let taps = typed.map { TapInput.exact(String($0)) }
                let a = memory.fuzzySearch(taps: taps, costs: .standard, maxCost: 18, limit: 20)
                let b = binary.fuzzySearch(taps: taps, costs: .standard, maxCost: 18, limit: 20)
                XCTAssertEqual(a, b, "\(id) fuzzy \(typed)")
                fuzzyQueries += 1
            }
            // The exact (lower-case) spelling is always found at cost 0.
            let exact = TextUnits.lookupKey(entry.word).map { TapInput.exact(String($0)) }
            XCTAssertTrue(binary.fuzzySearch(taps: exact, costs: .standard, maxCost: 18, limit: 50)
                .contains { $0.cost == 0 && binary.word($0.id) == entry.word }, "\(id) exact fuzzy \(entry.word)")
        }
        XCTAssertGreaterThan(fuzzyQueries, 300)

        // Bigrams: identical in both, and the probabilities the Python writer stored survive the rebuild.
        var comparedPairs = 0
        for i in 0..<binary.wordCount {
            let a = memory.successors(of: i, limit: 30), b = binary.successors(of: i, limit: 30)
            XCTAssertEqual(a.map(\.id), b.map(\.id))
            XCTAssertEqual(a.map(\.log2Prob), b.map(\.log2Prob))
        }
        for pair in bigrams {
            guard let prev = LexiconTestData.id(of: pair.previous, in: binary), let next = LexiconTestData.id(of: pair.next, in: binary),
                  binary.lookup(key: TextUnits.lookupKey(pair.previous)).first == prev,
                  binary.lookup(key: TextUnits.lookupKey(pair.next)).first == next else { continue }
            let stored = binary.successors(of: prev, limit: 255).first { $0.id == next }
            XCTAssertEqual(stored?.log2Prob, pair.log2Prob, "\(id) P(\(pair.next) | \(pair.previous))")
            comparedPairs += 1
        }
        print("[lexicon-sample] \(id): \(binary.wordCount) words, \(binary.lookup(key: "").count) root ids, \(bigrams.count) bigrams (\(comparedPairs) compared), \(prefixes.count) prefixes, \(fuzzyQueries) fuzzy queries")
        if id == "de-AT" { XCTAssertGreaterThan(comparedPairs, 100) }
    }

    func testGermanSampleConsistency() throws {
        try checkConsistency("de-AT")
    }

    func testAlbanianSampleConsistency() throws {
        try checkConsistency("sq")
    }

    /// The full structural check of every file runs in `LexiconTests.testBundledDictionariesLoad`.
    func testEveryLanguageHasABundledDictionary() throws {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "kbdl" }
        guard !files.isEmpty else { throw XCTSkip("no dictionaries") }
        let bundled = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(bundled, ["de-AT", "en-GB", "en-US", "it", "sq"])
        XCTAssertEqual(Set(KeyboardLanguage.allCases.map(\.dictionaryID)), bundled)
        for url in files {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            XCTAssertEqual(LexiconTestData.u32(data, 4), 1, "\(url.lastPathComponent) format version")
            XCTAssertEqual(try BinaryLexicon(data: data).languageID, url.deletingPathExtension().lastPathComponent)
        }
    }

    func testFastLookupKeyMatchesTextUnits() {
        let words = ["Haus", "HAUS", "Straße", "STRASSE", "geht’s", "don't", "Ärger", "ÇFARË", "është", "perché", "İstanbul",
                     "Ǆemal", "ΣΟΦΙΑ", "e\u{301}", "😀ok", "Ⅻ", "ﬁx", "", "x"]
        for w in words { XCTAssertEqual(LexiconKey.string(w), TextUnits.lookupKey(w), w.debugDescription) }
    }
}
