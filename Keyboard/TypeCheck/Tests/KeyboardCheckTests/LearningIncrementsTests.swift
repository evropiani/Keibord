import XCTest
import KeibordCore
@testable import KeyboardCheck

/// Mirrors KeyboardViewController's learning bookkeeping: pending delta + in-memory model, flushed to a "disk" model.
private struct LearningBookkeeping {
    var disk: UserModel
    var memory: UserModel
    var pending = UserModelDelta()
    var events = 0
    var oldStyleMemory: UserModel

    init(base: UserModel) {
        disk = base
        memory = base
        oldStyleMemory = base
    }

    mutating func record(_ event: LearningEvent, flushEvery: Int = 25) {
        // Old approach: a fresh one-event delta.
        var single = UserModelDelta()
        single.record(event, day: 100, now: 1)
        oldStyleMemory.apply(single)
        // New approach.
        let before = pending
        pending.record(event, day: 100, now: 1)
        let inc = pending.increments(since: before)
        guard !inc.isEmpty else { return }
        memory.apply(inc)
        events += 1
        if events >= flushEvery {
            if case .committedWord(_, _, _, _, _, true) = event { return }
            flush()
        }
    }

    mutating func flush() {
        disk.apply(pending)
        pending = UserModelDelta()
        events = 0
    }
}

private func tap(_ c: String) -> TapInput {
    TapInput(candidates: [TapCandidate(character: c, cost: 0.1, dx: 0.1, dy: -0.05)], touchModelKey: "qwertz11.letters")
}


/// Equal counts, word pairs, language usage, emoji counts and touch statistics (sums up to rounding).
/// `lastUsedDay`/`language` of a word whose increment was taken back may differ: neither affects suggestions.
private func assertSameLearning(_ a: UserModel, _ b: UserModel, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.words.mapValues { $0.count }, b.words.mapValues { $0.count }, file: file, line: line)
    XCTAssertEqual(a.bigrams, b.bigrams, file: file, line: line)
    XCTAssertEqual(a.languageUsage.filter { $0.value != 0 }, b.languageUsage.filter { $0.value != 0 }, file: file, line: line)
    XCTAssertEqual(a.emoji.mapValues { $0.count }, b.emoji.mapValues { $0.count }, file: file, line: line)
    XCTAssertEqual(Set(a.touch.keys), Set(b.touch.keys), file: file, line: line)
    for (k, t) in a.touch {
        guard let u = b.touch[k] else { continue }
        XCTAssertEqual(t.count, u.count, file: file, line: line)
        XCTAssertEqual(t.sumDX, u.sumDX, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(t.sumDY, u.sumDY, accuracy: 1e-9, file: file, line: line)
    }
}

private func sameLearning(_ a: UserModel, _ b: UserModel) -> Bool {
    a.words.mapValues { $0.count } == b.words.mapValues { $0.count } && a.bigrams == b.bigrams
}

final class LearningIncrementsTests: XCTestCase {
    func commit(_ final: String, typed: String? = nil, previous: String?, auto: Bool = false, taps: Bool = true) -> LearningEvent {
        .committedWord(final: final, typed: typed ?? final, previous: previous, language: .deAT,
                       taps: taps ? final.map { tap(String($0)) } : nil, wasAutocorrected: auto)
    }

    func testRejectedAutocorrectionIsRetractedInMemoryLikeOnDisk() {
        var base = UserModel()
        base.words["Haus"] = LearnedWord(count: 1, lastUsedDay: 90)
        var kb = LearningBookkeeping(base: base)
        kb.record(commit("ein", previous: nil))
        kb.record(commit("Haus", typed: "Hais", previous: "ein", auto: true))
        kb.record(.rejectedCorrection(typed: "Hais", correction: "Haus"))
        kb.flush()
        assertSameLearning(kb.memory, kb.disk)
        XCTAssertEqual(kb.memory.words["Haus"]?.count, 1, "the rejected correction is not reinforced")
        XCTAssertNil(kb.memory.bigrams[UserModel.bigramKey("ein", "Haus")])
        XCTAssertEqual(kb.memory.words["Hais"]?.count, 2)
        // The old one-event deltas kept the correction's +1 and its word pair in memory.
        XCTAssertEqual(kb.oldStyleMemory.words["Haus"]?.count, 2)
        XCTAssertEqual(kb.oldStyleMemory.bigrams[UserModel.bigramKey("ein", "Haus")], 1)
        XCTAssertFalse(sameLearning(kb.oldStyleMemory, kb.disk))
    }

    func testRetractionRemovesWordAndLanguageUsageThatWereNew() {
        var kb = LearningBookkeeping(base: UserModel())
        kb.record(commit("Bahnhof", typed: "Bahnhif", previous: "zum", auto: true))
        XCTAssertEqual(kb.memory.words["Bahnhof"]?.count, 1)
        XCTAssertEqual(kb.memory.languageUsage["de-AT"], 1)
        kb.record(.rejectedCorrection(typed: "Bahnhif", correction: "Bahnhof"))
        XCTAssertNil(kb.memory.words["Bahnhof"])
        XCTAssertNil(kb.memory.bigrams[UserModel.bigramKey("zum", "Bahnhof")])
        kb.flush()
        XCTAssertEqual(kb.memory.words, kb.disk.words)
        XCTAssertEqual(kb.memory.bigrams, kb.disk.bigrams)
        XCTAssertEqual(kb.memory.languageUsage["de-AT"] ?? 0, kb.disk.languageUsage["de-AT"] ?? 0)
    }

    func testFlushIsDeferredPastAnAutocorrectedCommitSoItCanStillBeRetracted() {
        var kb = LearningBookkeeping(base: UserModel())
        for i in 0..<24 { kb.record(commit("wort\(["a", "b", "c", "d", "e", "f"][i % 6])", previous: nil)) }
        kb.record(commit("Haus", typed: "Hais", previous: nil, auto: true)) // 25th event: no flush yet
        XCTAssertFalse(kb.pending.isEmpty)
        kb.record(.rejectedCorrection(typed: "Hais", correction: "Haus")) // flushes after retracting
        XCTAssertTrue(kb.pending.isEmpty)
        XCTAssertNil(kb.disk.words["Haus"])
        assertSameLearning(kb.memory, kb.disk)
    }

    func testLongMixedSessionKeepsMemoryEqualToDisk() {
        var base = UserModel()
        base.words["servus"] = LearnedWord(count: 3, lastUsedDay: 50, language: "de-AT")
        base.bigrams[UserModel.bigramKey("na", "servus")] = 2
        var kb = LearningBookkeeping(base: base)
        let vocabulary = ["servus", "na", "leiwand", "Haus", "heute", "morgen", "ciao", "faleminderit"]
        var previous: String?
        for i in 0..<200 {
            let word = vocabulary[(i * 7) % vocabulary.count]
            let auto = i % 9 == 4
            kb.record(commit(word, typed: auto ? word + "x" : word, previous: previous, auto: auto, taps: i % 3 != 0))
            if auto, i % 2 == 0 { kb.record(.rejectedCorrection(typed: word + "x", correction: word)) }
            if i % 11 == 0 { kb.record(.usedEmoji(["😀", "🇦🇹", "❤️"][i % 3])) }
            previous = word
        }
        kb.flush()
        assertSameLearning(kb.memory, kb.disk)
        XCTAssertFalse(sameLearning(kb.oldStyleMemory, kb.disk))
    }

    func testIncrementsOfAnUnchangedDeltaAreEmpty() {
        var delta = UserModelDelta()
        delta.record(commit("hallo", previous: "na"))
        XCTAssertTrue(delta.increments(since: delta).isEmpty)
        let before = delta
        delta.record(commit("x", previous: nil)) // not learnable
        XCTAssertTrue(delta.increments(since: before).isEmpty)
    }

    func testTouchAndEmojiIncrements() {
        var delta = UserModelDelta()
        delta.record(commit("ab", previous: nil))
        let before = delta
        delta.record(commit("ab", previous: nil))
        delta.record(.usedEmoji("😀"))
        let inc = delta.increments(since: before)
        let key = UserModel.touchKey(layout: "qwertz11.letters", keyID: "a")
        XCTAssertEqual(inc.touch[key]?.count, 1)
        XCTAssertEqual(inc.touch[key]?.sumDX ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(inc.emoji["😀"]?.count, 1)
        XCTAssertEqual(inc.words["ab"]?.count, 1)
    }

    func testMergeAddsAFailedDeltaAndKeepsTheRetractableCommit() {
        var older = UserModelDelta()
        older.record(.committedWord(final: "Servus", typed: "Servus", previous: nil, language: .deAT, taps: nil, wasAutocorrected: false), day: 100, now: 1)
        older.record(.usedEmoji("\u{1F600}"), day: 100, now: 1)
        var pending = UserModelDelta()
        pending.record(.committedWord(final: "oida", typed: "oida", previous: "Servus", language: .deAT, taps: nil, wasAutocorrected: false), day: 101, now: 2)
        pending.record(.committedWord(final: "Servus", typed: "Servis", previous: "oida", language: .deAT, taps: nil, wasAutocorrected: true), day: 101, now: 2)
        pending.merge(older)
        XCTAssertEqual(pending.words["Servus"]?.count, 2)
        XCTAssertEqual(pending.words["Servus"]?.lastUsedDay, 101)
        XCTAssertEqual(pending.words["oida"]?.count, 1)
        XCTAssertEqual(pending.languageUsage["de-AT"], 3)
        XCTAssertEqual(pending.emoji["\u{1F600}"]?.count, 1)
        // A backspace right after the autocorrection still takes back what that commit learned.
        pending.record(.rejectedCorrection(typed: "Servis", correction: "Servus"), day: 101, now: 3)
        XCTAssertEqual(pending.words["Servus"]?.count, 1)
        XCTAssertEqual(pending.languageUsage["de-AT"], 2)
        XCTAssertNil(pending.bigrams[UserModel.bigramKey("oida", "Servus")])

        // Applying the merged delta equals applying both deltas.
        var newer = UserModelDelta()
        newer.record(.committedWord(final: "oida", typed: "oida", previous: "Servus", language: .deAT, taps: nil, wasAutocorrected: false), day: 101, now: 2)
        var both = UserModel()
        both.apply(older)
        both.apply(newer)
        var merged = newer
        merged.merge(older)
        var once = UserModel()
        once.apply(merged)
        XCTAssertEqual(both, once)
    }
}
