import XCTest
@testable import KeibordCore

/// Runs the engine against the real bundled dictionaries (skipped if they are missing).
final class EngineIntegrationTests: XCTestCase {
    static let dictionaryDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Dictionaries")

    static let engine: SuggestionEngine = SuggestionEngine { language in
        try? BinaryLexicon(url: dictionaryDir.appendingPathComponent("\(language.dictionaryID).kbdl"))
    }

    private func correct(_ word: String, _ languages: [KeyboardLanguage], previous: [String] = []) throws -> String? {
        guard FileManager.default.fileExists(atPath: Self.dictionaryDir.appendingPathComponent("de-AT.kbdl").path) else {
            throw XCTSkip("dictionaries not built")
        }
        let r = Self.engine.suggest(SuggestionQuery(currentWord: word, previousWords: previous, languages: languages))
        return r.autocorrection?.text
    }

    func testCorrections() throws {
        XCTAssertEqual(try correct("eshte", [.sqXK]), "është")
        XCTAssertEqual(try correct("cfare", [.sqXK]), "çfarë")
        XCTAssertEqual(try correct("perche", [.itIT]), "perché")
        XCTAssertEqual(try correct("citta", [.itIT]), "città")
        XCTAssertEqual(try correct("teh", [.enGB]), "the")
        XCTAssertEqual(try correct("dont", [.enUS]), "don't")
        XCTAssertEqual(try correct("recieve", [.enUS]), "receive")
        XCTAssertEqual(try correct("haus", [.deAT], previous: ["das"]), "Haus")
        XCTAssertEqual(try correct("strase", [.deAT]), "Straße")
        XCTAssertNil(try correct("essen", [.deAT]))
        XCTAssertNil(try correct("the", [.deAT, .enGB]))
        XCTAssertEqual(try correct("color", [.enGB]), "colour")
        XCTAssertNil(try correct("color", [.enUS]))
    }

    func testPredictionsAndTiming() throws {
        guard FileManager.default.fileExists(atPath: Self.dictionaryDir.appendingPathComponent("de-AT.kbdl").path) else { throw XCTSkip("no dicts") }
        let p = Self.engine.suggest(SuggestionQuery(currentWord: "", previousWords: ["in"], languages: [.enGB]))
        XCTAssertFalse(p.suggestions.isEmpty)
        let start = Date()
        for w in ["Entschuldi", "wahrscheinlich", "faleminderit", "probabilmente", "Gesellschaft"] {
            _ = Self.engine.suggest(SuggestionQuery(currentWord: w, languages: [.deAT, .enGB, .sqXK]))
        }
        print("5 queries x 3 languages:", Date().timeIntervalSince(start) * 1000, "ms")
        print(Self.engine.suggest(SuggestionQuery(currentWord: "Entschuldi", languages: [.deAT])).suggestions.map(\.display))
        print(p.suggestions.map(\.display))
    }
}
