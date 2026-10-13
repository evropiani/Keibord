import Foundation

/// Lower-case letter ↔ diacritic variant tables used by fuzzy matching (accent restoration)
/// and by long-press menus. All characters are lower-case, NFC, single UTF-16 code units.
public enum Diacritics {
    /// Variant → base letter. "ß" is treated as a variant of "s".
    public static let baseOf: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (base, variants) in variantsOf {
            for v in variants { map[v] = base }
        }
        return map
    }()

    /// Base letter → its diacritic variants (lower-case).
    public static let variantsOf: [Character: [Character]] = [
        "a": ["à", "á", "â", "ä", "ã", "å", "ā", "æ"],
        "c": ["ç", "ć", "č"],
        "d": ["đ", "ď"],
        "e": ["ë", "è", "é", "ê", "ē", "ė", "ę"],
        "g": ["ğ"],
        "i": ["ì", "í", "î", "ï", "ī", "į"],
        "l": ["ł", "ľ"],
        "n": ["ñ", "ń", "ň"],
        "o": ["ö", "ò", "ó", "ô", "õ", "ø", "ō", "œ"],
        "r": ["ř"],
        "s": ["ß", "ś", "š", "ş"],
        "t": ["ť"],
        "u": ["ü", "ù", "ú", "û", "ū", "ů"],
        "y": ["ÿ", "ý"],
        "z": ["ž", "ź", "ż"],
    ]

    /// The base letter for a (lower-case) character, or the character itself if it has no diacritic.
    public static func base(of c: Character) -> Character {
        baseOf[c] ?? c
    }

    /// Same as `base(of:)` but works on UTF-16 code units (used by the trie search).
    public static let baseOfUnit: [UInt16: UInt16] = {
        var map: [UInt16: UInt16] = [:]
        for (variant, base) in baseOf {
            guard let v = String(variant).utf16.first, String(variant).utf16.count == 1,
                  let b = String(base).utf16.first else { continue }
            map[v] = b
        }
        return map
    }()

    /// Removes diacritics from a whole string ("është" → "eshte"). Keeps case-insensitive semantics simple:
    /// the input is lower-cased first.
    public static func fold(_ s: String) -> String {
        String(s.lowercased().map { base(of: $0) })
    }
}
