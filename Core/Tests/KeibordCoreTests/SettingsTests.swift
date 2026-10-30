import XCTest
@testable import KeibordCore

/// Tolerant decoding of every persisted model: missing, extra, wrongly typed fields and values from a
/// newer version only ever affect the field concerned.
final class SettingsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try KeibordJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try KeibordJSON.encoder().encode(value)
        XCTAssertEqual(try KeibordJSON.decoder().decode(T.self, from: data), value, file: file, line: line)
    }

    private var customSettings: KeibordSettings {
        var s = KeibordSettings()
        s.enabledLanguages = [.sqXK, .deAT, .itIT]
        s.layoutOverrides = ["sq-XK": .qwerty]
        s.quoteStyleOverrides = ["de-AT": .guillemets]
        s.autocorrect = false
        s.incognito = true
        s.haptics = .strong
        s.keySound = true
        s.appearance.themeMode = .dark
        s.appearance.keyHeight = .tall
        s.appearance.labelScale = 1.2
        s.appearance.keyCornerRadius = 4
        s.appearance.showNumberRow = true
        s.appearance.lightColors = .systemDark
        s.appearance.tintedKeys = [TintedKey(keyID: "return", color: RGBAColor(hex: "#FF0000")!),
                                   TintedKey(keyID: "k", color: RGBAColor(hex: "#00FF00")!, labelColor: .black)]
        s.favoriteEmoji = ["❤️", "😂", "🇦🇹"]
        return s
    }

    func testStickerListKeepsEachImageOnceAndSkipsDamagedEntries() throws {
        var index = StickerIndex()
        let date = Date(timeIntervalSince1970: 1_800_000_000) // whole seconds, as the JSON keeps them
        XCTAssertEqual(index.add(StickerEntry(id: "a", contentKey: "glyph:1", label: "cat", hasGlyph: true, added: date)), .added)
        XCTAssertEqual(index.add(StickerEntry(id: "b", contentKey: "glyph:1", added: date)), .duplicate)
        XCTAssertEqual(index.add(StickerEntry(id: "c", contentKey: "image:2", added: date)), .added)
        XCTAssertEqual(index.stickers.map(\.id), ["a", "c"], "in the order they were added")
        try roundTrip(index)
        index.remove(ids: ["a"])
        XCTAssertEqual(index.stickers.map(\.id), ["c"])
        var full = StickerIndex(stickers: (0..<StickerIndex.maxCount).map { StickerEntry(id: "\($0)", contentKey: "k\($0)") })
        XCTAssertEqual(full.add(StickerEntry(id: "x", contentKey: "new")), .full)

        let json = """
        {"stickers": [{"id": "a", "contentKey": "glyph:1", "hasGlyph": "yes"}, {"label": "no id"}, 7,
                      {"id": "b", "contentKey": "glyph:1"}, {"id": "c"}, {"id": "a", "contentKey": "other"}], "future": 1}
        """
        let decoded = try decode(StickerIndex.self, json)
        XCTAssertEqual(decoded.stickers.map(\.id), ["a", "c"], "damaged entries and repeated images are skipped")
        XCTAssertFalse(decoded.stickers[0].hasGlyph)
        XCTAssertEqual(decoded.stickers[1].contentKey, "c")
        XCTAssertEqual(try decode(StickerIndex.self, "{}"), StickerIndex())
        XCTAssertEqual(StickerIndex.contentHash(Data([1, 2, 3])), StickerIndex.contentHash(Data([1, 2, 3])))
        XCTAssertNotEqual(StickerIndex.contentHash(Data([1, 2, 3])), StickerIndex.contentHash(Data([1, 2, 4])))
    }

    func testFavoriteEmojiAreEmojiOnlyEachOnceAndAtMostEight() throws {
        var s = KeibordSettings()
        s.favoriteEmoji = ["😀", "a", "😀", "❤️", "7️⃣", "🇦🇹", "👍🏽", "👨‍👩‍👧", "🙂", "😉", "🥳", "😎"]
        XCTAssertEqual(s.favoriteEmoji, ["😀", "❤️", "7️⃣", "🇦🇹", "👍🏽", "👨‍👩‍👧", "🙂", "😉"])
        let decoded = try decode(KeibordSettings.self, #"{"favoriteEmoji": ["🥳", 5, "hi", "🥳", "😎"]}"#)
        XCTAssertEqual(decoded.favoriteEmoji, ["🥳", "😎"])
        XCTAssertEqual(try decode(KeibordSettings.self, #"{"favoriteEmoji": "🥳"}"#).favoriteEmoji, [])
        XCTAssertEqual(EmojiText.emoji(in: "hi 👋🏼 du ❤️!"), ["👋🏼", "❤️"])
        XCTAssertFalse(EmojiText.isEmoji("1"))
        XCTAssertFalse(EmojiText.isEmoji("😀😀"))
    }

    // MARK: KeibordSettings

    func testSettingsRoundTripAndDefaults() throws {
        try roundTrip(KeibordSettings())
        try roundTrip(customSettings)
        XCTAssertEqual(try decode(KeibordSettings.self, "{}"), KeibordSettings())
        XCTAssertThrowsError(try decode(KeibordSettings.self, "[]"))
        XCTAssertThrowsError(try decode(KeibordSettings.self, "\"settings\""))
    }

    func testUnknownEnumValuesOnlyResetTheirField() throws {
        var json = try XCTUnwrap(String(data: KeibordJSON.encoder().encode(customSettings), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"haptics\":\"strong\"", with: "\"haptics\":\"ultra\"")
            .replacingOccurrences(of: "\"themeMode\":\"dark\"", with: "\"themeMode\":\"sepia\"")
            .replacingOccurrences(of: "\"keyHeight\":\"tall\"", with: "\"keyHeight\":\"huge\"")
        XCTAssertTrue(json.contains("ultra") && json.contains("sepia") && json.contains("huge"))
        let decoded = try decode(KeibordSettings.self, json)
        var expected = customSettings
        expected.haptics = KeibordSettings().haptics
        expected.appearance.themeMode = .system
        expected.appearance.keyHeight = .standard
        XCTAssertEqual(decoded, expected)
    }

    func testWronglyTypedMissingAndExtraFields() throws {
        let json = """
        {"version": "two", "autocorrect": "yes", "incognito": true, "keySound": 1, "haptics": 3,
         "enabledLanguages": "de-AT", "futureSetting": {"x": [1, 2]}, "predictiveText": null,
         "appearance": {"labelScale": "big", "keyShadows": false, "showNumberRow": true, "futureColour": "#FFF",
                        "lightColors": {"characterKey": "#FFF"}, "keyCornerRadius": 99}}
        """
        let s = try decode(KeibordSettings.self, json)
        let d = KeibordSettings()
        XCTAssertEqual(s.version, d.version)
        XCTAssertEqual(s.autocorrect, d.autocorrect)
        XCTAssertTrue(s.incognito)
        XCTAssertEqual(s.keySound, d.keySound)
        XCTAssertEqual(s.haptics, d.haptics)
        XCTAssertEqual(s.predictiveText, d.predictiveText)
        XCTAssertEqual(s.enabledLanguages, d.enabledLanguages)
        XCTAssertEqual(s.appearance.labelScale, 1.0)
        XCTAssertFalse(s.appearance.keyShadows)
        XCTAssertTrue(s.appearance.showNumberRow)
        XCTAssertNil(s.appearance.lightColors, "an incomplete colour scheme falls back to the system colours")
        XCTAssertEqual(s.appearance.keyCornerRadius, 16, "clamped to the range the app offers")
        XCTAssertEqual(try decode(KeibordSettings.self, #"{"appearance": {"labelScale": 0.1}}"#).appearance.labelScale, 0.8)
        XCTAssertEqual(try decode(KeibordSettings.self, #"{"appearance": "dark"}"#).appearance, AppearanceSettings())
    }

    func testLanguagesAndOverridesFromANewerVersion() throws {
        let json = """
        {"enabledLanguages": ["fr-FR", "sq-XK", 7, "de-AT", "sq-XK", null],
         "layoutOverrides": {"de-AT": "azerty", "sq-XK": "qwerty", "it-IT": 1},
         "quoteStyleOverrides": {"de-AT": {"doubleOpen": "«"}, "it-IT": {"doubleOpen": "«", "doubleClose": "»", "singleOpen": "‹", "singleClose": "›", "apostrophe": "’"}}}
        """
        let s = try decode(KeibordSettings.self, json)
        XCTAssertEqual(s.enabledLanguages, [.sqXK, .deAT], "unknown codes and duplicates are dropped")
        XCTAssertEqual(s.layoutOverrides, ["sq-XK": .qwerty])
        XCTAssertEqual(s.quoteStyleOverrides, ["it-IT": .guillemets])
        XCTAssertEqual(s.baseLayout(for: .deAT), .qwertz)
        XCTAssertEqual(try decode(KeibordSettings.self, #"{"enabledLanguages": ["fr-FR"]}"#).enabledLanguages, KeibordSettings().enabledLanguages)
        XCTAssertEqual(try decode(KeibordSettings.self, #"{"enabledLanguages": []}"#).activeLanguages, KeibordSettings().enabledLanguages)
    }

    func testOneDamagedTintedKeyKeepsTheOthers() throws {
        let json = """
        {"appearance": {"tintedKeys": [{"keyID": "return", "color": "#FF0000"}, {"keyID": "k", "color": "not a colour"},
          {"color": "#00FF00"}, "space", {"keyID": "space", "color": "#0000FF", "labelColor": "#XYZ", "extra": true}]}}
        """
        let keys = try decode(KeibordSettings.self, json).appearance.tintedKeys
        XCTAssertEqual(keys, [TintedKey(keyID: "return", color: RGBAColor(hex: "#FF0000")!),
                              TintedKey(keyID: "space", color: RGBAColor(hex: "#0000FF")!)])
        try roundTrip(TintedKey(keyID: "k", color: .white, labelColor: .black))
    }

    func testEncodedKeysStayStable() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: KeibordJSON.encoder().encode(KeibordSettings())) as? [String: Any])
        for key in ["version", "enabledLanguages", "autocorrect", "haptics", "appearance", "learnWords", "incognito", "adaptiveTouch"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertEqual(object["enabledLanguages"] as? [String], ["de-AT", "en-GB"])
        XCTAssertEqual(object["haptics"] as? String, "light")
    }

    // MARK: Profile

    func testProfileToleratesDamagedShortcutsAndFields() throws {
        let id = UUID()
        let json = """
        {"info": {"givenName": "Senad", "emails": ["a@b.at", 5, "c@d.at"], "phones": "0664", "city": 1010, "nickname": null},
         "shortcuts": [{"id": "\(id.uuidString)", "shortcut": "lg", "phrase": "Liebe Grüße"},
                       {"shortcut": "mfg", "phrase": "Mit freundlichen Grüßen"},
                       {"id": "nope", "shortcut": "omw", "phrase": "On my way"},
                       {"shortcut": "  ", "phrase": "empty"}, 42, {"id": "\(UUID().uuidString)"}],
         "cards": [1, 2]}
        """
        let p = try decode(PersonalProfile.self, json)
        XCTAssertEqual(p.info.givenName, "Senad")
        XCTAssertEqual(p.info.emails, ["a@b.at", "c@d.at"])
        XCTAssertEqual(p.info.phones, [])
        XCTAssertEqual(p.info.city, "")
        XCTAssertEqual(p.shortcuts.map(\.shortcut), ["lg", "mfg", "omw"])
        XCTAssertEqual(p.shortcuts.first?.id, id)
        XCTAssertEqual(Set(p.shortcuts.map(\.id)).count, 3, "missing ids are generated")
        XCTAssertEqual(try decode(PersonalProfile.self, "{}"), PersonalProfile())
        var full = PersonalProfile(shortcuts: [TextShortcut(shortcut: "lg", phrase: "Liebe Grüße")])
        full.info.familyName = "Hamza"
        full.info.usernames = ["senad"]
        try roundTrip(full)
    }

    // MARK: UserModel and runtime state

    func testUserModelKeepsEverythingButTheDamagedEntries() throws {
        let json = """
        {"version": 1, "futureField": true,
         "words": {"Paradeiser": {"count": 5, "lastUsedDay": 20000, "language": "de-AT", "addedManually": false},
                   "leiwand": {"count": 3, "lastUsedDay": 20001},
                   "kaputt": {"count": "many"}, "kaputt2": "x", "neu": {},
                   "minus": {"count": -4, "lastUsedDay": 1, "addedManually": true, "language": 7}},
         "bigrams": {"voll\\u001fleiwand": 2, "bad\\u001fpair": "2"},
         "blocked": ["fuck", 3, "oida"],
         "touch": {"g|a": {"sumDX": 1.5, "sumDY": -0.5, "count": 12}, "g|b": {"count": "x"}, "g|c": [1]},
         "emoji": {"😂": {"count": 2, "lastUsed": 1700000000}, "❤️": {"count": 1}, "👍": 5},
         "languageUsage": {"de-AT": 10, "sq-XK": "x"}}
        """
        let m = try decode(UserModel.self, json)
        XCTAssertEqual(m.words["Paradeiser"], LearnedWord(count: 5, lastUsedDay: 20000, language: "de-AT"))
        XCTAssertEqual(m.words["leiwand"], LearnedWord(count: 3, lastUsedDay: 20001), "fields added later default")
        XCTAssertEqual(m.words["kaputt"], LearnedWord(count: 1, lastUsedDay: 0))
        XCTAssertNil(m.words["kaputt2"])
        XCTAssertEqual(m.words["neu"], LearnedWord(count: 1, lastUsedDay: 0))
        XCTAssertEqual(m.words["minus"], LearnedWord(count: 0, lastUsedDay: 1, addedManually: true))
        XCTAssertEqual(m.bigrams, ["voll\u{1F}leiwand": 2])
        XCTAssertEqual(m.blocked, ["fuck", "oida"])
        XCTAssertEqual(m.touch["g|a"], TouchStat(sumDX: 1.5, sumDY: -0.5, count: 12))
        XCTAssertEqual(m.touch["g|b"], TouchStat())
        XCTAssertNil(m.touch["g|c"])
        XCTAssertEqual(m.emoji["😂"], EmojiStat(count: 2, lastUsed: 1_700_000_000))
        XCTAssertEqual(m.emoji["❤️"], EmojiStat(count: 1, lastUsed: 0))
        XCTAssertNil(m.emoji["👍"])
        XCTAssertEqual(m.languageUsage, ["de-AT": 10])
        XCTAssertEqual(try decode(UserModel.self, #"{"words": [1, 2], "blocked": "x"}"#), UserModel())
        try roundTrip(m)
    }

    func testHugeCountsAreClampedSoMergingCannotOverflow() throws {
        // A damaged or hand-made backup with Int.max counts used to crash the app on a merge import
        // (integer overflow when the counts were added up).
        let max = "9223372036854775807"
        let json = """
        {"words": {"leiwand": {"count": \(max), "lastUsedDay": 1}, "Leiwand": {"count": \(max), "lastUsedDay": 2}},
         "bigrams": {"voll\\u001fleiwand": \(max), "zero\\u001fpair": 0, "neg\\u001fpair": -3},
         "touch": {"g|a": {"sumDX": 1e308, "sumDY": -1e308, "count": \(max)}, "g|b": {"sumDX": 50, "sumDY": -0.5, "count": 10}},
         "emoji": {"😂": {"count": \(max), "lastUsed": 1}},
         "languageUsage": {"de-AT": \(max), "it-IT": -5}}
        """
        let m = try decode(UserModel.self, json)
        let limit = UserModel.maxCount
        XCTAssertEqual(m.words["leiwand"]?.count, limit)
        XCTAssertEqual(m.bigrams, ["voll\u{1F}leiwand": limit], "pairs that were never seen are dropped")
        XCTAssertEqual(m.touch["g|a"], TouchStat(sumDX: Double(limit), sumDY: -Double(limit), count: limit))
        XCTAssertEqual(m.touch["g|b"], TouchStat(sumDX: 10, sumDY: -0.5, count: 10), "each sample lies within ±1 key size")
        XCTAssertEqual(m.emoji["😂"]?.count, limit)
        XCTAssertEqual(m.languageUsage, ["de-AT": limit, "it-IT": 0])

        var merged = m.merged(with: m)
        merged.apply({ var d = UserModelDelta(); d.record(.committedWord(final: "leiwand", typed: "leiwand", previous: "voll", language: .deAT, taps: nil, wasAutocorrected: false)); return d }())
        merged.prune()
        XCTAssertEqual(merged.words["leiwand"]?.count, 2 * limit + 1)
        XCTAssertEqual(merged.knownWords().first?.word, "leiwand")
        XCTAssertEqual(merged.knownWords().first?.zipf, 6)
        // Saved and loaded again, the counts are back within the limit (repeated merges cannot grow them).
        let reloaded = try KeibordJSON.decoder().decode(UserModel.self, from: KeibordJSON.encoder().encode(merged))
        XCTAssertEqual(reloaded.words["leiwand"]?.count, limit)
        XCTAssertEqual(reloaded.touch["g|a"]?.count, limit)
        XCTAssertTrue(reloaded.touch.values.allSatisfy { $0.sumDX.isFinite && $0.sumDY.isFinite })
    }

    func testKeyboardRuntimeState() throws {
        let state = KeyboardRuntimeState(currentLanguage: .sqXK, lastActive: Date(timeIntervalSince1970: 1_760_000_000), hasFullAccess: true,
                                         keyboardVersion: "1.0.0 (1)", appGroupIdentifier: "group.com.keibord.app")
        try roundTrip(state)
        let s = try decode(KeyboardRuntimeState.self, #"{"currentLanguage": "fr-FR", "lastActive": "yesterday", "hasFullAccess": "yes", "keyboardVersion": 1, "appGroupIdentifier": "group.x", "new": 1}"#)
        XCTAssertEqual(s, KeyboardRuntimeState(appGroupIdentifier: "group.x"))
        XCTAssertEqual(try decode(KeyboardRuntimeState.self, "{}"), KeyboardRuntimeState())
    }

    func testFileNames() {
        XCTAssertEqual(Set(KeibordFile.allCases.map(\.rawValue)).count, KeibordFile.allCases.count)
        XCTAssertEqual(KeibordFile.userModel.rawValue, "user-model.json")
    }

    // MARK: iOS 26 look

    func testOldSettingsLoseTheKeyShadowsIOS26KeysDoNotHave() throws {
        let old = try decode(KeibordSettings.self, #"{"version": 1, "appearance": {"keyShadows": true, "labelScale": 0.8}}"#)
        XCTAssertFalse(old.appearance.keyShadows)
        XCTAssertEqual(old.appearance.labelScale, 0.8, "only the shadows change")
        XCTAssertEqual(old.version, KeibordSettings.currentVersion)
        let chosen = try decode(KeibordSettings.self, #"{"version": 2, "appearance": {"keyShadows": true}}"#)
        XCTAssertTrue(chosen.appearance.keyShadows, "turned on again after the change: kept")
        XCTAssertFalse(KeibordSettings().appearance.keyShadows)
        XCTAssertEqual(try decode(KeibordSettings.self, #"{"version": 9}"#).version, 9, "a newer file keeps its version")
    }

    func testIOS26ColoursShareOneKeyColour() {
        for scheme in [KeyColorScheme.systemLight, .systemDark] {
            XCTAssertEqual(scheme.characterKey, scheme.functionKey, "function keys look like letter keys on iOS 26")
            XCTAssertNotEqual(scheme.pressedFunctionKey, scheme.characterKey, "a pressed key still shows")
            XCTAssertNil(scheme.background)
        }
        XCTAssertEqual(KeyColorScheme.systemLight.characterKey.hexString, "#FFFFFFFF")
        XCTAssertEqual(KeyColorScheme.systemDark.characterKey.hexString, "#454545FF")
    }
}
