import Foundation
import XCTest
@testable import KeibordCore

/// End-to-end typing: real layouts, `TouchResolver` taps, the real `SuggestionEngine` with the bundled
/// dictionaries and the `InputController`, typing whole sentences key by key (skipped without dictionaries).
final class InputIntegrationTests: XCTestCase {
    private static var lexicons: [String: BinaryLexicon] = [:]

    private static func lexicon(_ language: KeyboardLanguage) -> BinaryLexicon? {
        if let cached = lexicons[language.dictionaryID] { return cached }
        let url = EngineIntegrationTests.dictionaryDir.appendingPathComponent("\(language.dictionaryID).kbdl")
        guard let lex = try? BinaryLexicon(url: url) else { return nil }
        lexicons[language.dictionaryID] = lex
        return lex
    }

    /// A person typing on a 390 pt wide portrait keyboard. Keys are hit at their centre; `{a>s}` in the
    /// typed text means "meant a, but the finger landed 65 % of the way towards s" (a realistic typo).
    final class Typist {
        let doc = MockDocument()
        let settings: KeibordSettings
        let controller: InputController
        var now: TimeInterval = 0
        private(set) var missingKeys: [String] = []

        init(_ settings: KeibordSettings, language: KeyboardLanguage) {
            self.settings = settings
            // A fresh engine per typist: language detection must not leak between sentences.
            let engine = SuggestionEngine { InputIntegrationTests.lexicon($0) }
            var clockNow: () -> TimeInterval = { 0 }
            controller = InputController(document: doc, engine: engine, settings: settings, language: language, clock: { clockNow() })
            clockNow = { [unowned self] in self.now }
        }

        private func currentFrames() -> (KeyboardLayout, [KeyFrame]) {
            let c = controller
            let request = LayoutRequest(language: c.language, base: settings.baseLayout(for: c.language), page: c.page,
                                        variant: c.field.layoutVariant, showLanguageKey: settings.activeLanguages.count > 1,
                                        returnKind: c.field.returnKind)
            let layout = LayoutFactory.layout(for: request)
            let metrics = KeyboardMetrics.standard(height: .standard, landscape: false)
            return (layout, LayoutGeometry.frames(for: layout, width: 390, metrics: metrics))
        }

        /// Touches the key matching `match` (optionally slipping towards `slip`) and delivers the event
        /// for the key the resolver actually hit, exactly like the keyboard view does.
        @discardableResult
        private func touch(_ match: (KeySpec) -> Bool, slip: Character? = nil) -> Bool {
            let (layout, frames) = currentFrames()
            guard let target = frames.first(where: { match($0.key) }) else { return false }
            var point = CGPoint(x: target.rect.midX, y: target.rect.midY)
            if let slip = slip, let other = frames.first(where: { $0.key.action == .insert(String(slip)) }) {
                point.x += 0.65 * (other.rect.midX - point.x)
                point.y += 0.65 * (other.rect.midY - point.y)
            }
            let resolver = TouchResolver(frames: frames, touchModelKey: layout.touchModelKey)
            guard let (index, tap) = resolver.resolve(point) else { return false }
            let key = frames[index].key
            switch key.action {
            case .insert(let text): controller.handle(.character(text, tap: key.isLetter ? tap : nil, isLetter: key.isLetter))
            case .space: controller.handle(.space)
            case .returnKey: controller.handle(.returnKey)
            case .switchPage(let page): controller.handle(.switchPage(page))
            case .shift: controller.handle(.shift)
            case .backspace: controller.handle(.backspace)
            default: return false
            }
            now += 0.15
            return true
        }

        private func press(_ ch: Character, slip: Character?) {
            let match: (KeySpec) -> Bool
            switch ch {
            case " ": match = { $0.action == .space }
            case "\n": match = { $0.action == .returnKey }
            default: match = { $0.action == .insert(String(ch)) }
            }
            if touch(match, slip: slip) || longPress(ch) { return }
            for page in [LayoutPage.letters, .numbers, .symbols] where page != controller.page {
                if touch({ $0.action == .switchPage(page) }), touch(match, slip: slip) || longPress(ch) { return }
            }
            missingKeys.append(String(ch))
        }

        /// Picks `ch` from a key's long-press menu (no spatial tap, like the keyboard view).
        private func longPress(_ ch: Character) -> Bool {
            let (_, frames) = currentFrames()
            guard let key = frames.first(where: { $0.key.alternates.contains(String(ch)) })?.key else { return false }
            controller.handle(.character(String(ch), tap: nil, isLetter: key.isLetter))
            now += 0.6
            return true
        }

        func type(_ text: String) {
            var chars = Array(text)[...]
            while let ch = chars.popFirst() {
                if ch == "{", let close = chars.firstIndex(of: "}") {
                    let spec = Array(chars[chars.startIndex..<close])  // e.g. ["a", ">", "s"]
                    chars = chars[(close + 1)...]
                    press(spec[0], slip: spec.count == 3 ? spec[2] : nil)
                } else {
                    press(ch, slip: nil)
                }
            }
        }

        func backspace() { _ = touch({ $0.action == .backspace }) }
    }

    private func requireDictionaries() throws {
        let path = EngineIntegrationTests.dictionaryDir.appendingPathComponent("de-AT.kbdl").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("dictionaries not built") }
    }

    private func settings(_ languages: [KeyboardLanguage]) -> KeibordSettings {
        var s = KeibordSettings()
        s.enabledLanguages = languages
        return s
    }

    /// Types every sentence into a fresh document and compares the result.
    private func check(_ languages: [KeyboardLanguage], _ cases: [(typed: String, expected: String)],
                       file: StaticString = #filePath, line: UInt = #line) throws {
        try requireDictionaries()
        var passed = 0
        for (typed, expected) in cases {
            let typist = Typist(settings(languages), language: languages[0])
            typist.type(typed)
            XCTAssertEqual(typist.missingKeys, [], "keys not found while typing \(typed)", file: file, line: line)
            XCTAssertEqual(typist.doc.text, expected, "typed \(typed.debugDescription) in \(languages.map(\.rawValue))", file: file, line: line)
            if typist.doc.text == expected { passed += 1 }
        }
        print("InputIntegration \(languages.map(\.rawValue)): \(passed)/\(cases.count) sentences exact")
    }

    func testGerman() throws {
        try check([.deAT, .enGB], [
            ("ich hab das haus gesehen. ", "Ich hab das Haus gesehen. "),
            ("wie geht's dir? ", "Wie geht’s dir? "),
            ("wir treffen uns morgen um 8 uhr. ", "Wir treffen uns morgen um 8 Uhr. "),
            ("er sagte \"hallo\" und ging. ", "Er sagte „hallo“ und ging. "),
            ("danke  ", "Danke. "),
            ("kannst du mir bitte {h>j}elfen? ", "Kannst du mir bitte helfen? "),
            ("das ist eine gute {i>o}dee. ", "Das ist eine gute Idee. "),
            ("ich {w>e}eiß es nicht. ", "Ich weiß es nicht. "),
            ("das war z.b. gestern. ", "Das war z.b. gestern. "),
            ("ich gehe ins buro. ", "Ich gehe ins Büro. "),
            ("so'n quatsch, ich hab's gesehen. ", "So’n quatsch, ich hab’s gesehen. "),
            ("das ist \"super\"! ", "Das ist „super“! "),
        ])
    }

    func testEnglish() throws {
        try check([.enGB, .deAT], [
            ("i think teh weather is nice today. ", "I think the weather is nice today. "),
            ("i dont know  ", "I don’t know. "),
            ("she said 'hello' to me. ", "She said ‘hello’ to me. "),
            ("it's a {g>f}reat idea. ", "It’s a great idea. "),
            ("i recieved your message. ", "I received your message. "),
            ("youre right, thats it. ", "You’re right, that’s it. "),
            ("the dogs' toys. ", "The dogs’ toys. "),
        ])
    }

    func testAlbanian() throws {
        try check([.sqXK], [
            ("eshte mire ", "Është mirë "),
            ("faleminderit shume. ", "Faleminderit shumë. "),
            ("si je? une jam mire. ", "Si je? Unë jam mirë. "),
            ("kam qene shume i lodhur sot. ", "Kam qenë shumë i lodhur sot. "),
        ])
    }

    func testItalian() throws {
        try check([.itIT], [
            ("perche non vieni in citta? ", "Perché non vieni in città? "),
            ("l'amico di mio padre. ", "L’amico di mio padre. "),
            ("c'è un problema. ", "C’è un problema. "),
            ("dov'è la stazione? ", "Dov’è la stazione? "),
            ("grazie {m>n}ille. ", "Grazie mille. "),
            ("puo venire domani. ", "Può venire domani. "),
            ("un po' di pane. ", "Un po’ di pane. "),
            ("dell'anno scorso. ", "Dell’anno scorso. "),
        ])
    }

    func testOwnersFourLanguages() throws {
        try check([.deAT, .enGB, .sqXK, .itIT], [
            ("ich hab das haus gesehen. ", "Ich hab das Haus gesehen. "),
            ("wie geht's dir? ", "Wie geht’s dir? "),
            ("faleminderit shume. ", "Faleminderit shumë. "),
            ("perche non vieni in citta? ", "Perché non vieni in città? "),
            ("i dont know. ", "I don’t know. "),
            ("l'amico di mio padre. ", "L’amico di mio padre. "),
        ])
    }

    func testUndoAutocorrectionByBackspace() throws {
        try requireDictionaries()
        let typist = Typist(settings([.enGB]), language: .enGB)
        typist.type("teh ")
        XCTAssertEqual(typist.doc.text, "The ")
        typist.backspace()
        XCTAssertEqual(typist.doc.text, "Teh")
        typist.type(" ")
        XCTAssertEqual(typist.doc.text, "Teh ")
    }
}
