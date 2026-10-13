import Foundation

/// A word the user typed that is learned by the keyboard (or added manually in the app).
public struct LearnedWord: Codable, Equatable, Sendable {
    /// How often the word was committed.
    public var count: Int
    /// Last use, in whole days since 1970-01-01 (UTC).
    public var lastUsedDay: Int
    /// Most likely language (`KeyboardLanguage.rawValue`), if known.
    public var language: String?
    /// Added in the app's dictionary editor (always treated as known).
    public var addedManually: Bool

    public init(count: Int, lastUsedDay: Int, language: String? = nil, addedManually: Bool = false) {
        self.count = count
        self.lastUsedDay = lastUsedDay
        self.language = language
        self.addedManually = addedManually
    }
}

/// Accumulated touch offsets for one key in one layout geometry (normalised by key size).
public struct TouchStat: Codable, Equatable, Sendable {
    public var sumDX: Double
    public var sumDY: Double
    public var count: Int

    public init(sumDX: Double = 0, sumDY: Double = 0, count: Int = 0) {
        self.sumDX = sumDX
        self.sumDY = sumDY
        self.count = count
    }

    public var meanDX: Double { count > 0 ? sumDX / Double(count) : 0 }
    public var meanDY: Double { count > 0 ? sumDY / Double(count) : 0 }
}

public struct EmojiStat: Codable, Equatable, Sendable {
    public var count: Int
    /// Seconds since 1970.
    public var lastUsed: Double

    public init(count: Int, lastUsed: Double) {
        self.count = count
        self.lastUsed = lastUsed
    }
}

/// Everything Keibord learns from typing (user-model.json). This is the "typing data" that is
/// exported/imported to move between devices.
///
/// Keys:
/// * `words`: exact word form as typed/committed ("Paradeiser", "leiwand") → stats
/// * `bigrams`: "<prev>\u{1F}<next>" with both parts as lookup keys (`TextUnits.lookupKey`) → count
/// * `blocked`: lookup keys that must never be suggested or learned
/// * `touch`: "<touchModelKey>|<keyID>" → offsets
/// * `emoji`: emoji → usage
/// * `languageUsage`: `KeyboardLanguage.rawValue` → number of committed words
public struct UserModel: Codable, Equatable, Sendable {
    public static let bigramSeparator: Character = "\u{1F}"

    public var version: Int = 1
    public var words: [String: LearnedWord] = [:]
    public var bigrams: [String: Int] = [:]
    public var blocked: Set<String> = []
    public var touch: [String: TouchStat] = [:]
    public var emoji: [String: EmojiStat] = [:]
    public var languageUsage: [String: Int] = [:]

    public init() {}

    public static func bigramKey(_ previous: String, _ next: String) -> String {
        TextUnits.lookupKey(previous) + String(bigramSeparator) + TextUnits.lookupKey(next)
    }

    public static func touchKey(layout: String, keyID: String) -> String {
        layout + "|" + keyID
    }

    private enum CodingKeys: String, CodingKey { case version, words, bigrams, blocked, touch, emoji, languageUsage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: 1)
        words = c.value(.words, default: [:])
        bigrams = c.value(.bigrams, default: [:])
        blocked = c.value(.blocked, default: [])
        touch = c.value(.touch, default: [:])
        emoji = c.value(.emoji, default: [:])
        languageUsage = c.value(.languageUsage, default: [:])
    }
}
