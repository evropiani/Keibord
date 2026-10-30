import UIKit

/// Key icons Keibord draws itself where SF Symbols has nothing like Apple's keyboard.
enum KeyboardIcons {
    /// Apple's emoji key (iOS 26/27), drawn instead of the SF Symbol.
    static let emojiSymbol = "keibord.emoji"

    /// The icon of `name`: Keibord's own drawings, else the SF Symbol of that name.
    static func image(named name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, filled: Bool) -> UIImage? {
        if name == emojiSymbol { return emojiFace(diameter: pointSize, filled: filled) }
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    private static var cache: [String: UIImage] = [:]

    /// Apple's emoji key: a grinning face (oval eyes, open mouth with the upper teeth), outlined on light
    /// keys and filled on dark ones, measured from screenshots of iOS 26. A template image (tinted with
    /// the label colour); `diameter` is the face's size in points.
    static func emojiFace(diameter: CGFloat, filled: Bool) -> UIImage? {
        let key = "\(diameter)|\(filled)"
        if let cached = cache[key] { return cached }
        #if os(iOS)
        let side = ceil(diameter) + 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            let r = diameter / 2
            let c = CGPoint(x: side / 2, y: side / 2)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }
            let line = 0.17 * r
            let eyes = UIBezierPath()
            for x in [-0.29, 0.29] as [CGFloat] {
                eyes.append(UIBezierPath(ovalIn: CGRect(x: c.x + (x - 0.108) * r, y: c.y - 0.364 * r, width: 0.216 * r, height: 0.27 * r)))
            }
            // The open mouth: a gently curved top edge over a half ellipse.
            let mouth = UIBezierPath()
            mouth.move(to: p(-0.645, 0.08))
            mouth.addQuadCurve(to: p(0.645, 0.08), controlPoint: p(0, 0.22))
            mouth.addCurve(to: p(0, 0.67), controlPoint1: p(0.645, 0.406), controlPoint2: p(0.356, 0.67))
            mouth.addCurve(to: p(-0.645, 0.08), controlPoint1: p(-0.356, 0.67), controlPoint2: p(-0.645, 0.406))
            mouth.close()
            mouth.lineJoinStyle = .round
            // The upper teeth: a curved band with blunt ends just under the mouth's top edge.
            let teeth = UIBezierPath()
            teeth.move(to: p(-0.52, 0.19))
            teeth.addQuadCurve(to: p(0.52, 0.19), controlPoint: p(0, 0.31))
            teeth.addLine(to: p(0.5, 0.29))
            teeth.addQuadCurve(to: p(-0.5, 0.29), controlPoint: p(0, 0.465))
            teeth.close()
            UIColor.black.setFill()
            UIColor.black.setStroke()
            if filled {
                UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
                cg.setBlendMode(.clear)
                eyes.fill()
                mouth.fill()
                cg.setBlendMode(.normal)
                teeth.fill()
            } else {
                let face = UIBezierPath(ovalIn: CGRect(x: c.x - r + line / 2, y: c.y - r + line / 2, width: 2 * r - line, height: 2 * r - line))
                face.lineWidth = line
                face.stroke()
                eyes.fill()
                mouth.lineWidth = line * 0.5
                mouth.fill()
                mouth.stroke()
                cg.setBlendMode(.clear)
                teeth.fill()
                cg.setBlendMode(.normal)
            }
        }.withRenderingMode(.alwaysTemplate)
        cache[key] = image
        return image
        #else
        return UIImage(systemName: filled ? "face.smiling.inverse" : "face.smiling")
        #endif
    }
}
