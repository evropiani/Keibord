import XCTest
@testable import KeibordCore

private struct FakeCipher: BackupCipher {
    func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        Data((Array(password.utf8) + Array(salt)).prefix(32))
    }
    func seal(_ plaintext: Data, key: Data) throws -> Data {
        let k = Array(key)
        let body = plaintext.enumerated().map { $0.element ^ k[$0.offset % k.count] }
        let tag = UInt8(truncatingIfNeeded: k.reduce(0) { $0 &+ Int($1) })
        return Data([tag] + body)
    }
    func open(_ combined: Data, key: Data) throws -> Data {
        let k = Array(key)
        guard combined.first == UInt8(truncatingIfNeeded: k.reduce(0) { $0 &+ Int($1) }) else { throw BackupError.wrongPassword }
        return Data(combined.dropFirst().enumerated().map { $0.element ^ k[$0.offset % k.count] })
    }
    func randomBytes(_ count: Int) -> Data { Data(repeating: 7, count: count) }
}

final class LearningBackupEmojiTests: XCTestCase {
    func testDeltaAndKnownWords() {
        var delta = UserModelDelta()
        let tap = TapInput(candidates: [TapCandidate(character: "l", cost: 0, dx: 0.1, dy: 0.2)], touchModelKey: "qwertz11.letters.standard")
        delta.record(.committedWord(final: "leiwand", typed: "leiwand", previous: "voll", language: .deAT, taps: nil, wasAutocorrected: false), day: 1)
        delta.record(.committedWord(final: "leiwand", typed: "leiwand", previous: nil, language: .deAT, taps: nil, wasAutocorrected: false), day: 2)
        delta.record(.committedWord(final: "la", typed: "la", previous: nil, language: .deAT, taps: [tap, .exact("a")], wasAutocorrected: false), day: 2)
        var model = UserModel()
        model.apply(delta)
        XCTAssertEqual(model.words["leiwand"]?.count, 2)
        XCTAssertEqual(model.bigrams[UserModel.bigramKey("voll", "leiwand")], 1)
        XCTAssertTrue(model.knownWords().contains { $0.word == "leiwand" })
        XCTAssertEqual(model.touch["qwertz11.letters.standard|l"]?.count, 1)
        model.block("leiwand")
        XCTAssertNil(model.words["leiwand"])
        model.apply(delta)
        XCTAssertNil(model.words["leiwand"])
    }

    func testBackupRoundTrip() throws {
        var model = UserModel()
        model.addWord("Paradeiser")
        let payload = BackupPayload(createdAt: Date(timeIntervalSince1970: 0), appVersion: "1.0.0", settings: KeibordSettings(), profile: nil, userModel: model)
        let plain = try BackupFile.encode(payload, password: nil, cipher: nil)
        XCTAssertEqual(try BackupFile.decode(plain, password: nil, cipher: nil), payload)
        let enc = try BackupFile.encode(payload, password: "geheim", cipher: FakeCipher(), iterations: 1)
        XCTAssertTrue(BackupFile.isEncrypted(enc))
        XCTAssertThrowsError(try BackupFile.decode(enc, password: nil, cipher: FakeCipher())) { XCTAssertEqual($0 as? BackupError, .passwordRequired) }
        XCTAssertThrowsError(try BackupFile.decode(enc, password: "falsch", cipher: FakeCipher())) { XCTAssertEqual($0 as? BackupError, .wrongPassword) }
        XCTAssertEqual(try BackupFile.decode(enc, password: "geheim", cipher: FakeCipher()), payload)
        XCTAssertThrowsError(try BackupFile.decode(Data("{}".utf8), password: nil, cipher: nil))
    }

    func testEmojiCatalog() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Emoji")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("emoji.json").path) else { throw XCTSkip("no emoji data") }
        let catalog = try EmojiCatalog(baseURL: dir)
        XCTAssertEqual(catalog.categories.count, 8)
        XCTAssertEqual(catalog.variants(of: "👍").count, 5)
        XCTAssertTrue(catalog.search("herz", languageCodes: ["de"]).contains("❤️"))
        XCTAssertTrue(catalog.search("grun", languageCodes: ["de"]).contains("💚"))
        XCTAssertFalse(catalog.search("zemer", languageCodes: ["sq"]).isEmpty)
    }
}
