import Foundation

/// One candidate key for a tap, produced by the touch resolver from the touch position.
public struct TapCandidate: Hashable, Sendable {
    /// Lower-case character of the key (e.g. "e").
    public var character: String
    /// Cost in bits (−log2 likelihood relative to the best key). The hit key has cost 0.
    public var cost: Double
    /// Touch offset relative to this key's centre, normalised by key width/height (−0.5…0.5 inside the key).
    public var dx: Double
    public var dy: Double

    public init(character: String, cost: Double, dx: Double = 0, dy: Double = 0) {
        self.character = character
        self.cost = cost
        self.dx = dx
        self.dy = dy
    }
}

/// Spatial information for one typed character. `candidates[0]` is the key that was actually hit.
public struct TapInput: Hashable, Sendable {
    public var candidates: [TapCandidate]
    /// `LayoutGeometry`/touch model key of the layout the tap happened on.
    public var touchModelKey: String

    public init(candidates: [TapCandidate], touchModelKey: String = "") {
        self.candidates = candidates
        self.touchModelKey = touchModelKey
    }

    /// A tap with no spatial alternatives (e.g. inserted from a long-press menu).
    public static func exact(_ character: String) -> TapInput {
        TapInput(candidates: [TapCandidate(character: character.lowercased(), cost: 0)])
    }

    public var primary: String { candidates.first?.character ?? "" }
}

public enum SuggestionKind: String, Hashable, Sendable {
    /// The literal typed word (shown in quotes when an autocorrection is pending).
    case typed
    /// A spelling/typo correction.
    case correction
    /// Completion of the current prefix.
    case completion
    /// Next-word prediction (no current word).
    case prediction
    /// Text replacement / shortcut expansion.
    case shortcut
    /// Personal-info autofill value (email, phone, address, …).
    case autofill
    /// Payment card value (handled by the keyboard UI).
    case card
    /// Hint button (e.g. "Switch to the iOS keyboard for one-time codes").
    case action
}

public struct Suggestion: Hashable, Sendable {
    /// Text that replaces the current word (or is inserted when there is no current word).
    public var text: String
    /// Label shown in the suggestion bar.
    public var display: String
    public var kind: SuggestionKind
    /// True for the candidate that will be applied automatically on space/punctuation.
    public var isAutocorrect: Bool
    public var language: KeyboardLanguage?
    /// Whether a space is appended after inserting (false for e.g. autofilled email prefixes).
    public var appendsSpace: Bool
    /// Free-form identifier (card id for `.card`, action id for `.action`).
    public var payload: String?

    public init(text: String, display: String? = nil, kind: SuggestionKind, isAutocorrect: Bool = false, language: KeyboardLanguage? = nil, appendsSpace: Bool = true, payload: String? = nil) {
        self.text = text
        self.display = display ?? text
        self.kind = kind
        self.isAutocorrect = isAutocorrect
        self.language = language
        self.appendsSpace = appendsSpace
        self.payload = payload
    }
}

/// Input to the suggestion engine for the current cursor position.
public struct SuggestionQuery: Sendable {
    /// The partially typed word right before the cursor ("" ⇒ next-word prediction).
    public var currentWord: String
    /// Taps for each character of `currentWord`, when they are known (same count as `currentWord`).
    public var taps: [TapInput]?
    /// Up to two words before the current word, oldest first.
    public var previousWords: [String]
    /// True if the current word starts a sentence (affects casing of predictions).
    public var isSentenceStart: Bool
    /// Languages to consider, the current layout language first.
    public var languages: [KeyboardLanguage]
    public var field: FieldContext
    /// Settings toggles (already combined with the field's own flags by the caller where relevant).
    public var autocorrectEnabled: Bool
    public var accentRestoration: Bool
    public var predictionsEnabled: Bool

    public init(currentWord: String, taps: [TapInput]? = nil, previousWords: [String] = [], isSentenceStart: Bool = false, languages: [KeyboardLanguage], field: FieldContext = .plain, autocorrectEnabled: Bool = true, accentRestoration: Bool = true, predictionsEnabled: Bool = true) {
        self.currentWord = currentWord
        self.taps = taps
        self.previousWords = previousWords
        self.isSentenceStart = isSentenceStart
        self.languages = languages
        self.field = field
        self.autocorrectEnabled = autocorrectEnabled
        self.accentRestoration = accentRestoration
        self.predictionsEnabled = predictionsEnabled
    }

    public var primaryLanguage: KeyboardLanguage? { languages.first }
}

public struct SuggestionResult: Sendable {
    /// Up to 3 suggestions in bar order (left, centre, right). When `autocorrection` is set it is the
    /// centre entry and the typed word (kind `.typed`) is the left entry.
    public var suggestions: [Suggestion]
    /// The replacement to apply when the user commits the word with space/punctuation.
    public var autocorrection: Suggestion?

    public init(suggestions: [Suggestion] = [], autocorrection: Suggestion? = nil) {
        self.suggestions = suggestions
        self.autocorrection = autocorrection
    }

    public static let empty = SuggestionResult()
}

/// Implemented by `SuggestionEngine`; the input controller only depends on this protocol.
public protocol SuggestionProviding: AnyObject {
    func suggest(_ query: SuggestionQuery) -> SuggestionResult
    /// Called whenever a word is committed so the engine can update its language detection.
    func noteCommitted(word: String, language: KeyboardLanguage?)
    /// Whether `word` is a known word (dictionary, learned words, supplementary lexicon) in any of `languages`.
    func isKnownWord(_ word: String, languages: [KeyboardLanguage]) -> Bool
    /// The language a committed word most likely belongs to (for learning statistics).
    func likelyLanguage(of word: String, among languages: [KeyboardLanguage]) -> KeyboardLanguage?
}
