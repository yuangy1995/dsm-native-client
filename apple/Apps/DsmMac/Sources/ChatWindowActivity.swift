import AppKit
import SwiftUI

/// 使用所属窗口而非全局 App 活跃状态，避免另一个窗口抢焦点时推进已读。
struct ChatWindowActivity: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ActivityView, context: Context) { view.onChange = onChange; view.report() }

    final class ActivityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(notificationChanged), name: name, object: nil)
            }
            report()
        }

        @objc private func notificationChanged(_ notification: Notification) { report() }

        func report() {
            let active = window?.isKeyWindow == true && NSApp.isActive && window?.isMiniaturized == false
            guard lastValue != active else { return }
            lastValue = active
            // SwiftUI 更新期间不直接发布可观察状态。
            Task { @MainActor [weak self] in self?.onChange?(active) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
