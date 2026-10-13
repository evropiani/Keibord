import Foundation

/// Increments recorded by the keyboard between two flushes to disk. Applying a delta is additive,
/// so the keyboard and the app can both edit `user-model.json` without losing each other's changes.
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

    public static func today(_ date: Date = Date()) -> Int { Int(date.timeIntervalSince1970 / 86_400) }

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
        case let .rejectedCorrection(typed, _):
            guard LearningPolicy.isLearnable(typed) else { return }
            addWord(typed, count: 2, day: day, language: nil)
        case .usedEmoji(let e):
            var stat = emoji[e] ?? EmojiStat(count: 0, lastUsed: now)
            stat.count += 1
            stat.lastUsed = now
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

    private mutating func recordTouches(word: String, taps: [TapInput]) {
        let letters = Array(word.lowercased())
        guard letters.count == taps.count else { return }
        for (i, tap) in taps.enumerated() {
            let letter = String(letters[i])
            guard !tap.touchModelKey.isEmpty, let c = tap.candidates.first(where: { $0.character == letter }) else { continue }
            let key = UserModel.touchKey(layout: tap.touchModelKey, keyID: letter)
            var stat = touch[key] ?? TouchStat()
            stat.sumDX += c.dx
            stat.sumDY += c.dy
            stat.count += 1
            touch[key] = stat
        }
    }
}

public enum LearningPolicy {
    /// Words worth learning: 2–40 characters, no digits, not an email/URL.
    public static func isLearnable(_ word: String) -> Bool {
        let n = word.count
        guard n >= 2, n <= 40 else { return false }
        if word.contains(where: { $0.isNumber || $0 == "@" || $0 == "/" }) { return false }
        return word.contains(where: { $0.isLetter })
    }

    /// A learned word counts as "known" once used this often.
    public static let knownThreshold = 2
}

public extension UserModel {
    mutating func apply(_ delta: UserModelDelta) {
        for (word, d) in delta.words where !blocked.contains(TextUnits.lookupKey(word)) {
            var w = words[word] ?? LearnedWord(count: 0, lastUsedDay: d.lastUsedDay, language: d.language)
            w.count += d.count
            w.lastUsedDay = max(w.lastUsedDay, d.lastUsedDay)
            if d.language != nil { w.language = d.language }
            words[word] = w
        }
        for (k, v) in delta.bigrams { bigrams[k, default: 0] += v }
        for (k, v) in delta.touch {
            var t = touch[k] ?? TouchStat()
            t.sumDX += v.sumDX
            t.sumDY += v.sumDY
            t.count += v.count
            touch[k] = t
        }
        for (k, v) in delta.emoji {
            var e = emoji[k] ?? EmojiStat(count: 0, lastUsed: v.lastUsed)
            e.count += v.count
            e.lastUsed = max(e.lastUsed, v.lastUsed)
            emoji[k] = e
        }
        for (k, v) in delta.languageUsage { languageUsage[k, default: 0] += v }
    }

    /// Keeps the model small: drops the least used / oldest entries beyond the limits.
    mutating func prune(maxWords: Int = 30_000, maxBigrams: Int = 80_000, maxEmoji: Int = 200) {
        if words.count > maxWords {
            let keep = words.sorted {
                ($0.value.addedManually ? 1 : 0, $0.value.count, $0.value.lastUsedDay) > ($1.value.addedManually ? 1 : 0, $1.value.count, $1.value.lastUsedDay)
            }.prefix(maxWords)
            words = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if bigrams.count > maxBigrams {
            bigrams = Dictionary(uniqueKeysWithValues: bigrams.sorted { $0.value > $1.value }.prefix(maxBigrams).map { ($0.key, $0.value) })
        }
        if emoji.count > maxEmoji {
            emoji = Dictionary(uniqueKeysWithValues: emoji.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(maxEmoji).map { ($0.key, $0.value) })
        }
        // Cap touch statistics so old habits fade: halve when very large.
        for (k, t) in touch where t.count > 400 {
            touch[k] = TouchStat(sumDX: t.sumDX / 2, sumDY: t.sumDY / 2, count: t.count / 2)
        }
    }

    /// Import merge: sums counts, keeps the most recent dates, unions blocked words.
    func merged(with other: UserModel) -> UserModel {
        var result = self
        result.blocked.formUnion(other.blocked)
        var delta = UserModelDelta()
        delta.words = other.words
        delta.bigrams = other.bigrams
        delta.touch = other.touch
        delta.emoji = other.emoji
        delta.languageUsage = other.languageUsage
        result.apply(delta)
        for (word, w) in other.words where w.addedManually { result.words[word]?.addedManually = true }
        for key in result.blocked {
            result.words = result.words.filter { TextUnits.lookupKey($0.key) != key }
        }
        return result
    }

    /// Words for the user lexicon: known words with a Zipf estimate; casings merged per lookup key.
    func knownWords(minCount: Int = LearningPolicy.knownThreshold) -> [(word: String, zipf: Double)] {
        var best: [String: (String, Int)] = [:]
        var totals: [String: Int] = [:]
        for (word, w) in words where w.addedManually || w.count >= minCount {
            let key = TextUnits.lookupKey(word)
            guard !blocked.contains(key) else { continue }
            let weight = w.addedManually ? max(w.count, minCount) : w.count
            totals[key, default: 0] += weight
            if let b = best[key], b.1 >= weight { continue }
            best[key] = (word, weight)
        }
        return best.map { key, value in
            (word: value.0, zipf: min(6, 3 + log10(Double(max(1, totals[key] ?? value.1)))))
        }
    }

    /// Most recently used emoji first.
    var emojiRecents: [String] {
        emoji.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(32).map { $0.key }
    }

    /// Mean learned touch offsets per key id for one layout geometry, clamped to ±0.25 key sizes.
    func touchOffsets(for touchModelKey: String, minSamples: Int = 12) -> [String: (dx: Double, dy: Double)] {
        var result: [String: (dx: Double, dy: Double)] = [:]
        let prefix = touchModelKey + "|"
        for (k, t) in touch where t.count >= minSamples && k.hasPrefix(prefix) {
            let id = String(k.dropFirst(prefix.count))
            result[id] = (dx: min(0.25, max(-0.25, t.meanDX)), dy: min(0.25, max(-0.25, t.meanDY)))
        }
        return result
    }

    mutating func addWord(_ word: String, day: Int = UserModelDelta.today()) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        blocked.remove(TextUnits.lookupKey(trimmed))
        var w = words[trimmed] ?? LearnedWord(count: 0, lastUsedDay: day)
        w.addedManually = true
        w.count = max(w.count, LearningPolicy.knownThreshold)
        words[trimmed] = w
    }

    mutating func removeWord(_ word: String) {
        words[word] = nil
        let key = TextUnits.lookupKey(word)
        bigrams = bigrams.filter { entry in
            !entry.key.split(separator: UserModel.bigramSeparator).contains { String($0) == key }
        }
    }

    mutating func block(_ word: String) {
        let key = TextUnits.lookupKey(word)
        guard !key.isEmpty else { return }
        blocked.insert(key)
        words = words.filter { TextUnits.lookupKey($0.key) != key }
    }

    mutating func unblock(_ word: String) {
        blocked.remove(TextUnits.lookupKey(word))
    }

    mutating func resetTouch() { touch = [:] }

    var touchSampleCount: Int { touch.values.reduce(0) { $0 + $1.count } }
}
