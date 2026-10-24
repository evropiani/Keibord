import XCTest
@testable import KeibordCore

final class LayoutGeometryTests: XCTestCase {
    typealias S = LayoutTestSupport

    static let portraitWidths: [CGFloat] = [320, 375, 393, 402, 430, 440]
    static let landscapeWidths: [CGFloat] = [667, 852, 932]
    static let eps: CGFloat = 0.001

    // MARK: Metrics

    func testMetricsPresets() {
        for landscape in [false, true] {
            var previousPitch: CGFloat = 0
            for height in [KeyHeightOption.compact, .standard, .tall] {
                let m = KeyboardMetrics.standard(height: height, landscape: landscape)
                XCTAssertGreaterThan(m.rowPitch, previousPitch, "pitch grows compact → standard → tall")
                previousPitch = m.rowPitch
                XCTAssertGreaterThan(m.keyHeight, 0)
                XCTAssertLessThan(m.keyHeight, m.rowPitch)
                XCTAssertGreaterThan(m.horizontalGap, 0)
                XCTAssertGreaterThanOrEqual(m.sideInset, 0)
                XCTAssertEqual(m.keyboardHeight(rows: 4), m.topInset + 4 * m.rowPitch + m.bottomInset)
                XCTAssertEqual(LayoutGeometry.totalHeight(rows: 5, metrics: m), m.keyboardHeight(rows: 5))
            }
        }
        // iOS proportions: portrait row pitch ≈ 54 pt with ≈ 43 pt keys; landscape ≈ 40 / 32.
        let portrait = KeyboardMetrics.standard(height: .standard, landscape: false)
        XCTAssertEqual(portrait.rowPitch, 54)
        XCTAssertEqual(portrait.keyHeight, 43)
        XCTAssertEqual(portrait.horizontalGap, 6)
        let landscape = KeyboardMetrics.standard(height: .standard, landscape: true)
        XCTAssertEqual(landscape.rowPitch, 40)
        XCTAssertEqual(landscape.keyHeight, 32)
        XCTAssertEqual(KeyboardMetrics.standard(height: .compact, landscape: false).rowPitch, 50)
        XCTAssertEqual(KeyboardMetrics.standard(height: .tall, landscape: false).rowPitch, 59)
    }

    /// The system may keep the keyboard lower than requested (iOS 27 kept its default height): the rows
    /// then shrink so every row stays inside the key area.
    func testMetricsFittedIntoALowerKeyArea() {
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        XCTAssertEqual(m.fitted(toHeight: m.keyboardHeight(rows: 4), rows: 4), m)
        XCTAssertEqual(m.fitted(toHeight: 400, rows: 4), m, "more room than needed: unchanged")
        XCTAssertEqual(m.fitted(toHeight: 0, rows: 4), m, "height not known yet")
        // iOS's 241 pt keyboard minus the suggestion bar: the row gaps give way, the keys keep their height.
        let slightly = m.fitted(toHeight: 205, rows: 4)
        XCTAssertEqual(slightly.keyboardHeight(rows: 4), 205, accuracy: 0.001)
        XCTAssertEqual(slightly.keyHeight, m.keyHeight)
        XCTAssertGreaterThanOrEqual(slightly.rowPitch - slightly.keyHeight, KeyboardMetrics.minimumRowGap)
        // Five rows in the same room: gaps at their minimum, then the keys get lower.
        let five = m.fitted(toHeight: 205, rows: 5)
        XCTAssertEqual(five.keyboardHeight(rows: 5), 205, accuracy: 0.001)
        XCTAssertEqual(five.rowPitch - five.keyHeight, KeyboardMetrics.minimumRowGap, accuracy: 0.001)
        XCTAssertLessThan(five.keyHeight, m.keyHeight)
        let fitted = m.fitted(toHeight: 180, rows: 4)
        XCTAssertEqual(fitted.keyboardHeight(rows: 4), 180, accuracy: 0.001)
        XCTAssertEqual(fitted.horizontalGap, m.horizontalGap)
        XCTAssertGreaterThan(m.fitted(toHeight: 20, rows: 4).keyHeight, 0, "never negative")
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz, page: .letters, variant: .standard,
                                                             showNumberRow: false, showLanguageKey: true, showGlobeKey: false, returnKind: .default))
        let frames = LayoutGeometry.frames(for: layout, width: 440, metrics: fitted)
        XCTAssertLessThanOrEqual(frames.map(\.rect.maxY).max() ?? 0, 180)
    }

    // MARK: Invariants for every combination

    func testFramesForEveryCombinationWidthAndHeight() {
        let requests = S.allRequests()
        for landscape in [false, true] {
            let widths = landscape ? Self.landscapeWidths : Self.portraitWidths
            for height in KeyHeightOption.allCases {
                let m = KeyboardMetrics.standard(height: height, landscape: landscape)
                for width in widths {
                    for r in requests {
                        let layout = LayoutFactory.layout(for: r)
                        checkFrames(layout, width: width, metrics: m, what: "\(S.describe(r)) width=\(width) \(height)")
                    }
                }
            }
        }
    }

    private func checkFrames(_ layout: KeyboardLayout, width: CGFloat, metrics m: KeyboardMetrics, what: String, file: StaticString = #filePath, line: UInt = #line) {
        let frames = LayoutGeometry.frames(for: layout, width: width, metrics: m)
        let keyCount = layout.rows.reduce(0) { $0 + $1.keys.count }
        guard frames.count == keyCount else {
            return XCTFail("\(what): \(frames.count) frames for \(keyCount) keys", file: file, line: line)
        }
        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }

        let height = m.keyboardHeight(rows: layout.rows.count)
        let letterWidths = frames.filter { $0.key.isLetter }.map { $0.rect.width }
        let letterWidth = letterWidths.first ?? 0
        for (i, f) in frames.enumerated() {
            check(f.index == i, "index \(f.index) at \(i)")
            check(f.rect.width >= 0, "\(f.key.id) negative width \(f.rect.width)")
            check(f.rect.minX >= -Self.eps && f.rect.maxX <= width + Self.eps, "\(f.key.id) outside [0, \(width)]: \(f.rect)")
            check(f.rect.minY >= 0 && f.rect.maxY <= height + Self.eps, "\(f.key.id) outside height \(height): \(f.rect)")
            check(abs(f.rect.height - m.keyHeight) < Self.eps, "\(f.key.id) height \(f.rect.height)")
            let expectedY = m.topInset + CGFloat(f.row) * m.rowPitch + (m.rowPitch - m.keyHeight) / 2
            check(abs(f.rect.minY - expectedY) < Self.eps, "\(f.key.id) y \(f.rect.minY) ≠ \(expectedY)")
            if f.key.isInteractive {
                check(f.rect.width > 1, "\(f.key.id) collapsed to \(f.rect.width)")
            }
        }
        // Rows in order, keys left to right without overlaps (at least the horizontal gap apart).
        for row in 0..<layout.rows.count {
            let inRow = frames.filter { $0.row == row }
            check(inRow.count == layout.rows[row].keys.count, "row \(row) count")
            for (a, b) in zip(inRow, inRow.dropFirst()) {
                check(a.rect.maxX <= b.rect.minX + Self.eps, "\(a.key.id) overlaps \(b.key.id): \(a.rect) \(b.rect)")
                check(b.rect.minX - a.rect.maxX >= m.horizontalGap - Self.eps || a.key.style == .spacer || b.key.style == .spacer,
                      "\(a.key.id)–\(b.key.id) gap \(b.rect.minX - a.rect.maxX)")
            }
        }
        // Letter keys: equal width everywhere (within and across rows).
        for w in letterWidths { check(abs(w - letterWidth) < Self.eps, "letter widths differ: \(w) vs \(letterWidth)") }

        if layout.unitCount != 3 {
            // Every interactive key is at least ~0.85 of a letter (one 10-unit) key wide.
            let unitWidth = (width - 2 * m.sideInset - CGFloat(layout.unitCount - 1) * m.horizontalGap) / CGFloat(layout.unitCount)
            for f in frames where f.key.isInteractive {
                check(f.rect.width >= 0.85 * unitWidth - Self.eps, "\(f.key.id) only \(f.rect.width) wide (unit \(unitWidth))")
            }
            if layout.page == .letters {
                check(abs(letterWidth - unitWidth) < Self.eps, "letter \(letterWidth) ≠ unit \(unitWidth)")
                // The space bar keeps at least 3.5 letter widths, even with language + globe keys.
                if let space = frames.first(where: { $0.key.id == "space" }) {
                    check(space.rect.width >= 3.5 * letterWidth - Self.eps, "space \(space.rect.width) < 3.5 × \(letterWidth)")
                }
                // Shift / backspace roughly iOS-sized: 1.25–1.6 letter widths.
                for id in ["shift", "backspace"] {
                    let f = frames.first { $0.key.id == id }!
                    check(f.rect.width >= 1.25 * letterWidth && f.rect.width <= 1.6 * letterWidth, "\(id) \(f.rect.width) vs letter \(letterWidth)")
                }
            }
            if let dotcom = frames.first(where: { $0.key.id == "dotcom" }) {
                check(dotcom.rect.width >= 1.5 * unitWidth, "dotcom \(dotcom.rect.width)")
            }
        }
        if !failures.isEmpty {
            XCTFail("\(what): " + failures.prefix(5).joined(separator: "; "), file: file, line: line)
        }
    }

    // MARK: iOS proportions

    func testIPhone393PortraitProportions() {
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .enUS, base: .qwerty))
        let frames = LayoutGeometry.frames(for: layout, width: 393, metrics: m)
        func f(_ id: String) -> CGRect { frames.first { $0.key.id == id }!.rect }
        XCTAssertEqual(f("q").width, 33.3, accuracy: 0.5, "QWERTY letter ≈ 33 pt")
        XCTAssertEqual(f("a").minY - f("q").minY, 54, accuracy: 0.01, "row pitch ≈ 54 pt")
        XCTAssertEqual(f("q").height, 43, accuracy: 0.01)
        XCTAssertEqual(f("q").minX, 3, accuracy: 0.01)
        XCTAssertEqual(f("p").maxX, 390, accuracy: 0.01)
        // Home row centred: "a" starts half a key in; "z" sits under "s".
        XCTAssertEqual(f("a").minX, f("q").midX + 3, accuracy: 0.01)
        XCTAssertEqual(f("z").minX, f("s").minX, accuracy: 0.01)
        XCTAssertEqual(f("m").maxX, f("k").maxX, accuracy: 0.01)
        XCTAssertEqual(f("shift").width, 44, accuracy: 2.5)
        XCTAssertEqual(f("backspace").width, f("shift").width, accuracy: 0.01)
        XCTAssertEqual(f("numbers").width, 42, accuracy: 3)
        XCTAssertEqual(f("return").width, 87, accuracy: 4)
        XCTAssertEqual(f("space").width, 190, accuracy: 8)
        XCTAssertEqual(f("return").maxX, 390, accuracy: 0.01)
        XCTAssertEqual(f("numbers").minX, 3, accuracy: 0.01)
    }

    func testGerman11UnitProportions() {
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz, showNumberRow: true))
        let frames = LayoutGeometry.frames(for: layout, width: 393, metrics: m)
        func f(_ id: String) -> CGRect { frames.first { $0.key.id == id }!.rect }
        XCTAssertEqual(f("q").width, (387 - 60) / 11, accuracy: 0.01)
        XCTAssertEqual(f("ü").maxX, 390, accuracy: 0.01)
        XCTAssertEqual(f("ä").maxX, 390, accuracy: 0.01)
        XCTAssertEqual(f("a").minX, 3, accuracy: 0.01)
        // The number row spans the full width too.
        XCTAssertEqual(f("1").minX, 3, accuracy: 0.01)
        XCTAssertEqual(f("0").maxX, 390, accuracy: 0.01)
        // Shift keeps (about) the same physical size as on the 10-unit layout.
        let en = LayoutGeometry.frames(for: LayoutFactory.layout(for: LayoutRequest(language: .enUS, base: .qwerty)), width: 393, metrics: m)
        let enShift = en.first { $0.key.id == "shift" }!.rect.width
        XCTAssertEqual(f("shift").width, enShift, accuracy: 2)
        // Albanian home row (10 letters) is centred in the 11-unit grid.
        let sq = LayoutGeometry.frames(for: LayoutFactory.layout(for: LayoutRequest(language: .sqXK, base: .qwertz)), width: 393, metrics: m)
        let a = sq.first { $0.key.id == "a" }!.rect, e = sq.first { $0.key.id == "ë" }!.rect
        XCTAssertEqual(a.minX - 3, 390 - e.maxX, accuracy: 0.01)
    }

    func testNumberPadGeometry() {
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        let pad = LayoutFactory.layout(for: LayoutRequest(language: .deAT, base: .qwertz, variant: .decimalPad))
        let frames = LayoutGeometry.frames(for: pad, width: 393, metrics: m)
        XCTAssertEqual(frames.count, 12)
        let w = (393 - 6 - 12) / CGFloat(3)
        for f in frames { XCTAssertEqual(f.rect.width, w, accuracy: 0.01) }
        XCTAssertEqual(frames[0].rect.minX, 3, accuracy: 0.01)
        XCTAssertEqual(frames[2].rect.maxX, 390, accuracy: 0.01)
    }

    // MARK: Robustness

    func testOverfullRowIsShrunkToFit() {
        // Fixed keys need 14 units in a 10-unit layout: the row must still fit into the width.
        let wide = (0..<7).map { KeySpec(id: "k\($0)", action: .insert("\($0)"), label: "\($0)", width: .units(2), style: .character) }
        let spacer = KeySpec(id: "spacer.0", action: .none, label: "", width: .fill, style: .spacer)
        let layout = KeyboardLayout(language: .enUS, page: .letters, variant: .standard,
                                    rows: [KeyRow(keys: wide), KeyRow(keys: [wide[0], spacer, wide[1]])], unitCount: 10)
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        for width in [CGFloat(320), 393, 852] {
            let frames = LayoutGeometry.frames(for: layout, width: width, metrics: m)
            let row0 = frames.filter { $0.row == 0 }
            XCTAssertEqual(row0.first!.rect.minX, m.sideInset, accuracy: 0.01)
            XCTAssertEqual(row0.last!.rect.maxX, width - m.sideInset, accuracy: 0.01)
            for (a, b) in zip(row0, row0.dropFirst()) {
                XCTAssertEqual(b.rect.minX - a.rect.maxX, m.horizontalGap, accuracy: 0.01)
                XCTAssertEqual(a.rect.width, b.rect.width, accuracy: 0.01, "proportions kept")
            }
        }
    }

    func testDegenerateWidthsNeverProduceNegativeOrOutOfBoundsFrames() {
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        for width in [CGFloat(0), 1, 10, 50, 120, 200] {
            for r in [LayoutRequest(language: .deAT, base: .qwertz, showNumberRow: true, showLanguageKey: true, showGlobeKey: true),
                      LayoutRequest(language: .enUS, base: .qwerty, page: .numbers, variant: .email, showLanguageKey: true, showGlobeKey: true),
                      LayoutRequest(language: .itIT, base: .qwerty, variant: .numberPad, showGlobeKey: true)] {
                let frames = LayoutGeometry.frames(for: LayoutFactory.layout(for: r), width: width, metrics: m)
                for f in frames {
                    XCTAssertGreaterThanOrEqual(f.rect.width, 0, "\(width) \(f.key.id)")
                    XCTAssertGreaterThanOrEqual(f.rect.minX, -Self.eps, "\(width) \(f.key.id)")
                    XCTAssertLessThanOrEqual(f.rect.maxX, max(width, 0) + Self.eps, "\(width) \(f.key.id)")
                    XCTAssertFalse(f.rect.minX.isNaN || f.rect.width.isNaN)
                }
            }
        }
    }

    func testCentredRowWithoutFillKeys() {
        let m = KeyboardMetrics.standard(height: .standard, landscape: false)
        let layout = LayoutFactory.layout(for: LayoutRequest(language: .enGB, base: .qwerty))
        let frames = LayoutGeometry.frames(for: layout, width: 375, metrics: m)
        let home = frames.filter { $0.row == 1 }
        XCTAssertEqual(home.first!.rect.minX - 0, 375 - home.last!.rect.maxX, accuracy: 0.01)
    }
}
