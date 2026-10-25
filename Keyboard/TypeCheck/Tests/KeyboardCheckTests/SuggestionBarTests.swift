import XCTest
import UIKit
import KeibordCore
@testable import KeyboardCheck

private final class BarRecorder: SuggestionBarDelegate {
    var selected: [String] = []
    func suggestionBar(_ bar: SuggestionBarView, didSelect suggestion: Suggestion) { selected.append(suggestion.text) }
}

final class SuggestionBarTests: XCTestCase {
    private var bar: SuggestionBarView!
    private var recorder: BarRecorder!

    private func setUpBar(_ words: [String]) {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        bar = SuggestionBarView(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        container.addSubview(bar)
        recorder = BarRecorder()
        bar.delegate = recorder
        bar.update(words.map { Suggestion(text: $0, kind: .prediction) }, theme: KeyboardTheme(settings: KeibordSettings(), dark: false))
        bar.layoutIfNeeded()
    }

    private func tap(_ x: CGFloat, _ y: CGFloat = 22) {
        let t = UITouch()
        t.testLocation = CGPoint(x: x, y: y)
        bar.touchesBegan([t], with: UIEvent())
        bar.touchesEnded([t], with: UIEvent())
    }

    func testTheWholeThirdOfTheBarSelectsItsWord() {
        setUpBar(["to", "the", "you"])
        tap(2, 2)        // far left edge, top: "to" is short but its whole slot counts
        tap(128, 42)     // right end of the first slot, bottom
        tap(132)         // just inside the second slot
        tap(388)         // right edge
        XCTAssertEqual(recorder.selected, ["to", "to", "the", "you"])
    }

    func testTheAutocorrectHighlightStaysInsideTheBar() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 36))
        bar = SuggestionBarView(frame: CGRect(x: 0, y: 0, width: 390, height: 36))
        container.addSubview(bar)
        bar.update([Suggestion(text: "the", kind: .correction, isAutocorrect: true), Suggestion(text: "then", kind: .prediction)],
                   theme: KeyboardTheme(settings: KeibordSettings(), dark: false))
        bar.layoutIfNeeded()
        let highlight = bar.subviews.first { !($0 is UIButton) && !$0.isHidden && $0.frame.width > 10 }
        XCTAssertNotNil(highlight)
        XCTAssertGreaterThanOrEqual(highlight?.frame.minY ?? -1, 0)
        XCTAssertLessThanOrEqual(highlight?.frame.maxY ?? 99, 36)
        let word = bar.subviews.compactMap { $0 as? UIButton }.first
        XCTAssertEqual(highlight?.frame.midY ?? 0, word?.frame.midY ?? -1, accuracy: 0.01, "centred on its word")
    }

    func testEmptySlotsDoNothingAndTheSlotUnderTheLiftedFingerCounts() {
        setUpBar(["ok", "okay"])
        tap(300) // the third slot is empty
        let t = UITouch()
        t.testLocation = CGPoint(x: 60, y: 22)
        bar.touchesBegan([t], with: UIEvent())
        t.testLocation = CGPoint(x: 200, y: 22) // slid onto the next word, like sliding between keys
        bar.touchesMoved([t], with: UIEvent())
        bar.touchesEnded([t], with: UIEvent())
        let away = UITouch()
        away.testLocation = CGPoint(x: 60, y: 22)
        bar.touchesBegan([away], with: UIEvent())
        away.testLocation = CGPoint(x: 60, y: 120) // dragged far down onto the keys: cancelled
        bar.touchesMoved([away], with: UIEvent())
        bar.touchesEnded([away], with: UIEvent())
        XCTAssertEqual(recorder.selected, ["okay"])
    }
}
