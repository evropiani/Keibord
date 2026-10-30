import XCTest
import UIKit
import KeibordCore
@testable import KeyboardCheck

/// Records what the key area reports, as short strings ("down:h", "char:h", "space", …).
private final class Recorder: KeyboardViewDelegate {
    var events: [String] = []
    var globeForwards = 0
    var onEvent: ((KeyboardViewEvent) -> Void)?

    func keyboardView(_ view: KeyboardView, didTrigger event: KeyboardViewEvent) {
        switch event {
        case .keyDown(let key): events.append("down:\(key.id)")
        case let .character(text, _, _): events.append("char:\(text)")
        case .backspace: events.append("backspace")
        case .backspaceRepeat(let wordMode): events.append(wordMode ? "repeatWord" : "repeat")
        case .space: events.append("space")
        case .returnKey: events.append("return")
        case .shift: events.append("shift")
        case .shiftDoubleTap: events.append("capslock")
        case .shiftReleased: events.append("shiftUp")
        case .switchPage(let page): events.append("page:\(page.rawValue)")
        case .emoji: events.append("emoji")
        case .nextLanguage: events.append("nextLanguage")
        case .selectLanguage(let language): events.append("language:\(language.rawValue)")
        case .moveCursor(let n): events.append("move:\(n)")
        case .trackpad(let on): events.append("trackpad:\(on)")
        }
        onEvent?(event)
    }

    func keyboardView(_ view: KeyboardView, globeTouchedWith event: UIEvent, in keyView: UIView) { globeForwards += 1 }

    /// Events other than key-downs.
    var actions: [String] { events.filter { !$0.hasPrefix("down:") } }
}

final class KeyboardViewTouchTests: XCTestCase {
    private let barHeight: CGFloat = 44
    private let width: CGFloat = 390
    private var container: UIView!
    private var keyboard: KeyboardView!
    private var recorder: Recorder!
    private var metrics = KeyboardMetrics.standard(height: .standard, landscape: false)
    private let theme = KeyboardTheme(settings: KeibordSettings(), dark: false)

    private func request(_ page: LayoutPage = .letters, globe: Bool = false, languages: Int = 2) -> LayoutRequest {
        LayoutRequest(language: .deAT, base: .qwertz, page: page, variant: .standard, showNumberRow: false,
                      showLanguageKey: languages > 1, showGlobeKey: globe, returnKind: .default)
    }

    private func configure(_ request: LayoutRequest, shift: ShiftState = .off, returnEnabled: Bool = true) {
        keyboard.configure(layout: LayoutFactory.layout(for: request), metrics: metrics, theme: theme, shiftState: shift,
                           spaceLabel: "Leerzeichen", returnEnabled: returnEnabled, returnProminent: false,
                           touchOffsets: [:], touchOffsetsID: "off")
        keyboard.layoutIfNeeded()
    }

    private func setUpKeyboard(_ request: LayoutRequest, returnEnabled: Bool = true) {
        let height = metrics.keyboardHeight(rows: 4)
        container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: barHeight + height))
        keyboard = KeyboardView(frame: .zero)
        container.addSubview(keyboard)
        keyboard.frame = CGRect(x: 0, y: barHeight, width: width, height: height)
        recorder = Recorder()
        keyboard.delegate = recorder
        keyboard.languages = [.deAT, .enGB]
        configure(request, returnEnabled: returnEnabled)
    }

    /// Centre of a key (by id) of `request`'s layout, in window coordinates.
    private func point(_ id: String, in request: LayoutRequest? = nil, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
        let layout = request.map(LayoutFactory.layout(for:)) ?? keyboard.layout!
        guard let f = LayoutGeometry.frames(for: layout, width: width, metrics: metrics).first(where: { $0.key.id == id }) else {
            XCTFail("no key \(id)")
            return .zero
        }
        return CGPoint(x: f.rect.midX + dx, y: f.rect.midY + barHeight + dy)
    }

    private func touch(at p: CGPoint) -> UITouch {
        let t = UITouch()
        t.testLocation = p
        return t
    }

    private func down(_ t: UITouch) { keyboard.touchesBegan([t], with: UIEvent()) }
    private func move(_ t: UITouch, to p: CGPoint) {
        t.testLocation = p
        keyboard.touchesMoved([t], with: UIEvent())
    }
    private func up(_ t: UITouch) { keyboard.touchesEnded([t], with: UIEvent()) }
    private func tap(_ id: String) {
        let t = touch(at: point(id))
        down(t)
        up(t)
    }
    private func tap(at p: CGPoint) {
        let t = touch(at: p)
        down(t)
        up(t)
    }
    private func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: Rollover

    func testRolloverCommitsThePendingLetterBeforeTheNextKey() {
        setUpKeyboard(request())
        let h = touch(at: point("h")), i = touch(at: point("i"))
        down(h)
        down(i) // "h" is still held
        up(i)
        up(h)
        XCTAssertEqual(recorder.events, ["down:h", "char:h", "down:i", "char:i"])
    }

    func testRolloverAfterAPageSwitchResolvesTheNextTouchOnTheNewPage() {
        let numbers = request(.numbers), letters = request(.letters)
        setUpKeyboard(numbers)
        // The controller returns to letters after a space typed on the numbers page.
        recorder.onEvent = { [unowned self] event in
            if case .space = event { self.configure(letters) }
        }
        tap("5")
        let space = touch(at: point("space"))
        down(space)
        let u = touch(at: point("u", in: letters))
        down(u) // commits the held space first, which switches to letters
        up(u)
        up(space)
        XCTAssertEqual(recorder.actions, ["char:5", "space", "char:u"])
    }

    // MARK: Page keys

    /// Switches the page like the controller does when a page key asks for it.
    private func followPageSwitches() {
        recorder.onEvent = { [unowned self] event in
            if case .switchPage(let page) = event { self.configure(self.request(page)) }
        }
    }

    func testHoldingTheNumbersKeyTypesSymbolsAndReleasingItGoesBackToLetters() {
        setUpKeyboard(request())
        followPageSwitches()
        let numbers = touch(at: point("numbers"))
        down(numbers)
        XCTAssertEqual(keyboard.layout?.page, .numbers, "the page shows as soon as the key is touched")
        wait(0.35)
        tap("?")
        tap("5")
        XCTAssertEqual(keyboard.layout?.page, .numbers)
        up(numbers)
        XCTAssertEqual(recorder.actions, ["page:numbers", "char:?", "char:5", "page:letters"])
        XCTAssertEqual(keyboard.layout?.page, .letters)
    }

    func testTappingThePageKeyStaysOnTheNewPage() {
        setUpKeyboard(request())
        followPageSwitches()
        tap("numbers")
        XCTAssertEqual(keyboard.layout?.page, .numbers)
        let abc = touch(at: point("letters"))
        down(abc)
        wait(0.35)
        up(abc) // held without typing: stays too
        XCTAssertEqual(recorder.actions, ["page:numbers", "page:letters"])
        XCTAssertEqual(keyboard.layout?.page, .letters)
    }

    func testAPageKeyOverlappingFastTypingIsATap() {
        setUpKeyboard(request())
        followPageSwitches()
        let numbers = touch(at: point("numbers"))
        down(numbers)
        tap("5") // the next key before the page key was released
        up(numbers)
        XCTAssertEqual(recorder.actions, ["page:numbers", "char:5"])
        XCTAssertEqual(keyboard.layout?.page, .numbers)
    }

    func testSlidingFromThePageKeyTypesTheKeyAndGoesBack() {
        setUpKeyboard(request())
        followPageSwitches()
        let numbers = touch(at: point("numbers"))
        down(numbers)
        move(numbers, to: point("letters", dx: 5)) // still on the page key ("ABC" now): nothing yet
        move(numbers, to: point("."))
        XCTAssertEqual(recorder.actions, ["page:numbers"])
        up(numbers)
        XCTAssertEqual(recorder.actions, ["page:numbers", "char:.", "page:letters"])
        XCTAssertEqual(keyboard.layout?.page, .letters)
    }

    func testSlidingToANeighbourTypesTheKeyUnderTheFinger() {
        setUpKeyboard(request())
        let t = touch(at: point("a"))
        down(t)
        move(t, to: point("s"))
        up(t)
        XCTAssertEqual(recorder.actions, ["char:s"])
    }

    func testLikelyNextLetterTakesTheEdgeOfItsNeighbourAndKeepsIt() {
        setUpKeyboard(request())
        let w = point("w"), e = point("e")
        let edge = CGPoint(x: w.x + 0.42 * (e.x - w.x), y: w.y) // on "w", towards "e"
        tap(at: edge)
        keyboard.letterPrior = ["e": -0.05] // after "ther"
        let t = touch(at: edge)
        down(t)
        move(t, to: CGPoint(x: edge.x - 1, y: edge.y)) // a jitter must not slide back to "w"
        up(t)
        tap(at: w) // the middle of "w" always types "w"
        XCTAssertEqual(recorder.actions, ["char:w", "char:e", "char:w"])
    }

    func testQuickTapCancelledByTheSystemStillTypes() {
        setUpKeyboard(request())
        let t = touch(at: point("a"))
        down(t)
        keyboard.touchesCancelled([t], with: UIEvent())
        XCTAssertEqual(recorder.actions, ["char:a"], "iOS cancels taps near the screen edges; they are key presses")
    }

    func testCancelledSwipeOrLongTouchTypesNothing() {
        setUpKeyboard(request())
        let swipe = touch(at: point("a"))
        down(swipe)
        move(swipe, to: point("a", dx: 25))
        keyboard.touchesCancelled([swipe], with: UIEvent())
        let held = touch(at: point("l"))
        down(held)
        wait(0.35)
        keyboard.touchesCancelled([held], with: UIEvent())
        XCTAssertEqual(recorder.actions, [], "a swipe or a held finger was not a tap")
    }

    // MARK: Return, shift, globe

    func testDimmedReturnKeyDoesNothing() {
        setUpKeyboard(request(), returnEnabled: false)
        tap("return")
        XCTAssertEqual(recorder.events, ["down:return"])
        configure(request(), returnEnabled: true)
        tap("return")
        XCTAssertEqual(recorder.actions, ["return"])
    }

    func testShiftDoubleTapLocksAndSlowTapsToggle() {
        setUpKeyboard(request())
        tap("shift")
        tap("shift")
        XCTAssertEqual(recorder.actions, ["shift", "shiftUp", "capslock", "shiftUp"])
        recorder.events = []
        tap("shift")
        wait(0.35)
        tap("shift")
        XCTAssertEqual(recorder.actions, ["shift", "shiftUp", "shift", "shiftUp"])
    }

    func testGlobeTouchesAreForwardedIncludingCancellation() {
        setUpKeyboard(request(globe: true))
        let t = touch(at: point("globe"))
        down(t)
        move(t, to: point("globe", dx: 2))
        keyboard.touchesCancelled([t], with: UIEvent())
        XCTAssertEqual(recorder.globeForwards, 3, "began, moved and cancelled reach handleInputModeList")
        XCTAssertEqual(recorder.actions, [])
    }

    // MARK: Long presses

    func testSpaceTrackpadMovesTheCursorAndIgnoresOtherFingers() {
        setUpKeyboard(request())
        let space = touch(at: point("space"))
        down(space)
        wait(0.5)
        XCTAssertEqual(recorder.actions, ["trackpad:true"])
        let stray = touch(at: point("a"))
        down(stray)
        up(stray)
        move(space, to: point("space", dx: 20))
        move(space, to: point("space", dx: 2))
        up(space)
        XCTAssertEqual(recorder.actions, ["trackpad:true", "move:2", "move:-2", "trackpad:false"])
    }

    func testLanguageListReleasedInPlaceKeepsTheLanguageAndSlidingUpPicksAnother() {
        setUpKeyboard(request())
        var t = touch(at: point("language"))
        down(t)
        wait(0.5)
        up(t)
        XCTAssertEqual(recorder.actions, ["language:de-AT"])
        recorder.events = []
        t = touch(at: point("language"))
        down(t)
        wait(0.5)
        // Two 40 pt rows end 6 pt above the key: the lower row is the second language.
        let key = point("language")
        move(t, to: CGPoint(x: key.x, y: key.y - metrics.keyHeight / 2 - 26))
        up(t)
        XCTAssertEqual(recorder.actions, ["language:en-GB"])
    }

    func testAccentMenuInsertsTheFirstAlternateWhenReleasedInPlace() {
        setUpKeyboard(request())
        let t = touch(at: point("s"))
        down(t)
        wait(0.5)
        up(t)
        XCTAssertEqual(recorder.actions, ["char:ß"])
    }

    func testShiftedAccentMenuUppercasesExceptSharpS() {
        setUpKeyboard(request())
        configure(request(), shift: .on)
        let t = touch(at: point("a"))
        down(t)
        wait(0.5)
        up(t)
        XCTAssertEqual(recorder.actions, ["char:Ä"])
        recorder.events = []
        let s = touch(at: point("s"))
        down(s)
        wait(0.5)
        up(s)
        XCTAssertEqual(recorder.actions, ["char:ß"])
    }

    // MARK: Backspace

    func testBackspaceDeletesOnTouchDownRepeatsAndSwitchesToWords() {
        setUpKeyboard(request())
        let t = touch(at: point("backspace"))
        down(t)
        XCTAssertEqual(recorder.actions, ["backspace"])
        wait(0.8)
        XCTAssertTrue(recorder.actions.contains("repeat"), "repeats after 0.5 s")
        XCTAssertFalse(recorder.actions.contains("repeatWord"))
        wait(1.3)
        XCTAssertTrue(recorder.actions.contains("repeatWord"), "whole words after 1.6 s")
        up(t)
        let count = recorder.events.count
        wait(0.3)
        XCTAssertEqual(recorder.events.count, count, "stops on release")
    }

    func testLayoutChangeStopsAHeldBackspace() {
        setUpKeyboard(request())
        let t = touch(at: point("backspace"))
        down(t)
        configure(request(.numbers))
        wait(0.8)
        XCTAssertEqual(recorder.actions, ["backspace"])
    }

    // MARK: Popups

    func testRowsShrinkWhenTheKeyAreaIsLowerThanRequested() {
        setUpKeyboard(request())
        keyboard.frame.size.height = 170 // the system kept the keyboard lower than it asked for
        keyboard.layoutIfNeeded()
        let keys = keyboard.subviews.compactMap { $0 as? KeyView }
        XCTAssertFalse(keys.isEmpty)
        XCTAssertLessThanOrEqual(keys.map(\.frame.maxY).max() ?? 0, 170, "no row is cut off")
        guard let space = keys.first(where: { $0.key.id == "space" }) else { return XCTFail("no space key") }
        let t = touch(at: CGPoint(x: space.frame.midX, y: space.frame.midY + barHeight))
        down(t)
        up(t)
        XCTAssertEqual(recorder.actions, ["space"], "touches use the shrunk rows")
    }

    func testPopupOfATopRowKeyStaysInsideTheInputView() {
        metrics = KeyboardMetrics.standard(height: .tall, landscape: false)
        setUpKeyboard(request())
        for id in ["q", "ü"] {
            let t = touch(at: point(id))
            down(t)
            let popup = keyboard.subviews.compactMap { $0 as? KeyPopupView }.first
            XCTAssertNotNil(popup)
            if let popup = popup {
                XCTAssertFalse(popup.isHidden)
                XCTAssertGreaterThanOrEqual(popup.frame.minY, -barHeight, "\(id): not above the input view")
                XCTAssertGreaterThanOrEqual(popup.frame.minX, 0, id)
                XCTAssertLessThanOrEqual(popup.frame.maxX, width, id)
            }
            up(t)
        }
    }

    func testReleasingShiftKeepsThePreviewOfTheHeldLetter() {
        setUpKeyboard(request())
        let popup = { self.keyboard.subviews.compactMap { $0 as? KeyPopupView }.first }
        let shift = touch(at: point("shift")), h = touch(at: point("h"))
        down(shift)
        down(h)
        XCTAssertEqual(popup()?.isHidden, false)
        up(shift) // shift goes up first, the letter is still held
        XCTAssertEqual(popup()?.isHidden, false, "the held letter keeps its preview")
        up(h)
        XCTAssertEqual(popup()?.isHidden, true)
        XCTAssertEqual(recorder.actions, ["shift", "shiftUp", "char:h"])
    }

    func testShiftHeldWhileTypingIsReleasedAfterTheLetters() {
        setUpKeyboard(request())
        let shift = touch(at: point("shift"))
        down(shift)
        tap("h")
        tap("a")
        up(shift)
        XCTAssertEqual(recorder.actions, ["shift", "char:h", "char:a", "shiftUp"])
    }

    func testCancelledShiftTouchIsReleased() {
        setUpKeyboard(request())
        let shift = touch(at: point("shift"))
        down(shift)
        keyboard.touchesCancelled([shift], with: UIEvent())
        XCTAssertEqual(recorder.actions, ["shift", "shiftUp"])
        recorder.events = []
        wait(0.35) // not a double tap
        down(touch(at: point("shift")))
        configure(request(.numbers)) // a page switch drops every touch
        XCTAssertEqual(recorder.actions, ["shift", "shiftUp"])
    }

    func testAccentMenuOnTheRightEdgeStaysInsideTheKeyboard() {
        setUpKeyboard(request())
        let t = touch(at: point("o"))
        down(t)
        wait(0.5)
        let callout = keyboard.subviews.compactMap { $0 as? CalloutView }.first
        XCTAssertNotNil(callout)
        if let callout = callout {
            XCTAssertFalse(callout.isHidden)
            XCTAssertGreaterThanOrEqual(callout.frame.minX, 0)
            XCTAssertLessThanOrEqual(callout.frame.maxX, width)
            XCTAssertGreaterThanOrEqual(callout.frame.minY, -barHeight)
        }
        up(t)
        XCTAssertEqual(recorder.actions, ["char:ö"], "the first alternate sits above the key")
    }
}
