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

    /// Minimum share of typo cases whose autocorrection is exactly the intended word.
    static let minAccuracy: [KeyboardLanguage: Double] = [.deAT: 0.85, .enGB: 0.85, .sqXK: 0.85, .itIT: 0.85]
    /// Minimum share of typo cases with the intended word in the bar (or as autocorrection).
    static let minTop3: [KeyboardLanguage: Double] = [.deAT: 0.92, .enGB: 0.92, .sqXK: 0.92, .itIT: 0.92]
    /// Accuracy floor with all four of the owner's languages enabled (layout language first).
    static let minMultilingualAccuracy = 0.80

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
                if c.category != "case", h.isKnownKey(c.typed, language) { problems.append("\(language) typo is a known word: \(c.typed)") }
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
            XCTAssertGreaterThanOrEqual(m.accuracy, Self.minMultilingualAccuracy, "\(language) multilingual accuracy after context\n\(m.failureList)")
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
            XCTAssertGreaterThanOrEqual(m.accuracy, 0.7, "\(language) on the German layout\n\(m.failureList)")
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
            _ = h.falsePositives(EngineQualityData.validationValidWords, label: "validation \(languages.map(\.rawValue))") { _ in languages }
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
            let words = h.topWords(language, count: 300)
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
            XCTAssertGreaterThanOrEqual(mono.top3Recall, 0.9, "\(language) completions\n\(mono.failureList)")
            // "nesë" → "nëse" is a fair guess on space; a prefix becoming an unrelated word ("Nachri" → "Nach") is not.
            XCTAssertLessThanOrEqual(mono.wrongAutocorrections, cases.count / 10, "prefixes autocorrected into other words\n\(mono.failureList)")
            let multi = h.evaluate(cases, label: "completion multi \(language.rawValue)") { EngineQualityData.ownerLanguages(first: $0) }
            XCTAssertGreaterThanOrEqual(multi.top3Recall, 0.8, "\(language) multilingual completions\n\(multi.failureList)")
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

extension EngineQualityTests {
    /// Diagnostic dump: KEIBORD_EVAL_DEBUG="de-AT:word1,prev word2;en-GB,de-AT:word3" prints the ranked candidates.
    func testDebugDump() throws {
        guard let spec = ProcessInfo.processInfo.environment["KEIBORD_EVAL_DEBUG"], EngineQualityHarness.available else { return }
        let h = EngineQualityHarness.shared
        let engine = h.makeEngine()
        for group in spec.split(separator: ";") {
            let parts = group.split(separator: ":", maxSplits: 1)
            let languages = parts[0].split(separator: ",").compactMap { KeyboardLanguage(rawValue: String($0)) }
            for word in parts[1].split(separator: ",") {
                let spec = word.contains(">") ? String(word) : "\(word)>\(word.split(separator: " ").last!)"
                let c = EvalCase(spec, language: languages[0], category: word.contains(">") ? "slip" : "debug")
                let q = SuggestionQuery(currentWord: c.typed, taps: h.taps(for: c, on: languages[0]), previousWords: c.previous, languages: languages)
                let r = engine.suggest(q)
                print("[debug] \(c.typed) ac=\(r.autocorrection?.text ?? "nil") bar=\(r.suggestions.map(\.display))")
                for cand in engine.rankedCandidates(q, languages: languages).prefix(6) {
                    print(String(format: "[debug]    %@ %@ score %.2f cost %.2f %@", cand.text, "\(cand.kind)", cand.score, cand.cost, cand.language?.rawValue ?? "user"))
                }
            }
        }
    }
}

extension EngineQualityTests {
    /// Grid search over the tuning knobs: KEIBORD_EVAL_SWEEP=1 (use -c release).
    func testParameterSweep() throws {
        guard ProcessInfo.processInfo.environment["KEIBORD_EVAL_SWEEP"] == "1", EngineQualityHarness.available else { return }
        let h = EngineQualityHarness.shared
        h.quiet = true
        defer { h.quiet = false; h.configure = nil }
        let marginTables: [[Double]] = [[12, 12, 12, 11, 6, 5], [12, 12, 12, 10, 6, 4], [12, 12, 12, 10, 5, 4], [12, 12, 12, 11, 6, 6]]
        for table in marginTables {
        for substitution in [9.0, 10.0, 11.0] {
        for deletion in [8.0] {
        for stop in [3.0] {
        let transposition = 5.0, insertion = 6.5, diacritic = 1.5, doubled = 3.5
            h.configure = { e in
                e.shortWordMargins = table
                e.costModel = FuzzyCostModel(substitution: substitution, insertion: insertion, deletion: deletion, transposition: transposition, diacritic: diacritic)
                e.prefixStopPenalty = stop
                e.doubledLetterCost = doubled
            }
            var mono = 0, multi = 0, total = 0, fp = 0, wrongPrefix = 0
            for language in EngineQualityData.evaluatedLanguages {
                let cases = EngineQualityData.typoCases(for: language)
                total += cases.count
                mono += h.evaluate(cases, label: "") { _ in [language] }.correct
                multi += h.evaluate(cases, label: "") { EngineQualityData.ownerLanguages(first: $0) }.correct
                wrongPrefix += h.evaluate(EngineQualityData.completionCases(for: language), label: "") { _ in [language] }.wrongAutocorrections
                let words = EngineQualityData.curatedValidWords(for: language)
                fp += h.falsePositives(words, label: "") { _ in [language] }.count
                fp += h.falsePositives(words, label: "") { _ in EngineQualityData.ownerLanguages(first: language) }.count
                fp += h.falsePositives(EngineQualityData.sharedValidWords, label: "") { _ in [language] }.count
            }
            fp += h.falsePositives(EngineQualityData.sharedValidWords, label: "") { _ in [.deAT, .enGB, .sqXK] }.count
            var validation: [String] = []
            for languages in [[KeyboardLanguage.deAT], [.enGB], [.sqXK], [.itIT], [.deAT, .enGB, .sqXK, .itIT]] {
                validation += h.falsePositives(EngineQualityData.validationValidWords, label: "") { _ in languages }
            }
            print("[sweep] validation \(validation.filter { pair in let p = pair.components(separatedBy: "→"); return TextUnits.lookupKey(p[0]) != TextUnits.lookupKey(p[1]) })")
            print("[sweep] margins=\(table) s=\(substitution) t=\(transposition) i=\(insertion) d=\(deletion) dia=\(diacritic) stop=\(stop) dbl=\(doubled) mono=\(mono)/\(total) multi=\(multi)/\(total) fp=\(fp) prefixWrong=\(wrongPrefix)")
        }}}}
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
