import UIKit
import KeibordCore

enum KeyboardViewEvent {
    case keyDown(KeySpec)
    case character(text: String, tap: TapInput?, isLetter: Bool)
    case backspace
    case backspaceRepeat(wordMode: Bool)
    case space
    case returnKey
    case shift
    case shiftDoubleTap
    case switchPage(LayoutPage)
    case emoji
    case nextLanguage
    case selectLanguage(KeyboardLanguage)
    case moveCursor(Int)
    case trackpad(Bool)
}

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didTrigger event: KeyboardViewEvent)
    /// Forward globe-key touches to `handleInputModeList(from:with:)`.
    func keyboardView(_ view: KeyboardView, globeTouchedWith event: UIEvent, in keyView: UIView)
}

/// One drawn key.
final class KeyView: UIView {
    let label = UILabel()
    let icon = UIImageView()
    private let shadowLayer = CALayer()
    private let fill = CALayer()
    var key: KeySpec

    init(key: KeySpec) {
        self.key = key
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(shadowLayer)
        layer.addSublayer(fill)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
        icon.contentMode = .center
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(fillColor: UIColor, labelColor: UIColor, theme: KeyboardTheme) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = fillColor.cgColor
        fill.cornerRadius = theme.cornerRadius
        shadowLayer.backgroundColor = theme.colors.keyShadow.uiColor.cgColor
        shadowLayer.cornerRadius = theme.cornerRadius
        shadowLayer.isHidden = !theme.shadows || key.style == .spacer
        CATransaction.commit()
        label.textColor = labelColor
        icon.tintColor = labelColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        shadowLayer.frame = bounds.offsetBy(dx: 0, dy: 1)
        CATransaction.commit()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        icon.frame = bounds
    }
}

/// The key area: draws keys and turns touches into `KeyboardViewEvent`s.
final class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    private(set) var layout: KeyboardLayout?
    private var metrics = KeyboardMetrics.standard(height: .standard, landscape: false)
    private var theme: KeyboardTheme?
    private var shiftState: ShiftState = .off
    private var spaceLabel = ""
    private var returnEnabled = true
    private var touchOffsets: [String: (dx: Double, dy: Double)] = [:]
    var languages: [KeyboardLanguage] = []
    var spacebarCursor = true

    private var frames: [KeyFrame] = []
    private var keyViews: [Int: KeyView] = [:]
    private var resolver: TouchResolver?
    private var laidOutWidth: CGFloat = 0

    private let popup = KeyPopupView()
    private let callout = CalloutView()

    // Touch tracking
    private enum Mode { case normal, callout, trackpad, repeating }
    private final class Tracked {
        var frameIndex: Int
        var tap: TapInput?
        var mode: Mode = .normal
        var timer: Timer?
        var startTime: TimeInterval
        var lastX: CGFloat = 0
        var cursorRemainder: CGFloat = 0
        init(frameIndex: Int, tap: TapInput?, startTime: TimeInterval) {
            self.frameIndex = frameIndex
            self.tap = tap
            self.startTime = startTime
        }
        deinit { timer?.invalidate() }
    }
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var lastShiftTap: TimeInterval = 0
    private var trackpadActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        backgroundColor = .clear
        popup.isHidden = true
        callout.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Configuration

    func configure(layout: KeyboardLayout, metrics: KeyboardMetrics, theme: KeyboardTheme, shiftState: ShiftState,
                   spaceLabel: String, returnEnabled: Bool, returnProminent: Bool, touchOffsets: [String: (dx: Double, dy: Double)]) {
        prominentReturn = returnProminent
        let layoutChanged = layout != self.layout || metrics != self.metrics
        self.layout = layout
        self.metrics = metrics
        self.theme = theme
        self.shiftState = shiftState
        self.spaceLabel = spaceLabel
        self.returnEnabled = returnEnabled
        self.touchOffsets = touchOffsets
        if layoutChanged {
            cancelAllTouches()
            rebuildKeys()
        } else {
            resolver = TouchResolver(frames: frames, offsets: touchOffsets, touchModelKey: layout.touchModelKey)
        }
        refreshAppearance()
    }

    private func rebuildKeys() {
        keyViews.values.forEach { $0.removeFromSuperview() }
        keyViews = [:]
        laidOutWidth = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout = layout, bounds.width > 0 else { return }
        if laidOutWidth == bounds.width, !keyViews.isEmpty { return }
        laidOutWidth = bounds.width
        frames = LayoutGeometry.frames(for: layout, width: bounds.width, metrics: metrics)
        resolver = TouchResolver(frames: frames, offsets: touchOffsets, touchModelKey: layout.touchModelKey)
        keyViews.values.forEach { $0.removeFromSuperview() }
        keyViews = [:]
        for f in frames where f.key.style != .spacer {
            let v = KeyView(key: f.key)
            v.frame = f.rect
            addSubview(v)
            keyViews[f.index] = v
        }
        if popup.superview == nil { addSubview(popup) }
        if callout.superview == nil { addSubview(callout) }
        bringSubviewToFront(popup)
        bringSubviewToFront(callout)
        refreshAppearance()
    }

    private var prominentReturn = false

    func refreshAppearance() {
        guard let theme = theme else { return }
        let prominent = prominentReturn
        for (index, view) in keyViews {
            let key = frames[index].key
            let pressed = isPressed(index)
            var fill = theme.keyColor(key, prominentReturn: prominent)
            if pressed, !(key.style == .character && theme.showsPopups && key.isLetter) {
                fill = key.style == .function || key.style == .returnKey ? theme.colors.pressedFunctionKey.uiColor : theme.colors.functionKey.uiColor
            }
            if key.id == "shift", shiftState != .off, theme.tints[key.id] == nil {
                fill = theme.colors.characterKey.uiColor
            }
            view.apply(fillColor: fill, labelColor: theme.labelColor(key, prominentReturn: prominent), theme: theme)
            configureContent(view, key: key, theme: theme)
            view.alpha = (key.id == "return" && !returnEnabled) ? 0.5 : 1
            view.label.alpha = trackpadActive ? 0 : 1
            view.icon.alpha = trackpadActive ? 0 : 1
        }
    }

    private func isPressed(_ index: Int) -> Bool {
        tracked.values.contains { $0.frameIndex == index && $0.mode != .trackpad }
    }

    private func symbol(_ name: String, _ size: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    private func configureContent(_ view: KeyView, key: KeySpec, theme: KeyboardTheme) {
        let scale = theme.labelScale
        view.icon.image = nil
        view.label.text = nil
        switch key.id {
        case "shift":
            let name = shiftState == .locked ? "capslock.fill" : (shiftState == .on ? "shift.fill" : "shift")
            view.icon.image = symbol(name, 18 * scale, weight: .medium)
            return
        case "backspace":
            view.icon.image = symbol("delete.left", 18 * scale)
            return
        case "emoji":
            view.icon.image = symbol("face.smiling", 20 * scale)
            return
        case "globe":
            view.icon.image = symbol("globe", 19 * scale)
            return
        case "return" where key.label.isEmpty:
            view.icon.image = symbol("return", 19 * scale)
            return
        case "space":
            view.label.text = spaceLabel
            view.label.font = .systemFont(ofSize: 15 * scale)
            view.label.textColor = theme.tints["space"] == nil ? theme.secondaryLabel : theme.labelColor(key, prominentReturn: false)
            return
        default:
            break
        }
        var text = key.label
        if key.isLetter, shiftState != .off || theme.uppercaseLabels {
            text = text == "ß" ? "ẞ" : text.uppercased()
        }
        view.label.text = text
        switch key.style {
        case .character:
            let size: CGFloat = key.isLetter ? 23 : (text.count > 1 ? 16 : 22)
            view.label.font = .systemFont(ofSize: size * scale, weight: .regular)
        default:
            view.label.font = .systemFont(ofSize: 15 * scale, weight: .regular)
        }
    }

    // MARK: Touches

    private func cancelAllTouches() {
        tracked.values.forEach { $0.timer?.invalidate() }
        tracked = [:]
        popup.isHidden = true
        callout.isHidden = true
        if trackpadActive {
            trackpadActive = false
            delegate?.keyboardView(self, didTrigger: .trackpad(false))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            // Rollover: a new touch commits a pending character touch immediately.
            for (id, t) in tracked where t.mode == .normal && frames.indices.contains(t.frameIndex) && frames[t.frameIndex].key.style == .character {
                commit(t)
                tracked[id] = nil
            }
            let point = touch.location(in: self)
            guard let resolver = resolver, let hit = resolver.resolve(point) else { continue }
            let key = frames[hit.frameIndex].key
            let t = Tracked(frameIndex: hit.frameIndex, tap: hit.tap, startTime: touch.timestamp)
            t.lastX = point.x
            tracked[ObjectIdentifier(touch)] = t
            delegate?.keyboardView(self, didTrigger: .keyDown(key))
            begin(t, key: key, event: event)
        }
        refreshAppearance()
    }

    private func begin(_ t: Tracked, key: KeySpec, event: UIEvent?) {
        switch key.action {
        case .backspace:
            delegate?.keyboardView(self, didTrigger: .backspace)
            t.mode = .repeating
            let start = Date()
            t.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self, weak t] _ in
                guard let self = self, let t = t else { return }
                t.timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let wordMode = Date().timeIntervalSince(start) > 1.6
                    self.delegate?.keyboardView(self, didTrigger: .backspaceRepeat(wordMode: wordMode))
                }
            }
        case .shift:
            let now = Date().timeIntervalSince1970
            if now - lastShiftTap < 0.3 {
                delegate?.keyboardView(self, didTrigger: .shiftDoubleTap)
                lastShiftTap = 0
            } else {
                delegate?.keyboardView(self, didTrigger: .shift)
                lastShiftTap = now
            }
        case .space:
            if spacebarCursor { scheduleLongPress(t, delay: 0.4) }
        case .nextLanguage:
            if languages.count > 1 { scheduleLongPress(t, delay: 0.4) }
        case .globe:
            if let event = event, let view = keyViews[t.frameIndex] {
                delegate?.keyboardView(self, globeTouchedWith: event, in: view)
            }
        case .insert:
            showPopup(for: t.frameIndex)
            if !keyAlternates(frames[t.frameIndex].key).isEmpty { scheduleLongPress(t, delay: 0.42) }
        default:
            break
        }
    }

    private func keyAlternates(_ key: KeySpec) -> [String] {
        let upper = key.isLetter && shiftState != .off
        return key.alternates.map { upper && $0 != "ß" ? $0.uppercased() : $0 }
    }

    private func scheduleLongPress(_ t: Tracked, delay: TimeInterval) {
        t.timer?.invalidate()
        t.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak t] _ in
            guard let self = self, let t = t else { return }
            self.longPress(t)
        }
    }

    private func longPress(_ t: Tracked) {
        guard frames.indices.contains(t.frameIndex) else { return }
        let key = frames[t.frameIndex].key
        switch key.action {
        case .space:
            t.mode = .trackpad
            trackpadActive = true
            delegate?.keyboardView(self, didTrigger: .trackpad(true))
            refreshAppearance()
        case .nextLanguage:
            t.mode = .callout
            showCallout(options: languages.map { $0.displayName }, for: t.frameIndex, selected: languages.firstIndex(where: { $0.shortLabel == key.label }) ?? 0)
        case .insert:
            let options = keyAlternates(key)
            guard !options.isEmpty else { return }
            t.mode = .callout
            popup.isHidden = true
            showCallout(options: options, for: t.frameIndex, selected: 0)
        default:
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let t = tracked[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            switch t.mode {
            case .trackpad:
                t.cursorRemainder += point.x - t.lastX
                t.lastX = point.x
                let step: CGFloat = 9
                let n = Int(t.cursorRemainder / step)
                if n != 0 {
                    t.cursorRemainder -= CGFloat(n) * step
                    delegate?.keyboardView(self, didTrigger: .moveCursor(n))
                }
            case .callout:
                callout.select(at: convert(point, to: callout))
            case .normal:
                guard frames.indices.contains(t.frameIndex) else { continue }
                let key = frames[t.frameIndex].key
                if key.action == .globe, let event = event, let view = keyViews[t.frameIndex] {
                    delegate?.keyboardView(self, globeTouchedWith: event, in: view)
                    continue
                }
                guard key.style == .character, let hit = resolver?.resolve(point), hit.frameIndex != t.frameIndex,
                      frames[hit.frameIndex].key.style == .character else { continue }
                // Slide to a neighbouring character key.
                t.frameIndex = hit.frameIndex
                t.tap = hit.tap
                showPopup(for: hit.frameIndex)
                t.timer?.invalidate()
                if !keyAlternates(frames[hit.frameIndex].key).isEmpty { scheduleLongPress(t, delay: 0.42) }
                refreshAppearance()
            case .repeating:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let t = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            t.timer?.invalidate()
            if frames.indices.contains(t.frameIndex), frames[t.frameIndex].key.action == .globe,
               let event = event, let view = keyViews[t.frameIndex] {
                delegate?.keyboardView(self, globeTouchedWith: event, in: view)
            } else {
                commit(t)
            }
        }
        if tracked.isEmpty {
            popup.isHidden = true
        }
        refreshAppearance()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            tracked.removeValue(forKey: ObjectIdentifier(touch))?.timer?.invalidate()
        }
        popup.isHidden = true
        callout.isHidden = true
        if trackpadActive {
            trackpadActive = false
            delegate?.keyboardView(self, didTrigger: .trackpad(false))
        }
        refreshAppearance()
    }

    private func commit(_ t: Tracked) {
        t.timer?.invalidate()
        guard frames.indices.contains(t.frameIndex) else { return }
        let key = frames[t.frameIndex].key
        popup.isHidden = true
        switch t.mode {
        case .trackpad:
            trackpadActive = false
            delegate?.keyboardView(self, didTrigger: .trackpad(false))
            return
        case .callout:
            callout.isHidden = true
            guard let index = callout.selectedIndex else { return }
            if key.action == .nextLanguage {
                if languages.indices.contains(index) { delegate?.keyboardView(self, didTrigger: .selectLanguage(languages[index])) }
            } else {
                let options = keyAlternates(key)
                if options.indices.contains(index) {
                    delegate?.keyboardView(self, didTrigger: .character(text: options[index], tap: nil, isLetter: key.isLetter))
                }
            }
            return
        case .repeating:
            return
        case .normal:
            break
        }
        switch key.action {
        case .insert(let text):
            delegate?.keyboardView(self, didTrigger: .character(text: text, tap: key.isLetter ? t.tap : nil, isLetter: key.isLetter))
        case .space: delegate?.keyboardView(self, didTrigger: .space)
        case .returnKey: delegate?.keyboardView(self, didTrigger: .returnKey)
        case .switchPage(let page): delegate?.keyboardView(self, didTrigger: .switchPage(page))
        case .emoji: delegate?.keyboardView(self, didTrigger: .emoji)
        case .nextLanguage: delegate?.keyboardView(self, didTrigger: .nextLanguage)
        case .shift, .backspace, .globe, .none: break
        }
    }

    // MARK: Popups

    private func showPopup(for index: Int) {
        guard let theme = theme, theme.showsPopups, frames.indices.contains(index) else { popup.isHidden = true; return }
        let key = frames[index].key
        guard key.style == .character, key.label.count <= 2 else { popup.isHidden = true; return }
        var text = key.label
        if key.isLetter, shiftState != .off || theme.uppercaseLabels { text = text == "ß" ? "ẞ" : text.uppercased() }
        popup.show(text: text, keyRect: frames[index].rect, in: bounds, theme: theme)
        bringSubviewToFront(popup)
    }

    private func showCallout(options: [String], for index: Int, selected: Int) {
        guard let theme = theme else { return }
        callout.show(options: options, keyRect: frames[index].rect, in: bounds, theme: theme, selected: selected)
        bringSubviewToFront(callout)
    }
}

/// Magnified key preview shown above a pressed character key.
final class KeyPopupView: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(shape)
        shape.shadowOpacity = 0.25
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(text: String, keyRect: CGRect, in bounds: CGRect, theme: KeyboardTheme) {
        let extra: CGFloat = 10
        let topHeight = keyRect.height * 1.05
        var top = CGRect(x: keyRect.minX - extra, y: keyRect.minY - topHeight - 4, width: keyRect.width + 2 * extra, height: topHeight)
        top.origin.x = min(max(top.minX, 0), bounds.width - top.width)
        let whole = top.union(keyRect)
        frame = whole
        let t = top.offsetBy(dx: -whole.minX, dy: -whole.minY)
        let k = keyRect.offsetBy(dx: -whole.minX, dy: -whole.minY)
        let r = theme.cornerRadius + 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: t.minX + r, y: t.minY))
        path.addLine(to: CGPoint(x: t.maxX - r, y: t.minY))
        path.addQuadCurve(to: CGPoint(x: t.maxX, y: t.minY + r), controlPoint: CGPoint(x: t.maxX, y: t.minY))
        path.addLine(to: CGPoint(x: t.maxX, y: t.maxY - 6))
        path.addCurve(to: CGPoint(x: k.maxX, y: k.minY + 8), controlPoint1: CGPoint(x: t.maxX, y: t.maxY), controlPoint2: CGPoint(x: k.maxX, y: t.maxY))
        path.addLine(to: CGPoint(x: k.maxX, y: k.maxY - theme.cornerRadius))
        path.addQuadCurve(to: CGPoint(x: k.maxX - theme.cornerRadius, y: k.maxY), controlPoint: CGPoint(x: k.maxX, y: k.maxY))
        path.addLine(to: CGPoint(x: k.minX + theme.cornerRadius, y: k.maxY))
        path.addQuadCurve(to: CGPoint(x: k.minX, y: k.maxY - theme.cornerRadius), controlPoint: CGPoint(x: k.minX, y: k.maxY))
        path.addLine(to: CGPoint(x: k.minX, y: k.minY + 8))
        path.addCurve(to: CGPoint(x: t.minX, y: t.maxY - 6), controlPoint1: CGPoint(x: k.minX, y: t.maxY), controlPoint2: CGPoint(x: t.minX, y: t.maxY))
        path.addLine(to: CGPoint(x: t.minX, y: t.minY + r))
        path.addQuadCurve(to: CGPoint(x: t.minX + r, y: t.minY), controlPoint: CGPoint(x: t.minX, y: t.minY))
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path.cgPath
        shape.fillColor = theme.colors.characterKey.uiColor.cgColor
        CATransaction.commit()
        label.text = text
        label.textColor = theme.colors.label.uiColor
        label.font = .systemFont(ofSize: 34 * theme.labelScale, weight: .light)
        label.frame = t
        isHidden = false
    }
}

/// Long-press menu (accented letters, language list).
final class CalloutView: UIView {
    private var labels: [UILabel] = []
    private(set) var selectedIndex: Int?
    private var theme: KeyboardTheme?
    private var vertical = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(options: [String], keyRect: CGRect, in bounds: CGRect, theme: KeyboardTheme, selected: Int) {
        self.theme = theme
        labels.forEach { $0.removeFromSuperview() }
        labels = []
        vertical = options.contains { $0.count > 3 }
        let cell = CGSize(width: vertical ? 190 : max(30, keyRect.width), height: vertical ? 40 : keyRect.height + 4)
        let size = vertical ? CGSize(width: cell.width, height: cell.height * CGFloat(options.count))
                            : CGSize(width: cell.width * CGFloat(options.count), height: cell.height)
        var origin = CGPoint(x: keyRect.midX - cell.width / 2, y: keyRect.minY - size.height - 6)
        if vertical { origin.x = keyRect.minX }
        origin.x = min(max(origin.x, 2), bounds.width - size.width - 2)
        frame = CGRect(origin: origin, size: size)
        backgroundColor = theme.colors.characterKey.uiColor
        layer.cornerRadius = theme.cornerRadius + 2
        for (i, option) in options.enumerated() {
            let l = UILabel()
            l.text = option
            l.textAlignment = .center
            l.font = .systemFont(ofSize: vertical ? 17 : 24 * theme.labelScale)
            l.layer.cornerRadius = theme.cornerRadius
            l.layer.masksToBounds = true
            l.frame = vertical ? CGRect(x: 0, y: CGFloat(i) * cell.height, width: cell.width, height: cell.height)
                               : CGRect(x: CGFloat(i) * cell.width, y: 0, width: cell.width, height: cell.height)
            addSubview(l)
            labels.append(l)
        }
        setSelected(selected)
        isHidden = false
    }

    func select(at point: CGPoint) {
        guard !labels.isEmpty else { return }
        let coordinate = vertical ? point.y : point.x
        let length = vertical ? labels[0].frame.height : labels[0].frame.width
        setSelected(min(max(Int(floor(coordinate / max(length, 1))), 0), labels.count - 1))
    }

    private func setSelected(_ index: Int) {
        guard let theme = theme else { return }
        selectedIndex = index
        for (i, l) in labels.enumerated() {
            l.backgroundColor = i == index ? theme.colors.accent.uiColor : .clear
            l.textColor = i == index ? .white : theme.colors.label.uiColor
        }
    }
}
