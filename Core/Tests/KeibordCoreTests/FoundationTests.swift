import XCTest
@testable import KeibordCore

final class FoundationTests: XCTestCase {
    func testTrailingWord() {
        XCTAssertEqual(TextUnits.trailingWord(in: "Hallo Welt"), "Welt")
        XCTAssertEqual(TextUnits.trailingWord(in: "Hallo "), "")
        XCTAssertEqual(TextUnits.trailingWord(in: "I don't"), "don't")
        XCTAssertEqual(TextUnits.trailingWord(in: "I don'"), "don'")
        XCTAssertEqual(TextUnits.trailingWord(in: "'quoted"), "quoted")
        XCTAssertEqual(TextUnits.trailingWord(in: "është"), "është")
        XCTAssertEqual(TextUnits.trailingWord(in: ""), "")
        XCTAssertEqual(TextUnits.trailingWord(in: "geht’s"), "geht’s")
    }

    func testWords() {
        XCTAssertEqual(TextUnits.words(in: "Ich bin's, 'Hallo' – ok."), ["Ich", "bin's", "Hallo", "ok"])
    }

    func testLookupKeyAndFold() {
        XCTAssertEqual(TextUnits.lookupKey("Don’t"), "don't")
        XCTAssertEqual(Diacritics.fold("Është"), "eshte")
        XCTAssertEqual(Diacritics.base(of: "ß"), "s")
        XCTAssertEqual(Diacritics.baseOfUnit[0x00EB], 0x0065)
    }

    func testSettingsRoundTripAndTolerance() throws {
        var s = KeibordSettings()
        s.enabledLanguages = [.sqXK, .deAT]
        s.appearance.tintedKeys = [TintedKey(keyID: "k", color: RGBAColor(hex: "#FF0000")!)]
        let data = try KeibordJSON.encoder().encode(s)
        let back = try KeibordJSON.decoder().decode(KeibordSettings.self, from: data)
        XCTAssertEqual(back, s)
        let partial = #"{"enabledLanguages":["xx-YY","it-IT"],"autocorrect":false,"unknown":1}"#.data(using: .utf8)!
        let p = try KeibordJSON.decoder().decode(KeibordSettings.self, from: partial)
        XCTAssertEqual(p.enabledLanguages, [.itIT])
        XCTAssertFalse(p.autocorrect)
        XCTAssertTrue(p.smartQuotes)
    }

    func testColorHex() {
        XCTAssertEqual(RGBAColor(hex: "#0A84FF")?.hexString, "#0A84FFFF")
        XCTAssertEqual(RGBAColor(hex: "fff")?.hexString, "#FFFFFFFF")
        XCTAssertNil(RGBAColor(hex: "zz"))
    }

    func testFieldContextVariant() {
        XCTAssertEqual(FieldContext(kind: .email).layoutVariant, .email)
        XCTAssertEqual(FieldContext(kind: .oneTimeCode).layoutVariant, .numberPad)
        XCTAssertFalse(FieldContext(kind: .email).learningAllowed)
        XCTAssertTrue(FieldContext(kind: .text).autocorrectAllowed)
    }

    func testEveryLanguageBelongsToOneKeyboard() {
        for family in KeyboardLanguageFamily.allCases {
            XCTAssertFalse(family.variants.isEmpty)
            for language in family.variants { XCTAssertEqual(language.family, family) }
            XCTAssertEqual(family.language(enabled: []), family.variants[0])
            XCTAssertTrue(family.keyboardName.hasPrefix("Keibord "))
        }
        XCTAssertEqual(Set(KeyboardLanguageFamily.allCases.flatMap(\.variants)), Set(KeyboardLanguage.allCases))
        XCTAssertEqual(KeyboardLanguageFamily.sq.language(enabled: [.deAT, .sqXK, .sqAL]), .sqXK)
        XCTAssertEqual(KeyboardLanguageFamily.en.language(enabled: [.deAT]), .enGB)
    }

    func testSpaceBarShowsTheKeyboardsOwnLanguage() {
        XCTAssertEqual(KeyboardLanguage.deAT.spaceBarCode, "DE")
        XCTAssertEqual(KeyboardLanguage.enUS.spaceBarCode, "EN")
        XCTAssertEqual(KeyboardLanguage.sqXK.spaceBarCode, "SQ")
        XCTAssertEqual(KeyboardLanguage.deAT.languageName, "Deutsch")
        XCTAssertEqual(KeyboardLanguage.enGB.languageName, "English")
        XCTAssertEqual(KeyboardLanguage.sqAL.languageName, "Shqip")
        XCTAssertEqual(KeyboardLanguage.itIT.languageName, "Italiano")
    }
}
