import XCTest
@testable import KeibordCore

final class MockDocument: TextDocumentProxyLike {
    var text = ""
    var cursor = 0
    var documentContextBeforeInput: String? { String(Array(text)[0..<cursor]) }
    var documentContextAfterInput: String? { String(Array(text)[cursor...]) }
    var selectedText: String? { nil }
    func insertText(_ t: String) {
        var chars = Array(text)
        chars.insert(contentsOf: Array(t), at: cursor)
        text = String(chars)
        cursor += t.count
    }
    func deleteBackward() {
        guard cursor > 0 else { return }
        var chars = Array(text)
        chars.remove(at: cursor - 1)
        text = String(chars)
        cursor -= 1
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        cursor = min(max(0, cursor + offset), text.count)
    }
}

final class FakeEngine: SuggestionProviding {
    var corrections: [String: String] = ["teh": "the", "haus": "Haus"]
    func suggest(_ q: SuggestionQuery) -> SuggestionResult {
        guard let c = corrections[q.currentWord] else { return SuggestionResult(suggestions: [Suggestion(text: q.currentWord, kind: .typed)]) }
        let ac = Suggestion(text: c, kind: .correction, isAutocorrect: true)
        return SuggestionResult(suggestions: [Suggestion(text: q.currentWord, kind: .typed), ac], autocorrection: ac)
    }
    func noteCommitted(word: String, language: KeyboardLanguage?) {}
    func isKnownWord(_ word: String, languages: [KeyboardLanguage]) -> Bool { true }
    func likelyLanguage(of word: String, among languages: [KeyboardLanguage]) -> KeyboardLanguage? { languages.first }
}

final class Sink: LearningSink {
    var events: [LearningEvent] = []
    func record(_ event: LearningEvent) { events.append(event) }
}

final class InputControllerTests: XCTestCase {
    var doc: MockDocument!
    var c: InputController!
    var sink: Sink!
    var now: TimeInterval = 0

    override func setUp() {
        doc = MockDocument()
        var s = KeibordSettings()
        s.enabledLanguages = [.deAT, .enGB]
        c = InputController(document: doc, engine: FakeEngine(), settings: s, clock: { [unowned self] in self.now })
        sink = Sink()
        c.learningSink = sink
    }

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
}
