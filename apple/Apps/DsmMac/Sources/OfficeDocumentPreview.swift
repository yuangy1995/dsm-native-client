import AppKit
import DsmCore
import DsmFileFeature
import DsmLocalization
import QuickLookUI
import SwiftUI

/// 只把已下载的本机文件交给系统预览，不向第三方文档服务发送文件或 NAS 凭据。
struct OfficeDocumentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        view.setAccessibilityLabel(L10n.string("files.office.preview"))
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard view.previewItem?.previewItemURL != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
