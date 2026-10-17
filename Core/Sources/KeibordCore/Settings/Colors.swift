import Foundation

/// Platform-independent colour (sRGB, components 0…1). Encoded as a "#RRGGBBAA" string.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Accepts "#RGB", "#RRGGBB" or "#RRGGBBAA" (leading "#" optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        red = Double((v >> 24) & 0xFF) / 255
        green = Double((v >> 16) & 0xFF) / 255
        blue = Double((v >> 8) & 0xFF) / 255
        alpha = Double(v & 0xFF) / 255
    }

    public var hexString: String {
        func c(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", c(red), c(green), c(blue), c(alpha))
    }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// Black or white, whichever is more readable on top of this colour.
    public var contrastingLabel: RGBAColor {
        luminance > 0.45 ? .black : .white
    }

    public func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: a) }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        guard let c = RGBAColor(hex: s) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid colour \(s)")
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

/// Key colours for one appearance (light or dark).
public struct KeyColorScheme: Codable, Hashable, Sendable {
    /// Letter / digit / symbol keys.
    public var characterKey: RGBAColor
    /// Shift, backspace, 123, emoji, language, return (when not prominent).
    public var functionKey: RGBAColor
    public var label: RGBAColor
    /// Keyboard background. `nil` = the system keyboard backdrop.
    public var background: RGBAColor?
    /// Prominent return key (go/search/send/done…) and highlights.
    public var accent: RGBAColor
    public var keyShadow: RGBAColor
    /// Pressed-key highlight for function keys.
    public var pressedFunctionKey: RGBAColor

    public init(characterKey: RGBAColor, functionKey: RGBAColor, label: RGBAColor, background: RGBAColor? = nil, accent: RGBAColor, keyShadow: RGBAColor, pressedFunctionKey: RGBAColor) {
        self.characterKey = characterKey
        self.functionKey = functionKey
        self.label = label
        self.background = background
        self.accent = accent
        self.keyShadow = keyShadow
        self.pressedFunctionKey = pressedFunctionKey
    }

    /// iOS-like light keyboard.
    public static let systemLight = KeyColorScheme(
        characterKey: RGBAColor(hex: "#FFFFFF")!,
        functionKey: RGBAColor(hex: "#ABB0BA")!,
        label: RGBAColor(hex: "#000000")!,
        background: nil,
        accent: RGBAColor(hex: "#007AFF")!,
        keyShadow: RGBAColor(hex: "#898A8D")!,
        pressedFunctionKey: RGBAColor(hex: "#FFFFFF")!
    )

    /// iOS-like dark keyboard.
    public static let systemDark = KeyColorScheme(
        characterKey: RGBAColor(hex: "#6B6B6B")!,
        functionKey: RGBAColor(hex: "#464646")!,
        label: RGBAColor(hex: "#FFFFFF")!,
        background: nil,
        accent: RGBAColor(hex: "#0A84FF")!,
        keyShadow: RGBAColor(hex: "#00000059")!,
        pressedFunctionKey: RGBAColor(hex: "#6B6B6B")!
    )
}

/// A key that stays tinted in a chosen colour (by `KeySpec.id`, e.g. "k", "space", "return").
public struct TintedKey: Codable, Hashable, Identifiable, Sendable {
    public var keyID: String
    public var color: RGBAColor
    /// Label colour; `nil` = automatic black/white for contrast.
    public var labelColor: RGBAColor?

    public var id: String { keyID }

    public init(keyID: String, color: RGBAColor, labelColor: RGBAColor? = nil) {
        self.keyID = keyID
        self.color = color
        self.labelColor = labelColor
    }

    public var effectiveLabelColor: RGBAColor { labelColor ?? color.contrastingLabel }

    private enum CodingKeys: String, CodingKey { case keyID, color, labelColor }

    /// `keyID` and `color` are required; an invalid label colour falls back to automatic contrast.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyID = try c.decode(String.self, forKey: .keyID)
        color = try c.decode(RGBAColor.self, forKey: .color)
        labelColor = c.optionalValue(.labelColor, as: RGBAColor.self)
    }
}
