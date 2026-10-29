import Foundation

/// The physical letter arrangement a language layout is built on.
public enum BaseLayout: String, Codable, CaseIterable, Hashable, Sendable {
    case qwertz
    case qwerty

    public var displayName: String {
        switch self {
        case .qwertz: return "QWERTZ"
        case .qwerty: return "QWERTY"
        }
    }
}

/// Typographic quote characters used by smart quotes.
public struct QuoteStyle: Codable, Hashable, Sendable {
    public var doubleOpen: String
    public var doubleClose: String
    public var singleOpen: String
    public var singleClose: String
    /// Apostrophe used inside words (e.g. "don’t", "geht’s").
    public var apostrophe: String

    public init(doubleOpen: String, doubleClose: String, singleOpen: String, singleClose: String, apostrophe: String = "\u{2019}") {
        self.doubleOpen = doubleOpen
        self.doubleClose = doubleClose
        self.singleOpen = singleOpen
        self.singleClose = singleClose
        self.apostrophe = apostrophe
    }

    /// „…“ ‚…‘ (German, Albanian)
    public static let germanLow = QuoteStyle(doubleOpen: "\u{201E}", doubleClose: "\u{201C}", singleOpen: "\u{201A}", singleClose: "\u{2018}")
    /// “…” ‘…’ (English, Italian default)
    public static let english = QuoteStyle(doubleOpen: "\u{201C}", doubleClose: "\u{201D}", singleOpen: "\u{2018}", singleClose: "\u{2019}")
    /// «…» ‹…› (Italian guillemets)
    public static let guillemets = QuoteStyle(doubleOpen: "\u{00AB}", doubleClose: "\u{00BB}", singleOpen: "\u{2039}", singleClose: "\u{203A}")
    /// "…" '…' (no conversion)
    public static let straight = QuoteStyle(doubleOpen: "\"", doubleClose: "\"", singleOpen: "'", singleClose: "'", apostrophe: "'")

    public static let allPresets: [(name: String, style: QuoteStyle)] = [
        ("„German“", .germanLow),
        ("“English”", .english),
        ("«Guillemets»", .guillemets),
        ("\"Straight\"", .straight),
    ]
}

/// The kind of return key requested by the text field (mirrors UIReturnKeyType).
public enum ReturnKind: String, Codable, CaseIterable, Hashable, Sendable {
    case `default`, go, google, join, next, route, search, send, yahoo, done, emergencyCall, `continue`

    /// iOS draws these return keys in the accent (blue) colour.
    public var isProminent: Bool {
        switch self {
        case .default, .next: return false
        default: return true
        }
    }
}

/// A language Keibord can type in. Raw values are BCP-47 tags and are persisted.
public enum KeyboardLanguage: String, Codable, CaseIterable, Hashable, Sendable {
    case deAT = "de-AT"
    case enGB = "en-GB"
    case enUS = "en-US"
    case sqAL = "sq-AL"
    case sqXK = "sq-XK"
    case itIT = "it-IT"

    /// Native display name, shown on the space bar and in settings.
    public var displayName: String {
        switch self {
        case .deAT: return "Deutsch (Österreich)"
        case .enGB: return "English (UK)"
        case .enUS: return "English (US)"
        case .sqAL: return "Shqip (Shqipëri)"
        case .sqXK: return "Shqip (Kosovë)"
        case .itIT: return "Italiano"
        }
    }

    /// English name used in the settings app subtitles.
    public var englishName: String {
        switch self {
        case .deAT: return "German (Austria)"
        case .enGB: return "English (UK)"
        case .enUS: return "English (US)"
        case .sqAL: return "Albanian (Albania)"
        case .sqXK: return "Albanian (Kosovo)"
        case .itIT: return "Italian"
        }
    }

    /// Two-letter label shown on the language key.
    public var shortLabel: String {
        switch self {
        case .deAT: return "DE"
        case .enGB: return "UK"
        case .enUS: return "US"
        case .sqAL: return "AL"
        case .sqXK: return "XK"
        case .itIT: return "IT"
        }
    }

    /// ISO 639-1 language code ("de", "en", "sq", "it").
    public var languageCode: String {
        String(rawValue.prefix(2))
    }

    /// Identifier of the bundled dictionary file (`<id>.kbdl`). Albanian variants share one dictionary.
    public var dictionaryID: String {
        switch self {
        case .deAT: return "de-AT"
        case .enGB: return "en-GB"
        case .enUS: return "en-US"
        case .sqAL, .sqXK: return "sq"
        case .itIT: return "it"
        }
    }

    /// Code of the CLDR emoji keyword file (`keywords-<code>.json`).
    public var emojiKeywordCode: String { languageCode }

    public var defaultBaseLayout: BaseLayout {
        switch self {
        case .deAT, .sqAL, .sqXK: return .qwertz
        case .enGB, .enUS, .itIT: return .qwerty
        }
    }

    /// Extra letter keys appended to the end of the first two letter rows
    /// (index 0 = top row, index 1 = home row), like Apple's German layout (ü / ö ä).
    public var extraLetterKeys: [[String]] {
        switch self {
        case .deAT: return [["ü"], ["ö", "ä"]]
        case .sqAL, .sqXK: return [["ç"], ["ë"]]
        case .enGB, .enUS, .itIT: return [[], []]
        }
    }

    /// Currency symbol shown on the first numbers page.
    public var currencySymbol: String {
        switch self {
        case .enGB: return "£"
        case .enUS: return "$"
        case .deAT, .itIT, .sqXK: return "€"
        case .sqAL: return "€"
        }
    }

    public var decimalSeparator: String {
        switch self {
        case .enGB, .enUS: return "."
        default: return ","
        }
    }

    public var defaultQuoteStyle: QuoteStyle {
        switch self {
        case .deAT, .sqAL, .sqXK: return .germanLow
        case .enGB, .enUS, .itIT: return .english
        }
    }

    /// Label for the return key. `nil` means "draw the return glyph (SF Symbol `return`)".
    public func returnKeyLabel(for kind: ReturnKind) -> String? {
        let code = languageCode
        func pick(_ de: String, _ en: String, _ sq: String, _ it: String) -> String {
            switch code {
            case "de": return de
            case "sq": return sq
            case "it": return it
            default: return en
            }
        }
        switch kind {
        case .default: return nil
        case .go: return pick("Los", "go", "Shko", "Vai")
        case .google, .yahoo, .search: return pick("Suchen", "search", "Kërko", "Cerca")
        case .join: return pick("Beitreten", "join", "Bashkohu", "Unisciti")
        case .next: return pick("Weiter", "next", "Tjetër", "Avanti")
        case .route: return pick("Route", "route", "Itinerari", "Percorso")
        case .send: return pick("Senden", "send", "Dërgo", "Invia")
        case .done: return pick("Fertig", "done", "U krye", "Fine")
        case .emergencyCall: return pick("Notruf", "emergency", "Urgjenca", "Emergenza")
        case .continue: return pick("Weiter", "continue", "Vazhdo", "Continua")
        }
    }

    /// Word shown on the space bar when no language label is displayed.
    public var spaceKeyLabel: String {
        switch languageCode {
        case "de": return "Leerzeichen"
        case "sq": return "hapësirë"
        case "it": return "spazio"
        default: return "space"
        }
    }
}

/// One Keibord keyboard in iOS Settings: each language is a keyboard of its own (Keibord Deutsch,
/// English, Shqip, Italiano), switched with the globe key like Apple's keyboards. The regional variant
/// (UK/US English, Albania/Kosovo) comes from the app's language list.
public enum KeyboardLanguageFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case de, en, sq, it

    public var variants: [KeyboardLanguage] {
        switch self {
        case .de: return [.deAT]
        case .en: return [.enGB, .enUS]
        case .sq: return [.sqAL, .sqXK]
        case .it: return [.itIT]
        }
    }

    /// The variant this keyboard types: the first one enabled in the app, else the first variant.
    public func language(enabled: [KeyboardLanguage]) -> KeyboardLanguage {
        enabled.first { $0.family == self } ?? variants[0]
    }

    /// The keyboard's name in iOS Settings and in the globe key's list.
    public var keyboardName: String {
        switch self {
        case .de: return "Keibord Deutsch"
        case .en: return "Keibord English"
        case .sq: return "Keibord Shqip"
        case .it: return "Keibord Italiano"
        }
    }
}

extension KeyboardLanguage {
    public var family: KeyboardLanguageFamily {
        switch self {
        case .deAT: return .de
        case .enGB, .enUS: return .en
        case .sqAL, .sqXK: return .sq
        case .itIT: return .it
        }
    }

    /// Small label at the bottom right of the space bar, like Apple's "DE EN": the language codes of a
    /// keyboard that types in more than one language; empty for a single language.
    public static func spaceBarCodes(_ languages: [KeyboardLanguage]) -> String {
        var codes: [String] = []
        for code in languages.map({ $0.languageCode.uppercased() }) where !codes.contains(code) {
            codes.append(code)
        }
        return codes.count > 1 ? codes.joined(separator: " ") : ""
    }
}
