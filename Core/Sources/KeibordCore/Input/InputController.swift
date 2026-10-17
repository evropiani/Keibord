import Foundation

public protocol InputControllerDelegate: AnyObject {
    func controllerStateDidChange(_ controller: InputController)
}

/// Remembers an applied autocorrection so a backspace right after it can undo it.
struct UndoInfo: Equatable {
    /// Document text of the word before the correction (restored on undo).
    var original: String
    /// Document text of the corrected word (removed on undo).
    var correction: String
    /// Everything inserted after the correction by the committing event (" ", "\n", ".", "“", …).
    var separator: String
    /// Taps of the original token.
    var taps: [TapInput]
    /// The words reported in `.rejectedCorrection` (without a trailing closing quote).
    var typedWord: String
    var correctedWord: String
}

/// All text-editing logic of the keyboard, independent of UIKit (ARCHITECTURE.md §7).
public final class InputController {
    public weak var delegate: InputControllerDelegate?
    public weak var learningSink: LearningSink?
    public var settings: KeibordSettings {
        didSet {
            if !settings.activeLanguages.contains(language) {
                language = settings.activeLanguages[0]
                emit(.switchedLanguage(language), force: true)
            }
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

    /// Taps of the token before the cursor (`TextUnits.trailingWord`), one per character, or empty when unknown.
    private var taps: [TapInput] = []
    private var undo: UndoInfo?
    /// The last inserted space was added automatically (after a suggestion).
    private var autoSpace = false
    /// Time of the space typed by the previous event (for the double-space period).
    private var lastSpaceTime: TimeInterval?
    private var suppressAutocorrectFor: String?
    private var expectedContext: String?
    /// The user set the shift state by hand; auto-capitalisation leaves it alone until the next letter.
    private var manualShift = false
    /// A closing single quote that becomes an apostrophe if a letter follows directly ("‚er geht‘" + s → "geht’s").
    private var pendingApostrophe: (quote: String, apostrophe: String, taps: [TapInput])?

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

    /// The word being typed: the word characters before the cursor, without an elided article that is
    /// a word of its own ("l’amico" → "amico", "c’è" → "è", "dell’anno" → "anno").
    public var currentWord: String { composing(context).word }

    /// Languages used for suggestions: the current language first, then the other enabled ones (in
    /// settings order) when multilingual typing is on.
    public var languages: [KeyboardLanguage] {
        let enabled = settings.activeLanguages
        guard settings.multilingualTyping else { return [language] }
        return [language] + enabled.filter { $0 != language }
    }

    public func configure(field: FieldContext) {
        let changed = field != self.field
        self.field = field
        // A new field, or text that changed while the keyboard was away: start from a clean state.
        if changed || contextChangedExternally {
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
        if contextChangedExternally { resetComposing() }
        update()
    }

    public func refreshSuggestions() {
        let ctx = context
        let c = composing(ctx)
        if !taps.isEmpty, taps.count != c.token.count { taps = [] }
        // Never pass what is typed into a password field to the engine, and never show it in the bar.
        // Inside a word ("Hau|stür") a suggestion would only replace the part before the cursor.
        guard !field.isSecure, c.word.isEmpty || !cursorIsInsideWord else {
            suggestions = []
            autocorrection = nil
            return
        }
        let before = String(ctx.dropLast(c.word.count))
        let result = engine.suggest(makeQuery(word: c.word, taps: composingTaps(c), before: before))
        var list = result.suggestions
        var correction = result.autocorrection
        if correction != nil, !autocorrectPermitted(c.word, before: before) {
            correction = nil
            list = list.map { s in
                var s = s
                s.isAutocorrect = false
                return s
            }
        }
        autocorrection = correction
        suggestions = (settings.predictiveText || field.kind.isPersonalInfo) ? list : []
    }

    public func handle(_ event: KeyEvent) {
        switch event {
        case let .character(text, tap, isLetter):
            if isLetter { insertLetter(text, tap: tap) } else { insertSymbol(text) }
        case .space:
            handleSpace()
        case .returnKey:
            pendingApostrophe = nil
            commitWord(separator: "\n", autocorrect: true)
            autoSpace = false
            lastSpaceTime = nil
            manualShift = false
        case .backspace:
            handleBackspace()
        case .backspaceRepeat(let wordMode):
            if wordMode { deleteWordBackward() } else { deleteCharacter() }
        case .shift:
            toggleShift()
            delegate?.controllerStateDidChange(self)
            return
        case .shiftDoubleTap:
            if settings.capsLock {
                shiftState = .locked
                manualShift = true
            } else {
                // Without caps lock the second tap of a double tap is just another shift tap.
                toggleShift()
            }
            delegate?.controllerStateDidChange(self)
            return
        case .switchPage(let p):
            page = p
            delegate?.controllerStateDidChange(self)
            return
        case .suggestion(let s):
            apply(s)
        case let .insertText(text, commitsWord):
            pendingApostrophe = nil
            if commitsWord { commitWord(separator: "", autocorrect: false) }
            insert(text)
            undo = nil
            autoSpace = false
            lastSpaceTime = nil
        case .moveCursor(let offset):
            document.adjustTextPosition(byCharacterOffset: offset)
            resetComposing()
        }
        update()
    }

    // MARK: Composing word

    private struct Composing {
        /// Word characters (with inner/trailing apostrophes) before the cursor.
        var token: String
        /// The part of `token` the engine works on (`currentWord`).
        var word: String
        /// Elided article before `word` ("l’"), when `token` was split.
        var head: String?
    }

    private func composing(_ ctx: String) -> Composing {
        let token = TextUnits.trailingWord(in: ctx)
        if let split = elisionSplit(token) {
            return Composing(token: token, word: split.word, head: split.head)
        }
        return Composing(token: token, word: token, head: nil)
    }

    /// Splits an unknown token at its last inner apostrophe when the part up to and including the
    /// apostrophe is a word of its own: "l'amico" → ("l'", "amico"), "c'è" → ("c'", "è").
    private func elisionSplit(_ token: String) -> (head: String, word: String)? {
        guard field.kind.isProse else { return nil }
        let chars = Array(token)
        guard chars.count > 2,
              let i = chars.indices.last(where: { $0 > 0 && $0 + 1 < chars.count && TextUnits.apostrophes.contains(chars[$0]) })
        else { return nil }
        let langs = languages
        guard !engine.isKnownWord(token, languages: langs) else { return nil }
        let head = String(chars[...i])
        guard engine.isKnownWord(head, languages: langs) else { return nil }
        return (head, String(chars[(i + 1)...]))
    }

    private func composingTaps(_ c: Composing) -> [TapInput] {
        guard !taps.isEmpty, taps.count == c.token.count else { return [] }
        return Array(taps.suffix(c.word.count))
    }

    /// A closing quote typed right after a word ("hello’"): the word without it, unless the word is
    /// known with the apostrophe ("po'").
    private func trailingQuoteStem(_ word: String) -> String? {
        guard field.kind.isProse, word.count > 1, let last = word.last, TextUnits.apostrophes.contains(last) else { return nil }
        return engine.isKnownWord(word, languages: languages) ? nil : String(word.dropLast())
    }

    /// An unknown word whose part before the first apostrophe is known: a deliberate contraction
    /// ("wie's", "hab's", "so'n") that must not be "corrected" to the bare word.
    private func isContraction(_ word: String) -> Bool {
        guard let i = word.firstIndex(where: { TextUnits.apostrophes.contains($0) }), i != word.startIndex,
              word.index(after: i) != word.endIndex else { return false }
        let langs = languages
        return !engine.isKnownWord(word, languages: langs) && engine.isKnownWord(String(word[..<i]), languages: langs)
    }

    private var hasSelection: Bool { !(document.selectedText ?? "").isEmpty }

    private var cursorIsInsideWord: Bool {
        guard let next = document.documentContextAfterInput?.first else { return false }
        return TextUnits.isWordCharacter(next)
    }

    private func autocorrectPermitted(_ word: String, before: String) -> Bool {
        guard settings.autocorrect, field.autocorrectAllowed, suppressAutocorrectFor != word else { return false }
        // With a selection, deleteBackward would remove the selection instead of the word.
        if hasSelection || cursorIsInsideWord || isEmbedded(before: before) || trailingQuoteStem(word) != nil { return false }
        return !isContraction(word)
    }

    /// A word glued to a URL, e-mail address, path, hashtag or mention ("www.|gogle", "max@|gmx",
    /// "#|urlaub") is neither autocorrected nor learned.
    private func isEmbedded(before: String) -> Bool {
        guard let previous = before.last else { return false }
        return "@./\\_#".contains(previous)
    }

    /// Up to two words of the current sentence before `before`'s end, elided articles split off.
    private func previousWords(before: String) -> [String] {
        var text = Substring(before.suffix(200))
        if let i = text.lastIndex(where: { $0.isNewline || TextUnits.sentenceTerminators.contains($0) }) {
            text = text[text.index(after: i)...]
        }
        let sentence = String(text)
        var words = TextUnits.words(in: sentence)
        // An elided article right before the word keeps its apostrophe ("l'" + "amico").
        let trailing = TextUnits.trailingWord(in: sentence)
        if let last = trailing.last, TextUnits.apostrophes.contains(last), !words.isEmpty {
            words[words.count - 1] = trailing
        }
        var result: [String] = []
        for w in words.suffix(2) {
            if let split = elisionSplit(w) { result += [split.head, split.word] } else { result.append(w) }
        }
        return Array(result.suffix(2))
    }

    private func makeQuery(word: String, taps wordTaps: [TapInput], before: String) -> SuggestionQuery {
        SuggestionQuery(
            currentWord: word,
            taps: !wordTaps.isEmpty && wordTaps.count == word.count ? wordTaps : nil,
            previousWords: previousWords(before: before),
            isSentenceStart: SmartPunctuation.isSentenceStart(before),
            languages: languages,
            field: field,
            autocorrectEnabled: settings.autocorrect && suppressAutocorrectFor != word,
            accentRestoration: settings.accentRestoration,
            predictionsEnabled: settings.predictiveText
        )
    }

    // MARK: Editing

    private var context: String { document.documentContextBeforeInput ?? "" }

    private var contextChangedExternally: Bool {
        guard let expected = expectedContext else { return false }
        return expected != context
    }

    private var smartQuotesActive: Bool {
        settings.smartQuotes && field.smartQuotesAllowed && field.kind.isProse && !field.isSecure
    }

    /// Fields where typed text is natural language (no passwords, addresses, numbers, codes).
    private var allowsTextTransforms: Bool {
        if field.isSecure || field.kind.isCreditCard { return false }
        switch field.kind {
        case .email, .url, .username, .oneTimeCode, .phone, .number, .decimal: return false
        default: return true
        }
    }

    /// Dictionary words use the straight apostrophe ("don't"); with smart quotes, inserted words use the
    /// language's apostrophe like typed ones ("don’t").
    private func styled(_ text: String) -> String {
        guard smartQuotesActive, text.contains("'") else { return text }
        let apostrophe = settings.quoteStyle(for: language).apostrophe
        return apostrophe == "'" ? text : text.replacingOccurrences(of: "'", with: apostrophe)
    }

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
        lastSpaceTime = nil
        suppressAutocorrectFor = nil
        expectedContext = nil
        manualShift = false
        pendingApostrophe = nil
    }

    private func toggleShift() {
        let wasLocked = shiftState == .locked
        shiftState = shiftState == .off ? .on : .off
        // Leaving caps lock hands control back to auto-capitalisation.
        manualShift = !wasLocked
    }

    private func insertLetter(_ text: String, tap: TapInput?) {
        if let p = pendingApostrophe, context.hasSuffix(p.quote) {
            deleteCharacters(p.quote.count)
            insert(p.apostrophe)
            taps = p.taps.isEmpty ? [] : p.taps + [.exact("'")]
        }
        pendingApostrophe = nil
        let tokenBefore = TextUnits.trailingWord(in: context)
        let aligned = taps.count == tokenBefore.count
        if !aligned { taps = [] }
        let output = shiftState.isUppercase ? (text == "ß" ? text : text.uppercased()) : text
        insert(output)
        if aligned {
            if TextUnits.trailingWord(in: context).count == tokenBefore.count + output.count {
                if output.count == 1 {
                    taps.append(tap ?? .exact(output.lowercased()))
                } else {
                    for ch in output { taps.append(.exact(String(ch).lowercased())) }
                }
            } else {
                taps = []
            }
        }
        undo = nil
        autoSpace = false
        lastSpaceTime = nil
        if shiftState == .on { shiftState = .off }
        manualShift = false
    }

    /// Punctuation that ends the word before it (and triggers its autocorrection).
    private static let committingPunctuation: Set<String> = [".", ",", "!", "?", ":", ";", ")", "]", "}", "…", "\"", "»", "«", "”", "“", "‘", "›", "‹"]

    private func insertSymbol(_ raw: String) {
        pendingApostrophe = nil
        let ctx = context
        let style = settings.quoteStyle(for: language)
        let isQuote = raw == "\"" || raw == "'"
        let smart = isQuote && smartQuotesActive
        defer {
            lastSpaceTime = nil
            if page != .letters, raw == "'" || raw == "\u{2019}" { page = .letters }
        }

        // A closing quote right after an automatic space replaces it: „Haus␣ + " → „Haus“␣
        if isQuote, autoSpace, settings.smartPunctuationSpacing, ctx.hasSuffix(" "),
           let close = SmartPunctuation.closingQuoteAfterAutoSpace(for: raw, before: String(ctx.dropLast()), style: smart ? style : .straight) {
            deleteCharacters(1)
            insert(close + " ")
            autoSpace = true
            undo = nil
            return
        }

        let text = smart ? SmartPunctuation.quote(for: raw, before: ctx, style: style) : raw
        let afterWord = ctx.last.map(TextUnits.isWordCharacter) ?? false
        let joinsWord = text.count == 1 && TextUnits.apostrophes.contains(text.first!) && afterWord
        let tapsBefore = taps
        undo = nil
        if !joinsWord, Self.committingPunctuation.contains(text) || Self.committingPunctuation.contains(raw) {
            commitWord(separator: "", autocorrect: true)
        }
        let commitUndo = undo

        if settings.smartPunctuationSpacing, autoSpace, text.count == 1, let c = text.first,
           TextUnits.spaceSwallowingPunctuation.contains(c), context.hasSuffix(" ") {
            deleteCharacters(1)
            insert(text + " ")
            autoSpace = true
            undo = nil
            return
        }

        let tokenBefore = TextUnits.trailingWord(in: context)
        let aligned = taps.count == tokenBefore.count
        insert(text)
        let tokenAfter = TextUnits.trailingWord(in: context)
        if aligned, !tokenAfter.isEmpty, tokenAfter.count == tokenBefore.count + text.count {
            // Apostrophes and digits inside a word ("geht’s", "mp3") keep the tap list aligned.
            for ch in text { taps.append(.exact(TextUnits.apostrophes.contains(ch) ? "'" : String(ch).lowercased())) }
        } else {
            taps = []
        }
        autoSpace = false
        if var u = commitUndo {
            u.separator += text
            undo = u
        }
        if smart, raw == "'", afterWord, text == style.singleClose, style.singleClose != style.apostrophe {
            pendingApostrophe = (quote: text, apostrophe: style.apostrophe, taps: tapsBefore.count == TextUnits.trailingWord(in: ctx).count ? tapsBefore : [])
        }
    }

    private func handleSpace() {
        pendingApostrophe = nil
        let now = clock()
        let ctx = context
        if settings.doubleSpacePeriod, allowsTextTransforms, let last = lastSpaceTime, now - last < 2.0,
           ctx.hasSuffix(" "), SmartPunctuation.canInsertDoubleSpacePeriod(before: String(ctx.dropLast())) {
            deleteCharacters(1)
            insert(". ")
            lastSpaceTime = nil
            autoSpace = false
            undo = nil
        } else {
            commitWord(separator: " ", autocorrect: true)
            lastSpaceTime = now
            autoSpace = false
        }
        if page != .letters { page = .letters }
    }

    /// Commits the word before the cursor (optionally autocorrecting it) and inserts `separator`.
    private func commitWord(separator: String, autocorrect: Bool) {
        let ctx = context
        let c = composing(ctx)
        let word = c.word
        guard !word.isEmpty else {
            insert(separator)
            undo = nil
            return
        }
        let before = String(ctx.dropLast(word.count))
        let previous = previousWords(before: before).last
        let tokenTaps = taps.count == c.token.count ? taps : []
        let wordTaps = composingTaps(c)
        // A closing quote typed right after the word stays outside it: "hello’" commits "hello".
        var core = word
        var tail = ""
        if let stem = trailingQuoteStem(word) {
            core = stem
            tail = String(word.suffix(1))
        }
        let coreTaps = wordTaps.count == word.count ? Array(wordTaps.prefix(core.count)) : []
        var final = core
        var corrected = false
        var expandedShortcut = false
        if autocorrect, suppressAutocorrectFor != word, autocorrectPermitted(core, before: before) {
            let result = engine.suggest(makeQuery(word: core, taps: coreTaps, before: before))
            if let ac = result.autocorrection, !ac.text.isEmpty {
                // Shortcut phrases are inserted exactly as the user stored them.
                expandedShortcut = ac.kind == .shortcut
                let replacement = expandedShortcut ? ac.text : styled(ac.text)
                if replacement != core {
                    final = replacement
                    deleteCharacters(word.count)
                    insert(final + tail)
                    corrected = true
                }
            }
        }
        insert(separator)
        undo = corrected ? UndoInfo(original: word, correction: final + tail, separator: separator, taps: tokenTaps, typedWord: core, correctedWord: final) : nil
        // An expanded shortcut is a phrase, not a word to learn; neither are pieces of URLs and addresses.
        if !(corrected && expandedShortcut), !isEmbedded(before: before) {
            recordCommit(final: final, typed: core, previous: previous, taps: coreTaps, corrected: corrected)
        }
        taps = []
        suppressAutocorrectFor = nil
    }

    private func recordCommit(final: String, typed: String, previous: String?, taps: [TapInput], corrected: Bool) {
        // Nothing typed into passwords, e-mail addresses, URLs, numbers, … reaches the engine or the learning sink.
        guard field.learningAllowed else { return }
        let lang = engine.likelyLanguage(of: final, among: languages)
        engine.noteCommitted(word: final, language: lang)
        emit(.committedWord(final: final, typed: typed, previous: previous, language: lang, taps: taps.isEmpty ? nil : taps, wasAutocorrected: corrected))
    }

    private func handleBackspace() {
        pendingApostrophe = nil
        let ctx = context
        if let u = undo, document.selectedText?.isEmpty ?? true, ctx.hasSuffix(u.correction + u.separator) {
            deleteCharacters(u.correction.count + u.separator.count)
            insert(u.original)
            taps = u.taps
            suppressAutocorrectFor = u.original
            emit(.rejectedCorrection(typed: u.typedWord, correction: u.correctedWord))
            undo = nil
            autoSpace = false
            lastSpaceTime = nil
            manualShift = false
            return
        }
        deleteCharacter()
    }

    private func deleteCharacter() {
        pendingApostrophe = nil
        let tokenBefore = TextUnits.trailingWord(in: context)
        let aligned = !taps.isEmpty && taps.count == tokenBefore.count
        if let selected = document.selectedText, !selected.isEmpty {
            document.deleteBackward()
            expectedContext = context
            taps = []
        } else {
            deleteCharacters(1)
            if aligned, TextUnits.trailingWord(in: context).count == tokenBefore.count - 1 { taps.removeLast() } else { taps = [] }
        }
        undo = nil
        autoSpace = false
        lastSpaceTime = nil
        manualShift = false
        if suppressAutocorrectFor != nil, suppressAutocorrectFor != currentWord { suppressAutocorrectFor = nil }
    }

    /// Deletes back to the previous word boundary: trailing whitespace, then punctuation attached to
    /// the word, then the word itself. A lone emoji (or other symbol) goes on its own.
    private func deleteWordBackward() {
        pendingApostrophe = nil
        if let selected = document.selectedText, !selected.isEmpty {
            deleteCharacter()
            return
        }
        let chars = Array(context)
        var i = chars.count
        func isWordPart(_ c: Character) -> Bool { TextUnits.isWordCharacter(c) || TextUnits.apostrophes.contains(c) }
        func isPunctuation(_ c: Character) -> Bool { !c.isWhitespace && !isWordPart(c) && !SmartPunctuation.isEmoji(c) }
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        let afterWhitespace = i
        while i > 0, isPunctuation(chars[i - 1]) { i -= 1 }
        if i == afterWhitespace, i > 0, SmartPunctuation.isEmoji(chars[i - 1]) {
            i -= 1
        } else {
            while i > 0, isWordPart(chars[i - 1]) { i -= 1 }
        }
        deleteCharacters(max(1, chars.count - i))
        taps = []
        undo = nil
        autoSpace = false
        lastSpaceTime = nil
        manualShift = false
        suppressAutocorrectFor = nil
    }

    private func apply(_ s: Suggestion) {
        pendingApostrophe = nil
        let ctx = context
        let c = composing(ctx)
        let word = c.word
        let wordTaps = composingTaps(c)
        let previous = previousWords(before: String(ctx.dropLast(word.count))).last
        // No extra space when the text after the cursor already starts with one (the cursor moves over
        // it instead) or with punctuation.
        let next = document.documentContextAfterInput?.first
        let skipSpace = s.appendsSpace && next == " "
        let addSpace = s.appendsSpace && !(next.map { $0.isWhitespace || TextUnits.spaceSwallowingPunctuation.contains($0) } ?? false)
        defer {
            if skipSpace, s.kind != .card, s.kind != .action {
                document.adjustTextPosition(byCharacterOffset: 1)
                expectedContext = context
                autoSpace = true
            }
        }
        switch s.kind {
        case .card, .action:
            return
        case .prediction:
            let text = styled(s.text)
            if SmartPunctuation.needsSpaceBeforeWord(after: ctx.last, style: settings.quoteStyle(for: language)) { insert(" ") }
            insert(text)
            if addSpace { insert(" ") }
            recordCommit(final: text, typed: text, previous: previous, taps: [], corrected: false)
        case .typed:
            if !word.isEmpty, let ac = autocorrection, ac.text != word {
                emit(.rejectedCorrection(typed: word, correction: ac.text))
            }
            if addSpace { insert(" ") }
            if !word.isEmpty { recordCommit(final: word, typed: word, previous: previous, taps: wordTaps, corrected: false) }
        case .correction, .completion, .shortcut, .autofill:
            // Shortcut phrases and autofill values are inserted exactly as the user stored them.
            let text = s.kind == .correction || s.kind == .completion ? styled(s.text) : s.text
            if hasSelection { document.deleteBackward() }
            deleteCharacters(word.count)
            insert(text)
            if addSpace { insert(" ") }
            if s.kind != .autofill, s.kind != .shortcut {
                recordCommit(final: text, typed: word, previous: previous, taps: s.kind == .completion ? [] : wordTaps, corrected: false)
            }
        }
        taps = []
        undo = nil
        suppressAutocorrectFor = nil
        lastSpaceTime = nil
        manualShift = false
        autoSpace = addSpace
    }

    // MARK: State

    private func emit(_ event: LearningEvent, force: Bool = false) {
        guard force || (settings.learningEnabled && field.learningAllowed) else { return }
        learningSink?.record(event)
    }

    private func updateAutoShift() {
        guard shiftState != .locked, !manualShift else { return }
        shiftState = autoShiftWanted() ? .on : .off
    }

    private func autoShiftWanted() -> Bool {
        guard settings.autoCapitalization, !field.isSecure else { return false }
        let ctx = context
        switch field.autocapitalization {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard TextUnits.trailingWord(in: ctx).isEmpty else { return false }
            var rest = Substring(ctx)
            while let last = rest.last, "([{\"'„“‚‘«»‹›".contains(last) { rest = rest.dropLast() }
            return rest.last.map { $0.isWhitespace } ?? true
        case .sentences:
            return currentWord.isEmpty && SmartPunctuation.isSentenceStart(ctx)
        }
    }

    private func update() {
        updateAutoShift()
        refreshSuggestions()
        delegate?.controllerStateDidChange(self)
    }
}
