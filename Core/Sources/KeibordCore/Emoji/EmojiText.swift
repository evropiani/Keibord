import Foundation

/// Emoji in plain text (smart punctuation, the app's favourite emoji field).
public enum EmojiText {
    /// An emoji: a character shown as emoji by default, or a text-style one made emoji (VS16, keycap).
    public static func isEmoji(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return scalars.count > 1 && scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 })
    }

    /// Exactly one emoji.
    public static func isEmoji(_ s: String) -> Bool {
        guard s.count == 1, let c = s.first else { return false }
        return isEmoji(c)
    }

    /// The emoji of `text`, in order.
    public static func emoji(in text: String) -> [String] {
        text.filter { isEmoji($0) }.map { String($0) }
    }
}
