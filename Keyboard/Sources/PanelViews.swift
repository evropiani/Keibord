import UIKit
import KeibordCore

// MARK: - Suggestion bar

protocol SuggestionBarDelegate: AnyObject {
    func suggestionBar(_ bar: SuggestionBarView, didSelect suggestion: Suggestion)
}

final class SuggestionBarView: UIView {
    weak var delegate: SuggestionBarDelegate?
    private var buttons: [UIButton] = []
    private var separators: [UIView] = []
    private var highlight = UIView()
    private var items: [Suggestion] = []
    /// The slot under the finger. The bar tracks touches itself: every slot is tappable across its whole
    /// third of the bar (gaps and separators included), not only on the drawn word.
    private var pressedSlot: Int? {
        didSet {
            guard pressedSlot != oldValue else { return }
            for (i, b) in buttons.enumerated() { b.isHighlighted = i == pressedSlot }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .touchableClear // empty areas must take touches too
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        for i in 0..<3 {
            let b = UIButton(type: .system)
            b.tag = i
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.6
            b.titleLabel?.lineBreakMode = .byTruncatingMiddle
            b.isUserInteractionEnabled = false // drawn only; touches go to the bar (see `slot(at:)`)
            addSubview(b)
            buttons.append(b)
        }
        for _ in 0..<2 {
            let s = UIView()
            addSubview(s)
            separators.append(s)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var appliedTheme: (dark: Bool, label: UIColor, accent: UIColor, highlight: UIColor, radius: CGFloat)?

    func update(_ newItems: [Suggestion], theme: KeyboardTheme) {
        let trimmed = Array(newItems.prefix(3))
        let themeKey = (dark: theme.isDark, label: theme.labelUIColor, accent: theme.accentColor, highlight: theme.barHighlight, radius: theme.cornerRadius)
        // render() runs on every keystroke: leave the buttons alone when nothing changed.
        if trimmed == items, let applied = appliedTheme, applied.dark == themeKey.dark, applied.label == themeKey.label,
           applied.accent == themeKey.accent, applied.highlight == themeKey.highlight, applied.radius == themeKey.radius {
            return
        }
        appliedTheme = themeKey
        items = trimmed
        pressedSlot = nil
        let single = items.count == 1 && (items[0].kind == .action || items[0].kind == .card)
        // System buttons cross-fade title changes; while typing that makes the bar flicker.
        UIView.performWithoutAnimation {
            for (i, b) in buttons.enumerated() {
                if i < items.count {
                    let s = items[i]
                    b.isHidden = false
                    b.setTitle(s.display, for: .normal)
                    b.setTitleColor(s.kind == .action ? theme.accentColor : theme.labelUIColor, for: .normal)
                    let bold = s.isAutocorrect || s.kind == .card || s.kind == .action
                    b.titleLabel?.font = .systemFont(ofSize: 16, weight: bold ? .semibold : .regular)
                } else {
                    b.isHidden = true
                    b.setTitle(nil, for: .normal)
                }
                b.layoutIfNeeded()
            }
        }
        separators.forEach { $0.backgroundColor = theme.labelUIColor.withAlphaComponent(0.18) }
        separators[0].isHidden = items.count < 2 || single
        separators[1].isHidden = items.count < 3 || single
        highlight.backgroundColor = theme.barHighlight
        highlight.layer.cornerRadius = theme.cornerRadius
        highlight.isHidden = !items.contains { $0.isAutocorrect }
        setNeedsLayout()
    }

    /// The words' middle sits this far below the bar's middle. iOS 26/27 draws a 17 pt glass strip above
    /// third-party keyboards in some places (Spotlight, the App Library, apps after switching) and leaves
    /// it out in others (apps at first), and the keyboard cannot tell which: its view, window and safe area
    /// are the same either way (Apple developer forums thread 843093). No single position is centred in
    /// both cases, so the words sit between the two: a little high without the strip, a little low with
    /// it, never against the top edge. (1.0.8–1.0.20 placed them for the strip, 3.5 pt above the middle,
    /// and in apps without it they sat against the edge.)
    static let textOffset: CGFloat = 2.5

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = max(items.count, 1)
        let w = bounds.width / CGFloat(count == 1 ? 1 : 3)
        // 29 pt in the 36 pt bar, so the autocorrect highlight (2 pt inside it) stays inside the bar.
        let textHeight = max(0, bounds.height - 7)
        let textTop = (bounds.height - textHeight) / 2 + Self.textOffset
        for (i, b) in buttons.enumerated() {
            let x: CGFloat = count == 1 ? 0 : CGFloat(i) * w
            b.frame = CGRect(x: x + 4, y: textTop, width: (count == 1 ? bounds.width : w) - 8, height: textHeight)
        }
        for (i, s) in separators.enumerated() {
            s.frame = CGRect(x: CGFloat(i + 1) * w, y: textTop + textHeight * 0.25, width: 1 / max(traitCollection.displayScale, 1), height: textHeight * 0.5)
        }
        if let index = items.firstIndex(where: { $0.isAutocorrect }), index < buttons.count {
            highlight.frame = buttons[index].frame.insetBy(dx: -2, dy: 2)
        }
    }

    /// The slot a point belongs to: the whole bar for a single item, otherwise its third of the bar
    /// (as laid out by `layoutSubviews`), at any height of the bar.
    func slot(at point: CGPoint) -> Int? {
        guard !items.isEmpty, point.x >= 0, point.x <= bounds.width, bounds.width > 0 else { return nil }
        if items.count == 1 { return 0 }
        let index = min(2, max(0, Int(point.x / (bounds.width / 3))))
        return index < items.count ? index : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        pressedSlot = slot(at: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, pressedSlot != nil else { return }
        let p = touch.location(in: self)
        // Like a button: sliding far off the slot cancels the tap, sliding back restores it.
        pressedSlot = p.y < -40 || p.y > bounds.height + 40 ? nil : slot(at: p)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { pressedSlot = nil }
        guard let touch = touches.first, let slot = pressedSlot, slot == self.slot(at: touch.location(in: self)),
              slot < items.count else { return }
        delegate?.suggestionBar(self, didSelect: items[slot])
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressedSlot = nil
    }
}

// MARK: - Emoji panel

protocol EmojiPanelDelegate: AnyObject {
    func emojiPanel(_ panel: EmojiPanelView, didSelect emoji: String)
    func emojiPanelDidTapBackspace(_ panel: EmojiPanelView)
    func emojiPanelDidTapABC(_ panel: EmojiPanelView)
    func emojiPanelDidRequestSearch(_ panel: EmojiPanelView)
}

final class EmojiCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 31)
        contentView.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }
}

final class EmojiPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    weak var delegate: EmojiPanelDelegate?
    private var sections: [EmojiCategory] = []
    private var catalog: EmojiCatalog?
    /// Grid emoji → the skin tone last chosen for it (shown and inserted instead of the plain emoji).
    private var preferred: [String: String] = [:]
    /// The grid emoji whose variants the long-press menu shows.
    private var variantBase: String?
    private let searchButton = UIButton(type: .system)
    private let collection: UICollectionView
    private let bottomBar = UIStackView()
    private var categoryButtons: [UIButton] = []
    private let variantStack = UIStackView()
    private var theme: KeyboardTheme?
    private var languageCode = "en"
    /// Backspace held down: deletes again after 0.5 s, then every 0.09 s (like the key area).
    private var backspaceTimer: Timer?

    override init(frame: CGRect) {
        let flow = UICollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = CGSize(width: 42, height: 42)
        flow.minimumInteritemSpacing = 0
        flow.minimumLineSpacing = 0
        flow.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(frame: frame)
        backgroundColor = .touchableClear // empty areas must take touches too
        collection.backgroundColor = .touchableClear // scrolling starts between emoji too
        collection.showsHorizontalScrollIndicator = false
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
        collection.dataSource = self
        collection.delegate = self
        addSubview(collection)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.35
        collection.addGestureRecognizer(press)

        searchButton.contentHorizontalAlignment = .left
        searchButton.layer.cornerRadius = 9
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        addSubview(searchButton)

        bottomBar.axis = .horizontal
        bottomBar.distribution = .fillEqually
        addSubview(bottomBar)

        variantStack.axis = .vertical
        variantStack.distribution = .fillEqually
        variantStack.isHidden = true
        variantStack.layer.cornerRadius = 10
        variantStack.layer.shadowOpacity = 0.3
        variantStack.layer.shadowRadius = 4
        addSubview(variantStack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `used`: every emoji used, newest first (for the skin tone last chosen per emoji).
    func configure(catalog: EmojiCatalog?, recents: [String], used: [String] = [], theme: KeyboardTheme, languageCode: String) {
        stopBackspaceRepeat() // the bottom bar (and a held backspace button) is rebuilt below
        self.catalog = catalog
        preferred = catalog?.preferredVariants(used: used) ?? [:]
        self.theme = theme
        self.languageCode = languageCode
        var s: [EmojiCategory] = []
        if !recents.isEmpty { s.append(EmojiCategory(id: "recents", emojis: recents)) }
        s += catalog?.categories ?? []
        sections = s
        collection.reloadData()

        let search: String
        switch languageCode {
        case "de": search = "Emoji suchen"
        case "sq": search = "Kërko emoji"
        case "it": search = "Cerca emoji"
        default: search = "Search Emoji"
        }
        searchButton.setTitle("  \u{1F50D} " + search, for: .normal)
        searchButton.setTitleColor(theme.secondaryLabel, for: .normal)
        searchButton.backgroundColor = theme.colors.characterKey.uiColor.withAlphaComponent(theme.isDark ? 0.5 : 0.8)

        bottomBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        categoryButtons = []
        let abc = UIButton(type: .system)
        abc.setTitle("ABC", for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        abc.setTitleColor(theme.colors.label.uiColor, for: .normal)
        abc.addTarget(self, action: #selector(abcTapped), for: .touchUpInside)
        bottomBar.addArrangedSubview(abc)
        for (i, section) in sections.enumerated() {
            let b = UIButton(type: .system)
            b.tag = i
            b.setImage(UIImage(systemName: section.symbolName), for: .normal)
            b.tintColor = theme.secondaryLabel
            b.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
            bottomBar.addArrangedSubview(b)
            categoryButtons.append(b)
        }
        let back = UIButton(type: .system)
        back.setImage(UIImage(systemName: "delete.left"), for: .normal)
        back.tintColor = theme.colors.label.uiColor
        // Deletes on touch-down and repeats while held, like the backspace key of the letters.
        back.addTarget(self, action: #selector(backDown), for: .touchDown)
        back.addTarget(self, action: #selector(backUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bottomBar.addArrangedSubview(back)
        variantStack.backgroundColor = theme.colors.characterKey.uiColor
        updateCategoryHighlight()
    }

    /// Frees the catalog (and the keyword tables it loaded for searching) while the panel is hidden;
    /// `configure` is called again before it is shown.
    func releaseData() {
        stopBackspaceRepeat()
        catalog = nil
        sections = []
        preferred = [:]
        variantBase = nil
        variantStack.isHidden = true
        collection.reloadData()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        searchButton.frame = CGRect(x: 8, y: 6, width: bounds.width - 16, height: 32)
        let barHeight: CGFloat = 40
        bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        collection.frame = CGRect(x: 0, y: 42, width: bounds.width, height: bounds.height - 42 - barHeight)
        if let flow = collection.collectionViewLayout as? UICollectionViewFlowLayout {
            let rows = max(1, floor(collection.bounds.height / 42))
            let side = collection.bounds.height / rows
            if flow.itemSize.height != side { flow.itemSize = CGSize(width: side, height: side) }
        }
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].emojis.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "e", for: indexPath) as! EmojiCell
        cell.label.text = shownEmoji(at: indexPath)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        variantStack.isHidden = true
        delegate?.emojiPanel(self, didSelect: shownEmoji(at: indexPath))
    }

    /// The emoji of a cell: recents as used, grid emoji in the skin tone last chosen.
    private func shownEmoji(at indexPath: IndexPath) -> String {
        let section = sections[indexPath.section]
        let emoji = section.emojis[indexPath.item]
        return section.id == "recents" ? emoji : (preferred[emoji] ?? emoji)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        variantStack.isHidden = true
        updateCategoryHighlight()
    }

    private func updateCategoryHighlight() {
        guard let theme = theme else { return }
        let x = collection.contentOffset.x + 20
        var current = 0
        for i in 0..<sections.count {
            if let attrs = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: i)), attrs.frame.minX <= x { current = i }
        }
        for (i, b) in categoryButtons.enumerated() {
            b.tintColor = i == current ? theme.colors.label.uiColor : theme.secondaryLabel
        }
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard sender.tag < sections.count, !sections[sender.tag].emojis.isEmpty else { return }
        collection.scrollToItem(at: IndexPath(item: 0, section: sender.tag), at: .left, animated: false)
        updateCategoryHighlight()
    }

    @objc private func abcTapped() { delegate?.emojiPanelDidTapABC(self) }
    @objc private func backDown() {
        stopBackspaceRepeat()
        delegate?.emojiPanelDidTapBackspace(self)
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // Stop once the panel was closed (ABC) or the keyboard went away.
                guard self.window != nil, !self.isHidden else { self.stopBackspaceRepeat(); return }
                self.delegate?.emojiPanelDidTapBackspace(self)
            }
        }
    }

    @objc private func backUp() { stopBackspaceRepeat() }

    func stopBackspaceRepeat() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
    }

    @objc private func searchTapped() { delegate?.emojiPanelDidRequestSearch(self) }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let path = collection.indexPathForItem(at: g.location(in: collection)),
              let cell = collection.cellForItem(at: path) else { return }
        let shown = sections[path.section].emojis[path.item]
        let emoji = catalog?.base(of: shown) ?? shown // a toned recent offers its emoji's tones too
        let variants = catalog?.variants(of: emoji) ?? []
        guard !variants.isEmpty else { return }
        variantBase = emoji
        // Two people with a skin tone each: the plain emoji above a 5 × 5 grid (row: first person,
        // column: second). Everything else: one row with the plain emoji first.
        let grid = variants.count == 25
        let rows: [[String]] = grid ? [[emoji]] + stride(from: 0, to: 25, by: 5).map { Array(variants[$0 ..< $0 + 5]) }
                                    : [Array(([emoji] + variants).prefix(6))]
        let side: CGFloat = grid ? 40 : 46
        variantStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            let line = UIStackView()
            line.axis = .horizontal
            line.distribution = .fillEqually
            for option in row {
                let b = UIButton(type: .system)
                b.setTitle(option, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: grid ? 26 : 30)
                b.addTarget(self, action: #selector(variantTapped(_:)), for: .touchUpInside)
                line.addArrangedSubview(b)
            }
            variantStack.addArrangedSubview(line)
        }
        let cellFrame = cell.convert(cell.bounds, to: self)
        let width = CGFloat(rows.map(\.count).max() ?? 1) * side
        let height = CGFloat(rows.count) * side + 2
        let x = min(max(cellFrame.midX - width / 2, 4), bounds.width - width - 4)
        let y = min(max(0, cellFrame.minY - height - 2), max(0, bounds.height - height))
        variantStack.frame = CGRect(x: x, y: y, width: width, height: height)
        variantStack.isHidden = false
        bringSubviewToFront(variantStack)
    }

    @objc private func variantTapped(_ sender: UIButton) {
        variantStack.isHidden = true
        guard let e = sender.title(for: .normal) else { return }
        if let base = variantBase {
            preferred[base] = e
            collection.reloadData()
        }
        delegate?.emojiPanel(self, didSelect: e)
    }
}

// MARK: - Emoji search bar (shown above the letter keys while searching)

protocol EmojiSearchBarDelegate: AnyObject {
    func emojiSearchBar(_ bar: EmojiSearchBarView, didSelect emoji: String)
    func emojiSearchBarDidCancel(_ bar: EmojiSearchBarView)
}

final class EmojiSearchBarView: UIView {
    weak var delegate: EmojiSearchBarDelegate?
    private let field = UILabel()
    private let cancel = UIButton(type: .system)
    private let results = UIScrollView()
    private(set) var query = ""
    private var placeholder = "Search Emoji"
    private var theme: KeyboardTheme?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .touchableClear // empty areas must take touches too
        field.layer.cornerRadius = 9
        field.layer.masksToBounds = true
        addSubview(field)
        cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        addSubview(cancel)
        results.showsHorizontalScrollIndicator = false
        addSubview(results)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(theme: KeyboardTheme, placeholder: String) {
        self.theme = theme
        self.placeholder = placeholder
        field.backgroundColor = theme.colors.characterKey.uiColor.withAlphaComponent(theme.isDark ? 0.5 : 0.85)
        field.textColor = theme.colors.label.uiColor
        cancel.tintColor = theme.secondaryLabel
        refreshField()
    }

    func setQuery(_ q: String, results emojis: [String]) {
        query = q
        refreshField()
        results.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 4
        for e in emojis {
            let b = UIButton(type: .system)
            b.setTitle(e, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 28)
            b.frame = CGRect(x: x, y: 0, width: 44, height: 44)
            b.addTarget(self, action: #selector(resultTapped(_:)), for: .touchUpInside)
            results.addSubview(b)
            x += 44
        }
        results.contentSize = CGSize(width: x + 4, height: 44)
        results.contentOffset = .zero
    }

    private func refreshField() {
        field.text = "  \u{1F50D} " + (query.isEmpty ? placeholder : query + "|")
        field.alpha = query.isEmpty ? 0.7 : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = CGRect(x: 8, y: 6, width: bounds.width - 52, height: 32)
        cancel.frame = CGRect(x: bounds.width - 42, y: 4, width: 36, height: 36)
        results.frame = CGRect(x: 0, y: 44, width: bounds.width, height: 44)
    }

    @objc private func cancelTapped() { delegate?.emojiSearchBarDidCancel(self) }

    @objc private func resultTapped(_ sender: UIButton) {
        if let e = sender.title(for: .normal) { delegate?.emojiSearchBar(self, didSelect: e) }
    }
}

// MARK: - Card unlock (CVV entry)

protocol CardUnlockViewDelegate: AnyObject {
    func cardUnlockView(_ view: CardUnlockView, didEnter cvv: String)
    func cardUnlockViewDidCancel(_ view: CardUnlockView)
}

final class CardUnlockView: UIView {
    weak var delegate: CardUnlockViewDelegate?
    private let title = UILabel()
    private let dots = UILabel()
    private let error = UILabel()
    private var buttons: [UIButton] = []
    private var digits = ""
    private var length = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .touchableClear // empty areas must take touches too
        title.textAlignment = .center
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        dots.textAlignment = .center
        dots.font = .systemFont(ofSize: 22, weight: .bold)
        error.textAlignment = .center
        error.font = .systemFont(ofSize: 13)
        error.textColor = .systemRed
        [title, dots, error].forEach { addSubview($0) }
        for label in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "✕", "0", "⌫"] {
            let b = UIButton(type: .system)
            b.setTitle(label, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 22)
            b.layer.cornerRadius = 8
            b.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            addSubview(b)
            buttons.append(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title text: String, cvvLength: Int, theme: KeyboardTheme) {
        title.text = text
        title.textColor = theme.colors.label.uiColor
        dots.textColor = theme.colors.label.uiColor
        length = cvvLength
        digits = ""
        error.text = nil
        for b in buttons {
            b.backgroundColor = theme.colors.characterKey.uiColor
            b.setTitleColor(theme.colors.label.uiColor, for: .normal)
        }
        refreshDots()
    }

    func showError(_ message: String) {
        error.text = message
        digits = ""
        refreshDots()
    }

    private func refreshDots() {
        dots.text = String(repeating: "● ", count: digits.count) + String(repeating: "○ ", count: max(0, length - digits.count))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 8, y: 6, width: bounds.width - 16, height: 20)
        dots.frame = CGRect(x: 8, y: 28, width: bounds.width - 16, height: 26)
        error.frame = CGRect(x: 8, y: 54, width: bounds.width - 16, height: 16)
        let top: CGFloat = 74
        let gap: CGFloat = 6
        let w = (bounds.width - 4 * gap) / 3
        let h = max(30, (bounds.height - top - 5 * gap) / 4)
        for (i, b) in buttons.enumerated() {
            let row = CGFloat(i / 3), col = CGFloat(i % 3)
            b.frame = CGRect(x: gap + col * (w + gap), y: top + gap + row * (h + gap), width: w, height: h)
        }
    }

    @objc private func pressed(_ sender: UIButton) {
        guard let t = sender.title(for: .normal) else { return }
        switch t {
        case "✕": delegate?.cardUnlockViewDidCancel(self)
        case "⌫": if !digits.isEmpty { digits.removeLast() }
        default:
            guard digits.count < length else { return }
            digits += t
            error.text = nil
        }
        refreshDots()
        if digits.count == length {
            let entered = digits
            // Do not keep the security code around in the view once it was handed over.
            digits = ""
            delegate?.cardUnlockView(self, didEnter: entered)
            refreshDots()
        }
    }
}
