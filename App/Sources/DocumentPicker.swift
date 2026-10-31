import UIKit
import UniformTypeIdentifiers

/// Lets the user pick one file with UIKit's document picker. SwiftUI's `.fileImporter` can stay open
/// on a real iPhone: tapping a file does nothing and its completion is never called.
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()

    private var completion: ((URL?) -> Void)?

    /// Every regular file can be picked (a backup renamed or saved without ".json" too); the content
    /// decides whether it is a backup. The file is copied into the app, so no access rights are needed.
    func pickFile(completion: @escaping (URL?) -> Void) {
        guard let presenter = Self.topViewController() else { completion(nil); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.completion = completion
        presenter.present(picker, animated: true)
    }

    /// The Save dialog for `url` (the first automatic backup): the file is moved where the user saves it,
    /// and the completion gets its new, security-scoped place (keep a bookmark of it to write there later).
    /// A folder picker (`forOpeningContentTypes: [.folder]`) did nothing when Open was tapped (1.0.27).
    func export(_ url: URL, completion: @escaping (URL?) -> Void) {
        guard let presenter = Self.topViewController() else { completion(nil); return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
        picker.delegate = self
        self.completion = completion
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(controller, url: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(controller, url: nil)
    }

    /// Continues once the picker is gone: an alert or sheet presented while it is still on screen
    /// would not appear.
    private func finish(_ controller: UIDocumentPickerViewController, url: URL?) {
        guard let completion = completion else { return }
        self.completion = nil
        if let coordinator = controller.transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { _ in completion(url) }) {
            return
        }
        if controller.presentingViewController != nil && !controller.isBeingDismissed {
            controller.dismiss(animated: true) { completion(url) }
        } else {
            DispatchQueue.main.async { completion(url) }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
