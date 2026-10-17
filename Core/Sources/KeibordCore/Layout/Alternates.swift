import Foundation

/// Long-press alternatives (lower-case; the UI upper-cases them when shifted).
public enum Alternates {
    private static let generic: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
    ]

    private static let german: [String: [String]] = [
        "a": ["ä", "à", "á", "â", "æ", "ã", "å", "ā"],
        "o": ["ö", "ô", "ò", "ó", "œ", "ø", "ō", "õ"],
        "u": ["ü", "û", "ù", "ú", "ū"],
        "s": ["ß", "ś", "š"],
        "e": ["é", "è", "ê", "ë", "ė"],
        "ü": ["u"], "ö": ["o"], "ä": ["a"],
    ]

    private static let albanian: [String: [String]] = [
        "e": ["ë", "é", "è", "ê"],
        "c": ["ç", "ć", "č"],
        "ë": ["e", "é", "è"],
        "ç": ["c", "ć", "č"],
    ]

    private static let italian: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "e": ["è", "é", "ê", "ë", "ē"],
        "i": ["ì", "í", "î", "ï", "ī"],
        "o": ["ò", "ó", "ô", "ö", "õ", "œ", "ø", "ō"],
        "u": ["ù", "ú", "û", "ü", "ū"],
    ]

    private static let symbols: [String: [String]] = [
        "-": ["–", "—", "•"],
        "/": ["\\"],
        "$": ["$", "€", "£", "¥", "₩", "₽", "¢"],
        "€": ["€", "$", "£", "¥", "₩", "₽", "¢"],
        "£": ["£", "€", "$", "¥", "₩", "₽", "¢"],
        "&": ["§"],
        "\"": ["„", "“", "”", "«", "»"],
        "'": ["‚", "‘", "’", "`"],
        ".": ["…"],
        "?": ["¿"],
        "!": ["¡"],
        "%": ["‰"],
        "0": ["°", "⁰"],
        "1": ["¹", "½", "⅓", "¼", "⅛"],
        "2": ["²", "⅔"],
        "3": ["³", "¾", "⅜"],
        "4": ["⁴"],
        "5": ["⁵", "⅝"],
        "7": ["⅞"],
    ]

    /// Quote keys list the language's own quotation marks first („“ for German/Albanian, “” for
    /// English/Italian).
    private static let englishQuotes: [String: [String]] = [
        "\"": ["“", "”", "„", "«", "»"],
        "'": ["‘", "’", "‚", "`"],
    ]

    public static func alternates(for key: String, language: KeyboardLanguage) -> [String] {
        let table: [String: [String]]
        switch language.languageCode {
        case "de": table = german
        case "sq": table = albanian
        case "it": table = italian
        default: table = [:]
        }
        if language.defaultQuoteStyle == .english, let quotes = englishQuotes[key] { return quotes }
        return table[key] ?? generic[key] ?? symbols[key] ?? []
    }

    /// Long-press domains of the `.com` key: the language's own country domain first.
    public static func topLevelDomains(for language: KeyboardLanguage) -> [String] {
        let first: [String]
        switch language {
        case .deAT: first = [".at", ".de"]
        case .enGB: first = [".co.uk", ".com"]
        case .enUS: first = [".com", ".net", ".org"]
        case .sqAL: first = [".al", ".com"]
        case .sqXK: first = [".com", ".al"]
        case .itIT: first = [".it", ".com"]
        }
        let all = [".at", ".de", ".com", ".net", ".org", ".eu", ".it", ".al", ".co.uk"]
        return first + all.filter { !first.contains($0) }
    }
}
