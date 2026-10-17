import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Vertical/horizontal spacing of the key area.
public struct KeyboardMetrics: Hashable, Sendable {
    /// Distance between the tops of two rows (key height + vertical gap).
    public var rowPitch: CGFloat
    public var keyHeight: CGFloat
    public var horizontalGap: CGFloat
    public var sideInset: CGFloat
    public var topInset: CGFloat
    public var bottomInset: CGFloat

    public init(rowPitch: CGFloat, keyHeight: CGFloat, horizontalGap: CGFloat, sideInset: CGFloat, topInset: CGFloat, bottomInset: CGFloat) {
        self.rowPitch = rowPitch
        self.keyHeight = keyHeight
        self.horizontalGap = horizontalGap
        self.sideInset = sideInset
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    public static func standard(height: KeyHeightOption, landscape: Bool) -> KeyboardMetrics {
        if landscape {
            let pitch: CGFloat = height == .compact ? 37 : (height == .tall ? 43 : 40)
            return KeyboardMetrics(rowPitch: pitch, keyHeight: pitch - 8, horizontalGap: 6, sideInset: 3, topInset: 3, bottomInset: 2)
        }
        let pitch: CGFloat = height == .compact ? 50 : (height == .tall ? 59 : 54)
        return KeyboardMetrics(rowPitch: pitch, keyHeight: pitch - 11, horizontalGap: 6, sideInset: 3, topInset: 4, bottomInset: 4)
    }

    /// Height of the key area (without the suggestion bar).
    public func keyboardHeight(rows: Int) -> CGFloat {
        topInset + rowPitch * CGFloat(rows) + bottomInset
    }
}

public struct KeyFrame {
    public var key: KeySpec
    public var rect: CGRect
    public var row: Int
    public var index: Int

    public init(key: KeySpec, rect: CGRect, row: Int, index: Int) {
        self.key = key
        self.rect = rect
        self.row = row
        self.index = index
    }
}

public enum LayoutGeometry {
    /// Frames of all keys (spacers included) in reading order; `KeyFrame.index` is the array index.
    ///
    /// Every frame lies within `[0, width]`. A row whose fixed keys do not fit (only possible for
    /// hand-built layouts or tiny widths) is shrunk proportionally instead of overflowing, and
    /// when even the gaps do not fit they shrink too, so frames never get negative widths.
    public static func frames(for layout: KeyboardLayout, width: CGFloat, metrics m: KeyboardMetrics) -> [KeyFrame] {
        var frames: [KeyFrame] = []
        let width = width.isFinite ? max(0, width) : 0
        let side = min(max(0, m.sideInset), width / 2)
        let available = width - 2 * side
        let gap = max(0, m.horizontalGap)
        let units = CGFloat(max(layout.unitCount, 1))
        let unit = max(0, (available - (units - 1) * gap) / units)
        for (rowIndex, row) in layout.rows.enumerated() {
            let y = m.topInset + CGFloat(rowIndex) * m.rowPitch + (m.rowPitch - m.keyHeight) / 2
            var widths: [CGFloat] = []
            var fills = 0
            for key in row.keys {
                switch key.width {
                case .units(let u):
                    let u = CGFloat(u.isFinite ? max(0, u) : 0)
                    widths.append(u * unit + max(0, u - 1) * gap)
                case .fill:
                    widths.append(0)
                    fills += 1
                }
            }
            var rowGap = gap
            var gaps = CGFloat(max(0, row.keys.count - 1)) * rowGap
            let fixed = widths.reduce(0, +)
            var x = side
            if fixed + gaps > available {
                // Overfull: shrink the fixed keys (keeping their proportions); fill keys get nothing.
                if gaps >= available {
                    rowGap = row.keys.count > 1 ? available / CGFloat(row.keys.count - 1) : 0
                    gaps = available
                }
                let scale = fixed > 0 ? max(0, available - gaps) / fixed : 0
                widths = widths.map { $0 * scale }
            } else if fills > 0 {
                let each = (available - fixed - gaps) / CGFloat(fills)
                for (i, key) in row.keys.enumerated() where key.width == .fill { widths[i] = each }
            } else {
                x += (available - fixed - gaps) / 2
            }
            for (i, key) in row.keys.enumerated() {
                let rect = CGRect(x: x, y: y, width: widths[i], height: m.keyHeight)
                frames.append(KeyFrame(key: key, rect: rect, row: rowIndex, index: frames.count))
                x += widths[i] + rowGap
            }
        }
        return frames
    }

    public static func totalHeight(rows: Int, metrics: KeyboardMetrics) -> CGFloat {
        metrics.keyboardHeight(rows: rows)
    }
}

/// Maps touch points to keys, using learned per-key offsets, and produces spatial `TapInput`s.
public struct TouchResolver {
    public let frames: [KeyFrame]
    public let offsets: [String: (dx: Double, dy: Double)]
    public let touchModelKey: String
    private let rowBands: [(row: Int, minY: CGFloat, maxY: CGFloat)]

    public init(frames: [KeyFrame], offsets: [String: (dx: Double, dy: Double)] = [:], touchModelKey: String = "") {
        self.frames = frames
        self.offsets = offsets.mapValues { (dx: Self.clampOffset($0.dx), dy: Self.clampOffset($0.dy)) }
        self.touchModelKey = touchModelKey
        var bands: [Int: (CGFloat, CGFloat)] = [:]
        for f in frames {
            let b = bands[f.row] ?? (f.rect.minY, f.rect.maxY)
            bands[f.row] = (min(b.0, f.rect.minY), max(b.1, f.rect.maxY))
        }
        rowBands = bands.keys.sorted().map { (row: $0, minY: bands[$0]!.0, maxY: bands[$0]!.1) }
    }

    /// Learned offsets are clamped to ±0.25 key sizes; NaN (corrupt statistics) counts as no offset.
    static func clampOffset(_ value: Double) -> Double {
        value.isNaN ? 0 : min(0.25, max(-0.25, value))
    }

    private func isLetter(_ f: KeyFrame) -> Bool { f.key.style == .character && f.key.isLetter }

    private func normalizedDistance(_ p: CGPoint, _ f: KeyFrame, adjusted: Bool) -> (d: Double, dx: Double, dy: Double) {
        let w = Double(max(f.rect.width, 1)), h = Double(max(f.rect.height, 1))
        var cx = Double(f.rect.midX), cy = Double(f.rect.midY)
        let rawDX = (Double(p.x) - cx) / w, rawDY = (Double(p.y) - cy) / h
        if adjusted, let o = offsets[f.key.id] {
            cx += o.dx * w
            cy += o.dy * h
        }
        let ndx = (Double(p.x) - cx) / w, ndy = (Double(p.y) - cy) / h
        return ((ndx * ndx + ndy * ndy).squareRoot(), rawDX, rawDY)
    }

    public func resolve(_ point: CGPoint) -> (frameIndex: Int, tap: TapInput)? {
        guard !rowBands.isEmpty else { return nil }
        // Row: the band containing y (gaps split halfway), clamped to the first/last row.
        var row = rowBands[0].row
        for (i, band) in rowBands.enumerated() {
            let lower = i + 1 < rowBands.count ? (band.maxY + rowBands[i + 1].minY) / 2 : .greatestFiniteMagnitude
            row = band.row
            if point.y < lower { break }
        }
        let inRow = frames.filter { $0.row == row && $0.key.isInteractive }
        guard !inRow.isEmpty else { return nil }
        var hit = inRow.min { a, b in
            horizontalDistance(point.x, a.rect) < horizontalDistance(point.x, b.rect)
        }!
        if isLetter(hit) {
            // Re-decide among nearby letters with the learned offsets (may switch to an adjacent row).
            let letters = frames.filter { isLetter($0) && abs($0.row - row) <= 1 }
            if let best = letters.min(by: { normalizedDistance(point, $0, adjusted: true).d < normalizedDistance(point, $1, adjusted: true).d }),
               normalizedDistance(point, best, adjusted: true).d < normalizedDistance(point, hit, adjusted: true).d {
                hit = best
            }
        }
        return (hit.index, tap(at: point, hit: hit))
    }

    private func horizontalDistance(_ x: CGFloat, _ r: CGRect) -> CGFloat {
        if x < r.minX { return r.minX - x }
        if x > r.maxX { return x - r.maxX }
        return 0
    }

    private func tap(at point: CGPoint, hit: KeyFrame) -> TapInput {
        guard isLetter(hit) else {
            if hit.key.style == .character, case .insert(let text) = hit.key.action {
                let d = normalizedDistance(point, hit, adjusted: false)
                return TapInput(candidates: [TapCandidate(character: text.lowercased(), cost: 0, dx: d.dx, dy: d.dy)], touchModelKey: touchModelKey)
            }
            return TapInput(candidates: [], touchModelKey: touchModelKey)
        }
        let hitD = normalizedDistance(point, hit, adjusted: true)
        var others: [TapCandidate] = []
        let log2e = 1.4426950408889634
        for f in frames where isLetter(f) && f.index != hit.index && f.key.id != hit.key.id {
            let d = normalizedDistance(point, f, adjusted: true)
            guard d.d <= 1.6 else { continue }
            let cost = max(0, 2.5 * (d.d * d.d - hitD.d * hitD.d) * log2e)
            others.append(TapCandidate(character: f.key.id, cost: cost, dx: d.dx, dy: d.dy))
        }
        // The hit key always comes first (cost 0), even when a neighbour ties with it.
        others.sort { $0.cost < $1.cost }
        return TapInput(candidates: [TapCandidate(character: hit.key.id, cost: 0, dx: hitD.dx, dy: hitD.dy)] + others,
                        touchModelKey: touchModelKey)
    }

    /// A tap at the centre of the key for `character` (used when no real touch is available).
    public func syntheticTap(for character: String) -> TapInput {
        let c = character.lowercased()
        guard let f = frames.first(where: { isLetter($0) && $0.key.id == c }) else { return .exact(c) }
        return tap(at: CGPoint(x: f.rect.midX, y: f.rect.midY), hit: f)
    }
}
