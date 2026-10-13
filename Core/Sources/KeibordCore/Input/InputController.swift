import Foundation

public protocol InputControllerDelegate: AnyObject {
    func controllerStateDidChange(_ controller: InputController)
}

/// Remembers an applied autocorrection so a backspace right after it can undo it.
struct UndoInfo: Equatable {
    var original: String
    var correction: String
    var separator: String
    var taps: [TapInput]
}

/// All text-editing logic of the keyboard, independent of UIKit (ARCHITECTURE.md §7).
public final class InputController {
    public weak var delegate: InputControllerDelegate?
    public weak var learningSink: LearningSink?
    public var settings: KeibordSettings {
        didSet {
            if !settings.activeLanguages.contains(language) { language = settings.activeLanguages[0] }
            update()
        }
    }
    public private(set) var field: FieldContext = .plain
    public private(set) var language: KeyboardLanguage
    public private(set) var shiftState: ShiftState = .off
    public private(set) var page: LayoutPage = .letters
    public private(set) var suggestions: [Suggestion] = []
    public private(set) var autocorrection: Suggestion?

    private let document: TextDocumentProxyLike
    private let engine: SuggestionProviding
    private let clock: () -> TimeInterval

    private var taps: [TapInput] = []
    private var undo: UndoInfo?
    /// The last inserted space was added automatically (after a suggestion / correction).
    private var autoSpace = false
    private var lastManualSpaceTime: TimeInterval?
    private var suppressAutocorrectFor: String?
    private var expectedContext: String?

    public init(document: TextDocumentProxyLike, engine: SuggestionProviding, settings: KeibordSettings, language: KeyboardLanguage? = nil, clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.document = document
        self.engine = engine
        self.settings = settings
        self.clock = clock
        let langs = settings.activeLanguages
        self.language = language.flatMap { langs.contains($0) ? $0 : nil } ?? langs[0]
        updateAutoShift()
        refreshSuggestions()
    }

    // MARK: Public API

    public var currentWord: String { TextUnits.trailingWord(in: context) }

    public var languages: [KeyboardLanguage] {
        let enabled = settings.activeLanguages
        guard settings.multilingualTyping else { return [language] }
        return [language] + enabled.filter { $0 != language }
    }

    public func configure(field: FieldContext) {
        let changed = field != self.field
        self.field = field
        if changed {
            page = .letters
            resetComposing()
        }
        update()
    }

    public func setLanguage(_ newLanguage: KeyboardLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        emit(.switchedLanguage(newLanguage), force: true)
        update()
    }

    /// Cycles through the enabled languages.
    public func nextLanguage() {
        let langs = settings.activeLanguages
        guard langs.count > 1 else { return }
        let i = langs.firstIndex(of: language) ?? 0
        setLanguage(langs[(i + 1) % langs.count])
    }

    /// Call from `UIInputViewController.textDidChange`. Resets composing state if the text changed
    /// in a way this controller did not cause (cursor moved, text sent/cleared by the app).
    public func documentDidChange() {
        if let expected = expectedContext, expected != context {
            resetComposing()
        }
        update()
    }

    public func refreshSuggestions() {
        let word = currentWord
        if taps.count != word.count { taps = [] }
        let before = String(context.dropLast(word.count))
        let previous = Array(TextUnits.words(in: String(before.suffix(200))).suffix(2))
        let query = SuggestionQuery(
            currentWord: word,
            taps: taps.isEmpty ? nil : taps,
            previousWords: previous,
            isSentenceStart: isSentenceStart(before),
            languages: languages,
            field: field,
            autocorrectEnabled: settings.autocorrect && suppressAutocorrectFor != word,
            accentRestoration: settings.accentRestoration,
            predictionsEnabled: settings.predictiveText
        )
        let result = engine.suggest(query)
        autocorrection = result.autocorrection
        suggestions = (settings.predictiveText || field.kind.isPersonalInfo) ? result.suggestions : []
    }

    public func handle(_ event: KeyEvent) {
        switch event {
        case let .character(text, tap, isLetter):
            if isLetter { insertLetter(text, tap: tap) } else { insertSymbol(text) }
        case .space:
            handleSpace()
        case .returnKey:
            commitWord(separator: "\n", autocorrect: true)
            autoSpace = false
        case .backspace:
            handleBackspace()
        case .backspaceRepeat(let wordMode):
            if wordMode { deleteWordBackward() } else { deleteCharacter() }
        case .shift:
            switch shiftState {
            case .off: shiftState = .on
            case .on, .locked: shiftState = .off
            }
            delegate?.controllerStateDidChange(self)
            return
        case .shiftDoubleTap:
            shiftState = settings.capsLock ? .locked : .on
            delegate?.controllerStateDidChange(self)
            return
        case .switchPage(let p):
            page = p
            delegate?.controllerStateDidChange(self)
            return
        case .suggestion(let s):
            apply(s)
        case let .insertText(text, commitsWord):
            if commitsWord { commitWord(separator: "", autocorrect: false) }
            insert(text)
            undo = nil
            autoSpace = false
        case .moveCursor(let offset):
            document.adjustTextPosition(byCharacterOffset: offset)
            resetComposing()
        }
        update()
    }

    // MARK: Editing

    private var context: String { document.documentContextBeforeInput ?? "" }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        document.insertText(text)
        expectedContext = context
    }

    private func deleteCharacters(_ n: Int) {
        for _ in 0..<max(0, n) { document.deleteBackward() }
        expectedContext = context
    }

    private func resetComposing() {
        taps = []
        undo = nil
        autoSpace = false
        lastManualSpaceTime = nil
        suppressAutocorrectFor = nil
        expectedContext = nil
    }

    private func insertLetter(_ text: String, tap: TapInput?) {
        if currentWord.isEmpty || taps.count != currentWord.count { taps = [] }
        let output = shiftState.isUppercase ? (text == "ß" ? text : text.uppercased()) : text
        let alignedBefore = taps.count == currentWord.count
        insert(output)
        if alignedBefore {
            for ch in output { taps.append(output.count == 1 ? (tap ?? .exact(String(ch).lowercased())) : .exact(String(ch).lowercased())) }
        }
        undo = nil
        autoSpace = false
        lastManualSpaceTime = nil
        if shiftState == .on { shiftState = .off }
    }

    private static let committingPunctuation: Set<String> = [".", ",", "!", "?", ":", ";", ")", "]", "}", "…", "\"", "»", "”", "“"]

    private func insertSymbol(_ raw: String) {
        var text = raw
        let smartQuotes = settings.smartQuotes && field.smartQuotesAllowed && field.kind.isProse
        if smartQuotes, raw == "\"" || raw == "'" {
            text = SmartPunctuation.quote(for: raw, before: context, style: settings.quoteStyle(for: language))
        }
        let isApostropheInWord = (raw == "'" || raw == "\u{2019}") && !currentWord.isEmpty
        if Self.committingPunctuation.contains(raw), !isApostropheInWord {
            commitWord(separator: "", autocorrect: true)
        }
        if settings.smartPunctuationSpacing, autoSpace, let c = text.first, text.count == 1,
           TextUnits.spaceSwallowingPunctuation.contains(c), context.hasSuffix(" ") {
            deleteCharacters(1)
            insert(text + " ")
            autoSpace = true
        } else {
            if !isApostropheInWord, raw == "'" || raw == "\u{2019}" { taps = [] }
            insert(text)
            if isApostropheInWord, taps.count + 1 == currentWord.count { taps.append(.exact("'")) }
            autoSpace = false
        }
        undo = nil
        lastManualSpaceTime = nil
        if page != .letters, raw == "'" { page = .letters }
    }

    private func handleSpace() {
        let now = clock()
        let ctx = context
        if settings.doubleSpacePeriod, let last = lastManualSpaceTime, now - last < 2.0,
           ctx.hasSuffix(" "), SmartPunctuation.canInsertDoubleSpacePeriod(before: String(ctx.dropLast())) {
            deleteCharacters(1)
            insert(". ")
            lastManualSpaceTime = nil
            autoSpace = false
            undo = nil
            return
        }
        commitWord(separator: " ", autocorrect: true)
        lastManualSpaceTime = now
        autoSpace = false
        if page != .letters { page = .letters }
    }

    /// Commits the word before the cursor (optionally autocorrecting it) and inserts `separator`.
    private func commitWord(separator: String, autocorrect: Bool) {
        let word = currentWord
        guard !word.isEmpty else {
            insert(separator)
            return
        }
        let previous = previousWord()
        // Make sure the autocorrection belongs to the current word.
        refreshSuggestions()
        var final = word
        var corrected = false
        if autocorrect, settings.autocorrect, field.autocorrectAllowed, suppressAutocorrectFor != word, let ac = autocorrection, ac.text != word {
            deleteCharacters(word.count)
            insert(ac.text)
            final = ac.text
            corrected = true
        }
        let wordTaps = taps
        insert(separator)
        undo = corrected ? UndoInfo(original: word, correction: final, separator: separator, taps: wordTaps) : nil
        recordCommit(final: final, typed: word, previous: previous, taps: wordTaps, corrected: corrected)
        taps = []
        suppressAutocorrectFor = nil
    }

    /// The word before the word currently being typed.
    private func previousWord() -> String? {
        let before = String(context.dropLast(currentWord.count))
        return TextUnits.words(in: String(before.suffix(100))).last
    }

    private func recordCommit(final: String, typed: String, previous: String?, taps: [TapInput], corrected: Bool) {
        let lang = engine.likelyLanguage(of: final, among: languages)
        engine.noteCommitted(word: final, language: lang)
        emit(.committedWord(final: final, typed: typed, previous: previous, language: lang, taps: taps.isEmpty ? nil : taps, wasAutocorrected: corrected))
    }

    private func handleBackspace() {
        let ctx = context
        if let u = undo, ctx.hasSuffix(u.correction + u.separator) {
            deleteCharacters(u.correction.count + u.separator.count)
            insert(u.original)
            taps = u.taps
            suppressAutocorrectFor = u.original
            emit(.rejectedCorrection(typed: u.original, correction: u.correction))
            undo = nil
            autoSpace = false
            return
        }
        deleteCharacter()
    }

    private func deleteCharacter() {
        let alignedBefore = taps.count == currentWord.count
        if let selected = document.selectedText, !selected.isEmpty {
            document.deleteBackward()
            expectedContext = context
            taps = []
        } else {
            deleteCharacters(1)
            if alignedBefore, !taps.isEmpty { taps.removeLast() } else { taps = [] }
        }
        undo = nil
        autoSpace = false
        lastManualSpaceTime = nil
        if suppressAutocorrectFor != nil, suppressAutocorrectFor != currentWord { suppressAutocorrectFor = nil }
    }

    private func deleteWordBackward() {
        let chars = Array(context)
        var i = chars.count
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        if i > 0, TextUnits.isWordCharacter(chars[i - 1]) || TextUnits.apostrophes.contains(chars[i - 1]) {
            while i > 0, TextUnits.isWordCharacter(chars[i - 1]) || TextUnits.apostrophes.contains(chars[i - 1]) { i -= 1 }
        } else if i > 0 {
            i -= 1
        }
        let count = max(1, chars.count - i)
        deleteCharacters(count)
        taps = []
        undo = nil
        autoSpace = false
    }

    private func apply(_ s: Suggestion) {
        let word = currentWord
        let previous = word.isEmpty ? TextUnits.words(in: String(context.suffix(100))).last : previousWord()
        switch s.kind {
        case .card, .action:
            return
        case .prediction:
            if let last = context.last, TextUnits.isWordCharacter(last) { insert(" ") }
            insert(s.text)
            if s.appendsSpace { insert(" ") }
            recordCommit(final: s.text, typed: s.text, previous: previous, taps: [], corrected: false)
        case .typed:
            if let ac = autocorrection, ac.text != word, !word.isEmpty {
                emit(.rejectedCorrection(typed: word, correction: ac.text))
            }
            let wordTaps = taps
            if s.appendsSpace { insert(" ") }
            if !word.isEmpty { recordCommit(final: word, typed: word, previous: previous, taps: wordTaps, corrected: false) }
        case .correction, .completion, .shortcut, .autofill:
            let wordTaps = taps
            deleteCharacters(word.count)
            insert(s.text)
            if s.appendsSpace { insert(" ") }
            if s.kind != .autofill {
                recordCommit(final: s.text, typed: word, previous: previous, taps: s.kind == .completion ? [] : wordTaps, corrected: false)
            }
        }
        taps = []
        undo = nil
        suppressAutocorrectFor = nil
        lastManualSpaceTime = nil
        autoSpace = s.appendsSpace
    }

    // MARK: State

    private func emit(_ event: LearningEvent, force: Bool = false) {
        guard force || (settings.learningEnabled && field.learningAllowed) else { return }
        learningSink?.record(event)
    }

    private func isSentenceStart(_ before: String) -> Bool {
        var trimmed = Substring(before)
        if let last = trimmed.last, last == "\n" { return true }
        while let last = trimmed.last, last == " " || last == "\t" { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return true }
        if last == "\n" { return true }
        if TextUnits.sentenceTerminators.contains(last) { return trimmed.count < before.count }
        return false
    }

    private func updateAutoShift() {
        guard shiftState != .locked else { return }
        let mode = settings.autoCapitalization ? field.autocapitalization : .none
        let ctx = context
        let on: Bool
        switch mode {
        case .none: on = false
        case .allCharacters: on = true
        case .words: on = ctx.isEmpty || (ctx.last.map { $0.isWhitespace } ?? true)
        case .sentences: on = currentWord.isEmpty && isSentenceStart(ctx)
        }
        shiftState = on ? .on : .off
    }

    private func update() {
        updateAutoShift()
        refreshSuggestions()
        delegate?.controllerStateDidChange(self)
    }
}
