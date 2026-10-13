import Foundation

/// Small status file written by the keyboard extension (state.json) so the app can show diagnostics
/// and remember the last used language.
public struct KeyboardRuntimeState: Codable, Equatable, Sendable {
    public var currentLanguage: KeyboardLanguage?
    public var lastActive: Date?
    public var hasFullAccess: Bool = false
    public var keyboardVersion: String?
    /// The app-group identifier the keyboard resolved (for diagnostics).
    public var appGroupIdentifier: String?

    public init(currentLanguage: KeyboardLanguage? = nil, lastActive: Date? = nil, hasFullAccess: Bool = false, keyboardVersion: String? = nil, appGroupIdentifier: String? = nil) {
        self.currentLanguage = currentLanguage
        self.lastActive = lastActive
        self.hasFullAccess = hasFullAccess
        self.keyboardVersion = keyboardVersion
        self.appGroupIdentifier = appGroupIdentifier
    }

    private enum CodingKeys: String, CodingKey { case currentLanguage, lastActive, hasFullAccess, keyboardVersion, appGroupIdentifier }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentLanguage = c.optionalValue(.currentLanguage, as: KeyboardLanguage.self)
        lastActive = c.optionalValue(.lastActive, as: Date.self)
        hasFullAccess = c.value(.hasFullAccess, default: false)
        keyboardVersion = c.optionalValue(.keyboardVersion, as: String.self)
        appGroupIdentifier = c.optionalValue(.appGroupIdentifier, as: String.self)
    }
}

/// File names inside the shared `Keibord/` directory of the app-group container.
public enum KeibordFile: String, CaseIterable, Sendable {
    case settings = "settings.json"
    case profile = "profile.json"
    case userModel = "user-model.json"
    case state = "state.json"
    case cards = "cards.json"
    case deviceKey = "device.key"
}

/// Shared JSON encoder/decoder configuration so every process writes identical files.
public enum KeibordJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
