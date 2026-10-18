import Foundation
import Security
import KeibordCore

/// A random 32-byte secret bound to this device, used to encrypt stored cards.
/// Stored in the keychain (shared via the app group) or, if that fails, in the shared directory.
enum DeviceSecret {
    private static let service = "com.keibord.device-secret"
    private static let length = 32

    private static func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "v1",
        ]
        if let group = AppGroup.resolvedIdentifier {
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }

    /// Returns the secret. With `create` (the app, when saving a card) a missing secret is generated;
    /// the keyboard only reads. A secret is never generated while an existing one is merely unreadable
    /// (locked keychain, concurrent creation): a second, different secret would make every saved card
    /// undecryptable.
    static func get(create: Bool) -> Data? {
        let keychain = readKeychain()
        if let data = keychain.data { return data }
        let fileURL = KeibordStore.shared.url(.deviceKey)
        if let data = readFile(fileURL) { return data }
        guard create else { return nil }
        // errSecSuccess here means an item exists but is not a valid secret; errSecInteractionNotAllowed
        // means the keychain is locked right now. Neither is "no secret yet".
        guard keychain.status != errSecSuccess, keychain.status != errSecInteractionNotAllowed else { return nil }

        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)
        var add = baseQuery()
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return secret }
        if addStatus == errSecDuplicateItem {
            // Another process created it in the meantime (or it became readable): use that one.
            return readKeychain().data
        }
        // No usable keychain (e.g. a sideloaded build without the access group): keep the secret in the
        // shared directory, but never replace a file that appeared in the meantime.
        do {
            try secret.write(to: fileURL, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            return secret
        } catch {
            return readFile(fileURL)
        }
    }

    private static func readKeychain() -> (status: OSStatus, data: Data?) {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == length else { return (status, nil) }
        return (status, data)
    }

    private static func readFile(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count == length else { return nil }
        return data
    }
}
