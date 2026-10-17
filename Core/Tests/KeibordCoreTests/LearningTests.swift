import XCTest
@testable import KeibordCore

final class LearningTests: XCTestCase {
    private let geometry = "qwertz11.letters.standard"

    private func commit(_ final: String, typed: String? = nil, previous: String? = nil, language: KeyboardLanguage? = .deAT,
                        taps: [TapInput]? = nil, corrected: Bool = false) -> LearningEvent {
        .committedWord(final: final, typed: typed ?? final, previous: previous, language: language, taps: taps, wasAutocorrected: corrected)
    }

    /// A tap that hit `character` at offset (dx, dy), with optional neighbouring candidates.
    private func tap(_ character: String, dx: Double = 0, dy: Double = 0, others: [TapCandidate] = [], geometry: String? = nil) -> TapInput {
        TapInput(candidates: [TapCandidate(character: character, cost: 0, dx: dx, dy: dy)] + others, touchModelKey: geometry ?? self.geometry)
    }

    // MARK: Recording events

    func testCommittedWordLearnsWordPairLanguageAndTouches() {
        var delta = UserModelDelta()
        XCTAssertTrue(delta.isEmpty)
        delta.record(commit("Paradeiser", previous: "Die", taps: "paradeiser".map { tap(String($0), dx: 0.1, dy: -0.1) }), day: 100)
        delta.record(commit("Paradeiser", previous: nil, language: nil), day: 102)
        XCTAssertFalse(delta.isEmpty)
        XCTAssertEqual(delta.words["Paradeiser"], LearnedWord(count: 2, lastUsedDay: 102, language: "de-AT"))
        XCTAssertEqual(delta.bigrams, [UserModel.bigramKey("die", "paradeiser"): 1])
        XCTAssertEqual(delta.languageUsage, ["de-AT": 1])
        // "paradeiser": 10 letters on 7 keys (a, r and e twice).
        XCTAssertEqual(delta.touch.count, 7)
        XCTAssertEqual(delta.touch["\(geometry)|a"]?.count, 2)
        XCTAssertEqual(delta.touch["\(geometry)|a"]?.sumDX ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(delta.touch["\(geometry)|a"]?.sumDY ?? 0, -0.2, accuracy: 1e-9)
    }

    func testLearningPolicy() {
        let learnable = ["ab", "leiwand", "Paradeiser", "don't", "geht’s", "l'amico", "E-Mail", "Hans'", "rock'n'roll", "Ende.",
                         "është", "çfarë", "perché", "Straße", "ÄÖÜ", "Lehrer:innen", String(repeating: "x", count: 40)]
        let notLearnable = ["", "a", "ë", "e\u{308}", "1", "abc1", "2nd", "4you", "x²", "max@mail.at", "@home", "http://orf.at",
                            "orf.at", "www.orf", "z.B.", "a/b", "C:\\Users", "'", "''", "--", "-'-", "...", "New York", "tab\there",
                            "line\nbreak", "a\u{0}b", "soft\u{AD}hyphen", String(repeating: "x", count: 41), "😀😀", "👍🏻"]
        for word in learnable { XCTAssertTrue(LearningPolicy.isLearnable(word), word) }
        for word in notLearnable { XCTAssertFalse(LearningPolicy.isLearnable(word), word.debugDescription) }

        // Nothing at all is recorded for an unlearnable word (no language usage, pairs or touches either).
        var delta = UserModelDelta()
        for word in notLearnable {
            delta.record(commit(word, previous: "Haus", taps: word.map { tap(String($0)) }))
            delta.record(.rejectedCorrection(typed: word, correction: word))
        }
        XCTAssertTrue(delta.isEmpty, "\(delta)")
    }

    func testUnlearnablePreviousWordRecordsNoPair() {
        var delta = UserModelDelta()
        delta.record(commit("Uhr", previous: "10"), day: 1)
        delta.record(commit("Uhr", previous: "a"), day: 1)
        delta.record(commit("Uhr", previous: "orf.at"), day: 1)
        XCTAssertEqual(delta.words["Uhr"]?.count, 3)
        XCTAssertTrue(delta.bigrams.isEmpty)
        // Bigram keys use lookup keys on both sides.
        delta.record(commit("Uhr", previous: "Drei"), day: 1)
        delta.record(commit("uhr", previous: "drei"), day: 1)
        XCTAssertEqual(delta.bigrams, ["drei\u{1F}uhr": 2])
    }

    func testAutocorrectedCommitLearnsTheFinalWordButNoTouches() {
        var delta = UserModelDelta()
        let taps = "hsus".map { tap(String($0), dx: 0.4, others: [TapCandidate(character: "a", cost: 1, dx: -0.6)]) }
        delta.record(commit("Haus", typed: "Hsus", taps: taps, corrected: true), day: 5)
        XCTAssertEqual(delta.words.keys.sorted(), ["Haus"])
        XCTAssertTrue(delta.touch.isEmpty)
    }

    func testPickedSuggestionRecordsTheIntendedKeysOffsets() {
        // Typed "tge", picked "the" from the bar: the second tap hit "g", but "h" was a candidate.
        var delta = UserModelDelta()
        let taps = [tap("t", dx: 0.1), tap("g", dx: 0.3, others: [TapCandidate(character: "h", cost: 2, dx: -0.7, dy: 0.1)]), tap("e", dy: 0.2)]
        delta.record(commit("the", typed: "tge", language: .enGB, taps: taps), day: 1)
        XCTAssertEqual(delta.touch["\(geometry)|h"], TouchStat(sumDX: -0.7, sumDY: 0.1, count: 1))
        XCTAssertNil(delta.touch["\(geometry)|g"])
        XCTAssertEqual(delta.touch.count, 3)
    }

    func testTouchAlignmentEdgeCases() {
        var delta = UserModelDelta()
        // Length mismatch (completion picked after two taps): nothing is recorded.
        delta.record(commit("Haus", taps: [tap("h"), tap("a")]))
        XCTAssertTrue(delta.touch.isEmpty)
        // Upper-case final word, typographic apostrophe: only letter keys are recorded.
        delta.record(commit("GEHT’S", taps: [tap("g"), tap("e"), tap("h"), tap("t"), tap("'"), tap("s")]))
        XCTAssertEqual(Set(delta.touch.keys), Set(["g", "e", "h", "t", "s"].map { "\(geometry)|\($0)" }))
        // Long-press insertions have no geometry; taps on another geometry are kept apart.
        delta = UserModelDelta()
        delta.record(commit("ëe", taps: [.exact("ë"), tap("e", geometry: "qwertz11.letters.tall")]))
        XCTAssertEqual(Array(delta.touch.keys), ["qwertz11.letters.tall|e"])
        // Non-finite offsets are ignored (they would make user-model.json unencodable) and far taps clamped.
        delta = UserModelDelta()
        delta.record(commit("ab", taps: [tap("a", dx: .nan, dy: 0), tap("b", dx: 1.5, dy: -.infinity)]))
        delta.record(commit("ab", taps: [tap("a", dx: 1.5, dy: -1.4), tap("b", dx: -0.2, dy: 0.1)]))
        XCTAssertEqual(delta.touch["\(geometry)|a"], TouchStat(sumDX: 1, sumDY: -1, count: 1))
        XCTAssertEqual(delta.touch["\(geometry)|b"], TouchStat(sumDX: -0.2, sumDY: 0.1, count: 1))
        var model = UserModel()
        model.apply(delta)
        XCTAssertNoThrow(try KeibordJSON.encoder().encode(model))
    }

    func testRejectedCorrectionLearnsTypedWordAndTakesBackTheCorrection() {
        var model = UserModel()
        model.apply({ var d = UserModelDelta(); for _ in 0..<3 { d.record(commit("Servus"), day: 1) }; return d }())
        XCTAssertEqual(model.words["Servus"]?.count, 3)

        // Autocorrect "Servas" → "Servus", then backspace: the keyboard records both events.
        var pending = UserModelDelta()
        pending.record(commit("Na"), day: 9)
        pending.record(commit("Servus", typed: "Servas", previous: "Na", corrected: true), day: 9)
        XCTAssertEqual(pending.bigrams, [UserModel.bigramKey("na", "servus"): 1])
        pending.record(.rejectedCorrection(typed: "Servas", correction: "Servus"), day: 9)
        XCTAssertNil(pending.words["Servus"], "commit and rejection cancel out")
        XCTAssertTrue(pending.bigrams.isEmpty, "the word pair is taken back too")
        XCTAssertEqual(pending.languageUsage, ["de-AT": 1], "only \"Na\" still counts")
        XCTAssertEqual(pending.words["Servas"], LearnedWord(count: 2, lastUsedDay: 9))
        var flushed = model
        flushed.apply(pending)
        XCTAssertEqual(flushed.words["Servus"], model.words["Servus"])
        XCTAssertEqual(flushed.words["Servas"]?.count, 2)
        XCTAssertTrue(flushed.knownWords().contains { $0.word == "Servas" }, "known immediately")

        // Undoing the same autocorrection again and again never makes it a known word.
        var fresh = UserModel()
        for day in 0..<5 {
            var d = UserModelDelta()
            d.record(commit("Oder", typed: "oda", corrected: true), day: day)
            d.record(.rejectedCorrection(typed: "oda", correction: "Oder"), day: day)
            fresh.apply(d)
        }
        XCTAssertNil(fresh.words["Oder"])
        XCTAssertTrue(fresh.bigrams.isEmpty && fresh.languageUsage.isEmpty)
        XCTAssertEqual(fresh.words["oda"]?.count, 10)

        // Picking the typed word while a correction is pending: the correction was never committed, so
        // a word the user really uses keeps its count (it used to lose one every time and could drop out
        // of the user lexicon).
        var delta = UserModelDelta()
        delta.record(commit("Servus"), day: 9)
        delta.record(commit("Haus", typed: "Huas", corrected: true), day: 9)
        delta.record(commit("da"), day: 9)
        delta.record(.rejectedCorrection(typed: "Servas", correction: "Servus"), day: 9)
        XCTAssertEqual(delta.words["Servus"]?.count, 1)
        XCTAssertEqual(delta.words["Haus"]?.count, 1, "an earlier autocorrection is not taken back")
        var kept = model
        kept.apply(delta)
        XCTAssertEqual(kept.words["Servus"]?.count, 4)
        // Only the autocorrection the rejection names is taken back, and only once.
        delta = UserModelDelta()
        delta.record(commit("Haus", typed: "Huas", corrected: true), day: 9)
        delta.record(.rejectedCorrection(typed: "Huas", correction: "Hand"), day: 9)
        delta.record(.rejectedCorrection(typed: "Huas", correction: "Haus"), day: 9)
        XCTAssertEqual(delta.words["Haus"]?.count, 1)
        // The keyboard also applies every event on its own to its in-memory model: there a rejection
        // cannot see the commit before it and takes nothing back (the file is right; reloading fixes it).
        var live = model
        for event in [commit("Servus", typed: "Servas", corrected: true), .rejectedCorrection(typed: "Servas", correction: "Servus")] {
            var single = UserModelDelta()
            single.record(event, day: 9)
            live.apply(single)
        }
        XCTAssertEqual(live.words["Servus"]?.count, 4)
        XCTAssertEqual(live.words["Servas"]?.count, 2)

        // Only casing differs: "Hallo" is taken back, "hallo" learned. Equality ignores what the delta
        // remembers about the last autocorrection.
        delta = UserModelDelta()
        delta.record(commit("Hallo", typed: "hallo", corrected: true), day: 3)
        delta.record(.rejectedCorrection(typed: "hallo", correction: "Hallo"), day: 3)
        XCTAssertEqual(delta.words, ["hallo": LearnedWord(count: 2, lastUsedDay: 3)])
        var rejectionOnly = UserModelDelta()
        rejectionOnly.record(.rejectedCorrection(typed: "hallo", correction: "Hallo"), day: 3)
        XCTAssertEqual(delta, rejectionOnly)
        // An unlearnable typed word: only the correction is taken back.
        delta = UserModelDelta()
        delta.record(commit("ex", typed: "x", corrected: true), day: 3)
        delta.record(.rejectedCorrection(typed: "x", correction: "ex"), day: 3)
        XCTAssertTrue(delta.isEmpty)

        // A negative word count in a delta lowers the stored count; manually added words stay.
        var negative = UserModelDelta()
        negative.words["Oder"] = LearnedWord(count: -1, lastUsedDay: 0)
        fresh.apply({ var d = UserModelDelta(); d.record(commit("Oder"), day: 3); return d }())
        fresh.apply(negative)
        XCTAssertNil(fresh.words["Oder"])
        fresh.apply(negative)
        XCTAssertNil(fresh.words["Oder"], "never created by a negative count")
        fresh.addWord("Oder")
        for _ in 0..<5 { fresh.apply(negative) }
        XCTAssertEqual(fresh.words["Oder"]?.addedManually, true)
        XCTAssertEqual(fresh.words["Oder"]?.count, 0)
        XCTAssertTrue(fresh.knownWords().contains { $0.word == "Oder" })
    }


    /// The events of the real input controller, recorded like the keyboard does.
    func testRejectionsFromTheInputControllerOnlyTakeBackCommittedCorrections() {
        func run(_ actions: (InputController, (String) -> Void) -> Void) -> UserModelDelta {
            let doc = MockDocument()
            let sink = Sink()
            var settings = KeibordSettings()
            settings.enabledLanguages = [.enGB]
            let controller = InputController(document: doc, engine: FakeEngine(), settings: settings, language: .enGB, clock: { 0 })
            controller.learningSink = sink
            controller.configure(field: FieldContext(autocapitalization: .none))
            actions(controller) { text in
                for ch in text {
                    controller.handle(ch == " " ? .space : .character(String(ch), tap: nil, isLetter: ch.isLetter))
                }
            }
            var delta = UserModelDelta()
            for event in sink.events { delta.record(event, day: 7) }
            return delta
        }
        var model = UserModel()
        model.words["the"] = LearnedWord(count: 2, lastUsedDay: 1)

        // "teh " is autocorrected to "the", then backspace restores "teh".
        let undone = run { _, type in type("teh ") }
        XCTAssertEqual(undone.words["the"]?.count, 1)
        let undoneThenRejected = run { c, type in
            type("teh ")
            c.handle(.backspace)
            type(" ")
        }
        XCTAssertNil(undoneThenRejected.words["the"], "the autocorrection is taken back")
        XCTAssertEqual(undoneThenRejected.words["teh"]?.count, 3)

        // The literal "teh" is picked while "the" is pending: "the" was never committed.
        let picked = run { c, type in
            type("teh")
            c.handle(.suggestion(Suggestion(text: "teh", display: "“teh”", kind: .typed)))
        }
        XCTAssertEqual(picked.words, ["teh": LearnedWord(count: 3, lastUsedDay: 7, language: "en-GB")])
        var after = model
        after.apply(picked)
        XCTAssertEqual(after.words["the"]?.count, 2, "a learned word keeps its count")
        XCTAssertTrue(after.knownWords().contains { $0.word == "the" })
    }

    func testEmojiAndLanguageSwitchEvents() {
        var delta = UserModelDelta()
        delta.record(.switchedLanguage(.sqXK))
        delta.record(.usedEmoji(""))
        XCTAssertTrue(delta.isEmpty)
        delta.record(.usedEmoji("😂"), now: 100)
        delta.record(.usedEmoji("😂"), now: 50)
        delta.record(.usedEmoji("❤️"), now: 70)
        XCTAssertEqual(delta.emoji["😂"], EmojiStat(count: 2, lastUsed: 100))
        var model = UserModel()
        model.emoji["😂"] = EmojiStat(count: 5, lastUsed: 200)
        model.apply(delta)
        XCTAssertEqual(model.emoji["😂"], EmojiStat(count: 7, lastUsed: 200))
        XCTAssertEqual(model.emojiRecents, ["😂", "❤️"])
    }

    // MARK: Applying, pruning, merging

    func testApplyNeverResurrectsBlockedWords() {
        var model = UserModel()
        model.apply({ var d = UserModelDelta(); d.record(commit("leiwand", previous: "voll"), day: 1); return d }())
        model.block("Leiwand")
        XCTAssertTrue(model.words.isEmpty)
        XCTAssertTrue(model.bigrams.isEmpty, "blocking removes the word's pairs")
        var delta = UserModelDelta()
        delta.record(commit("leiwand", previous: "voll"), day: 2)
        delta.record(commit("Leiwand", previous: nil), day: 2)
        delta.record(commit("LEIWAND", previous: nil), day: 2)
        delta.record(commit("Party", previous: "leiwand"), day: 2)
        delta.record(.rejectedCorrection(typed: "leiwand", correction: "Leinwand"), day: 2)
        model.apply(delta)
        XCTAssertEqual(model.words.keys.sorted(), ["Party"])
        XCTAssertTrue(model.bigrams.isEmpty)
        XCTAssertTrue(model.knownWords().allSatisfy { TextUnits.lookupKey($0.word) != "leiwand" })
        model.unblock("leiwand")
        model.apply(delta)
        XCTAssertEqual(model.words["leiwand"]?.count, 3)
        XCTAssertEqual(model.bigrams.count, 2)
    }

    func testPruneLimitsAndOrdering() {
        var model = UserModel()
        model.words = [
            "manual": LearnedWord(count: 0, lastUsedDay: 1, addedManually: true),
            "often": LearnedWord(count: 9, lastUsedDay: 1),
            "recent": LearnedWord(count: 2, lastUsedDay: 50),
            "older": LearnedWord(count: 2, lastUsedDay: 10),
            "tieB": LearnedWord(count: 1, lastUsedDay: 5),
            "tieA": LearnedWord(count: 1, lastUsedDay: 5),
        ]
        var pruned = model
        pruned.prune(maxWords: 4)
        XCTAssertEqual(pruned.words.keys.sorted(), ["manual", "often", "older", "recent"])
        pruned = model
        pruned.prune(maxWords: 5)
        XCTAssertEqual(pruned.words.keys.sorted(), ["manual", "often", "older", "recent", "tieA"], "ties are broken by key")
        pruned = model
        pruned.prune(maxWords: 6)
        XCTAssertEqual(pruned.words, model.words)
        pruned.prune(maxWords: 0)
        XCTAssertTrue(pruned.words.isEmpty)

        model.bigrams = ["a\u{1F}b": 3, "a\u{1F}c": 1, "b\u{1F}c": 1, "c\u{1F}d": 2]
        model.emoji = ["😀": EmojiStat(count: 9, lastUsed: 1), "😂": EmojiStat(count: 1, lastUsed: 3), "❤️": EmojiStat(count: 1, lastUsed: 2)]
        model.touch = ["g|a": TouchStat(sumDX: 80.2, sumDY: -40.4, count: 401), "g|b": TouchStat(sumDX: 1, sumDY: 1, count: 400)]
        model.prune(maxWords: 100, maxBigrams: 3, maxEmoji: 2)
        XCTAssertEqual(model.bigrams, ["a\u{1F}b": 3, "c\u{1F}d": 2, "a\u{1F}c": 1])
        XCTAssertEqual(Set(model.emoji.keys), ["😂", "❤️"], "the most recently used emoji are kept")
        XCTAssertEqual(model.touch["g|a"]?.count, 200)
        // Halving keeps the mean exactly (halving the sums of 401 samples but keeping 200 moved it).
        XCTAssertEqual(model.touch["g|a"]?.meanDX ?? 0, 80.2 / 401, accuracy: 1e-12)
        XCTAssertEqual(model.touch["g|a"]?.meanDY ?? 0, -40.4 / 401, accuracy: 1e-12)
        XCTAssertEqual(model.touch["g|b"], TouchStat(sumDX: 1, sumDY: 1, count: 400))
    }

    func testMergedSemantics() {
        var mine = UserModel()
        mine.words = ["Haus": LearnedWord(count: 3, lastUsedDay: 10, language: "de-AT"),
                      "pinned": LearnedWord(count: 2, lastUsedDay: 1, addedManually: true),
                      "oida": LearnedWord(count: 4, lastUsedDay: 2)]
        mine.bigrams = ["das\u{1F}haus": 2, "oida\u{1F}geh": 1]
        mine.blocked = ["fuck"]
        mine.touch = ["g|a": TouchStat(sumDX: 1, sumDY: 2, count: 3)]
        mine.emoji = ["😂": EmojiStat(count: 2, lastUsed: 100)]
        mine.languageUsage = ["de-AT": 10]

        var theirs = UserModel()
        theirs.words = ["Haus": LearnedWord(count: 2, lastUsedDay: 20, language: nil),
                        "pinned": LearnedWord(count: 5, lastUsedDay: 30),
                        "Paradeiser": LearnedWord(count: 0, lastUsedDay: 3, addedManually: true),
                        "Fuck": LearnedWord(count: 7, lastUsedDay: 3),
                        "zero": LearnedWord(count: 0, lastUsedDay: 3)]
        theirs.bigrams = ["das\u{1F}haus": 1, "geh\u{1F}oida": 5, "so\u{1F}fuck": 1]
        theirs.blocked = ["oida"]
        theirs.touch = ["g|a": TouchStat(sumDX: 1, sumDY: 1, count: 1), "g|b": TouchStat(sumDX: 0.5, sumDY: 0, count: 2)]
        theirs.emoji = ["😂": EmojiStat(count: 1, lastUsed: 50), "❤️": EmojiStat(count: 1, lastUsed: 70)]
        theirs.languageUsage = ["de-AT": 5, "sq-XK": 2]

        let merged = mine.merged(with: theirs)
        XCTAssertEqual(merged.words["Haus"], LearnedWord(count: 5, lastUsedDay: 20, language: "de-AT"))
        XCTAssertEqual(merged.words["pinned"], LearnedWord(count: 7, lastUsedDay: 30, addedManually: true))
        XCTAssertEqual(merged.words["Paradeiser"], LearnedWord(count: 0, lastUsedDay: 3, addedManually: true))
        XCTAssertNil(merged.words["Fuck"], "blocked on this device")
        XCTAssertNil(merged.words["oida"], "blocked on the other device")
        XCTAssertNil(merged.words["zero"])
        XCTAssertEqual(merged.blocked, ["fuck", "oida"])
        XCTAssertEqual(merged.bigrams, ["das\u{1F}haus": 3])
        XCTAssertEqual(merged.touch["g|a"], TouchStat(sumDX: 2, sumDY: 3, count: 4))
        XCTAssertEqual(merged.touch["g|b"], TouchStat(sumDX: 0.5, sumDY: 0, count: 2))
        XCTAssertEqual(merged.emoji["😂"], EmojiStat(count: 3, lastUsed: 100))
        XCTAssertEqual(merged.emoji["❤️"], EmojiStat(count: 1, lastUsed: 70))
        XCTAssertEqual(merged.languageUsage, ["de-AT": 15, "sq-XK": 2])
        XCTAssertEqual(mine.words.count, 3, "merging does not change the receiver")
        // Merging with an empty model changes nothing; the merge is symmetric for counts.
        XCTAssertEqual(mine.merged(with: UserModel()), mine)
        XCTAssertEqual(theirs.merged(with: mine).words.filter { $0.key != "zero" }, merged.words)
    }

    // MARK: Derived data

    func testKnownWordsMergesCasingsAndClampsZipf() {
        var model = UserModel()
        model.words = [
            "Leiwand": LearnedWord(count: 1, lastUsedDay: 1),
            "leiwand": LearnedWord(count: 1, lastUsedDay: 1),
            "Paradeiser": LearnedWord(count: 5, lastUsedDay: 1),
            "paradeiser": LearnedWord(count: 1, lastUsedDay: 1),
            "Heuriger": LearnedWord(count: 0, lastUsedDay: 1, addedManually: true),
            "heuriger": LearnedWord(count: 3, lastUsedDay: 1),
            "einmal": LearnedWord(count: 1, lastUsedDay: 1),
            "oft": LearnedWord(count: 50_000_000, lastUsedDay: 1),
            "Fuck": LearnedWord(count: 9, lastUsedDay: 1),
            "geht's": LearnedWord(count: 1, lastUsedDay: 1),
            "geht’s": LearnedWord(count: 2, lastUsedDay: 1),
        ]
        model.blocked = ["fuck"]
        let known = model.knownWords()
        let byWord = Dictionary(uniqueKeysWithValues: known.map { ($0.word, $0.zipf) })
        XCTAssertEqual(Set(byWord.keys), ["leiwand", "Paradeiser", "Heuriger", "oft", "geht’s"])
        XCTAssertEqual(byWord["leiwand"] ?? 0, 3 + log10(2), accuracy: 1e-9, "two casings used once each make the word known")
        XCTAssertEqual(byWord["Paradeiser"] ?? 0, 3 + log10(6), accuracy: 1e-9)
        XCTAssertEqual(byWord["Heuriger"] ?? 0, 3 + log10(5), accuracy: 1e-9, "the manual casing wins and weighs as known")
        XCTAssertEqual(byWord["oft"], 6)
        XCTAssertEqual(byWord["geht’s"] ?? 0, 3 + log10(3), accuracy: 1e-9)
        for entry in known { XCTAssertTrue((3 + log10(2) - 1e-9)...6 ~= entry.zipf, entry.word) }
        XCTAssertEqual(known.map(\.word), ["oft", "Paradeiser", "Heuriger", "geht’s", "leiwand"], "sorted by zipf, then word")
        XCTAssertEqual(model.knownWords(minCount: 1).count, 6)
        XCTAssertEqual(model.knownWords(minCount: 100).map(\.word), ["oft", "Heuriger"])
        // The result does not depend on dictionary order.
        for _ in 0..<5 {
            var copy = UserModel()
            for (k, v) in model.words.shuffled() { copy.words[k] = v }
            copy.blocked = model.blocked
            XCTAssertEqual(copy.knownWords().map(\.word), known.map(\.word))
        }
        // The manual form wins even when used less; on equal use lower case wins over capitalised.
        var tie = UserModel()
        tie.words = ["Semmel": LearnedWord(count: 2, lastUsedDay: 1, addedManually: true), "semmel": LearnedWord(count: 7, lastUsedDay: 1)]
        XCTAssertEqual(tie.knownWords().map(\.word), ["Semmel"])
        tie.words["semmel"]?.count = 2
        tie.words["Semmel"]?.addedManually = false
        XCTAssertEqual(tie.knownWords().map(\.word), ["semmel"])
    }

    func testKnownWordsBuildAUserLexicon() {
        var model = UserModel()
        model.addWord("Paradeiser")
        model.apply({ var d = UserModelDelta(); for _ in 0..<3 { d.record(commit("Fisolen")) }; return d }())
        let lexicon = InMemoryLexicon(languageID: "user", entries: model.knownWords())
        XCTAssertEqual(lexicon.wordCount, 2)
        XCTAssertEqual(lexicon.lookup(key: "paradeiser").map(lexicon.word), ["Paradeiser"])
        XCTAssertEqual(lexicon.word(0), "Fisolen")
    }

    func testTouchOffsetsClampingAndMinSamples() {
        var model = UserModel()
        model.touch = [
            "geo|a": TouchStat(sumDX: 1.2, sumDY: -1.2, count: 12),
            "geo|s": TouchStat(sumDX: 12, sumDY: -12, count: 12),
            "geo|d": TouchStat(sumDX: 1, sumDY: 1, count: 11),
            "geo|f": TouchStat(sumDX: .nan, sumDY: 0, count: 20),
            "geo2|a": TouchStat(sumDX: 1.2, sumDY: 1.2, count: 12),
            "geo|": TouchStat(sumDX: 0, sumDY: 0, count: 0),
        ]
        let offsets = model.touchOffsets(for: "geo")
        XCTAssertEqual(Set(offsets.keys), ["a", "s"])
        XCTAssertEqual(offsets["a"]?.dx ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(offsets["a"]?.dy ?? 0, -0.1, accuracy: 1e-9)
        XCTAssertEqual(offsets["s"]?.dx, 0.25)
        XCTAssertEqual(offsets["s"]?.dy, -0.25)
        XCTAssertEqual(Set(model.touchOffsets(for: "geo", minSamples: 11).keys), ["a", "s", "d"])
        XCTAssertEqual(Set(model.touchOffsets(for: "geo", minSamples: 0).keys), ["a", "s", "d"], "keys without samples are never returned")
        XCTAssertEqual(Set(model.touchOffsets(for: "geo2").keys), ["a"])
        XCTAssertTrue(model.touchOffsets(for: "ge").isEmpty, "the geometry must match exactly")
        XCTAssertEqual(model.touchSampleCount, 67)
        model.resetTouch()
        XCTAssertTrue(model.touch.isEmpty)
    }

    func testAddRemoveBlockUnblock() {
        var model = UserModel()
        model.addWord("  Paradeiser \n", day: 7)
        XCTAssertEqual(model.words["Paradeiser"], LearnedWord(count: 2, lastUsedDay: 7, addedManually: true))
        model.addWord("   ")
        XCTAssertEqual(model.words.count, 1)
        model.words["Topfen"] = LearnedWord(count: 5, lastUsedDay: 3)
        model.addWord("Topfen", day: 9)
        XCTAssertEqual(model.words["Topfen"], LearnedWord(count: 5, lastUsedDay: 3, addedManually: true))

        model.words["haus"] = LearnedWord(count: 1, lastUsedDay: 1)
        model.words["Haus"] = LearnedWord(count: 4, lastUsedDay: 1)
        model.bigrams = ["das\u{1F}haus": 3, "haus\u{1F}tür": 1, "das\u{1F}auto": 2, "haushalt\u{1F}geld": 1]
        model.removeWord("Haus")
        XCTAssertNil(model.words["Haus"])
        XCTAssertEqual(model.bigrams.count, 4, "another casing is still learned")
        model.removeWord("haus")
        XCTAssertEqual(model.bigrams, ["das\u{1F}auto": 2, "haushalt\u{1F}geld": 1])
        model.removeWord("nichtda")
        XCTAssertEqual(model.bigrams.count, 2)

        model.block(" Auto ")
        XCTAssertEqual(model.blocked, ["auto"])
        XCTAssertEqual(model.bigrams, ["haushalt\u{1F}geld": 1])
        model.block("")
        XCTAssertEqual(model.blocked, ["auto"])
        model.block("Topfen")
        XCTAssertNil(model.words["Topfen"], "blocking removes manual words too")
        model.unblock("TOPFEN")
        XCTAssertEqual(model.blocked, ["auto"])
        model.addWord("Auto")
        XCTAssertTrue(model.blocked.isEmpty, "adding a word unblocks it")
        XCTAssertEqual(model.words["Auto"]?.addedManually, true)
    }

    func testEmojiRecentsOrdering() {
        var model = UserModel()
        for i in 0..<40 {
            model.emoji[String(UnicodeScalar(0x1F600 + i)!)] = EmojiStat(count: 1, lastUsed: Double(i))
        }
        let recents = model.emojiRecents
        XCTAssertEqual(recents.count, 32)
        XCTAssertEqual(recents.first, String(UnicodeScalar(0x1F600 + 39)!))
        XCTAssertEqual(recents.last, String(UnicodeScalar(0x1F600 + 8)!))
        var tie = UserModel()
        tie.emoji = ["😀": EmojiStat(count: 1, lastUsed: 5), "😂": EmojiStat(count: 3, lastUsed: 5), "❤️": EmojiStat(count: 1, lastUsed: 5)]
        XCTAssertEqual(tie.emojiRecents, ["😂", "❤️", "😀"])
    }
}
