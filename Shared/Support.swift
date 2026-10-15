import UIKit
import KeibordCore

extension RGBAColor {
    var uiColor: UIColor { UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }

    init(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(min(max(r, 0), 1)), green: Double(min(max(g, 0), 1)), blue: Double(min(max(b, 0), 1)), alpha: Double(a))
    }
}

enum KeibordVersion {
    static var marketing: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var display: String { "\(marketing) (\(build))" }
}
