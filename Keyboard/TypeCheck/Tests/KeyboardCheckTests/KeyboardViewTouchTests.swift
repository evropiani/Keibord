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

    func testSlidingToANeighbourTypesTheKeyUnderTheFinger() {
        setUpKeyboard(request())
        let t = touch(at: point("a"))
        down(t)
        move(t, to: point("s"))
        up(t)
        XCTAssertEqual(recorder.actions, ["char:s"])
    }

    func testCancelledTouchTypesNothing() {
        setUpKeyboard(request())
        let t = touch(at: point("a"))
        down(t)
        keyboard.touchesCancelled([t], with: UIEvent())
        XCTAssertEqual(recorder.actions, [])
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
        XCTAssertEqual(recorder.actions, ["shift", "capslock"])
        recorder.events = []
        tap("shift")
        wait(0.35)
        tap("shift")
        XCTAssertEqual(recorder.actions, ["shift", "shift"])
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
