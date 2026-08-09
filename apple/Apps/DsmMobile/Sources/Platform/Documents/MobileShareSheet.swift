import SwiftUI
import UIKit

struct MobileShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak coordinator = context.coordinator] _, _, _, _ in
            Task { @MainActor in
                coordinator?.finishOnce()
            }
        }
        // SwiftUI 的 sheet 提供合法呈现锚点；下行兼容直接呈现时也保证 iPad 不崩溃。
        controller.popoverPresentationController?.sourceView = controller.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: controller.view.bounds.midX,
            y: controller.view.bounds.midY,
            width: 1,
            height: 1
        )
        controller.popoverPresentationController?.permittedArrowDirections = []
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        private var didComplete = false
        private let completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func finishOnce() {
            guard !didComplete else { return }
            didComplete = true
            completion()
        }
    }
}
