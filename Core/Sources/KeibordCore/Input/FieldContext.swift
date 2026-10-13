import Foundation

/// Semantic kind of the focused text field, derived (in the keyboard extension) from
/// `UITextContentType` and `UIKeyboardType`.
public enum FieldKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case webSearch
    case email
    case url
    case username
    case phone
    case number
    case decimal
    case oneTimeCode
    // Personal information
    case fullName, givenName, middleName, familyName, nickname, organization, jobTitle
    case fullStreetAddress, streetLine1, streetLine2, postalCode, city, region, country
    // Payment cards
    case creditCardNumber, creditCardExpiration, creditCardExpirationMonth, creditCardExpirationYear
    case creditCardSecurityCode, creditCardName, creditCardGivenName, creditCardFamilyName, creditCardType

    /// Card related fields show card chips in the suggestion bar.
    public var isCreditCard: Bool { rawValue.hasPrefix("creditCard") }

    /// Fields that are filled from the personal profile (names, address, email, phone, ...).
    public var isPersonalInfo: Bool {
        switch self {
        case .email, .username, .phone, .url,
             .fullName, .givenName, .middleName, .familyName, .nickname, .organization, .jobTitle,
             .fullStreetAddress, .streetLine1, .streetLine2, .postalCode, .city, .region, .country:
            return true
        default:
            return false
        }
    }

    /// Prose fields where autocorrect, predictions and learning make sense.
    public var isProse: Bool { self == .text || self == .webSearch }
}

/// Mirrors `UITextAutocapitalizationType`.
public enum AutocapitalizationMode: String, Codable, Hashable, Sendable {
    case none, words, sentences, allCharacters
}

/// Everything the input logic needs to know about the focused field.
public struct FieldContext: Equatable, Sendable {
    public var kind: FieldKind
    /// The physical keyboard variant (from `UIKeyboardType`); `kind` may refine it.
    public var keyboardVariant: LayoutVariant
    public var autocapitalization: AutocapitalizationMode
    /// `false` when the field sets `autocorrectionType = .no`.
    public var autocorrectionAllowed: Bool
    /// `false` when the field sets `smartQuotesType = .no`.
    public var smartQuotesAllowed: Bool
    public var returnKind: ReturnKind
    public var enablesReturnKeyAutomatically: Bool
    public var isSecure: Bool

    public init(kind: FieldKind = .text, keyboardVariant: LayoutVariant = .standard, autocapitalization: AutocapitalizationMode = .sentences, autocorrectionAllowed: Bool = true, smartQuotesAllowed: Bool = true, returnKind: ReturnKind = .default, enablesReturnKeyAutomatically: Bool = false, isSecure: Bool = false) {
        self.kind = kind
        self.keyboardVariant = keyboardVariant
        self.autocapitalization = autocapitalization
        self.autocorrectionAllowed = autocorrectionAllowed
        self.smartQuotesAllowed = smartQuotesAllowed
        self.returnKind = returnKind
        self.enablesReturnKeyAutomatically = enablesReturnKeyAutomatically
        self.isSecure = isSecure
    }

    public static let plain = FieldContext()

    /// Layout variant actually shown: content type wins over keyboard type for email/url/one-time-code.
    public var layoutVariant: LayoutVariant {
        switch kind {
        case .email: return .email
        case .url: return .url
        case .oneTimeCode, .creditCardNumber, .creditCardSecurityCode, .number:
            return keyboardVariant == .decimalPad ? .decimalPad : .numberPad
        case .decimal: return .decimalPad
        default: return keyboardVariant
        }
    }

    /// Learning (new words, bigrams, touch model) is only allowed in prose fields.
    public var learningAllowed: Bool { kind.isProse && !isSecure }

    /// Autocorrect is only applied in prose fields that allow it.
    public var autocorrectAllowed: Bool { kind.isProse && autocorrectionAllowed && !isSecure }

    /// Predictions / completions are shown for prose fields; personal-info fields show autofill instead.
    public var predictionsAllowed: Bool { kind.isProse && !isSecure }
}
