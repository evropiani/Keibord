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
    /// Invisible view pinned to all edges that carries the keyboard's height as well, so the height also
    /// comes from the content (as with KeyboardKit or Hamster keyboards), not only from the view itself.
    private let heightSizer = UIView()
    private var sizerHeightConstraint: NSLayoutConstraint?
    /// Height of the suggestion bar plus the keys, as computed by `render()`.
    private var requestedHeight: CGFloat = 260
    /// The keyboard has appeared on screen (height requests made before are not always applied).
    private var appeared = false
    /// Height requests repeated in this appearance because the system kept another height.
    private var heightRetries = 0
    /// The container the system touch delays were last relaxed for.
    private weak var touchDelaysDisabledFor: UIView?
    private static let maxHeightRetries = 3

    private enum Mode: Equatable { case keys, emoji, emojiSearch, cardUnlock(UUID) }
    private var mode: Mode = .keys
    /// Page of the key area while typing an emoji search (the document's page stays untouched).
    private var searchPage: LayoutPage = .letters

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
    /// False while user-model.json is being loaded in the background (launch, or after the app changed it).
    private var userModelLoaded = false
    /// Counts background loads, so a failed write can tell whether a load started after it was queued.
    private var userModelLoadGeneration = 0
    /// Learning recorded while loading: applied on top of the loaded model, which does not contain it.
    private var preloadIncrements: [UserModelDelta] = []
    /// A word became "known" since the user lexicon was last built.
    private var userLexiconDirty = false
    private var engineRefreshToken = 0
    private var engineRefreshPending = false
    private var lastSupplementaryRequest: Date?
    /// `hasFullAccess`, read once per appearance (it cannot change while the keyboard is shown).
    private var fullAccess = false
    /// Why what is set in the Keibord app cannot reach this keyboard (checked once per appearance).
    private var linkProblem: AppLinkProblem?
    private var linkHintExpanded = false
    /// The document as of the controller's last update (see `textDidChange`).
    private var documentSnapshot: DocumentSnapshot?
    /// Whether the last render included the globe key (`needsInputModeSwitchKey`).
    private var renderedGlobeKey: Bool?

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
    /// Next-letter prediction for the current word (recomputed when the word or the languages change).
    private var cachedLetterPrior: (key: String, prior: [String: Double])?

    /// Suggestion bar: kept low, iOS already pads the keyboard above it.
    private static let barHeight: CGFloat = 36
    /// Emoji search: query field and result row (shown instead of the suggestion bar).
    private static let searchBarHeight: CGFloat = 88
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

        engine = SuggestionEngine { language in
            guard let url = Bundle.main.url(forResource: language.dictionaryID, withExtension: "kbdl", subdirectory: "Dictionaries") else { return nil }
            return try? BinaryLexicon(url: url)
        }
        engine.setProfile(profile.info)
        engine.setShortcuts(profile.shortcuts)
        loadUserModelInBackground()

        document = ProxyDocument(owner: self)
        let state = store.loadState()
        controller = InputController(document: document, engine: engine, settings: settings, language: state.currentLanguage)
        controller.delegate = self
        controller.learningSink = self

        suggestionBar.delegate = self
        keyboardView.delegate = self
        keyboardView.inputModeTarget = self
        heightSizer.isUserInteractionEnabled = false
        heightSizer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heightSizer)
        NSLayoutConstraint.activate([
            heightSizer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heightSizer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightSizer.topAnchor.constraint(equalTo: view.topAnchor),
            heightSizer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.addSubview(suggestionBar)
        view.addSubview(keyboardView)
        inputView?.allowsSelfSizing = true

        installHeightConstraint()
    }

    /// Asks the system for `requestedHeight` with new height constraints (on the keyboard's view and on
    /// the sizer pinned to its edges): replacing them makes the system measure the keyboard again.
    private func installHeightConstraint() {
        heightConstraint?.isActive = false
        sizerHeightConstraint?.isActive = false
        let h = view.heightAnchor.constraint(equalToConstant: requestedHeight)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h
        let sizer = heightSizer.heightAnchor.constraint(equalToConstant: requestedHeight)
        sizer.priority = UILayoutPriority(999)
        sizer.isActive = true
        sizerHeightConstraint = sizer
        view.setNeedsUpdateConstraints()
        view.setNeedsLayout()
    }

    /// The system laid the keyboard out at another height than requested (it applies requests only
    /// after the keyboard is on screen, and not reliably in every app): ask again a few times, a moment
    /// later, so the keyboard ends up with the same height in every app.
    private func requestHeightAgainIfIgnored() {
        guard appeared, view.bounds.height > 0, abs(view.bounds.height - requestedHeight) > 1,
              heightRetries < Self.maxHeightRetries else { return }
        heightRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(heightRetries)) { [weak self] in
            guard let self = self, self.appeared, abs(self.view.bounds.height - self.requestedHeight) > 1 else { return }
            self.installHeightConstraint()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        fullAccess = hasFullAccess
        heightRetries = 0
        // Before reloading: a settings change renders right away (controller delegate), which must not
        // configure the emoji panel (loading the emoji catalog) the keyboard was dismissed in.
        mode = .keys
        linkHintExpanded = false
        reloadIfChanged()
        linkProblem = currentLinkProblem()
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
        controller.configure(field: FieldContextMapper.context(for: textDocumentProxy))
        if startsOnNumbersPage { controller.handle(.switchPage(.numbers)) }
        writeState()
        render()
        scheduleEngineRefresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disableSystemTouchDelays()
        // A keyboard can only change its height once it has been drawn on screen; a request made
        // before is not always applied (iOS 27 kept the default height, which cut off the bottom row).
        // Ask again now (and again if the system still keeps another height). Should the height still
        // fall short, the rows shrink to fit (KeyboardView).
        appeared = true
        installHeightConstraint()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appeared = false
        // A held backspace must not keep deleting once the keyboard goes away.
        keyboardView.cancelAllTouches()
        if emojiPanelAdded { emojiPanel.stopBackspaceRepeat() }
        cancelEngineRefresh()
        // The main thread never waits for the file here: a write stuck behind another process kept the
        // keyboard from responding, and it opened blank the next time.
        flushLearning()
        finishWritesBeforeSuspension()
        releaseEmojiSearchData()
        purgeExpiredCards()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        layoutCache.removeAll()
        if mode != .emoji, mode != .emojiSearch { releaseEmojiSearchData(force: true) }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // `needsInputModeSwitchKey` can change after viewWillAppear (Apple's template checks it here):
        // add or remove the globe key then, not only at the next keystroke.
        if controller != nil, renderedGlobeKey != nil, renderedGlobeKey != needsInputModeSwitchKey { render() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutChildren()
        requestHeightAgainIfIgnored()
        // The system may move the keyboard into other container views after it appeared.
        if appeared, view.window != nil, touchDelaysDisabledFor !== view.superview { disableSystemTouchDelays() }
    }

    /// System gesture recognizers (screen-edge gestures) delay touchesBegan for keys at the screen edges
    /// (q, a, y, p, ü, ä, shift, backspace…): those taps lagged, came out of order or were lost when
    /// typing fast. They sit on the keyboard's window and, in newer iOS versions, on the container views
    /// around the keyboard, so every one of them is relaxed.
    private func disableSystemTouchDelays() {
        var ancestor = view.superview
        while let v = ancestor {
            v.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
            ancestor = v.superview
        }
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        touchDelaysDisabledFor = view.superview
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
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
        if field != controller.field {
            controller.configure(field: field) // re-syncs the document too
            if startsOnNumbersPage { controller.handle(.switchPage(.numbers)) }
        } else if DocumentSnapshot(textDocumentProxy) != documentSnapshot {
            // Many hosts call textDidChange after each of the keyboard's own edits too: suggestions are
            // only recomputed when the text around the cursor is not what the controller last saw.
            controller.documentDidChange()
        }
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
        if userModelLoaded, store.modificationDate(of: .userModel) != userModelDate {
            // Pending increments go to disk first; the reload, queued after that write, contains them.
            flushLearning()
            loadUserModelInBackground()
        }
    }

    /// Decodes user-model.json and builds the user lexicon on the learning queue. On the main thread
    /// this took a few hundred milliseconds with a big model before the keyboard could first draw.
    private func loadUserModelInBackground() {
        userModelLoaded = false
        userModelLoadGeneration += 1
        preloadIncrements = []
        let store = self.store
        flushQueue.async {
            let date = store.modificationDate(of: .userModel)
            // nil: the file exists but cannot be read right now. Start empty and forget the date, so the
            // next appearance reads it again instead of typing without the learned words until the app
            // changes the file.
            let readable = store.loadUserModelIfReadable()
            let model = readable ?? UserModel()
            let words = model.knownWords()
            let lexicon: InMemoryLexicon? = words.isEmpty ? nil : InMemoryLexicon(languageID: "user", entries: words)
            let loadedDate = readable == nil ? nil : date
            DispatchQueue.main.async { [weak self] in
                self?.didLoadUserModel(model, lexicon: lexicon, date: loadedDate)
            }
        }
    }

    private func didLoadUserModel(_ loaded: UserModel, lexicon: InMemoryLexicon?, date: Date?) {
        var model = loaded
        for increments in preloadIncrements { model.apply(increments) }
        userModel = model
        // Flushes queued after the load report this date as their "before", so they are recognised as ours.
        userModelDate = date
        userModelLoaded = true
        if preloadIncrements.isEmpty {
            engine.setUserModel(userModel)
            engine.setUserLexicon(lexicon)
            userLexiconDirty = false
            engineNeedsUserModel = false
            userModelGeneration += 1 // learned touch offsets
        } else {
            applyUserModelToEngine(rebuildLexicon: true)
        }
        preloadIncrements = []
        controller.refreshSuggestions()
        render()
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
        let before = pendingDelta
        pendingDelta.record(event)
        // Exactly what the pending delta gained (a rejected autocorrection also takes back what its
        // commit learned), so the in-memory model matches what the next flush writes to disk.
        let increments = pendingDelta.increments(since: before)
        guard !increments.isEmpty else { return }
        let threshold = LearningPolicy.knownThreshold
        let wasUnknown = increments.words.keys.filter { (userModel.words[$0]?.count ?? 0) < threshold }
        userModel.apply(increments)
        if !userModelLoaded { preloadIncrements.append(increments) }
        if wasUnknown.contains(where: { (userModel.words[$0]?.count ?? 0) >= threshold }) {
            userLexiconDirty = true
            if case .rejectedCorrection = event {
                // A rejected autocorrection must stop being "corrected" soon, not only after the next
                // 25 events: hand it to the engine at the next typing pause. Other newly known words
                // wait for the next flush (rebuilding the user lexicon costs tens of milliseconds).
                engineNeedsUserModel = true
                scheduleEngineRefresh()
            }
        }
        pendingEvents += 1
    }

    /// Writes the pending learning delta in the background.
    private func flushLearning() {
        guard !pendingDelta.isEmpty else { return }
        let delta = pendingDelta
        pendingDelta = UserModelDelta()
        pendingEvents = 0
        let store = self.store
        let generation = userModelLoadGeneration
        flushQueue.async {
            let result = writeLearning(delta, to: store)
            DispatchQueue.main.async { [weak self] in self?.didFlush(result, delta: delta, loadGeneration: generation) }
        }
        engineNeedsUserModel = true
        scheduleEngineRefresh()
    }

    /// iOS suspends a hidden keyboard soon: ask for the time to finish the queued writes (on a
    /// background thread, so the keyboard stays responsive).
    private func finishWritesBeforeSuspension() {
        let queue = flushQueue
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Keibord saves what it learned") { expired in
            if !expired { queue.sync {} }
        }
    }

    /// Waits until the queued writes and loads are done (tests).
    func waitForPendingWrites() {
        flushQueue.sync {}
    }

    private func didFlush(_ result: LearningWrite, delta: UserModelDelta, loadGeneration: Int) {
        guard result.written else {
            // Nothing reached the disk (file unreadable right now, no access): keep the increments for the
            // next flush instead of dropping them. The in-memory model already has them, unless a load
            // queued after this write replaces it: that load cannot contain them, so they go on top.
            pendingDelta.merge(delta)
            if !userModelLoaded, loadGeneration != userModelLoadGeneration { preloadIncrements.insert(delta, at: 0) }
            return
        }
        // Our own write: remember its date so the next appearance does not decode the file again. If the
        // app had changed the file in between, keep the old date so that change is loaded next time.
        if result.before == userModelDate { userModelDate = result.after }
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
            // While loading, the loaded model goes to the engine anyway (didLoadUserModel).
            guard self.engineNeedsUserModel, self.userModelLoaded else { return }
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
            // An app may ask for a light or a dark keyboard; otherwise the iPhone's appearance decides. The
            // keyboard's own trait collection is only a fallback: it could stay dark in light mode.
            switch textDocumentProxy.keyboardAppearance ?? .default {
            case .dark: return true
            case .light: return false
            default:
                let system = UIScreen.main.traitCollection.userInterfaceStyle
                return system == .unspecified ? traitCollection.userInterfaceStyle == .dark : system == .dark
            }
        }
    }

    /// The system draws the keyboard's backdrop in its own light/dark style (the keyboard's trait
    /// collection), whatever the theme is. When they differ (Light or Dark chosen in the app, or the
    /// system's style is off), Keibord draws its own backdrop, so keys never sit on the wrong background
    /// (white keys on black).
    private func backgroundColor(for theme: KeyboardTheme) -> UIColor {
        let systemBackdropDark = traitCollection.userInterfaceStyle == .dark
        return theme.isDark == systemBackdropDark ? theme.backgroundColor : theme.backdropColor
    }

    private var isLandscape: Bool { traitCollection.verticalSizeClass == .compact }

    /// Fields for numbers and punctuation (house numbers, times, IP addresses) open on the "123" page,
    /// as with the system keyboard.
    private var startsOnNumbersPage: Bool { (textDocumentProxy.keyboardType ?? .default) == .numbersAndPunctuation }

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

    /// Smart touch zones: the likely next letters get larger invisible hit zones (letters page, prose
    /// fields only; never in URL, e-mail or password fields).
    private func letterPrior(for page: LayoutPage) -> [String: Double] {
        guard settings.predictiveTouch, mode == .keys, page == .letters, controller.field.autocorrectAllowed else { return [:] }
        let word = controller.currentWord
        let languages = controller.languages
        let key = word + "\u{1}" + languages.map(\.rawValue).joined(separator: ",") + "\u{1}\(userModelGeneration)"
        if let cached = cachedLetterPrior, cached.key == key { return cached.prior }
        let prior = engine.nextLetterLog2Probabilities(after: word, languages: languages)
        cachedLetterPrior = (key: key, prior: prior)
        return prior
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
        view.backgroundColor = backgroundColor(for: theme) // never fully clear: see `UIColor.touchableClear`
        let baseMetrics = KeyboardMetrics.standard(height: settings.appearance.keyHeight, landscape: isLandscape)
        let field = controller.field
        let searching = mode == .emojiSearch
        let numberRow = settings.appearance.showNumberRow && !searching
        let globeKey = needsInputModeSwitchKey
        renderedGlobeKey = globeKey
        // The emoji panel and the CVV pad take the height of the letter keys they replace.
        let request = LayoutRequest(
            language: controller.language,
            base: settings.baseLayout(for: controller.language),
            page: searching ? searchPage : controller.page,
            variant: searching ? .standard : field.layoutVariant,
            showNumberRow: numberRow && controller.page == .letters,
            showLanguageKey: settings.activeLanguages.count > 1 && !searching,
            showGlobeKey: globeKey,
            // While searching, return only closes the search: a plain return key, never "Send".
            returnKind: searching ? .default : field.returnKind
        )
        let layout = self.layout(for: request)
        let isPad = request.variant == .numberPad || request.variant == .decimalPad
        let rows = max(layout.rows.count, isPad ? 4 : (numberRow ? 5 : 4))
        let keysHeight = baseMetrics.keyboardHeight(rows: rows)
        let total = (searching ? Self.searchBarHeight : Self.barHeight) + keysHeight
        requestedHeight = total
        if heightConstraint?.constant != total { heightConstraint?.constant = total }
        if sizerHeightConstraint?.constant != total { sizerHeightConstraint?.constant = total }

        if mode == .keys || searching {
            let offsets = touchOffsets(for: layout)
            let multiple = settings.activeLanguages.count > 1
            let spaceLabel = settings.appearance.showSpaceLanguageLabel && multiple ? controller.language.displayName : controller.language.spaceKeyLabel
            // The return key is dimmed (and inactive) only when both the field and the context agree it is empty.
            let empty = !textDocumentProxy.hasText && (textDocumentProxy.documentContextBeforeInput ?? "").isEmpty
                && (textDocumentProxy.documentContextAfterInput ?? "").isEmpty
            keyboardView.languages = settings.activeLanguages
            // While searching emoji, keys type into the query: no trackpad, and letters arrive lower-case.
            keyboardView.spacebarCursor = settings.spacebarCursor && !searching
            keyboardView.letterPrior = letterPrior(for: request.page)
            keyboardView.configure(layout: layout, metrics: Self.metrics(baseMetrics, rows: layout.rows.count, filling: rows),
                                   theme: theme, shiftState: searching ? .off : controller.shiftState,
                                   spaceLabel: spaceLabel, returnEnabled: searching || !(field.enablesReturnKeyAutomatically && empty),
                                   returnProminent: request.returnKind.isProminent,
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
        // In landscape on Face ID iPhones the keys stay clear of the rounded corners and the sensor
        // housing, like the system keyboard (the margins show the keyboard background).
        let insets = view.safeAreaInsets
        let b = CGRect(x: insets.left, y: 0, width: max(0, view.bounds.width - insets.left - insets.right), height: view.bounds.height)
        switch mode {
        case .keys:
            suggestionBar.frame = CGRect(x: b.minX, y: 0, width: b.width, height: Self.barHeight)
            keyboardView.frame = CGRect(x: b.minX, y: Self.barHeight, width: b.width, height: max(0, b.height - Self.barHeight))
        case .emojiSearch:
            if emojiSearchBarAdded { emojiSearchBar.frame = CGRect(x: b.minX, y: 0, width: b.width, height: Self.searchBarHeight) }
            keyboardView.frame = CGRect(x: b.minX, y: Self.searchBarHeight, width: b.width, height: max(0, b.height - Self.searchBarHeight))
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
        // What is set in the app does not reach the keyboard: said in every empty field (instead of the
        // first-word predictions, which hid the hint before) and whenever there is nothing to suggest.
        if let problem = linkProblem, controller.currentWord.isEmpty, controller.suggestions.isEmpty || documentIsEmpty {
            return [Suggestion(text: "", display: linkHintExpanded ? Self.linkInstructions(problem, controller.language.languageCode)
                                                                   : Self.linkHint(problem, controller.language.languageCode),
                               kind: .action, appendsSpace: false, payload: "full-access")]
        }
        return controller.suggestions
    }

    private var documentIsEmpty: Bool {
        (textDocumentProxy.documentContextBeforeInput ?? "").isEmpty && (textDocumentProxy.documentContextAfterInput ?? "").isEmpty
    }

    /// Why the settings, details and learning of the Keibord app cannot reach this keyboard.
    enum AppLinkProblem: Equatable {
        /// Without Full Access iOS gives a keyboard no access to the container it shares with its app.
        case fullAccess
        /// Full Access is on, but the installer gave the keyboard no app group.
        case noAppGroup
        /// The shared folder has no settings from the app: the app was never opened, or the installer gave
        /// the app and the keyboard different app groups.
        case appDataMissing
    }

    private func currentLinkProblem() -> AppLinkProblem? {
        if !fullAccess { return .fullAccess }
        if !store.isShared { return .noAppGroup }
        if !store.exists(.settings) { return .appDataMissing }
        return nil
    }

    static func linkHint(_ problem: AppLinkProblem, _ language: String) -> String {
        switch (problem, language) {
        case (.fullAccess, "de"): return "Vollen Zugriff erlauben, damit deine Einstellungen gelten"
        case (.fullAccess, "sq"): return "Lejo qasjen e plotë që të vlejnë cilësimet e tua"
        case (.fullAccess, "it"): return "Consenti l'accesso completo per usare le tue impostazioni"
        case (.fullAccess, _): return "Allow Full Access to use your settings"
        case (.noAppGroup, "de"): return "Keine Verbindung zur Keibord-App (App-Gruppe fehlt)"
        case (.noAppGroup, "sq"): return "Pa lidhje me aplikacionin Keibord (mungon grupi)"
        case (.noAppGroup, "it"): return "Nessun collegamento all'app Keibord (manca l'App Group)"
        case (.noAppGroup, _): return "No link to the Keibord app (app group missing)"
        case (.appDataMissing, "de"): return "Keibord-App einmal öffnen, damit deine Einstellungen gelten"
        case (.appDataMissing, "sq"): return "Hap aplikacionin Keibord një herë për cilësimet"
        case (.appDataMissing, "it"): return "Apri l'app Keibord una volta per le tue impostazioni"
        case (.appDataMissing, _): return "Open the Keibord app once to use your settings"
        }
    }

    /// Shown when the hint is tapped (a keyboard extension cannot open Settings itself).
    static func linkInstructions(_ problem: AppLinkProblem, _ language: String) -> String {
        switch (problem, language) {
        case (.fullAccess, "de"): return "Einstellungen › Keibord › Tastaturen › Voller Zugriff"
        case (.fullAccess, "sq"): return "Cilësimet › Keibord › Tastierat › Qasje e plotë"
        case (.fullAccess, "it"): return "Impostazioni › Keibord › Tastiere › Accesso completo"
        case (.fullAccess, _): return "Settings › Keibord › Keyboards › Allow Full Access"
        case (.noAppGroup, "de"), (.appDataMissing, "de"):
            return "Bleibt das so: neu installieren, sodass App und Tastatur eine App-Gruppe teilen"
        case (.noAppGroup, "sq"), (.appDataMissing, "sq"):
            return "Nëse mbetet: instalo përsëri që aplikacioni dhe tastiera të ndajnë një grup"
        case (.noAppGroup, "it"), (.appDataMissing, "it"):
            return "Se resta così: reinstalla in modo che app e tastiera condividano un App Group"
        case (.noAppGroup, _), (.appDataMissing, _):
            return "Still there? Reinstall so the app and keyboard share an app group"
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
        emojiPanel.configure(catalog: loadCatalog(), recents: emojiRecents, used: sessionEmoji + userModel.emojiByLastUse,
                             theme: theme, languageCode: controller.language.languageCode)
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

    private func rememberUnlocked(_ unlocked: UnlockedCard, id: UUID) {
        unlockedCards[id] = (unlocked, Date())
        // Purge on time even if the keyboard just stays open (not only at the next card use/appearance).
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unlockLifetime + 1) { [weak self] in
            self?.purgeExpiredCards()
        }
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
            rememberUnlocked(unlocked, id: id)
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

/// Outcome of one learning write: user-model.json's modification dates around it, and whether it was written.
private struct LearningWrite {
    var before: Date?
    var after: Date?
    var written: Bool
}

/// Applies a learning delta to user-model.json (runs on the flush queue).
private func writeLearning(_ delta: UserModelDelta, to store: KeibordStore) -> LearningWrite {
    let before = store.modificationDate(of: .userModel)
    let written = store.flush(delta)
    return LearningWrite(before: before, after: store.modificationDate(of: .userModel), written: written)
}

// MARK: - Delegates

extension KeyboardViewController: InputControllerDelegate {
    func controllerStateDidChange(_ controller: InputController) {
        documentSnapshot = DocumentSnapshot(textDocumentProxy)
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
        if pendingEvents >= 25 {
            // A backspace right after an autocorrected commit takes back what it learned, which only the
            // delta that recorded the commit can do: flush with the next event instead.
            if case .committedWord(_, _, _, _, _, true) = event { return }
            flushLearning()
        }
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
        case .shift:
            controller.handle(.shift)
            controller.setShiftHeld(true)
        case .shiftDoubleTap:
            controller.handle(.shiftDoubleTap)
            controller.setShiftHeld(true)
        case .shiftReleased: controller.setShiftHeld(false)
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
        case .space:
            query += " "
            if searchPage != .letters {
                searchPage = .letters // like the system keyboard: back to letters after a space
                render()
            }
        case .switchPage(let page):
            // "123" / "#+=" / "ABC" work in the query too (searching "100" finds 💯).
            searchPage = page
            render()
            return
        case .returnKey, .emoji:
            mode = .emoji
            render()
            return
        case .nextLanguage, .selectLanguage, .shift, .shiftDoubleTap, .shiftReleased, .moveCursor, .trackpad:
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
                linkHintExpanded.toggle()
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
        searchPage = .letters
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
            rememberUnlocked(unlocked, id: id)
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
