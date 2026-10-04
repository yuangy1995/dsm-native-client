import SwiftUI
import UIKit

struct MobileDocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: () -> Void

    init(url: URL, completion: @escaping () -> Void) { self.init(urls: [url], completion: completion) }
    init(urls: [URL], completion: @escaping () -> Void) { self.urls = urls; self.completion = completion }

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
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

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finishOnce()
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            finishOnce()
        }

        private func finishOnce() {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }
    }
}
