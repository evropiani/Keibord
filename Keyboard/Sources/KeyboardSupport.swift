import UIKit
import KeibordCore

extension UIColor {
    /// Background for every part of the keyboard that must take touches. iOS hit-tests a keyboard
    /// extension by what it drew: fully transparent pixels get no touches, so with a clear background the
    /// gaps between keys and the suggestion bar around its words were dead (only the key itself, or only
    /// the word, reacted). 1 % black is invisible on the keyboard backdrop but counts as drawn.
    static let touchableClear = UIColor(white: 0, alpha: 0.01)
}

/// Resolved visual appearance used by all keyboard views.
///
/// The `UIColor`s keys need are resolved once per theme (the controller caches the theme), not per
/// key and keystroke.
struct KeyboardTheme {
    let isDark: Bool
    let colors: KeyColorScheme
    let cornerRadius: CGFloat
    let shadows: Bool
    let labelScale: CGFloat
    let uppercaseLabels: Bool
    let showsPopups: Bool
    let tints: [String: TintedKey]

    let characterKeyColor: UIColor
    let functionKeyColor: UIColor
    let pressedFunctionKeyColor: UIColor
    let accentColor: UIColor
    let labelUIColor: UIColor
    let keyShadowColor: UIColor
    let secondaryLabel: UIColor
    let backgroundColor: UIColor
    private let tintFills: [String: UIColor]
    private let tintLabels: [String: UIColor]

    init(settings: KeibordSettings, dark: Bool) {
        let a = settings.appearance
        isDark = dark
        let c = a.colors(dark: dark)
        colors = c
        cornerRadius = CGFloat(a.keyCornerRadius)
        shadows = a.keyShadows
        labelScale = CGFloat(min(max(a.labelScale, 0.7), 1.4))
        uppercaseLabels = a.uppercaseLabels
        showsPopups = settings.keyPopups
        var t: [String: TintedKey] = [:]
        var fills: [String: UIColor] = [:]
        var labels: [String: UIColor] = [:]
        for tint in a.tintedKeys {
            t[tint.keyID] = tint
            fills[tint.keyID] = tint.color.uiColor
            labels[tint.keyID] = tint.effectiveLabelColor.uiColor
        }
        tints = t
        tintFills = fills
        tintLabels = labels
        characterKeyColor = c.characterKey.uiColor
        functionKeyColor = c.functionKey.uiColor
        pressedFunctionKeyColor = c.pressedFunctionKey.uiColor
        accentColor = c.accent.uiColor
        labelUIColor = c.label.uiColor
        keyShadowColor = c.keyShadow.uiColor
        secondaryLabel = labelUIColor.withAlphaComponent(0.55)
        // Never fully transparent: a clear keyboard takes no touches (see `UIColor.touchableClear`).
        if let background = c.background, background.alpha >= 0.01 {
            backgroundColor = background.uiColor
        } else {
            backgroundColor = .touchableClear
        }
    }

    func keyColor(_ key: KeySpec, prominentReturn: Bool) -> UIColor {
        if let tint = tintFills[key.id] { return tint }
        switch key.style {
        case .character, .space: return characterKeyColor
        case .returnKey: return prominentReturn ? accentColor : functionKeyColor
        case .function: return functionKeyColor
        case .spacer: return .clear
        }
    }

    func labelColor(_ key: KeySpec, prominentReturn: Bool) -> UIColor {
        if let tint = tintLabels[key.id] { return tint }
        if key.style == .returnKey, prominentReturn { return .white }
        return labelUIColor
    }

    var barHighlight: UIColor { characterKeyColor.withAlphaComponent(isDark ? 0.45 : 0.9) }
}

/// Wraps `UITextDocumentProxy` for the platform-independent input controller.
final class ProxyDocument: TextDocumentProxyLike {
    private unowned let owner: UIInputViewController
    init(owner: UIInputViewController) { self.owner = owner }
    private var proxy: UITextDocumentProxy { owner.textDocumentProxy }

    var documentContextBeforeInput: String? { proxy.documentContextBeforeInput }
    var documentContextAfterInput: String? { proxy.documentContextAfterInput }
    var selectedText: String? { proxy.selectedText }
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { proxy.adjustTextPosition(byCharacterOffset: offset) }
}

/// The text around the cursor as the input controller last saw it (to tell the host's echo of the
/// keyboard's own edits in `textDidChange` from real outside changes).
struct DocumentSnapshot: Equatable {
    var document: UUID
    var before: String?
    var after: String?
    var selected: String?

    init(_ proxy: UITextDocumentProxy) {
        document = proxy.documentIdentifier
        before = proxy.documentContextBeforeInput
        after = proxy.documentContextAfterInput
        selected = proxy.selectedText
    }
}

/// Maps the focused field's traits to a `FieldContext`.
enum FieldContextMapper {
    static func context(for proxy: UITextDocumentProxy) -> FieldContext {
        let contentType: UITextContentType? = proxy.textContentType ?? nil
        let keyboardType = proxy.keyboardType ?? .default
        var variant: LayoutVariant = .standard
        var kind: FieldKind = .text
        switch keyboardType {
        case .emailAddress: kind = .email
        case .URL: kind = .url
        case .webSearch: kind = .webSearch; variant = .webSearch
        case .numberPad, .asciiCapableNumberPad: kind = .number; variant = .numberPad
        case .decimalPad: kind = .decimal; variant = .decimalPad
        case .phonePad, .namePhonePad: kind = .phone
        default: break
        }
        if let t = contentType, let mapped = map(t) { kind = mapped }

        let autocap: AutocapitalizationMode
        switch proxy.autocapitalizationType ?? .sentences {
        case .none: autocap = .none
        case .words: autocap = .words
        case .allCharacters: autocap = .allCharacters
        default: autocap = .sentences
        }
        let returnKind: ReturnKind
        switch proxy.returnKeyType ?? .default {
        case .go: returnKind = .go
        case .google: returnKind = .google
        case .join: returnKind = .join
        case .next: returnKind = .next
        case .route: returnKind = .route
        case .search: returnKind = .search
        case .send: returnKind = .send
        case .yahoo: returnKind = .yahoo
        case .done: returnKind = .done
        case .emergencyCall: returnKind = .emergencyCall
        case .continue: returnKind = .continue
        default: returnKind = .default
        }
        let secure = proxy.isSecureTextEntry ?? false
        return FieldContext(
            kind: kind,
            keyboardVariant: variant,
            autocapitalization: autocap,
            autocorrectionAllowed: (proxy.autocorrectionType ?? .default) != .no,
            smartQuotesAllowed: (proxy.smartQuotesType ?? .default) != .no,
            returnKind: returnKind,
            enablesReturnKeyAutomatically: proxy.enablesReturnKeyAutomatically ?? false,
            isSecure: secure
        )
    }

    private static func map(_ t: UITextContentType) -> FieldKind? {
        switch t {
        case .emailAddress: return .email
        case .URL: return .url
        case .username: return .username
        case .telephoneNumber: return .phone
        case .oneTimeCode: return .oneTimeCode
        case .name: return .fullName
        case .givenName: return .givenName
        case .middleName: return .middleName
        case .familyName: return .familyName
        case .nickname: return .nickname
        case .organizationName: return .organization
        case .jobTitle: return .jobTitle
        case .fullStreetAddress: return .fullStreetAddress
        case .streetAddressLine1: return .streetLine1
        case .streetAddressLine2: return .streetLine2
        case .postalCode: return .postalCode
        case .addressCity: return .city
        case .addressState: return .region
        case .countryName: return .country
        case .creditCardNumber: return .creditCardNumber
        case .creditCardExpiration: return .creditCardExpiration
        case .creditCardExpirationMonth: return .creditCardExpirationMonth
        case .creditCardExpirationYear: return .creditCardExpirationYear
        case .creditCardSecurityCode: return .creditCardSecurityCode
        case .creditCardName: return .creditCardName
        case .creditCardGivenName: return .creditCardGivenName
        case .creditCardFamilyName: return .creditCardFamilyName
        case .creditCardType: return .creditCardType
        default: return nil
        }
    }
}
