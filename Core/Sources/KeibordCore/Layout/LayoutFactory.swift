import Foundation

/// Builds Apple-style key layouts for every language, page and field variant.
public enum LayoutFactory {
    public static func layout(for r: LayoutRequest) -> KeyboardLayout {
        switch r.variant {
        case .numberPad, .decimalPad:
            return numberPad(r)
        default:
            break
        }
        switch r.page {
        case .letters: return letters(r)
        case .numbers: return numbers(r)
        case .symbols: return symbols(r)
        }
    }

    // MARK: Key helpers

    static func letterKey(_ c: String, _ language: KeyboardLanguage) -> KeySpec {
        KeySpec(id: c, action: .insert(c), label: c, alternates: Alternates.alternates(for: c, language: language), width: .units(1), style: .character, isLetter: true)
    }

    static func charKey(_ c: String, _ language: KeyboardLanguage, width: Double = 1) -> KeySpec {
        KeySpec(id: c, action: .insert(c), label: c, alternates: Alternates.alternates(for: c, language: language), width: .units(width), style: .character)
    }

    static func function(_ id: String, _ action: KeyAction, label: String = "", width: Double) -> KeySpec {
        KeySpec(id: id, action: action, label: label, width: .units(width), style: .function)
    }

    private final class SpacerCounter {
        var n = 0
        func next() -> KeySpec {
            defer { n += 1 }
            return KeySpec(id: "spacer.\(n)", action: .none, label: "", width: .fill, style: .spacer)
        }
    }

    // MARK: Pages

    static func letterRows(_ r: LayoutRequest) -> [[String]] {
        let base: [String]
        switch r.base {
        case .qwertz: base = ["qwertzuiop", "asdfghjkl", "yxcvbnm"]
        case .qwerty: base = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        }
        var rows = base.map { $0.map { String($0) } }
        let extras = r.language.extraLetterKeys
        if extras.count > 0 { rows[0] += extras[0] }
        if extras.count > 1 { rows[1] += extras[1] }
        return rows
    }

    private static func letters(_ r: LayoutRequest) -> KeyboardLayout {
        let lang = r.language
        let rows = letterRows(r)
        let unitCount = Double(max(rows[0].count, rows[1].count))
        let s = unitCount / 10
        let spacers = SpacerCounter()
        var out: [KeyRow] = []
        if r.showNumberRow {
            out.append(KeyRow(keys: "1234567890".map { charKey(String($0), lang) }))
        }
        out.append(KeyRow(keys: rows[0].map { letterKey($0, lang) }))
        out.append(KeyRow(keys: rows[1].map { letterKey($0, lang) }))
        var third: [KeySpec] = [function("shift", .shift, width: 1.3 * s), spacers.next()]
        third += rows[2].map { letterKey($0, lang) }
        third += [spacers.next(), function("backspace", .backspace, width: 1.3 * s)]
        out.append(KeyRow(keys: third))
        out.append(bottomRow(r, pageKey: function("numbers", .switchPage(.numbers), label: "123", width: 1.25 * s), scale: s))
        return KeyboardLayout(language: lang, page: .letters, variant: r.variant, rows: out, unitCount: unitCount,
                              touchModelKey: "\(r.base.rawValue)\(Int(unitCount)).letters.\(r.variant.rawValue)")
    }

    private static func punctuationRow(_ r: LayoutRequest, pageKey: KeySpec) -> KeyRow {
        let spacers = SpacerCounter()
        var keys: [KeySpec] = [pageKey, spacers.next()]
        keys += [".", ",", "?", "!", "'"].map { charKey($0, r.language, width: 1.4) }
        keys += [spacers.next(), function("backspace", .backspace, width: 1.3)]
        return KeyRow(keys: keys)
    }

    private static func numbers(_ r: LayoutRequest) -> KeyboardLayout {
        let lang = r.language
        let row0 = "1234567890".map { charKey(String($0), lang) }
        let row1 = ["-", "/", ":", ";", "(", ")", lang.currencySymbol, "&", "@", "\""].map { charKey($0, lang) }
        let rows = [
            KeyRow(keys: row0),
            KeyRow(keys: row1),
            punctuationRow(r, pageKey: function("symbols", .switchPage(.symbols), label: "#+=", width: 1.3)),
            bottomRow(r, pageKey: function("letters", .switchPage(.letters), label: "ABC", width: 1.25), scale: 1),
        ]
        return KeyboardLayout(language: lang, page: .numbers, variant: r.variant, rows: rows, unitCount: 10,
                              touchModelKey: "sym10.numbers.\(r.variant.rawValue)")
    }

    private static func symbols(_ r: LayoutRequest) -> KeyboardLayout {
        let lang = r.language
        let currencies = ["€", "£", "$", "¥"].filter { $0 != lang.currencySymbol }.prefix(3)
        let row0 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { charKey($0, lang) }
        let row1 = (["_", "\\", "|", "~", "<", ">"] + currencies + ["•"]).map { charKey($0, lang) }
        let rows = [
            KeyRow(keys: row0),
            KeyRow(keys: Array(row1)),
            punctuationRow(r, pageKey: function("numbers", .switchPage(.numbers), label: "123", width: 1.3)),
            bottomRow(r, pageKey: function("letters", .switchPage(.letters), label: "ABC", width: 1.25), scale: 1),
        ]
        return KeyboardLayout(language: lang, page: .symbols, variant: r.variant, rows: rows, unitCount: 10,
                              touchModelKey: "sym10.symbols.\(r.variant.rawValue)")
    }

    private static func bottomRow(_ r: LayoutRequest, pageKey: KeySpec, scale s: Double) -> KeyRow {
        let lang = r.language
        var keys: [KeySpec] = [pageKey, function("emoji", .emoji, width: 1.25 * s)]
        if r.showLanguageKey {
            keys.append(function("language", .nextLanguage, label: lang.shortLabel, width: 1.15 * s))
        }
        if r.showGlobeKey {
            keys.append(function("globe", .globe, width: 1.15 * s))
        }
        let space = KeySpec(id: "space", action: .space, label: "", width: .fill, style: .space)
        func returnKey(_ w: Double) -> KeySpec {
            KeySpec(id: "return", action: .returnKey, label: lang.returnKeyLabel(for: r.returnKind) ?? "", width: .units(w * s), style: .returnKey)
        }
        switch r.variant {
        case .email:
            keys += [space, charKey("@", lang, width: s), charKey(".", lang, width: s), returnKey(2.0)]
        case .url:
            let dotcom = KeySpec(id: "dotcom", action: .insert(".com"), label: ".com",
                                 alternates: [".at", ".de", ".com", ".net", ".org", ".eu", ".it", ".al", ".co.uk"],
                                 width: .fill, style: .character)
            keys += [charKey(".", lang, width: s), charKey("/", lang, width: s), dotcom, returnKey(2.0)]
        case .webSearch:
            keys += [space, charKey(".", lang, width: s), returnKey(2.2)]
        default:
            keys += [space, returnKey(2.4)]
        }
        return KeyRow(keys: keys)
    }

    private static func numberPad(_ r: LayoutRequest) -> KeyboardLayout {
        let lang = r.language
        func digit(_ d: String) -> KeySpec { KeySpec(id: d, action: .insert(d), label: d, style: .character) }
        let left: KeySpec
        if r.variant == .decimalPad {
            left = KeySpec(id: lang.decimalSeparator, action: .insert(lang.decimalSeparator), label: lang.decimalSeparator, style: .character)
        } else if r.showGlobeKey {
            left = function("globe", .globe, width: 1)
        } else {
            left = KeySpec(id: "spacer.0", action: .none, label: "", width: .units(1), style: .spacer)
        }
        let rows = [
            KeyRow(keys: ["1", "2", "3"].map(digit)),
            KeyRow(keys: ["4", "5", "6"].map(digit)),
            KeyRow(keys: ["7", "8", "9"].map(digit)),
            KeyRow(keys: [left, digit("0"), function("backspace", .backspace, width: 1)]),
        ]
        return KeyboardLayout(language: lang, page: .letters, variant: r.variant, rows: rows, unitCount: 3,
                              touchModelKey: "pad.\(r.variant.rawValue)")
    }
}
