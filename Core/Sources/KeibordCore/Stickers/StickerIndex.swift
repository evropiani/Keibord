import Foundation

/// One saved sticker. Its images are files named after `id` in the shared stickers folder
/// (`StickerStore`): a PNG to paste, a small PNG for the keyboard and, for stickers taken from Apple's
/// keyboard, the original adaptive image glyph.
public struct StickerEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Identifies the image: Apple's content identifier, or a hash of the image. A sticker is kept once.
    public var contentKey: String
    /// Apple's description of the sticker (for VoiceOver); may be empty.
    public var label: String
    /// The original adaptive image glyph is kept: it pastes like Apple's own sticker where an app takes it.
    public var hasGlyph: Bool
    public var added: Date

    public init(id: String = UUID().uuidString, contentKey: String, label: String = "", hasGlyph: Bool = false, added: Date = Date()) {
        self.id = id
        self.contentKey = contentKey
        self.label = label
        self.hasGlyph = hasGlyph
        self.added = added
    }

    private enum CodingKeys: String, CodingKey { case id, contentKey, label, hasGlyph, added }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contentKey = c.value(.contentKey, default: id)
        label = c.value(.label, default: "")
        hasGlyph = c.value(.hasGlyph, default: false)
        added = c.value(.added, default: Date(timeIntervalSince1970: 0))
    }
}

/// The saved stickers in the order they were added (stickers.json). Written by the app, read by the
/// keyboard. Decoding is tolerant: an unreadable entry is skipped, not the whole list.
public struct StickerIndex: Codable, Equatable, Sendable {
    public var stickers: [StickerEntry] = []
    /// Enough for every sticker of a typical collection, small enough for the keyboard's memory and the
    /// shared container.
    public static let maxCount = 500

    public init(stickers: [StickerEntry] = []) {
        self.stickers = stickers
    }

    public enum AddResult: Equatable, Sendable { case added, duplicate, full }

    public func contains(contentKey: String) -> Bool { stickers.contains { $0.contentKey == contentKey } }

    /// Appends `entry` unless the same image is saved already or the list is full.
    public mutating func add(_ entry: StickerEntry) -> AddResult {
        if contains(contentKey: entry.contentKey) { return .duplicate }
        guard stickers.count < Self.maxCount else { return .full }
        stickers.append(entry)
        return .added
    }

    public mutating func remove(ids: Set<String>) {
        stickers.removeAll { ids.contains($0.id) }
    }

    private enum CodingKeys: String, CodingKey { case stickers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var seenIDs = Set<String>(), seenKeys = Set<String>()
        stickers = c.lossyArray(.stickers, default: [StickerEntry]()).filter {
            seenIDs.insert($0.id).inserted && seenKeys.insert($0.contentKey).inserted
        }
    }

    /// A stable hash of image bytes (64-bit FNV-1a, hex) for stickers without Apple's identifier.
    public static func contentHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
