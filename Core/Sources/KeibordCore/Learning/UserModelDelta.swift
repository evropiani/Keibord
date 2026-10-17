import Foundation

/// Increments recorded by the keyboard between two flushes to disk. Applying a delta is additive,
/// so the keyboard and the app can both edit `user-model.json` without losing each other's changes.
///
/// A word entry with a negative count takes back learning (a rejected autocorrection); applying it
/// lowers the stored count and removes words that drop to zero.
public struct UserModelDelta: Equatable, Sendable {
    public var words: [String: LearnedWord] = [:]
    public var bigrams: [String: Int] = [:]
    public var touch: [String: TouchStat] = [:]
    public var emoji: [String: EmojiStat] = [:]
    public var languageUsage: [String: Int] = [:]

    public init() {}

    public var isEmpty: Bool {
        words.isEmpty && bigrams.isEmpty && touch.isEmpty && emoji.isEmpty && languageUsage.isEmpty
    }

    public static func today(_ date: Date = Date()) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }

    public mutating func record(_ event: LearningEvent, day: Int = UserModelDelta.today(), now: Double = Date().timeIntervalSince1970) {
        switch event {
        case let .committedWord(final, _, previous, language, taps, wasAutocorrected):
            guard LearningPolicy.isLearnable(final) else { return }
            addWord(final, count: 1, day: day, language: language?.rawValue)
            if let previous = previous, LearningPolicy.isLearnable(previous) {
                bigrams[UserModel.bigramKey(previous, final), default: 0] += 1
            }
            if let language = language { languageUsage[language.rawValue, default: 0] += 1 }
            if !wasAutocorrected, let taps = taps { recordTouches(word: final, taps: taps) }
        case let .rejectedCorrection(typed, correction):
            if LearningPolicy.isLearnable(typed) {
                addWord(typed, count: 2, day: day, language: nil)
            }
            // The correction was learned when it was committed (autocorrect then backspace): take that
            // back so rejected corrections are not reinforced. Applying never drops a count below 0.
            if LexiconKey.string(correction) != LexiconKey.string(typed), LearningPolicy.isLearnable(correction) {
                unlearnWord(correction)
            }
        case .usedEmoji(let e):
            guard !e.isEmpty else { return }
            var stat = emoji[e] ?? EmojiStat(count: 0, lastUsed: now)
            stat.count += 1
            stat.lastUsed = max(stat.lastUsed, now)
            emoji[e] = stat
        case .switchedLanguage:
            break
        }
    }

    private mutating func addWord(_ word: String, count: Int, day: Int, language: String?) {
        var w = words[word] ?? LearnedWord(count: 0, lastUsedDay: day, language: language)
        w.count += count
        w.lastUsedDay = max(w.lastUsedDay, day)
        if language != nil { w.language = language }
        words[word] = w
    }

    private mutating func unlearnWord(_ word: String) {
        // lastUsedDay 0: an unlearn entry never makes a word look recently used.
        var w = words[word] ?? LearnedWord(count: 0, lastUsedDay: 0)
        w.count -= 1
        words[word] = w.count == 0 ? nil : w
    }

    /// Learns where the user taps each letter key. Taps align with the letters of the final word (same
    /// length, compared by lookup key); only letter keys with a finite offset are recorded.
    private mutating func recordTouches(word: String, taps: [TapInput]) {
        let letters = Array(LexiconKey.string(word))
        guard letters.count == taps.count else { return }
        for (i, tap) in taps.enumerated() where letters[i].isLetter && !tap.touchModelKey.isEmpty {
            let letter = String(letters[i])
            guard let c = tap.candidates.first(where: { $0.character == letter }), c.dx.isFinite, c.dy.isFinite else { continue }
            let key = UserModel.touchKey(layout: tap.touchModelKey, keyID: letter)
            var stat = touch[key] ?? TouchStat()
            // Candidates lie within ~1.6 key sizes; clamping limits the pull of a single far-off tap.
            stat.sumDX += min(1, max(-1, c.dx))
            stat.sumDY += min(1, max(-1, c.dy))
            stat.count += 1
            touch[key] = stat
        }
    }
}

public enum LearningPolicy {
    /// Words worth learning: 2–40 characters with at least one letter; no digits, whitespace or control
    /// characters, and nothing that looks like an e-mail address, URL, domain or path.
    public static func isLearnable(_ word: String) -> Bool {
        let n = word.count
        guard n >= 2, n <= 40 else { return false }
        var hasLetter = false
        var previous: Character?
        for c in word {
            if c.isNumber || c.isWhitespace || c.isNewline || c == "@" || c == "/" || c == "\\" { return false }
            if c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format && $0.value != 0x200D }) {
                return false
            }
            // An inner dot followed by a letter ("orf.at", "www.example"): a domain, not a word.
            if previous == ".", c.isLetter { return false }
            if c.isLetter { hasLetter = true }
            previous = c
        }
        return hasLetter
    }

    /// A learned word counts as "known" once used this often.
    public static let knownThreshold = 2
}

public extension UserModel {
    /// Adds the delta's increments. Blocked words (and word pairs containing them) are never learned
    /// again; negative word counts lower the stored count and drop words that reach zero (manually
    /// added words stay).
    mutating func apply(_ delta: UserModelDelta) {
        for (word, d) in delta.words where !blocked.contains(LexiconKey.string(word)) {
            if d.count < 0 {
                guard var w = words[word] else { continue }
                w.count = max(0, w.count + d.count)
                words[word] = w.count == 0 && !w.addedManually ? nil : w
                continue
            }
            var w = words[word] ?? LearnedWord(count: 0, lastUsedDay: d.lastUsedDay, language: d.language)
            w.count += d.count
            w.lastUsedDay = max(w.lastUsedDay, d.lastUsedDay)
            if d.language != nil { w.language = d.language }
            words[word] = w
        }
        for (k, v) in delta.bigrams where v != 0 && !UserModel.bigram(k, mentionsAnyOf: blocked) {
            let count = (bigrams[k] ?? 0) + v
            bigrams[k] = count > 0 ? count : nil
        }
        for (k, v) in delta.touch where v.count > 0 && v.sumDX.isFinite && v.sumDY.isFinite {
            var t = touch[k] ?? TouchStat()
            t.sumDX += v.sumDX
            t.sumDY += v.sumDY
            t.count += v.count
            touch[k] = t
        }
        for (k, v) in delta.emoji where !k.isEmpty {
            var e = emoji[k] ?? EmojiStat(count: 0, lastUsed: v.lastUsed)
            e.count += v.count
            e.lastUsed = max(e.lastUsed, v.lastUsed)
            emoji[k] = e
        }
        for (k, v) in delta.languageUsage { languageUsage[k, default: 0] += v }
    }

    /// Keeps the model small: beyond the limits, drops the least used entries (lowest count, then
    /// oldest; manually added words go last). Ties are broken by key so pruning is deterministic.
    mutating func prune(maxWords: Int = 30_000, maxBigrams: Int = 80_000, maxEmoji: Int = 200) {
        if words.count > maxWords {
            let keep = words.sorted { a, b in
                if a.value.addedManually != b.value.addedManually { return a.value.addedManually }
                if a.value.count != b.value.count { return a.value.count > b.value.count }
                if a.value.lastUsedDay != b.value.lastUsedDay { return a.value.lastUsedDay > b.value.lastUsedDay }
                return a.key < b.key
            }.prefix(max(0, maxWords))
            words = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if bigrams.count > maxBigrams {
            let keep = bigrams.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(max(0, maxBigrams))
            bigrams = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if emoji.count > maxEmoji {
            emoji = Dictionary(uniqueKeysWithValues: emojiByRecency.prefix(max(0, maxEmoji)).map { ($0.key, $0.value) })
        }
        // Cap touch statistics so old habits fade: halve when very large (sums scaled like the count,
        // so the mean offset stays the same for odd counts too).
        for (k, t) in touch where t.count > 400 {
            let kept = t.count / 2
            let scale = Double(kept) / Double(t.count)
            touch[k] = TouchStat(sumDX: t.sumDX * scale, sumDY: t.sumDY * scale, count: kept)
        }
    }

    /// Import merge: sums counts, keeps the most recent dates, unions blocked words (removing their
    /// words and word pairs from the result) and keeps the "added manually" flag from either side.
    func merged(with other: UserModel) -> UserModel {
        var result = self
        result.blocked.formUnion(other.blocked)
        var delta = UserModelDelta()
        delta.words = other.words.filter { $0.value.count > 0 || $0.value.addedManually }
        delta.bigrams = other.bigrams.filter { $0.value > 0 }
        delta.touch = other.touch
        delta.emoji = other.emoji
        delta.languageUsage = other.languageUsage
        result.apply(delta)
        for (word, w) in other.words where w.addedManually { result.words[word]?.addedManually = true }
        if !result.blocked.isEmpty {
            let blocked = result.blocked
            result.words = result.words.filter { !blocked.contains(LexiconKey.string($0.key)) }
            result.bigrams = result.bigrams.filter { !UserModel.bigram($0.key, mentionsAnyOf: blocked) }
        }
        return result
    }

    /// Words for the user lexicon: known words with a Zipf estimate, one entry per lookup key.
    ///
    /// All casings of a key ("Leiwand" at a sentence start, "leiwand" elsewhere) count together: the
    /// key is known once their total reaches `minCount` (manually added words always are) and the
    /// zipf is `min(6, 3 + log10(total))`. The entry uses the casing added manually, else the most
    /// used one (on a tie the lower-case form). Sorted by zipf (descending), then word.
    func knownWords(minCount: Int = LearningPolicy.knownThreshold) -> [(word: String, zipf: Double)] {
        struct Candidate {
            var word: String
            var weight: Int
            var manual: Bool
            var total: Int
            var anyManual: Bool
        }
        var byKey: [String: Candidate] = [:]
        for (word, w) in words where w.count > 0 || w.addedManually {
            let key = LexiconKey.string(word)
            guard !key.isEmpty, !blocked.contains(key) else { continue }
            let weight = w.addedManually ? max(w.count, minCount) : w.count
            guard var c = byKey[key] else {
                byKey[key] = Candidate(word: word, weight: weight, manual: w.addedManually, total: weight, anyManual: w.addedManually)
                continue
            }
            c.total += weight
            c.anyManual = c.anyManual || w.addedManually
            if Self.prefers(word, weight, w.addedManually, over: c.word, c.weight, c.manual) {
                c.word = word
                c.weight = weight
                c.manual = w.addedManually
            }
            byKey[key] = c
        }
        return byKey.values
            .filter { $0.anyManual || $0.total >= minCount }
            .map { (word: $0.word, zipf: min(6, 3 + log10(Double(max(1, $0.total))))) }
            .sorted { $0.zipf != $1.zipf ? $0.zipf > $1.zipf : $0.word < $1.word }
    }

    /// Most recently used emoji first (max 32; ties: more used, then by emoji).
    var emojiRecents: [String] {
        emojiByRecency.prefix(32).map { $0.key }
    }

    /// Mean learned touch offsets per key id for one layout geometry, clamped to ±0.25 key sizes.
    /// Keys with fewer than `minSamples` (at least 1) samples or unusable sums are left out.
    func touchOffsets(for touchModelKey: String, minSamples: Int = 12) -> [String: (dx: Double, dy: Double)] {
        var result: [String: (dx: Double, dy: Double)] = [:]
        let prefix = touchModelKey + "|"
        let required = max(1, minSamples)
        for (k, t) in touch where t.count >= required && k.hasPrefix(prefix) {
            let dx = t.meanDX, dy = t.meanDY
            guard dx.isFinite, dy.isFinite else { continue }
            let id = String(k.dropFirst(prefix.count))
            result[id] = (dx: min(0.25, max(-0.25, dx)), dy: min(0.25, max(-0.25, dy)))
        }
        return result
    }

    /// Adds a word in the app's dictionary editor: always known, and no longer blocked.
    mutating func addWord(_ word: String, day: Int = UserModelDelta.today()) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        blocked.remove(LexiconKey.string(trimmed))
        var w = words[trimmed] ?? LearnedWord(count: 0, lastUsedDay: day)
        w.addedManually = true
        w.count = max(w.count, LearningPolicy.knownThreshold)
        words[trimmed] = w
    }

    /// Removes one learned word (exact form). Word pairs with its lookup key are removed once no
    /// other casing of the word is left.
    mutating func removeWord(_ word: String) {
        words[word] = nil
        let key = LexiconKey.string(word)
        guard !key.isEmpty, !words.keys.contains(where: { LexiconKey.string($0) == key }) else { return }
        removeBigrams(containing: key)
    }

    /// Blocks a word: all its casings and word pairs are removed and it is never learned again.
    mutating func block(_ word: String) {
        let key = LexiconKey.string(word.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return }
        blocked.insert(key)
        words = words.filter { LexiconKey.string($0.key) != key }
        removeBigrams(containing: key)
    }

    mutating func unblock(_ word: String) {
        blocked.remove(LexiconKey.string(word))
        blocked.remove(LexiconKey.string(word.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    mutating func resetTouch() { touch = [:] }

    var touchSampleCount: Int { touch.values.reduce(0) { $0 + $1.count } }
}

extension UserModel {
    /// Emoji sorted by last use (newest first), then use count, then emoji.
    fileprivate var emojiByRecency: [(key: String, value: EmojiStat)] {
        emoji.sorted { a, b in
            if a.value.lastUsed != b.value.lastUsed { return a.value.lastUsed > b.value.lastUsed }
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            return a.key < b.key
        }
    }

    /// Whether either side of a bigram key is in `keys`.
    fileprivate static func bigram(_ bigramKey: String, mentionsAnyOf keys: Set<String>) -> Bool {
        guard !keys.isEmpty else { return false }
        return bigramKey.split(separator: UserModel.bigramSeparator, omittingEmptySubsequences: false)
            .contains { keys.contains(String($0)) }
    }

    fileprivate mutating func removeBigrams(containing key: String) {
        bigrams = bigrams.filter { entry in
            !entry.key.split(separator: UserModel.bigramSeparator, omittingEmptySubsequences: false).contains { String($0) == key }
        }
    }

    /// Whether `a` should represent a lookup key instead of `b` in `knownWords`.
    fileprivate static func prefers(_ a: String, _ aWeight: Int, _ aManual: Bool, over b: String, _ bWeight: Int, _ bManual: Bool) -> Bool {
        if aManual != bManual { return aManual }
        if aWeight != bWeight { return aWeight > bWeight }
        let aLower = a == a.lowercased(), bLower = b == b.lowercased()
        if aLower != bLower { return aLower }
        return a < b
    }
}
