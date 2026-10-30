import SwiftUI
import UIKit
import KeibordCore

// MARK: - Favourite emoji

/// Up to eight emoji pinned first on the recents page of Keibord's emoji panel, in an order of their own.
struct FavoriteEmojiView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    private var favorites: [String] { model.settings.favoriteEmoji }
    private var isFull: Bool { favorites.count >= KeibordSettings.maxFavoriteEmoji }

    var body: some View {
        List {
            Section {
                ForEach(favorites, id: \.self) { emoji in
                    Text(emoji).font(.system(size: 34))
                }
                .onMove { model.settings.favoriteEmoji.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { model.settings.favoriteEmoji.remove(atOffsets: $0) }
            } header: {
                Text("\(favorites.count) of \(KeibordSettings.maxFavoriteEmoji)")
            } footer: {
                Text("First on the recents page of Keibord's emoji panel, in this order: the first column from top to bottom, then the second. Drag to sort, swipe or tap ⊖ to remove.")
            }
            Section {
                TextField(isFull ? "Remove one to add another" : "Type or tap emoji to add them", text: $text)
                    .disabled(isFull)
                    .onChange(of: text) { _, typed in add(typed) }
            } footer: {
                Text("Any keyboard works here, Apple's emoji keyboard too.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Favourite Emoji")
    }

    private func add(_ typed: String) {
        guard !typed.isEmpty else { return }
        let new = EmojiText.emoji(in: typed).filter { !favorites.contains($0) }
        if !new.isEmpty { model.settings.favoriteEmoji += new }
        text = ""
    }
}

// MARK: - Stickers

/// Collects stickers from Apple's emoji keyboard: each sticker tapped into the field is saved at once.
struct StickersView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDeleteAll = false
    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Keyboards cannot read your iPhone's stickers, so Keibord keeps copies of its own. Tap the field, switch to Apple's emoji keyboard with 🌐, open your stickers and tap them one by one: each one is saved at once, nothing else to tap.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                StickerInputField(onSticker: { model.addSticker($0) },
                                  onOtherText: { model.stickerStatus = "Only stickers are saved here. Emoji go under Favourite Emoji." })
                    .frame(height: 88)
                    .overlay(alignment: .center) {
                        Text("Tap stickers here")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                Text(model.stickerStatus ?? " ")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("In Keibord, the stickers are to the left of the recent emoji. Tapping one copies it; then tap the text field and choose Paste. Apps that take Apple's stickers show it like one, other apps as an image. Stickers with effects or animation are saved as still images. Needs Allow Full Access.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !model.stickers.isEmpty {
                    Text("\(model.stickers.count) sticker\(model.stickers.count == 1 ? "" : "s") · hold one to delete it")
                        .font(.headline)
                        .padding(.top, 6)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.stickers) { sticker in
                        StickerThumbnail(id: sticker.id)
                            .frame(height: 76)
                            .accessibilityLabel(sticker.label.isEmpty ? "Sticker" : sticker.label)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { model.removeStickers([sticker.id]) }
                            }
                    }
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Stickers")
        .toolbar {
            if !model.stickers.isEmpty {
                Button("Delete All", role: .destructive) { confirmDeleteAll = true }
            }
        }
        .confirmationDialog("Delete all \(model.stickers.count) stickers from Keibord?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.removeStickers(Set(model.stickers.map(\.id))) }
        }
        .onAppear {
            model.stickerStatus = nil
            model.reloadStickers()
        }
    }
}

/// A saved sticker's small image.
private struct StickerThumbnail: View {
    let id: String

    var body: some View {
        if let image = UIImage(contentsOfFile: StickerStore.shared.smallImageURL(id).path) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }
}

/// A rich text field that takes stickers from Apple's emoji keyboard. Each sticker (an adaptive image
/// glyph on iOS 18 and later, an image attachment before) is handed over and the field emptied again,
/// ready for the next one.
struct StickerInputField: UIViewRepresentable {
    var onSticker: (StickerCapture) -> Void
    var onOtherText: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.allowsEditingTextAttributes = true
        if #available(iOS 18.0, *) { view.supportsAdaptiveImageGlyph = true }
        view.font = .preferredFont(forTextStyle: .title1)
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.autocorrectionType = .no
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StickerInputField

        init(parent: StickerInputField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard let text = textView.attributedText, text.length > 0 else { return }
            var captures: [StickerCapture] = []
            var otherText = false
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                if let capture = Self.capture(attributes) {
                    captures.append(capture)
                } else if !text.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    otherText = true
                }
            }
            textView.attributedText = NSAttributedString() // ready for the next sticker
            captures.forEach(parent.onSticker)
            if captures.isEmpty, otherText { parent.onOtherText() }
        }

        private static func capture(_ attributes: [NSAttributedString.Key: Any]) -> StickerCapture? {
            if #available(iOS 18.0, *), let glyph = attributes[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
                return .glyph(imageContent: glyph.imageContent, identifier: glyph.contentIdentifier, label: glyph.contentDescription)
            }
            guard let attachment = attributes[.attachment] as? NSTextAttachment else { return nil }
            if let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents ?? attachment.image?.pngData() {
                return .image(data)
            }
            return nil
        }
    }
}
