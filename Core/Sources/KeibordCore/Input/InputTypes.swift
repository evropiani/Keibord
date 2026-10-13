import Foundation

/// Minimal text-document interface (a subset of `UITextDocumentProxy`). The keyboard extension wraps
/// its `textDocumentProxy` in a class conforming to this; tests use an in-memory implementation.
public protocol TextDocumentProxyLike: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    var selectedText: String? { get }
    func insertText(_ text: String)
    /// Deletes one character (grapheme) before the cursor, or the selection.
    func deleteBackward()
    func adjustTextPosition(byCharacterOffset offset: Int)
}

public enum ShiftState: String, Codable, Hashable, Sendable {
    case off
    /// One-shot shift (manual or automatic); turns off after the next letter.
    case on
    /// Caps lock (double-tap on shift).
    case locked

    public var isUppercase: Bool { self != .off }
}

/// Events delivered from the keyboard UI to the `InputController`.
public enum KeyEvent: Hashable, Sendable {
    /// A character key. `text` is the key's lower-case text (or an alternate from a long-press menu);
    /// the controller applies the shift state for letters. `tap` carries spatial info for letter keys.
    case character(String, tap: TapInput?, isLetter: Bool)
    case backspace
    /// Backspace held down: `wordMode` deletes whole words (after the repeat accelerates).
    case backspaceRepeat(wordMode: Bool)
    case space
    case returnKey
    case shift
    case shiftDoubleTap
    case switchPage(LayoutPage)
    case suggestion(Suggestion)
    /// Inserts arbitrary text as-is (emoji, autofill values, ".com"). No autocorrect is applied before it,
    /// but the current word is committed first when `commitsWord` is true.
    case insertText(String, commitsWord: Bool)
    /// Space-bar trackpad movement, in characters (negative = left).
    case moveCursor(Int)
}

/// Learning signals emitted by the input controller. The keyboard extension turns them into a
/// `UserModelDelta` and persists it.
public enum LearningEvent: Hashable, Sendable {
    /// A word was committed (by space, punctuation, return or a suggestion).
    /// `typed` is what the user typed, `final` what ended up in the document (after autocorrect),
    /// `previous` the word before it (for bigrams), `taps` the spatial taps for the typed word.
    case committedWord(final: String, typed: String, previous: String?, language: KeyboardLanguage?, taps: [TapInput]?, wasAutocorrected: Bool)
    /// The user undid an autocorrection (backspace right after it) or picked the literal typed word.
    case rejectedCorrection(typed: String, correction: String)
    case usedEmoji(String)
    case switchedLanguage(KeyboardLanguage)
}

public protocol LearningSink: AnyObject {
    func record(_ event: LearningEvent)
}
