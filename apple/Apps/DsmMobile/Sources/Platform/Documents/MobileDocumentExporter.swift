import SwiftUI
import UIKit

struct MobileDocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: () -> Void
    var exported: (([URL]) -> Void)? = nil

    init(url: URL, completion: @escaping () -> Void) { self.init(urls: [url], completion: completion) }
    init(urls: [URL], completion: @escaping () -> Void) { self.urls = urls; self.completion = completion }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion, exported: exported)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        controller.view.accessibilityIdentifier = "mobile.documents.export-panel"
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var didComplete = false
        private let completion: () -> Void
        private let exported: (([URL]) -> Void)?

        init(completion: @escaping () -> Void, exported: (([URL]) -> Void)?) {
            self.completion = completion; self.exported = exported
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finishOnce()
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard !didComplete else { return }
            if !urls.isEmpty { exported?(urls) }
            finishOnce()
        }

        private func finishOnce() {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }
    }
}
