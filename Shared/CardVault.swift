import Foundation
import CryptoKit
import KeibordCore

enum CardBrand: String, Codable, CaseIterable {
    case visa, mastercard, amex, maestro, discover, jcb, dinersClub, unionPay, unknown

    var displayName: String {
        switch self {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .amex: return "American Express"
        case .maestro: return "Maestro"
        case .discover: return "Discover"
        case .jcb: return "JCB"
        case .dinersClub: return "Diners Club"
        case .unionPay: return "UnionPay"
        case .unknown: return "Card"
        }
    }

    /// Digits of the security code; the keyboard's unlock pad takes exactly this many.
    var cvvLength: Int { self == .amex ? 4 : 3 }

    /// The ASCII digits of `text` (spaces, dashes and any other characters dropped).
    static func digits(in text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars where scalar.value >= 48 && scalar.value <= 57 {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    static func detect(_ number: String) -> CardBrand {
        let d = digits(in: number)
        func prefix(_ n: Int) -> Int { d.count >= n ? Int(d.prefix(n)) ?? -1 : -1 }
        if d.hasPrefix("4") { return .visa }
        if (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)) { return .mastercard }
        if d.hasPrefix("34") || d.hasPrefix("37") { return .amex }
        if d.hasPrefix("62") { return .unionPay }
        if d.hasPrefix("6011") || d.hasPrefix("65") || (644...649).contains(prefix(3)) { return .discover }
        if (3528...3589).contains(prefix(4)) { return .jcb }
        if d.hasPrefix("36") || d.hasPrefix("38") || d.hasPrefix("39") || d.hasPrefix("3095") || (300...305).contains(prefix(3)) { return .dinersClub }
        if ["50", "56", "57", "58", "63", "67"].contains(String(d.prefix(2))) { return .maestro }
        return .unknown
    }

    static func luhnValid(_ number: String) -> Bool {
        let values = CardBrand.digits(in: number).compactMap { $0.wholeNumberValue }
        guard values.count >= 12, values.count <= 19 else { return false }
        var sum = 0
        for (i, digit) in values.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// A saved payment card. The number is encrypted; the CVV is never stored.
struct StoredCard: Codable, Identifiable, Equatable {
    var id: UUID
    var nickname: String
    var holderName: String
    var last4: String
    var brand: CardBrand
    var expMonth: Int
    var expYear: Int
    /// The number can only be decrypted with the CVV typed by the user.
    var requiresCVV: Bool
    var salt: Data
    var sealedNumber: Data
    var failedAttempts: Int
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, nickname, holderName, last4, brand, expMonth, expYear, requiresCVV, salt, sealedNumber, failedAttempts, createdAt
    }

    var title: String {
        let name = nickname.isEmpty ? brand.displayName : nickname
        return "\(name) •••• \(last4)"
    }

    var expiry: String { String(format: "%02d/%02d", expMonth, expYear % 100) }
    var isLockedOut: Bool { failedAttempts >= CardVault.maxAttempts }

    /// True once the expiry month is over.
    func isExpired(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let now = calendar.dateComponents([.year, .month], from: date)
        guard let year = now.year, let month = now.month else { return false }
        return expYear < year || (expYear == year && expMonth < month)
    }
}

extension StoredCard {
    /// Tolerant decoding (in an extension to keep the memberwise initializer): only the fields needed to
    /// decrypt are required, everything else falls back to a default, an unknown brand becomes `.unknown`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        salt = try c.decode(Data.self, forKey: .salt)
        sealedNumber = try c.decode(Data.self, forKey: .sealedNumber)
        nickname = c.value(.nickname, default: "")
        holderName = c.value(.holderName, default: "")
        last4 = c.value(.last4, default: "")
        brand = c.value(.brand, default: CardBrand.unknown)
        expMonth = c.value(.expMonth, default: 1)
        expYear = c.value(.expYear, default: 2000)
        requiresCVV = c.value(.requiresCVV, default: false)
        failedAttempts = c.value(.failedAttempts, default: 0)
        createdAt = c.value(.createdAt, default: Date(timeIntervalSince1970: 0))
    }
}

/// The contents of cards.json (a JSON array of cards). Decoding skips cards that cannot be read instead
/// of failing as a whole, so one damaged entry never hides (or, on the next save, deletes) the others.
struct StoredCardList: Codable {
    var cards: [StoredCard]

    init(cards: [StoredCard]) { self.cards = cards }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [StoredCard] = []
        while !container.isAtEnd {
            if let card = try? container.decode(StoredCard.self) {
                result.append(card)
            } else if (try? container.decode(Skipped.self)) == nil {
                break
            }
        }
        cards = result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cards)
    }
}

struct UnlockedCard {
    let card: StoredCard
    let number: String
    let cvv: String?
}

enum CardVaultError: LocalizedError {
    case invalidNumber, wrongCVV, lockedOut, cryptoFailure, notFound, invalidCVV, invalidExpiry, storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidNumber: return "This card number is not valid."
        case .wrongCVV: return "Wrong security code."
        case .lockedOut: return "Too many wrong attempts. Reset the card in the Keibord app."
        case .cryptoFailure: return "The card could not be decrypted on this device (Full Access needed?)."
        case .notFound: return "Card not found."
        case .invalidCVV: return "The security code must have 3 digits (4 for American Express)."
        case .invalidExpiry: return "The expiry date is not valid."
        case .storageUnavailable: return "The card storage could not be updated (Full Access needed?)."
        }
    }
}

/// Encrypted card storage (cards.json). Key = HKDF(device secret, card salt, CVV).
final class CardVault {
    static let shared = CardVault()
    static let maxAttempts = 5
    private let store = KeibordStore.shared

    func cards() -> [StoredCard] { store.read(StoredCardList.self, .cards)?.cards ?? [] }

    /// Coordinated read-modify-write of cards.json, so the app and the keyboard never overwrite each
    /// other's changes. Returns the saved list, or nil when nothing could be written.
    @discardableResult
    private func modify(_ transform: (inout [StoredCard]) -> Void) -> [StoredCard]? {
        store.update(StoredCardList.self, .cards, default: StoredCardList(cards: [])) { transform(&$0.cards) }?.cards
    }

    private func key(salt: Data, cvv: String?, create: Bool) throws -> SymmetricKey {
        guard let secret = DeviceSecret.get(create: create) else { throw CardVaultError.cryptoFailure }
        let info = Data(("keibord.card.v1|" + (cvv ?? "")).utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: info, outputByteCount: 32)
    }

    private func decryptNumber(_ card: StoredCard, using key: SymmetricKey) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: card.sealedNumber),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    @discardableResult
    func add(nickname: String, holderName: String, number: String, expMonth: Int, expYear: Int, requiresCVV: Bool, cvv: String?) throws -> StoredCard {
        let digits = CardBrand.digits(in: number)
        guard CardBrand.luhnValid(digits) else { throw CardVaultError.invalidNumber }
        guard (1...12).contains(expMonth), expYear >= 0 else { throw CardVaultError.invalidExpiry }
        let brand = CardBrand.detect(digits)
        var usedCVV: String?
        if requiresCVV {
            // The keyboard's unlock pad accepts exactly `cvvLength` digits: a code of any other length
            // could never be typed there and the card would only collect failed attempts.
            let code = CardBrand.digits(in: cvv ?? "")
            guard code.count == brand.cvvLength else { throw CardVaultError.invalidCVV }
            usedCVV = code
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let symmetric = try key(salt: salt, cvv: usedCVV, create: true)
        guard let sealed = try? AES.GCM.seal(Data(digits.utf8), using: symmetric).combined else { throw CardVaultError.cryptoFailure }
        let card = StoredCard(id: UUID(), nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                              holderName: holderName.trimmingCharacters(in: .whitespacesAndNewlines),
                              last4: String(digits.suffix(4)), brand: brand,
                              expMonth: expMonth, expYear: expYear < 100 ? 2000 + expYear : expYear, requiresCVV: requiresCVV,
                              salt: salt, sealedNumber: sealed, failedAttempts: 0, createdAt: Date())
        guard let saved = modify({ $0.append(card) }), saved.contains(where: { $0.id == card.id }) else {
            throw CardVaultError.storageUnavailable
        }
        return card
    }

    /// Replaces the stored card with the same id (a deleted card is not brought back).
    func update(_ card: StoredCard) {
        modify { cards in
            if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i] = card }
        }
    }

    func delete(id: UUID) {
        modify { cards in cards.removeAll { $0.id == id } }
    }

    func resetAttempts(id: UUID) {
        modify { cards in
            if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].failedAttempts = 0 }
        }
    }

    func unlock(id: UUID, cvv: String?) throws -> UnlockedCard {
        guard let card = cards().first(where: { $0.id == id }) else { throw CardVaultError.notFound }
        if card.isLockedOut { throw CardVaultError.lockedOut }
        guard card.requiresCVV else {
            let symmetric = try key(salt: card.salt, cvv: nil, create: false)
            guard let number = decryptNumber(card, using: symmetric) else { throw CardVaultError.cryptoFailure }
            return UnlockedCard(card: card, number: number, cvv: nil)
        }
        let symmetric = try key(salt: card.salt, cvv: cvv?.filter({ $0.isNumber }) ?? "", create: false)
        // Count the attempt before trying it: the keyboard process can be killed at any moment, and a guess
        // that was never counted would make the lockout useless. If the counter cannot be stored, do not try.
        var counted: StoredCard?
        let saved = modify { cards in
            guard let i = cards.firstIndex(where: { $0.id == id }), !cards[i].isLockedOut else { return }
            cards[i].failedAttempts += 1
            counted = cards[i]
        }
        guard saved != nil else { throw CardVaultError.storageUnavailable }
        guard var attempt = counted else {
            throw saved?.contains(where: { $0.id == id }) == true ? CardVaultError.lockedOut : CardVaultError.notFound
        }
        guard let number = decryptNumber(attempt, using: symmetric) else {
            throw attempt.isLockedOut ? CardVaultError.lockedOut : CardVaultError.wrongCVV
        }
        modify { cards in
            if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].failedAttempts = 0 }
        }
        attempt.failedAttempts = 0
        return UnlockedCard(card: attempt, number: number, cvv: cvv)
    }
}
