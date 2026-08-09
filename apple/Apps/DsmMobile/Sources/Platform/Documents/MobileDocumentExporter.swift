import SwiftUI
import UIKit

struct MobileDocumentExporter: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
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
