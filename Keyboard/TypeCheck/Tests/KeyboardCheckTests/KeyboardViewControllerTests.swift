import XCTest
import UIKit
import KeibordCore
@testable import KeyboardCheck

/// An in-memory text field as the keyboard sees it through `UITextDocumentProxy`.
final class TestProxy: UITextDocumentProxy {
    var text = ""
    var cursor = 0
    /// False until iOS connects the text field: the real proxy then has no document, and reading
    /// `documentIdentifier` (a non-optional UUID in Swift) crashes the keyboard.
    var connected = true
    private(set) var identifierReadWhileDisconnected = false
    private var identifier = UUID()
    var documentIdentifier: UUID {
        get {
            if !connected { identifierReadWhileDisconnected = true }
            return identifier
        }
        set { identifier = newValue }
    }
    var keyboardType: UIKeyboardType? = .default
    var keyboardAppearance: UIKeyboardAppearance? = .default
    var returnKeyType: UIReturnKeyType? = .default
    var autocapitalizationType: UITextAutocapitalizationType? = .sentences
    var autocorrectionType: UITextAutocorrectionType? = .default
    var smartQuotesType: UITextSmartQuotesType? = .default
    var enablesReturnKeyAutomatically: Bool? = false
    var isSecureTextEntry: Bool? = false
    var textContentType: UITextContentType?? = nil

    var documentContextBeforeInput: String? { String(text.prefix(cursor)) }
    var documentContextAfterInput: String? { String(text.dropFirst(cursor)) }
    var selectedText: String? { nil }
    var hasText: Bool { !text.isEmpty }

    func insertText(_ s: String) {
        text.insert(contentsOf: s, at: text.index(text.startIndex, offsetBy: cursor))
        cursor += s.count
    }

    func deleteBackward() {
        guard cursor > 0 else { return }
        text.remove(at: text.index(text.startIndex, offsetBy: cursor - 1))
        cursor -= 1
    }

    func adjustTextPosition(byCharacterOffset offset: Int) { cursor = min(max(cursor + offset, 0), text.count) }

    /// The app replaces the text (e.g. clears the field after sending).
    func replaceAll(with s: String) {
        text = s
        cursor = s.count
    }
}

final class KeyboardViewControllerTests: XCTestCase {
    private var vc: KeyboardViewController!
    private var proxy: TestProxy!

    override func setUp() {
        super.setUp()
        KeibordStore.shared.saveSettings(KeibordSettings())
        KeibordStore.shared.saveUserModel(UserModel())
        CardVault.shared.testCards = []
        UIScreen.main.testUserInterfaceStyle = .light
    }

    private func start(settings: KeibordSettings? = nil, fullAccess: Bool = false, systemBackdrop: UIUserInterfaceStyle = .light,
                       family: KeyboardLanguageFamily? = nil, configure: (TestProxy) -> Void = { _ in }) {
        if let settings = settings { KeibordStore.shared.saveSettings(settings) }
        proxy = TestProxy()
        configure(proxy)
        vc = KeyboardViewController()
        vc.languageFamily = family
        vc.testProxy = proxy
        vc.testHasFullAccess = fullAccess
        vc.testTraitCollection = UITraitCollection(testStyle: systemBackdrop)
        vc.viewDidLoad()
        vc.viewWillAppear(false)
        vc.viewDidLayoutSubviews()
        vc.viewDidAppear(false)
    }

    private var keyboard: KeyboardView { vc.view.subviews.compactMap { $0 as? KeyboardView }.first! }
    private func subview<T: UIView>(_ type: T.Type) -> T? { vc.view.subviews.compactMap { $0 as? T }.first }
    private var height: CGFloat { vc.view.heightAnchor.testConstraints.last?.constant ?? 0 }
    /// The key view of `id` after a layout pass (UIKit runs one before the next frame).
    private func keyView(_ id: String) -> KeyView? {
        vc.viewDidLayoutSubviews()
        keyboard.layoutIfNeeded()
        return keyboard.subviews.compactMap { $0 as? KeyView }.first { $0.key.id == id }
    }

    private func send(_ event: KeyboardViewEvent) { vc.keyboardView(keyboard, didTrigger: event) }
    private func type(_ text: String) {
        for c in text {
            if c == " " { send(.space) } else { send(.character(text: String(c), tap: nil, isLetter: c.isLetter)) }
        }
    }
    private func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    /// A write by the app, seconds after the keyboard's own (file times are coarse on Linux: two writes
    /// within a few milliseconds can share one modification date, which made tests flaky).
    private func markChangedByTheApp(_ file: KeibordFile) {
        let later = Date().addingTimeInterval(2)
        try? FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: KeibordStore.shared.url(file).path)
    }

    // MARK: Typing

    /// iOS gives a keyboard extension no touches where it drew nothing: with clear backgrounds the gaps
    /// between keys and the suggestion bar around its words did not react.
    func testEveryTouchSurfaceIsDrawnSoTouchesBetweenKeysArrive() {
        start()
        XCTAssertTrue(vc.view.backgroundColor === UIColor.touchableClear)
        XCTAssertTrue(keyboard.backgroundColor === UIColor.touchableClear)
        XCTAssertTrue(subview(SuggestionBarView.self)?.backgroundColor === UIColor.touchableClear)
        send(.emoji)
        XCTAssertTrue(subview(EmojiPanelView.self)?.backgroundColor === UIColor.touchableClear)
    }

    // MARK: Light and dark

    func testAutomaticFollowsTheIPhoneEvenWhenTheKeyboardIsReportedDark() {
        UIScreen.main.testUserInterfaceStyle = .light
        start(systemBackdrop: .dark) // iOS reports (and draws) a dark keyboard in light mode
        XCTAssertTrue(vc.view.backgroundColor === KeyboardTheme.lightBackdrop, "light keys on Keibord's own light backdrop")
        UIScreen.main.testUserInterfaceStyle = .dark
        vc.viewWillDisappear(false)
        vc.viewWillAppear(false)
        XCTAssertTrue(vc.view.backgroundColor === UIColor.touchableClear, "dark keys on the system's dark backdrop")
    }

    func testAnAppAskingForADarkKeyboardGetsOne() {
        start(systemBackdrop: .light) { $0.keyboardAppearance = .dark }
        XCTAssertTrue(vc.view.backgroundColor === KeyboardTheme.darkBackdrop)
    }

    func testChosenLightThemeNeverSitsOnTheDarkSystemBackdrop() {
        var s = KeibordSettings()
        s.appearance.themeMode = .light
        start(settings: s, systemBackdrop: .dark)
        XCTAssertTrue(vc.view.backgroundColor === KeyboardTheme.lightBackdrop, "white keys used to sit on black")
        s.appearance.themeMode = .dark
        KeibordStore.shared.saveSettings(s)
        markChangedByTheApp(.settings)
        vc.viewWillDisappear(false)
        vc.viewWillAppear(false)
        XCTAssertTrue(vc.view.backgroundColor === UIColor.touchableClear, "dark theme on the dark backdrop: the system's glass")
    }

    /// The height as iOS 27 gives it: a self-sizing input view with the full height on the view and on a
    /// sizer pinned to its edges while the keyboard loads. Not asked for again once it is on screen.
    func testTheHeightIsRequestedWhileLoadingOnly() {
        var settings = KeibordSettings()
        settings.appearance.showNumberRow = true
        KeibordStore.shared.saveSettings(settings)
        proxy = TestProxy()
        vc = KeyboardViewController()
        vc.testProxy = proxy
        vc.testTraitCollection = UITraitCollection(testStyle: .light)
        vc.inputView = UIInputView()
        vc.viewDidLoad()
        let full = 36 + KeyboardMetrics.standard(height: .standard, landscape: false).keyboardHeight(rows: 5)
        XCTAssertEqual(vc.inputView?.allowsSelfSizing, true, "1.0.14–1.0.17 left this off and got 241 or 224 pt")
        let first = vc.view.heightAnchor.testConstraints.last
        XCTAssertEqual(first?.constant, full, "the full height while loading")
        XCTAssertEqual(first?.isActive, true)
        XCTAssertNotNil(keyView("a"), "keys before the keyboard appears")
        vc.viewWillAppear(false)
        vc.viewDidAppear(false)
        wait(0.6)
        XCTAssertTrue(vc.view.heightAnchor.testConstraints.last === first, "no new request once on screen")
        XCTAssertEqual(first?.isActive, true)
        XCTAssertEqual(first?.constant, full)
        vc.viewWillDisappear(false)
    }

    /// Every page, field and mode keeps the height the keyboard opened with, so it never changes height
    /// on screen.
    func testTheHeightNeverChangesWhileOnScreen() {
        for numberRow in [true, false] {
            var settings = KeibordSettings()
            settings.appearance.showNumberRow = numberRow
            start(settings: settings)
            let constraints = vc.view.heightAnchor.testConstraints.count
            let full = height
            XCTAssertEqual(full, 36 + KeyboardMetrics.standard(height: .standard, landscape: false).keyboardHeight(rows: numberRow ? 5 : 4))
            func check(_ step: String) {
                XCTAssertEqual(height, full, "\(step) (number row \(numberRow))")
                XCTAssertEqual(vc.view.heightAnchor.testConstraints.count, constraints, "\(step): no new request")
            }
            send(.switchPage(.numbers)); check("numbers")
            send(.switchPage(.symbols)); check("symbols")
            send(.switchPage(.letters)); check("letters")
            proxy.keyboardType = .numberPad
            vc.textDidChange(nil); check("number pad field")
            proxy.keyboardType = .default
            vc.textDidChange(nil); check("text field again")
            send(.emoji); check("emoji panel")
            let panel = subview(EmojiPanelView.self)!
            vc.emojiPanelDidRequestSearch(panel); check("emoji search")
            vc.viewDidLayoutSubviews()
            XCTAssertLessThanOrEqual(keyboard.frame.maxY, vc.view.bounds.height + 0.5, "the keys fit below the query bar")
            vc.emojiSearchBarDidCancel(subview(EmojiSearchBarView.self)!); check("search cancelled")
            vc.emojiPanelDidTapABC(panel); check("back to the keys")
            vc.viewWillDisappear(false)
        }
    }

    func testKeysStayInsideTheSafeAreaInLandscape() {
        start()
        vc.view.frame = CGRect(x: 0, y: 0, width: 844, height: vc.view.bounds.height)
        vc.view.safeAreaInsets = UIEdgeInsets(top: 0, left: 47, bottom: 0, right: 47)
        vc.viewSafeAreaInsetsDidChange()
        vc.viewDidLayoutSubviews()
        XCTAssertEqual(keyboard.frame.minX, 47)
        XCTAssertEqual(keyboard.frame.width, 750)
        XCTAssertEqual(subview(SuggestionBarView.self)?.frame.minX, 47)
    }

    /// iOS shows its 17 pt glass strip above the keyboard in some places and not in others: the words sit
    /// between the place centred with it (14.5 pt, 1.0.8–1.0.20) and the one centred without it (23 pt).
    func testTheSuggestionWordsSitBetweenThePlacesForWithAndWithoutIOSsStrip() {
        start()
        vc.viewDidLayoutSubviews()
        let bar = subview(SuggestionBarView.self)
        XCTAssertEqual(bar?.frame.height, 36)
        XCTAssertEqual(keyboard.frame.minY, 36)
        bar?.layoutIfNeeded()
        let words = bar?.subviews.compactMap { $0 as? UIButton } ?? []
        XCTAssertFalse(words.isEmpty)
        for word in words {
            XCTAssertEqual(word.frame.midY, 20.5, accuracy: 0.01, "6 pt lower than 1.0.20: never against the top edge without the strip")
        }
    }

    func testKeysTypeIntoTheDocumentWithAutoCapitalisation() {
        start()
        type("hallo du")
        XCTAssertEqual(proxy.text, "Hallo du")
        XCTAssertEqual(keyView("a")?.label.text, "a")
    }

    func testHoldingShiftTypesCapitalsUntilReleased() {
        start()
        type("ich bin ")
        send(.shift)
        type("orf")
        send(.shiftReleased)
        type("x")
        XCTAssertEqual(proxy.text, "Ich bin ORFx")
    }

    func testTypingDoesNotRebuildKeyViews() {
        start()
        let a = keyView("a"), space = keyView("space")
        XCTAssertNotNil(a)
        type("hallo du ")
        send(.shift)
        send(.shiftReleased)
        send(.backspace)
        XCTAssertTrue(keyView("a") === a, "letters, shift and backspace keep the key views")
        XCTAssertTrue(keyView("space") === space)
        send(.switchPage(.numbers))
        XCTAssertNil(keyView("a"))
        send(.switchPage(.letters))
        XCTAssertFalse(keyView("a") === a, "a page change builds the keys anew")
    }

    func testSettingsChangedByTheAppApplyOnTheNextAppearance() {
        start()
        XCTAssertEqual(keyboard.layout?.rows.count, 4)
        vc.viewWillDisappear(false)
        var settings = KeibordSettings()
        settings.appearance.showNumberRow = true
        settings.enabledLanguages = [.enGB]
        KeibordStore.shared.saveSettings(settings)
        markChangedByTheApp(.settings)
        vc.viewWillAppear(false)
        XCTAssertEqual(keyboard.layout?.rows.count, 5)
        XCTAssertEqual(keyboard.layout?.language, .enGB, "a language that is no longer enabled is left")
        XCTAssertNil(keyView("language"), "no language key with one language")
    }

    func testRolloverThroughTheControllerReturnsToLettersBeforeTheNextKey() {
        start()
        send(.switchPage(.numbers))
        XCTAssertEqual(keyboard.layout?.page, .numbers)
        let metrics = KeyboardMetrics.standard(height: .standard, landscape: false)
        func centre(_ id: String) -> CGPoint {
            let f = LayoutGeometry.frames(for: keyboard.layout!, width: keyboard.bounds.width, metrics: metrics).first { $0.key.id == id }!
            return keyboard.convert(CGPoint(x: f.rect.midX, y: f.rect.midY), to: nil)
        }
        let five = UITouch(), space = UITouch(), u = UITouch()
        five.testLocation = centre("5")
        keyboard.touchesBegan([five], with: UIEvent())
        keyboard.touchesEnded([five], with: UIEvent())
        space.testLocation = centre("space")
        keyboard.touchesBegan([space], with: UIEvent())
        // "u" is where the letters page will have it once the held space is committed.
        let letters = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz, page: .letters, showLanguageKey: true, showGlobeKey: true))
        let uFrame = LayoutGeometry.frames(for: letters, width: keyboard.bounds.width, metrics: metrics).first { $0.key.id == "u" }!
        u.testLocation = keyboard.convert(CGPoint(x: uFrame.rect.midX, y: uFrame.rect.midY), to: nil)
        keyboard.touchesBegan([u], with: UIEvent())
        keyboard.touchesEnded([u], with: UIEvent())
        keyboard.touchesEnded([space], with: UIEvent())
        XCTAssertEqual(proxy.text, "5 u")
        XCTAssertEqual(keyboard.layout?.page, .letters)
    }

    func testHoldingTheNumbersKeyTypesSymbolsAndReleasingItGoesBackToLetters() {
        start()
        let metrics = KeyboardMetrics.standard(height: .standard, landscape: false)
        func centre(_ id: String) -> CGPoint {
            let f = LayoutGeometry.frames(for: keyboard.layout!, width: keyboard.bounds.width, metrics: metrics).first { $0.key.id == id }!
            return keyboard.convert(CGPoint(x: f.rect.midX, y: f.rect.midY), to: nil)
        }
        let numbers = UITouch()
        numbers.testLocation = centre("numbers")
        keyboard.touchesBegan([numbers], with: UIEvent())
        XCTAssertEqual(keyboard.layout?.page, .numbers)
        wait(0.35)
        for id in ["?", "!"] {
            let t = UITouch()
            t.testLocation = centre(id)
            keyboard.touchesBegan([t], with: UIEvent())
            keyboard.touchesEnded([t], with: UIEvent())
        }
        keyboard.touchesEnded([numbers], with: UIEvent())
        XCTAssertEqual(proxy.text, "?!")
        XCTAssertEqual(keyboard.layout?.page, .letters)
    }

    func testExternalChangeIsPickedUpAfterOwnEdits() {
        start()
        type("hallo")
        vc.textDidChange(nil) // the host echoing our own edit: nothing to re-sync
        XCTAssertEqual(keyView("a")?.label.text, "a")
        proxy.replaceAll(with: "") // the app clears the field (message sent)
        vc.textDidChange(nil)
        XCTAssertEqual(keyView("a")?.label.text, "A", "auto-capitalisation at the start of the now empty field")
        type("ok")
        XCTAssertEqual(proxy.text, "Ok")
    }

    func testDimmedReturnFollowsTheDocument() {
        start { $0.enablesReturnKeyAutomatically = true; $0.returnKeyType = .send }
        XCTAssertEqual(keyView("return")?.alpha, 0.5)
        type("a")
        XCTAssertEqual(keyView("return")?.alpha, 1)
        proxy.replaceAll(with: "")
        vc.textDidChange(nil)
        XCTAssertEqual(keyView("return")?.alpha, 0.5)
    }

    func testNumbersAndPunctuationFieldsOpenOnTheNumbersPage() {
        start { $0.keyboardType = .numbersAndPunctuation }
        XCTAssertEqual(keyboard.layout?.page, .numbers)
    }

    func testNumberRowKeepsOneHeightAcrossPages() {
        var settings = KeibordSettings()
        settings.appearance.showNumberRow = true
        start(settings: settings)
        let letters = height
        XCTAssertEqual(keyboard.layout?.rows.count, 5)
        send(.switchPage(.numbers))
        XCTAssertEqual(height, letters)
        send(.switchPage(.letters))
        XCTAssertEqual(height, letters)
    }

    /// iOS keeps some keyboards at 241 pt. The number row stays as set (it used to come and go from
    /// app to app), and the row gaps give way before the keys get lower.
    func testALowKeyboardKeepsTheNumberRowAndTheKeyHeight() {
        var settings = KeibordSettings()
        settings.appearance.showNumberRow = true
        start(settings: settings)
        let full = height
        vc.view.frame = CGRect(x: 0, y: 0, width: 440, height: 241)
        vc.viewDidLayoutSubviews()
        XCTAssertEqual(keyboard.layout?.rows.count, 5, "the number row stays")
        XCTAssertEqual(height, full, "the full height is still requested")
        XCTAssertGreaterThan(keyView("a")?.frame.height ?? 0, 34, "five rows in 205 pt: only the gaps are minimal")
        settings.appearance.showNumberRow = false
        KeibordStore.shared.saveSettings(settings)
        markChangedByTheApp(.settings)
        vc.viewWillDisappear(false)
        vc.viewWillAppear(false)
        vc.viewDidLayoutSubviews()
        XCTAssertEqual(keyboard.layout?.rows.count, 4)
        XCTAssertEqual(keyView("a")?.frame.height, KeyboardMetrics.standard(height: .standard, landscape: false).keyHeight,
                       "four rows in 241 pt keep the full key height")
    }

    /// The system kept another height after the keyboard appeared: new constraints a few times, a
    /// moment later each.
    func testAHeightIOSKeptIsRequestedAgainAFewTimes() {
        KeyboardLog.shared.clear()
        start()
        let wanted = height
        let before = vc.view.heightAnchor.testConstraints.count
        for _ in 0..<6 {
            vc.view.frame = CGRect(x: 0, y: 0, width: 440, height: 241)
            vc.viewDidLayoutSubviews()
        }
        wait(0.8)
        XCTAssertEqual(vc.view.heightAnchor.testConstraints.count, before + 3, "three new requests, then it gives up")
        XCTAssertEqual(height, wanted)
        KeyboardLog.shared.flush()
        XCTAssertEqual(KeyboardLog.shared.read().components(separatedBy: "asking again").count - 1, 3)
        vc.viewWillDisappear(false)
    }

    /// Each language is its own iOS keyboard: no language key (it sat next to the emoji key and was hit
    /// instead of it). Like Apple's space bar: the language's name in the middle while the keyboard
    /// appears, then only this keyboard's language small in the corner ("EN"), never the others'.
    func testALanguageKeyboardHasNoLanguageKeyAndShowsItsLanguageOnTheSpaceBar() {
        var settings = KeibordSettings()
        settings.enabledLanguages = [.deAT, .enUS, .sqXK]
        start(settings: settings, family: .en)
        XCTAssertEqual(keyboard.layout?.language, .enUS, "the English keyboard, in the variant chosen in the app")
        XCTAssertNil(keyView("language"))
        XCTAssertNotNil(keyView("emoji"))
        XCTAssertNil(keyView("ü"), "QWERTY without the German letters")
        XCTAssertTrue(keyboard.spaceNameShown)
        XCTAssertEqual(keyboard.spaceNameLabel.text, "English")
        XCTAssertEqual(keyboard.spaceNameLabel.alpha, 1)
        XCTAssertNil(keyView("space")?.cornerLabel?.text, "no corner code while the name shows")
        XCTAssertNil(keyView("space")?.label.text)
        wait(0.9)
        XCTAssertFalse(keyboard.spaceNameShown, "the name fades after 0.75 s, like Apple's")
        XCTAssertEqual(keyboard.spaceNameLabel.alpha, 0)
        XCTAssertEqual(keyView("space")?.cornerLabel?.text, "EN", "only this keyboard's language")
        send(.nextLanguage)
        XCTAssertEqual(keyboard.layout?.language, .enUS, "nothing switches the language inside a language keyboard")
        vc.viewWillDisappear(false)

        start(settings: settings, family: .de)
        XCTAssertEqual(keyboard.spaceNameLabel.text, "Deutsch")
        XCTAssertEqual(keyboard.layout?.language, .deAT)
        XCTAssertNotNil(keyView("ü"))
        vc.viewWillDisappear(false)
        XCTAssertFalse(keyboard.spaceNameShown, "gone when the keyboard closes")
        XCTAssertEqual(keyView("space")?.cornerLabel?.text, "DE")

        // iOS sometimes never sends viewDidAppear: the name still goes.
        vc = KeyboardViewController()
        vc.languageFamily = .it
        vc.testProxy = TestProxy()
        vc.viewDidLoad()
        vc.viewWillAppear(false)
        XCTAssertEqual(keyboard.spaceNameLabel.text, "Italiano")
        wait(1.7)
        XCTAssertFalse(keyboard.spaceNameShown)
        vc.viewWillDisappear(false)

        settings.appearance.showSpaceLanguageLabel = false
        start(settings: settings, family: .sq)
        XCTAssertFalse(keyboard.spaceNameShown)
        XCTAssertNil(keyView("space")?.cornerLabel?.text)
        vc.viewWillDisappear(false)
    }

    /// Without a language of its own (an older single keyboard) the language key still switches.
    func testAKeyboardWithoutALanguageSwitchesWithTheLanguageKey() {
        start()
        keyboard.fadeOutSpaceName(animated: false)
        XCTAssertNotNil(keyView("language"))
        XCTAssertEqual(keyView("space")?.cornerLabel?.text, "DE")
        send(.nextLanguage)
        XCTAssertEqual(keyboard.layout?.language, .enGB)
        XCTAssertEqual(keyView("space")?.cornerLabel?.text, "EN")
        XCTAssertNotNil(keyView("y"))
        send(.selectLanguage(.deAT))
        XCTAssertEqual(keyboard.layout?.language, .deAT)
        XCTAssertNotNil(keyView("ü"))
    }

    /// Emoji used to wait for the keyboard to close before they were written, and iOS often ends a
    /// keyboard without closing it (an app switch right after sending): the recents lost them.
    func testUsedEmojiAreWrittenSoonWithoutTheKeyboardClosing() {
        start(fullAccess: true)
        send(.emoji)
        let panel = subview(EmojiPanelView.self)!
        vc.emojiPanel(panel, didSelect: "😀")
        vc.emojiPanel(panel, didSelect: "🙈")
        vc.waitForPendingWrites()
        XCTAssertNil(KeibordStore.shared.loadUserModel().emoji["😀"], "not at once: a row of emoji is one write")
        wait(2.2)
        vc.waitForPendingWrites()
        let saved = KeibordStore.shared.loadUserModel()
        XCTAssertEqual(saved.emoji["😀"]?.count, 1)
        XCTAssertEqual(saved.emoji["🙈"]?.count, 1)
        XCTAssertEqual(saved.emojiRecents.first, "🙈")
        vc.emojiPanel(panel, didSelect: "👍")
        vc.emojiPanelDidTapABC(panel)
        vc.waitForPendingWrites()
        XCTAssertEqual(KeibordStore.shared.loadUserModel().emoji["👍"]?.count, 1, "leaving the emoji panel writes them too")
        vc.viewWillDisappear(false)
    }

    func testFavoritesAndStickersInTheEmojiPanel() {
        var settings = KeibordSettings()
        settings.favoriteEmoji = ["❤️", "🥳"]
        KeibordStore.shared.write(StickerIndex(stickers: [StickerEntry(id: "cat", contentKey: "glyph:cat")]), .stickers)
        defer { KeibordStore.shared.write(StickerIndex(), .stickers) }
        start(settings: settings)
        send(.emoji)
        let panel = subview(EmojiPanelView.self)!
        let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 1, "the stickers, to the left of the recents")
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 1), 2, "then the favourites")
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 1, section: 1))
        XCTAssertEqual(proxy.text, "🥳")
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 0))
        XCTAssertEqual(proxy.text, "🥳", "a sticker is never typed")
        XCTAssertEqual(panel.noteText, "Für Sticker „Vollen Zugriff erlauben“ einschalten", "without Full Access it cannot be copied")
        vc.viewWillDisappear(false)
    }

    /// The iOS 26/27 look: function keys in the letter keys' colour, no shadows, a pressed key turns grey.
    func testTheDefaultLookIsTheIOS26Keyboard() {
        for dark in [false, true] {
            start(settings: KeibordSettings(), systemBackdrop: dark ? .dark : .light) { $0.keyboardAppearance = dark ? .dark : .light }
            let letter = keyView("a")?.appliedAppearance
            let shift = keyView("shift")?.appliedAppearance
            XCTAssertNotNil(letter)
            XCTAssertEqual(letter?.fill, shift?.fill, "dark \(dark): shift looks like a letter key")
            XCTAssertEqual(letter?.shadowHidden, true)
            XCTAssertEqual(keyView("return")?.appliedAppearance?.fill, letter?.fill)
            XCTAssertEqual(letter?.fill, dark ? UIColor(red: 69 / 255, green: 69 / 255, blue: 69 / 255, alpha: 1) : UIColor(red: 1, green: 1, blue: 1, alpha: 1))
            vc.viewWillDisappear(false)
        }
    }

    func testBackspaceWordModeAndTrackpadEditTheDocument() {
        start()
        type("hallo welt")
        send(.backspaceRepeat(wordMode: true))
        XCTAssertEqual(proxy.text, "Hallo ")
        send(.moveCursor(-3))
        XCTAssertEqual(proxy.cursor, 3)
        type("x")
        XCTAssertEqual(proxy.text, "Halxlo ")
    }

    // MARK: Learning

    func testLearnedWordsLoadInTheBackgroundAndReachTheSuggestions() {
        var model = UserModel()
        model.words["leiwand"] = LearnedWord(count: 5, lastUsedDay: 20_000, language: "de-AT")
        KeibordStore.shared.saveUserModel(model)
        start()
        wait(0.3) // the background load
        type("leiw")
        XCTAssertTrue(barTitles.contains { $0.lowercased() == "leiwand" }, "\(barTitles)")
    }

    func testWordsLearnedWhileLoadingAreKept() {
        KeibordStore.shared.saveUserModel(UserModel())
        start()
        type("zzwort zzwort ") // before the load finished: twice makes it a known word
        wait(0.3)
        type("zzw")
        XCTAssertTrue(barTitles.contains { $0.lowercased() == "zzwort" }, "\(barTitles)")
    }

    func testLearningIsFlushedWhenTheKeyboardGoesAway() {
        KeibordStore.shared.saveUserModel(UserModel())
        start()
        wait(0.3)
        type("servus oida ")
        vc.viewWillDisappear(false)
        vc.waitForPendingWrites()
        let saved = KeibordStore.shared.loadUserModel()
        XCTAssertEqual(saved.words["oida"]?.count, 1)
        XCTAssertEqual(saved.bigrams[UserModel.bigramKey("Servus", "oida")] ?? saved.bigrams[UserModel.bigramKey("servus", "oida")], 1)
    }

    /// A file held by another process (suspended by iOS in the middle of a write) made the keyboard wait
    /// on its main thread: it opened blank. Opening and closing never wait for the files now.
    func testOpeningAndClosingNeverWaitForAFileHeldElsewhere() {
        start()
        wait(0.3)
        type("servus oida ")
        NSFileCoordinator.testWriteHold = 1.5
        defer { NSFileCoordinator.testWriteHold = 0 }
        let closing = Date()
        vc.viewWillDisappear(false) // its learning write now holds the files for 1.5 s
        XCTAssertLessThan(Date().timeIntervalSince(closing), 0.5, "closing waited for the write")
        let first = vc!
        let opening = Date()
        start() // the keyboard opens again (a new controller) while the write still holds the files
        XCTAssertLessThan(Date().timeIntervalSince(opening), 0.5, "opening waited for the held file")
        XCTAssertNotNil(keyView("a"), "the keys are shown")
        first.waitForPendingWrites()
        XCTAssertEqual(KeibordStore.shared.loadUserModel().words["oida"]?.count, 1, "the learning still reaches the disk")
    }

    // MARK: Blank or collapsed keyboard

    func testAClosedKeyboardControllerIsReleased() {
        weak var released: KeyboardViewController?
        start()
        vc.viewDidAppear(false)
        type("servus ")
        send(.emoji)
        send(.switchPage(.letters))
        vc.viewWillDisappear(false)
        vc.waitForPendingWrites()
        released = vc
        vc = nil
        proxy = nil
        wait(2) // scheduled checks and refreshes run out
        XCTAssertNil(released, "the keyboard controller leaked")
    }

    func testKeysAreShownWhenTheSystemSkipsViewWillAppear() {
        proxy = TestProxy()
        vc = KeyboardViewController()
        vc.testProxy = proxy
        vc.testTraitCollection = UITraitCollection(testStyle: .light)
        vc.viewDidLoad()
        vc.viewDidAppear(false) // no viewWillAppear: nothing was rendered before
        XCTAssertNotNil(keyView("a"), "the keyboard opened blank")
        vc.viewWillDisappear(false)
    }

    /// 1.0.14 read the document identifier while loading: the keyboard crashed before it was shown,
    /// every time. Learned words that finished loading before viewWillAppear did the same now and then.
    func testNothingReadsTheDocumentBeforeIOSConnectsIt() {
        var model = UserModel()
        model.words["leiwand"] = LearnedWord(count: 5, lastUsedDay: 20_000, language: "de-AT")
        KeibordStore.shared.saveUserModel(model)
        proxy = TestProxy()
        proxy.connected = false
        vc = KeyboardViewController()
        vc.testProxy = proxy
        vc.testTraitCollection = UITraitCollection(testStyle: .light)
        vc.viewDidLoad()
        wait(0.4) // the learned words load and refresh the suggestions
        vc.viewWillLayoutSubviews()
        vc.viewDidLayoutSubviews()
        XCTAssertFalse(proxy.identifierReadWhileDisconnected, "the keyboard would crash while loading")
        XCTAssertNotNil(keyView("a"), "keys while loading")
        proxy.connected = true
        vc.viewWillAppear(false)
        vc.viewDidAppear(false)
        type("servus ")
        XCTAssertEqual(proxy.text, "Servus ")
        vc.viewWillDisappear(false)
    }

    func testAKeyboardLoadedButNeverAnnouncedIsLoggedAndPrepared() {
        KeyboardLog.shared.clear()
        proxy = TestProxy()
        vc = KeyboardViewController()
        vc.testProxy = proxy
        vc.testTraitCollection = UITraitCollection(testStyle: .light)
        vc.viewDidLoad() // and then no viewWillAppear/viewDidAppear
        wait(1.2)
        KeyboardLog.shared.flush()
        XCTAssertTrue(KeyboardLog.shared.read().contains("not announced as shown"))
        XCTAssertNotNil(keyView("a"))
        XCTAssertFalse(proxy.identifierReadWhileDisconnected, "the fallback reads nothing from the text field")
    }

    /// Before iOS connects the text field the keyboard cannot know whether the app wants it light or
    /// dark: it stays invisible until then instead of flashing a guess.
    func testTheKeyboardIsInvisibleUntilItsAppearanceIsKnown() {
        UIScreen.main.testUserInterfaceStyle = .dark
        proxy = TestProxy()
        proxy.connected = false
        vc = KeyboardViewController()
        vc.testProxy = proxy
        vc.testTraitCollection = UITraitCollection(testStyle: .dark)
        vc.viewDidLoad()
        XCTAssertEqual(vc.view.alpha, 0)
        XCTAssertNotNil(keyView("a"), "keys and height are ready")
        proxy.connected = true
        vc.viewWillAppear(false)
        XCTAssertEqual(vc.view.alpha, 1)
        vc.viewDidAppear(false)
        vc.viewWillDisappear(false)
        UIScreen.main.testUserInterfaceStyle = .light
    }

    func testTheKeyboardLogRecordsOpeningAndClosingButNoTypedText() {
        KeyboardLog.shared.clear()
        start()
        vc.viewDidAppear(false)
        type("geheimwort ")
        vc.viewWillDisappear(false)
        KeyboardLog.shared.flush()
        let log = KeyboardLog.shared.read()
        for event in ["loading", "height wanted", "appear: text field", "on screen", "close"] {
            XCTAssertTrue(log.contains(event), "\(event) missing in\n\(log)")
        }
        XCTAssertFalse(log.contains("geheim"))
    }

    func testAStalledMainThreadIsLogged() {
        KeyboardLog.shared.clear()
        start() // the watchdog runs while the keyboard is open
        Thread.sleep(forTimeInterval: 2.2) // the main thread does not answer
        wait(1.2)
        vc.viewWillDisappear(false)
        wait(0.1)
        KeyboardLog.shared.flush()
        let log = KeyboardLog.shared.read()
        XCTAssertTrue(log.contains("main thread not responding"), log)
        XCTAssertTrue(log.contains("main thread responding again"), log)
    }

    func testModelChangedByTheAppIsReloadedOnTheNextAppearance() {
        start()
        wait(0.3)
        type("servus ")
        vc.viewWillDisappear(false)
        // The app adds a word in its dictionary editor while the keyboard is away.
        KeibordStore.shared.updateUserModel { $0.addWord("neuwort") }
        markChangedByTheApp(.userModel)
        type("oida ") // learned after the flush, still pending when the keyboard comes back
        vc.viewWillAppear(false)
        wait(0.3)
        type("neuw")
        XCTAssertTrue(barTitles.contains { $0.lowercased() == "neuwort" }, "\(barTitles)")
        vc.viewWillDisappear(false)
        vc.waitForPendingWrites()
        let saved = KeibordStore.shared.loadUserModel()
        XCTAssertNotNil(saved.words["neuwort"])
        XCTAssertNotNil(saved.words["Servus"] ?? saved.words["servus"])
        XCTAssertEqual(saved.words["oida"]?.count, 1)
    }

    /// Makes user-model.json unreadable (a directory in its place: root ignores file permissions).
    private func blockUserModelFile() {
        let url = KeibordStore.shared.url(.userModel)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func testLearningIsKeptWhenTheWriteFailsAndWrittenLater() {
        start()
        wait(0.3)
        type("servus oida ")
        blockUserModelFile()
        vc.viewWillDisappear(false) // the write fails: the file cannot be read
        vc.waitForPendingWrites()
        wait(0.05)
        try? FileManager.default.removeItem(at: KeibordStore.shared.url(.userModel))
        vc.viewWillAppear(false)
        wait(0.3)
        vc.viewWillDisappear(false)
        vc.waitForPendingWrites()
        let saved = KeibordStore.shared.loadUserModel()
        XCTAssertEqual(saved.words["oida"]?.count, 1, "the failed write's words reach the disk with the next one")
        XCTAssertEqual(saved.languageUsage.values.reduce(0, +), 2, "counted once")
    }

    func testUnreadableModelIsReadAgainOnTheNextAppearance() {
        // user-model.json is a symbolic link (its own modification date is what the keyboard sees) to a
        // directory: unreadable. Later the target becomes a readable model, the link's date unchanged,
        // like a file that could not be read for a moment (data protection, I/O error).
        let url = KeibordStore.shared.url(.userModel)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("keibord-model-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        XCTAssertNoThrow(try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target))
        defer { try? FileManager.default.removeItem(at: target) }
        let linkDate = KeibordStore.shared.modificationDate(of: .userModel)
        XCTAssertNotNil(linkDate)
        start()
        wait(0.3)
        vc.viewWillDisappear(false)
        var model = UserModel()
        model.words["leiwand"] = LearnedWord(count: 5, lastUsedDay: 20_000, language: "de-AT")
        try? FileManager.default.removeItem(at: target)
        XCTAssertNoThrow(try KeibordJSON.encoder().encode(model).write(to: target))
        XCTAssertEqual(KeibordStore.shared.modificationDate(of: .userModel), linkDate)
        vc.viewWillAppear(false)
        wait(0.3)
        type("leiw")
        XCTAssertTrue(barTitles.contains { $0.lowercased() == "leiwand" }, "\(barTitles)")
    }

    // MARK: Suggestion bar

    private var barTitles: [String] {
        guard let bar = subview(SuggestionBarView.self), !bar.isHidden else { return [] }
        return bar.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }.compactMap { $0.title(for: .normal) }
    }

    func testOneTimeCodeFieldOffersTheSystemKeyboard() {
        start { $0.textContentType = .oneTimeCode; $0.keyboardType = .numberPad }
        XCTAssertEqual(barTitles, ["Code aus Nachrichten → iOS-Tastatur"])
        let hint = Suggestion(text: "", display: "", kind: .action, appendsSpace: false, payload: "switch-keyboard")
        vc.suggestionBar(SuggestionBarView(), didSelect: hint)
        XCTAssertEqual(vc.testAdvanceCount, 1)
    }

    func testFullAccessHintOnlyWithoutFullAccessAndExpandsOnTap() {
        start()
        XCTAssertEqual(barTitles, ["Vollen Zugriff erlauben, damit deine Einstellungen gelten"])
        let hint = Suggestion(text: "", display: "", kind: .action, appendsSpace: false, payload: "full-access")
        vc.suggestionBar(SuggestionBarView(), didSelect: hint)
        XCTAssertEqual(barTitles, ["Einstellungen › Keibord › Tastaturen › Voller Zugriff"])
        vc.viewWillDisappear(false)
        vc.testHasFullAccess = true
        vc.viewWillAppear(false)
        XCTAssertEqual(barTitles, [])
    }

    func testHintWhenTheAppsSettingsAreMissingFromTheSharedFolder() throws {
        try? FileManager.default.removeItem(at: KeibordStore.shared.url(.settings))
        start(fullAccess: true)
        XCTAssertEqual(barTitles, ["Keibord-App einmal öffnen, damit deine Einstellungen gelten"])
        type("ha")
        XCTAssertFalse(barTitles.contains("Keibord-App einmal öffnen, damit deine Einstellungen gelten"), "not while typing a word")
        KeibordStore.shared.saveSettings(KeibordSettings()) // the app was opened
        vc.viewWillDisappear(false)
        vc.viewWillAppear(false)
        proxy.replaceAll(with: "")
        vc.textDidChange(nil)
        XCTAssertEqual(barTitles, [])
    }

    func testSettingsFromTheAppApplyWhenTheKeyboardAppearsAgain() {
        start(fullAccess: true)
        XCTAssertNotEqual(keyboard.layout?.rows.count, 5)
        var s = KeibordSettings()
        s.appearance.showNumberRow = true
        KeibordStore.shared.saveSettings(s)
        markChangedByTheApp(.settings)
        vc.viewWillDisappear(false)
        vc.viewWillAppear(false)
        XCTAssertEqual(keyboard.layout?.rows.count, 5, "the number row set in the app is shown")
    }

    // MARK: Emoji

    func testEmojiSearchTypesIntoTheQueryNotTheDocument() {
        start()
        type("x")
        let keysHeight = height
        send(.emoji)
        let panel = subview(EmojiPanelView.self)
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.isHidden, false)
        XCTAssertTrue(keyboard.isHidden)
        vc.emojiPanelDidRequestSearch(panel!)
        let bar = subview(EmojiSearchBarView.self)
        XCTAssertEqual(height, keysHeight, "one height: the 88 pt query bar takes its room from the keys")
        XCTAssertFalse(keyboard.isHidden)
        type("he")
        XCTAssertEqual(proxy.text, "X")
        XCTAssertEqual(bar?.query, "he")
        XCTAssertEqual(keyView("h")?.label.text, "h", "lower-case labels while searching")
        send(.backspace)
        XCTAssertEqual(bar?.query, "h")
        send(.switchPage(.numbers))
        XCTAssertEqual(keyboard.layout?.page, .numbers)
        send(.space)
        XCTAssertEqual(keyboard.layout?.page, .letters)
        XCTAssertEqual(bar?.query, "h ")
        XCTAssertEqual(proxy.text, "X")
        vc.emojiSearchBarDidCancel(bar!)
        XCTAssertEqual(panel?.isHidden, false)
        vc.emojiPanel(panel!, didSelect: "😀")
        XCTAssertEqual(proxy.text, "X😀")
        vc.emojiPanelDidTapABC(panel!)
        XCTAssertEqual(height, keysHeight)
        XCTAssertFalse(keyboard.isHidden)
        XCTAssertEqual(panel?.isHidden, true)
    }

    // MARK: Cards

    private func card(requiresCVV: Bool) -> StoredCard {
        StoredCard(id: UUID(), nickname: "", holderName: "Senad Hamza", last4: "1111", brand: .visa, expMonth: 4, expYear: 2029,
                   requiresCVV: requiresCVV, salt: Data(), sealedNumber: Data(), failedAttempts: 0, createdAt: Date())
    }

    func testCardChipFillsTheNumberAndTheUnlockIsCachedForTheExpiry() {
        let c = card(requiresCVV: true)
        CardVault.shared.testCards = [c]
        CardVault.shared.testNumbers[c.id] = "4111111111111111"
        CardVault.shared.testCVVs[c.id] = "123"
        var settings = KeibordSettings()
        settings.cardSuggestions = true
        start(settings: settings) { $0.textContentType = .creditCardNumber; $0.keyboardType = .numberPad }
        let chip = Suggestion(text: "", display: c.title, kind: .card, appendsSpace: false, payload: c.id.uuidString)
        vc.suggestionBar(SuggestionBarView(), didSelect: chip)
        let unlock = subview(CardUnlockView.self)
        XCTAssertEqual(unlock?.isHidden, false, "a card with a security code asks for it first")
        vc.cardUnlockView(unlock!, didEnter: "999")
        XCTAssertEqual(proxy.text, "", "wrong code inserts nothing")
        vc.cardUnlockView(unlock!, didEnter: "123")
        XCTAssertEqual(proxy.text, "4111111111111111")
        XCTAssertEqual(unlock?.isHidden, true)
        // Another field of the same form within 3 minutes: no second prompt.
        proxy.textContentType = .creditCardExpiration
        proxy.keyboardType = .default
        proxy.replaceAll(with: "")
        proxy.documentIdentifier = UUID()
        vc.textDidChange(nil)
        let unlocks = CardVault.shared.testUnlockCount
        vc.suggestionBar(SuggestionBarView(), didSelect: chip)
        XCTAssertEqual(proxy.text, "04/29")
        XCTAssertEqual(CardVault.shared.testUnlockCount, unlocks)
    }
}
