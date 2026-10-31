import XCTest
import UIKit
import KeibordCore
@testable import KeyboardCheck

private final class PanelRecorder: EmojiPanelDelegate {
    var selected: [String] = []
    func emojiPanel(_ panel: EmojiPanelView, didSelect emoji: String) { selected.append(emoji) }
    func emojiPanel(_ panel: EmojiPanelView, didSelectSticker id: String) { selected.append("sticker:" + id) }
    func emojiPanelDidTapBackspace(_ panel: EmojiPanelView) {}
    func emojiPanelDidTapABC(_ panel: EmojiPanelView) {}
    func emojiPanelDidRequestSearch(_ panel: EmojiPanelView) {}
}

final class EmojiPanelTests: XCTestCase {
    private func catalog() throws -> EmojiCatalog {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try EmojiCatalog(baseURL: repo.appendingPathComponent("Resources/Emoji"))
    }

    func testTheGridInsertsTheSkinToneChosenLast() throws {
        let catalog = try catalog()
        let panel = EmojiPanelView(frame: CGRect(x: 0, y: 0, width: 390, height: 260))
        let recorder = PanelRecorder()
        panel.delegate = recorder
        panel.configure(catalog: catalog, recents: [], used: ["👍🏾", "👍🏻"], theme: KeyboardTheme(settings: KeibordSettings(), dark: false), languageCode: "de")
        guard let section = catalog.categories.firstIndex(where: { $0.emojis.contains("👍") }),
              let item = catalog.categories[section].emojis.firstIndex(of: "👍"),
              let smile = catalog.categories[section].emojis.firstIndex(of: "😀") else { return XCTFail("no 👍 in the grid") }
        let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: item, section: section))
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: smile, section: section))
        XCTAssertEqual(recorder.selected, ["👍🏾", "😀"])
    }

    func testFavoritesComeFirstOnTheRecentsPageWithoutRepeatingInTheRecents() throws {
        let catalog = try catalog()
        let panel = EmojiPanelView(frame: CGRect(x: 0, y: 0, width: 440, height: 313))
        let recorder = PanelRecorder()
        panel.delegate = recorder
        panel.configure(catalog: catalog, recents: ["😂", "❤️", "🥳"], favorites: ["❤️", "👍🏽"], used: ["👍🏾"],
                        theme: KeyboardTheme(settings: KeibordSettings(), dark: false), languageCode: "de")
        let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        XCTAssertEqual(panel.numberOfSections(in: grid), 2 + catalog.categories.count)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 2)
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 1), 2, "❤️ only once, as a favourite")
        for path in [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0), IndexPath(item: 0, section: 1), IndexPath(item: 1, section: 1)] {
            panel.collectionView(grid, didSelectItemAt: path)
        }
        XCTAssertEqual(recorder.selected, ["❤️", "👍🏽", "😂", "🥳"], "favourites as chosen, not in the skin tone used last")
        // One clock button for the favourites and the recents: ABC, the pages, backspace.
        let bar = panel.subviews.compactMap { $0 as? UIStackView }.first { $0.axis == .horizontal }
        XCTAssertEqual(bar?.arrangedSubviews.count, 1 + 1 + catalog.categories.count + 1)

        panel.configure(catalog: catalog, recents: [], favorites: ["❤️"], theme: KeyboardTheme(settings: KeibordSettings(), dark: false), languageCode: "de")
        XCTAssertEqual(panel.collectionView(grid, numberOfItemsInSection: 0), 1, "favourites without recents")
        XCTAssertEqual(bar?.arrangedSubviews.count, 1 + 1 + catalog.categories.count + 1)
    }

    func testStickersArePastedNotTypedAndHaveTheirOwnPage() {
        let panel = EmojiPanelView(frame: CGRect(x: 0, y: 0, width: 440, height: 313))
        let recorder = PanelRecorder()
        panel.delegate = recorder
        panel.configure(catalog: nil, recents: ["😂"], favorites: ["❤️"], stickers: ["a", "b"],
                        theme: KeyboardTheme(settings: KeibordSettings(), dark: false), languageCode: "en")
        let grid = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        XCTAssertEqual(panel.numberOfSections(in: grid), 3)
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 1, section: 0))
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 1))
        XCTAssertEqual(recorder.selected, ["sticker:b", "❤️"])
        // ABC, stickers, the recents page, backspace.
        let bar = panel.subviews.compactMap { $0 as? UIStackView }.first { $0.axis == .horizontal }
        XCTAssertEqual(bar?.arrangedSubviews.count, 4)
        XCTAssertEqual(EmojiCategory(id: "stickers", emojis: []).symbolName, KeyboardIcons.stickerSymbol, "Apple's sticker icon, drawn")
        XCTAssertNotNil(EmojiPanelView.categoryIcon(KeyboardIcons.stickerSymbol))
        panel.showNote("Copied")
        XCTAssertEqual(panel.noteText, "Copied")
    }

    /// Apple's iOS 26/27 grid, measured from screenshots: 55 pt cells, four rows, 38 pt emoji.
    func testTheGridHasApplesSize() {
        let panel = EmojiPanelView(frame: CGRect(x: 0, y: 0, width: 440, height: 313))
        panel.configure(catalog: nil, recents: ["😂"], theme: KeyboardTheme(settings: KeibordSettings(), dark: false), languageCode: "de")
        panel.layoutSubviews()
        let collection = panel.subviews.compactMap { $0 as? UICollectionView }.first
        let flow = collection?.collectionViewLayout as? UICollectionViewFlowLayout
        XCTAssertEqual(flow?.itemSize, CGSize(width: 55, height: 55))
        XCTAssertEqual(flow?.sectionInset.top ?? 0, 5.5, accuracy: 0.01, "four rows centred in the 231 pt grid")
        XCTAssertEqual(flow?.sectionInset.left, 7)
        XCTAssertEqual((flow?.sectionInset.left ?? 0) + (flow?.sectionInset.right ?? 0), 22, "the gap between sections")
        let cell = EmojiCell(frame: CGRect(x: 0, y: 0, width: 55, height: 55))
        cell.layoutSubviews()
        XCTAssertEqual(cell.label.font.pointSize, 38)
    }
}
