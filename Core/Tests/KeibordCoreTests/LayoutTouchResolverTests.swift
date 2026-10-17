import XCTest
@testable import KeibordCore

final class LayoutTouchResolverTests: XCTestCase {
    typealias S = LayoutTestSupport

    private let portrait = KeyboardMetrics.standard(height: .standard, landscape: false)

    private func make(_ r: LayoutRequest, width: CGFloat = 393, metrics: KeyboardMetrics? = nil,
                      offsets: [String: (dx: Double, dy: Double)] = [:]) -> (layout: KeyboardLayout, frames: [KeyFrame], resolver: TouchResolver) {
        let layout = LayoutFactory.layout(for: r)
        let frames = LayoutGeometry.frames(for: layout, width: width, metrics: metrics ?? portrait)
        return (layout, frames, TouchResolver(frames: frames, offsets: offsets, touchModelKey: layout.touchModelKey))
    }

    private func frame(_ frames: [KeyFrame], _ id: String) -> KeyFrame { frames.first { $0.key.id == id }! }
    private func centre(_ f: KeyFrame) -> CGPoint { CGPoint(x: f.rect.midX, y: f.rect.midY) }

    // MARK: Hit testing

    func testKeyCentresAndInteriorsHitTheirKey() {
        let requests = [
            LayoutRequest(language: .deAT, base: .qwertz, showNumberRow: true, showLanguageKey: true, showGlobeKey: true),
            LayoutRequest(language: .sqXK, base: .qwertz, variant: .email, showLanguageKey: true),
            LayoutRequest(language: .enUS, base: .qwerty, variant: .url),
            LayoutRequest(language: .itIT, base: .qwerty, page: .numbers, variant: .webSearch, showGlobeKey: true),
            LayoutRequest(language: .enGB, base: .qwerty, page: .symbols),
            LayoutRequest(language: .deAT, base: .qwertz, variant: .decimalPad),
            LayoutRequest(language: .deAT, base: .qwertz, variant: .numberPad, showGlobeKey: true),
        ]
        for r in requests {
            for (width, landscape) in [(CGFloat(320), false), (393, false), (440, false), (852, true)] {
                for height in KeyHeightOption.allCases {
                    let m = KeyboardMetrics.standard(height: height, landscape: landscape)
                    let (_, frames, resolver) = make(r, width: width, metrics: m)
                    for f in frames where f.key.isInteractive {
                        let inset = f.rect.insetBy(dx: min(1, f.rect.width / 4), dy: 1)
                        let points = [centre(f), CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                                      CGPoint(x: inset.minX, y: inset.maxY), CGPoint(x: inset.maxX, y: inset.maxY)]
                        for p in points {
                            let hit = resolver.resolve(p)
                            XCTAssertEqual(hit?.frameIndex, f.index, "\(S.describe(r)) \(width) \(height): \(p) inside \(f.key.id) hit \(hit.map { frames[$0.frameIndex].key.id } ?? "nil")")
                        }
                    }
                }
            }
        }
    }

    func testRandomInteriorPointsHitTheirKey() {
        var rng = SystemRandomNumberGenerator()
        for r in S.allRequests() where r.returnKind == .default && r.showNumberRow == (r.language == .deAT) {
            let (_, frames, resolver) = make(r, width: 375)
            for f in frames where f.key.isInteractive {
                for _ in 0..<3 {
                    let p = CGPoint(x: CGFloat.random(in: f.rect.minX + 0.5...f.rect.maxX - 0.5, using: &rng),
                                    y: CGFloat.random(in: f.rect.minY + 0.5...f.rect.maxY - 0.5, using: &rng))
                    XCTAssertEqual(resolver.resolve(p)?.frameIndex, f.index, "\(S.describe(r)) \(f.key.id) \(p)")
                }
            }
        }
    }

    func testHorizontalGapsGoToTheNearestKey() {
        let (_, frames, resolver) = make(LayoutRequest(language: .deAT, base: .qwertz))
        let rowKeys = frames.filter { $0.row == 0 }
        for (a, b) in zip(rowKeys, rowKeys.dropFirst()) {
            let y = a.rect.midY
            let mid = (a.rect.maxX + b.rect.minX) / 2
            XCTAssertEqual(resolver.resolve(CGPoint(x: mid - 0.5, y: y))?.frameIndex, a.index, "\(a.key.id)|\(b.key.id)")
            XCTAssertEqual(resolver.resolve(CGPoint(x: mid + 0.5, y: y))?.frameIndex, b.index, "\(a.key.id)|\(b.key.id)")
        }
        // The gap between shift and "y" (spacer) goes to whichever is closer.
        let shift = frame(frames, "shift"), y = frame(frames, "y")
        XCTAssertEqual(resolver.resolve(CGPoint(x: shift.rect.maxX + 1, y: shift.rect.midY))?.frameIndex, shift.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: y.rect.minX - 1, y: y.rect.midY))?.frameIndex, y.index)
        // Side margins of the centred Albanian home row go to the outer keys.
        let (_, sqFrames, sqResolver) = make(LayoutRequest(language: .sqAL, base: .qwertz))
        let a = frame(sqFrames, "a"), e = frame(sqFrames, "ë")
        XCTAssertEqual(sqResolver.resolve(CGPoint(x: 1, y: a.rect.midY))?.frameIndex, a.index)
        XCTAssertEqual(sqResolver.resolve(CGPoint(x: 392, y: e.rect.midY))?.frameIndex, e.index)
    }

    func testVerticalGapsGoToTheNearestRow() {
        let (_, frames, resolver) = make(LayoutRequest(language: .enUS, base: .qwerty))
        let e = frame(frames, "e"), d = frame(frames, "d"), c = frame(frames, "c"), space = frame(frames, "space")
        XCTAssertEqual(resolver.resolve(CGPoint(x: e.rect.midX, y: e.rect.maxY + 2))?.frameIndex, e.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: d.rect.midX, y: d.rect.minY - 2))?.frameIndex, d.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: c.rect.midX, y: c.rect.maxY + 2))?.frameIndex, c.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: c.rect.midX, y: space.rect.minY - 2))?.frameIndex, space.index,
                       "touches just above the space bar stay on the space bar")
    }

    func testTouchesOutsideTheKeyboardClampToTheEdgeRows() {
        let (_, frames, resolver) = make(LayoutRequest(language: .deAT, base: .qwertz, showLanguageKey: true))
        let t = frame(frames, "t"), space = frame(frames, "space"), q = frame(frames, "q"), ret = frame(frames, "return")
        let numbers = frame(frames, "numbers"), u = frame(frames, "ü")
        XCTAssertEqual(resolver.resolve(CGPoint(x: t.rect.midX, y: -30))?.frameIndex, t.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: space.rect.midX, y: 10_000))?.frameIndex, space.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: -20, y: -20))?.frameIndex, q.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: 500, y: -20))?.frameIndex, u.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: -20, y: 500))?.frameIndex, numbers.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: 500, y: 500))?.frameIndex, ret.index)
    }

    func testFunctionKeysAreNeverStolenByLetters() {
        let (_, frames, resolver) = make(LayoutRequest(language: .enUS, base: .qwerty))
        let shift = frame(frames, "shift"), backspace = frame(frames, "backspace")
        for f in [shift, backspace] {
            for p in [CGPoint(x: f.rect.midX, y: f.rect.minY + 1), CGPoint(x: f.rect.midX, y: f.rect.maxY - 1)] {
                let hit = resolver.resolve(p)
                XCTAssertEqual(hit?.frameIndex, f.index)
                XCTAssertEqual(hit?.tap.candidates, [], "function keys have no spatial candidates")
            }
        }
    }

    func testEmptyResolver() {
        XCTAssertNil(TouchResolver(frames: []).resolve(.zero))
        XCTAssertEqual(TouchResolver(frames: []).syntheticTap(for: "a"), .exact("a"))
    }

    // MARK: Learned offsets

    func testLearnedOffsetsShiftTheBoundary() {
        let r = LayoutRequest(language: .enUS, base: .qwerty)
        let (_, frames, plain) = make(r)
        let e = frame(frames, "e"), w = frame(frames, "w")
        // Just inside "e", half a point from its left edge.
        let p = CGPoint(x: e.rect.minX + 0.5, y: e.rect.midY)
        XCTAssertEqual(plain.resolve(p)?.frameIndex, e.index)
        // The user habitually hits "w" right of its centre (+0.25 key widths): the boundary moves
        // to halfway between the shifted "w" centre and the "e" centre, ≈ 1.2 pt inside "e".
        let (_, _, adapted) = make(r, offsets: ["w": (dx: 0.25, dy: 0)])
        XCTAssertEqual(adapted.resolve(p)?.frameIndex, w.index)
        XCTAssertEqual(adapted.resolve(CGPoint(x: e.rect.minX + 2, y: e.rect.midY))?.frameIndex, e.index)
        XCTAssertEqual(adapted.resolve(CGPoint(x: (w.rect.maxX + e.rect.minX) / 2 + 0.5, y: e.rect.midY))?.frameIndex, w.index,
                       "the gap now belongs to w")
        // The same habit on "e" (hitting it left of centre) cancels the shift.
        let (_, _, both) = make(r, offsets: ["w": (dx: 0.25, dy: 0), "e": (dx: -0.25, dy: 0)])
        XCTAssertEqual(both.resolve(p)?.frameIndex, e.index)
        // The key centre itself is never taken over by a neighbour.
        XCTAssertEqual(adapted.resolve(centre(e))?.frameIndex, e.index)
        // Vertical: hitting "s" high pulls the boundary to the row above.
        let s = frame(frames, "s")
        let q = CGPoint(x: s.rect.midX - s.rect.width * 0.3, y: frame(frames, "w").rect.maxY - 2)
        XCTAssertEqual(plain.resolve(q)?.frameIndex, frame(frames, "w").index)
        let (_, _, high) = make(r, offsets: ["s": (dx: 0, dy: -0.25), "w": (dx: 0, dy: -0.25)])
        XCTAssertEqual(high.resolve(q)?.frameIndex, s.index)
    }

    func testOffsetsAreClampedAndSanitised() {
        let r = LayoutRequest(language: .enUS, base: .qwerty)
        let (_, frames, huge) = make(r, offsets: ["d": (dx: 50, dy: -50), "f": (dx: .infinity, dy: .nan), "g": (dx: .nan, dy: .nan)])
        XCTAssertEqual(huge.offsets["d"]?.dx, 0.25)
        XCTAssertEqual(huge.offsets["d"]?.dy, -0.25)
        XCTAssertEqual(huge.offsets["f"]?.dx, 0.25)
        XCTAssertEqual(huge.offsets["f"]?.dy, 0, "NaN offsets are ignored, not pinned to −0.25")
        XCTAssertEqual(huge.offsets["g"]?.dx, 0)
        // A huge offset can't make "d" steal the centre of a neighbouring key.
        for id in ["s", "e", "r", "f", "x", "c"] {
            XCTAssertEqual(huge.resolve(centre(frame(frames, id)))?.frameIndex, frame(frames, id).index, id)
        }
        let (_, _, quarter) = make(r, offsets: ["d": (dx: 0.25, dy: -0.25), "f": (dx: 0.25, dy: 0), "g": (dx: 0, dy: 0)])
        let f = frame(frames, "f")
        for dx in stride(from: -0.5, through: 0.5, by: 0.1) {
            let p = CGPoint(x: f.rect.midX + CGFloat(dx) * f.rect.width, y: f.rect.minY + 1)
            XCTAssertEqual(huge.resolve(p)?.frameIndex, quarter.resolve(p)?.frameIndex, "clamped like ±0.25")
        }
    }

    // MARK: Candidates

    func testHitKeyComesFirstWithZeroCostAndRawOffsets() {
        let r = LayoutRequest(language: .deAT, base: .qwertz)
        let offsets: [String: (dx: Double, dy: Double)] = ["g": (dx: 0.2, dy: 0.1), "h": (dx: -0.1, dy: 0.2), "t": (dx: 0, dy: -0.2)]
        let (_, frames, resolver) = make(r, offsets: offsets)
        let g = frame(frames, "g")
        let p = CGPoint(x: g.rect.midX + 4, y: g.rect.midY - 6)
        let hit = resolver.resolve(p)!
        XCTAssertEqual(frames[hit.frameIndex].key.id, "g")
        let tap = hit.tap
        XCTAssertEqual(tap.primary, "g")
        XCTAssertEqual(tap.candidates[0].cost, 0)
        XCTAssertEqual(tap.touchModelKey, "qwertz11.letters.standard")
        // dx/dy are relative to the raw key centre (the learned offset is not subtracted).
        XCTAssertEqual(tap.candidates[0].dx, 4 / Double(g.rect.width), accuracy: 1e-9)
        XCTAssertEqual(tap.candidates[0].dy, -6 / Double(g.rect.height), accuracy: 1e-9)
        for c in tap.candidates.dropFirst() {
            let f = frame(frames, c.character)
            XCTAssertTrue(f.key.isLetter)
            XCTAssertEqual(c.dx, Double((p.x - f.rect.midX) / f.rect.width), accuracy: 1e-9, c.character)
            XCTAssertEqual(c.dy, Double((p.y - f.rect.midY) / f.rect.height), accuracy: 1e-9, c.character)
            XCTAssertGreaterThan(c.cost, 0, c.character)
        }
        // Sorted by cost; every candidate is a distinct letter.
        XCTAssertEqual(tap.candidates.map { $0.cost }, tap.candidates.map { $0.cost }.sorted())
        XCTAssertEqual(Set(tap.candidates.map { $0.character }).count, tap.candidates.count)
        // Plausible neighbours of "g" on the German 11-unit QWERTZ layout: the top and home rows are
        // not staggered (t sits above g, c below it), so v/b are diagonal and out of range.
        let chars = Set(tap.candidates.map { $0.character })
        XCTAssertEqual(chars, ["g", "f", "h", "t", "z", "c"])
        XCTAssertEqual(tap.candidates[1].character, "h", "touch right of centre → h is the cheapest alternative")
        // On staggered QWERTY the same touch also reaches y (above-right) and v (below).
        let (_, enFrames, en) = make(LayoutRequest(language: .enUS, base: .qwerty), offsets: offsets)
        let enG = frame(enFrames, "g")
        let enTap = en.resolve(CGPoint(x: enG.rect.midX + 4, y: enG.rect.midY - 6))!.tap
        XCTAssertEqual(enTap.primary, "g")
        XCTAssertEqual(enTap.touchModelKey, "qwerty10.letters.standard")
        XCTAssertEqual(Set(enTap.candidates.map { $0.character }), ["g", "f", "h", "t", "y", "v"])
    }

    func testCandidateCostsGrowWithDistance() {
        let (_, frames, resolver) = make(LayoutRequest(language: .enUS, base: .qwerty))
        let f = frame(frames, "f"), g = frame(frames, "g"), d = frame(frames, "d")
        var lastG = Double.infinity, lastD = -1.0
        // Walk across "f" from left to right (staying where both neighbours are within the
        // 1.6-key candidate radius): "g" gets cheaper, "d" more expensive.
        for step in 0...10 {
            let x = f.rect.midX + CGFloat(-0.4 + 0.08 * Double(step)) * f.rect.width
            let tap = resolver.resolve(CGPoint(x: x, y: f.rect.midY))!.tap
            XCTAssertEqual(tap.primary, "f")
            let gCost = tap.candidates.first { $0.character == "g" }!.cost
            let dCost = tap.candidates.first { $0.character == "d" }!.cost
            if step > 0 {
                XCTAssertLessThan(gCost, lastG, "g cheaper as the touch approaches it")
                XCTAssertGreaterThan(dCost, lastD, "d dearer as the touch moves away")
            }
            lastG = gCost; lastD = dCost
            XCTAssertGreaterThan(gCost, 0)
            XCTAssertGreaterThan(dCost, 0)
        }
        // At the very centre, the cost of a same-row neighbour is 2.5·d²·log2(e) bits.
        let tap = resolver.resolve(centre(f))!.tap
        let dist = Double((g.rect.midX - f.rect.midX) / f.rect.width)
        XCTAssertEqual(tap.candidates.first { $0.character == "g" }!.cost, 2.5 * dist * dist * 1.4426950408889634, accuracy: 1e-6)
        XCTAssertEqual(tap.candidates.first { $0.character == "d" }!.cost, tap.candidates.first { $0.character == "g" }!.cost, accuracy: 1e-6)
        _ = d
    }

    func testHitIsFirstEvenOnExactTies() {
        // A point exactly between the adjusted centres of two letters: both have the same distance.
        let (_, frames, resolver) = make(LayoutRequest(language: .enUS, base: .qwerty))
        let f = frame(frames, "f"), g = frame(frames, "g")
        let p = CGPoint(x: (f.rect.maxX + g.rect.minX) / 2, y: f.rect.midY)
        let hit = resolver.resolve(p)!
        XCTAssertEqual(hit.tap.primary, frames[hit.frameIndex].key.id)
        XCTAssertEqual(hit.tap.candidates[0].cost, 0)
        let other = hit.tap.candidates.first { $0.character == (hit.tap.primary == "f" ? "g" : "f") }
        XCTAssertEqual(other?.cost ?? -1, 0, accuracy: 1e-9)
    }

    func testSyntheticTap() {
        for (language, base) in [(KeyboardLanguage.deAT, BaseLayout.qwertz), (.enUS, .qwerty), (.sqAL, .qwertz), (.itIT, .qwerty)] {
            let (layout, frames, resolver) = make(LayoutRequest(language: language, base: base))
            for key in layout.allKeys where key.isLetter {
                let tap = resolver.syntheticTap(for: key.id.uppercased())
                XCTAssertEqual(tap.primary, key.id, "\(language) \(key.id)")
                XCTAssertEqual(tap.candidates[0].cost, 0)
                XCTAssertEqual(tap.candidates[0].dx, 0, accuracy: 1e-9)
                XCTAssertEqual(tap.candidates[0].dy, 0, accuracy: 1e-9)
                XCTAssertEqual(tap.touchModelKey, layout.touchModelKey)
                XCTAssertGreaterThanOrEqual(tap.candidates.count, 3, "\(language) \(key.id) has neighbours")
                // Same-row neighbours are the cheapest alternatives.
                let f = frame(frames, key.id)
                let sameRow = frames.filter { $0.row == f.row && $0.key.isLetter && abs($0.index - f.index) == 1 }.map { $0.key.id }
                for n in sameRow { XCTAssertTrue(tap.candidates.contains { $0.character == n }, "\(key.id)→\(n)") }
                if let second = tap.candidates.dropFirst().first {
                    XCTAssertTrue(sameRow.contains(second.character), "\(key.id): cheapest alternative \(second.character)")
                    XCTAssertGreaterThan(second.cost, 3)
                }
            }
        }
        let (_, _, resolver) = make(LayoutRequest(language: .deAT, base: .qwertz))
        // German: w directly above s; e and y (under d) are diagonal, 1.74 key sizes away.
        XCTAssertEqual(Set(resolver.syntheticTap(for: "s").candidates.map { $0.character }), ["s", "a", "d", "w"])
        // QWERTY: the home row is staggered by half a key, z sits directly under s.
        let (_, _, en) = make(LayoutRequest(language: .enUS, base: .qwerty))
        XCTAssertEqual(Set(en.syntheticTap(for: "s").candidates.map { $0.character }), ["s", "a", "d", "w", "e", "z"])
        XCTAssertEqual(resolver.syntheticTap(for: "ß"), .exact("ß"))
        XCTAssertEqual(resolver.syntheticTap(for: "1"), .exact("1"))
        XCTAssertEqual(resolver.syntheticTap(for: "Ä").primary, "ä")
    }

    func testSyntheticTapWithOffsetsKeepsKeyFirst() {
        let offsets: [String: (dx: Double, dy: Double)] = ["e": (dx: 0.25, dy: 0.25), "w": (dx: 0.25, dy: 0), "r": (dx: -0.25, dy: 0), "d": (dx: 0, dy: -0.25)]
        let (_, _, resolver) = make(LayoutRequest(language: .enUS, base: .qwerty), width: 852,
                                    metrics: KeyboardMetrics.standard(height: .compact, landscape: true), offsets: offsets)
        let tap = resolver.syntheticTap(for: "e")
        XCTAssertEqual(tap.primary, "e")
        XCTAssertEqual(tap.candidates[0].cost, 0)
        XCTAssertTrue(tap.candidates.dropFirst().allSatisfy { $0.cost > 0 })
    }

    func testNonLetterKeysProduceSensibleTaps() {
        let (_, frames, resolver) = make(LayoutRequest(language: .deAT, base: .qwertz, variant: .url, showNumberRow: true))
        for id in ["1", "0", ".", "/"] {
            let tap = resolver.resolve(centre(frame(frames, id)))!.tap
            XCTAssertEqual(tap.candidates.map { $0.character }, [id])
            XCTAssertEqual(tap.candidates[0].cost, 0)
        }
        XCTAssertEqual(resolver.resolve(centre(frame(frames, "dotcom")))!.tap.primary, ".com")
        for id in ["shift", "backspace", "numbers", "emoji", "return"] {
            let hit = resolver.resolve(centre(frame(frames, id)))!
            XCTAssertEqual(frames[hit.frameIndex].key.id, id)
            XCTAssertTrue(hit.tap.candidates.isEmpty, id)
        }
        // Touches at the top of the first letter row never resolve to a digit of the number row and vice versa.
        let q = frame(frames, "q"), one = frame(frames, "1")
        XCTAssertEqual(resolver.resolve(CGPoint(x: q.rect.midX, y: q.rect.minY + 1))?.frameIndex, q.index)
        XCTAssertEqual(resolver.resolve(CGPoint(x: one.rect.midX, y: one.rect.maxY - 1))?.frameIndex, one.index)
        // Number pad.
        let (_, padFrames, pad) = make(LayoutRequest(language: .deAT, base: .qwertz, variant: .decimalPad))
        XCTAssertEqual(pad.resolve(centre(frame(padFrames, ",")))!.tap.primary, ",")
        XCTAssertEqual(pad.resolve(centre(frame(padFrames, "5")))!.tap.primary, "5")
        // The empty corner of the number pad (spacer) goes to the nearest real key.
        let (_, nFrames, n) = make(LayoutRequest(language: .deAT, base: .qwertz, variant: .numberPad))
        let spacer = frame(nFrames, "spacer.0")
        XCTAssertEqual(n.resolve(centre(spacer))?.frameIndex, frame(nFrames, "0").index)
    }
}
