import UIKit
import KeibordCore

/// Resolved visual appearance used by all keyboard views.
struct KeyboardTheme {
    var isDark: Bool
    var colors: KeyColorScheme
    var cornerRadius: CGFloat
    var shadows: Bool
    var labelScale: CGFloat
    var uppercaseLabels: Bool
    var showsPopups: Bool
    var tints: [String: TintedKey]

    init(settings: KeibordSettings, dark: Bool) {
        let a = settings.appearance
        isDark = dark
        colors = a.colors(dark: dark)
        cornerRadius = CGFloat(a.keyCornerRadius)
        shadows = a.keyShadows
        labelScale = CGFloat(min(max(a.labelScale, 0.7), 1.4))
        uppercaseLabels = a.uppercaseLabels
        showsPopups = settings.keyPopups
        var t: [String: TintedKey] = [:]
        for tint in a.tintedKeys { t[tint.keyID] = tint }
        tints = t
    }

    func keyColor(_ key: KeySpec, prominentReturn: Bool) -> UIColor {
        if let tint = tints[key.id] { return tint.color.uiColor }
        switch key.style {
        case .character, .space: return colors.characterKey.uiColor
        case .returnKey: return prominentReturn ? colors.accent.uiColor : colors.functionKey.uiColor
        case .function: return colors.functionKey.uiColor
        case .spacer: return .clear
        }
    }

    func labelColor(_ key: KeySpec, prominentReturn: Bool) -> UIColor {
        if let tint = tints[key.id] { return tint.effectiveLabelColor.uiColor }
        if key.style == .returnKey, prominentReturn { return .white }
        return colors.label.uiColor
    }

    var backgroundColor: UIColor { colors.background?.uiColor ?? .clear }
    var secondaryLabel: UIColor { colors.label.uiColor.withAlphaComponent(0.55) }
    var barHighlight: UIColor { colors.characterKey.uiColor.withAlphaComponent(isDark ? 0.45 : 0.9) }
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
