// Stand-ins for the Shared/ files and Foundation APIs that need Apple-only frameworks (CryptoKit, Security,
// NSFileCoordinator, app groups), with the API the keyboard uses. Keep in sync with Shared/CardVault.swift.
import Foundation
import KeibordCore

/// One coordinated access at a time, like a file held by another process. `testWriteHold` keeps each
/// write's claim that long (a process iOS suspended in the middle of a write).
final class NSFileCoordinator {
    static var testWriteHold: TimeInterval = 0
    private static let claim = NSLock()
    init() {}
    struct ReadingOptions: OptionSet { var rawValue: Int }
    func coordinate(readingItemAt url: URL, options: ReadingOptions = [], error: UnsafeMutablePointer<NSError?>?, byAccessor reader: (URL) -> Void) {
        Self.claim.lock()
        defer { Self.claim.unlock() }
        reader(url)
    }
    func coordinate(writingItemAt url: URL, options: WritingOptions = [], error: UnsafeMutablePointer<NSError?>?, byAccessor writer: (URL) -> Void) {
        Self.claim.lock()
        defer { Self.claim.unlock() }
        if Self.testWriteHold > 0 { Thread.sleep(forTimeInterval: Self.testWriteHold) }
        writer(url)
    }
    struct WritingOptions: OptionSet {
        var rawValue: Int
        static let forReplacing = WritingOptions(rawValue: 1)
        static let forMerging = WritingOptions(rawValue: 2)
        static let forDeleting = WritingOptions(rawValue: 4)
    }
}

extension ProcessInfo {
    /// Darwin only: runs the block on a background thread, as iOS does for an extension.
    func performExpiringActivity(withReason reason: String, using block: @escaping (Bool) -> Void) {
        DispatchQueue.global().async { block(false) }
    }
}

extension FileManager {
    /// A working app group (one temporary directory per test run), like a correctly signed install.
    func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        temporaryDirectory.appendingPathComponent("keibord-check-group-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
}

enum CardBrand: String, Codable, CaseIterable {
    case visa, mastercard, amex, maestro, discover, jcb, dinersClub, unionPay, unknown
    var displayName: String { rawValue }
    var cvvLength: Int { self == .amex ? 4 : 3 }
}

struct StoredCard: Codable, Identifiable {
    var id: UUID
    var nickname: String
    var holderName: String
    var last4: String
    var brand: CardBrand
    var expMonth: Int
    var expYear: Int
    var requiresCVV: Bool
    var salt: Data
    var sealedNumber: Data
    var failedAttempts: Int
    var createdAt: Date
    var isLockedOut: Bool { failedAttempts >= 5 }
    var title: String { (nickname.isEmpty ? brand.displayName : nickname) + " •••• " + last4 }
    var expiry: String { String(format: "%02d/%02d", expMonth, expYear % 100) }
}

struct UnlockedCard {
    let card: StoredCard
    let number: String
    let cvv: String?
}

enum CardVaultError: LocalizedError {
    case invalidNumber, wrongCVV, lockedOut, cryptoFailure, notFound
}

final class CardVault {
    static let shared = CardVault()
    /// Test-only: stored cards, their numbers and security codes.
    var testCards: [StoredCard] = []
    var testNumbers: [UUID: String] = [:]
    var testCVVs: [UUID: String] = [:]
    private(set) var testUnlockCount = 0

    func cards() -> [StoredCard] { testCards }

    func unlock(id: UUID, cvv: String?) throws -> UnlockedCard {
        testUnlockCount += 1
        guard let card = testCards.first(where: { $0.id == id }), let number = testNumbers[id] else { throw CardVaultError.notFound }
        if card.requiresCVV, cvv != testCVVs[id] { throw CardVaultError.wrongCVV }
        return UnlockedCard(card: card, number: number, cvv: cvv)
    }
}
