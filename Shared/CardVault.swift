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

    var cvvLength: Int { self == .amex ? 4 : 3 }

    static func detect(_ number: String) -> CardBrand {
        let d = number.filter { $0.isNumber }
        func prefix(_ n: Int) -> Int { Int(d.prefix(n)) ?? -1 }
        if d.hasPrefix("4") { return .visa }
        if (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)) { return .mastercard }
        if d.hasPrefix("34") || d.hasPrefix("37") { return .amex }
        if d.hasPrefix("62") { return .unionPay }
        if d.hasPrefix("6011") || d.hasPrefix("65") || (644...649).contains(prefix(3)) { return .discover }
        if (3528...3589).contains(prefix(4)) { return .jcb }
        if d.hasPrefix("36") || d.hasPrefix("38") || (300...305).contains(prefix(3)) { return .dinersClub }
        if ["50", "56", "57", "58", "63", "67"].contains(String(d.prefix(2))) { return .maestro }
        return .unknown
    }

    static func luhnValid(_ number: String) -> Bool {
        let digits = number.compactMap { $0.wholeNumberValue }
        guard digits.count >= 12, digits.count <= 19 else { return false }
        var sum = 0
        for (i, digit) in digits.reversed().enumerated() {
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

    var title: String {
        let name = nickname.isEmpty ? brand.displayName : nickname
        return "\(name) •••• \(last4)"
    }

    var expiry: String { String(format: "%02d/%02d", expMonth, expYear % 100) }
    var isLockedOut: Bool { failedAttempts >= CardVault.maxAttempts }
}

struct UnlockedCard {
    let card: StoredCard
    let number: String
    let cvv: String?
}

enum CardVaultError: LocalizedError {
    case invalidNumber, wrongCVV, lockedOut, cryptoFailure, notFound

    var errorDescription: String? {
        switch self {
        case .invalidNumber: return "This card number is not valid."
        case .wrongCVV: return "Wrong security code."
        case .lockedOut: return "Too many wrong attempts. Reset the card in the Keibord app."
        case .cryptoFailure: return "The card could not be decrypted on this device (Full Access needed?)."
        case .notFound: return "Card not found."
        }
    }
}

/// Encrypted card storage (cards.json). Key = HKDF(device secret, card salt, CVV).
final class CardVault {
    static let shared = CardVault()
    static let maxAttempts = 5
    private let store = KeibordStore.shared

    func cards() -> [StoredCard] { store.read([StoredCard].self, .cards) ?? [] }

    private func save(_ cards: [StoredCard]) { store.write(cards, .cards) }

    private func key(salt: Data, cvv: String?, create: Bool) throws -> SymmetricKey {
        guard let secret = DeviceSecret.get(create: create) else { throw CardVaultError.cryptoFailure }
        let info = Data(("keibord.card.v1|" + (cvv ?? "")).utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt, info: info, outputByteCount: 32)
    }

    @discardableResult
    func add(nickname: String, holderName: String, number: String, expMonth: Int, expYear: Int, requiresCVV: Bool, cvv: String?) throws -> StoredCard {
        let digits = number.filter { $0.isNumber }
        guard CardBrand.luhnValid(digits) else { throw CardVaultError.invalidNumber }
        let brand = CardBrand.detect(digits)
        var saltBytes = [UInt8](repeating: 0, count: 16)
        for i in saltBytes.indices { saltBytes[i] = UInt8.random(in: 0...255) }
        let salt = Data(saltBytes)
        let usedCVV = requiresCVV ? cvv?.filter({ $0.isNumber }) : nil
        if requiresCVV, (usedCVV ?? "").count < 3 { throw CardVaultError.wrongCVV }
        let symmetric = try key(salt: salt, cvv: usedCVV, create: true)
        guard let sealed = try? AES.GCM.seal(Data(digits.utf8), using: symmetric).combined else { throw CardVaultError.cryptoFailure }
        let card = StoredCard(id: UUID(), nickname: nickname, holderName: holderName, last4: String(digits.suffix(4)), brand: brand,
                              expMonth: expMonth, expYear: expYear < 100 ? 2000 + expYear : expYear, requiresCVV: requiresCVV,
                              salt: salt, sealedNumber: sealed, failedAttempts: 0, createdAt: Date())
        save(cards() + [card])
        return card
    }

    func update(_ card: StoredCard) {
        var all = cards()
        if let i = all.firstIndex(where: { $0.id == card.id }) { all[i] = card }
        save(all)
    }

    func delete(id: UUID) { save(cards().filter { $0.id != id }) }

    func resetAttempts(id: UUID) {
        guard var card = cards().first(where: { $0.id == id }) else { return }
        card.failedAttempts = 0
        update(card)
    }

    func unlock(id: UUID, cvv: String?) throws -> UnlockedCard {
        guard var card = cards().first(where: { $0.id == id }) else { throw CardVaultError.notFound }
        if card.isLockedOut { throw CardVaultError.lockedOut }
        let usedCVV = card.requiresCVV ? cvv?.filter({ $0.isNumber }) : nil
        let symmetric = try key(salt: card.salt, cvv: usedCVV, create: false)
        do {
            let box = try AES.GCM.SealedBox(combined: card.sealedNumber)
            let plain = try AES.GCM.open(box, using: symmetric)
            if card.failedAttempts != 0 {
                card.failedAttempts = 0
                update(card)
            }
            return UnlockedCard(card: card, number: String(decoding: plain, as: UTF8.self), cvv: cvv)
        } catch {
            if card.requiresCVV {
                card.failedAttempts += 1
                update(card)
                throw card.isLockedOut ? CardVaultError.lockedOut : CardVaultError.wrongCVV
            }
            throw CardVaultError.cryptoFailure
        }
    }
}
