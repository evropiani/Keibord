import XCTest
import UIKit
import KeibordCore
@testable import KeyboardCheck

/// An in-memory text field as the keyboard sees it through `UITextDocumentProxy`.
final class TestProxy: UITextDocumentProxy {
    var text = ""
    var cursor = 0
    var documentIdentifier = UUID()
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
    }

    private func start(settings: KeibordSettings? = nil, configure: (TestProxy) -> Void = { _ in }) {
        if let settings = settings { KeibordStore.shared.saveSettings(settings) }
        proxy = TestProxy()
        configure(proxy)
        vc = KeyboardViewController()
        vc.testProxy = proxy
        vc.viewDidLoad()
        vc.viewWillAppear(false)
        vc.viewDidLayoutSubviews()
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

    func testLanguageKeySwitchesLayoutAndSpaceLabel() {
        start()
        XCTAssertEqual(keyView("space")?.label.text, "Deutsch (Österreich)")
        send(.nextLanguage)
        XCTAssertEqual(keyboard.layout?.language, .enGB)
        XCTAssertEqual(keyView("space")?.label.text, "English (UK)")
        XCTAssertNotNil(keyView("y"))
        send(.selectLanguage(.deAT))
        XCTAssertEqual(keyboard.layout?.language, .deAT)
        XCTAssertNotNil(keyView("ü"))
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
        let saved = KeibordStore.shared.loadUserModel()
        XCTAssertEqual(saved.words["oida"]?.count, 1)
        XCTAssertEqual(saved.bigrams[UserModel.bigramKey("Servus", "oida")] ?? saved.bigrams[UserModel.bigramKey("servus", "oida")], 1)
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
        wait(0.05)
        try? FileManager.default.removeItem(at: KeibordStore.shared.url(.userModel))
        vc.viewWillAppear(false)
        wait(0.3)
        vc.viewWillDisappear(false)
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
        XCTAssertEqual(barTitles, ["Vollen Zugriff erlauben für Lernen & Einstellungen"])
        let hint = Suggestion(text: "", display: "", kind: .action, appendsSpace: false, payload: "full-access")
        vc.suggestionBar(SuggestionBarView(), didSelect: hint)
        XCTAssertEqual(barTitles, ["Einstellungen › Keibord › Tastaturen › Voller Zugriff"])
        vc.viewWillDisappear(false)
        vc.testHasFullAccess = true
        vc.viewWillAppear(false)
        XCTAssertEqual(barTitles, [])
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
        XCTAssertEqual(height, keysHeight + 44, "the query bar is added on top")
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
