import XCTest
@testable import KeibordCore

/// Types real sentences with scattered thumb touches through the whole pipeline (touch resolver → input
/// controller → autocorrect), with and without the predictive touch zones, and compares the results.
final class PredictiveTouchEvalTests: XCTestCase {
    static let sentences: [KeyboardLanguage: [String]] = [
        .deAT: ["ich bin heute nicht zu hause weil ich arbeiten muss", "kannst du mir bitte sagen wann wir uns treffen",
                "das wetter ist schön und wir gehen am abend spazieren", "ich habe keine zeit aber morgen komme ich gerne vorbei",
                "wir sehen uns nächste woche in der schule", "danke für die nachricht ich melde mich später",
                "hast du schon gegessen oder sollen wir etwas bestellen", "meine mutter hat gesagt dass sie heute kocht"],
        .enGB: ["there is nothing we can do about it right now", "i think we should meet tomorrow after work",
                "thank you so much for your help with the project", "can you tell me where the station is please",
                "we are going to the cinema this evening", "what time does the shop open on sunday",
                "my brother lives in london with his family", "please let me know if you need anything else"],
        .sqXK: ["si je sot unë jam mirë faleminderit", "nesër do të shkojmë në shkollë bashkë",
                "kam shumë punë sot por nesër jam i lirë", "a mund të më ndihmosh pak me këtë",
                "ku je tani a po vjen në shtëpi", "e dua shumë familjen time"],
        .itIT: ["oggi non posso venire perché devo lavorare", "ci vediamo domani sera al solito posto",
                "grazie mille per il tuo aiuto di ieri", "dove sei adesso stai tornando a casa",
                "la mia famiglia vive in una piccola città", "vorrei un caffè e un cornetto per favore"],
    ]

    /// Deterministic Gaussian scatter (Box–Muller over a fixed linear congruential generator).
    struct Scatter {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }

    final class NoisyTypist {
        let doc = MockDocument()
        let engine: SuggestionEngine
        let controller: InputController
        let predictive: Bool
        let prediction: TouchResolver.Prediction
        var scatter: Scatter
        /// Letters typed (before autocorrect) and how many of them were the intended ones.
        var letters = 0
        var rightLetters = 0

        init(language: KeyboardLanguage, predictive: Bool, seed: UInt64, prediction: TouchResolver.Prediction = .standard) {
            var s = KeibordSettings()
            s.enabledLanguages = [language]
            engine = SuggestionEngine { EngineQualityHarness.shared.lexicon($0) }
            controller = InputController(document: doc, engine: engine, settings: s, language: language)
            controller.configure(field: FieldContext(autocapitalization: .none))
            self.predictive = predictive
            self.prediction = prediction
            scatter = Scatter(state: seed)
        }

        func type(_ sentence: String, spreadX: Double, spreadY: Double) {
            for ch in sentence {
                if ch == " " { controller.handle(.space); continue }
                let c = controller
                let layout = LayoutFactory.layout(for: LayoutRequest(language: c.language, base: c.settings.baseLayout(for: c.language),
                                                                     page: .letters, variant: c.field.layoutVariant,
                                                                     showLanguageKey: false, returnKind: c.field.returnKind))
                let frames = LayoutGeometry.frames(for: layout, width: 393, metrics: .standard(height: .standard, landscape: false))
                guard let target = frames.first(where: { $0.key.action == .insert(String(ch)) }) else {
                    controller.handle(.character(String(ch), tap: nil, isLetter: true)) // accents: long press
                    continue
                }
                let point = CGPoint(x: target.rect.midX + spreadX * target.rect.width * scatter.gaussian(),
                                    y: target.rect.midY + spreadY * target.rect.height * scatter.gaussian())
                let resolver = TouchResolver(frames: frames, touchModelKey: layout.touchModelKey)
                let prior = predictive ? engine.nextLetterLog2Probabilities(after: controller.currentWord, languages: controller.languages) : [:]
                guard let (index, tap) = resolver.resolve(point, letterLog2Prior: prior, prediction: prediction) else { continue }
                let key = frames[index].key
                guard case .insert(let text) = key.action else { continue }
                letters += 1
                if text == String(ch) { rightLetters += 1 }
                controller.handle(.character(text, tap: key.isLetter ? tap : nil, isLetter: key.isLetter))
            }
            controller.handle(.space)
        }
    }

    private func requireDictionaries() throws {
        let path = EngineIntegrationTests.dictionaryDir.appendingPathComponent("de-AT.kbdl").path
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("dictionaries not built") }
    }

    static let verbose = ProcessInfo.processInfo.environment["KEIBORD_EVAL_VERBOSE"] == "1"

    /// Accuracy of `prediction` (nil: geometry only) over all languages, a few rounds per sentence.
    func measure(_ prediction: TouchResolver.Prediction?, spread: (x: Double, y: Double), rounds: Int)
        -> (words: Int, right: Int, letters: Int, rightLetters: Int) {
        var r = (words: 0, right: 0, letters: 0, rightLetters: 0)
        for (language, sentences) in Self.sentences.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for (i, sentence) in sentences.enumerated() {
                for round in 0..<rounds {
                    let typist = NoisyTypist(language: language, predictive: prediction != nil, seed: UInt64(1000 * i + round + 1),
                                             prediction: prediction ?? .standard)
                    typist.type(sentence, spreadX: spread.x, spreadY: spread.y)
                    let typed = typist.doc.text.lowercased().split(separator: " ").map(String.init)
                    let wanted = sentence.split(separator: " ").map(String.init)
                    r.words += wanted.count
                    r.right += zip(typed, wanted).filter { $0.0 == $0.1 }.count
                    r.letters += typist.letters
                    r.rightLetters += typist.rightLetters
                }
            }
        }
        return r
    }

    /// KEIBORD_TUNE=1: compares prediction strengths (slow; for choosing `TouchResolver.Prediction.standard`).
    func testTunePrediction() throws {
        try requireDictionaries()
        guard ProcessInfo.processInfo.environment["KEIBORD_TUNE"] == "1" else { throw XCTSkip("set KEIBORD_TUNE=1") }
        let spreads = [(x: 0.22, y: 0.18), (x: 0.3, y: 0.25)]
        func report(_ label: String, _ p: TouchResolver.Prediction?) {
            var parts: [String] = []
            for spread in spreads {
                let m = measure(p, spread: spread, rounds: 5)
                parts.append(String(format: "s%.2f words %.2f%% letters %.2f%%", spread.x, 100 * Double(m.right) / Double(m.words),
                                    100 * Double(m.rightLetters) / Double(m.letters)))
            }
            print("[tune] \(label): " + parts.joined(separator: " | "))
        }
        report("off", nil)
        for weight in [0.3, 0.45, 0.6] {
            for core in [0.3, 0.38] {
                for reach in [0.75, 0.9] {
                    report("w\(weight) c\(core) r\(reach)", TouchResolver.Prediction(core: core, reach: reach, weight: weight))
                }
            }
        }
    }

    /// Word accuracy of the final text and letter accuracy of the raw taps, per language and spread.
    func testPredictiveZonesTypeMoreAccurately() throws {
        try requireDictionaries()
        var totals: [Bool: (words: Int, right: Int, letters: Int, rightLetters: Int)] = [:]
        for spread in [(x: 0.22, y: 0.18), (x: 0.3, y: 0.25)] {
            for (language, sentences) in Self.sentences.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                for predictive in [false, true] {
                    var words = 0, right = 0, letters = 0, rightLetters = 0
                    for (i, sentence) in sentences.enumerated() {
                        for round in 0..<3 {
                            let typist = NoisyTypist(language: language, predictive: predictive, seed: UInt64(1000 * i + round + 1))
                            typist.type(sentence, spreadX: spread.x, spreadY: spread.y)
                            // Case-insensitive: autocorrect rightly capitalises German nouns ("Hause").
                            let typed = typist.doc.text.lowercased().split(separator: " ").map(String.init)
                            let wanted = sentence.split(separator: " ").map(String.init)
                            words += wanted.count
                            right += zip(typed, wanted).filter { $0.0 == $0.1 }.count
                            if Self.verbose {
                                for (t, w) in zip(typed, wanted) where t != w { print("  [miss] \(language.rawValue) p=\(predictive) \(w) → \(t)") }
                            }
                            letters += typist.letters
                            rightLetters += typist.rightLetters
                        }
                    }
                    var t = totals[predictive] ?? (0, 0, 0, 0)
                    t.words += words; t.right += right; t.letters += letters; t.rightLetters += rightLetters
                    totals[predictive] = t
                    print("[predictive touch] \(language.rawValue) spread \(spread.x) predictive=\(predictive): words "
                          + String(format: "%.1f%%", 100 * Double(right) / Double(words)) + ", raw letters "
                          + String(format: "%.1f%%", 100 * Double(rightLetters) / Double(letters)))
                }
            }
        }
        let off = totals[false]!, on = totals[true]!
        print("[predictive touch] all: words off " + String(format: "%.1f%%", 100 * Double(off.right) / Double(off.words))
              + " on " + String(format: "%.1f%%", 100 * Double(on.right) / Double(on.words))
              + "; raw letters off " + String(format: "%.1f%%", 100 * Double(off.rightLetters) / Double(off.letters))
              + " on " + String(format: "%.1f%%", 100 * Double(on.rightLetters) / Double(on.letters)))
        XCTAssertGreaterThan(on.rightLetters * off.letters, off.rightLetters * on.letters, "predictive zones hit more intended letters")
        XCTAssertGreaterThanOrEqual(on.right, off.right, "and cost no words after autocorrect")
    }
}
