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
    /// The finger left the shift key (letters typed while it was held are all capitalised).
    case shiftReleased
    case switchPage(LayoutPage)
    case emoji
    case nextLanguage
    case selectLanguage(KeyboardLanguage)
    case moveCursor(Int)
    case trackpad(Bool)
}

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didTrigger event: KeyboardViewEvent)
    /// Forward globe-key touches to `handleInputModeList(from:with:)` (fallback for touches that land
    /// next to the globe key's own control).
    func keyboardView(_ view: KeyboardView, globeTouchedWith event: UIEvent, in keyView: UIView)
}

/// Visual state of one key; `KeyView` only touches its layers when this changes.
struct KeyAppearance: Equatable {
    var fill: UIColor
    var label: UIColor
    var shadow: UIColor
    var cornerRadius: CGFloat
    var shadowHidden: Bool
}

/// Label text / SF Symbol of one key.
struct KeyContent: Equatable {
    var text: String?
    var fontSize: CGFloat = 0
    var fontWeight: UIFont.Weight = .regular
    var symbol: String?
    var symbolSize: CGFloat = 0
    var symbolWeight: UIImage.SymbolWeight = .regular
    /// Filled variant of a drawn icon (the emoji face on dark keys, like Apple's).
    var symbolFilled = false
    /// Small text in the bottom right corner (the space bar's "DE EN", like Apple's keyboard).
    var cornerText: String?
    var cornerFontSize: CGFloat = 0
}

/// One drawn key.
final class KeyView: UIView {
    let label = UILabel()
    let icon = UIImageView()
    /// Only the space bar has one (created on first use).
    private(set) var cornerLabel: UILabel?
    private let shadowLayer = CALayer()
    private let fill = CALayer()
    var key: KeySpec
    private(set) var appliedAppearance: KeyAppearance?
    private var appliedContent: KeyContent?

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

    /// Applies colours; a no-op when nothing changed (this runs for every key on every touch).
    func apply(_ a: KeyAppearance) {
        guard a != appliedAppearance else { return }
        appliedAppearance = a
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = a.fill.cgColor
        fill.cornerRadius = a.cornerRadius
        shadowLayer.backgroundColor = a.shadow.cgColor
        shadowLayer.cornerRadius = a.cornerRadius
        shadowLayer.isHidden = a.shadowHidden
        CATransaction.commit()
        label.textColor = a.label
        icon.tintColor = a.label
        cornerLabel?.textColor = a.label
    }

    /// Applies text and icon; unchanged labels are not reset (that would redraw every label per touch).
    func apply(_ c: KeyContent) {
        guard c != appliedContent else { return }
        let old = appliedContent
        appliedContent = c
        if c.text != old?.text { label.text = c.text }
        if c.fontSize != old?.fontSize || c.fontWeight != old?.fontWeight {
            label.font = .systemFont(ofSize: max(c.fontSize, 1), weight: c.fontWeight)
        }
        if c.symbol != old?.symbol || c.symbolSize != old?.symbolSize || c.symbolWeight != old?.symbolWeight || c.symbolFilled != old?.symbolFilled {
            icon.image = c.symbol.flatMap { KeyboardIcons.image(named: $0, pointSize: c.symbolSize, weight: c.symbolWeight, filled: c.symbolFilled) }
        }
        if c.cornerText != old?.cornerText || c.cornerFontSize != old?.cornerFontSize {
            if c.cornerText != nil, cornerLabel == nil {
                let corner = UILabel()
                corner.textAlignment = .right
                corner.textColor = appliedAppearance?.label
                addSubview(corner)
                cornerLabel = corner
            }
            cornerLabel?.text = c.cornerText
            cornerLabel?.font = .systemFont(ofSize: max(c.cornerFontSize, 1), weight: .regular, width: .condensed)
            setNeedsLayout()
        }
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
        if let corner = cornerLabel {
            // Like Apple's space bar: about 7 pt from the right and 6 pt from the bottom edge.
            let size = corner.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
            corner.frame = CGRect(x: bounds.maxX - 7 - size.width, y: bounds.maxY - 6 - size.height, width: size.width, height: size.height)
        }
    }
}

/// Touch timing of the key area.
private enum KeyTiming {
    /// Backspace: repeat starts after 0.5 s, then every 0.09 s; whole words after 1.6 s, at half that rate.
    static let backspaceRepeatDelay: TimeInterval = 0.5
    static let backspaceRepeatInterval: TimeInterval = 0.09
    static let backspaceWordModeDelay: TimeInterval = 1.6
    /// Space-bar trackpad: points of horizontal drag per character.
    static let trackpadStep: CGFloat = 9
    /// A touch iOS cancels (it suspected a system edge gesture) still types its key when it was this short
    /// and stayed this close to where it began: a tap, not a swipe.
    static let cancelledTapMaxDuration: TimeInterval = 0.3
    static let cancelledTapMaxTravel: CGFloat = 12
    /// A page key ("123", "ABC", "#+=") held at least this long while something was typed goes back to
    /// its page when released; shorter, it was a tap overlapping fast typing ("123", "5") and stays.
    static let pageHoldMinDuration: TimeInterval = 0.3
}

/// The key area: draws keys and turns touches into `KeyboardViewEvent`s.
final class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?
    /// Receives the globe key's touches through `handleInputModeList(from:with:)` (Apple's documented
    /// target/action for the input-mode key).
    weak var inputModeTarget: UIInputViewController?

    private(set) var layout: KeyboardLayout?
    private var metrics = KeyboardMetrics.standard(height: .standard, landscape: false)
    private var theme: KeyboardTheme?
    private var shiftState: ShiftState = .off
    private var spaceLabel = ""
    /// The language name in the middle of the space bar while the keyboard appears (like Apple's).
    let spaceNameLabel = UILabel()
    private(set) var spaceNameShown = false
    private var returnEnabled = true
    private var prominentReturn = false
    private var touchOffsets: [String: (dx: Double, dy: Double)] = [:]
    private var touchOffsetsID = ""
    var languages: [KeyboardLanguage] = []
    var spacebarCursor = true

    private var frames: [KeyFrame] = []
    private var keyViews: [Int: KeyView] = [:]
    private var resolver: TouchResolver?
    private var laidOutWidth: CGFloat = 0
    /// Next-letter prediction (log2 P by lower-case letter) that reshapes the invisible hit zones of the
    /// letter keys, as on the iPhone keyboard; empty = geometry (and the learned offsets) only.
    var letterPrior: [String: Double] = [:]
    /// `metrics` fitted into the current height (see `KeyboardMetrics.fitted(toHeight:rows:)`).
    private var laidOutMetrics: KeyboardMetrics?

    private let popup = KeyPopupView()
    /// Frame index of the key the preview balloon was last shown for.
    private var popupIndex: Int?
    private let callout = CalloutView()
    private var globeControl: UIControl?
    private var globeIndex: Int?
    private var globePressed = false

    // Touch tracking
    /// `pageHold`: a page key that switched the page when it was touched and is still held.
    private enum Mode { case normal, callout, trackpad, repeating, pageHold }
    private final class Tracked {
        var frameIndex: Int
        /// The key this touch is on, captured when it began (or slid onto it), so it commits correctly
        /// even if the layout was rebuilt in between.
        var key: KeySpec
        var tap: TapInput?
        var mode: Mode = .normal
        var timer: Timer?
        let order: Int
        var lastX: CGFloat = 0
        var lastPoint: CGPoint = .zero
        /// The page a held page key (or a key slid onto from it) goes back to; nil: it stays.
        var returnPage: LayoutPage?
        var typedWhileHeld = false
        /// Trackpad: finger x where it started and the cursor steps sent since, so moving back to a
        /// spot always puts the cursor back where it was there.
        var trackpadOriginX: CGFloat = 0
        var cursorSteps = 0
        var repeatTicks = 0
        /// When and where the finger went down, and how far it moved since (cancelled taps).
        let beganAt = ProcessInfo.processInfo.systemUptime
        var startPoint: CGPoint = .zero
        var travel: CGFloat = 0
        init(frameIndex: Int, key: KeySpec, tap: TapInput?, order: Int) {
            self.frameIndex = frameIndex
            self.key = key
            self.tap = tap
            self.order = order
        }
        deinit { timer?.invalidate() }
    }
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    private var touchCounter = 0
    private var lastShiftTap: TimeInterval = 0
    private var trackpadActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        backgroundColor = .touchableClear // touches in the gaps between keys reach the nearest key
        popup.isHidden = true
        callout.isHidden = true
        spaceNameLabel.textAlignment = .center
        spaceNameLabel.isUserInteractionEnabled = false
        spaceNameLabel.alpha = 0
        addSubview(spaceNameLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Space bar name

    /// Shows the language name in the middle of the space bar (Apple's keyboard does so for a moment when
    /// it appears); `fadeOutSpaceName` then leaves only the code in the corner.
    func showSpaceName(_ name: String) {
        spaceNameLabel.text = name
        spaceNameLabel.alpha = 1
        spaceNameShown = true
        positionSpaceName()
        refreshAppearance()
    }

    /// Fades the name out like Apple's (0.2 s), then the corner code appears.
    func fadeOutSpaceName(animated: Bool = true) {
        guard spaceNameShown else { return }
        let finish = { [weak self] in
            guard let self = self else { return }
            self.spaceNameShown = false
            self.spaceNameLabel.alpha = 0
            self.refreshAppearance()
        }
        guard animated else { finish(); return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.spaceNameLabel.alpha = 0
        }, completion: { _ in finish() })
    }

    private func positionSpaceName() {
        guard let space = frames.first(where: { $0.key.id == "space" }) else {
            spaceNameLabel.isHidden = true
            return
        }
        spaceNameLabel.isHidden = false
        spaceNameLabel.frame = space.rect.insetBy(dx: 6, dy: 0)
        bringSubviewToFront(spaceNameLabel)
    }

    // MARK: Configuration

    /// `touchOffsetsID` identifies `touchOffsets` (layout + learning generation): the touch resolver is
    /// only rebuilt when it changes, not on every keystroke.
    func configure(layout: KeyboardLayout, metrics: KeyboardMetrics, theme: KeyboardTheme, shiftState: ShiftState,
                   spaceLabel: String, returnEnabled: Bool, returnProminent: Bool,
                   touchOffsets: [String: (dx: Double, dy: Double)], touchOffsetsID: String) {
        prominentReturn = returnProminent
        let layoutChanged = layout != self.layout || metrics != self.metrics
        let offsetsChanged = touchOffsetsID != self.touchOffsetsID
        self.layout = layout
        self.metrics = metrics
        self.theme = theme
        self.shiftState = shiftState
        self.spaceLabel = spaceLabel
        self.returnEnabled = returnEnabled
        self.touchOffsets = touchOffsets
        self.touchOffsetsID = touchOffsetsID
        if layoutChanged {
            cancelAllTouches(keepingPageKeys: true)
            rebuildKeys()
            // Build the new frames now: a touch that begins right after a rollover commit switched the
            // page (e.g. space after a digit) must resolve against the new page, not the old one.
            layoutIfNeeded()
            // A held page key stays held on the new page, drawn pressed on the page key now under the
            // finger ("123" becomes "ABC").
            for t in tracked.values where t.mode == .pageHold {
                let index = resolver?.resolve(t.lastPoint, letterLog2Prior: [:])?.frameIndex
                if let index = index, frames.indices.contains(index), case .switchPage = frames[index].key.action {
                    t.frameIndex = index
                    t.key = frames[index].key
                } else {
                    t.frameIndex = -1
                }
            }
        } else if offsetsChanged {
            resolver = TouchResolver(frames: frames, offsets: touchOffsets, touchModelKey: layout.touchModelKey)
        }
        refreshAppearance()
    }

    /// Key views exist (they are built in the first layout pass with a width).
    var hasKeys: Bool { !keyViews.isEmpty }

    private func rebuildKeys() {
        keyViews.values.forEach { $0.removeFromSuperview() }
        keyViews = [:]
        globeControl?.removeFromSuperview()
        globeControl = nil
        globeIndex = nil
        laidOutWidth = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout = layout, bounds.width > 0 else { return }
        // When the system keeps the keyboard lower than requested, the rows shrink to fit instead of
        // the bottom row being cut off.
        let fitted = metrics.fitted(toHeight: bounds.height, rows: layout.rows.count)
        if laidOutWidth == bounds.width, laidOutMetrics == fitted, !keyViews.isEmpty { return }
        laidOutWidth = bounds.width
        laidOutMetrics = fitted
        frames = LayoutGeometry.frames(for: layout, width: bounds.width, metrics: fitted)
        resolver = TouchResolver(frames: frames, offsets: touchOffsets, touchModelKey: layout.touchModelKey)
        keyViews.values.forEach { $0.removeFromSuperview() }
        keyViews = [:]
        globeControl?.removeFromSuperview()
        globeControl = nil
        globeIndex = nil
        for f in frames where f.key.style != .spacer {
            let v = KeyView(key: f.key)
            v.frame = f.rect
            addSubview(v)
            keyViews[f.index] = v
            if f.key.action == .globe { installGlobeControl(for: f) }
        }
        if popup.superview == nil { addSubview(popup) }
        if callout.superview == nil { addSubview(callout) }
        positionSpaceName()
        bringSubviewToFront(popup)
        bringSubviewToFront(callout)
        refreshAppearance()
    }

    /// The globe key gets a real `UIControl` wired to `handleInputModeList(from:with:)` for all touch
    /// events (tap → next keyboard, hold → keyboard list), as Apple's template does. It covers the key
    /// plus half the gaps around it down to the bottom edge, like the touch resolver would.
    private func installGlobeControl(for f: KeyFrame) {
        let control = UIControl()
        control.backgroundColor = .clear
        let m = laidOutMetrics ?? metrics
        let halfGap = m.horizontalGap / 2
        let top = f.rect.minY - (m.rowPitch - m.keyHeight) / 2
        control.frame = CGRect(x: f.rect.minX - halfGap, y: top, width: f.rect.width + 2 * halfGap,
                               height: m.rowPitch + m.bottomInset)
        control.addTarget(self, action: #selector(globeTouchDown), for: .touchDown)
        control.addTarget(self, action: #selector(globeTouchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        if let target = inputModeTarget {
            control.addTarget(target, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        addSubview(control)
        globeControl = control
        globeIndex = f.index
    }

    @objc private func globeTouchDown() {
        commitPendingTaps()
        globePressed = true
        if let index = globeIndex, frames.indices.contains(index) {
            delegate?.keyboardView(self, didTrigger: .keyDown(frames[index].key))
        }
        refreshAppearance()
    }

    @objc private func globeTouchEnded() {
        globePressed = false
        refreshAppearance()
    }

    func refreshAppearance() {
        guard let theme = theme else { return }
        if spaceNameShown, let space = frames.first(where: { $0.key.id == "space" }) {
            // In the label colour, 18 pt like the words of the bottom row (Apple's size).
            spaceNameLabel.font = .systemFont(ofSize: 18 * theme.labelScale)
            spaceNameLabel.textColor = theme.labelColor(space.key, prominentReturn: false)
        }
        let labelAlpha: CGFloat = trackpadActive ? 0 : 1
        for (index, view) in keyViews {
            guard frames.indices.contains(index) else { continue }
            let key = frames[index].key
            view.apply(appearance(for: key, pressed: isPressed(index), theme: theme))
            view.apply(content(for: key, theme: theme))
            let alpha: CGFloat = (key.id == "return" && !returnEnabled) ? 0.5 : 1
            if view.alpha != alpha { view.alpha = alpha }
            if view.label.alpha != labelAlpha { view.label.alpha = labelAlpha }
            if view.icon.alpha != labelAlpha { view.icon.alpha = labelAlpha }
            if let corner = view.cornerLabel, corner.alpha != labelAlpha { corner.alpha = labelAlpha }
            // The space bar turned into a trackpad: its name goes at once.
            if trackpadActive, spaceNameShown, key.id == "space" { spaceNameShown = false; spaceNameLabel.alpha = 0 }
        }
    }

    private func appearance(for key: KeySpec, pressed: Bool, theme: KeyboardTheme) -> KeyAppearance {
        var fill = theme.keyColor(key, prominentReturn: prominentReturn)
        // Keys with a preview balloon keep their colour while pressed (the balloon is the feedback).
        if pressed, !showsPopup(for: key) {
            fill = theme.pressedColor(for: key)
        }
        if key.id == "shift", shiftState != .off, theme.tints[key.id] == nil {
            fill = theme.characterKeyColor
        }
        var labelColor = theme.labelColor(key, prominentReturn: prominentReturn)
        if key.id == "space", theme.tints["space"] == nil { labelColor = theme.spaceCodesColor }
        return KeyAppearance(fill: fill, label: labelColor, shadow: theme.keyShadowColor, cornerRadius: theme.cornerRadius,
                             shadowHidden: !theme.shadows || key.style == .spacer)
    }

    /// Label sizes at 100 % are those of the iOS 26/27 keyboard, measured from screenshots: letters
    /// 24.5 pt, "123" and other words 18 pt, icons about 19 pt.
    private func content(for key: KeySpec, theme: KeyboardTheme) -> KeyContent {
        let scale = theme.labelScale
        switch key.id {
        case "shift":
            let name = shiftState == .locked ? "capslock.fill" : (shiftState == .on ? "shift.fill" : "shift")
            return KeyContent(symbol: name, symbolSize: 18.5 * scale, symbolWeight: .medium)
        case "backspace":
            return KeyContent(symbol: "delete.left", symbolSize: 19 * scale)
        case "emoji":
            // Apple's grinning face (outlined, filled on dark keys), 18.6 pt like on iOS 26.
            return KeyContent(symbol: KeyboardIcons.emojiSymbol, symbolSize: 18.6 * scale, symbolFilled: theme.isDark)
        case "globe":
            return KeyContent(symbol: "globe", symbolSize: 19 * scale)
        case "return" where key.label.isEmpty:
            return KeyContent(symbol: "return", symbolSize: 19 * scale)
        case "space":
            // Apple's space bar has no word on it, only the language in its corner ("DE"); the name shows
            // in the middle for a moment when the keyboard appears (`showSpaceName`), the corner then empty.
            return KeyContent(cornerText: spaceLabel.isEmpty || spaceNameShown ? nil : spaceLabel, cornerFontSize: 12.5 * scale)
        default:
            break
        }
        let text = displayLabel(key, theme: theme)
        switch key.style {
        case .character:
            let size: CGFloat = key.isLetter ? 24.5 : (text.count > 1 ? 17 : 23.5)
            return KeyContent(text: text, fontSize: size * scale)
        default:
            return KeyContent(text: text, fontSize: 18 * scale)
        }
    }

    /// Label of a key in the current shift state. "ß" stays "ß": the input controller inserts "ß" (not
    /// "SS"/"ẞ") when shifted, so the label shows what the key types.
    private func displayLabel(_ key: KeySpec, theme: KeyboardTheme) -> String {
        guard key.isLetter, shiftState != .off || theme.uppercaseLabels else { return key.label }
        return key.label == "ß" ? key.label : key.label.uppercased()
    }

    private func showsPopup(for key: KeySpec) -> Bool {
        guard let theme = theme, theme.showsPopups else { return false }
        return key.style == .character && key.label.count <= 2
    }

    private func isPressed(_ index: Int) -> Bool {
        if globePressed, index == globeIndex { return true }
        return tracked.values.contains { $0.frameIndex == index && $0.mode != .trackpad }
    }

    // MARK: Touches

    /// Drops every tracked touch without committing it (layout change, keyboard disappearing); a page
    /// key that is held stays when `keepingPageKeys` (its own page switch changed the layout).
    func cancelAllTouches(keepingPageKeys: Bool = false) {
        let shiftWasHeld = tracked.values.contains { $0.key.action == .shift }
        let dropped = tracked.filter { !keepingPageKeys || $0.value.mode != .pageHold }
        dropped.values.forEach { $0.timer?.invalidate() }
        tracked = tracked.filter { dropped[$0.key] == nil }
        globePressed = false
        popup.isHidden = true
        callout.isHidden = true
        if trackpadActive {
            trackpadActive = false
            delegate?.keyboardView(self, didTrigger: .trackpad(false))
        }
        if shiftWasHeld { delegate?.keyboardView(self, didTrigger: .shiftReleased) }
    }

    /// Keys that commit early when another touch begins (rollover), like the system keyboard.
    private static func commitsOnRollover(_ key: KeySpec) -> Bool {
        switch key.action {
        case .insert, .space, .returnKey: return true
        default: return false
        }
    }

    /// Rollover: a new touch commits pending taps first, in the order they began, so fast typing never
    /// loses or reorders characters (also spaces: "5", space, "U" → "5 U" on letters). Page keys switch
    /// when touched (`begin`).
    private func commitPendingTaps() {
        let pending = tracked.filter { $0.value.mode == .normal && Self.commitsOnRollover($0.value.key) }
            .sorted { $0.value.order < $1.value.order }
        for (id, t) in pending {
            tracked[id] = nil
            commit(t)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            // While the space bar moves the cursor, a second finger brushing a key must not type it.
            if trackpadActive, tracked.values.contains(where: { $0.mode == .trackpad }) { continue }
            commitPendingTaps()
            let point = touch.location(in: self)
            guard let resolver = resolver, let hit = resolver.resolve(point, letterLog2Prior: letterPrior),
                  frames.indices.contains(hit.frameIndex) else { continue }
            let key = frames[hit.frameIndex].key
            touchCounter += 1
            let t = Tracked(frameIndex: hit.frameIndex, key: key, tap: hit.tap, order: touchCounter)
            t.lastX = point.x
            t.lastPoint = point
            t.startPoint = point
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
            t.timer = Timer.scheduledTimer(withTimeInterval: KeyTiming.backspaceRepeatDelay, repeats: false) { [weak self, weak t] _ in
                guard let self = self, let t = t else { return }
                self.startBackspaceRepeat(t, start: start)
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
            if let event = event { delegate?.keyboardView(self, globeTouchedWith: event, in: self) }
        case .insert:
            showPopup(for: t.frameIndex)
            if !keyAlternates(key).isEmpty { scheduleLongPress(t, delay: 0.42) }
        case .switchPage(let page):
            // Like Apple's keyboard the page shows as soon as its key is touched. Held, other fingers
            // type on it and releasing the key goes back (`releasePageKey`); sliding onto a key types it
            // and goes back too; a tap stays on the new page.
            t.mode = .pageHold
            let holdingAnother = tracked.values.contains { $0 !== t && $0.mode == .pageHold && $0.returnPage != nil }
            t.returnPage = holdingAnother ? nil : layout?.page
            delegate?.keyboardView(self, didTrigger: .switchPage(page))
        default:
            break
        }
    }

    /// The finger left a held page key: back to the page it came from when something was typed while it
    /// was held (long enough not to be a tap overlapping the next key).
    private func releasePageKey(_ t: Tracked) {
        guard let page = t.returnPage, t.typedWhileHeld, layout?.page != page,
              ProcessInfo.processInfo.systemUptime - t.beganAt >= KeyTiming.pageHoldMinDuration else { return }
        delegate?.keyboardView(self, didTrigger: .switchPage(page))
    }

    /// Something was typed: a held page key goes back to its page when released.
    private func noteTyped() {
        for t in tracked.values where t.mode == .pageHold { t.typedWhileHeld = true }
    }

    private func startBackspaceRepeat(_ t: Tracked, start: Date) {
        guard t.mode == .repeating else { return }
        t.timer = Timer.scheduledTimer(withTimeInterval: KeyTiming.backspaceRepeatInterval, repeats: true) { [weak self, weak t] _ in
            guard let self = self, let t = t else { return }
            t.repeatTicks += 1
            let wordMode = Date().timeIntervalSince(start) > KeyTiming.backspaceWordModeDelay
            // Whole words go at half the rate (every 0.18 s), so the user can stop in time.
            if wordMode, t.repeatTicks % 2 != 0 { return }
            self.delegate?.keyboardView(self, didTrigger: .backspaceRepeat(wordMode: wordMode))
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
        // A touch that is no longer tracked (committed by rollover, cancelled) must not open anything.
        guard tracked.values.contains(where: { $0 === t }), t.mode == .normal, frames.indices.contains(t.frameIndex) else { return }
        let key = t.key
        switch key.action {
        case .space:
            t.mode = .trackpad
            // Measure the drag from where the finger is now, not from where it first touched.
            t.trackpadOriginX = t.lastX
            t.cursorSteps = 0
            popup.isHidden = true
            trackpadActive = true
            delegate?.keyboardView(self, didTrigger: .trackpad(true))
            refreshAppearance()
        case .nextLanguage:
            t.mode = .callout
            let current = languages.firstIndex(where: { $0.shortLabel == key.label }) ?? 0
            showCallout(options: languages.map { $0.displayName }, for: t.frameIndex, selected: current)
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
                t.lastX = point.x
                // Steps from the start, truncated towards zero (symmetric). Carrying a remainder instead
                // drifted: +20 pt then back to +2 pt moved the cursor +2, -1.
                let target = Int((point.x - t.trackpadOriginX) / KeyTiming.trackpadStep)
                let n = target - t.cursorSteps
                if n != 0 {
                    t.cursorSteps = target
                    delegate?.keyboardView(self, didTrigger: .moveCursor(n))
                }
            case .callout:
                callout.select(at: convert(point, to: callout))
            case .pageHold:
                t.lastPoint = point
                t.travel = max(t.travel, hypot(point.x - t.startPoint.x, point.y - t.startPoint.y))
                // Slid onto a key of the new page (Apple's slide from "123"): it types when released, then
                // the page goes back.
                guard let hit = resolver?.resolve(point, letterLog2Prior: [:]), hit.frameIndex != t.frameIndex,
                      frames.indices.contains(hit.frameIndex), frames[hit.frameIndex].key.style == .character else { continue }
                let key = frames[hit.frameIndex].key
                t.mode = .normal
                t.frameIndex = hit.frameIndex
                t.key = key
                t.tap = nil
                t.lastX = point.x
                showPopup(for: hit.frameIndex)
                if !keyAlternates(key).isEmpty { scheduleLongPress(t, delay: 0.42) }
                refreshAppearance()
            case .normal:
                t.lastX = point.x
                t.travel = max(t.travel, hypot(point.x - t.startPoint.x, point.y - t.startPoint.y))
                if t.key.action == .globe {
                    if let event = event { delegate?.keyboardView(self, globeTouchedWith: event, in: self) }
                    continue
                }
                guard t.key.style == .character, let hit = resolver?.resolve(point, letterLog2Prior: letterPrior), hit.frameIndex != t.frameIndex,
                      frames.indices.contains(hit.frameIndex), frames[hit.frameIndex].key.style == .character else { continue }
                // Slide to a neighbouring character key.
                let key = frames[hit.frameIndex].key
                t.frameIndex = hit.frameIndex
                t.key = key
                t.tap = hit.tap
                showPopup(for: hit.frameIndex)
                t.timer?.invalidate()
                t.timer = nil
                if !keyAlternates(key).isEmpty { scheduleLongPress(t, delay: 0.42) }
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
            t.timer = nil
            if t.mode == .pageHold {
                releasePageKey(t)
            } else if t.key.action == .globe {
                if let event = event { delegate?.keyboardView(self, globeTouchedWith: event, in: self) }
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
            guard let t = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            t.timer?.invalidate()
            t.timer = nil
            // iOS cancels touches when it suspects a system gesture (keys at the screen edges, fast typing
            // with both thumbs): a short tap that stayed in place was a key press and still types.
            if t.mode == .normal, Self.commitsOnRollover(t.key),
               ProcessInfo.processInfo.systemUptime - t.beganAt <= KeyTiming.cancelledTapMaxDuration,
               t.travel <= KeyTiming.cancelledTapMaxTravel {
                commit(t)
                continue
            }
            if t.key.action == .globe, let event = event {
                // The system must see the end of a globe touch too, or its keyboard list stays open.
                delegate?.keyboardView(self, globeTouchedWith: event, in: self)
            }
            if t.mode == .trackpad, trackpadActive {
                trackpadActive = false
                delegate?.keyboardView(self, didTrigger: .trackpad(false))
            }
            if t.mode == .callout { callout.isHidden = true }
            if t.mode == .pageHold { releasePageKey(t) }
            if t.key.action == .shift { delegate?.keyboardView(self, didTrigger: .shiftReleased) }
        }
        if tracked.isEmpty {
            popup.isHidden = true
            callout.isHidden = true
        }
        refreshAppearance()
    }

    private func commit(_ t: Tracked) {
        t.timer?.invalidate()
        t.timer = nil
        let key = t.key
        // Only this touch's own preview: releasing shift before the letter it capitalises must not hide
        // the letter's preview while that key is still held.
        if popupIndex == t.frameIndex { popup.isHidden = true }
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
                    noteTyped()
                    delegate?.keyboardView(self, didTrigger: .character(text: options[index], tap: nil, isLetter: key.isLetter))
                    returnAfterSlide(t)
                }
            }
            return
        case .repeating, .pageHold:
            return
        case .normal:
            break
        }
        switch key.action {
        case .insert(let text):
            noteTyped()
            delegate?.keyboardView(self, didTrigger: .character(text: text, tap: key.isLetter ? t.tap : nil, isLetter: key.isLetter))
            returnAfterSlide(t)
        case .space:
            noteTyped()
            delegate?.keyboardView(self, didTrigger: .space)
        case .returnKey:
            // Dimmed return key (`enablesReturnKeyAutomatically` and an empty field): like the system
            // keyboard it does nothing, so e.g. an empty search or message is not submitted.
            if returnEnabled {
                noteTyped()
                delegate?.keyboardView(self, didTrigger: .returnKey)
            }
        case .switchPage(let page): delegate?.keyboardView(self, didTrigger: .switchPage(page))
        case .emoji: delegate?.keyboardView(self, didTrigger: .emoji)
        case .nextLanguage: delegate?.keyboardView(self, didTrigger: .nextLanguage)
        case .shift: delegate?.keyboardView(self, didTrigger: .shiftReleased)
        case .backspace, .globe, .none: break
        }
    }

    /// A key slid onto from a page key was typed: back to the page the page key came from.
    private func returnAfterSlide(_ t: Tracked) {
        guard let page = t.returnPage, layout?.page != page else { return }
        delegate?.keyboardView(self, didTrigger: .switchPage(page))
    }

    // MARK: Popups

    /// Top of the keyboard's input view in this view's coordinates: the system clips anything above it.
    private var visibleTop: CGFloat {
        guard let container = superview else { return 0 }
        return convert(CGPoint(x: 0, y: container.bounds.minY), from: container).y
    }

    private func showPopup(for index: Int) {
        guard let theme = theme, frames.indices.contains(index), showsPopup(for: frames[index].key) else { popup.isHidden = true; return }
        let key = frames[index].key
        popupIndex = index
        popup.show(text: displayLabel(key, theme: theme), keyRect: frames[index].rect, in: bounds, minY: visibleTop, theme: theme)
        bringSubviewToFront(popup)
    }

    private func showCallout(options: [String], for index: Int, selected: Int) {
        guard let theme = theme, frames.indices.contains(index) else { return }
        callout.show(options: options, keyRect: frames[index].rect, in: bounds, minY: visibleTop, theme: theme, selected: selected)
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

    /// `minY` is the highest visible y (the top of the input view); the balloon never goes above it.
    func show(text: String, keyRect: CGRect, in bounds: CGRect, minY: CGFloat, theme: KeyboardTheme) {
        let extra: CGFloat = 10
        let topHeight = keyRect.height * 1.05
        var top = CGRect(x: keyRect.minX - extra, y: keyRect.minY - topHeight - 4, width: keyRect.width + 2 * extra, height: topHeight)
        top.origin.x = min(max(top.minX, 0), bounds.width - top.width)
        top.origin.y = max(top.minY, minY)
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
        shape.fillColor = theme.characterKeyColor.cgColor
        CATransaction.commit()
        label.text = text
        label.textColor = theme.labelUIColor
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
    /// Horizontal menu laid out right-to-left (keys on the right half), so option 0 sits above the key.
    private var reversed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the menu above `keyRect`, inside `bounds` horizontally and below `minY` (the top of the
    /// input view; the system clips anything above it) vertically.
    func show(options: [String], keyRect: CGRect, in bounds: CGRect, minY: CGFloat, theme: KeyboardTheme, selected: Int) {
        self.theme = theme
        labels.forEach { $0.removeFromSuperview() }
        labels = []
        guard !options.isEmpty else {
            selectedIndex = nil
            isHidden = true
            return
        }
        vertical = options.contains { $0.count > 3 }
        let count = CGFloat(options.count)
        let gap: CGFloat = 6
        let cell: CGSize
        if vertical {
            // Rows shrink (down to 28 pt) so a long language list fits between the top and the key.
            let room = keyRect.minY - gap - minY
            cell = CGSize(width: min(190, max(bounds.width - 4, 1)), height: max(28, min(40, room / count)))
        } else {
            // Cells shrink so even a long accent list fits the width.
            cell = CGSize(width: min(max(30, keyRect.width), max(bounds.width - 4, 1) / count), height: keyRect.height + 4)
        }
        let size = vertical ? CGSize(width: cell.width, height: cell.height * count)
                            : CGSize(width: cell.width * count, height: cell.height)
        reversed = !vertical && options.count > 1 && keyRect.midX > bounds.midX
        var origin = CGPoint(x: reversed ? keyRect.midX + cell.width / 2 - size.width : keyRect.midX - cell.width / 2,
                             y: max(minY, keyRect.minY - size.height - gap))
        if vertical { origin.x = keyRect.minX }
        origin.x = min(max(origin.x, 2), bounds.width - size.width - 2)
        frame = CGRect(origin: origin, size: size)
        backgroundColor = theme.characterKeyColor
        layer.cornerRadius = theme.cornerRadius + 2
        for (i, option) in options.enumerated() {
            let l = UILabel()
            l.text = option
            l.textAlignment = .center
            l.font = .systemFont(ofSize: vertical ? 17 : 24 * theme.labelScale)
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.6
            l.layer.cornerRadius = theme.cornerRadius
            l.layer.masksToBounds = true
            let slot = reversed ? options.count - 1 - i : i
            l.frame = vertical ? CGRect(x: 0, y: CGFloat(i) * cell.height, width: cell.width, height: cell.height)
                               : CGRect(x: CGFloat(slot) * cell.width, y: 0, width: cell.width, height: cell.height)
            addSubview(l)
            labels.append(l)
        }
        setSelected(min(max(selected, 0), options.count - 1))
        isHidden = false
    }

    func select(at point: CGPoint) {
        guard !labels.isEmpty else { return }
        if vertical {
            // The finger starts on the key below the list: keep the current choice until it moves up into
            // the list, so a long-press released without moving changes nothing.
            guard point.y < bounds.height else { return }
            let height = max(labels[0].frame.height, 1)
            setSelected(min(max(Int(floor(point.y / height)), 0), labels.count - 1))
        } else {
            let width = max(labels[0].frame.width, 1)
            let slot = min(max(Int(floor(point.x / width)), 0), labels.count - 1)
            setSelected(reversed ? labels.count - 1 - slot : slot)
        }
    }

    private func setSelected(_ index: Int) {
        guard let theme = theme else { return }
        selectedIndex = index
        for (i, l) in labels.enumerated() {
            l.backgroundColor = i == index ? theme.accentColor : .clear
            l.textColor = i == index ? .white : theme.labelUIColor
        }
    }
}
