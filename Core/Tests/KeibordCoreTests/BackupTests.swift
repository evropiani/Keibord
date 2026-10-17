import XCTest
@testable import KeibordCore

/// XOR "cipher" with a one-byte tag so a wrong key is detected (stands in for AES-GCM on iOS).
private final class TestCipher: BackupCipher {
    private(set) var derivations: [Int] = []

    func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        derivations.append(iterations)
        return Data((Array(password.utf8) + Array(salt)).prefix(32))
    }

    func seal(_ plaintext: Data, key: Data) throws -> Data {
        let k = Array(key)
        return Data([tag(k)] + plaintext.enumerated().map { $0.element ^ k[$0.offset % k.count] })
    }

    func open(_ combined: Data, key: Data) throws -> Data {
        let k = Array(key)
        guard combined.first == tag(k) else { throw BackupError.wrongPassword }
        return Data(combined.dropFirst().enumerated().map { $0.element ^ k[$0.offset % k.count] })
    }

    func randomBytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }) }

    private func tag(_ k: [UInt8]) -> UInt8 { UInt8(truncatingIfNeeded: k.reduce(0) { $0 &+ Int($1) }) }
}

final class BackupTests: XCTestCase {
    private func samplePayload(profile: Bool = true) -> BackupPayload {
        var model = UserModel()
        model.addWord("Paradeiser", day: 20_000)
        model.words["leiwand"] = LearnedWord(count: 4, lastUsedDay: 20_001, language: "de-AT")
        model.bigrams[UserModel.bigramKey("voll", "leiwand")] = 3
        model.blocked = ["oida"]
        model.touch["g|a"] = TouchStat(sumDX: 1.25, sumDY: -0.5, count: 12)
        model.emoji["😂"] = EmojiStat(count: 3, lastUsed: 1_760_000_000)
        model.languageUsage = ["de-AT": 40, "sq-XK": 3]
        var settings = KeibordSettings()
        settings.enabledLanguages = [.deAT, .sqXK]
        settings.haptics = .medium
        var p = PersonalProfile(shortcuts: [TextShortcut(shortcut: "lg", phrase: "Liebe Grüße")])
        p.info.givenName = "Senad"
        p.info.emails = ["senad@example.at"]
        return BackupPayload(createdAt: Date(timeIntervalSince1970: 1_760_000_000), appVersion: "1.0.0 (1)", settings: settings,
                             profile: profile ? p : nil, userModel: model)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertError(_ expected: BackupError, _ body: @autoclosure () throws -> BackupPayload, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? BackupError, expected, file: file, line: line)
        }
    }

    private func assertCorrupted(_ body: @autoclosure () throws -> BackupPayload, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .corrupted = error as? BackupError else { return XCTFail("\(error)", file: file, line: line) }
        }
    }

    // MARK: Round trips

    func testPlainRoundTrip() throws {
        for payload in [samplePayload(), samplePayload(profile: false)] {
            let data = try BackupFile.encode(payload, password: nil, cipher: nil)
            XCTAssertFalse(BackupFile.isEncrypted(data))
            XCTAssertEqual(try BackupFile.decode(data, password: nil, cipher: nil), payload)
            XCTAssertEqual(try BackupFile.decode(data, password: "ignored", cipher: TestCipher()), payload)
            let object = try json(data)
            XCTAssertEqual(object["format"] as? String, "keibord-backup")
            XCTAssertEqual(object["version"] as? Int, 1)
            XCTAssertEqual(object["encrypted"] as? Bool, false)
            XCTAssertNotNil(object["payload"])
        }
        // An empty password means "not encrypted".
        let data = try BackupFile.encode(samplePayload(), password: "", cipher: TestCipher())
        XCTAssertFalse(BackupFile.isEncrypted(data))
    }

    func testEncryptedRoundTrip() throws {
        let cipher = TestCipher()
        let payload = samplePayload()
        let data = try BackupFile.encode(payload, password: "geheim", cipher: cipher, iterations: 1000)
        XCTAssertTrue(BackupFile.isEncrypted(data))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("Paradeiser") || text.contains("Senad"), "nothing readable in an encrypted file")
        let object = try json(data)
        XCTAssertEqual(object["encrypted"] as? Bool, true)
        XCTAssertNil(object["payload"])
        XCTAssertEqual(object["cipher"] as? String, "AES-GCM-256")
        let kdf = try XCTUnwrap(object["kdf"] as? [String: Any])
        XCTAssertEqual(kdf["name"] as? String, "PBKDF2-SHA256")
        XCTAssertEqual(kdf["iterations"] as? Int, 1000)
        XCTAssertEqual(Data(base64Encoded: kdf["salt"] as? String ?? "")?.count, 16)
        XCTAssertEqual(try BackupFile.decode(data, password: "geheim", cipher: cipher), payload)
        XCTAssertEqual(cipher.derivations, [1000, 1000])
        XCTAssertEqual(try BackupFile.encode(payload, password: "x", cipher: cipher).count > 0, true, "default iterations are accepted")
    }

    // MARK: Errors

    func testPasswordErrors() throws {
        let data = try BackupFile.encode(samplePayload(), password: "geheim", cipher: TestCipher(), iterations: 10)
        assertError(.passwordRequired, try BackupFile.decode(data, password: nil, cipher: TestCipher()))
        assertError(.passwordRequired, try BackupFile.decode(data, password: "", cipher: TestCipher()))
        assertError(.wrongPassword, try BackupFile.decode(data, password: "falsch", cipher: TestCipher()))
        assertError(.wrongPassword, try BackupFile.decode(data, password: "Geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(data, password: "geheim", cipher: nil))
        XCTAssertThrowsError(try BackupFile.encode(samplePayload(), password: "geheim", cipher: nil))
        XCTAssertThrowsError(try BackupFile.encode(samplePayload(), password: "geheim", cipher: TestCipher(), iterations: 0))
    }

    func testCorruptedEncryptedFiles() throws {
        let payload = samplePayload()
        let data = try BackupFile.encode(payload, password: "geheim", cipher: TestCipher(), iterations: 10)
        func modified(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = try json(data)
            change(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }
        func kdf(_ key: String, _ value: Any) throws -> Data {
            try modified { o in
                var k = o["kdf"] as! [String: Any]
                k[key] = value
                o["kdf"] = k
            }
        }
        assertCorrupted(try BackupFile.decode(modified { $0["box"] = "%%% not base64 %%%" }, password: "geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(modified { $0["box"] = "" }, password: "geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(modified { $0["box"] = nil; $0["encrypted"] = true }, password: "geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(modified { $0["kdf"] = nil }, password: "geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(kdf("salt", "***"), password: "geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(kdf("name", "scrypt"), password: "geheim", cipher: TestCipher()))
        assertCorrupted(try BackupFile.decode(modified { $0["cipher"] = "ChaCha20" }, password: "geheim", cipher: TestCipher()))
        // Iteration counts that would crash (negative → UInt32) or hang the iOS key derivation are
        // rejected before deriving a key.
        for iterations in [0, -1, Int(UInt32.max) + 1, 50_000_000] {
            let cipher = TestCipher()
            assertCorrupted(try BackupFile.decode(kdf("iterations", iterations), password: "geheim", cipher: cipher))
            XCTAssertTrue(cipher.derivations.isEmpty)
        }
        // A damaged box is indistinguishable from a wrong password with AES-GCM.
        let flipped = try modified { o in
            var box = Data(base64Encoded: o["box"] as! String)!
            box[0] ^= 0xFF
            o["box"] = box.base64EncodedString()
        }
        assertError(.wrongPassword, try BackupFile.decode(flipped, password: "geheim", cipher: TestCipher()))
        // The right key but an unreadable plaintext.
        let cipher = TestCipher()
        let salt = Data([1, 2, 3])
        let key = try cipher.deriveKey(password: "pw", salt: salt, iterations: 5)
        let garbage = try modified { o in
            o["kdf"] = ["name": "PBKDF2-SHA256", "iterations": 5, "salt": salt.base64EncodedString()]
            o["box"] = try! cipher.seal(Data("not json".utf8), key: key).base64EncodedString()
        }
        assertCorrupted(try BackupFile.decode(garbage, password: "pw", cipher: cipher))
        // "encrypted" missing: a box means the file is encrypted.
        let noFlag = try modified { $0["encrypted"] = nil }
        XCTAssertTrue(BackupFile.isEncrypted(noFlag))
        XCTAssertEqual(try BackupFile.decode(noFlag, password: "geheim", cipher: TestCipher()), payload)
    }

    func testNotABackupAndNewerVersions() throws {
        let notBackups = ["", "not json", "[]", "42", "{}", #"{"format":"other","version":1,"encrypted":false,"payload":{}}"#,
                          #"{"format":"keibord-backup"}"#, #"{"format":"keibord-backup","version":"one"}"#, #"{"words":{}}"#]
        for text in notBackups {
            assertError(.notAKeibordBackup, try BackupFile.decode(Data(text.utf8), password: nil, cipher: nil))
            XCTAssertFalse(BackupFile.isEncrypted(Data(text.utf8)), text)
        }
        assertError(.notAKeibordBackup, try BackupFile.decode(Data([0xFF, 0xFE, 0x00, 0x01]), password: nil, cipher: nil))

        // A newer version is reported as such, whatever its payload looks like.
        let newer = [#"{"format":"keibord-backup","version":2,"encrypted":false,"payload":{"settings":{}}}"#,
                     #"{"format":"keibord-backup","version":2,"encrypted":false,"payload":"v2 layout","chunks":[1]}"#,
                     #"{"format":"keibord-backup","version":3,"encrypted":true,"kdf":{"name":"argon2id"},"box":"AAAA"}"#]
        for (i, text) in newer.enumerated() {
            assertError(.unsupportedVersion(i == 2 ? 3 : 2), try BackupFile.decode(Data(text.utf8), password: "pw", cipher: TestCipher()))
            assertError(.unsupportedVersion(i == 2 ? 3 : 2), try BackupFile.decode(Data(text.utf8), password: nil, cipher: nil))
            XCTAssertFalse(BackupFile.isEncrypted(Data(text.utf8)), "no password prompt for a file that cannot be read")
        }
        XCTAssertEqual("\(BackupError.unsupportedVersion(2))", "This backup was made by a newer version of Keibord (format 2). Update Keibord to import it.")
        XCTAssertEqual(BackupError.wrongPassword.localizedDescription, "Wrong password.")

        // A Keibord file whose payload is missing or unusable is corrupted, not "not a backup".
        assertCorrupted(try BackupFile.decode(Data(#"{"format":"keibord-backup","version":1,"encrypted":false}"#.utf8), password: nil, cipher: nil))
        assertCorrupted(try BackupFile.decode(Data(#"{"format":"keibord-backup","version":1,"encrypted":false,"payload":[1]}"#.utf8), password: nil, cipher: nil))
        assertCorrupted(try BackupFile.decode(Data(#"{"format":"keibord-backup","version":1,"encrypted":false,"payload":{}}"#.utf8), password: nil, cipher: nil))
    }

    func testOlderAndPartialPayloadsDecodeTolerantly() throws {
        let text = """
        {"format": "keibord-backup", "version": 0, "encrypted": false, "extra": 1,
         "payload": {"createdAt": "gestern", "settings": {"haptics": "ultra", "autocorrect": false},
                     "userModel": {"words": {"Paradeiser": {"count": 3, "lastUsedDay": 1}, "bad": 1}}}}
        """
        let payload = try BackupFile.decode(Data(text.utf8), password: nil, cipher: nil)
        XCTAssertEqual(payload.createdAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(payload.appVersion, "")
        XCTAssertFalse(payload.settings.autocorrect)
        XCTAssertEqual(payload.settings.haptics, KeibordSettings().haptics)
        XCTAssertNil(payload.profile)
        XCTAssertEqual(payload.userModel.words, ["Paradeiser": LearnedWord(count: 3, lastUsedDay: 1)])
    }

    // MARK: Applying an import

    func testApplyReplace() throws {
        let payload = samplePayload()
        var current = (settings: KeibordSettings(), profile: PersonalProfile(shortcuts: [TextShortcut(shortcut: "omw", phrase: "On my way")]), model: UserModel())
        current.model.addWord("Fisolen")
        let (settings, profile, model) = BackupFile.apply(payload, mode: .replace, to: current)
        XCTAssertEqual(settings, payload.settings)
        XCTAssertEqual(profile, payload.profile)
        XCTAssertEqual(model, payload.userModel)
        // A backup exported without personal details keeps the details on this device.
        let (_, kept, _) = BackupFile.apply(samplePayload(profile: false), mode: .replace, to: current)
        XCTAssertEqual(kept, current.profile)
        // The imported model is pruned to the usual limits.
        var huge = samplePayload()
        for i in 0..<30_050 { huge.userModel.words["w\(i)x"] = LearnedWord(count: 1, lastUsedDay: i) }
        XCTAssertEqual(BackupFile.apply(huge, mode: .replace, to: current).2.words.count, 30_000)
    }

    func testApplyMerge() throws {
        let payload = samplePayload()
        var currentProfile = PersonalProfile(shortcuts: [TextShortcut(shortcut: "LG", phrase: "Lg, Senad"),
                                                         TextShortcut(id: payload.profile!.shortcuts[0].id, shortcut: "lgx", phrase: "renamed")])
        currentProfile.info.familyName = "Hamza"
        currentProfile.info.emails = ["Senad@Example.at", "work@example.at"]
        currentProfile.info.city = "Wien"
        var importedProfile = payload.profile!
        importedProfile.info.city = "Prishtina"
        importedProfile.info.postalCode = "10000"
        importedProfile.info.phones = ["+43 664 000000"]
        importedProfile.shortcuts += [TextShortcut(shortcut: "mfg", phrase: "Mit freundlichen Grüßen"),
                                      TextShortcut(shortcut: " MFG ", phrase: "duplicate in the import"),
                                      TextShortcut(id: currentProfile.shortcuts[0].id, shortcut: "gn8", phrase: "Gute Nacht")]
        var imported = payload
        imported.profile = importedProfile

        var currentModel = UserModel()
        currentModel.words["leiwand"] = LearnedWord(count: 1, lastUsedDay: 20_005)
        currentModel.words["oida"] = LearnedWord(count: 9, lastUsedDay: 1)
        currentModel.blocked = ["fuck"]
        let current = (settings: KeibordSettings(), profile: currentProfile, model: currentModel)
        let (settings, profile, model) = BackupFile.apply(imported, mode: .merge, to: current)

        XCTAssertEqual(settings, payload.settings, "imported settings replace the current ones")
        XCTAssertEqual(profile.info.givenName, "Senad", "empty fields are filled")
        XCTAssertEqual(profile.info.familyName, "Hamza")
        XCTAssertEqual(profile.info.emails, ["Senad@Example.at", "work@example.at"], "no case-insensitive duplicates")
        XCTAssertEqual(profile.info.phones, ["+43 664 000000"])
        XCTAssertEqual(profile.info.city, "Wien", "the address on this device is kept as a whole")
        XCTAssertEqual(profile.info.postalCode, "")
        XCTAssertEqual(profile.shortcuts.map(\.shortcut), ["LG", "lgx", "mfg", "gn8"])
        XCTAssertEqual(profile.shortcuts[0].phrase, "Lg, Senad", "this device wins for an existing shortcut")
        XCTAssertEqual(Set(profile.shortcuts.map(\.id)).count, 4, "ids stay unique")

        XCTAssertEqual(model.words["leiwand"], LearnedWord(count: 5, lastUsedDay: 20_005, language: "de-AT"))
        XCTAssertNil(model.words["oida"], "blocked in the backup")
        XCTAssertEqual(model.words["Paradeiser"]?.addedManually, true)
        XCTAssertEqual(model.blocked, ["fuck", "oida"])
        XCTAssertEqual(model.bigrams, payload.userModel.bigrams)

        // Without a profile in the backup the current one stays untouched.
        XCTAssertEqual(BackupFile.apply(samplePayload(profile: false), mode: .merge, to: current).1, currentProfile)
        // Filling an empty profile takes over everything.
        let (_, filled, _) = BackupFile.apply(payload, mode: .merge, to: (KeibordSettings(), PersonalProfile(), UserModel()))
        XCTAssertEqual(filled, payload.profile)
    }

    // MARK: Large models

    func testLargeModelRoundTripAndMergeStayFast() throws {
        var model = UserModel()
        var rng = LexiconTestRandom(seed: 30)
        let letters = Array("abcdefghijklmnopqrstuvwxyzäöüß")
        func randomWord() -> String { String((0..<Int.random(in: 4...12, using: &rng)).map { _ in letters.randomElement(using: &rng)! }) }
        while model.words.count < 30_000 {
            model.words[randomWord()] = LearnedWord(count: Int.random(in: 1...50, using: &rng), lastUsedDay: 20_000 + Int.random(in: 0...400, using: &rng), language: "de-AT")
        }
        let wordList = Array(model.words.keys)
        while model.bigrams.count < 80_000 {
            model.bigrams[UserModel.bigramKey(wordList.randomElement(using: &rng)!, wordList.randomElement(using: &rng)!)] = Int.random(in: 1...9, using: &rng)
        }
        model.blocked = Set(wordList.prefix(500).map { TextUnits.lookupKey($0) })
        let payload = BackupPayload(createdAt: Date(timeIntervalSince1970: 1_760_000_000), appVersion: "1.0.0", settings: KeibordSettings(), profile: nil, userModel: model)

        var start = Date()
        let data = try BackupFile.encode(payload, password: "pw", cipher: TestCipher(), iterations: 1)
        let decoded = try BackupFile.decode(data, password: "pw", cipher: TestCipher())
        let roundTrip = Date().timeIntervalSince(start)
        XCTAssertEqual(decoded, payload)

        start = Date()
        var other = UserModel()
        for word in wordList.suffix(10_000) { other.words[word] = LearnedWord(count: 2, lastUsedDay: 20_500) }
        other.blocked = Set(wordList.suffix(300).map { TextUnits.lookupKey($0) })
        var merged = model.merged(with: other)
        merged.prune()
        let mergeTime = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(merged.words.count, 30_000)
        XCTAssertTrue(merged.words.keys.allSatisfy { !merged.blocked.contains(TextUnits.lookupKey($0)) })

        start = Date()
        let known = merged.knownWords()
        let knownTime = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(known.count, 20_000)
        print("[backup] \(data.count / 1024) KiB, encrypted round trip \(Int(roundTrip * 1000)) ms, merge+prune \(Int(mergeTime * 1000)) ms, knownWords \(Int(knownTime * 1000)) ms")
        // Generous bounds for unoptimised builds; the old merge took seconds with many blocked words.
        XCTAssertLessThan(roundTrip, 15)
        XCTAssertLessThan(mergeTime, 3)
        XCTAssertLessThan(knownTime, 2)
    }
}
