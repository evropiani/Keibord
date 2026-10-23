import XCTest
@testable import KeibordCore

/// Invisible touch zones that grow for the letters likely to come next (as on the iPhone keyboard).
final class PredictiveTouchTests: XCTestCase {
    private let lexicon = InMemoryLexicon(languageID: "en-GB", entries: [
        ("the", 7.0), ("there", 6.0), ("they", 6.2), ("then", 5.5), ("therefore", 4.5), ("wet", 4.0),
    ])

    func testNextLettersCarryTheirBranchesMostFrequentWord() {
        let next = Dictionary(uniqueKeysWithValues: lexicon.nextLetters(prefix: "the").map { (String($0.letter), $0.zipf) })
        XCTAssertEqual(Set(next.keys), ["r", "y", "n"])
        XCTAssertEqual(next["y"] ?? 0, 6.2, accuracy: 0.05)
        XCTAssertEqual(next["r"] ?? 0, 6.0, accuracy: 0.05)
        XCTAssertEqual(lexicon.nextLetters(prefix: "THER").map { String($0.letter) }, ["e"], "lookup keys are lower case")
        XCTAssertTrue(lexicon.nextLetters(prefix: "thx").isEmpty)
    }

    func testEngineProbabilitiesFavourTheContinuationsOfKnownWords() {
        let engine = SuggestionEngine { [lexicon] _ in lexicon }
        let p = engine.nextLetterLog2Probabilities(after: "Ther", languages: [.enGB])
        XCTAssertEqual(p["e"] ?? -99, 0, accuracy: 0.001, "after \"ther\" only \"e\" continues a word")
        XCTAssertNil(p["w"])
        let start = engine.nextLetterLog2Probabilities(after: "", languages: [.enGB])
        XCTAssertGreaterThan(start["t"] ?? -99, start["w"] ?? -99)
        XCTAssertTrue(engine.nextLetterLog2Probabilities(after: "xq", languages: [.enGB]).isEmpty, "unknown words: geometry only")
    }

    private func resolver() -> (TouchResolver, [KeyFrame]) {
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .enGB, base: .qwerty, page: .letters, variant: .standard,
                                                             showNumberRow: false, showLanguageKey: false, showGlobeKey: false, returnKind: .default))
        let frames = LayoutGeometry.frames(for: layout, width: 390, metrics: .standard(height: .standard, landscape: false))
        return (TouchResolver(frames: frames, touchModelKey: layout.touchModelKey), frames)
    }

    private func frame(_ id: String, _ frames: [KeyFrame]) -> KeyFrame { frames.first { $0.key.id == id }! }

    func testALikelyLetterTakesOverTheEdgeOfItsNeighbour() throws {
        let (resolver, frames) = resolver()
        let w = frame("w", frames), e = frame("e", frames)
        // On "w", 40 % of the way from its centre towards "e".
        let edge = CGPoint(x: w.rect.midX + 0.4 * w.rect.width, y: w.rect.midY)
        XCTAssertEqual(resolver.resolve(edge)?.tap.candidates.first?.character, "w")
        let afterTher: [String: Double] = ["e": -0.05]
        let predicted = try XCTUnwrap(resolver.resolve(edge, letterLog2Prior: afterTher))
        XCTAssertEqual(frames[predicted.frameIndex].key.id, "e")
        XCTAssertEqual(predicted.tap.candidates.first?.character, "e")
        XCTAssertEqual(predicted.tap.candidates.first?.cost, 0)
        XCTAssertEqual(predicted.tap.candidates.first(where: { $0.character == "w" })?.cost, 0, "the closer key stays a free alternative")
        // The middle of a key always types it, however unlikely.
        let middle = CGPoint(x: w.rect.midX + 0.1 * w.rect.width, y: w.rect.midY)
        XCTAssertEqual(resolver.resolve(middle, letterLog2Prior: afterTher).map { frames[$0.frameIndex].key.id }, "w")
        // The far side of "w" is out of reach for "e".
        let farSide = CGPoint(x: w.rect.midX - 0.4 * w.rect.width, y: w.rect.midY)
        XCTAssertEqual(resolver.resolve(farSide, letterLog2Prior: afterTher).map { frames[$0.frameIndex].key.id }, "w")
        // Without a prediction, or when both are about as likely, geometry decides.
        XCTAssertEqual(resolver.resolve(edge, letterLog2Prior: [:]).map { frames[$0.frameIndex].key.id }, "w")
        XCTAssertEqual(resolver.resolve(edge, letterLog2Prior: ["e": -1, "w": -1]).map { frames[$0.frameIndex].key.id }, "w")
        _ = e
    }

    func testPredictionNeverMovesATapOntoAFunctionKey() {
        let (resolver, frames) = resolver()
        let m = frame("m", frames)
        let edge = CGPoint(x: m.rect.maxX - 1, y: m.rect.midY)
        XCTAssertEqual(resolver.resolve(edge, letterLog2Prior: ["n": -0.1]).map { frames[$0.frameIndex].key.id }, "m",
                       "\"n\" is too far; backspace is never predicted")
    }
}
