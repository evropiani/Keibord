import XCTest
@testable import KeibordCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Sentence-level suggestion quality: whole messages typed key by key through the real `InputController`
/// and `SuggestionEngine` (bundled dictionaries, 393 pt portrait layout, `TouchResolver` taps), so the
/// engine sees what it sees on the device: the previous words of the sentence (elided articles split
/// off), sentence starts, auto-capitalisation and the language detector fed by every committed word.
///
/// Scoring is per word: a word typed correctly must come out unchanged (else it is a false positive), a
/// misspelt word must come out as intended. `{a>s}` in the typed text means "meant a, but the finger
/// landed 65 % of the way towards s". Set `KEIBORD_EVAL_VERBOSE=1` to print every wrong word.
final class EngineQualitySentenceTests: XCTestCase {
    // Measured before → after the engine-quality pass (Oct 2026): fixed words mono de 70 → 100 %, en 85 → 100 %,
    // sq 90 → 90 %, it 69 → 100 %; four languages de 41 → 100 %, en 69 → 92 %, sq 67 → 90 %, it 54 → 100 %;
    // German layout 57 → 94 %; held-out validation 69 → 89 %. Damaged correct words: monolingual 5/270 → 0,
    // four languages 4/270 → 0, held-out 7/369 → 0.

    /// Minimum share of misspelt words that come out as intended.
    static let minFixRate = 0.85
    /// Owner's four languages, layout language = the sentence's language.
    static let minFixRateMultilingual = 0.85
    /// Albanian / English / Italian typed on the German layout with all four languages enabled.
    static let minFixRateOnGermanLayout = 0.85
    /// Held-out sentences (written after tuning).
    static let minFixRateValidation = 0.80

    private func requireDictionaries() throws {
        guard EngineQualityHarness.available else { throw XCTSkip("dictionaries not built") }
    }

    func testMonolingualSentences() throws {
        try requireDictionaries()
        for language in EngineQualityData.evaluatedLanguages {
            let m = SentenceEvaluator.run(EngineQualitySentences.cases(for: language), languages: [language], label: "sentences mono \(language.rawValue)")
            XCTAssertEqual(m.damaged, 0, "\(language): correct words changed\n\(m.failureList)")
            XCTAssertGreaterThanOrEqual(m.fixRate, Self.minFixRate, "\(language)\n\(m.failureList)")
        }
    }

    func testOwnersLanguagesSentences() throws {
        try requireDictionaries()
        for language in EngineQualityData.evaluatedLanguages {
            let languages = EngineQualityData.ownerLanguages(first: language)
            let m = SentenceEvaluator.run(EngineQualitySentences.cases(for: language), languages: languages, label: "sentences multi \(language.rawValue)")
            XCTAssertEqual(m.damaged, 0, "\(language): correct words changed\n\(m.failureList)")
            XCTAssertGreaterThanOrEqual(m.fixRate, Self.minFixRateMultilingual, "\(language)\n\(m.failureList)")
        }
    }

    /// The owner rarely switches the layout: Albanian, English and Italian typed with German first.
    func testOwnersLanguagesOnGermanLayout() throws {
        try requireDictionaries()
        let languages = EngineQualityData.ownerLanguages(first: .deAT)
        var total = SentenceMetrics(label: "sentences de-layout all")
        for language in [KeyboardLanguage.enGB, .sqXK, .itIT] {
            let m = SentenceEvaluator.run(EngineQualitySentences.cases(for: language), languages: languages, keyboard: .deAT,
                                          label: "sentences de-layout \(language.rawValue)")
            XCTAssertEqual(m.damaged, 0, "\(language) on the German layout: correct words changed\n\(m.failureList)")
            total.add(m)
        }
        let mixed = SentenceEvaluator.run(EngineQualitySentences.mixed, languages: languages, label: "sentences mixed")
        XCTAssertEqual(mixed.damaged, 0, "mixed messages: correct words changed\n\(mixed.failureList)")
        total.add(mixed)
        print(String(format: "[quality] sentences de-layout all: fixed %.1f%% (%d/%d), damaged %d", total.fixRate * 100, total.fixed, total.toFix, total.damaged))
        XCTAssertGreaterThanOrEqual(total.fixRate, Self.minFixRateOnGermanLayout, total.failureList)
    }
}

extension EngineQualitySentenceTests {
    /// Held-out sentences written after the engine was tuned on the sets above: they guard against
    /// over-fitting (lower bar for the fix rate, but still no damaged words).
    func testValidationSentences() throws {
        try requireDictionaries()
        var total = SentenceMetrics(label: "validation all")
        for language in EngineQualityData.evaluatedLanguages {
            let cases = EngineQualitySentences.validation[language] ?? []
            for languages in [[language], EngineQualityData.ownerLanguages(first: .deAT)] {
                let m = SentenceEvaluator.run(cases, languages: languages, label: "validation \(language.rawValue) \(languages.map(\.rawValue))")
                XCTAssertEqual(m.damaged, 0, "\(language) \(languages): correct words changed\n\(m.failureList)")
                total.add(m)
            }
        }
        let mixed = SentenceEvaluator.run(EngineQualitySentences.mixedValidation, languages: EngineQualityData.ownerLanguages(first: .deAT),
                                          label: "validation mixed")
        XCTAssertEqual(mixed.damaged, 0, mixed.failureList)
        total.add(mixed)
        print(String(format: "[quality] validation all: fixed %.1f%% (%d/%d), damaged %d/%d", total.fixRate * 100, total.fixed, total.toFix,
                     total.damaged, total.toKeep))
        XCTAssertGreaterThanOrEqual(total.fixRate, Self.minFixRateValidation, total.failureList)
    }
}

// MARK: - Data

enum EngineQualitySentences {
    static func cases(for language: KeyboardLanguage) -> [(typed: String, expected: String)] {
        all[language] ?? []
    }

    static let all: [KeyboardLanguage: [(typed: String, expected: String)]] = [
        .deAT: [
            ("ich hab heute keine zeit, vielleicht morgen. ", "Ich hab heute keine Zeit, vielleicht morgen. "),
            ("wir treffen uns am samstag in der schule. ", "Wir treffen uns am Samstag in der Schule. "),
            ("das {w>e}ochenende war echt leiwand. ", "Das Wochenende war echt leiwand. "),
            ("kannst du mir bitte die nachricht schicken? ", "Kannst du mir bitte die Nachricht schicken? "),
            ("ich hätte gerne einen kafee. ", "Ich hätte gerne einen Kaffee. "),
            ("fur mich ist das kein problem. ", "Für mich ist das kein Problem. "),
            ("oida, heast, gemma morgen auf a bier? ", "Oida, heast, gemma morgen auf a Bier? "),
            ("gruss aus wien ", "Gruß aus Wien "),
            ("ich bin gleich zuruck, warte kurz. ", "Ich bin gleich zurück, warte kurz. "),
            ("das ist {n>m}icht so schlimm. ", "Das ist nicht so schlimm. "),
            ("meine freundin hat {g>h}eburtstag. ", "Meine Freundin hat Geburtstag. "),
            ("brot, milch, eier usw. ", "Brot, Milch, Eier usw. "),
            ("ich weiss nicht, ob das geht. ", "Ich weiß nicht, ob das geht. "),
            ("es tut mir leid, ich hab das vergessen. ", "Es tut mir leid, ich hab das vergessen. "),
            ("uber das wetter reden wir spater. ", "Über das Wetter reden wir später. "),
            ("keine angst, das wird schon. ", "Keine Angst, das wird schon. "),
            ("ich treffe Arben und Ardita in Graz. ", "Ich treffe Arben und Ardita in Graz. "),
            ("so ein quatsch, bis zum ende. ", "So ein Quatsch, bis zum Ende. "),
            ("vielen dank fur die schnelle antwort. ", "Vielen Dank für die schnelle Antwort. "),
            ("wir essen heute bei mama. ", "Wir essen heute bei Mama. "),
            ("bzw. ist das nicht so wichtig. ", "Bzw. ist das nicht so wichtig. "),
            ("lg Senad ", "Lg Senad "),
        ],
        .enGB: [
            ("i think teh meeting is tomorow. ", "I think the meeting is tomorrow. "),
            ("dont worry about it. ", "Don’t worry about it. "),
            ("thanks for yo{u>i}r help. ", "Thanks for your help. "),
            ("im going to the {c>v}inema with my mum. ", "I’m going to the cinema with my mum. "),
            ("she recieved the parcel yesterday. ", "She received the parcel yesterday. "),
            ("what colour is your new car? ", "What colour is your new car? "),
            ("we were definately rigth. ", "We were definitely right. "),
            ("can you send me the adress? ", "Can you send me the address? "),
            ("lol that was so funny. ", "Lol that was so funny. "),
            ("my favourite place in london is the {p>o}ark. ", "My favourite place in London is the park. "),
            ("i dont know where shes going. ", "I don’t know where she’s going. "),
            ("the weather is realy nice today. ", "The weather is really nice today. "),
            ("Senad and Arben are coming too. ", "Senad and Arben are coming too. "),
            ("see you on {m>n}onday, cheers. ", "See you on Monday, cheers. "),
            ("i ate too much pizza. ", "I ate too much pizza. "),
            ("its not {w>e}orking, ok? ", "Its not working, ok? "),
            ("could you {p>o}lease call me back. ", "Could you please call me back. "),
            ("btw the {s>a}hop is closed. ", "Btw the shop is closed. "),
        ],
        .sqXK: [
            ("eshte mire qe erdhe. ", "Është mirë që erdhe. "),
            ("faleminderit shume per ndihmen. ", "Faleminderit shumë për ndihmën. "),
            ("une jam ne shtepi. ", "Unë jam në shtëpi. "),
            ("si je sot? ", "Si je sot? "),
            ("cfare po ben? ", "Çfarë po bën? "),
            ("kam qene shume i lodhur sot. ", "Kam qenë shumë i lodhur sot. "),
            ("neser shkojme ne prishtine. ", "Nesër shkojmë në Prishtinë. "),
            ("flm shume, shihemi. ", "Flm shumë, shihemi. "),
            ("vetem pak minuta. ", "Vetëm pak minuta. "),
            ("keto jane gjerat qe dua. ", "Këto janë gjërat që dua. "),
            ("a ke ngrene buke? ", "A ke ngrënë bukë? "),
            ("Arben dhe Ardita vijne neser. ", "Arben dhe Ardita vijnë nesër. "),
            ("ckemi, a je mire? ", "Ckemi, a je mirë? "),
            ("te dua shume. ", "Të dua shumë. "),
            ("nuk e di, ndoshta {n>m}esër. ", "Nuk e di, ndoshta nesër. "),
        ],
        .itIT: [
            ("perche non vieni in citta? ", "Perché non vieni in città? "),
            ("c'e un problema con la macchina. ", "C’è un problema con la macchina. "),
            ("puo venire anche lui domani. ", "Può venire anche lui domani. "),
            ("ci vediamo venerdi sera. ", "Ci vediamo venerdì sera. "),
            ("grazie mille per il caffe. ", "Grazie mille per il caffè. "),
            ("allora, com'e andata? ", "Allora, com’è andata? "),
            ("sono gia arrivato a casa. ", "Sono già arrivato a casa. "),
            ("la mia {f>g}amiglia sta bene. ", "La mia famiglia sta bene. "),
            ("non lo so, forse piu tardi. ", "Non lo so, forse più tardi. "),
            ("dov'e la stazione? ", "Dov’è la stazione? "),
            ("ciao bella, tutto bene? ", "Ciao bella, tutto bene? "),
            ("l'amico di Matteo è simpatico. ", "L’amico di Matteo è simpatico. "),
            ("cosi non va bene. ", "Così non va bene. "),
            ("un po' di pane, per favore. ", "Un po’ di pane, per favore. "),
            ("lunedi c'e la riunione. ", "Lunedì c’è la riunione. "),
        ],
    ]

    static let validation: [KeyboardLanguage: [(typed: String, expected: String)]] = [
        .deAT: [
            ("hast du am wochenende zeit fur einen kaffee? ", "Hast du am Wochenende Zeit für einen Kaffee? "),
            ("ich bin gerade im buro, ruf mich spater an. ", "Ich bin gerade im Büro, ruf mich später an. "),
            ("das wetter in wien ist heute leiwand. ", "Das Wetter in Wien ist heute leiwand. "),
            ("kannst du bitte das {f>g}enster zumachen? ", "Kannst du bitte das Fenster zumachen? "),
            ("wir {s>a}ehen uns um 8 beim heurigen. ", "Wir sehen uns um 8 beim Heurigen. "),
            ("mein handy ist kaputt, ich schreib dir spater. ", "Mein Handy ist kaputt, ich schreib dir später. "),
            ("geh bitte, das ist ja ur peinlich. ", "Geh bitte, das ist ja ur peinlich. "),
            ("die kinder spielen im garten. ", "Die Kinder spielen im Garten. "),
            ("ich muss noch einkaufen gehen, brauchst du was? ", "Ich muss noch einkaufen gehen, brauchst du was? "),
            ("danke fur alles, baba! ", "Danke für alles, baba! "),
            ("hab grad keine lust auf arbeit. ", "Hab grad keine Lust auf Arbeit. "),
            ("um wie viel uhr fahrt der zug? ", "Um wie viel Uhr fährt der Zug? "),
        ],
        .enGB: [
            ("hey, are you comming tonight? ", "Hey, are you coming tonight? "),
            ("i cant find my keys anywhere. ", "I can’t find my keys anywhere. "),
            ("thats a really good idea. ", "That’s a really good idea. "),
            ("we should meet up next {w>e}eek. ", "We should meet up next week. "),
            ("my phone is {a>s}lmost dead. ", "My phone is almost dead. "),
            ("did you see the match yesterday? ", "Did you see the match yesterday? "),
            ("she doesnt like coffee. ", "She doesn’t like coffee. "),
            ("the trian was late again. ", "The train was late again. "),
            ("happy birthday Arben! ", "Happy birthday Arben! "),
            ("ok see you at 7. ", "Ok see you at 7. "),
        ],
        .sqXK: [
            ("pershendetje, si jeni? ", "Përshëndetje, si jeni? "),
            ("sot eshte nje dite e bukur. ", "Sot është një ditë e bukur. "),
            ("a do vish neser ne darke? ", "A do vish nesër në darkë? "),
            ("me fal, nuk kam pas kohe. ", "Më fal, nuk kam pas kohë. "),
            ("faleminderit per gjithcka. ", "Faleminderit për gjithçka. "),
            ("jam shume i lumtur sot. ", "Jam shumë i lumtur sot. "),
            ("ku je ti tani? ", "Ku je ti tani? "),
            ("do te shkojme bashke. ", "Do të shkojmë bashkë. "),
            ("nena po gatuan dreken. ", "Nëna po gatuan drekën. "),
            ("flm per ndihmen vlla. ", "Flm për ndihmën vlla. "),
        ],
        .itIT: [
            ("che bello, ci vediamo domani. ", "Che bello, ci vediamo domani. "),
            ("non ho capito, puoi ripetere? ", "Non ho capito, puoi ripetere? "),
            ("questa e la mia macchina nuova. ", "Questa è la mia macchina nuova. "),
            ("sono andato al mare con mio fratello. ", "Sono andato al mare con mio fratello. "),
            ("perche non mi hai chiamato? ", "Perché non mi hai chiamato? "),
            ("un caffe per favore. ", "Un caffè per favore. "),
            ("ho gia mangiato, grazie. ", "Ho già mangiato, grazie. "),
            ("qual e il tuo numero? ", "Qual è il tuo numero? "),
            ("lunedi vado a Milano. ", "Lunedì vado a Milano. "),
            ("la citta e bellissima di sera. ", "La città è bellissima di sera. "),
        ],
    ]

    static let mixedValidation: [(typed: String, expected: String)] = [
        ("ok, une po vij tani. ", "Ok, unë po vij tani. "),
        ("thanks, see you tomorow! ", "Thanks, see you tomorrow! "),
        ("grazie mille, a domani. ", "Grazie mille, a domani. "),
        ("faleminderit shume vlla. ", "Faleminderit shumë vlla. "),
        ("bis spater, ich muss los. ", "Bis später, ich muss los. "),
    ]

    /// Messages in different languages after each other in one session (no layout switch).
    static let mixed: [(typed: String, expected: String)] = [
        ("eshte mire. ", "Është mirë. "),
        ("une jam mire, po ti? ", "Unë jam mirë, po ti? "),
        ("i dont know, teh bus is late. ", "I don’t know, the bus is late. "),
        ("uber das reden wir morgen. ", "Über das reden wir morgen. "),
        ("ich hab keine zeit. ", "Ich hab keine Zeit. "),
        ("c'e un problema. ", "C’è un problema. "),
        ("here we go. ", "Here we go. "),
    ]
}

// MARK: - Evaluator

struct SentenceMetrics {
    var label: String
    var sentences = 0
    var exact = 0
    var toFix = 0
    var fixed = 0
    var toKeep = 0
    var damaged = 0
    var failures: [String] = []

    var fixRate: Double { toFix == 0 ? 1 : Double(fixed) / Double(toFix) }
    var failureList: String { failures.joined(separator: "\n") }

    mutating func add(_ other: SentenceMetrics) {
        sentences += other.sentences
        exact += other.exact
        toFix += other.toFix
        fixed += other.fixed
        toKeep += other.toKeep
        damaged += other.damaged
        failures += other.failures
    }
}

enum SentenceEvaluator {
    /// Types every case into a fresh document with a fresh engine (neutral language detector).
    static func run(_ cases: [(typed: String, expected: String)], languages: [KeyboardLanguage], keyboard: KeyboardLanguage? = nil,
                    label: String) -> SentenceMetrics {
        var m = SentenceMetrics(label: label)
        for (typed, expected) in cases {
            var settings = KeibordSettings()
            settings.enabledLanguages = languages
            let typist = SentenceTypist(settings, language: keyboard ?? languages[0])
            typist.type(typed)
            let output = typist.doc.text
            score(typed: plain(typed), expected: expected, output: output, into: &m)
        }
        print(String(format: "[quality] %@: fixed %.1f%% (%d/%d), damaged %d/%d, sentences exact %d/%d", label, m.fixRate * 100, m.fixed, m.toFix,
                     m.damaged, m.toKeep, m.exact, m.sentences))
        if EngineQualityHarness.verbose { m.failures.forEach { print($0) } }
        return m
    }

    /// The typed text without slip markup ("{a>s}" → "a").
    static func plain(_ typed: String) -> String {
        var out = ""
        var chars = Array(typed)[...]
        while let ch = chars.popFirst() {
            if ch == "{", let close = chars.firstIndex(of: "}") {
                out.append(chars[chars.startIndex])
                chars = chars[(close + 1)...]
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{201E}", with: "\"").replacingOccurrences(of: "\u{201C}", with: "\"")
    }

    static func score(typed: String, expected: String, output: String, into m: inout SentenceMetrics) {
        m.sentences += 1
        if output == expected { m.exact += 1 }
        let t = normalise(typed).split(separator: " ").map(String.init)
        let e = normalise(expected).split(separator: " ").map(String.init)
        let o = normalise(output).split(separator: " ").map(String.init)
        guard t.count == e.count else {
            m.failures.append("  bad case: \(typed)")
            return
        }
        guard o.count == e.count else {
            m.toFix += e.count
            m.failures.append("  [\(m.label)] word count changed: \(typed.debugDescription) → \(output.debugDescription)")
            return
        }
        for i in e.indices {
            // Typed as intended, allowing the automatic capital at the start of a sentence.
            let sentenceStart = i == 0 || e[i - 1].last.map { ".!?".contains($0) } ?? false
            let keep = t[i] == e[i] || (sentenceStart && Casing.capitalizingFirstLetter(t[i]) == e[i])
            if keep {
                m.toKeep += 1
                if o[i] != e[i] {
                    m.damaged += 1
                    m.failures.append("  [\(m.label)] DAMAGED \(t[i]) → \(o[i]) in \(output.debugDescription)")
                }
            } else {
                m.toFix += 1
                if o[i] == e[i] {
                    m.fixed += 1
                } else {
                    m.failures.append("  [\(m.label)] \(t[i]) → \(o[i]) (want \(e[i])) in \(output.debugDescription)")
                }
            }
        }
    }
}

/// A person typing on a 393 pt wide portrait keyboard: keys are hit at their centre, `{a>s}` slips 65 %
/// towards the neighbouring key, upper-case letters are typed with shift, characters without a key come
/// from long-press menus.
final class SentenceTypist {
    let doc = MockDocument()
    let settings: KeibordSettings
    let controller: InputController
    private var now: TimeInterval = 0

    init(_ settings: KeibordSettings, language: KeyboardLanguage) {
        self.settings = settings
        let engine = SuggestionEngine { EngineQualityHarness.shared.lexicon($0) }
        var clockNow: () -> TimeInterval = { 0 }
        controller = InputController(document: doc, engine: engine, settings: settings, language: language, clock: { clockNow() })
        clockNow = { [unowned self] in self.now }
    }

    private func frames() -> (KeyboardLayout, [KeyFrame]) {
        let c = controller
        let request = LayoutRequest(language: c.language, base: settings.baseLayout(for: c.language), page: c.page,
                                    variant: c.field.layoutVariant, showLanguageKey: settings.activeLanguages.count > 1,
                                    returnKind: c.field.returnKind)
        let layout = LayoutFactory.layout(for: request)
        return (layout, LayoutGeometry.frames(for: layout, width: 393, metrics: .standard(height: .standard, landscape: false)))
    }

    @discardableResult
    private func touch(_ match: (KeySpec) -> Bool, slip: Character? = nil, text: String? = nil) -> Bool {
        let (layout, frames) = frames()
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
        case .insert(let inserted):
            let output = text ?? inserted
            controller.handle(.character(output, tap: key.isLetter ? tap : nil, isLetter: key.isLetter))
        case .space: controller.handle(.space)
        case .returnKey: controller.handle(.returnKey)
        case .switchPage(let page): controller.handle(.switchPage(page))
        default: return false
        }
        now += 0.15
        return true
    }

    private func longPress(_ ch: Character) -> Bool {
        let (_, frames) = frames()
        guard let key = frames.first(where: { $0.key.alternates.contains(String(ch)) })?.key else { return false }
        controller.handle(.character(String(ch), tap: nil, isLetter: key.isLetter))
        now += 0.6
        return true
    }

    private func press(_ ch: Character, slip: Character?) {
        let lower = Character(ch.lowercased())
        let upperText: String? = ch.isUppercase && ch != lower ? String(ch) : nil
        let match: (KeySpec) -> Bool
        switch ch {
        case " ": match = { $0.action == .space }
        case "\n": match = { $0.action == .returnKey }
        default: match = { $0.action == .insert(String(lower)) }
        }
        if touch(match, slip: slip, text: upperText) || longPress(ch) { return }
        for page in [LayoutPage.letters, .numbers, .symbols] where page != controller.page {
            if touch({ $0.action == .switchPage(page) }), touch(match, slip: slip, text: upperText) || longPress(ch) { return }
        }
        XCTFail("no key for \(ch)")
    }

    func type(_ text: String) {
        var chars = Array(text)[...]
        while let ch = chars.popFirst() {
            if ch == "{", let close = chars.firstIndex(of: "}") {
                let spec = Array(chars[chars.startIndex..<close])
                chars = chars[(close + 1)...]
                press(spec[0], slip: spec.count == 3 ? spec[2] : nil)
            } else {
                press(ch, slip: nil)
            }
        }
    }
}
