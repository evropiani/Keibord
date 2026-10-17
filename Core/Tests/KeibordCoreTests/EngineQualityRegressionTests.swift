import XCTest
@testable import KeibordCore

/// Regressions found while testing the input controller with the owner's four languages
/// ([de-AT, en-GB, sq-XK, it-IT]), against the real bundled dictionaries.
final class EngineQualityRegressionTests: XCTestCase {
    private let four: [KeyboardLanguage] = [.deAT, .enGB, .sqXK, .itIT]

    private func engine() throws -> SuggestionEngine {
        guard EngineQualityHarness.available else { throw XCTSkip("dictionaries not built") }
        return EngineQualityHarness.shared.makeEngine()
    }

    /// The autocorrection for `word`, after the words of `previous` were typed and committed like the input
    /// controller does ("cfare>çfarë": typed without accents, committed corrected).
    private func correct(_ e: SuggestionEngine, _ word: String, after previous: [String] = [], sentenceStart: Bool = false,
                         _ languages: [KeyboardLanguage], accents: Bool = true) -> String? {
        var committed: [String] = []
        for p in previous {
            let parts = p.components(separatedBy: ">")
            let final = parts.last!
            _ = e.suggest(SuggestionQuery(currentWord: parts[0], languages: languages))
            e.noteCommitted(word: final, language: e.likelyLanguage(of: final, among: languages))
            committed.append(final)
        }
        let q = SuggestionQuery(currentWord: word, previousWords: committed.suffix(2), isSentenceStart: sentenceStart,
                                languages: languages, accentRestoration: accents)
        return e.suggest(q).autocorrection?.text
    }

    // MARK: Accent restoration of words valid in another enabled language

    func testAccentRestorationWhenTheBareFormIsARareWordOfAnotherLanguage() throws {
        XCTAssertEqual(correct(try engine(), "mire", after: ["është"], four), "mirë", "mire is English (a bog)")
        XCTAssertEqual(correct(try engine(), "Une", sentenceStart: true, four), "Unë", "une is a rare English / Italian word")
        XCTAssertEqual(correct(try engine(), "une", after: ["po"], four), "unë")
        XCTAssertEqual(correct(try engine(), "jane", after: ["këto"], four), "janë", "not the name Jane")
        XCTAssertEqual(correct(try engine(), "keto", four), "këto")
        XCTAssertEqual(correct(try engine(), "uber", after: ["reden"], four), "über", "uber is English / Italian")
        XCTAssertEqual(correct(try engine(), "Uber", sentenceStart: true, four), "Über")
        XCTAssertEqual(correct(try engine(), "fur", after: ["danke"], four), "für", "fur is English")
        XCTAssertEqual(correct(try engine(), "per", after: ["faleminderit"], four), "për", "per is Italian, but the message is Albanian")
        XCTAssertEqual(correct(try engine(), "ben", after: ["cfare>çfarë", "po"], four), "bën")
        XCTAssertEqual(correct(try engine(), "mire", after: ["eshte>është"], four), "mirë")
    }

    func testValidWordsOfTheLanguageBeingWrittenStay() throws {
        XCTAssertNil(correct(try engine(), "ate", after: ["I"], [.enGB, .deAT, .sqXK, .itIT]), "English keyboard: not the Albanian atë")
        XCTAssertNil(correct(try engine(), "ate", after: ["we"], four), "English context: not the Albanian atë")
        XCTAssertNil(correct(try engine(), "here", after: ["come"], four))
        XCTAssertNil(correct(try engine(), "per", after: ["grazie"], four), "Italian per")
        XCTAssertNil(correct(try engine(), "per", after: ["nur"], four), "German per")
        XCTAssertNil(correct(try engine(), "mire", after: ["the"], [.enGB, .sqXK]), "English context: the bog")
        XCTAssertNil(correct(try engine(), "ne", [.itIT]), "Italian ne")
        XCTAssertNil(correct(try engine(), "e", after: ["pane"], [.itIT]), "Italian and")
        XCTAssertNil(correct(try engine(), "së", [.sqXK]), "accents are never removed")
        XCTAssertNil(correct(try engine(), "ketë", [.sqXK]), "someone typing accents typed this word as meant")
        XCTAssertNil(correct(try engine(), "Mire", after: ["Senad", "and"], four), "a capitalised word in mid-sentence may be a name")
        XCTAssertNil(correct(try engine(), "mire", four, accents: false), "accent restoration switched off")
    }

    /// Same-language pairs where both forms are frequent ("ne" we / "në" in, "te" at / "të") stay as typed
    /// for a new user: they are among the 300 most frequent Albanian words and the dictionary has no
    /// Albanian bigrams. Learned context restores them.
    func testAlbanianValidBareFormsNeedContext() throws {
        let fresh = try engine()
        XCTAssertNil(correct(fresh, "ne", [.sqXK]))
        XCTAssertNil(correct(fresh, "te", [.sqXK]))
        XCTAssertNil(correct(fresh, "me", [.sqXK]))

        // The user wrote "jam në" before: the learned bigram decides.
        let learned = try engine()
        var model = UserModel()
        model.bigrams["jam" + String(UserModel.bigramSeparator) + "në"] = 3
        learned.setUserModel(model)
        XCTAssertEqual(correct(learned, "ne", after: ["jam"], [.sqXK]), "në")

        // A user who leaves out "ë" all the time gets "të" for "te" (but "me" stays: "më" is barely more frequent).
        let omitter = try engine()
        XCTAssertGreaterThan(omitter.accentOmissionCost(.sqXK), 1.5)
        for (typed, final) in [("eshte", "është"), ("shume", "shumë"), ("pershendetje", "përshëndetje"), ("mire", "mirë"), ("une", "unë"),
                               ("nje", "një"), ("vetem", "vetëm"), ("keshtu", "kështu"), ("neser", "nesër"), ("shtepi", "shtëpi"),
                               ("kete", "këtë"), ("gjithe", "gjithë")] {
            _ = omitter.suggest(SuggestionQuery(currentWord: typed, languages: [.sqXK]))
            omitter.noteCommitted(word: final, language: .sqXK)
        }
        XCTAssertLessThan(omitter.accentOmissionCost(.sqXK), 0.3)
        XCTAssertEqual(correct(omitter, "te", [.sqXK]), "të")
        XCTAssertNil(correct(omitter, "me", [.sqXK]))
        // Typing accents again moves the estimate back.
        for _ in 0..<20 {
            _ = omitter.suggest(SuggestionQuery(currentWord: "është", languages: [.sqXK]))
            omitter.noteCommitted(word: "është", language: .sqXK)
        }
        XCTAssertGreaterThan(omitter.accentOmissionCost(.sqXK), 1)
        XCTAssertNil(correct(omitter, "te", [.sqXK]))
    }

    // MARK: Italian elision

    func testItalianElidedVerb() throws {
        XCTAssertEqual(correct(try engine(), "e", after: ["c'"], [.itIT]), "è")
        XCTAssertEqual(correct(try engine(), "e", after: ["dov\u{2019}"], four), "è")
        XCTAssertEqual(correct(try engine(), "e", after: ["com'"], [.itIT, .deAT]), "è")
        XCTAssertNil(correct(try engine(), "e", after: ["c'"], [.itIT], accents: false))
        XCTAssertNil(correct(try engine(), "e", after: ["c'"], [.deAT, .enGB]), "Italian not enabled")
    }

    func testItalianElidedVerbThroughTheInputController() throws {
        try XCTSkipUnless(EngineQualityHarness.available)
        var settings = KeibordSettings()
        settings.enabledLanguages = four
        let typist = SentenceTypist(settings, language: .itIT)
        typist.type("c'e un problema, dov'e la stazione? ")
        XCTAssertEqual(typist.doc.text, "C\u{2019}è un problema, dov\u{2019}è la stazione? ")
    }

    // MARK: Abbreviations, slang

    func testChatAbbreviationsAreKnownAndKept() throws {
        let e = try engine()
        for languages in [four, [.deAT], [.enGB], [.sqXK], [.itIT]] as [[KeyboardLanguage]] {
            for word in ["lol", "ok", "omg", "btw", "thx"] {
                XCTAssertTrue(e.isKnownWord(word, languages: languages), "\(word) \(languages)")
                XCTAssertNil(correct(e, word, languages), "\(word) \(languages)")
            }
        }
        for (word, language) in [("usw", KeyboardLanguage.deAT), ("bzw", .deAT), ("zb", .deAT), ("evtl", .deAT), ("vllt", .deAT), ("grad", .deAT),
                                 ("etc", .enGB), ("idk", .enGB), ("tbh", .enGB), ("flm", .sqXK), ("dmth", .sqXK), ("cmq", .itIT), ("xke", .itIT)] {
            XCTAssertTrue(e.isKnownWord(word, languages: [language]), word)
            XCTAssertNil(correct(e, word, [language]), word)
            XCTAssertNil(correct(e, word, [language] + four.filter { $0 != language }), "\(word) with four languages")
        }
        XCTAssertNil(correct(e, "usw", four), "not 'us'")
        XCTAssertNil(correct(e, "grad", after: ["hab"], four), "colloquial gerade, not Grad")
    }

    // MARK: German nouns

    func testGermanNounsAreCapitalisedWithOtherLanguagesEnabled() throws {
        XCTAssertEqual(correct(try engine(), "zeit", four), "Zeit")
        XCTAssertEqual(correct(try engine(), "zeit", after: ["keine"], four), "Zeit")
        XCTAssertEqual(correct(try engine(), "berg", after: ["der"], four), "Berg", "berg is English")
        XCTAssertEqual(correct(try engine(), "quatsch", after: ["so", "ein"], four), "Quatsch")
        XCTAssertEqual(correct(try engine(), "quatsch", after: ["ist"], four), "Quatsch")
        XCTAssertEqual(correct(try engine(), "ende", after: ["bis", "zum"], four), "Ende", "ende is Albanian")
        XCTAssertEqual(correct(try engine(), "schule", after: ["in", "der"], [.deAT]), "Schule")
        XCTAssertEqual(correct(try engine(), "wetter", after: ["das"], four), "Wetter")
        XCTAssertEqual(correct(try engine(), "angst", after: ["keine"], [.deAT]), "Angst")
        XCTAssertEqual(correct(try engine(), "dank", after: ["vielen"], four), "Dank")
        XCTAssertEqual(correct(try engine(), "haus", after: ["das"], four), "Haus")
    }

    func testGermanLowerCaseTwinsStayWhenMeant() throws {
        XCTAssertNil(correct(try engine(), "sorge", after: ["ich"], [.deAT]), "verb after a pronoun")
        XCTAssertNil(correct(try engine(), "essen", after: ["wir"], [.deAT]))
        XCTAssertNil(correct(try engine(), "essen", [.deAT]))
        XCTAssertNil(correct(try engine(), "arm", after: ["bist"], [.deAT]), "adjective")
        XCTAssertNil(correct(try engine(), "null", after: ["habe"], [.deAT]))
        XCTAssertNil(correct(try engine(), "leid", after: ["mir"], [.deAT]), "tut mir leid")
        XCTAssertNil(correct(try engine(), "baba", after: ["ok"], [.deAT]), "Austrian bye")
        XCTAssertNil(correct(try engine(), "zeit", after: ["ich"], [.deAT]), "after a pronoun the twin may be meant")
    }

    func testPredictionsShowGermanNounCasing() throws {
        let e = try engine()
        let r = e.suggest(SuggestionQuery(currentWord: "", previousWords: ["keine"], languages: [.deAT]))
        let texts = r.suggestions.map(\.text)
        XCTAssertFalse(texts.contains("zeit"), "\(texts)")
        XCTAssertFalse(texts.contains("angst"), "\(texts)")
    }

    /// Bigrams are stored under the most frequent form of a key, but apply to all its casings.
    func testBigramsApplyToEveryCasing() throws {
        let e = try engine()
        let q = SuggestionQuery(currentWord: "zeit", previousWords: ["keine"], languages: [.deAT])
        let ranked = e.rankedCandidates(q, languages: [.deAT])
        let lower = try XCTUnwrap(ranked.first { $0.text == "zeit" })
        let upper = try XCTUnwrap(ranked.first { $0.text == "Zeit" })
        XCTAssertLessThan(abs(lower.score - upper.score), 3, "Zeit gets the bigram of zeit")
    }

    // MARK: Cross-language corrections and respellings

    func testCrossLanguageCorrections() throws {
        XCTAssertEqual(correct(try engine(), "teh", four), "the", "teh is a rare Albanian word")
        XCTAssertEqual(correct(try engine(), "teh", after: ["I", "think"], four), "the")
        XCTAssertEqual(correct(try engine(), "shes", after: ["don't", "know", "where"], [.enGB, .deAT, .sqXK, .itIT]), "she's")
        XCTAssertNil(correct(try engine(), "teh", [.sqXK, .enGB]), "Albanian keyboard: the Albanian word")
        XCTAssertNil(correct(try engine(), "Dardan", after: ["mit"], [.deAT, .enGB, .sqXK]), "a name, not Daran")
    }

    func testGermanRespellings() throws {
        XCTAssertEqual(correct(try engine(), "gruss", [.deAT]), "Gruß")
        XCTAssertEqual(correct(try engine(), "gruss", four), "Gruß")
        XCTAssertEqual(correct(try engine(), "Strasse", after: ["die"], four), "Straße", "strasse is a rare Italian word")
        XCTAssertEqual(correct(try engine(), "gross", after: ["ist", "sehr"], four), "groß", "gross is English")
        XCTAssertEqual(correct(try engine(), "weiss", after: ["ich"], four), "weiß")
        XCTAssertNil(correct(try engine(), "gross", after: ["that's"], four), "English gross")
    }
}
