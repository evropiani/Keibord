import UIKit
import AudioToolbox
import KeibordCore

final class KeyboardViewController: UIInputViewController {
    private let store = KeibordStore.shared
    private var settings = KeibordSettings()
    private var profile = PersonalProfile()
    private var userModel = UserModel()
    private var engine: SuggestionEngine!
    private var controller: InputController!
    private var document: ProxyDocument!

    private let suggestionBar = SuggestionBarView()
    private let keyboardView = KeyboardView()
    // Created on first use only (each flag says whether the view exists and is in the hierarchy).
    private lazy var emojiPanel = EmojiPanelView()
    private lazy var emojiSearchBar = EmojiSearchBarView()
    private lazy var cardUnlockView = CardUnlockView()
    private var emojiPanelAdded = false
    private var emojiSearchBarAdded = false
    private var cardUnlockAdded = false
    private var heightConstraint: NSLayoutConstraint?

    private enum Mode: Equatable { case keys, emoji, emojiSearch, cardUnlock(UUID) }
    private var mode: Mode = .keys

    private var pendingDelta = UserModelDelta()
    private var pendingEvents = 0
    private var settingsDate: Date?
    private var profileDate: Date?
    /// Modification date of user-model.json as last loaded or written by this keyboard. Another date on
    /// disk means the app changed the file (dictionary edits, import, reset).
    private var userModelDate: Date?
    /// Writes learning data (JSON decode/encode + coordinated file IO) off the main thread, in order.
    private let flushQueue = DispatchQueue(label: "com.keibord.keyboard.learning", qos: .utility)
    /// The engine has not seen the latest learned words/bigrams yet; refreshed when typing pauses.
    private var engineNeedsUserModel = false
    /// A word became "known" since the user lexicon was last built.
    private var userLexiconDirty = false
    private var engineRefreshToken = 0
    private var engineRefreshPending = false
    private var lastSupplementaryRequest: Date?
    /// `hasFullAccess`, read once per appearance (it cannot change while the keyboard is shown).
    private var fullAccess = false
    private var fullAccessHintExpanded = false

    private var emojiCatalog: EmojiCatalog?
    private var emojiCatalogLoaded = false
    /// The emoji search loaded keyword tables (a few MB) that should be freed when leaving the emoji UI.
    private var emojiSearchUsed = false
    private var sessionEmoji: [String] = []
    private var cards: [StoredCard] = []
    private var unlockedCards: [UUID: (UnlockedCard, Date)] = [:]
    private var feedback: UIImpactFeedbackGenerator?

    // render() runs for every key event: layouts, the theme and learned touch offsets are cached.
    private var layoutCache: [LayoutRequest: KeyboardLayout] = [:]
    private var settingsGeneration = 0
    private var userModelGeneration = 0
    private var cachedTheme: (generation: Int, dark: Bool, theme: KeyboardTheme)?
    private var cachedOffsets: (id: String, offsets: [String: (dx: Double, dy: Double)])?

    private static let barHeight: CGFloat = 44
    /// An unlocked card stays usable (in memory) for 3 minutes.
    private static let unlockLifetime: TimeInterval = 180
    /// Learned words/bigrams reach the engine after this much typing pause.
    private static let engineRefreshDelay: TimeInterval = 2

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = store.loadSettings()
        settingsDate = store.modificationDate(of: .settings)
        profile = store.loadProfile()
        profileDate = store.modificationDate(of: .profile)
        userModelDate = store.modificationDate(of: .userModel)
        userModel = store.loadUserModel()

        engine = SuggestionEngine { language in
            guard let url = Bundle.main.url(forResource: language.dictionaryID, withExtension: "kbdl", subdirectory: "Dictionaries") else { return nil }
            return try? BinaryLexicon(url: url)
        }
        engine.setProfile(profile.info)
        engine.setShortcuts(profile.shortcuts)
        applyUserModelToEngine(rebuildLexicon: true)

        document = ProxyDocument(owner: self)
        let state = store.loadState()
        controller = InputController(document: document, engine: engine, settings: settings, language: state.currentLanguage)
        controller.delegate = self
        controller.learningSink = self

        suggestionBar.delegate = self
        keyboardView.delegate = self
        keyboardView.inputModeTarget = self
        view.addSubview(suggestionBar)
        view.addSubview(keyboardView)

        let h = view.heightAnchor.constraint(equalToConstant: 260)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        fullAccess = hasFullAccess
        reloadIfChanged()
        purgeExpiredCards()
        cards = settings.cardSuggestions ? CardVault.shared.cards() : []
        if fullAccess, settings.haptics != .off {
            let style: UIImpactFeedbackGenerator.FeedbackStyle = settings.haptics == .strong ? .heavy : (settings.haptics == .medium ? .medium : .light)
            feedback = UIImpactFeedbackGenerator(style: style)
            feedback?.prepare()
        } else {
            feedback = nil
        }
        // Text replacements and contact names: refreshed at most every 5 minutes, not on every appearance.
        if lastSupplementaryRequest.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            lastSupplementaryRequest = Date()
            requestSupplementaryLexicon { [weak self] lexicon in
                let entries = lexicon.entries.map { (input: $0.userInput, text: $0.documentText) }
                DispatchQueue.main.async { self?.engine.setSupplementaryLexicon(entries) }
            }
        }
        mode = .keys
        fullAccessHintExpanded = false
        controller.configure(field: FieldContextMapper.context(for: textDocumentProxy))
        writeState()
        render()
        scheduleEngineRefresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A held backspace must not keep deleting once the keyboard goes away.
        keyboardView.cancelAllTouches()
        cancelEngineRefresh()
        flushLearning(synchronously: true)
        releaseEmojiSearchData()
        purgeExpiredCards()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        layoutCache.removeAll()
        if mode != .emoji, mode != .emojiSearch { releaseEmojiSearchData(force: true) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChildren()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.render() }, completion: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        render()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard controller != nil else { return }
        let field = FieldContextMapper.context(for: textDocumentProxy)
        if field != controller.field { controller.configure(field: field) }
        controller.documentDidChange()
    }

    // MARK: Data

    private func reloadIfChanged() {
        let sDate = store.modificationDate(of: .settings)
        if sDate != settingsDate {
            settingsDate = sDate
            settings = store.loadSettings()
            settingsGeneration += 1
            controller?.settings = settings
        }
        let pDate = store.modificationDate(of: .profile)
        if pDate != profileDate {
            profileDate = pDate
            profile = store.loadProfile()
            engine.setProfile(profile.info)
            engine.setShortcuts(profile.shortcuts)
        }
        // Learned data is only reloaded when the app changed the file: decoding a large model and
        // rebuilding the user lexicon on every appearance delayed the keyboard and spiked its memory.
        if store.modificationDate(of: .userModel) != userModelDate {
            // Pending increments go to disk first (and running writes finish), so the reload contains them.
            flushLearning(synchronously: true)
            userModelDate = store.modificationDate(of: .userModel)
            userModel = store.loadUserModel()
            applyUserModelToEngine(rebuildLexicon: true)
        }
    }

    /// Hands the in-memory user model to the engine (bigrams, blocked words, language usage) and, when
    /// asked, rebuilds the user lexicon of known words. Both take tens of milliseconds with a big model.
    private func applyUserModelToEngine(rebuildLexicon: Bool) {
        engine.setUserModel(userModel)
        if rebuildLexicon {
            let words = userModel.knownWords()
            engine.setUserLexicon(words.isEmpty ? nil : InMemoryLexicon(languageID: "user", entries: words))
            userLexiconDirty = false
        }
        engineNeedsUserModel = false
        userModelGeneration += 1 // learned touch offsets may have changed
    }

    /// Records a learning event in the pending delta and the in-memory model.
    private func noteLearning(_ event: LearningEvent) {
        var single = UserModelDelta()
        single.record(event)
        guard !single.isEmpty else { return }
        let threshold = LearningPolicy.knownThreshold
        let wasUnknown = single.words.keys.filter { (userModel.words[$0]?.count ?? 0) < threshold }
        pendingDelta.record(event)
        userModel.apply(single)
        if wasUnknown.contains(where: { (userModel.words[$0]?.count ?? 0) >= threshold }) {
            // A newly known word (e.g. a rejected autocorrection) must stop being "corrected" soon, not
            // only after the next 25 events: hand it to the engine at the next typing pause.
            userLexiconDirty = true
            engineNeedsUserModel = true
            scheduleEngineRefresh()
        }
        pendingEvents += 1
    }

    /// Writes the pending learning delta. Typing flushes run in the background; `synchronously` (keyboard
    /// disappearing, reload) also waits for writes still running.
    private func flushLearning(synchronously: Bool = false) {
        guard !pendingDelta.isEmpty else {
            if synchronously { flushQueue.sync {} }
            return
        }
        let delta = pendingDelta
        pendingDelta = UserModelDelta()
        pendingEvents = 0
        let store = self.store
        if synchronously {
            flushQueue.sync {
                let dates = writeLearning(delta, to: store)
                DispatchQueue.main.async { [weak self] in self?.didFlush(before: dates.before, after: dates.after) }
            }
        } else {
            flushQueue.async {
                let dates = writeLearning(delta, to: store)
                DispatchQueue.main.async { [weak self] in self?.didFlush(before: dates.before, after: dates.after) }
            }
        }
        engineNeedsUserModel = true
        scheduleEngineRefresh()
    }

    private func didFlush(before: Date?, after: Date?) {
        // Our own write: remember its date so the next appearance does not decode the file again. If the
        // app had changed the file in between, keep the old date so that change is loaded next time.
        if before == userModelDate { userModelDate = after }
    }

    /// Refreshes the engine's view of the learned data once typing pauses for a moment, instead of in
    /// the middle of a keystroke. Called again on every key press, which postpones it while typing.
    private func scheduleEngineRefresh() {
        guard engineNeedsUserModel else { return }
        engineRefreshToken += 1
        let token = engineRefreshToken
        engineRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.engineRefreshDelay) { [weak self] in
            // Superseded by a later key press (or cancelled by viewWillDisappear).
            guard let self = self, self.engineRefreshToken == token else { return }
            self.engineRefreshPending = false
            guard self.engineNeedsUserModel else { return }
            self.applyUserModelToEngine(rebuildLexicon: self.userLexiconDirty)
        }
    }

    private func cancelEngineRefresh() {
        engineRefreshToken += 1
        engineRefreshPending = false
    }

    private func writeState() {
        let state = KeyboardRuntimeState(currentLanguage: controller.language, lastActive: Date(), hasFullAccess: fullAccess,
                                         keyboardVersion: KeibordVersion.display, appGroupIdentifier: AppGroup.resolvedIdentifier)
        let store = self.store
        flushQueue.async { store.saveState(state) }
    }

    private var isDark: Bool {
        switch settings.appearance.themeMode {
        case .light: return false
        case .dark: return true
        case .system:
            return (textDocumentProxy.keyboardAppearance ?? .default) == .dark || traitCollection.userInterfaceStyle == .dark
        }
    }

    private var isLandscape: Bool { traitCollection.verticalSizeClass == .compact }

    // MARK: Rendering

    private func currentTheme() -> KeyboardTheme {
        let dark = isDark
        if let cached = cachedTheme, cached.generation == settingsGeneration, cached.dark == dark { return cached.theme }
        let theme = KeyboardTheme(settings: settings, dark: dark)
        cachedTheme = (generation: settingsGeneration, dark: dark, theme: theme)
        return theme
    }

    private func layout(for request: LayoutRequest) -> KeyboardLayout {
        if let cached = layoutCache[request] { return cached }
        let layout = LayoutFactory.layout(for: request)
        if layoutCache.count >= 8 { layoutCache.removeAll() }
        layoutCache[request] = layout
        return layout
    }

    private func touchOffsets(for layout: KeyboardLayout) -> (id: String, offsets: [String: (dx: Double, dy: Double)]) {
        guard settings.adaptiveTouch else { return (id: "off", offsets: [:]) }
        let id = "\(layout.touchModelKey)#\(userModelGeneration)"
        if let cached = cachedOffsets, cached.id == id { return cached }
        let result = (id: id, offsets: userModel.touchOffsets(for: layout.touchModelKey))
        cachedOffsets = result
        return result
    }

    /// Metrics for a page with fewer rows than the keyboard is tall (numbers/symbols next to a letters
    /// page with a number row): the rows get taller instead of the keyboard changing height.
    private static func metrics(_ m: KeyboardMetrics, rows: Int, filling target: Int) -> KeyboardMetrics {
        guard rows > 0, target > rows else { return m }
        var stretched = m
        stretched.rowPitch = m.rowPitch * CGFloat(target) / CGFloat(rows)
        stretched.keyHeight = stretched.rowPitch - (m.rowPitch - m.keyHeight)
        return stretched
    }

    private func render() {
        guard controller != nil else { return }
        let theme = currentTheme()
        view.backgroundColor = theme.backgroundColor
        let baseMetrics = KeyboardMetrics.standard(height: settings.appearance.keyHeight, landscape: isLandscape)
        let field = controller.field
        let searching = mode == .emojiSearch
        let numberRow = settings.appearance.showNumberRow && !searching
        // The emoji panel and the CVV pad take the height of the letter keys they replace.
        let request = LayoutRequest(
            language: controller.language,
            base: settings.baseLayout(for: controller.language),
            page: searching ? .letters : controller.page,
            variant: searching ? .standard : field.layoutVariant,
            showNumberRow: numberRow && controller.page == .letters,
            showLanguageKey: settings.activeLanguages.count > 1 && !searching,
            showGlobeKey: needsInputModeSwitchKey,
            returnKind: field.returnKind
        )
        let layout = self.layout(for: request)
        let isPad = request.variant == .numberPad || request.variant == .decimalPad
        let rows = max(layout.rows.count, isPad ? 4 : (numberRow ? 5 : 4))
        let keysHeight = baseMetrics.keyboardHeight(rows: rows)
        var total = Self.barHeight + keysHeight
        if searching { total += Self.barHeight }
        if heightConstraint?.constant != total { heightConstraint?.constant = total }

        if mode == .keys || searching {
            let offsets = touchOffsets(for: layout)
            let multiple = settings.activeLanguages.count > 1
            let spaceLabel = settings.appearance.showSpaceLanguageLabel && multiple ? controller.language.displayName : controller.language.spaceKeyLabel
            let empty = (textDocumentProxy.documentContextBeforeInput ?? "").isEmpty && (textDocumentProxy.documentContextAfterInput ?? "").isEmpty
            keyboardView.languages = settings.activeLanguages
            // While searching emoji, keys type into the query: no trackpad, and letters arrive lower-case.
            keyboardView.spacebarCursor = settings.spacebarCursor && !searching
            keyboardView.configure(layout: layout, metrics: Self.metrics(baseMetrics, rows: layout.rows.count, filling: rows),
                                   theme: theme, shiftState: searching ? .off : controller.shiftState,
                                   spaceLabel: spaceLabel, returnEnabled: !(field.enablesReturnKeyAutomatically && empty),
                                   returnProminent: field.returnKind.isProminent,
                                   touchOffsets: offsets.offsets, touchOffsetsID: offsets.id)
        }

        switch mode {
        case .keys:
            suggestionBar.update(barItems(), theme: theme)
        case .emoji:
            configureEmojiPanel(theme: theme)
        case .emojiSearch:
            emojiSearchBar.configure(theme: theme, placeholder: searchPlaceholder)
        case .cardUnlock:
            break
        }
        updateVisibility()
        layoutChildren()
    }

    private func layoutChildren() {
        let b = view.bounds
        switch mode {
        case .keys:
            suggestionBar.frame = CGRect(x: 0, y: 0, width: b.width, height: Self.barHeight)
            keyboardView.frame = CGRect(x: 0, y: Self.barHeight, width: b.width, height: max(0, b.height - Self.barHeight))
        case .emojiSearch:
            if emojiSearchBarAdded { emojiSearchBar.frame = CGRect(x: 0, y: 0, width: b.width, height: 2 * Self.barHeight) }
            keyboardView.frame = CGRect(x: 0, y: 2 * Self.barHeight, width: b.width, height: max(0, b.height - 2 * Self.barHeight))
        case .emoji:
            if emojiPanelAdded { emojiPanel.frame = b }
        case .cardUnlock:
            if cardUnlockAdded { cardUnlockView.frame = b }
        }
    }

    private func updateVisibility() {
        suggestionBar.isHidden = mode != .keys
        keyboardView.isHidden = !(mode == .keys || mode == .emojiSearch)
        if mode == .emoji, !emojiPanelAdded {
            emojiPanelAdded = true
            emojiPanel.delegate = self
            view.addSubview(emojiPanel)
        }
        if mode == .emojiSearch, !emojiSearchBarAdded {
            emojiSearchBarAdded = true
            emojiSearchBar.delegate = self
            // Below the key area, so the previews and accent menus of the top key row stay visible.
            view.insertSubview(emojiSearchBar, belowSubview: keyboardView)
        }
        if case .cardUnlock = mode, !cardUnlockAdded {
            cardUnlockAdded = true
            cardUnlockView.delegate = self
            view.addSubview(cardUnlockView)
        }
        if emojiPanelAdded { emojiPanel.isHidden = mode != .emoji }
        if emojiSearchBarAdded { emojiSearchBar.isHidden = mode != .emojiSearch }
        if cardUnlockAdded {
            if case .cardUnlock = mode { cardUnlockView.isHidden = false } else { cardUnlockView.isHidden = true }
        }
    }

    private func barItems() -> [Suggestion] {
        let field = controller.field
        if field.kind.isCreditCard, settings.cardSuggestions, !cards.isEmpty {
            return cards.prefix(3).map { Suggestion(text: "", display: $0.title, kind: .card, appendsSpace: false, payload: $0.id.uuidString) }
        }
        if field.kind == .oneTimeCode, settings.oneTimeCodeHint {
            let text: String
            switch controller.language.languageCode {
            case "de": text = "Code aus Nachrichten → iOS-Tastatur"
            case "sq": text = "Kodi nga Mesazhet → tastiera e iOS"
            case "it": text = "Codice da Messaggi → tastiera iOS"
            default: text = "Code from Messages → iOS keyboard"
            }
            return [Suggestion(text: "", display: text, kind: .action, appendsSpace: false, payload: "switch-keyboard")]
        }
        if !fullAccess, controller.suggestions.isEmpty, controller.currentWord.isEmpty {
            return [Suggestion(text: "", display: fullAccessHintExpanded ? fullAccessInstructions : fullAccessHint,
                               kind: .action, appendsSpace: false, payload: "full-access")]
        }
        return controller.suggestions
    }

    private var fullAccessHint: String {
        switch controller.language.languageCode {
        case "de": return "Vollen Zugriff erlauben für Lernen & Einstellungen"
        case "sq": return "Lejo qasjen e plotë për mësim dhe cilësime"
        case "it": return "Consenti accesso completo per apprendimento e impostazioni"
        default: return "Allow Full Access for learning & settings"
        }
    }

    /// Shown when the hint is tapped (a keyboard extension cannot open Settings itself).
    private var fullAccessInstructions: String {
        switch controller.language.languageCode {
        case "de": return "Einstellungen › Keibord › Tastaturen › Voller Zugriff"
        case "sq": return "Cilësimet › Keibord › Tastierat › Qasje e plotë"
        case "it": return "Impostazioni › Keibord › Tastiere › Accesso completo"
        default: return "Settings › Keibord › Keyboards › Allow Full Access"
        }
    }

    private func showBarMessage(_ message: String) {
        suggestionBar.update([Suggestion(text: "", display: message, kind: .action, appendsSpace: false)], theme: currentTheme())
    }

    // MARK: Emoji

    private var searchPlaceholder: String {
        switch controller.language.languageCode {
        case "de": return "Emoji suchen"
        case "sq": return "Kërko emoji"
        case "it": return "Cerca emoji"
        default: return "Search Emoji"
        }
    }

    private func loadCatalog() -> EmojiCatalog? {
        if !emojiCatalogLoaded {
            emojiCatalogLoaded = true
            if let url = Bundle.main.url(forResource: "Emoji", withExtension: nil) {
                emojiCatalog = try? EmojiCatalog(baseURL: url)
            }
        }
        return emojiCatalog
    }

    /// Frees the emoji catalog once its keyword tables were loaded by a search (the extension's memory
    /// limit is tight); the panel loads it again when it is next opened.
    private func releaseEmojiSearchData(force: Bool = false) {
        guard emojiSearchUsed || force else { return }
        emojiSearchUsed = false
        emojiCatalog = nil
        emojiCatalogLoaded = false
        if emojiPanelAdded { emojiPanel.releaseData() }
    }

    private var emojiRecents: [String] {
        var result = sessionEmoji
        for e in userModel.emojiRecents where !result.contains(e) { result.append(e) }
        return Array(result.prefix(32))
    }

    private func configureEmojiPanel(theme: KeyboardTheme) {
        emojiPanel.configure(catalog: loadCatalog(), recents: emojiRecents, theme: theme, languageCode: controller.language.languageCode)
    }

    private func insertEmoji(_ emoji: String) {
        controller.handle(.insertText(emoji, commitsWord: true))
        sessionEmoji.removeAll { $0 == emoji }
        sessionEmoji.insert(emoji, at: 0)
        // Incognito pauses all learning, emoji recents included (they stay for this session only).
        if !settings.incognito { noteLearning(.usedEmoji(emoji)) }
        playFeedback(sound: 1104)
    }

    private func updateEmojiSearch(_ query: String) {
        let codes = Array(Set(settings.activeLanguages.map { $0.emojiKeywordCode } + ["en"])).sorted()
        let results: [String]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = emojiRecents
        } else {
            emojiSearchUsed = true
            results = loadCatalog()?.search(query, languageCodes: codes, limit: 40) ?? []
        }
        emojiSearchBar.setQuery(query, results: results)
    }

    // MARK: Cards

    private func fill(card unlocked: UnlockedCard) {
        let c = unlocked.card
        let value: String?
        switch controller.field.kind {
        case .creditCardNumber: value = unlocked.number
        case .creditCardExpiration: value = c.expiry
        case .creditCardExpirationMonth: value = String(format: "%02d", c.expMonth)
        case .creditCardExpirationYear: value = String(c.expYear)
        case .creditCardSecurityCode: value = unlocked.cvv
        case .creditCardName: value = c.holderName
        case .creditCardGivenName: value = c.holderName.split(separator: " ").first.map(String.init)
        case .creditCardFamilyName: value = c.holderName.split(separator: " ").dropFirst().joined(separator: " ")
        case .creditCardType: value = c.brand.displayName
        default: value = unlocked.number
        }
        if let value = value, !value.isEmpty {
            controller.handle(.insertText(value, commitsWord: false))
        }
    }

    /// Drops unlocked cards older than 3 minutes, so decrypted numbers do not stay in memory.
    private func purgeExpiredCards() {
        let now = Date()
        unlockedCards = unlockedCards.filter { now.timeIntervalSince($0.value.1) < Self.unlockLifetime }
    }

    private func useCard(id: UUID) {
        purgeExpiredCards()
        if let cached = unlockedCards[id] {
            fill(card: cached.0)
            return
        }
        guard let card = cards.first(where: { $0.id == id }) else { return }
        if card.requiresCVV {
            mode = .cardUnlock(id)
            updateVisibility()
            cardUnlockView.configure(title: cvvTitle(card), cvvLength: card.brand.cvvLength, theme: currentTheme())
            layoutChildren()
            return
        }
        do {
            let unlocked = try CardVault.shared.unlock(id: id, cvv: nil)
            unlockedCards[id] = (unlocked, Date())
            fill(card: unlocked)
        } catch {
            showBarMessage(error.localizedDescription)
        }
    }

    private func cvvTitle(_ card: StoredCard) -> String {
        switch controller.language.languageCode {
        case "de": return "Prüfnummer für \(card.title)"
        case "sq": return "Kodi CVV për \(card.title)"
        case "it": return "CVV per \(card.title)"
        default: return "CVV for \(card.title)"
        }
    }

    // MARK: Feedback

    private func playFeedback(sound: SystemSoundID) {
        guard fullAccess else { return }
        if let feedback = feedback {
            feedback.impactOccurred()
            // Keeps the Taptic Engine ready, so the next key press has no haptic lag.
            feedback.prepare()
        }
        if settings.keySound { AudioServicesPlaySystemSound(sound) }
    }

    private static func sound(for key: KeySpec) -> SystemSoundID {
        if key.action == .backspace { return 1155 }
        return key.style == .character || key.style == .space ? 1104 : 1156
    }
}

/// Applies a learning delta to user-model.json (runs on the flush queue) and returns the file's
/// modification dates before and after the write.
private func writeLearning(_ delta: UserModelDelta, to store: KeibordStore) -> (before: Date?, after: Date?) {
    let before = store.modificationDate(of: .userModel)
    store.flush(delta)
    return (before: before, after: store.modificationDate(of: .userModel))
}

// MARK: - Delegates

extension KeyboardViewController: InputControllerDelegate {
    func controllerStateDidChange(_ controller: InputController) {
        guard mode == .keys || mode == .emojiSearch else { return }
        render()
    }
}

extension KeyboardViewController: LearningSink {
    func record(_ event: LearningEvent) {
        if case .switchedLanguage = event {
            writeState()
            return
        }
        guard settings.learningEnabled else { return }
        noteLearning(event)
        if pendingEvents >= 25 { flushLearning() }
    }
}

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardView(_ view: KeyboardView, didTrigger event: KeyboardViewEvent) {
        if case .keyDown = event, engineRefreshPending {
            scheduleEngineRefresh() // still typing: postpone the engine refresh
        }
        if mode == .emojiSearch {
            handleSearchKey(event)
            return
        }
        switch event {
        case .keyDown(let key):
            playFeedback(sound: Self.sound(for: key))
        case let .character(text, tap, isLetter):
            controller.handle(.character(text, tap: tap, isLetter: isLetter))
        case .backspace: controller.handle(.backspace)
        case .backspaceRepeat(let wordMode):
            controller.handle(.backspaceRepeat(wordMode: wordMode))
            playFeedback(sound: 1155)
        case .space: controller.handle(.space)
        case .returnKey: controller.handle(.returnKey)
        case .shift: controller.handle(.shift)
        case .shiftDoubleTap: controller.handle(.shiftDoubleTap)
        case .switchPage(let page): controller.handle(.switchPage(page))
        case .emoji:
            mode = .emoji
            render()
        case .nextLanguage:
            controller.nextLanguage()
        case .selectLanguage(let language):
            controller.setLanguage(language)
        case .moveCursor(let n):
            controller.handle(.moveCursor(n))
            feedback?.impactOccurred(intensity: 0.4)
        case .trackpad(let active):
            if active { feedback?.impactOccurred() }
        }
    }

    func keyboardView(_ view: KeyboardView, globeTouchedWith event: UIEvent, in keyView: UIView) {
        handleInputModeList(from: keyView, with: event)
    }

    private func handleSearchKey(_ event: KeyboardViewEvent) {
        var query = emojiSearchBar.query
        switch event {
        case .keyDown(let key):
            playFeedback(sound: Self.sound(for: key))
            return
        case .character(let text, _, _): query += text
        case .backspace: if !query.isEmpty { query.removeLast() }
        case .backspaceRepeat:
            if !query.isEmpty { query.removeLast() }
            playFeedback(sound: 1155)
        case .space: query += " "
        case .returnKey, .emoji:
            mode = .emoji
            render()
            return
        case .switchPage, .nextLanguage, .selectLanguage, .shift, .shiftDoubleTap, .moveCursor, .trackpad:
            return
        }
        updateEmojiSearch(query)
    }
}

extension KeyboardViewController: SuggestionBarDelegate {
    func suggestionBar(_ bar: SuggestionBarView, didSelect suggestion: Suggestion) {
        playFeedback(sound: 1104)
        switch suggestion.kind {
        case .card:
            if let id = suggestion.payload.flatMap(UUID.init(uuidString:)) { useCard(id: id) }
        case .action:
            if suggestion.payload == "switch-keyboard" {
                advanceToNextInputMode()
            } else if suggestion.payload == "full-access" {
                fullAccessHintExpanded.toggle()
                render()
            }
        default:
            controller.handle(.suggestion(suggestion))
        }
    }
}

extension KeyboardViewController: EmojiPanelDelegate {
    func emojiPanel(_ panel: EmojiPanelView, didSelect emoji: String) { insertEmoji(emoji) }

    func emojiPanelDidTapBackspace(_ panel: EmojiPanelView) {
        controller.handle(.backspace)
        playFeedback(sound: 1155)
    }

    func emojiPanelDidTapABC(_ panel: EmojiPanelView) {
        mode = .keys
        releaseEmojiSearchData()
        controller.refreshSuggestions()
        render()
    }

    func emojiPanelDidRequestSearch(_ panel: EmojiPanelView) {
        mode = .emojiSearch
        render()
        updateEmojiSearch("")
    }
}

extension KeyboardViewController: EmojiSearchBarDelegate {
    func emojiSearchBar(_ bar: EmojiSearchBarView, didSelect emoji: String) {
        insertEmoji(emoji)
    }

    func emojiSearchBarDidCancel(_ bar: EmojiSearchBarView) {
        mode = .emoji
        render()
    }
}

extension KeyboardViewController: CardUnlockViewDelegate {
    func cardUnlockView(_ view: CardUnlockView, didEnter cvv: String) {
        guard case .cardUnlock(let id) = mode else { return }
        do {
            let unlocked = try CardVault.shared.unlock(id: id, cvv: cvv)
            unlockedCards[id] = (unlocked, Date())
            mode = .keys
            render()
            fill(card: unlocked)
        } catch {
            let message = error.localizedDescription
            view.showError(message)
            if (error as? CardVaultError) == .lockedOut {
                mode = .keys
                render()
                // The unlock view is gone: keep the reason visible in the bar.
                showBarMessage(message)
            }
        }
    }

    func cardUnlockViewDidCancel(_ view: CardUnlockView) {
        mode = .keys
        render()
    }
}
