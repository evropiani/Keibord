import Foundation

/// Context rules used by the input controller: smart quotes, sentence starts, double-space period and
/// the spacing of inserted words.
enum SmartPunctuation {
    /// Characters after which a quote opens (besides whitespace and the start of the text).
    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "'", "-", "–", "—", "/"]
    /// Typographic opening quotes of any style; used when the character is not part of the active style.
    private static let typographicOpeners: Set<Character> = ["„", "‚", "“", "‘", "«", "‹"]
    /// Opening brackets/quotes that may stand between a sentence end and the next word ("Ja. „Nein").
    private static let sentenceOpeners: Set<Character> = ["(", "[", "{", "\"", "'", "„", "“", "‚", "‘", "«", "»", "‹", "›", "¿", "¡"]
    /// Closing brackets/quotes that may follow a sentence terminator ("Er sagte „Ja.“ Dann").
    private static let sentenceClosers: Set<Character> = [")", "]", "}", "\"", "'", "”", "“", "’", "‘", "»", "«", "›", "‹"]
    /// Punctuation after which an inserted word (prediction) needs a separating space.
    private static let spaceRequiringPunctuation: Set<Character> = [".", ",", "!", "?", ":", ";", "…", ")", "]", "}", "%"]

    // MARK: Quotes

    /// Whether a quote typed after `previous` is an opening quote in `style`.
    static func opensQuote(after previous: Character?, style: QuoteStyle) -> Bool {
        guard let p = previous else { return true }
        if p.isWhitespace || openingPunctuation.contains(p) { return true }
        let s = String(p)
        if s == style.doubleOpen || s == style.singleOpen { return true }
        if s == style.doubleClose || s == style.singleClose || s == style.apostrophe { return false }
        return typographicOpeners.contains(p)
    }

    /// Converts a straight quote typed after `before` into the language's typographic quote.
    /// `"` opens at the start, after whitespace and after opening brackets/quotes, and closes otherwise.
    /// `'` right after a letter or digit is an apostrophe ("geht’s", "don’t", "l’amico") — unless it
    /// closes a pending single quotation in a style whose closing quote differs from the apostrophe
    /// (German „…“ ‚…‘); otherwise it opens or closes a single quotation.
    static func quote(for raw: String, before: String, style: QuoteStyle) -> String {
        let previous = before.last
        if raw == "\"" {
            return opensQuote(after: previous, style: style) ? style.doubleOpen : style.doubleClose
        }
        if let p = previous, TextUnits.isWordCharacter(p) {
            if style.singleClose != style.apostrophe, hasUnclosedSingleQuote(paragraph(of: before), style: style) {
                return style.singleClose
            }
            return style.apostrophe
        }
        return opensQuote(after: previous, style: style) ? style.singleOpen : style.singleClose
    }

    /// A quote typed right after an automatically inserted space (after a suggestion): when it closes
    /// an open quotation in the current paragraph, returns the closing quote that replaces the space
    /// ("„Haus␣" + `"` → "„Haus“␣"). `before` is the text *without* the automatic space.
    static func closingQuoteAfterAutoSpace(for raw: String, before: String, style: QuoteStyle) -> String? {
        guard let p = before.last, !p.isWhitespace, !opensQuote(after: p, style: style) else { return nil }
        let text = paragraph(of: before)
        if raw == "\"" {
            return hasUnclosedQuote(open: style.doubleOpen, close: style.doubleClose, in: text) ? style.doubleClose : nil
        }
        if raw == "'" {
            return hasUnclosedSingleQuote(text, style: style) ? style.singleClose : nil
        }
        return nil
    }

    /// The text after the last line break.
    static func paragraph(of text: String) -> Substring {
        guard let i = text.lastIndex(where: { $0.isNewline }) else { return Substring(text) }
        return text[text.index(after: i)...]
    }

    private static func occurrences(of needle: String, in text: Substring) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    private static func hasUnclosedQuote(open: String, close: String, in text: Substring) -> Bool {
        if open == close { return occurrences(of: open, in: text) % 2 == 1 }
        return occurrences(of: open, in: text) > occurrences(of: close, in: text)
    }

    /// Single quotes are ambiguous with apostrophes: a closing quote directly followed by a letter is an
    /// apostrophe and does not count. Straight single quotes cannot be told apart at all.
    private static func hasUnclosedSingleQuote(_ text: Substring, style: QuoteStyle) -> Bool {
        guard style.singleOpen != style.singleClose, style.singleOpen.count == 1, style.singleClose.count == 1,
              let open = style.singleOpen.first, let close = style.singleClose.first else { return false }
        let chars = Array(text)
        var opens = 0
        var closes = 0
        for (i, c) in chars.enumerated() {
            if c == open {
                opens += 1
            } else if c == close, !(i + 1 < chars.count && TextUnits.isWordCharacter(chars[i + 1])) {
                closes += 1
            }
        }
        return opens > closes
    }

    // MARK: Sentences and spacing

    /// True when a word typed after `before` starts a sentence: at the start of the text, after a line
    /// break, or after `. ! ? …` followed by whitespace. Closing quotes/brackets after the terminator
    /// ("Ja.“ ") and opening ones before the word ("Ja. „") do not change that.
    static func isSentenceStart(_ before: String) -> Bool {
        var rest = Substring(before)
        while let last = rest.last, sentenceOpeners.contains(last) { rest = rest.dropLast() }
        var sawSpace = false
        while let last = rest.last, last.isWhitespace {
            if last.isNewline { return true }
            rest = rest.dropLast()
            sawSpace = true
        }
        guard !rest.isEmpty else { return true }
        guard sawSpace else { return false }
        while let last = rest.last, sentenceClosers.contains(last) { rest = rest.dropLast() }
        guard let terminator = rest.last else { return true }
        guard TextUnits.sentenceTerminators.contains(terminator) else { return false }
        return terminator != "." || !endsWithAbbreviation(rest.dropLast())
    }

    /// Abbreviations after which a period does not end the sentence (titles and the like).
    private static let abbreviations: Set<String> = ["dr", "prof", "nr", "hr", "fr", "mr", "mrs", "ms", "st", "jr", "sr", "bzw", "vgl", "ca", "sig", "dott"]

    /// Whether the text before a period is an abbreviation: initials and dotted abbreviations
    /// ("A.", "z.B.", "d.h.", "e.g.") or a title ("Dr.", "Nr.").
    static func endsWithAbbreviation(_ text: Substring) -> Bool {
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            let c = text[previous]
            if c.isWhitespace || sentenceOpeners.contains(c) { break }
            start = previous
        }
        let token = text[start...]
        guard !token.isEmpty else { return false }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.allSatisfy({ $0.count == 1 && $0.first!.isLetter }) { return true }
        return abbreviations.contains(token.lowercased())
    }

    /// "word" + space + space → "word. " only after a word character (not after punctuation or emoji).
    static func canInsertDoubleSpacePeriod(before: String) -> Bool {
        guard let last = before.last else { return false }
        return TextUnits.isWordCharacter(last)
    }

    /// Whether a word inserted directly after `previous` (a prediction tap) needs a separating space:
    /// after letters, digits, sentence punctuation, closing brackets/quotes and emoji — not at the start,
    /// after whitespace or after opening brackets/quotes.
    static func needsSpaceBeforeWord(after previous: Character?, style: QuoteStyle) -> Bool {
        guard let p = previous, !p.isWhitespace else { return false }
        if TextUnits.isWordCharacter(p) || spaceRequiringPunctuation.contains(p) { return true }
        let s = String(p)
        if s == style.doubleClose, s != style.doubleOpen { return true }
        if s == style.singleClose, s != style.singleOpen { return true }
        return isEmoji(p)
    }

    static func isEmoji(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return scalars.count > 1 && scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 })
    }
}
