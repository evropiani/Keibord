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
            // The ten digits span the full width of the letter rows (1.1 units each on 11-unit layouts).
            out.append(KeyRow(keys: "1234567890".map { charKey(String($0), lang, width: s) }))
        }
        out.append(KeyRow(keys: rows[0].map { letterKey($0, lang) }))
        out.append(KeyRow(keys: rows[1].map { letterKey($0, lang) }))
        var third: [KeySpec] = [function("shift", .shift, width: 1.3 * s), spacers.next()]
        third += rows[2].map { letterKey($0, lang) }
        third += [spacers.next(), function("backspace", .backspace, width: 1.3 * s)]
        out.append(KeyRow(keys: third))
        out.append(bottomRow(r, pageKey: function("numbers", .switchPage(.numbers), label: "123", width: 1.25 * s), scale: s, above: out))
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
        var rows = [
            KeyRow(keys: row0),
            KeyRow(keys: row1),
            punctuationRow(r, pageKey: function("symbols", .switchPage(.symbols), label: "#+=", width: 1.3)),
        ]
        rows.append(bottomRow(r, pageKey: function("letters", .switchPage(.letters), label: "ABC", width: 1.25), scale: 1, above: rows))
        return KeyboardLayout(language: lang, page: .numbers, variant: r.variant, rows: rows, unitCount: 10,
                              touchModelKey: "sym10.numbers.\(r.variant.rawValue)")
    }

    private static func symbols(_ r: LayoutRequest) -> KeyboardLayout {
        let lang = r.language
        let currencies = ["€", "£", "$", "¥"].filter { $0 != lang.currencySymbol }.prefix(3)
        let row0 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { charKey($0, lang) }
        let row1 = (["_", "\\", "|", "~", "<", ">"] + currencies + ["•"]).map { charKey($0, lang) }
        var rows = [
            KeyRow(keys: row0),
            KeyRow(keys: Array(row1)),
            punctuationRow(r, pageKey: function("numbers", .switchPage(.numbers), label: "123", width: 1.3)),
        ]
        rows.append(bottomRow(r, pageKey: function("letters", .switchPage(.letters), label: "ABC", width: 1.25), scale: 1, above: rows))
        return KeyboardLayout(language: lang, page: .symbols, variant: r.variant, rows: rows, unitCount: 10,
                              touchModelKey: "sym10.symbols.\(r.variant.rawValue)")
    }

    /// Preferred and minimum widths of the bottom-row keys, in units of a 10-unit row
    /// (multiplied by `unitCount / 10` on wider layouts).
    enum BottomRowWidths {
        static let pageKey = 1.25, emoji = 1.25, language = 1.15, globe = 1.15
        /// Return key: 2.4, minus 0.2 for every character key (`@`, `.`, `/`) in the row.
        static let returnKey = 2.4, returnStep = 0.2
        static let minimumFunction = 1.0, minimumReturn = 1.5
        /// Width the fill key (space bar, or `.com` in URL fields) keeps at least.
        static let minimumSpace = 4.0, minimumCrowdedSpace = 3.5, minimumDotCom = 1.6
    }

    /// The bottom row: page key, emoji, [language], [globe], then the variant's keys and return.
    ///
    /// Characters that already appear on the page (e.g. `@` and `.` on the numbers page) are not
    /// repeated, so key ids stay unique. When the optional keys would squeeze the space bar below
    /// its minimum, the function keys and the return key shrink towards their minimum widths; if
    /// that is still not enough (e-mail row with language *and* globe keys) the emoji key gives
    /// way — the globe key still reaches the system emoji keyboard.
    private static func bottomRow(_ r: LayoutRequest, pageKey: KeySpec, scale s: Double, above: [KeyRow]) -> KeyRow {
        typealias W = BottomRowWidths
        let lang = r.language
        let onPage = Set(above.flatMap { $0.keys }.filter { $0.style == .character }.map { $0.id })

        struct Item {
            var key: KeySpec
            var preferred: Double
            var minimum: Double
        }
        var leading: [Item] = [
            Item(key: pageKey, preferred: W.pageKey, minimum: W.minimumFunction),
            Item(key: function("emoji", .emoji, width: W.emoji), preferred: W.emoji, minimum: W.minimumFunction),
        ]
        if r.showLanguageKey {
            leading.append(Item(key: function("language", .nextLanguage, label: lang.shortLabel, width: W.language),
                                preferred: W.language, minimum: W.minimumFunction))
        }
        if r.showGlobeKey {
            leading.append(Item(key: function("globe", .globe, width: W.globe), preferred: W.globe, minimum: W.minimumFunction))
        }

        var fill = KeySpec(id: "space", action: .space, label: "", width: .fill, style: .space)
        var characters: [String] = []
        var fillFirst = true
        switch r.variant {
        case .email:
            characters = ["@", "."]
        case .url:
            fill = KeySpec(id: "dotcom", action: .insert(".com"), label: ".com",
                           alternates: [".at", ".de", ".com", ".net", ".org", ".eu", ".it", ".al", ".co.uk"],
                           width: .fill, style: .character)
            characters = [".", "/"]
            fillFirst = false
        case .webSearch:
            characters = ["."]
        default:
            break
        }
        let charItems = characters.filter { !onPage.contains($0) }.map { Item(key: charKey($0, lang), preferred: 1, minimum: 1) }
        let returnPreferred = W.returnKey - W.returnStep * Double(charItems.count)
        let returnItem = Item(key: KeySpec(id: "return", action: .returnKey, label: lang.returnKeyLabel(for: r.returnKind) ?? "",
                                           width: .units(returnPreferred), style: .returnKey),
                              preferred: returnPreferred, minimum: W.minimumReturn)
        let minimumFill = r.variant == .url ? W.minimumDotCom : (charItems.isEmpty ? W.minimumSpace : W.minimumCrowdedSpace)

        let total = 10.0, epsilon = 1e-9
        func minimumSum() -> Double { (leading + charItems + [returnItem]).reduce(0) { $0 + $1.minimum } }
        if r.showGlobeKey, minimumSum() + minimumFill > total + epsilon {
            leading.removeAll { $0.key.id == "emoji" }
        }
        let fixed = leading + charItems + [returnItem]
        let preferred = fixed.reduce(0) { $0 + $1.preferred }
        let minimum = fixed.reduce(0) { $0 + $1.minimum }
        let budget = total - minimumFill
        // 0 = preferred widths … 1 = minimum widths.
        var squeeze = 0.0
        if preferred > budget + epsilon, preferred - minimum > epsilon {
            squeeze = min(1, (preferred - budget) / (preferred - minimum))
        }
        func sized(_ item: Item) -> KeySpec {
            var key = item.key
            key.width = .units((item.preferred - (item.preferred - item.minimum) * squeeze) * s)
            return key
        }

        var keys = leading.map(sized)
        if fillFirst { keys.append(fill) }
        keys += charItems.map(sized)
        if !fillFirst { keys.append(fill) }
        keys.append(sized(returnItem))
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
