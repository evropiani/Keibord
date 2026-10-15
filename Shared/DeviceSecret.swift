import Foundation
import Security
import KeibordCore

/// A random 32-byte secret bound to this device, used to encrypt stored cards.
/// Stored in the keychain (shared via the app group) or, if that fails, in the shared directory.
enum DeviceSecret {
    private static let service = "com.keibord.device-secret"

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

    static func get(create: Bool) -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data
        }
        let fileURL = KeibordStore.shared.url(.deviceKey)
        if let data = try? Data(contentsOf: fileURL), data.count == 32 { return data }
        guard create else { return nil }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = Data(bytes)
        var add = baseQuery()
        add[kSecValueData as String] = secret
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return secret }
        do {
            try secret.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return secret
        } catch {
            return nil
        }
    }
}
