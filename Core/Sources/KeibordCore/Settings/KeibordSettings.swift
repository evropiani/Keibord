import Foundation

public enum ThemeMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Follow the text field's keyboard appearance / system dark mode.
    case system, light, dark
}

public enum HapticStrength: String, Codable, CaseIterable, Hashable, Sendable {
    case off, light, medium, strong
}

public enum KeyHeightOption: String, Codable, CaseIterable, Hashable, Sendable {
    case compact, standard, tall
}

/// Visual customisation of the keyboard.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var themeMode: ThemeMode = .system
    /// Corner radius of keys in points.
    public var keyCornerRadius: Double = 8.5
    /// iOS 26 keys have no shadow (settings saved before version 2 had them on by default: turned off).
    public var keyShadows: Bool = false
    public var keyHeight: KeyHeightOption = .standard
    /// Multiplier for key label font sizes (0.8…1.3).
    public var labelScale: Double = 1.0
    /// Always show upper-case letters on keys (iOS shows lower-case unless shifted).
    public var uppercaseLabels: Bool = false
    public var showNumberRow: Bool = false
    /// Show the language name on the space bar.
    public var showSpaceLanguageLabel: Bool = true
    /// Custom colours; `nil` = iOS default.
    public var lightColors: KeyColorScheme? = nil
    public var darkColors: KeyColorScheme? = nil
    /// Keys that are always tinted.
    public var tintedKeys: [TintedKey] = []

    public init() {}

    public func colors(dark: Bool) -> KeyColorScheme {
        dark ? (darkColors ?? .systemDark) : (lightColors ?? .systemLight)
    }

    public func tint(for keyID: String) -> TintedKey? {
        tintedKeys.first { $0.keyID == keyID }
    }

    private enum CodingKeys: String, CodingKey {
        case themeMode, keyCornerRadius, keyShadows, keyHeight, labelScale, uppercaseLabels, showNumberRow
        case showSpaceLanguageLabel, lightColors, darkColors, tintedKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        themeMode = c.value(.themeMode, default: d.themeMode)
        // Out-of-range numbers (hand-edited files, other versions) are clamped to what the app offers.
        keyCornerRadius = AppearanceSettings.clamp(c.value(.keyCornerRadius, default: d.keyCornerRadius), AppearanceSettings.cornerRadiusRange, default: d.keyCornerRadius)
        keyShadows = c.value(.keyShadows, default: d.keyShadows)
        keyHeight = c.value(.keyHeight, default: d.keyHeight)
        labelScale = AppearanceSettings.clamp(c.value(.labelScale, default: d.labelScale), AppearanceSettings.labelScaleRange, default: d.labelScale)
        uppercaseLabels = c.value(.uppercaseLabels, default: d.uppercaseLabels)
        showNumberRow = c.value(.showNumberRow, default: d.showNumberRow)
        showSpaceLanguageLabel = c.value(.showSpaceLanguageLabel, default: d.showSpaceLanguageLabel)
        lightColors = c.optionalValue(.lightColors, as: KeyColorScheme.self)
        darkColors = c.optionalValue(.darkColors, as: KeyColorScheme.self)
        tintedKeys = c.lossyArray(.tintedKeys, default: d.tintedKeys)
    }

    /// Range of `keyCornerRadius` offered by the app.
    public static let cornerRadiusRange: ClosedRange<Double> = 0...16
    /// Range of `labelScale` offered by the app.
    public static let labelScaleRange: ClosedRange<Double> = 0.8...1.3

    static func clamp(_ value: Double, _ range: ClosedRange<Double>, default defaultValue: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// All user preferences. Written by the app, read by the keyboard (settings.json).
/// Decoding is tolerant: unknown keys are ignored and missing keys fall back to defaults.
public struct KeibordSettings: Codable, Equatable, Sendable {
    /// 2 (1.0.22): key shadows off, as on iOS 26 (they were on by default before).
    public var version: Int = KeibordSettings.currentVersion
    public static let currentVersion = 2

    // MARK: Languages
    /// Languages of multilingual typing, in order; each picks the variant of its language keyboard
    /// (`KeyboardLanguageFamily`). Never empty.
    public var enabledLanguages: [KeyboardLanguage] = [.deAT, .enGB]
    /// Per-language base layout override (key: `KeyboardLanguage.rawValue`).
    public var layoutOverrides: [String: BaseLayout] = [:]
    /// Suggest and autocorrect across all enabled languages at once.
    public var multilingualTyping: Bool = true
    /// Per-language quote style override (key: `KeyboardLanguage.rawValue`).
    public var quoteStyleOverrides: [String: QuoteStyle] = [:]

    // MARK: Typing
    public var autocorrect: Bool = true
    public var autoCapitalization: Bool = true
    public var predictiveText: Bool = true
    public var doubleSpacePeriod: Bool = true
    public var smartQuotes: Bool = true
    /// Move the auto-inserted space after punctuation ("word ." → "word. ").
    public var smartPunctuationSpacing: Bool = true
    /// Restore missing accents/diacritics ("eshte" → "është", "perche" → "perché").
    public var accentRestoration: Bool = true
    public var capsLock: Bool = true
    /// Long-press the space bar to move the cursor.
    public var spacebarCursor: Bool = true
    /// Learn new words, word pairs and the personal touch model.
    public var learnWords: Bool = true
    /// Temporarily stop learning anything.
    public var incognito: Bool = false
    /// Learn where you tap each key and adapt the hit areas.
    public var adaptiveTouch: Bool = true
    /// Invisible hit zones that grow for the letters likely to come next (like the iPhone keyboard).
    public var predictiveTouch: Bool = true

    // MARK: AutoFill
    public var autofillSuggestions: Bool = true
    public var cardSuggestions: Bool = true
    /// Show "use iOS keyboard" hint in one-time-code fields.
    public var oneTimeCodeHint: Bool = true

    // MARK: Feedback
    public var haptics: HapticStrength = .light
    public var keySound: Bool = false
    public var keyPopups: Bool = true

    // MARK: Appearance
    public var appearance: AppearanceSettings = AppearanceSettings()

    // MARK: Emoji
    /// Favourite emoji, pinned first on the emoji panel's recents page in this order (at most
    /// `maxFavoriteEmoji`: two columns of the four-row grid).
    public var favoriteEmoji: [String] = [] {
        didSet { favoriteEmoji = Self.cleanedFavorites(favoriteEmoji) }
    }
    public static let maxFavoriteEmoji = 8

    /// Emoji only, each once, at most `maxFavoriteEmoji`.
    public static func cleanedFavorites(_ list: [String]) -> [String] {
        var result: [String] = []
        for e in list where !result.contains(e) && EmojiText.isEmoji(e) && result.count < maxFavoriteEmoji {
            result.append(e)
        }
        return result
    }

    public init() {}

    public func baseLayout(for language: KeyboardLanguage) -> BaseLayout {
        layoutOverrides[language.rawValue] ?? language.defaultBaseLayout
    }

    public func quoteStyle(for language: KeyboardLanguage) -> QuoteStyle {
        quoteStyleOverrides[language.rawValue] ?? language.defaultQuoteStyle
    }

    /// Enabled languages, guaranteed non-empty.
    public var activeLanguages: [KeyboardLanguage] {
        enabledLanguages.isEmpty ? [.deAT] : enabledLanguages
    }

    /// Whether learning is currently allowed by the settings.
    public var learningEnabled: Bool { learnWords && !incognito }

    private enum CodingKeys: String, CodingKey {
        case version, enabledLanguages, layoutOverrides, multilingualTyping, quoteStyleOverrides
        case autocorrect, autoCapitalization, predictiveText, doubleSpacePeriod, smartQuotes, smartPunctuationSpacing
        case accentRestoration, capsLock, spacebarCursor, learnWords, incognito, adaptiveTouch, predictiveTouch
        case autofillSuggestions, cardSuggestions, oneTimeCodeHint
        case haptics, keySound, keyPopups, appearance, favoriteEmoji
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeibordSettings()
        version = c.value(.version, default: d.version)
        // Unknown language codes (from a newer version) are dropped instead of failing.
        // Duplicates are removed (the language key would otherwise cycle through a language twice).
        let rawLanguages = c.lossyArray(.enabledLanguages, default: [String]())
        var parsed: [KeyboardLanguage] = []
        for language in rawLanguages.compactMap(KeyboardLanguage.init(rawValue:)) where !parsed.contains(language) {
            parsed.append(language)
        }
        enabledLanguages = parsed.isEmpty ? d.enabledLanguages : parsed
        // Entries for unknown languages or layouts/quote styles from a newer version are skipped one by one.
        layoutOverrides = c.lossyDictionary(.layoutOverrides, default: d.layoutOverrides)
        multilingualTyping = c.value(.multilingualTyping, default: d.multilingualTyping)
        quoteStyleOverrides = c.lossyDictionary(.quoteStyleOverrides, default: d.quoteStyleOverrides)
        autocorrect = c.value(.autocorrect, default: d.autocorrect)
        autoCapitalization = c.value(.autoCapitalization, default: d.autoCapitalization)
        predictiveText = c.value(.predictiveText, default: d.predictiveText)
        doubleSpacePeriod = c.value(.doubleSpacePeriod, default: d.doubleSpacePeriod)
        smartQuotes = c.value(.smartQuotes, default: d.smartQuotes)
        smartPunctuationSpacing = c.value(.smartPunctuationSpacing, default: d.smartPunctuationSpacing)
        accentRestoration = c.value(.accentRestoration, default: d.accentRestoration)
        capsLock = c.value(.capsLock, default: d.capsLock)
        spacebarCursor = c.value(.spacebarCursor, default: d.spacebarCursor)
        learnWords = c.value(.learnWords, default: d.learnWords)
        incognito = c.value(.incognito, default: d.incognito)
        adaptiveTouch = c.value(.adaptiveTouch, default: d.adaptiveTouch)
        predictiveTouch = c.value(.predictiveTouch, default: d.predictiveTouch)
        autofillSuggestions = c.value(.autofillSuggestions, default: d.autofillSuggestions)
        cardSuggestions = c.value(.cardSuggestions, default: d.cardSuggestions)
        oneTimeCodeHint = c.value(.oneTimeCodeHint, default: d.oneTimeCodeHint)
        haptics = c.value(.haptics, default: d.haptics)
        keySound = c.value(.keySound, default: d.keySound)
        keyPopups = c.value(.keyPopups, default: d.keyPopups)
        appearance = c.value(.appearance, default: d.appearance)
        // didSet does not run in an initialiser: cleaned here (emoji only, each once, at most 8).
        favoriteEmoji = Self.cleanedFavorites(c.lossyArray(.favoriteEmoji, default: d.favoriteEmoji))
        // Version 1 had key shadows on by default; iOS 26 keys have none.
        if version < 2 { appearance.keyShadows = false }
        version = max(version, Self.currentVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(enabledLanguages.map(\.rawValue), forKey: .enabledLanguages)
        try c.encode(layoutOverrides, forKey: .layoutOverrides)
        try c.encode(multilingualTyping, forKey: .multilingualTyping)
        try c.encode(quoteStyleOverrides, forKey: .quoteStyleOverrides)
        try c.encode(autocorrect, forKey: .autocorrect)
        try c.encode(autoCapitalization, forKey: .autoCapitalization)
        try c.encode(predictiveText, forKey: .predictiveText)
        try c.encode(doubleSpacePeriod, forKey: .doubleSpacePeriod)
        try c.encode(smartQuotes, forKey: .smartQuotes)
        try c.encode(smartPunctuationSpacing, forKey: .smartPunctuationSpacing)
        try c.encode(accentRestoration, forKey: .accentRestoration)
        try c.encode(capsLock, forKey: .capsLock)
        try c.encode(spacebarCursor, forKey: .spacebarCursor)
        try c.encode(learnWords, forKey: .learnWords)
        try c.encode(incognito, forKey: .incognito)
        try c.encode(adaptiveTouch, forKey: .adaptiveTouch)
        try c.encode(predictiveTouch, forKey: .predictiveTouch)
        try c.encode(autofillSuggestions, forKey: .autofillSuggestions)
        try c.encode(cardSuggestions, forKey: .cardSuggestions)
        try c.encode(oneTimeCodeHint, forKey: .oneTimeCodeHint)
        try c.encode(haptics, forKey: .haptics)
        try c.encode(keySound, forKey: .keySound)
        try c.encode(keyPopups, forKey: .keyPopups)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(favoriteEmoji, forKey: .favoriteEmoji)
    }
}

// MARK: - Tolerant decoding helpers

public extension KeyedDecodingContainer {
    /// Decodes `key` if present and valid, otherwise returns `defaultValue` (never throws).
    func value<T: Decodable>(_ key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? defaultValue
    }

    /// Decodes an optional value; invalid data yields `nil` instead of throwing.
    func optionalValue<T: Decodable>(_ key: Key, as type: T.Type) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Decodes an array element by element: invalid elements (an unknown enum case written by a newer
    /// version, a damaged entry) are skipped instead of discarding the whole array. Returns
    /// `defaultValue` when the key is missing or not an array.
    func lossyArray<T: Decodable>(_ key: Key, default defaultValue: [T]) -> [T] {
        // Fast path: an undamaged array decodes in one go.
        if let all = try? decodeIfPresent([T].self, forKey: key) { return all }
        guard var items = try? nestedUnkeyedContainer(forKey: key) else { return defaultValue }
        var result: [T] = []
        if let count = items.count { result.reserveCapacity(count) }
        while !items.isAtEnd {
            if let item = try? items.decode(T.self) {
                result.append(item)
            } else if (try? items.decode(SkippedValue.self)) == nil {
                break
            }
        }
        return result
    }

    /// Decodes a string-keyed dictionary entry by entry: invalid values are skipped instead of
    /// discarding the whole dictionary (a single damaged learned word must not wipe all others).
    /// Returns `defaultValue` when the key is missing or not an object.
    func lossyDictionary<T: Decodable>(_ key: Key, default defaultValue: [String: T]) -> [String: T] {
        // Fast path: an undamaged dictionary decodes in one go (entry by entry is ~40% slower, which
        // matters for a large user-model.json loaded whenever the keyboard opens).
        if let all = try? decodeIfPresent([String: T].self, forKey: key) { return all }
        guard let entries = try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: key) else { return defaultValue }
        let keys = entries.allKeys
        var result: [String: T] = [:]
        result.reserveCapacity(keys.count)
        for k in keys {
            if let value = try? entries.decode(T.self, forKey: k) { result[k.stringValue] = value }
        }
        return result
    }
}

/// Any JSON object key (used to decode dictionaries entry by entry).
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    public init(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Consumes one value of any type (moves an unkeyed container past an element that failed to decode).
private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}
