import XCTest
@testable import KeibordCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Suggestion-quality evaluation against the real bundled dictionaries and real spatial taps.
///
/// Taps come from the actual letters layout of a 393 pt wide portrait iPhone (`LayoutFactory` +
/// `LayoutGeometry` + `TouchResolver`): clean typing taps key centres, an adjacent-key slip taps a point
/// between the intended key and the neighbouring key that was hit. The data lives in
/// `EngineQualityDataTests.swift`. Set `KEIBORD_EVAL_VERBOSE=1` to print every miss.
final class EngineQualityTests: XCTestCase {
    // MARK: Thresholds (current measured values are printed by every test run)
    //
    // Measured on the bundled dictionaries (Oct 2026, before → after the engine-quality pass):
    //   mono accuracy        de 95.5 → 98.9 %, en 91.0 → 98.7 %, sq 100 → 98.2 %, it 98.4 → 98.4 %; top-3 ≥ 98.7 → 100 %
    //   4 languages (cold)   de 83.1 → 94.4 %, en 75.6 → 88.5 %, sq 91.1 → 96.4 %, it 92.2 → 98.4 %
    //   4 languages (context) de 83.1 → 98.9 %, en 82.1 → 93.6 %, sq 91.1 → 98.2 %, it 93.8 → 98.4 %
    //   German layout        en 70.5 → 80.8 %, sq 89.3 → 94.6 %
    //   curated valid words  false positives mono 24 → 0, multilingual 17 → 0; shared names/slang 29 → 0;
    //                        held-out valid words 22/31/27/23 → 4/1/3/0 (de/en/sq/it), four languages 18 → 1
    // The floors sit a few cases below the measured values so dictionary updates do not break the build,
    // while a real regression in a category still does.

    /// Minimum share of typo cases whose autocorrection is exactly the intended word.
    static let minAccuracy: [KeyboardLanguage: Double] = [.deAT: 0.93, .enGB: 0.93, .sqXK: 0.93, .itIT: 0.93]
    /// Minimum share of typo cases with the intended word in the bar (or as autocorrection).
    static let minTop3: [KeyboardLanguage: Double] = [.deAT: 0.97, .enGB: 0.97, .sqXK: 0.97, .itIT: 0.97]
    /// Most typo cases one language alone may autocorrect into a different word (measured: 0).
    static let maxWrongAutocorrections = 1
    /// Accuracy floor with all four of the owner's languages enabled (layout language first), first word.
    static let minMultilingualAccuracy = 0.85
    /// Same, a few words into the message (the language detector knows the language).
    static let minMultilingualAccuracyAfterContext = 0.90
    /// English and Albanian typed on the German layout.
    static let minAccuracyOnGermanLayout: [KeyboardLanguage: Double] = [.enGB: 0.75, .sqXK: 0.88]
    /// Held-out valid words (names, slang, brands) never tuned on: most false positives per configuration.
    /// The remaining ones are mostly legitimate in the active language (German "safe" → "Safe").
    static let maxValidationFalsePositives = 6
    /// Same with all four of the owner's languages enabled (measured: "gspritzter" → "Gspritzter").
    static let maxValidationFalsePositivesMultilingual = 2
    /// Categories whose typed form may be a dictionary key.
    static let knownTypoCategories: Set<String> = ["case", "variety"]

    private func requireDictionaries() throws {
        guard EngineQualityHarness.available else { throw XCTSkip("dictionaries not built") }
    }

    // MARK: Data sanity

    func testDatasetIsWellFormed() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        var problems: [String] = []
        for language in EngineQualityData.evaluatedLanguages {
            let cases = EngineQualityData.typoCases(for: language)
            XCTAssertGreaterThanOrEqual(cases.count, 40, "\(language): at least 40 typo cases")
            for c in cases {
                if !h.isDictionaryWord(c.intended, language) { problems.append("\(language) intended not in dictionary: \(c.intended)") }
                // Case corrections and British spellings of American words ("center" is also the name "Center")
                // start from known keys; every other typo must be an unknown word.
                if !Self.knownTypoCategories.contains(c.category), h.isKnownKey(c.typed, language) {
                    problems.append("\(language) typo is a known word: \(c.typed)")
                }
            }
            for c in EngineQualityData.completionCases(for: language) where !h.isDictionaryWord(c.intended, language) {
                problems.append("\(language) completion not in dictionary: \(c.intended)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: Autocorrection

    func testTypoAccuracyMonolingual() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in EngineQualityData.evaluatedLanguages {
            let m = h.evaluate(EngineQualityData.typoCases(for: language), label: "mono \(language.rawValue)") { _ in [language] }
            XCTAssertGreaterThanOrEqual(m.accuracy, Self.minAccuracy[language] ?? 0.8, "\(language) accuracy\n\(m.failureList)")
            XCTAssertGreaterThanOrEqual(m.top3Recall, Self.minTop3[language] ?? 0.9, "\(language) top-3 recall\n\(m.failureList)")
            XCTAssertLessThanOrEqual(m.wrongAutocorrections, Self.maxWrongAutocorrections, "\(language) wrong autocorrections\n\(m.failureList)")
        }
    }

    func testTypoAccuracyMultilingual() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in EngineQualityData.evaluatedLanguages {
            let m = h.evaluate(EngineQualityData.typoCases(for: language), label: "multi \(language.rawValue)") {
                EngineQualityData.ownerLanguages(first: $0)
            }
            XCTAssertGreaterThanOrEqual(m.accuracy, Self.minMultilingualAccuracy, "\(language) multilingual accuracy\n\(m.failureList)")
        }
    }

    /// The realistic multilingual case: a few words into a message the detector knows the language.
    func testTypoAccuracyMultilingualAfterContext() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in EngineQualityData.evaluatedLanguages {
            let m = h.evaluate(EngineQualityData.typoCases(for: language), label: "multi+context \(language.rawValue)", primeDetector: true) {
                EngineQualityData.ownerLanguages(first: $0)
            }
            XCTAssertGreaterThanOrEqual(m.accuracy, Self.minMultilingualAccuracyAfterContext,
                                        "\(language) multilingual accuracy after context\n\(m.failureList)")
        }
    }

    /// English and Albanian typed on the German layout with [de-AT, en-GB, sq-XK] (no language switch).
    func testTypoAccuracyOnGermanLayout() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in [KeyboardLanguage.enGB, .sqXK] {
            let m = h.evaluate(EngineQualityData.typoCases(for: language), label: "de-layout \(language.rawValue)") { _ in
                [.deAT, .enGB, .sqXK]
            }
            XCTAssertGreaterThanOrEqual(m.accuracy, Self.minAccuracyOnGermanLayout[language] ?? 0.7, "\(language) on the German layout\n\(m.failureList)")
        }
    }

    // MARK: False positives

    func testNoFalsePositivesOnCuratedWords() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in EngineQualityData.evaluatedLanguages {
            let words = EngineQualityData.curatedValidWords(for: language)
            let mono = h.falsePositives(words, label: "curated mono \(language.rawValue)") { _ in [language] }
            XCTAssertTrue(mono.isEmpty, "\(language): \(mono.joined(separator: ", "))")
            let multi = h.falsePositives(words, label: "curated multi \(language.rawValue)") { _ in EngineQualityData.ownerLanguages(first: language) }
            XCTAssertTrue(multi.isEmpty, "\(language) multilingual: \(multi.joined(separator: ", "))")
        }
        for languages in [[KeyboardLanguage.deAT], [.enGB], [.sqXK], [.itIT], [.deAT, .enGB, .sqXK, .itIT]] {
            let fp = h.falsePositives(EngineQualityData.validationValidWords, label: "validation \(languages.map(\.rawValue))") { _ in languages }
            let limit = languages.count > 1 ? Self.maxValidationFalsePositivesMultilingual : Self.maxValidationFalsePositives
            XCTAssertLessThanOrEqual(fp.count, limit, "held-out valid words \(languages): \(fp.joined(separator: ", "))")
        }
        let shared = EngineQualityData.sharedValidWords
        for languages in [[KeyboardLanguage.deAT, .enGB, .sqXK], [.deAT], [.enGB], [.sqXK], [.itIT]] {
            let fp = h.falsePositives(shared, label: "shared \(languages.map(\.rawValue))") { _ in languages }
            XCTAssertTrue(fp.isEmpty, "\(languages): \(fp.joined(separator: ", "))")
        }
    }

    func testNoFalsePositivesOnFrequentWords() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in EngineQualityData.evaluatedLanguages {
            // German nouns whose rare lower-case twin outranks them in the dictionary ("zeit") are capitalised on purpose.
            let words = h.topWords(language, count: 300).filter { !SuggestionEngine.germanNouns.contains($0) }
            let mono = h.falsePositives(words, label: "top300 mono \(language.rawValue)") { _ in [language] }
            XCTAssertTrue(mono.isEmpty, "\(language): \(mono.joined(separator: ", "))")
            let multi = h.falsePositives(words, label: "top300 multi \(language.rawValue)") { _ in [.deAT, .enGB, .sqXK, .itIT] }
            XCTAssertTrue(multi.isEmpty, "\(language) multilingual: \(multi.joined(separator: ", "))")
            // Typed at sentence start with auto-capitalisation.
            let capitalised = words.map { Casing.capitalizingFirstLetter($0) }
            let start = h.falsePositives(capitalised, sentenceStart: true, label: "top300 capitalised \(language.rawValue)") { _ in [language] }
            XCTAssertTrue(start.isEmpty, "\(language) capitalised: \(start.joined(separator: ", "))")
        }
    }

    // MARK: Completions and predictions

    func testCompletions() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        for language in EngineQualityData.evaluatedLanguages {
            let cases = EngineQualityData.completionCases(for: language)
            let mono = h.evaluate(cases, label: "completion mono \(language.rawValue)") { _ in [language] }
            XCTAssertGreaterThanOrEqual(mono.top3Recall, 0.93, "\(language) completions\n\(mono.failureList)")
            // "nesë" → "nëse" is a fair guess on space; a prefix becoming an unrelated word ("Nachri" → "Nach") is not.
            XCTAssertLessThanOrEqual(mono.wrongAutocorrections, cases.count / 10, "prefixes autocorrected into other words\n\(mono.failureList)")
            let multi = h.evaluate(cases, label: "completion multi \(language.rawValue)") { EngineQualityData.ownerLanguages(first: $0) }
            XCTAssertGreaterThanOrEqual(multi.top3Recall, 0.9, "\(language) multilingual completions\n\(multi.failureList)")
        }
    }

    func testPredictions() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        let engine = h.makeEngine()
        var misses: [String] = []
        var total = 0
        for (language, cases) in EngineQualityData.predictionCases {
            for (previous, expected) in cases {
                total += 1
                let r = engine.suggest(SuggestionQuery(currentWord: "", previousWords: previous, languages: [language]))
                XCTAssertEqual(r.suggestions.count, 3, "\(language) \(previous): three predictions")
                XCTAssertNil(r.autocorrection)
                XCTAssertTrue(r.suggestions.allSatisfy { $0.kind == .prediction })
                let texts = r.suggestions.map(\.text)
                if EngineQualityHarness.verbose { print("  [prediction] \(language.rawValue) \(previous) → \(texts)") }
                if !texts.contains(where: { expected.contains($0) }) {
                    misses.append("\(language.rawValue) \(previous.joined(separator: " ")) → \(texts) (expected one of \(expected))")
                }
            }
        }
        print("[quality] predictions: \(total - misses.count)/\(total) contain an expected word")
        XCTAssertLessThanOrEqual(misses.count, total / 5, misses.joined(separator: "\n"))
    }

    /// After ". " the previous sentence's last word must not drive the predictions or the bigram LM.
    func testPredictionsAtSentenceStartIgnorePreviousSentence() throws {
        try requireDictionaries()
        let engine = EngineQualityHarness.shared.makeEngine()
        let mid = engine.suggest(SuggestionQuery(currentWord: "", previousWords: ["thank"], languages: [.enGB]))
        XCTAssertEqual(mid.suggestions.first?.text, "you")
        let start = engine.suggest(SuggestionQuery(currentWord: "", previousWords: ["thank"], isSentenceStart: true, languages: [.enGB]))
        XCTAssertEqual(start.suggestions.count, 3)
        XCTAssertTrue(start.suggestions.allSatisfy { Casing.startsUppercase($0.text) })
        let fresh = engine.suggest(SuggestionQuery(currentWord: "", isSentenceStart: true, languages: [.enGB]))
        XCTAssertEqual(start.suggestions.map(\.text), fresh.suggestions.map(\.text))
    }


    // MARK: Latency

    func testSuggestLatency() throws {
        try requireDictionaries()
        let h = EngineQualityHarness.shared
        let engine = h.makeEngine()
        let languages: [KeyboardLanguage] = [.deAT, .enGB, .sqXK]
        var queries: [SuggestionQuery] = []
        for language in EngineQualityData.evaluatedLanguages {
            for c in EngineQualityData.typoCases(for: language) {
                queries.append(SuggestionQuery(currentWord: c.typed, taps: h.taps(for: c, on: .deAT), previousWords: c.previous, languages: languages))
            }
        }
        for q in queries.prefix(20) { _ = engine.suggest(q) } // warm up (dictionary pages)
        var times: [Double] = []
        for q in queries {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = engine.suggest(q)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        let mean = times.reduce(0, +) / Double(times.count)
        let p95 = times[Int(Double(times.count - 1) * 0.95)]
        print(String(format: "[quality] suggest() latency, 3 languages, %d queries: mean %.2f ms, p95 %.2f ms, max %.2f ms",
                     times.count, mean, p95, times.last ?? 0))
        #if DEBUG
        XCTAssertLessThan(mean, 150)
        #else
        XCTAssertLessThan(mean, 15)
        XCTAssertLessThan(p95, 30)
        #endif
    }
}

// MARK: - Harness

struct EvalCase {
    var language: KeyboardLanguage
    var category: String
    var previous: [String]
    var typed: String
    var intended: String

    /// Parses "previous words typed>intended".
    init(_ spec: String, language: KeyboardLanguage, category: String) {
        let parts = spec.components(separatedBy: ">")
        precondition(parts.count == 2, "bad case \(spec)")
        var words = parts[0].split(separator: " ").map(String.init)
        typed = words.removeLast()
        previous = words
        intended = parts[1]
        self.language = language
        self.category = category
    }
}

struct EvalMetrics {
    var label: String
    var total = 0
    var correct = 0
    var top3 = 0
    var wrongAutocorrections = 0
    var failures: [String] = []

    var accuracy: Double { total == 0 ? 1 : Double(correct) / Double(total) }
    var top3Recall: Double { total == 0 ? 1 : Double(top3) / Double(total) }
    var failureList: String { failures.joined(separator: "\n") }
}

final class EngineQualityHarness {
    static let dictionaryDir = EngineIntegrationTests.dictionaryDir
    static var available: Bool {
        FileManager.default.fileExists(atPath: dictionaryDir.appendingPathComponent("de-AT.kbdl").path)
    }
    static let shared = EngineQualityHarness()
    static let verbose = ProcessInfo.processInfo.environment["KEIBORD_EVAL_VERBOSE"] == "1"

    private var lexicons: [String: BinaryLexicon] = [:]
    private var keyboards: [KeyboardLanguage: SimulatedKeyboard] = [:]
    private let lock = NSLock()

    func lexicon(_ language: KeyboardLanguage) -> BinaryLexicon? {
        lock.lock()
        defer { lock.unlock() }
        if let lex = lexicons[language.dictionaryID] { return lex }
        let url = Self.dictionaryDir.appendingPathComponent("\(language.dictionaryID).kbdl")
        guard let lex = try? BinaryLexicon(url: url) else { return nil }
        lexicons[language.dictionaryID] = lex
        return lex
    }

    /// Applied to every engine made by `makeEngine` (parameter sweeps).
    var configure: ((SuggestionEngine) -> Void)?
    var quiet = false

    /// A fresh engine (neutral language detector) over the shared dictionaries.
    func makeEngine() -> SuggestionEngine {
        let engine = SuggestionEngine { [unowned self] in self.lexicon($0) }
        configure?(engine)
        return engine
    }

    func keyboard(_ language: KeyboardLanguage) -> SimulatedKeyboard {
        if let k = keyboards[language] { return k }
        let k = SimulatedKeyboard(language: language)
        keyboards[language] = k
        return k
    }

    func isDictionaryWord(_ word: String, _ language: KeyboardLanguage) -> Bool {
        guard let lex = lexicon(language) else { return false }
        return lex.lookup(key: TextUnits.lookupKey(word)).contains { lex.word($0) == word }
    }

    func isKnownKey(_ word: String, _ language: KeyboardLanguage) -> Bool {
        guard let lex = lexicon(language) else { return false }
        return !lex.lookup(key: TextUnits.lookupKey(word)).isEmpty
    }

    func topWords(_ language: KeyboardLanguage, count: Int) -> [String] {
        guard let lex = lexicon(language) else { return [] }
        return lex.topWords(limit: count).map { lex.word($0) }
    }

    func taps(for c: EvalCase, on language: KeyboardLanguage) -> [TapInput] {
        keyboard(language).taps(typed: c.typed, slipFrom: c.category == "slip" ? c.intended : nil)
    }

    /// Autocorrection accuracy and bar recall of `cases`; `languages` maps a case's language to the query languages.
    func evaluate(_ cases: [EvalCase], label: String, primeDetector: Bool = false, languages: (KeyboardLanguage) -> [KeyboardLanguage]) -> EvalMetrics {
        let engine = makeEngine()
        if primeDetector, let c = cases.first {
            // Five committed words known only in the case's language.
            for _ in 0..<5 { engine.detector.observe(knownIn: [c.language], among: languages(c.language)) }
        }
        var m = EvalMetrics(label: label)
        var perCategory: [String: (Int, Int)] = [:]
        for c in cases {
            let langs = languages(c.language)
            let query = SuggestionQuery(currentWord: c.typed, taps: taps(for: c, on: langs[0]), previousWords: c.previous, languages: langs)
            let r = engine.suggest(query)
            m.total += 1
            let ac = r.autocorrection?.text
            let ok = ac == c.intended
            if ok { m.correct += 1 }
            let inBar = ok || r.suggestions.contains { $0.text == c.intended }
            if inBar { m.top3 += 1 }
            let isCompletion = c.category == "completion"
            // A case-only change ("funktion" → "Funktion") is not a different word.
            if let ac = ac, ac != c.intended, TextUnits.lookupKey(ac) != TextUnits.lookupKey(c.typed) { m.wrongAutocorrections += 1 }
            var stats = perCategory[c.category] ?? (0, 0)
            stats.0 += 1
            if isCompletion ? inBar : ok { stats.1 += 1 }
            perCategory[c.category] = stats
            if !(isCompletion ? inBar && (ac == nil || ac == c.intended || TextUnits.lookupKey(ac!) == TextUnits.lookupKey(c.typed)) : ok) {
                let prev = c.previous.isEmpty ? "" : c.previous.joined(separator: " ") + " "
                m.failures.append("  [\(c.category)] \(prev)\(c.typed) → ac=\(ac ?? "nil") bar=\(r.suggestions.map(\.display)) (want \(c.intended))")
            }
        }
        if quiet { return m }
        let categories = perCategory.keys.sorted().map { "\($0) \(perCategory[$0]!.1)/\(perCategory[$0]!.0)" }.joined(separator: ", ")
        print(String(format: "[quality] %@: accuracy %.1f%% (%d/%d), top-3 %.1f%%, wrong autocorrections %d | %@",
                     label, m.accuracy * 100, m.correct, m.total, m.top3Recall * 100, m.wrongAutocorrections, categories))
        if Self.verbose { m.failures.forEach { print($0) } }
        return m
    }

    /// Words that get autocorrected into something else (the false positives).
    func falsePositives(_ words: [String], sentenceStart: Bool = false, label: String, languages: (KeyboardLanguage) -> [KeyboardLanguage]) -> [String] {
        let engine = makeEngine()
        var fps: [String] = []
        for word in words {
            let langs = languages(.deAT)
            let k = keyboard(langs[0])
            let query = SuggestionQuery(currentWord: word, taps: k.taps(typed: word, slipFrom: nil), isSentenceStart: sentenceStart, languages: langs)
            let r = engine.suggest(query)
            if let ac = r.autocorrection, ac.text != word { fps.append("\(word)→\(ac.text)") }
        }
        if quiet { return fps }
        print("[quality] \(label): \(fps.count) false positives / \(words.count)" + (fps.isEmpty ? "" : " " + fps.joined(separator: ", ")))
        return fps
    }
}

/// The letters layout of one language on a 393 pt wide portrait iPhone.
struct SimulatedKeyboard {
    let resolver: TouchResolver
    let centres: [String: CGPoint]

    init(language: KeyboardLanguage) {
        let layout = LayoutFactory.layout(for: LayoutRequest(language: language, base: language.defaultBaseLayout))
        let frames = LayoutGeometry.frames(for: layout, width: 393, metrics: .standard(height: .standard, landscape: false))
        resolver = TouchResolver(frames: frames, touchModelKey: layout.touchModelKey)
        var centres: [String: CGPoint] = [:]
        for f in frames where f.key.isLetter && f.key.style == .character {
            centres[f.key.id] = CGPoint(x: f.rect.midX, y: f.rect.midY)
        }
        self.centres = centres
    }

    func tap(at point: CGPoint) -> TapInput {
        resolver.resolve(point)?.tap ?? TapInput(candidates: [])
    }

    /// Taps for `typed`: key centres, except where `slipFrom` (the intended word, same length) has a
    /// different letter on a neighbouring key — there the touch lands 55…80 % of the way from the
    /// intended key towards the key that was hit. Characters without a key (long-press accents,
    /// apostrophes) are exact taps, like the input controller produces.
    func taps(typed: String, slipFrom intended: String?) -> [TapInput] {
        let typedChars = Array(typed.lowercased())
        let intendedChars = intended.map { Array($0.lowercased()) }
        var result: [TapInput] = []
        for (i, ch) in typedChars.enumerated() {
            let key = String(ch)
            guard let centre = centres[key] else {
                result.append(.exact(key))
                continue
            }
            var point = centre
            if let intendedChars = intendedChars, intendedChars.count == typedChars.count,
               intendedChars[i] != ch, let from = centres[String(intendedChars[i])] {
                let seed = typedChars.reduce(i * 7) { $0 &+ Int($1.unicodeScalars.first!.value) }
                let fraction = 0.55 + Double(seed % 6) * 0.05
                let candidate = CGPoint(x: from.x + (centre.x - from.x) * CGFloat(fraction), y: from.y + (centre.y - from.y) * CGFloat(fraction))
                if tap(at: candidate).primary == key { point = candidate }
            }
            result.append(tap(at: point))
        }
        return result
    }
}
