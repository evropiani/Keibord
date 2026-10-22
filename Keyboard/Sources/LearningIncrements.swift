import Foundation
import KeibordCore

// Foundation only (no UIKit), so this file can also be compiled and tested against Core on Linux.

extension UserModelDelta {
    /// What recording events added to this delta since it was `before`: the exact increments, including
    /// the negative ones a rejected autocorrection takes back (`record` retracts the autocorrected
    /// commit it remembers, which a fresh one-event delta cannot do).
    ///
    /// The keyboard applies this to its in-memory model, so that model stays equal to what flushing the
    /// pending delta writes to disk.
    func increments(since before: UserModelDelta) -> UserModelDelta {
        var d = UserModelDelta()
        for (word, w) in words {
            let change = w.count - (before.words[word]?.count ?? 0)
            if change != 0 { d.words[word] = LearnedWord(count: change, lastUsedDay: w.lastUsedDay, language: w.language) }
        }
        for (word, w) in before.words where words[word] == nil && w.count != 0 {
            d.words[word] = LearnedWord(count: -w.count, lastUsedDay: w.lastUsedDay, language: w.language)
        }
        for (key, count) in bigrams {
            let change = count - (before.bigrams[key] ?? 0)
            if change != 0 { d.bigrams[key] = change }
        }
        for (key, count) in before.bigrams where bigrams[key] == nil && count != 0 {
            d.bigrams[key] = -count
        }
        for (key, t) in touch {
            let b = before.touch[key] ?? TouchStat()
            if t.count != b.count {
                d.touch[key] = TouchStat(sumDX: t.sumDX - b.sumDX, sumDY: t.sumDY - b.sumDY, count: t.count - b.count)
            }
        }
        for (key, e) in emoji {
            let change = e.count - (before.emoji[key]?.count ?? 0)
            if change != 0 { d.emoji[key] = EmojiStat(count: change, lastUsed: e.lastUsed) }
        }
        for (key, count) in languageUsage {
            let change = count - (before.languageUsage[key] ?? 0)
            if change != 0 { d.languageUsage[key] = change }
        }
        for (key, count) in before.languageUsage where languageUsage[key] == nil && count != 0 {
            d.languageUsage[key] = -count
        }
        return d
    }

    /// Adds the increments of `older` (a delta whose write failed) to this one, so the next flush writes
    /// both. Keeps this delta's own state: the autocorrected commit a backspace can still take back.
    mutating func merge(_ older: UserModelDelta) {
        for (word, w) in older.words {
            guard var mine = words[word] else {
                if w.count != 0 { words[word] = w }
                continue
            }
            mine.count += w.count
            mine.lastUsedDay = max(mine.lastUsedDay, w.lastUsedDay)
            if mine.language == nil { mine.language = w.language }
            words[word] = mine.count != 0 ? mine : nil
        }
        for (key, count) in older.bigrams {
            let sum = (bigrams[key] ?? 0) + count
            bigrams[key] = sum != 0 ? sum : nil
        }
        for (key, t) in older.touch {
            var mine = touch[key] ?? TouchStat()
            mine.sumDX += t.sumDX
            mine.sumDY += t.sumDY
            mine.count += t.count
            touch[key] = mine
        }
        for (key, e) in older.emoji {
            var mine = emoji[key] ?? EmojiStat(count: 0, lastUsed: e.lastUsed)
            mine.count += e.count
            mine.lastUsed = max(mine.lastUsed, e.lastUsed)
            emoji[key] = mine
        }
        for (key, count) in older.languageUsage {
            let sum = (languageUsage[key] ?? 0) + count
            languageUsage[key] = sum != 0 ? sum : nil
        }
    }
}
