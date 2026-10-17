import XCTest
@testable import KeibordCore

/// In-memory `TextDocumentProxyLike` with UIKit-like semantics: positions and deletions work on
/// graphemes (`Character`s), `deleteBackward` removes the selection when there is one, and
/// `visibleLimit` emulates hosts that only expose the last few characters before the cursor.
final class MockDocument: TextDocumentProxyLike {
    /// Text before the cursor and after it (the selection is the first `selectionLength` characters of `after`).
    private var before = ""
    private var after = ""
    var selectionLength = 0
    var visibleLimit: Int?
    var contextUnavailable = false
    var deleteCount = 0

    var text: String { before + after }
    var cursor: Int {
        get { before.count }
        set {
            let all = Array(text)
            let i = min(max(0, newValue), all.count)
            before = String(all[..<i])
            after = String(all[i...])
        }
    }

    var documentContextBeforeInput: String? {
        if contextUnavailable { return nil }
        if let limit = visibleLimit { return String(before.suffix(limit)) }
        return before
    }
    var documentContextAfterInput: String? { String(after.dropFirst(selectionLength)) }
    var selectedText: String? { selectionLength > 0 ? String(after.prefix(selectionLength)) : nil }
    func insertText(_ t: String) {
        after = String(after.dropFirst(selectionLength))
        selectionLength = 0
        before += t
    }
    func deleteBackward() {
        deleteCount += 1
        if selectionLength > 0 {
            after = String(after.dropFirst(selectionLength))
            selectionLength = 0
        } else if !before.isEmpty {
            before.removeLast()
        }
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        selectionLength = 0
        cursor += offset
    }
    /// Replaces the whole document (as the host app would) and puts the cursor after `before`.
    func set(_ before: String, after: String = "") {
        self.before = before
        self.after = after
        selectionLength = 0
    }
}

/// Deterministic stand-in for the suggestion engine.
final class FakeEngine: SuggestionProviding {
    /// typed lookup key → autocorrection (capitalised when the typed word is).
    var corrections: [String: String] = ["teh": "the", "haus": "Haus"]
    /// Lookup keys containing an apostrophe that count as known words.
    var knownApostropheWords: Set<String> = ["l'", "c'", "dell'", "po'", "don't"]
    var completions: [String: [String]] = [:]
    var predictions: [String] = []
    var autofill: [String] = []
    private(set) var queries: [SuggestionQuery] = []
    private(set) var noted: [String] = []

    func suggest(_ q: SuggestionQuery) -> SuggestionResult {
        queries.append(q)
        if q.field.kind.isPersonalInfo {
            let items = autofill.filter { $0.hasPrefix(q.currentWord) && $0 != q.currentWord }
            return SuggestionResult(suggestions: items.map { Suggestion(text: $0, kind: .autofill, appendsSpace: false) })
        }
        guard q.field.kind.isProse, !q.field.isSecure else { return .empty }
        if q.currentWord.isEmpty {
            guard q.predictionsEnabled else { return .empty }
            return SuggestionResult(suggestions: predictions.map { Suggestion(text: $0, kind: .prediction) })
        }
        let key = TextUnits.lookupKey(q.currentWord)
        var list = [Suggestion(text: q.currentWord, display: "“\(q.currentWord)”", kind: .typed)]
        var ac: Suggestion?
        if q.autocorrectEnabled, q.field.autocorrectAllowed, var c = corrections[key] {
            if q.currentWord.first?.isUppercase == true { c = c.prefix(1).uppercased() + c.dropFirst() }
            let s = Suggestion(text: c, kind: .correction, isAutocorrect: true)
            ac = s
            list.append(s)
        }
        list += (completions[key] ?? []).map { Suggestion(text: $0, kind: .completion) }
        return SuggestionResult(suggestions: Array(list.prefix(3)), autocorrection: ac)
    }
    func noteCommitted(word: String, language: KeyboardLanguage?) { noted.append(word) }
    func isKnownWord(_ word: String, languages: [KeyboardLanguage]) -> Bool {
        let key = TextUnits.lookupKey(word)
        if key.contains("'") { return knownApostropheWords.contains(key) }
        return corrections[key] == nil
    }
    func likelyLanguage(of word: String, among languages: [KeyboardLanguage]) -> KeyboardLanguage? { languages.first }
}

final class Sink: LearningSink {
    var events: [LearningEvent] = []
    func record(_ event: LearningEvent) { events.append(event) }

    var commits: [(final: String, typed: String, previous: String?, taps: [TapInput]?, corrected: Bool)] {
        events.compactMap {
            if case let .committedWord(final, typed, previous, _, taps, corrected) = $0 { return (final, typed, previous, taps, corrected) }
            return nil
        }
    }
    var rejections: [LearningEvent] { events.filter { if case .rejectedCorrection = $0 { return true }; return false } }
}

final class InputControllerTests: XCTestCase {
    var doc: MockDocument!
    var engine: FakeEngine!
    var c: InputController!
    var sink: Sink!
    var now: TimeInterval = 0

    override func setUp() {
        var s = KeibordSettings()
        s.enabledLanguages = [.deAT, .enGB]
        make(s)
    }

    /// Creates a fresh controller (and document) with `settings`, optionally in `field`.
    func make(_ settings: KeibordSettings, field: FieldContext? = nil, language: KeyboardLanguage? = nil) {
        doc = MockDocument()
        engine = FakeEngine()
        now = 0
        c = InputController(document: doc, engine: engine, settings: settings, language: language, clock: { [unowned self] in self.now })
        sink = Sink()
        c.learningSink = sink
        if let field = field { c.configure(field: field) }
    }

    func settings(_ languages: [KeyboardLanguage] = [.deAT, .enGB], _ change: (inout KeibordSettings) -> Void = { _ in }) -> KeibordSettings {
        var s = KeibordSettings()
        s.enabledLanguages = languages
        change(&s)
        return s
    }

    /// Types `s` key by key: letters as (lower-case) letter keys, " " as space, "\n" as return,
    /// everything else as symbol keys. Each key press advances the clock by 0.1 s.
    func type(_ s: String) {
        for ch in s {
            switch ch {
            case " ": c.handle(.space)
            case "\n": c.handle(.returnKey)
            default:
                let str = String(ch)
                if ch.isLetter { c.handle(.character(str.lowercased(), tap: nil, isLetter: true)) }
                else { c.handle(.character(str, tap: nil, isLetter: false)) }
            }
            now += 0.1
        }
    }

    /// Puts `before` (and `after`) into the document as if the host app changed it.
    func setDocument(_ before: String, after: String = "") {
        doc.set(before, after: after)
        c.documentDidChange()
    }

    var noAutoCap: FieldContext { FieldContext(autocapitalization: .none) }

    // MARK: - Original smoke tests

    func testAutoCapAndAutocorrect() {
        XCTAssertEqual(c.shiftState, .on)
        type("ich teh ")
        XCTAssertEqual(doc.text, "Ich the ")
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "Ich teh")
        type(" ")
        XCTAssertEqual(doc.text, "Ich teh ")
        XCTAssertTrue(sink.events.contains(.rejectedCorrection(typed: "teh", correction: "the")))
    }

    func testPunctuationAutocorrectAndSentenceShift() {
        type("das haus. ")
        XCTAssertEqual(doc.text, "Das Haus. ")
        XCTAssertEqual(c.shiftState, .on)
    }

    func testDoubleSpacePeriod() {
        type("hallo  ")
        XCTAssertEqual(doc.text, "Hallo. ")
    }

    func testSmartQuotesGerman() {
        type("er sagt \"hallo\" geht's")
        XCTAssertEqual(doc.text, "Er sagt „hallo“ geht’s")
    }

    func testSuggestionAndSmartSpacing() {
        type("tes")
        c.handle(.suggestion(Suggestion(text: "Test", kind: .completion)))
        XCTAssertEqual(doc.text, "Test ")
        type(".")
        XCTAssertEqual(doc.text, "Test. ")
    }

    func testCapsLockAndWordDelete() {
        c.handle(.shiftDoubleTap)
        type("ab")
        XCTAssertEqual(doc.text, "AB")
        c.handle(.shift)
        type(" cd")
        c.handle(.backspaceRepeat(wordMode: true))
        XCTAssertEqual(doc.text, "AB ")
    }

    func testLearningEvent() {
        type("hallo welt ")
        guard case let .committedWord(final, _, previous, _, _, corrected)? = sink.events.last else { return XCTFail() }
        XCTAssertEqual(final, "welt")
        XCTAssertEqual(previous, "Hallo")
        XCTAssertFalse(corrected)
    }

    func testEmailFieldNoAutocorrect() {
        c.configure(field: FieldContext(kind: .email, autocapitalization: .none, autocorrectionAllowed: false))
        type("teh ")
        XCTAssertEqual(doc.text, "teh ")
        XCTAssertTrue(sink.events.isEmpty)
    }

    // MARK: - Shift, caps lock, auto-capitalisation

    func testOneShotShiftTurnsOffAfterOneLetter() {
        c.configure(field: noAutoCap)
        XCTAssertEqual(c.shiftState, .off)
        c.handle(.shift)
        XCTAssertEqual(c.shiftState, .on)
        type("ab")
        XCTAssertEqual(doc.text, "Ab")
        XCTAssertEqual(c.shiftState, .off)
    }

    func testShiftTapTogglesBackOff() {
        c.configure(field: noAutoCap)
        c.handle(.shift)
        c.handle(.shift)
        XCTAssertEqual(c.shiftState, .off)
        type("a")
        XCTAssertEqual(doc.text, "a")
    }

    func testManualShiftSurvivesSymbolsUntilTheNextLetter() {
        type("ich ")
        XCTAssertEqual(c.shiftState, .off)
        c.handle(.shift)
        c.handle(.switchPage(.numbers))
        type("(")
        XCTAssertEqual(c.shiftState, .on, "a manual shift must not be overridden by auto-capitalisation before a letter")
        c.handle(.switchPage(.letters))
        type("x")
        XCTAssertEqual(doc.text, "Ich (X")
        XCTAssertEqual(c.shiftState, .off)
    }

    func testManualShiftOffAtSentenceStartLastsForOneLetter() {
        XCTAssertEqual(c.shiftState, .on)
        c.handle(.shift)
        XCTAssertEqual(c.shiftState, .off)
        type("iphone. ")
        XCTAssertEqual(doc.text, "iphone. ")
        XCTAssertEqual(c.shiftState, .on, "auto-capitalisation resumes after the next letter")
    }

    func testCapsLockPersistsAcrossWordsAndSentencesUntilShift() {
        c.handle(.shiftDoubleTap)
        XCTAssertEqual(c.shiftState, .locked)
        type("abc. de")
        XCTAssertEqual(doc.text, "ABC. DE")
        XCTAssertEqual(c.shiftState, .locked)
        c.handle(.backspace)
        XCTAssertEqual(c.shiftState, .locked)
        c.handle(.shift)
        XCTAssertEqual(c.shiftState, .off)
        type("f")
        XCTAssertEqual(doc.text, "ABC. Df")
    }

    func testDoubleTapWithoutCapsLockSettingActsAsSecondTap() {
        make(settings { $0.capsLock = false }, field: noAutoCap)
        c.handle(.shift)
        c.handle(.shiftDoubleTap)
        XCTAssertEqual(c.shiftState, .off, "two quick taps without caps lock toggle shift twice")
        c.handle(.shift)
        type("ab")
        XCTAssertEqual(doc.text, "Ab")
    }

    func testEszettStaysLowerCaseWithShiftAndCapsLock() {
        c.configure(field: noAutoCap)
        c.handle(.shift)
        type("ß")
        XCTAssertEqual(doc.text, "ß")
        c.handle(.shiftDoubleTap)
        type("straße")
        XCTAssertEqual(doc.text, "ßSTRAßE")
    }

    func testSentenceAutoCapitalisation() {
        XCTAssertEqual(c.shiftState, .on, "document start")
        type("hallo")
        XCTAssertEqual(c.shiftState, .off)
        for (text, expected) in [("Hallo. ", true), ("Wirklich! ", true), ("Wie? ", true), ("Naja… ", true), ("Zeile\n", true),
                                 ("Hallo, ", false), ("Hallo.", false), ("z.B", false), ("Hallo ", false),
                                 ("Er sagte „Ja.“ ", true), ("Ja. „", true), ("„", true), ("(", true), ("Ja. (", true),
                                 ("Er sagt „", false), ("   ", true), ("Ja.\n\n", true),
                                 ("Das ist z.B. ", false), ("Siehe z. B. ", false), ("Grüße an Dr. ", false), ("Er heißt A. ", false),
                                 ("Wir kommen um 5. ", true), ("Naja... ", true), ("Gut. ", true), ("i.e. ", false), ("(Hallo.) ", true)] {
            setDocument(text)
            XCTAssertEqual(c.shiftState == .on, expected, "after \(text.debugDescription)")
        }
    }

    func testAbbreviationDoesNotStartASentence() {
        type("das ist z.b. gut. ja")
        XCTAssertEqual(doc.text, "Das ist z.b. gut. Ja")
    }

    func testSentenceStartAfterOpeningQuoteCapitalisesTheWord() {
        type("ja. \"nein")
        XCTAssertEqual(doc.text, "Ja. „Nein")
    }

    func testWordsAutoCapitalisation() {
        c.configure(field: FieldContext(kind: .fullName, autocapitalization: .words))
        type("anna maria\nmüller")
        XCTAssertEqual(doc.text, "Anna Maria\nMüller")
    }

    func testAllCharactersAutoCapitalisation() {
        c.configure(field: FieldContext(autocapitalization: .allCharacters))
        type("ab cd")
        XCTAssertEqual(doc.text, "AB CD")
        XCTAssertEqual(c.shiftState, .on)
    }

    func testNoAutoCapitalisationWhenModeNoneOrSettingOff() {
        c.configure(field: noAutoCap)
        type("hallo. welt")
        XCTAssertEqual(doc.text, "hallo. welt")
        make(settings { $0.autoCapitalization = false })
        XCTAssertEqual(c.shiftState, .off)
        type("hallo. welt")
        XCTAssertEqual(doc.text, "hallo. welt")
    }

    func testSecureFieldDoesNotAutoCapitalise() {
        c.configure(field: FieldContext(autocapitalization: .sentences, isSecure: true))
        XCTAssertEqual(c.shiftState, .off)
        type("geheim")
        XCTAssertEqual(doc.text, "geheim")
    }

    // MARK: - Autocorrect

    func testAutocorrectOnSpace() {
        c.configure(field: noAutoCap)
        type("teh ")
        XCTAssertEqual(doc.text, "the ")
    }

    func testAutocorrectOnEveryCommittingPunctuation() {
        for p in [".", ",", "!", "?", ":", ";", ")", "]", "}", "…"] {
            make(settings(), field: noAutoCap)
            type("teh" + p)
            XCTAssertEqual(doc.text, "the" + p, "punctuation \(p)")
            XCTAssertEqual(sink.commits.last?.corrected, true, "punctuation \(p)")
        }
    }

    func testAutocorrectBeforeClosingQuote() {
        c.configure(field: noAutoCap)
        type("\"teh\"")
        XCTAssertEqual(doc.text, "„the“")
    }

    func testNoAutocorrectOnNonCommittingSymbols() {
        for p in ["-", "/", "(", "@", "&"] {
            make(settings(), field: noAutoCap)
            type("teh" + p)
            XCTAssertEqual(doc.text, "teh" + p, "symbol \(p)")
        }
    }

    func testAutocorrectOnReturn() {
        c.configure(field: noAutoCap)
        type("teh\n")
        XCTAssertEqual(doc.text, "the\n")
    }

    func testAutocorrectPreservesCapitalisation() {
        type("teh ")
        XCTAssertEqual(doc.text, "The ")
    }

    func testNoAutocorrectWhenDisabled() {
        make(settings { $0.autocorrect = false }, field: noAutoCap)
        type("teh. teh ")
        XCTAssertEqual(doc.text, "teh. teh ")
        XCTAssertNil(c.autocorrection)
        make(settings(), field: FieldContext(autocapitalization: .none, autocorrectionAllowed: false))
        type("teh ")
        XCTAssertEqual(doc.text, "teh ")
    }

    func testNoAutocorrectWhenTheCursorIsInsideAWord() {
        c.configure(field: noAutoCap)
        setDocument("teh", after: "x")
        type(" ")
        XCTAssertEqual(doc.text, "teh x", "splitting a word must not autocorrect its first half")
        XCTAssertNil(c.autocorrection)
    }

    func testAutocorrectionUsesTheLanguagesApostrophe() {
        make(settings([.enGB]), field: noAutoCap)
        engine.corrections["dont"] = "don't"
        type("dont ")
        XCTAssertEqual(doc.text, "don’t ", "inserted corrections follow smart quotes like typed apostrophes")
        make(settings([.enGB]) { $0.smartQuotes = false }, field: noAutoCap)
        engine.corrections["dont"] = "don't"
        type("dont ")
        XCTAssertEqual(doc.text, "don't ")
    }

    func testPredictiveTextOffStillAutocorrects() {
        make(settings { $0.predictiveText = false }, field: noAutoCap)
        type("teh")
        XCTAssertTrue(c.suggestions.isEmpty)
        XCTAssertEqual(c.autocorrection?.text, "the")
        type(" ")
        XCTAssertEqual(doc.text, "the ")
    }

    // MARK: - Undo of an autocorrection

    func testBackspaceUndoesCorrectionAfterSpaceAndDoesNotRecorrect() {
        c.configure(field: noAutoCap)
        type("teh ")
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh")
        XCTAssertNil(c.autocorrection, "the rejected correction is not offered again")
        XCTAssertFalse(c.suggestions.contains { $0.isAutocorrect })
        XCTAssertEqual(sink.rejections, [.rejectedCorrection(typed: "teh", correction: "the")])
        type(" ")
        XCTAssertEqual(doc.text, "teh ")
        XCTAssertEqual(sink.commits.last?.final, "teh")
        XCTAssertEqual(sink.commits.last?.corrected, false)
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh", "a second backspace deletes normally")
    }

    func testBackspaceUndoesCorrectionAfterPunctuation() {
        c.configure(field: noAutoCap)
        type("teh.")
        XCTAssertEqual(doc.text, "the.")
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh")
        XCTAssertEqual(sink.rejections.count, 1)
        type(".")
        XCTAssertEqual(doc.text, "teh.")
    }

    func testBackspaceUndoesCorrectionAfterReturn() {
        c.configure(field: noAutoCap)
        type("teh\n")
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh")
    }

    func testUndoIsNotOfferedAfterOtherInput() {
        c.configure(field: noAutoCap)
        type("teh x")
        c.handle(.backspace)
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "the", "typing something else drops the undo")
        XCTAssertTrue(sink.rejections.isEmpty)

        make(settings(), field: noAutoCap)
        type("teh ")
        c.handle(.insertText("👍", commitsWord: true))
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "the ")

        make(settings(), field: noAutoCap)
        type("teh ")
        c.handle(.moveCursor(-1))
        c.handle(.moveCursor(1))
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "the")

        make(settings { $0.doubleSpacePeriod = false }, field: noAutoCap)
        type("teh  ")
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "the ")
        XCTAssertTrue(sink.rejections.isEmpty)
    }

    func testUndoSurvivesShiftAndPageSwitches() {
        c.configure(field: noAutoCap)
        type("teh ")
        c.handle(.shift)
        c.handle(.switchPage(.numbers))
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh")
    }

    func testUndoRestoresTapsOfTheOriginalWord() {
        c.configure(field: noAutoCap)
        let t = TapInput(candidates: [TapCandidate(character: "t", cost: 0), TapCandidate(character: "r", cost: 3)])
        c.handle(.character("t", tap: t, isLetter: true))
        type("eh ")
        c.handle(.backspace)
        c.refreshSuggestions()
        XCTAssertEqual(engine.queries.last?.taps?.first, t)
        XCTAssertEqual(engine.queries.last?.taps?.count, 3)
    }

    // MARK: - Suggestion taps

    func testCorrectionTapReplacesWordAndRecordsTaps() {
        c.configure(field: noAutoCap)
        type("das tset")
        c.handle(.suggestion(Suggestion(text: "test", kind: .correction)))
        XCTAssertEqual(doc.text, "das test ")
        let commit = sink.commits.last
        XCTAssertEqual(commit?.final, "test")
        XCTAssertEqual(commit?.typed, "tset")
        XCTAssertEqual(commit?.previous, "das")
        XCTAssertEqual(commit?.taps?.map(\.primary), ["t", "s", "e", "t"])
        XCTAssertEqual(commit?.corrected, false)
    }

    func testCompletionTapDoesNotRecordTaps() {
        type("tes")
        c.handle(.suggestion(Suggestion(text: "Testament", kind: .completion)))
        XCTAssertEqual(doc.text, "Testament ")
        XCTAssertNil(sink.commits.last?.taps)
        XCTAssertEqual(sink.commits.last?.typed, "Tes")
    }

    func testTypedLiteralTapRejectsPendingCorrection() {
        c.configure(field: noAutoCap)
        type("teh")
        XCTAssertEqual(c.autocorrection?.text, "the")
        c.handle(.suggestion(Suggestion(text: "teh", display: "“teh”", kind: .typed)))
        XCTAssertEqual(doc.text, "teh ")
        XCTAssertEqual(sink.rejections, [.rejectedCorrection(typed: "teh", correction: "the")])
        XCTAssertEqual(sink.commits.last?.final, "teh")
        type(".")
        XCTAssertEqual(doc.text, "teh. ", "the literal's space is an automatic space")
    }

    func testPredictionInsertsAtCursorWithAndWithoutLeadingSpace() {
        type("hallo ")
        c.handle(.suggestion(Suggestion(text: "Welt", kind: .prediction)))
        XCTAssertEqual(doc.text, "Hallo Welt ")
        XCTAssertEqual(sink.commits.last?.previous, "Hallo")

        for (before, expected) in [("Hallo.", "Hallo. Wie "), ("Ja,", "Ja, Wie "), ("(", "(Wie "), ("„", "„Wie "),
                                   ("👍", "👍 Wie "), ("", "Wie "), ("Ja\n", "Ja\nWie "), ("„Ja“", "„Ja“ Wie ")] {
            make(settings())
            setDocument(before)
            c.handle(.suggestion(Suggestion(text: "Wie", kind: .prediction)))
            XCTAssertEqual(doc.text, expected, "prediction after \(before.debugDescription)")
        }
    }

    func testAutofillWithoutSpace() {
        c.configure(field: FieldContext(kind: .email, keyboardVariant: .email, autocapitalization: .none, autocorrectionAllowed: false))
        engine.autofill = ["max@example.com"]
        type("max")
        XCTAssertEqual(c.suggestions.map(\.text), ["max@example.com"])
        c.handle(.suggestion(c.suggestions[0]))
        XCTAssertEqual(doc.text, "max@example.com")
        type(".")
        XCTAssertEqual(doc.text, "max@example.com.", "no automatic space was inserted, so nothing is swallowed")
        XCTAssertTrue(sink.events.isEmpty, "autofill values are never learned")
    }

    func testAutofillShownWithPredictiveTextOff() {
        make(settings { $0.predictiveText = false }, field: FieldContext(kind: .email, autocapitalization: .none))
        engine.autofill = ["max@example.com"]
        type("m")
        XCTAssertEqual(c.suggestions.map(\.text), ["max@example.com"])
    }

    func testShortcutTap() {
        c.configure(field: noAutoCap)
        type("mfg")
        c.handle(.suggestion(Suggestion(text: "Mit freundlichen Grüßen", kind: .shortcut)))
        XCTAssertEqual(doc.text, "Mit freundlichen Grüßen ")
    }

    func testSuggestionDoesNotDoubleTheSpaceBeforeFollowingText() {
        c.configure(field: noAutoCap)
        setDocument("ich bi", after: " heute")
        c.handle(.suggestion(Suggestion(text: "bin", kind: .correction)))
        XCTAssertEqual(doc.text, "ich bin heute")
        XCTAssertEqual(doc.cursor, 8, "the cursor moves over the existing space")
        type(".")
        XCTAssertEqual(doc.text, "ich bin. heute", "the existing space acts as the automatic space")
        setDocument("ich bi", after: ".")
        c.handle(.suggestion(Suggestion(text: "bin", kind: .correction)))
        XCTAssertEqual(doc.text, "ich bin.")
    }

    func testCardAndActionSuggestionsAreIgnored() {
        type("ab")
        c.handle(.suggestion(Suggestion(text: "•••• 1234", kind: .card, payload: "x")))
        c.handle(.suggestion(Suggestion(text: "Switch", kind: .action, payload: "switch-keyboard")))
        XCTAssertEqual(doc.text, "Ab")
    }

    // MARK: - Smart punctuation spacing

    func testSmartSpacingMovesAutomaticSpaceAfterPunctuation() {
        for p in [".", ",", "!", "?", ":", ";", ")", "…"] {
            make(settings(), field: noAutoCap)
            type("tes")
            c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
            type(p)
            XCTAssertEqual(doc.text, "test\(p) ", "punctuation \(p)")
        }
    }

    func testSmartSpacingStaysActiveForFollowingPunctuation() {
        c.configure(field: noAutoCap)
        type("ja")
        c.handle(.suggestion(Suggestion(text: "ja", kind: .typed)))
        type("?!")
        XCTAssertEqual(doc.text, "ja?! ")
        type("x")
        XCTAssertEqual(doc.text, "ja?! x")
    }

    func testNoSmartSpacingAfterManualSpaceOrWhenDisabled() {
        c.configure(field: noAutoCap)
        type("test .")
        XCTAssertEqual(doc.text, "test .")
        make(settings { $0.smartPunctuationSpacing = false }, field: noAutoCap)
        type("tes")
        c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
        type(".")
        XCTAssertEqual(doc.text, "test .")
    }

    func testOpeningPunctuationDoesNotSwallowAutomaticSpace() {
        c.configure(field: noAutoCap)
        type("tes")
        c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
        type("(")
        XCTAssertEqual(doc.text, "test (")
    }

    // MARK: - Double-space period

    func testDoubleSpacePeriodTiming() {
        c.configure(field: noAutoCap)
        type("hallo ")
        now += 2.5
        type(" ")
        XCTAssertEqual(doc.text, "hallo  ", "too slow for a double-space period")
        make(settings(), field: noAutoCap)
        type("hallo ")
        now += 1.5
        type(" ")
        XCTAssertEqual(doc.text, "hallo. ")
    }

    func testDoubleSpacePeriodOnlyAfterWordCharacters() {
        for text in ["hallo!", "hallo,", "👍", "(hallo)"] {
            make(settings(), field: noAutoCap)
            type(text + "  ")
            XCTAssertEqual(doc.text, text + "  ", "after \(text)")
        }
        make(settings(), field: noAutoCap)
        type("2024  ")
        XCTAssertEqual(doc.text, "2024. ")
    }

    func testThirdSpaceAfterDoubleSpacePeriodIsPlain() {
        c.configure(field: noAutoCap)
        type("hallo   ")
        XCTAssertEqual(doc.text, "hallo.  ")
    }

    func testNoDoubleSpacePeriodAfterSuggestionSpace() {
        c.configure(field: noAutoCap)
        type("tes")
        c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
        type(" ")
        XCTAssertEqual(doc.text, "test  ")
    }

    func testDoubleSpacePeriodNeedsTwoConsecutiveSpaceEvents() {
        c.configure(field: noAutoCap)
        setDocument("hallo ")
        type(" ")
        XCTAssertEqual(doc.text, "hallo  ", "the first space was not typed by the previous event")
    }

    func testNoDoubleSpacePeriodWhenDisabledOrInNonProseFields() {
        make(settings { $0.doubleSpacePeriod = false }, field: noAutoCap)
        type("hallo  ")
        XCTAssertEqual(doc.text, "hallo  ")
        make(settings(), field: FieldContext(kind: .email, autocapitalization: .none))
        type("max  ")
        XCTAssertEqual(doc.text, "max  ")
        make(settings(), field: FieldContext(autocapitalization: .none, isSecure: true))
        type("ab  ")
        XCTAssertEqual(doc.text, "ab  ", "passwords must stay exactly as typed")
    }

    func testDoubleSpacePeriodReturnsToLetters() {
        c.configure(field: noAutoCap)
        type("hallo ")
        c.handle(.switchPage(.numbers))
        type(" ")
        XCTAssertEqual(doc.text, "hallo. ")
        XCTAssertEqual(c.page, .letters)
    }

    // MARK: - Smart quotes

    func testSmartQuotesPerLanguage() {
        let cases: [(KeyboardLanguage, String, String)] = [
            (.deAT, "er sagt \"hallo\" und 'tschüss' – geht's?", "er sagt „hallo“ und ‚tschüss‘ – geht’s?"),
            (.enGB, "she said \"hi\" and 'bye', don't", "she said “hi” and ‘bye’, don’t"),
            (.enUS, "\"it's\" fine", "“it’s” fine"),
            (.itIT, "l'amico disse \"ciao\" all'una", "l’amico disse “ciao” all’una"),
            (.sqXK, "ai tha \"po\" s'ka", "ai tha „po“ s’ka"),
            (.sqAL, "'mirë'", "‚mirë‘"),
        ]
        for (language, typed, expected) in cases {
            make(settings([language]), field: noAutoCap)
            type(typed)
            XCTAssertEqual(doc.text, expected, "\(language)")
        }
    }

    func testQuotesOpenAfterBracketsAndCloseAfterPunctuation() {
        c.configure(field: noAutoCap)
        type("(\"ja\") -\"nein!\" ['so']")
        XCTAssertEqual(doc.text, "(„ja“) -„nein!“ [‚so‘]")
    }

    func testNestedGermanQuotesCloseCorrectly() {
        c.configure(field: noAutoCap)
        type("\"er sagte 'hallo'\"")
        XCTAssertEqual(doc.text, "„er sagte ‚hallo‘“")
    }

    func testApostropheInsideGermanSingleQuotation() {
        c.configure(field: noAutoCap)
        type("'er geht's heim'")
        XCTAssertEqual(doc.text, "‚er geht’s heim‘")
    }

    func testClosingQuoteReplacesAutomaticSpace() {
        c.configure(field: noAutoCap)
        type("\"tes")
        c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
        type("\"")
        XCTAssertEqual(doc.text, "„test“ ")
        type("x")
        XCTAssertEqual(doc.text, "„test“ x")

        make(settings([.enGB]), field: noAutoCap)
        type("'tes")
        c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
        type("'")
        XCTAssertEqual(doc.text, "‘test’ ")
    }

    func testQuoteAfterAutomaticSpaceOpensWhenNothingIsOpen() {
        c.configure(field: noAutoCap)
        type("tes")
        c.handle(.suggestion(Suggestion(text: "test", kind: .completion)))
        type("\"")
        XCTAssertEqual(doc.text, "test „")
    }

    func testQuoteStyleOverride() {
        make(settings([.itIT]) { $0.quoteStyleOverrides = ["it-IT": .guillemets] }, field: noAutoCap)
        type("\"ciao\"")
        XCTAssertEqual(doc.text, "«ciao»")
    }

    func testNoSmartQuotesWhereNotWanted() {
        make(settings { $0.smartQuotes = false }, field: noAutoCap)
        type("\"a\" b's")
        XCTAssertEqual(doc.text, "\"a\" b's")
        make(settings(), field: FieldContext(autocapitalization: .none, smartQuotesAllowed: false))
        type("\"a\"")
        XCTAssertEqual(doc.text, "\"a\"")
        make(settings(), field: FieldContext(kind: .email, autocapitalization: .none))
        type("\"a\"")
        XCTAssertEqual(doc.text, "\"a\"")
        make(settings(), field: FieldContext(kind: .url, keyboardVariant: .url, autocapitalization: .none))
        type("a'b")
        XCTAssertEqual(doc.text, "a'b")
        make(settings(), field: FieldContext(autocapitalization: .none, isSecure: true))
        type("p\"w'd")
        XCTAssertEqual(doc.text, "p\"w'd", "a password must not be altered by smart quotes")
    }

    func testClosingQuoteAfterWordIsNotAutocorrectedAway() {
        // The real engine "corrects" an unknown "hello’" to "hello", which would delete the quote.
        make(settings([.enGB]), field: noAutoCap)
        engine.corrections["hello'"] = "hello"
        engine.corrections["teh'"] = "the"
        type("'hello' ")
        XCTAssertEqual(doc.text, "‘hello’ ")
        XCTAssertEqual(sink.commits.last?.final, "hello")
        type("'teh' ")
        XCTAssertEqual(doc.text, "‘hello’ ‘the’ ", "the word inside the quotes is still corrected")
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "‘hello’ ‘teh’")
        XCTAssertEqual(sink.rejections.last, .rejectedCorrection(typed: "teh", correction: "the"))
    }

    func testKnownWordEndingInApostropheIsKept() {
        make(settings([.itIT]), field: noAutoCap)
        type("un po' ")
        XCTAssertEqual(doc.text, "un po’ ")
        XCTAssertEqual(sink.commits.last?.final, "po’")
    }

    // MARK: - Elisions and contractions

    func testItalianElisionIsAWordOfItsOwn() {
        make(settings([.itIT]), field: noAutoCap)
        engine.corrections["c'è"] = "c'"
        engine.corrections["amcio"] = "amico"
        type("l'am")
        XCTAssertEqual(c.currentWord, "am")
        XCTAssertEqual(engine.queries.last?.currentWord, "am")
        XCTAssertEqual(engine.queries.last?.previousWords.last, "l’")
        type("cio c'è ")
        XCTAssertEqual(doc.text, "l’amico c’è ", "only the part after the article is corrected; c’è is kept")
        XCTAssertEqual(sink.commits.map(\.final), ["amico", "è"])
        XCTAssertEqual(sink.commits.first?.typed, "amcio")
        XCTAssertEqual(sink.commits.first?.previous, "l’")
        XCTAssertEqual(sink.commits.last?.previous, "c’")
    }

    func testElidedPreviousWordIsSplit() {
        make(settings([.itIT]), field: noAutoCap)
        type("dell'anno scor")
        XCTAssertEqual(engine.queries.last?.previousWords, ["dell’", "anno"])
    }

    func testContractionWithKnownStemIsNotCorrected() {
        engine.corrections["wie's"] = "wie"
        c.configure(field: noAutoCap)
        type("wie's ")
        XCTAssertEqual(doc.text, "wie’s ")
    }

    // MARK: - Pages

    func testNumbersPageReturnsToLettersAfterSpaceAndApostrophe() {
        c.configure(field: noAutoCap)
        c.handle(.switchPage(.numbers))
        type("12.5")
        XCTAssertEqual(c.page, .numbers, "digits and punctuation stay on the numbers page")
        type(" ")
        XCTAssertEqual(c.page, .letters)
        c.handle(.switchPage(.symbols))
        XCTAssertEqual(c.page, .symbols)
        type("#")
        XCTAssertEqual(c.page, .symbols)
        type("'")
        XCTAssertEqual(c.page, .letters)
    }

    func testFieldChangeResetsPage() {
        c.handle(.switchPage(.numbers))
        c.configure(field: FieldContext(kind: .webSearch, keyboardVariant: .webSearch))
        XCTAssertEqual(c.page, .letters)
    }

    // MARK: - Backspace

    func testBackspaceDeletesOneGrapheme() {
        for text in ["ab👍🏽", "ab🇦🇹", "abe\u{308}", "ab👨‍👩‍👧", "ab1️⃣"] {
            make(settings(), field: noAutoCap)
            setDocument(text)
            c.handle(.backspace)
            XCTAssertEqual(doc.text, "ab", "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
            XCTAssertEqual(doc.deleteCount, 1)
        }
    }

    func testBackspaceDeletesSelection() {
        setDocument("hallo welt")
        doc.cursor = 6
        doc.selectionLength = 4
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "hallo ")
    }

    func testWordModeBackspace() {
        let cases: [(String, String)] = [
            ("Hallo Welt", "Hallo "),
            ("Hallo Welt  ", "Hallo "),
            ("Ich sage Hallo, ", "Ich sage "),
            ("Wow!!! ", ""),
            ("Er geht’s", "Er "),
            ("Hallo\n\n", ""),
            ("Hallo 👍🏽👍", "Hallo 👍🏽"),
            ("Hallo 👍🏽", "Hallo "),
            ("Hallo, 👍 ", "Hallo, "),
            ("(Test)", "("),
            ("e-mail", "e-"),
            ("über", ""),
            ("", ""),
        ]
        for (before, expected) in cases {
            make(settings(), field: noAutoCap)
            setDocument(before)
            c.handle(.backspaceRepeat(wordMode: true))
            XCTAssertEqual(doc.text, expected, "word delete in \(before.debugDescription)")
        }
    }

    func testWordModeBackspaceWithoutContextDeletesOneCharacter() {
        setDocument("hallo")
        doc.contextUnavailable = true
        c.handle(.backspaceRepeat(wordMode: true))
        XCTAssertEqual(doc.text, "hall")
    }

    func testRepeatedCharacterBackspace() {
        setDocument("hallo")
        c.handle(.backspaceRepeat(wordMode: false))
        c.handle(.backspaceRepeat(wordMode: false))
        XCTAssertEqual(doc.text, "hal")
    }

    func testBackspaceKeepsTapsAligned() {
        c.configure(field: noAutoCap)
        let t = TapInput(candidates: [TapCandidate(character: "a", cost: 0), TapCandidate(character: "s", cost: 2)])
        c.handle(.character("a", tap: t, isLetter: true))
        type("bc")
        c.handle(.backspace)
        XCTAssertEqual(engine.queries.last?.taps?.map(\.primary), ["a", "b"])
        XCTAssertEqual(engine.queries.last?.taps?.first, t)
    }

    // MARK: - Graphemes and emoji

    func testEmojiAndKeycapsAreNotPartOfWords() {
        c.configure(field: noAutoCap)
        c.handle(.insertText("👍🏽", commitsWord: true))
        type("ok")
        XCTAssertEqual(c.currentWord, "ok")
        setDocument("1️⃣ok")
        XCTAssertEqual(c.currentWord, "ok")
        XCTAssertFalse(TextUnits.isWordCharacter("1️⃣"))
        XCTAssertFalse(TextUnits.isWordCharacter("🇦🇹"))
        XCTAssertTrue(TextUnits.isWordCharacter("e\u{308}"))
        XCTAssertTrue(TextUnits.isWordCharacter("ë"))
        XCTAssertTrue(TextUnits.isWordCharacter("7"))
    }

    func testCorrectionOfDecomposedWordDeletesWholeGraphemes() {
        c.configure(field: noAutoCap)
        engine.corrections["scho\u{308}nn"] = "schön"
        setDocument("so scho\u{308}nn")
        XCTAssertEqual(c.currentWord, "scho\u{308}nn")
        type(" ")
        XCTAssertEqual(doc.text, "so schön ")
    }

    func testEmojiInsertCommitsWordWithoutCorrection() {
        c.configure(field: noAutoCap)
        type("teh")
        c.handle(.insertText("😀", commitsWord: true))
        XCTAssertEqual(doc.text, "teh😀")
        XCTAssertEqual(sink.commits.last?.final, "teh")
        XCTAssertEqual(sink.commits.last?.corrected, false)
    }

    func testTrailingWordAndWords() {
        let cases: [(String, String)] = [
            ("", ""), ("hallo", "hallo"), ("hallo ", ""), ("ein Haus", "Haus"), ("don'", "don'"), ("don't", "don't"),
            ("geht’s", "geht’s"), ("'hallo", "hallo"), ("x ''", ""), ("e-mail", "mail"), ("mp3", "mp3"), ("👍ok", "ok"),
            ("scho\u{308}n", "scho\u{308}n"), ("a.b", "b"), ("Ünd", "Ünd"), ("1️⃣", ""),
        ]
        for (context, expected) in cases {
            XCTAssertEqual(TextUnits.trailingWord(in: context), expected, context.debugDescription)
        }
        XCTAssertEqual(TextUnits.words(in: "Er geht’s an, l'amico 'x' don't."), ["Er", "geht’s", "an", "l'amico", "x", "don't"])
        XCTAssertEqual(TextUnits.lookupKey("Geht’s"), "geht's")
        XCTAssertEqual(TextUnits.lookupKey("SCHO\u{308}N"), "schön")
    }

    func testTypingInALongDocumentStaysFast() {
        setDocument(String(repeating: "Ein ziemlich langer Absatz mit vielen Wörtern. ", count: 200))
        let start = Date()
        type(String(repeating: "noch ein satz mit worten. ", count: 8))
        let perKey = Date().timeIntervalSince(start) / Double(26 * 8)
        XCTAssertLessThan(perKey, 0.005, "controller overhead per key press")
    }

    // MARK: - Cursor movement and external changes

    func testMoveCursorClearsComposingState() {
        c.configure(field: noAutoCap)
        let t = TapInput(candidates: [TapCandidate(character: "a", cost: 0)])
        c.handle(.character("a", tap: t, isLetter: true))
        c.handle(.character("b", tap: t, isLetter: true))
        c.handle(.moveCursor(-1))
        XCTAssertEqual(doc.cursor, 1)
        XCTAssertNil(engine.queries.last?.taps)
        c.handle(.moveCursor(5))
        XCTAssertEqual(doc.cursor, 2)
    }

    func testExternalChangeResetsStateAndRecomputesShift() {
        type("hallo")
        c.handle(.suggestion(Suggestion(text: "Hallo", kind: .typed)))
        setDocument("")
        XCTAssertEqual(c.shiftState, .on)
        setDocument("Neu ")
        type(".")
        XCTAssertEqual(doc.text, "Neu .", "the automatic space belonged to the old text")
    }

    func testOwnChangesReportedByTheHostKeepState() {
        c.configure(field: noAutoCap)
        type("teh ")
        c.documentDidChange()
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh")
    }

    func testConfigureWithChangedTextResetsStaleUndo() {
        c.configure(field: noAutoCap)
        type("teh ")
        doc.set("the ")  // another text field with the same traits, same text by chance
        c.configure(field: noAutoCap)
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "teh", "nothing changed: undo still valid")
        make(settings(), field: noAutoCap)
        type("teh ")
        doc.set("x the ")
        c.configure(field: noAutoCap)
        c.handle(.backspace)
        XCTAssertEqual(doc.text, "x the", "text changed while away: no undo")
    }

    // MARK: - Truncated context

    func testTruncatedContextStillWorks() {
        doc.visibleLimit = 50
        let long = String(repeating: "lorem ipsum ", count: 10)
        setDocument(long)
        XCTAssertEqual(doc.documentContextBeforeInput?.count, 50)
        type("teh ")
        XCTAssertTrue(doc.text.hasSuffix("ipsum the "))
        c.handle(.backspace)
        XCTAssertTrue(doc.text.hasSuffix("ipsum teh"))
        type(". ")
        XCTAssertEqual(c.shiftState, .on)
        type("x ")
        XCTAssertNil(sink.commits.last?.previous, "a new sentence has no previous word")
        c.handle(.backspaceRepeat(wordMode: true))
        XCTAssertTrue(doc.text.hasSuffix("teh. "))
        XCTAssertEqual(doc.text.count, long.count + 5)
    }

    // MARK: - Secure, e-mail and URL fields

    func testSecureFieldNeverReachesEngineOrLearning() {
        c.configure(field: FieldContext(autocapitalization: .sentences, isSecure: true))
        let queriesBefore = engine.queries.count
        type("teh geheim. ")
        XCTAssertEqual(doc.text, "teh geheim. ")
        XCTAssertEqual(engine.queries.count, queriesBefore, "no query may contain password characters")
        XCTAssertTrue(engine.noted.isEmpty)
        XCTAssertTrue(c.suggestions.isEmpty)
        XCTAssertNil(c.autocorrection)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testEmailAndURLFields() {
        for kind in [FieldKind.email, .url] {
            make(settings(), field: FieldContext(kind: kind, keyboardVariant: kind == .email ? .email : .url, autocapitalization: .none))
            type("teh.\"x\"'y ")
            XCTAssertEqual(doc.text, "teh.\"x\"'y ", "\(kind)")
            XCTAssertTrue(sink.events.isEmpty, "\(kind): no learning")
            XCTAssertTrue(engine.noted.isEmpty, "\(kind): no language detection")
        }
    }

    // MARK: - Learning events

    func testCommittedWordEventContents() {
        c.configure(field: noAutoCap)
        let taps = ["t", "e", "h"].map { TapInput(candidates: [TapCandidate(character: $0, cost: 0), TapCandidate(character: "x", cost: 4)]) }
        type("das ")
        for (ch, t) in zip(["t", "e", "h"], taps) { c.handle(.character(ch, tap: t, isLetter: true)) }
        type(" ")
        let commit = sink.commits.last
        XCTAssertEqual(commit?.final, "the")
        XCTAssertEqual(commit?.typed, "teh")
        XCTAssertEqual(commit?.previous, "das")
        XCTAssertEqual(commit?.taps, taps)
        XCTAssertEqual(commit?.corrected, true)
        XCTAssertEqual(engine.noted.last, "the")
    }

    func testPreviousWordStaysInsideTheSentence() {
        type("hallo. welt ")
        XCTAssertNil(sink.commits.last?.previous)
        type("ja\nnein ")
        XCTAssertNil(sink.commits.last?.previous)
        type("ich, du ")
        XCTAssertEqual(sink.commits.last?.previous, "ich")
    }

    func testPredictionQueryAtSentenceStart() {
        type("hallo. ")
        let q = engine.queries.last
        XCTAssertEqual(q?.currentWord, "")
        XCTAssertEqual(q?.isSentenceStart, true)
        XCTAssertEqual(q?.previousWords, [])
        type("wie geht ")
        XCTAssertEqual(engine.queries.last?.previousWords, ["Wie", "geht"])
        XCTAssertEqual(engine.queries.last?.isSentenceStart, false)
    }

    func testWordInternalApostropheKeepsTapsAligned() {
        c.configure(field: noAutoCap)
        type("geht's")
        XCTAssertEqual(engine.queries.last?.currentWord, "geht’s")
        XCTAssertEqual(engine.queries.last?.taps?.map(\.primary), ["g", "e", "h", "t", "'", "s"])
    }

    func testNoLearningInIncognitoOrWithLearningOff() {
        for change in [{ (s: inout KeibordSettings) in s.incognito = true }, { (s: inout KeibordSettings) in s.learnWords = false }] {
            make(settings([.deAT, .enGB], change), field: noAutoCap)
            type("teh ")
            c.handle(.backspace)
            type(" ab")
            c.handle(.suggestion(Suggestion(text: "abc", kind: .completion)))
            c.setLanguage(.enGB)
            XCTAssertEqual(sink.events, [.switchedLanguage(.enGB)], "only the language switch is reported")
        }
    }

    // MARK: - Languages

    func testLanguageListOrderAndSwitching() {
        make(settings([.deAT, .enGB, .itIT]))
        XCTAssertEqual(c.languages, [.deAT, .enGB, .itIT])
        c.setLanguage(.itIT)
        XCTAssertEqual(c.languages, [.itIT, .deAT, .enGB])
        XCTAssertEqual(engine.queries.last?.languages, [.itIT, .deAT, .enGB])
        XCTAssertEqual(sink.events.last, .switchedLanguage(.itIT))
        c.setLanguage(.itIT)
        XCTAssertEqual(sink.events.count, 1, "no event without a change")
        c.nextLanguage()
        XCTAssertEqual(c.language, .deAT)
        c.nextLanguage()
        XCTAssertEqual(c.language, .enGB)

        var s = c.settings
        s.multilingualTyping = false
        c.settings = s
        XCTAssertEqual(c.languages, [.enGB])

        s.enabledLanguages = [.sqXK, .deAT]
        c.settings = s
        XCTAssertEqual(c.language, .sqXK, "a disabled current language falls back to the first one")
        XCTAssertEqual(sink.events.last, .switchedLanguage(.sqXK))
    }

    func testInitialLanguageMustBeEnabled() {
        make(settings([.deAT, .enGB]), language: .itIT)
        XCTAssertEqual(c.language, .deAT)
        make(settings([.deAT, .enGB]), language: .enGB)
        XCTAssertEqual(c.language, .enGB)
    }

    func testSmartQuotesFollowTheCurrentLanguage() {
        make(settings([.deAT, .enGB]), field: noAutoCap)
        type("\"a\" ")
        c.setLanguage(.enGB)
        type("\"b\"")
        XCTAssertEqual(doc.text, "„a“ “b”")
    }
}
