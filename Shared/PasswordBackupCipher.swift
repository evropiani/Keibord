import Foundation
import CryptoKit
import CommonCrypto
import KeibordCore

/// PBKDF2-SHA256 + AES-GCM-256 for password-protected exports.
struct PasswordBackupCipher: BackupCipher {
    /// Iteration counts come from the (untrusted) backup file: refuse values that would crash
    /// (`UInt32` conversion of a negative or huge number) or freeze the app for hours.
    static let maxIterations = 10_000_000

    func deriveKey(password: String, salt: Data, iterations: Int) throws -> Data {
        guard iterations > 0, iterations <= PasswordBackupCipher.maxIterations else {
            throw BackupError.corrupted("Unsupported key derivation parameters")
        }
        // NUL-terminated, so the buffer (and its base address) is never empty, even for "".
        let passwordBytes = password.utf8CString
        let passwordLength = passwordBytes.count - 1
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedLength = derived.count
        let status = passwordBytes.withUnsafeBufferPointer { pw -> Int32 in
            saltBytes.withUnsafeBufferPointer { saltBuffer -> Int32 in
                derived.withUnsafeMutableBufferPointer { out -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress, passwordLength,
                                         saltBuffer.baseAddress, saltBuffer.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         out.baseAddress, derivedLength)
                }
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
