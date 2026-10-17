import XCTest
@testable import KeibordCore

// Diagnostics for tuning the suggestion engine. They use engine internals and do nothing unless their
// environment variable is set.

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
