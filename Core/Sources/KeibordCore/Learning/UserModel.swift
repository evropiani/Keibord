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

    private enum CodingKeys: String, CodingKey { case count, lastUsedDay, language, addedManually }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = UserModel.clampedCount(c.value(.count, default: 1))
        lastUsedDay = c.value(.lastUsedDay, default: 0)
        language = c.optionalValue(.language, as: String.self)
        addedManually = c.value(.addedManually, default: false)
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

    private enum CodingKeys: String, CodingKey { case sumDX, sumDY, count }

    /// Every recorded offset lies within ±1 key size, so the sums are clamped to ±count: a damaged or
    /// hand-made file can neither distort the mean beyond that nor make later sums overflow to
    /// infinity (which JSON cannot encode, so the model could never be saved again).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = UserModel.clampedCount(c.value(.count, default: 0))
        let limit = Double(count)
        sumDX = AppearanceSettings.clamp(c.value(.sumDX, default: 0), -limit...limit, default: 0)
        sumDY = AppearanceSettings.clamp(c.value(.sumDY, default: 0), -limit...limit, default: 0)
    }
}

public struct EmojiStat: Codable, Equatable, Sendable {
    public var count: Int
    /// Seconds since 1970.
    public var lastUsed: Double

    public init(count: Int, lastUsed: Double) {
        self.count = count
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey { case count, lastUsed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = UserModel.clampedCount(c.value(.count, default: 1))
        lastUsed = c.value(.lastUsed, default: 0)
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
        LexiconKey.string(previous) + String(bigramSeparator) + LexiconKey.string(next)
    }

    public static func touchKey(layout: String, keyID: String) -> String {
        layout + "|" + keyID
    }

    private enum CodingKeys: String, CodingKey { case version, words, bigrams, blocked, touch, emoji, languageUsage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.value(.version, default: 1)
        // Entry by entry: one damaged entry must not wipe everything learned (the next save would
        // make the loss permanent).
        // Counts are clamped (see `maxCount`); word pairs that were never seen are dropped.
        words = c.lossyDictionary(.words, default: [:])
        bigrams = c.lossyDictionary(.bigrams, default: [:])
        if bigrams.values.contains(where: { $0 <= 0 || $0 > UserModel.maxCount }) {
            bigrams = bigrams.filter { $0.value > 0 }.mapValues(UserModel.clampedCount)
        }
        blocked = Set(c.lossyArray(.blocked, default: [String]()))
        touch = c.lossyDictionary(.touch, default: [:])
        emoji = c.lossyDictionary(.emoji, default: [:])
        languageUsage = c.lossyDictionary(.languageUsage, default: [String: Int]()).mapValues(UserModel.clampedCount)
    }

    /// Upper bound for every stored count: far beyond real use, and small enough that adding counts
    /// (applying deltas, merging imports, summing casings) can never overflow, which would crash.
    static let maxCount = 1_000_000_000

    static func clampedCount(_ value: Int) -> Int {
        min(max(0, value), maxCount)
    }
}
