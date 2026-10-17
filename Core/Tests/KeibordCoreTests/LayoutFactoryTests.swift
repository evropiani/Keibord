import XCTest
@testable import KeibordCore

/// Shared helpers for the layout / geometry / touch tests.
enum LayoutTestSupport {
    /// Every KeyboardLanguage × BaseLayout × LayoutPage × LayoutVariant × number row × language key × globe.
    static func allRequests(returnKind: ReturnKind = .default) -> [LayoutRequest] {
        var out: [LayoutRequest] = []
        for language in KeyboardLanguage.allCases {
            for base in BaseLayout.allCases {
                for page in LayoutPage.allCases {
                    for variant in LayoutVariant.allCases {
                        for numberRow in [false, true] {
                            for languageKey in [false, true] {
                                for globe in [false, true] {
                                    out.append(LayoutRequest(language: language, base: base, page: page, variant: variant,
                                                             showNumberRow: numberRow, showLanguageKey: languageKey,
                                                             showGlobeKey: globe, returnKind: returnKind))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func describe(_ r: LayoutRequest) -> String {
        "\(r.language.rawValue) \(r.base.rawValue) \(r.page.rawValue) \(r.variant.rawValue) numberRow=\(r.showNumberRow) language=\(r.showLanguageKey) globe=\(r.showGlobeKey)"
    }

    static func isPad(_ v: LayoutVariant) -> Bool { v == .numberPad || v == .decimalPad }

    /// The letter rows as strings (letter keys only, in order).
    static func letterRows(_ layout: KeyboardLayout) -> [String] {
        layout.rows.map { $0.keys.filter { $0.isLetter }.map { $0.id }.joined() }.filter { !$0.isEmpty }
    }

    static func ids(_ row: KeyRow) -> [String] { row.keys.filter { $0.isInteractive }.map { $0.id } }

    static func units(_ key: KeySpec) -> Double? {
        if case .units(let u) = key.width { return u }
        return nil
    }
}

final class LayoutFactoryTests: XCTestCase {
    typealias S = LayoutTestSupport

    // MARK: Structure of every combination

    func testEveryCombinationIsWellFormed() {
        for kind in [ReturnKind.default, .go, .search] {
            for r in S.allRequests(returnKind: kind) {
                let layout = LayoutFactory.layout(for: r)
                let what = S.describe(r)
                XCTAssertEqual(layout.language, r.language, what)
                XCTAssertEqual(layout.variant, r.variant, what)
                XCTAssertGreaterThan(layout.unitCount, 0, what)
                XCTAssertFalse(layout.touchModelKey.isEmpty, what)
                XCTAssertGreaterThanOrEqual(layout.rows.count, 4, what)
                for (i, row) in layout.rows.enumerated() {
                    XCTAssertFalse(row.keys.isEmpty, "\(what) row \(i) empty")
                    XCTAssertTrue(row.keys.contains { $0.isInteractive }, "\(what) row \(i) has no interactive key")
                }
                let all = layout.rows.flatMap { $0.keys }
                let ids = all.map { $0.id }
                XCTAssertEqual(Set(ids).count, ids.count, "\(what) duplicate ids: \(ids)")
                for key in all {
                    if let u = S.units(key) {
                        XCTAssertGreaterThan(u, 0, "\(what) key \(key.id)")
                    }
                    XCTAssertEqual(key.isInteractive, key.style != .spacer, "\(what) key \(key.id)")
                    if key.style == .spacer { XCTAssertTrue(key.id.hasPrefix("spacer."), "\(what) \(key.id)") }
                    if key.isLetter {
                        XCTAssertEqual(key.style, .character, what)
                        XCTAssertEqual(key.action, .insert(key.id), what)
                        XCTAssertEqual(key.label, key.id, what)
                        XCTAssertEqual(key.id, key.id.lowercased(), what)
                        XCTAssertEqual(key.width, .units(1), "\(what) letter \(key.id) must be one unit wide")
                    }
                    if key.style == .character, case .insert(let text) = key.action {
                        XCTAssertFalse(text.isEmpty, what)
                        XCTAssertFalse(key.label.isEmpty, what)
                    }
                    if key.style == .character || key.style == .returnKey || key.style == .space {
                        XCTAssertNotEqual(key.action, KeyAction.none, what)
                    }
                }
                // Every layout can delete.
                XCTAssertEqual(all.filter { $0.action == .backspace }.count, 1, what)
                if S.isPad(r.variant) {
                    XCTAssertEqual(layout.unitCount, 3, what)
                    XCTAssertEqual(layout.rows.count, 4, what)
                    continue
                }
                // Exactly one return key, page switcher and emoji/space as specified below.
                XCTAssertEqual(all.filter { $0.action == .returnKey }.count, 1, what)
                XCTAssertEqual(all.filter { $0.id == "return" }.first?.label, r.language.returnKeyLabel(for: kind) ?? "", what)
                XCTAssertEqual(all.filter { $0.action == .shift }.count, r.page == .letters ? 1 : 0, what)
                XCTAssertEqual(all.filter { $0.action == .space }.count, r.variant == .url ? 0 : 1, what)
                XCTAssertEqual(all.filter { $0.action == .nextLanguage }.count, r.showLanguageKey ? 1 : 0, what)
                XCTAssertEqual(all.filter { $0.action == .globe }.count, r.showGlobeKey ? 1 : 0, what)
                XCTAssertLessThanOrEqual(all.filter { $0.action == .emoji }.count, 1, what)
                switch r.page {
                case .letters:
                    XCTAssertEqual(ids.filter { $0 == "numbers" }.count, 1, what)
                    XCTAssertFalse(ids.contains("letters"), what)
                case .numbers:
                    XCTAssertEqual(ids.filter { $0 == "symbols" }.count, 1, what)
                    XCTAssertEqual(ids.filter { $0 == "letters" }.count, 1, what)
                case .symbols:
                    XCTAssertEqual(ids.filter { $0 == "numbers" }.count, 1, what)
                    XCTAssertEqual(ids.filter { $0 == "letters" }.count, 1, what)
                }
                let expectedRows = (r.page == .letters && r.showNumberRow) ? 5 : 4
                XCTAssertEqual(layout.rows.count, expectedRows, what)
                // Rows never need more than the full width of fixed units.
                for row in layout.rows {
                    let fixed = row.keys.compactMap { S.units($0) }.reduce(0, +)
                    XCTAssertLessThanOrEqual(fixed, layout.unitCount + 1e-9, "\(what): \(S.ids(row))")
                }
            }
        }
    }

    // MARK: Letters

    func testGermanQWERTZLetters() {
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz))
        XCTAssertEqual(S.letterRows(layout), ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"])
        XCTAssertEqual(layout.unitCount, 11)
        XCTAssertEqual(layout.page, .letters)
        XCTAssertEqual(layout.touchModelKey, "qwertz11.letters.standard")
        let third = S.ids(layout.rows[2])
        XCTAssertEqual(third.first, "shift")
        XCTAssertEqual(third.last, "backspace")
    }

    func testAlbanianQWERTZLetters() {
        for language in [KeyboardLanguage.sqAL, .sqXK] {
            let layout = LayoutFactory.layout(for: LayoutRequest(language: language, base: .qwertz))
            XCTAssertEqual(S.letterRows(layout), ["qwertzuiopç", "asdfghjklë", "yxcvbnm"], language.rawValue)
            XCTAssertEqual(layout.unitCount, 11, language.rawValue)
            XCTAssertEqual(layout.touchModelKey, "qwertz11.letters.standard")
        }
    }

    func testQWERTYVariants() {
        let expected: [KeyboardLanguage: [String]] = [
            .enGB: ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
            .enUS: ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
            .itIT: ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
            .deAT: ["qwertyuiopü", "asdfghjklöä", "zxcvbnm"],
            .sqAL: ["qwertyuiopç", "asdfghjklë", "zxcvbnm"],
            .sqXK: ["qwertyuiopç", "asdfghjklë", "zxcvbnm"],
        ]
        for (language, rows) in expected {
            let layout = LayoutFactory.layout(for: LayoutRequest(language: language, base: .qwerty))
            XCTAssertEqual(S.letterRows(layout), rows, language.rawValue)
            XCTAssertEqual(layout.unitCount, Double(max(rows[0].count, rows[1].count)), language.rawValue)
            XCTAssertEqual(layout.touchModelKey, "qwerty\(Int(layout.unitCount)).letters.standard")
        }
        let en = LayoutFactory.layout(for: LayoutRequest(language: .enUS, base: .qwertz))
        XCTAssertEqual(S.letterRows(en), ["qwertzuiop", "asdfghjkl", "yxcvbnm"])
    }

    func testYZSwapForEveryLanguage() {
        for language in KeyboardLanguage.allCases {
            let qwertz = S.letterRows(LayoutFactory.layout(for: LayoutRequest(language: language, base: .qwertz)))
            let qwerty = S.letterRows(LayoutFactory.layout(for: LayoutRequest(language: language, base: .qwerty)))
            XCTAssertEqual(Array(qwertz[0])[5], "z", language.rawValue)
            XCTAssertEqual(qwertz[2].first, "y", language.rawValue)
            XCTAssertEqual(Array(qwerty[0])[5], "y", language.rawValue)
            XCTAssertEqual(qwerty[2].first, "z", language.rawValue)
            // Same letters, only y and z exchanged.
            let swapped = qwertz.map { String($0.map { $0 == "y" ? "z" : ($0 == "z" ? "y" : $0) }) }
            XCTAssertEqual(swapped, qwerty, language.rawValue)
            // Every letter of the language's alphabet is directly reachable or via long-press.
            XCTAssertEqual(Set(qwertz.joined()).count, qwertz.joined().count, language.rawValue)
        }
    }

    func testDefaultBaseLayouts() {
        XCTAssertEqual(KeyboardLanguage.deAT.defaultBaseLayout, .qwertz)
        XCTAssertEqual(KeyboardLanguage.sqAL.defaultBaseLayout, .qwertz)
        XCTAssertEqual(KeyboardLanguage.sqXK.defaultBaseLayout, .qwertz)
        XCTAssertEqual(KeyboardLanguage.enGB.defaultBaseLayout, .qwerty)
        XCTAssertEqual(KeyboardLanguage.enUS.defaultBaseLayout, .qwerty)
        XCTAssertEqual(KeyboardLanguage.itIT.defaultBaseLayout, .qwerty)
    }

    func testThirdRowShiftAndBackspaceAreSymmetric() {
        for r in S.allRequests() where r.page == .letters && !S.isPad(r.variant) {
            let layout = LayoutFactory.layout(for: r)
            let row = layout.rows[r.showNumberRow ? 3 : 2]
            XCTAssertEqual(row.keys.first?.id, "shift")
            XCTAssertEqual(row.keys.last?.id, "backspace")
            XCTAssertEqual(row.keys.first?.width, row.keys.last?.width)
            XCTAssertEqual(row.keys.filter { $0.width == .fill }.count, 2, "letters are centred between two spacers")
            let shift = S.units(row.keys.first!)!
            XCTAssertEqual(shift, 1.3 * layout.unitCount / 10, accuracy: 1e-9)
        }
    }

    func testNumberRow() {
        for language in KeyboardLanguage.allCases {
            for base in BaseLayout.allCases {
                let off = LayoutFactory.layout(for: LayoutRequest(language: language, base: base, showNumberRow: false))
                let on = LayoutFactory.layout(for: LayoutRequest(language: language, base: base, showNumberRow: true))
                XCTAssertEqual(on.rows.count, off.rows.count + 1)
                XCTAssertEqual(S.ids(on.rows[0]), "1234567890".map { String($0) })
                XCTAssertEqual(Array(on.rows.dropFirst()), off.rows, "number row only adds a row")
                XCTAssertEqual(on.touchModelKey, off.touchModelKey, "same letter geometry ⇒ same touch model")
                // The digits span the same width as the widest letter row.
                let units = on.rows[0].keys.compactMap { S.units($0) }.reduce(0, +)
                XCTAssertEqual(units, on.unitCount, accuracy: 1e-9, "\(language) \(base)")
                XCTAssertTrue(on.rows[0].keys.allSatisfy { $0.style == .character && !$0.isLetter })
                XCTAssertEqual(on.rows[0].keys.first { $0.id == "1" }?.alternates.first, "¹")
                // Ignored on the other pages.
                for page in [LayoutPage.numbers, .symbols] {
                    let a = LayoutFactory.layout(for: LayoutRequest(language: language, base: base, page: page, showNumberRow: true))
                    let b = LayoutFactory.layout(for: LayoutRequest(language: language, base: base, page: page, showNumberRow: false))
                    XCTAssertEqual(a, b)
                }
            }
        }
    }

    // MARK: Numbers / symbols

    func testCurrencyPerLanguage() {
        let expected: [KeyboardLanguage: String] = [.deAT: "€", .enGB: "£", .enUS: "$", .sqAL: "€", .sqXK: "€", .itIT: "€"]
        for (language, currency) in expected {
            XCTAssertEqual(language.currencySymbol, currency)
            let numbers = LayoutFactory.layout(for: LayoutRequest(language: language, base: language.defaultBaseLayout, page: .numbers))
            XCTAssertEqual(S.ids(numbers.rows[0]), "1234567890".map { String($0) })
            XCTAssertEqual(S.ids(numbers.rows[1]), ["-", "/", ":", ";", "(", ")", currency, "&", "@", "\""], language.rawValue)
            let currencyKey = numbers.rows[1].keys[6]
            XCTAssertEqual(currencyKey.alternates.first, currency, "own currency first in the long-press menu")
            XCTAssertTrue(currencyKey.alternates.contains("¥"))
            XCTAssertEqual(numbers.touchModelKey, "sym10.numbers.standard")
            XCTAssertEqual(numbers.unitCount, 10)

            let symbols = LayoutFactory.layout(for: LayoutRequest(language: language, base: language.defaultBaseLayout, page: .symbols))
            XCTAssertEqual(S.ids(symbols.rows[0]), ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="])
            let row1 = S.ids(symbols.rows[1])
            XCTAssertEqual(row1.count, 10, language.rawValue)
            XCTAssertEqual(Array(row1.prefix(6)), ["_", "\\", "|", "~", "<", ">"])
            XCTAssertEqual(row1.last, "•")
            let currencies = Array(row1[6..<9])
            XCTAssertFalse(currencies.contains(currency), "\(language): symbols page repeats the main currency")
            XCTAssertEqual(Set(currencies).count, 3)
            XCTAssertTrue(Set(currencies).isSubset(of: ["€", "£", "$", "¥"]))
            XCTAssertEqual(symbols.touchModelKey, "sym10.symbols.standard")
        }
    }

    func testPunctuationRows() {
        for page in [LayoutPage.numbers, .symbols] {
            let layout = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz, page: page))
            let row = layout.rows[2]
            XCTAssertEqual(S.ids(row), [page == .numbers ? "symbols" : "numbers", ".", ",", "?", "!", "'", "backspace"])
            XCTAssertEqual(row.keys.first { $0.id == "." }?.alternates, ["…"])
            XCTAssertEqual(row.keys.first { $0.id == "'" }?.alternates.first, "‚")
        }
    }

    // MARK: Number pads

    func testNumberPads() {
        for language in KeyboardLanguage.allCases {
            for page in LayoutPage.allCases {
                for globe in [false, true] {
                    for languageKey in [false, true] {
                        let pad = LayoutFactory.layout(for: LayoutRequest(language: language, base: .qwertz, page: page, variant: .numberPad,
                                                                          showNumberRow: true, showLanguageKey: languageKey, showGlobeKey: globe))
                        XCTAssertEqual(pad.rows.map { $0.keys.map { $0.id } }, [
                            ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"],
                            [globe ? "globe" : "spacer.0", "0", "backspace"],
                        ])
                        XCTAssertEqual(pad.unitCount, 3)
                        XCTAssertEqual(pad.touchModelKey, "pad.numberPad")
                        XCTAssertTrue(pad.rows.flatMap { $0.keys }.allSatisfy { $0.width == .units(1) })
                        XCTAssertEqual(pad.rows[3].keys[0].isInteractive, globe)

                        let decimal = LayoutFactory.layout(for: LayoutRequest(language: language, base: .qwertz, page: page, variant: .decimalPad,
                                                                              showLanguageKey: languageKey, showGlobeKey: globe))
                        let sep = language.decimalSeparator
                        XCTAssertEqual(decimal.rows.map { $0.keys.map { $0.id } }, [
                            ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [sep, "0", "backspace"],
                        ])
                        XCTAssertEqual(decimal.rows[3].keys[0].action, .insert(sep))
                        XCTAssertEqual(decimal.touchModelKey, "pad.decimalPad")
                    }
                }
            }
        }
        XCTAssertEqual(KeyboardLanguage.deAT.decimalSeparator, ",")
        XCTAssertEqual(KeyboardLanguage.enGB.decimalSeparator, ".")
        XCTAssertEqual(KeyboardLanguage.enUS.decimalSeparator, ".")
        XCTAssertEqual(KeyboardLanguage.itIT.decimalSeparator, ",")
        XCTAssertEqual(KeyboardLanguage.sqAL.decimalSeparator, ",")
    }

    // MARK: Bottom rows

    private func bottom(_ r: LayoutRequest) -> [String] {
        S.ids(LayoutFactory.layout(for: r).rows.last!)
    }

    func testBottomRowsPerVariant() {
        for language in KeyboardLanguage.allCases {
            for languageKey in [false, true] {
                for globe in [false, true] {
                    var extras: [String] = []
                    if languageKey { extras.append("language") }
                    if globe { extras.append("globe") }
                    func req(_ page: LayoutPage, _ variant: LayoutVariant) -> LayoutRequest {
                        LayoutRequest(language: language, base: language.defaultBaseLayout, page: page, variant: variant,
                                      showLanguageKey: languageKey, showGlobeKey: globe)
                    }
                    let what = "\(language) language=\(languageKey) globe=\(globe)"
                    XCTAssertEqual(bottom(req(.letters, .standard)), ["numbers", "emoji"] + extras + ["space", "return"], what)
                    XCTAssertEqual(bottom(req(.numbers, .standard)), ["letters", "emoji"] + extras + ["space", "return"], what)
                    XCTAssertEqual(bottom(req(.symbols, .standard)), ["letters", "emoji"] + extras + ["space", "return"], what)

                    // The emoji key may give way to the language + globe keys in the crowded e-mail row
                    // (the globe key still reaches the system emoji keyboard), never otherwise.
                    let email = bottom(req(.letters, .email))
                    let emoji = (languageKey && globe) ? [] : ["emoji"]
                    XCTAssertEqual(email, ["numbers"] + emoji + extras + ["space", "@", ".", "return"], what)
                    XCTAssertEqual(bottom(req(.letters, .webSearch)), ["numbers", "emoji"] + extras + ["space", ".", "return"], what)
                    XCTAssertEqual(bottom(req(.letters, .url)), ["numbers", "emoji"] + extras + [".", "/", "dotcom", "return"], what)

                    // On the other pages, characters that are already on the page are not repeated.
                    XCTAssertEqual(bottom(req(.numbers, .email)), ["letters", "emoji"] + extras + ["space", "return"], what)
                    XCTAssertEqual(bottom(req(.symbols, .email)), ["letters", "emoji"] + extras + ["space", "@", "return"], what)
                    XCTAssertEqual(bottom(req(.numbers, .webSearch)), ["letters", "emoji"] + extras + ["space", "return"], what)
                    XCTAssertEqual(bottom(req(.symbols, .webSearch)), ["letters", "emoji"] + extras + ["space", "return"], what)
                    XCTAssertEqual(bottom(req(.numbers, .url)), ["letters", "emoji"] + extras + ["dotcom", "return"], what)
                    XCTAssertEqual(bottom(req(.symbols, .url)), ["letters", "emoji"] + extras + ["/", "dotcom", "return"], what)
                }
            }
        }
    }

    func testBottomRowKeys() {
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .sqXK, base: .qwertz, variant: .url, showLanguageKey: true))
        let row = layout.rows.last!
        let dotcom = row.keys.first { $0.id == "dotcom" }!
        XCTAssertEqual(dotcom.action, .insert(".com"))
        XCTAssertEqual(dotcom.label, ".com")
        XCTAssertEqual(dotcom.style, .character)
        for tld in [".at", ".de", ".com", ".net", ".org", ".eu", ".it", ".al", ".co.uk"] {
            XCTAssertTrue(dotcom.alternates.contains(tld), tld)
        }
        let language = row.keys.first { $0.id == "language" }!
        XCTAssertEqual(language.label, "XK")
        XCTAssertEqual(language.style, .function)
        XCTAssertEqual(language.action, .nextLanguage)
        for l in KeyboardLanguage.allCases {
            let key = LayoutFactory.layout(for: LayoutRequest(language: l, base: .qwerty, showLanguageKey: true)).allKeys.first { $0.id == "language" }
            XCTAssertEqual(key?.label, l.shortLabel)
            XCTAssertEqual(key?.label.count, 2)
        }
        let standard = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz))
        let keys = standard.rows.last!.keys
        XCTAssertEqual(keys.first { $0.id == "numbers" }?.label, "123")
        XCTAssertEqual(keys.first { $0.id == "numbers" }?.action, .switchPage(.numbers))
        XCTAssertEqual(keys.first { $0.id == "space" }?.width, .fill)
        XCTAssertEqual(keys.first { $0.id == "space" }?.style, .space)
        XCTAssertEqual(keys.first { $0.id == "return" }?.style, .returnKey)
        XCTAssertEqual(keys.first { $0.id == "emoji" }?.action, .emoji)
        let numbers = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz, page: .numbers))
        XCTAssertEqual(numbers.rows.last!.keys.first?.label, "ABC")
        XCTAssertEqual(numbers.rows.last!.keys.first?.action, .switchPage(.letters))
        XCTAssertEqual(numbers.rows[2].keys.first?.label, "#+=")
        XCTAssertEqual(numbers.rows[2].keys.first?.action, .switchPage(.symbols))
    }

    /// iOS-like proportions of the plain bottom row (10-unit row): 123 1.25, emoji 1.25, return 2.4.
    func testPlainBottomRowWidths() {
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .enUS, base: .qwerty))
        let keys = layout.rows.last!.keys
        XCTAssertEqual(S.units(keys[0])!, 1.25, accuracy: 1e-9)
        XCTAssertEqual(S.units(keys[1])!, 1.25, accuracy: 1e-9)
        XCTAssertEqual(S.units(keys.last!)!, 2.4, accuracy: 1e-9)
        let german = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz)).rows.last!.keys
        XCTAssertEqual(S.units(german[0])!, 1.25 * 1.1, accuracy: 1e-9, "scaled by unitCount / 10")
        XCTAssertEqual(S.units(german.last!)!, 2.4 * 1.1, accuracy: 1e-9)
    }

    /// The fixed keys of a bottom row leave enough units for the space bar (or the .com key).
    func testBottomRowLeavesRoomForSpace() {
        for r in S.allRequests() where !S.isPad(r.variant) {
            let layout = LayoutFactory.layout(for: r)
            let row = layout.rows.last!
            let fixed = row.keys.compactMap { S.units($0) }.reduce(0, +)
            let free = (layout.unitCount - fixed) / (layout.unitCount / 10)  // in 10-unit-row units
            let what = S.describe(r)
            if r.variant == .url {
                XCTAssertGreaterThanOrEqual(free, 1.6 - 1e-9, what)
            } else if r.variant == .standard {
                XCTAssertGreaterThanOrEqual(free, 4.0 - 1e-9, what)
            } else {
                XCTAssertGreaterThanOrEqual(free, 3.5 - 1e-9, what)
            }
            // Function keys never shrink below a letter key, the return key never below 1.5 letters.
            for key in row.keys where key.isInteractive && key.width != .fill {
                let minimum = key.id == "return" ? 1.5 : 1.0
                XCTAssertGreaterThanOrEqual(S.units(key)! / (layout.unitCount / 10), minimum - 1e-9, "\(what) \(key.id)")
            }
            // Uncrowded rows keep the preferred iOS widths.
            if !r.showLanguageKey && !r.showGlobeKey {
                XCTAssertEqual(S.units(row.keys[0])! / (layout.unitCount / 10), 1.25, accuracy: 1e-9, what)
                XCTAssertEqual(S.units(row.keys[1])! / (layout.unitCount / 10), 1.25, accuracy: 1e-9, what)
            }
        }
    }

    // MARK: Return key

    func testReturnKeyLabelsForEveryKindAndLanguage() {
        for language in KeyboardLanguage.allCases {
            var labels: [ReturnKind: String] = [:]
            for kind in ReturnKind.allCases {
                for variant in [LayoutVariant.standard, .email, .url, .webSearch] {
                    for page in LayoutPage.allCases {
                        let layout = LayoutFactory.layout(for: LayoutRequest(language: language, base: language.defaultBaseLayout, page: page, variant: variant, returnKind: kind))
                        let key = layout.allKeys.first { $0.id == "return" }
                        XCTAssertNotNil(key)
                        XCTAssertEqual(key?.action, .returnKey)
                        XCTAssertEqual(key?.label, language.returnKeyLabel(for: kind) ?? "")
                    }
                }
                let label = language.returnKeyLabel(for: kind)
                if kind == .default {
                    XCTAssertNil(label, "default return draws the glyph")
                } else {
                    XCTAssertFalse(label?.isEmpty ?? true, "\(language) \(kind)")
                    labels[kind] = label
                }
            }
            XCTAssertEqual(labels[.search], labels[.google])
            XCTAssertEqual(labels[.search], labels[.yahoo])
        }
        XCTAssertEqual(KeyboardLanguage.deAT.returnKeyLabel(for: .send), "Senden")
        XCTAssertEqual(KeyboardLanguage.deAT.returnKeyLabel(for: .search), "Suchen")
        XCTAssertEqual(KeyboardLanguage.enGB.returnKeyLabel(for: .go), "go")
        XCTAssertEqual(KeyboardLanguage.sqXK.returnKeyLabel(for: .send), "Dërgo")
        XCTAssertEqual(KeyboardLanguage.itIT.returnKeyLabel(for: .done), "Fine")
    }

    // MARK: Alternates

    func testAlternatesPerLanguage() {
        func alts(_ c: String, _ l: KeyboardLanguage) -> [String] {
            let layout = LayoutFactory.layout(for: LayoutRequest(language: l, base: l.defaultBaseLayout))
            let key = layout.allKeys.first { $0.id == c }
            XCTAssertNotNil(key, "\(c) missing on \(l)")
            XCTAssertEqual(key?.alternates, Alternates.alternates(for: c, language: l))
            return key?.alternates ?? []
        }
        // German: umlauts / ß first.
        XCTAssertEqual(alts("a", .deAT).first, "ä")
        XCTAssertEqual(alts("o", .deAT).first, "ö")
        XCTAssertEqual(alts("u", .deAT).first, "ü")
        XCTAssertEqual(alts("s", .deAT).first, "ß")
        XCTAssertEqual(alts("e", .deAT).first, "é")
        XCTAssertTrue(alts("c", .deAT).contains("ç"))
        XCTAssertTrue(alts("n", .deAT).contains("ñ"))
        XCTAssertTrue(alts("i", .deAT).contains("í"))
        // Albanian: ë / ç first.
        for l in [KeyboardLanguage.sqAL, .sqXK] {
            XCTAssertEqual(alts("e", l).first, "ë")
            XCTAssertEqual(alts("c", l).first, "ç")
            XCTAssertTrue(alts("ë", l).contains("e"))
            XCTAssertTrue(alts("ç", l).contains("c"))
            XCTAssertTrue(alts("a", l).contains("à"))
        }
        // Italian: grave/acute accents first.
        XCTAssertEqual(Array(alts("e", .itIT).prefix(2)), ["è", "é"])
        XCTAssertEqual(alts("a", .itIT).first, "à")
        XCTAssertEqual(alts("i", .itIT).first, "ì")
        XCTAssertEqual(alts("o", .itIT).first, "ò")
        XCTAssertEqual(alts("u", .itIT).first, "ù")
        // English: the generic Latin set.
        for l in [KeyboardLanguage.enGB, .enUS] {
            XCTAssertTrue(alts("e", l).contains("é"))
            XCTAssertTrue(alts("a", l).contains("ä"))
            XCTAssertTrue(alts("u", l).contains("ü"))
            XCTAssertTrue(alts("s", l).contains("ß"))
            XCTAssertTrue(alts("c", l).contains("ç"))
        }
    }

    func testAlternatesAreWellFormed() {
        for r in S.allRequests() {
            let layout = LayoutFactory.layout(for: r)
            for key in layout.allKeys {
                XCTAssertEqual(Set(key.alternates).count, key.alternates.count, "\(S.describe(r)) duplicate alternates on \(key.id)")
                XCTAssertFalse(key.alternates.contains(""), key.id)
                if key.isLetter {
                    XCTAssertFalse(key.alternates.contains(key.id), "\(key.id) lists itself")
                    for a in key.alternates {
                        XCTAssertEqual(a, a.lowercased(), "\(key.id): \(a) must be lower-case")
                    }
                }
                if key.style == .function || key.style == .space || key.style == .returnKey {
                    XCTAssertTrue(key.alternates.isEmpty, key.id)
                }
            }
        }
    }

    func testSymbolAlternates() {
        let l = KeyboardLanguage.deAT
        XCTAssertEqual(Alternates.alternates(for: "-", language: l), ["–", "—", "•"])
        XCTAssertEqual(Alternates.alternates(for: "\"", language: l).first, "„")
        XCTAssertEqual(Alternates.alternates(for: "?", language: l), ["¿"])
        XCTAssertEqual(Alternates.alternates(for: "&", language: l), ["§"])
        XCTAssertEqual(Alternates.alternates(for: "0", language: l).first, "°")
        XCTAssertEqual(Alternates.alternates(for: "q", language: l), [])
    }
}
