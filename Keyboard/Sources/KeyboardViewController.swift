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
    private lazy var emojiPanel = EmojiPanelView()
    private lazy var emojiSearchBar = EmojiSearchBarView()
    private lazy var cardUnlockView = CardUnlockView()
    private var heightConstraint: NSLayoutConstraint?

    private enum Mode: Equatable { case keys, emoji, emojiSearch, cardUnlock(UUID) }
    private var mode: Mode = .keys

    private var pendingDelta = UserModelDelta()
    private var pendingEvents = 0
    private var settingsDate: Date?
    private var profileDate: Date?
    private var emojiCatalog: EmojiCatalog?
    private var emojiCatalogLoaded = false
    private var sessionEmoji: [String] = []
    private var cards: [StoredCard] = []
    private var unlockedCards: [UUID: (UnlockedCard, Date)] = [:]
    private var feedback: UIImpactFeedbackGenerator?
    private var lastLayoutRequest: LayoutRequest?

    private static let barHeight: CGFloat = 44

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = store.loadSettings()
        settingsDate = store.modificationDate(of: .settings)
        profile = store.loadProfile()
        profileDate = store.modificationDate(of: .profile)
        userModel = store.loadUserModel()

        engine = SuggestionEngine { language in
            guard let url = Bundle.main.url(forResource: language.dictionaryID, withExtension: "kbdl", subdirectory: "Dictionaries") else { return nil }
            return try? BinaryLexicon(url: url)
        }
        applyUserData()

        document = ProxyDocument(owner: self)
        let state = store.loadState()
        controller = InputController(document: document, engine: engine, settings: settings, language: state.currentLanguage)
        controller.delegate = self
        controller.learningSink = self

        suggestionBar.delegate = self
        keyboardView.delegate = self
        view.addSubview(suggestionBar)
        view.addSubview(keyboardView)

        let h = view.heightAnchor.constraint(equalToConstant: 260)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadIfChanged()
        cards = settings.cardSuggestions ? CardVault.shared.cards() : []
        if hasFullAccess, settings.haptics != .off {
            let style: UIImpactFeedbackGenerator.FeedbackStyle = settings.haptics == .strong ? .heavy : (settings.haptics == .medium ? .medium : .light)
            feedback = UIImpactFeedbackGenerator(style: style)
            feedback?.prepare()
        } else {
            feedback = nil
        }
        requestSupplementaryLexicon { [weak self] lexicon in
            let entries = lexicon.entries.map { (input: $0.userInput, text: $0.documentText) }
            DispatchQueue.main.async { self?.engine.setSupplementaryLexicon(entries) }
        }
        mode = .keys
        controller.configure(field: FieldContextMapper.context(for: textDocumentProxy))
        writeState()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushLearning()
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

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
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
            controller?.settings = settings
        }
        let pDate = store.modificationDate(of: .profile)
        if pDate != profileDate {
            profileDate = pDate
            profile = store.loadProfile()
            userModel = store.loadUserModel()
            applyUserData()
        } else if pendingEvents == 0 {
            // The app may have edited learned words.
            userModel = store.loadUserModel()
            applyUserData()
        }
    }

    private func applyUserData() {
        engine.setProfile(profile.info)
        engine.setShortcuts(profile.shortcuts)
        engine.setUserModel(userModel)
        let words = userModel.knownWords()
        engine.setUserLexicon(words.isEmpty ? nil : InMemoryLexicon(languageID: "user", entries: words))
    }

    private func flushLearning() {
        guard !pendingDelta.isEmpty else { return }
        store.flush(pendingDelta)
        pendingDelta = UserModelDelta()
        pendingEvents = 0
        let words = userModel.knownWords()
        engine.setUserLexicon(words.isEmpty ? nil : InMemoryLexicon(languageID: "user", entries: words))
        engine.setUserModel(userModel)
    }

    private func writeState() {
        let state = KeyboardRuntimeState(currentLanguage: controller.language, lastActive: Date(), hasFullAccess: hasFullAccess,
                                         keyboardVersion: KeibordVersion.display, appGroupIdentifier: AppGroup.resolvedIdentifier)
        store.saveState(state)
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

    private func render() {
        guard controller != nil else { return }
        let theme = KeyboardTheme(settings: settings, dark: isDark)
        view.backgroundColor = theme.backgroundColor
        let metrics = KeyboardMetrics.standard(height: settings.appearance.keyHeight, landscape: isLandscape)
        let field = controller.field
        let request = LayoutRequest(
            language: controller.language,
            base: settings.baseLayout(for: controller.language),
            page: mode == .emojiSearch ? .letters : controller.page,
            variant: mode == .emojiSearch ? .standard : field.layoutVariant,
            showNumberRow: settings.appearance.showNumberRow && controller.page == .letters && mode == .keys,
            showLanguageKey: settings.activeLanguages.count > 1 && mode == .keys,
            showGlobeKey: needsInputModeSwitchKey,
            returnKind: field.returnKind
        )
        let layout = LayoutFactory.layout(for: request)
        let offsets = settings.adaptiveTouch ? userModel.touchOffsets(for: layout.touchModelKey) : [:]
        let multiple = settings.activeLanguages.count > 1
        let spaceLabel = settings.appearance.showSpaceLanguageLabel && multiple ? controller.language.displayName : controller.language.spaceKeyLabel
        let empty = (textDocumentProxy.documentContextBeforeInput ?? "").isEmpty && (textDocumentProxy.documentContextAfterInput ?? "").isEmpty
        keyboardView.languages = settings.activeLanguages
        keyboardView.spacebarCursor = settings.spacebarCursor
        keyboardView.configure(layout: layout, metrics: metrics, theme: theme, shiftState: controller.shiftState,
                               spaceLabel: spaceLabel, returnEnabled: !(field.enablesReturnKeyAutomatically && empty),
                               returnProminent: field.returnKind.isProminent, touchOffsets: offsets)
        lastLayoutRequest = request

        let keysHeight = metrics.keyboardHeight(rows: max(layout.rows.count, 4))
        var total = Self.barHeight + keysHeight
        if mode == .emojiSearch { total += 44 }
        if heightConstraint?.constant != total { heightConstraint?.constant = total }

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
            emojiSearchBar.frame = CGRect(x: 0, y: 0, width: b.width, height: 88)
            keyboardView.frame = CGRect(x: 0, y: 88, width: b.width, height: max(0, b.height - 88))
        case .emoji:
            emojiPanel.frame = b
        case .cardUnlock:
            cardUnlockView.frame = b
        }
    }

    private func updateVisibility() {
        suggestionBar.isHidden = mode != .keys
        keyboardView.isHidden = !(mode == .keys || mode == .emojiSearch)
        if mode == .emoji, emojiPanel.superview == nil { view.addSubview(emojiPanel); emojiPanel.delegate = self }
        if mode == .emojiSearch, emojiSearchBar.superview == nil { view.addSubview(emojiSearchBar); emojiSearchBar.delegate = self }
        if case .cardUnlock = mode, cardUnlockView.superview == nil { view.addSubview(cardUnlockView); cardUnlockView.delegate = self }
        if emojiPanel.superview != nil { emojiPanel.isHidden = mode != .emoji }
        if emojiSearchBar.superview != nil { emojiSearchBar.isHidden = mode != .emojiSearch }
        if cardUnlockView.superview != nil {
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
        if !hasFullAccess, controller.suggestions.isEmpty, controller.currentWord.isEmpty {
            return [Suggestion(text: "", display: "Allow Full Access for learning & settings", kind: .action, appendsSpace: false, payload: "full-access")]
        }
        return controller.suggestions
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
        pendingDelta.record(.usedEmoji(emoji))
        var single = UserModelDelta()
        single.record(.usedEmoji(emoji))
        userModel.apply(single)
        pendingEvents += 1
        playFeedback(sound: 1104)
    }

    private func updateEmojiSearch(_ query: String) {
        let codes = Array(Set(settings.activeLanguages.map { $0.emojiKeywordCode } + ["en"]))
        let results = query.isEmpty ? emojiRecents : (loadCatalog()?.search(query, languageCodes: codes, limit: 40) ?? [])
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

    private func useCard(id: UUID) {
        if let cached = unlockedCards[id], Date().timeIntervalSince(cached.1) < 180 {
            fill(card: cached.0)
            return
        }
        guard let card = cards.first(where: { $0.id == id }) else { return }
        if card.requiresCVV {
            mode = .cardUnlock(id)
            updateVisibility()
            cardUnlockView.configure(title: cvvTitle(card), cvvLength: card.brand.cvvLength, theme: KeyboardTheme(settings: settings, dark: isDark))
            layoutChildren()
            return
        }
        do {
            let unlocked = try CardVault.shared.unlock(id: id, cvv: nil)
            unlockedCards[id] = (unlocked, Date())
            fill(card: unlocked)
        } catch {
            suggestionBar.update([Suggestion(text: "", display: error.localizedDescription, kind: .action, appendsSpace: false)], theme: KeyboardTheme(settings: settings, dark: isDark))
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
        guard hasFullAccess else { return }
        feedback?.impactOccurred()
        if settings.keySound { AudioServicesPlaySystemSound(sound) }
    }
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
        pendingDelta.record(event)
        var single = UserModelDelta()
        single.record(event)
        userModel.apply(single)
        pendingEvents += 1
        if pendingEvents >= 25 { flushLearning() }
    }
}

extension KeyboardViewController: KeyboardViewDelegate {
    func keyboardView(_ view: KeyboardView, didTrigger event: KeyboardViewEvent) {
        if mode == .emojiSearch {
            handleSearchKey(event)
            return
        }
        switch event {
        case .keyDown(let key):
            let sound: SystemSoundID = key.action == .backspace ? 1155 : (key.style == .character || key.style == .space ? 1104 : 1156)
            playFeedback(sound: sound)
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
        case .keyDown:
            playFeedback(sound: 1104)
            return
        case .character(let text, _, _): query += text
        case .backspace, .backspaceRepeat: if !query.isEmpty { query.removeLast() }
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
            if suggestion.payload == "switch-keyboard" { advanceToNextInputMode() }
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
            view.showError(error.localizedDescription)
            if (error as? CardVaultError) == .lockedOut {
                mode = .keys
                render()
            }
        }
    }

    func cardUnlockViewDidCancel(_ view: CardUnlockView) {
        mode = .keys
        render()
    }
}
