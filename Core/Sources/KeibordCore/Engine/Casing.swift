import Foundation

/// Casing rules for suggestions: the way the user typed a word decides how a dictionary word is shown.
public enum Casing {
    /// Applies the typed casing to a dictionary word:
    /// * typed ALL CAPS (≥ 2 letters) → the candidate in upper-case ("TEH" → "THE"),
    /// * typed Capitalised → the candidate's first letter capitalised ("Teh" → "The"); words with inner
    ///   capitals ("iPhone") keep their dictionary form,
    /// * otherwise the dictionary form is kept ("haus" → "Haus", "london" → "London").
    public static func apply(typed: String, to candidate: String) -> String {
        if isAllCaps(typed) { return candidate.uppercased() }
        if startsUppercase(typed) {
            return hasInnerCapitals(candidate) ? candidate : capitalizingFirstLetter(candidate)
        }
        return candidate
    }

    /// Upper-cases the first letter ("über" → "Über", "'tis" → "'Tis").
    public static func capitalizingFirstLetter(_ word: String) -> String {
        guard let index = word.firstIndex(where: { $0.isLetter }) else { return word }
        let letter = String(word[index])
        let upper = letter.uppercased()
        // "ß" has no single-letter capital form; keep it rather than producing "Ss".
        guard upper.count == 1 else { return word }
        return String(word[..<index]) + upper + String(word[word.index(after: index)...])
    }

    /// At least two letters and every letter upper-case ("ß", which has no capital key, is ignored).
    public static func isAllCaps(_ word: String) -> Bool {
        var letters = 0
        var upper = 0
        for c in word where c.isLetter {
            letters += 1
            if c.isUppercase {
                upper += 1
            } else if c != "ß" {
                return false
            }
        }
        return letters >= 2 && upper >= 1
    }

    /// The first letter is upper-case ("Haus", "I", "USA").
    public static func startsUppercase(_ word: String) -> Bool {
        word.first(where: { $0.isLetter })?.isUppercase ?? false
    }

    /// Any upper-case letter ("Haus", "iPhone").
    public static func hasUppercase(_ word: String) -> Bool {
        word.contains { $0.isUppercase }
    }

    /// An upper-case letter after the first letter in a word that is not ALL CAPS ("iPhone", "McDonald").
    public static func hasInnerCapitals(_ word: String) -> Bool {
        guard !isAllCaps(word) else { return false }
        var seenLetter = false
        for c in word where c.isLetter {
            if seenLetter && c.isUppercase { return true }
            seenLetter = true
        }
        return false
    }
}
