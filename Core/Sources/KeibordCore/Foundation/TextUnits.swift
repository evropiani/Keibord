import Foundation

/// Character classification shared by the input controller and the suggestion engine.
public enum TextUnits {
    /// Apostrophe-like characters that may appear *inside* a word ("don't", "geht’s").
    public static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    /// Characters that end a sentence.
    public static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Punctuation after which an automatically inserted space should be moved (smart punctuation).
    public static let spaceSwallowingPunctuation: Set<Character> = [".", ",", "!", "?", ":", ";", ")", "…"]

    /// A letter (any script), combining mark or digit. Apostrophes are handled separately.
    /// Emoji built on a digit or letter (keycaps "1️⃣", "#️⃣") are symbols, not word characters.
    public static func isWordCharacter(_ c: Character) -> Bool {
        if apostrophes.contains(c) { return false }
        let scalars = c.unicodeScalars
        if scalars.count > 1, scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 || $0.value == 0x200D }) {
            return false
        }
        return c.isLetter || c.isNumber || scalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    /// Normalises a word for dictionary lookups: NFC, lower-case, typographic apostrophe → "'".
    public static func lookupKey(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// Extracts the word that ends exactly at the end of `context` (the word being typed).
    /// Apostrophes are part of the word only when surrounded by word characters
    /// (a trailing apostrophe is kept so "don'" continues to "don't").
    /// Returns "" if the context ends with whitespace/punctuation.
    public static func trailingWord(in context: String) -> String {
        let chars = Array(context)
        var start = chars.count
        var i = chars.count - 1
        while i >= 0 {
            let c = chars[i]
            if isWordCharacter(c) {
                start = i
                i -= 1
                continue
            }
            // An apostrophe belongs to the word if a word character precedes it and it is either
            // the last character (still typing) or followed by a word character.
            if apostrophes.contains(c), i > 0, isWordCharacter(chars[i - 1]),
               i == chars.count - 1 || isWordCharacter(chars[i + 1]) {
                start = i
                i -= 1
                continue
            }
            break
        }
        return start < chars.count ? String(chars[start...]) : ""
    }

    /// Splits text into words (sequences of word characters, with inner apostrophes).
    public static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if isWordCharacter(c) {
                current.append(c)
            } else if apostrophes.contains(c), !current.isEmpty, i + 1 < chars.count, isWordCharacter(chars[i + 1]) {
                current.append(c)
            } else {
                if !current.isEmpty { result.append(current); current = "" }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
