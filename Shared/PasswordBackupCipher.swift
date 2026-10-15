import Foundation
import CryptoKit
import CommonCrypto
import KeibordCore

/// PBKDF2-SHA256 + AES-GCM-256 for password-protected exports.
struct PasswordBackupCipher: BackupCipher {
    func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { pw -> Int32 in
            pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(pw.count, 1)) { pwChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwChars, passwordBytes.count,
                                     saltBytes, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &derived, derived.count)
            }
        }
        guard status == Int32(kCCSuccess) else { throw BackupError.corrupted("Key derivation failed") }
        return Data(derived)
    }

    func seal(_ plaintext: Data, key: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined else {
            throw BackupError.corrupted("Encryption failed")
        }
        return combined
    }

    func open(_ combined: Data, key: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
    }

    func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
