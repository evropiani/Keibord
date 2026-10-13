import Foundation

/// Which page of the keyboard is visible.
public enum LayoutPage: String, Codable, CaseIterable, Hashable, Sendable {
    case letters
    case numbers   // "123"
    case symbols   // "#+="
}

/// Layout variant derived from the text field (keyboard type / content type).
public enum LayoutVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case standard
    case email        // bottom row: 123, emoji, space, @, ., return
    case url          // bottom row: 123, emoji, ., /, .com, return (no space bar)
    case webSearch    // bottom row: 123, emoji, space, ., return
    case numberPad    // 3×4 digit grid
    case decimalPad   // 3×4 digit grid with the decimal separator
}

/// What a key does when activated.
public enum KeyAction: Hashable, Sendable {
    /// Inserts text. Letter keys insert their lower-case letter; the input controller applies shift.
    case insert(String)
    case shift
    case backspace
    case space
    case returnKey
    case switchPage(LayoutPage)
    case emoji
    /// Cycles to the next enabled Keibord language (long-press: language list).
    case nextLanguage
    /// The system globe key (`UIInputViewController.handleInputModeList`).
    case globe
    /// Non-interactive (spacers).
    case none
}

/// Visual / behavioural category of a key.
public enum KeyStyle: String, Hashable, Sendable {
    case character   // letters, digits, symbols (light key)
    case function    // shift, backspace, 123, ABC, emoji, language, globe (dark key)
    case space
    case returnKey
    case spacer      // invisible, non-interactive
}

/// Width of a key. `units(1)` is the width of one letter key in the layout's widest letter row.
public enum KeyWidth: Hashable, Sendable {
    case units(Double)
    /// Shares the row's remaining width equally with other `.fill` keys.
    case fill
}

/// One key. `id` is stable across pages/languages and is what tinted keys refer to:
/// letters → the lower-case letter ("k"), digits/symbols → the character itself ("1", "@"),
/// special keys → "shift", "backspace", "space", "return", "numbers" (123), "letters" (ABC),
/// "symbols" (#+=), "emoji", "language", "globe", "dotcom" (.com), spacers → "spacer.<n>".
public struct KeySpec: Hashable, Sendable {
    public var id: String
    public var action: KeyAction
    /// Text label (lower-case for letters). Empty for icon keys (shift, backspace, emoji, globe, return w/o label).
    public var label: String
    /// Long-press alternatives (lower-case for letters). Empty = no long-press menu.
    public var alternates: [String]
    public var width: KeyWidth
    public var style: KeyStyle
    /// True for keys whose inserted text and label follow the shift state.
    public var isLetter: Bool

    public init(id: String, action: KeyAction, label: String, alternates: [String] = [], width: KeyWidth = .units(1), style: KeyStyle, isLetter: Bool = false) {
        self.id = id
        self.action = action
        self.label = label
        self.alternates = alternates
        self.width = width
        self.style = style
        self.isLetter = isLetter
    }

    public var isInteractive: Bool { style != .spacer && action != .none }
}

public struct KeyRow: Hashable, Sendable {
    public var keys: [KeySpec]
    public init(keys: [KeySpec]) { self.keys = keys }
}

/// A fully resolved keyboard page ready to be laid out and drawn.
public struct KeyboardLayout: Hashable, Sendable {
    public var language: KeyboardLanguage
    public var page: LayoutPage
    public var variant: LayoutVariant
    public var rows: [KeyRow]
    /// Number of `units(1)` keys that span the full width (e.g. 10 for QWERTY, 11 for German, 3 for number pads).
    public var unitCount: Double
    /// Identifies the geometry class for touch-model learning, e.g. "qwertz11.letters" (same physical
    /// arrangement ⇒ same key). Built by `LayoutFactory`.
    public var touchModelKey: String

    public init(language: KeyboardLanguage, page: LayoutPage, variant: LayoutVariant, rows: [KeyRow], unitCount: Double, touchModelKey: String = "") {
        self.language = language
        self.page = page
        self.variant = variant
        self.rows = rows
        self.unitCount = unitCount
        self.touchModelKey = touchModelKey
    }

    /// All interactive keys in reading order.
    public var allKeys: [KeySpec] { rows.flatMap { $0.keys }.filter { $0.isInteractive } }
}

/// Everything needed to build a layout.
public struct LayoutRequest: Hashable, Sendable {
    public var language: KeyboardLanguage
    public var base: BaseLayout
    public var page: LayoutPage
    public var variant: LayoutVariant
    public var showNumberRow: Bool
    /// Show the Keibord language key (when more than one language is enabled).
    public var showLanguageKey: Bool
    /// Show the system globe key (`needsInputModeSwitchKey`).
    public var showGlobeKey: Bool
    public var returnKind: ReturnKind

    public init(language: KeyboardLanguage, base: BaseLayout, page: LayoutPage = .letters, variant: LayoutVariant = .standard, showNumberRow: Bool = false, showLanguageKey: Bool = false, showGlobeKey: Bool = false, returnKind: ReturnKind = .default) {
        self.language = language
        self.base = base
        self.page = page
        self.variant = variant
        self.showNumberRow = showNumberRow
        self.showLanguageKey = showLanguageKey
        self.showGlobeKey = showGlobeKey
        self.returnKind = returnKind
    }
}
