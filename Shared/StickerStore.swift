import Foundation
import UIKit
import KeibordCore
#if os(iOS)
import ImageIO
import UniformTypeIdentifiers
#endif

/// What the app's sticker field caught: Apple's sticker as an adaptive image glyph, or a plain image.
enum StickerCapture {
    case glyph(imageContent: Data, identifier: String, label: String)
    case image(Data)
}

/// The saved stickers: the list in stickers.json (`StickerIndex`), the images in the shared `Stickers`
/// folder: `<id>.png` (pasted, at most 320 px), `<id>-small.png` (the keyboard's grid, at most 150 px)
/// and `<id>.glyph` (Apple's adaptive image glyph, when the sticker came from Apple's keyboard).
/// The app adds and deletes them; the keyboard only reads them.
final class StickerStore {
    static let shared = StickerStore()

    static let pasteSide: CGFloat = 320
    static let smallSide: CGFloat = 150

    private let store = KeibordStore.shared
    let folder: URL

    private init() {
        folder = KeibordStore.shared.directory.appendingPathComponent("Stickers", isDirectory: true)
    }

    func load() -> StickerIndex { store.read(StickerIndex.self, .stickers) ?? StickerIndex() }

    func imageURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).png") }
    func smallImageURL(_ id: String) -> URL { folder.appendingPathComponent("\(id)-small.png") }
    func glyphURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).glyph") }

    /// Deletes stickers and their images. Returns the list that was written (nil: nothing written).
    @discardableResult
    func remove(_ ids: Set<String>) -> StickerIndex? {
        let result = store.update(StickerIndex.self, .stickers, default: StickerIndex()) { $0.remove(ids: ids) }
        if result != nil { ids.forEach(removeFiles) }
        return result
    }

    private func removeFiles(_ id: String) {
        for url in [imageURL(id), smallImageURL(id), glyphURL(id)] { try? FileManager.default.removeItem(at: url) }
    }

    #if os(iOS)
    /// Saves a sticker (the app's sticker field). Run off the main thread: it decodes and scales images.
    func add(_ capture: StickerCapture) -> StickerIndex.AddResult? {
        let image: CGImage, key: String, label: String, glyph: Data?
        switch capture {
        case let .glyph(content, identifier, text):
            guard let largest = Self.largestImage(in: content) else { return nil }
            image = largest
            key = "glyph:" + identifier
            label = text
            glyph = content
        case .image(let data):
            guard let decoded = Self.largestImage(in: data) else { return nil }
            image = decoded
            key = "image:" + StickerIndex.contentHash(data)
            label = ""
            glyph = nil
        }
        let current = load()
        if current.contains(contentKey: key) { return .duplicate }
        if current.stickers.count >= StickerIndex.maxCount { return .full }

        let entry = StickerEntry(contentKey: key, label: label, hasGlyph: glyph != nil)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let png = Self.png(image, maxSide: Self.pasteSide), let small = Self.png(image, maxSide: Self.smallSide),
              Self.write(png, to: imageURL(entry.id)), Self.write(small, to: smallImageURL(entry.id)),
              glyph.map({ Self.write($0, to: glyphURL(entry.id)) }) ?? true else {
            removeFiles(entry.id)
            return nil
        }
        var result: StickerIndex.AddResult?
        let written = store.update(StickerIndex.self, .stickers, default: StickerIndex()) { result = $0.add(entry) }
        if written == nil || result != .added { removeFiles(entry.id) }
        return written == nil ? nil : result
    }

    /// The keyboard's small image of a sticker.
    func smallImage(_ id: String) -> UIImage? {
        UIImage(contentsOfFile: smallImageURL(id).path)
    }

    /// Puts a sticker on the pasteboard (the keyboard needs Full Access), the same data as dragging it.
    func copyToPasteboard(_ id: String) -> Bool {
        guard let provider = itemProvider(id) else { return false }
        UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
        return true
    }

    /// A sticker for the pasteboard or a drag. One taken from Apple's keyboard is offered only as Apple's
    /// sticker: the attributed string with its adaptive image glyph, written by UIKit in the types text
    /// views read (iOS 18+). An image next to it made Messages send a photo instead of a sticker (1.0.29),
    /// so there is none. Stickers saved as plain images are offered as a PNG.
    func itemProvider(_ id: String, forDrag: Bool = false) -> NSItemProvider? {
        if #available(iOS 18.0, *), let content = try? Data(contentsOf: glyphURL(id)) {
            let sticker = NSAttributedString(adaptiveImageGlyph: NSAdaptiveImageGlyph(imageContent: content), attributes: [:])
            guard forDrag else {
                let provider = NSItemProvider(object: sticker)
                provider.suggestedName = "Sticker"
                return provider
            }
            // A drop into Messages takes an item as an attachment or as text. With all of the string's types
            // it attached the RTFD package as a folder (1.0.30); with only UIKit's archive of the string it
            // took nothing (1.0.31). So a drag offers the archive (the sticker itself, which pasting reads)
            // and the rich text types, so the item counts as text, but no folder (RTFD package), no flat
            // RTFD file and no plain text (an empty box). The log says which type the receiver loads.
            let all = NSAttributedString.writableTypeIdentifiersForItemProvider
            let types = all.filter { identifier in
                if identifier.lowercased().contains("attributedstring") { return true }
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .text) && !type.conforms(to: .plainText) && !type.conforms(to: .compositeContent)
            }
            KeyboardLog.shared.add("sticker drag: offers \(types.joined(separator: ", ")) of \(all.joined(separator: ", "))")
            guard !types.isEmpty else { return NSItemProvider(object: sticker) }
            let provider = NSItemProvider()
            provider.suggestedName = "Sticker"
            for type in types {
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                    KeyboardLog.shared.add("sticker drag: the app loads \(type)")
                    return sticker.loadData(withTypeIdentifier: type, forItemProviderCompletionHandler: completion)
                }
            }
            return provider
        }
        guard let png = try? Data(contentsOf: imageURL(id)) else { return nil }
        let provider = NSItemProvider()
        provider.suggestedName = "Sticker"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        return provider
    }

    /// The largest image in `data` (Apple's stickers hold one image per size).
    private static func largestImage(in data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: (index: Int, pixels: Int)?
        for i in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let pixels = ((properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0) * ((properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
            if best.map({ pixels > $0.pixels }) ?? true { best = (i, pixels) }
        }
        return best.flatMap { CGImageSourceCreateImageAtIndex(source, $0.index, nil) }
    }

    /// A PNG of `image` scaled down to at most `maxSide` pixels (transparency kept).
    private static func png(_ image: CGImage, maxSide: CGFloat) -> Data? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxSide / max(width, height))
        let size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }
    #else
    func smallImage(_ id: String) -> UIImage? { nil }
    func copyToPasteboard(_ id: String) -> Bool { false }
    #endif
}
