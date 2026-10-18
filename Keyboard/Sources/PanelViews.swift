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

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.isUserInteractionEnabled = false
        addSubview(highlight)
        for i in 0..<3 {
            let b = UIButton(type: .system)
            b.tag = i
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.6
            b.titleLabel?.lineBreakMode = .byTruncatingMiddle
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = max(items.count, 1)
        let w = bounds.width / CGFloat(count == 1 ? 1 : 3)
        for (i, b) in buttons.enumerated() {
            let x: CGFloat = count == 1 ? 0 : CGFloat(i) * w
            b.frame = CGRect(x: x + 4, y: 0, width: (count == 1 ? bounds.width : w) - 8, height: bounds.height)
        }
        for (i, s) in separators.enumerated() {
            s.frame = CGRect(x: CGFloat(i + 1) * w, y: bounds.height * 0.25, width: 1 / max(traitCollection.displayScale, 1), height: bounds.height * 0.5)
        }
        if let index = items.firstIndex(where: { $0.isAutocorrect }), index < buttons.count {
            highlight.frame = buttons[index].frame.insetBy(dx: -2, dy: 6)
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        guard sender.tag < items.count else { return }
        delegate?.suggestionBar(self, didSelect: items[sender.tag])
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
    private let searchButton = UIButton(type: .system)
    private let collection: UICollectionView
    private let bottomBar = UIStackView()
    private var categoryButtons: [UIButton] = []
    private let variantStack = UIStackView()
    private var theme: KeyboardTheme?
    private var languageCode = "en"

    override init(frame: CGRect) {
        let flow = UICollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = CGSize(width: 42, height: 42)
        flow.minimumInteritemSpacing = 0
        flow.minimumLineSpacing = 0
        flow.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(frame: frame)
        collection.backgroundColor = .clear
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

        variantStack.axis = .horizontal
        variantStack.distribution = .fillEqually
        variantStack.isHidden = true
        variantStack.layer.cornerRadius = 10
        variantStack.layer.shadowOpacity = 0.3
        variantStack.layer.shadowRadius = 4
        addSubview(variantStack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(catalog: EmojiCatalog?, recents: [String], theme: KeyboardTheme, languageCode: String) {
        self.catalog = catalog
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
        back.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        bottomBar.addArrangedSubview(back)
        variantStack.backgroundColor = theme.colors.characterKey.uiColor
        updateCategoryHighlight()
    }

    /// Frees the catalog (and the keyword tables it loaded for searching) while the panel is hidden;
    /// `configure` is called again before it is shown.
    func releaseData() {
        catalog = nil
        sections = []
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
        cell.label.text = sections[indexPath.section].emojis[indexPath.item]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        variantStack.isHidden = true
        delegate?.emojiPanel(self, didSelect: sections[indexPath.section].emojis[indexPath.item])
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
    @objc private func backTapped() { delegate?.emojiPanelDidTapBackspace(self) }
    @objc private func searchTapped() { delegate?.emojiPanelDidRequestSearch(self) }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let path = collection.indexPathForItem(at: g.location(in: collection)),
              let cell = collection.cellForItem(at: path) else { return }
        let emoji = sections[path.section].emojis[path.item]
        let options = [emoji] + (catalog?.variants(of: emoji) ?? [])
        guard options.count > 1 else { return }
        variantStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for option in options.prefix(6) {
            let b = UIButton(type: .system)
            b.setTitle(option, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 30)
            b.addTarget(self, action: #selector(variantTapped(_:)), for: .touchUpInside)
            variantStack.addArrangedSubview(b)
        }
        let cellFrame = cell.convert(cell.bounds, to: self)
        let width = CGFloat(min(options.count, 6)) * 46
        let x = min(max(cellFrame.midX - width / 2, 4), bounds.width - width - 4)
        variantStack.frame = CGRect(x: x, y: max(0, cellFrame.minY - 50), width: width, height: 48)
        variantStack.isHidden = false
        bringSubviewToFront(variantStack)
    }

    @objc private func variantTapped(_ sender: UIButton) {
        variantStack.isHidden = true
        if let e = sender.title(for: .normal) { delegate?.emojiPanel(self, didSelect: e) }
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
