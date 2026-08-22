// Quick Look 在 Xcode 16.4 SDK 中尚未标注全局参与者，沿用兼容导入以保持协调器的主线程隔离。
@preconcurrency import QuickLook
import SwiftUI

/// SwiftUI 与系统 Quick Look 的轻量桥接；临时文件所有权始终属于预览 Model。
struct MobileQuickLookPreview: UIViewControllerRepresentable {
    let localURL: URL
    let title: String
    var onDismiss: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(localURL: localURL, title: title, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.update(localURL: localURL, title: title, onDismiss: onDismiss) {
            controller.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private var item: PreviewItem
        private var onDismiss: () -> Void

        init(localURL: URL, title: String, onDismiss: @escaping () -> Void) {
            item = PreviewItem(localURL: localURL, title: title)
            self.onDismiss = onDismiss
        }

        func update(
            localURL: URL,
            title: String,
            onDismiss: @escaping () -> Void
        ) -> Bool {
            let requiresReload = Self.requiresReload(
                currentURL: item.previewItemURL,
                currentTitle: item.previewItemTitle,
                nextURL: localURL,
                nextTitle: title
            )
            if requiresReload {
                item = PreviewItem(localURL: localURL, title: title)
            }
            self.onDismiss = onDismiss
            return requiresReload
        }

        nonisolated static func requiresReload(
            currentURL: URL?,
            currentTitle: String?,
            nextURL: URL,
            nextTitle: String
        ) -> Bool {
            currentURL != nextURL || currentTitle != nextTitle
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            item
        }

        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
            // 旧版 Quick Look Delegate 未标注主线程隔离；回调后再安全切回 SwiftUI 所在主线程。
            Task { @MainActor [weak self] in
                self?.onDismiss()
            }
        }
    }

    private final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(localURL: URL, title: String) {
            previewItemURL = localURL
            previewItemTitle = title
        }
    }
}
