import XCTest
import UIKit
import KeibordCore
@testable import KeyboardCheck

private final class PanelRecorder: EmojiPanelDelegate {
    var selected: [String] = []
    func emojiPanel(_ panel: EmojiPanelView, didSelect emoji: String) { selected.append(emoji) }
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
}
