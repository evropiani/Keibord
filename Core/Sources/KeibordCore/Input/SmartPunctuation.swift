import Foundation

enum SmartPunctuation {
    private static let openingContext: Set<Character> = ["(", "[", "{", "„", "“", "‚", "‘", "«", "‹", "\"", "'", "-", "–", "—", "/"]

    /// Converts a straight quote typed after `before` into the language's typographic quote.
    static func quote(for raw: String, before: String, style: QuoteStyle) -> String {
        let previous = before.last
        let opens = previous == nil || previous!.isWhitespace || openingContext.contains(previous!)
        if raw == "\"" {
            return opens ? style.doubleOpen : style.doubleClose
        }
        if let p = previous, TextUnits.isWordCharacter(p) || p == "." || p == "," {
            return style.apostrophe
        }
        return opens ? style.singleOpen : style.singleClose
    }

    /// "word" + space + space → "word. " only after a word character (not after punctuation).
    static func canInsertDoubleSpacePeriod(before: String) -> Bool {
        guard let last = before.last else { return false }
        return TextUnits.isWordCharacter(last)
    }
}
