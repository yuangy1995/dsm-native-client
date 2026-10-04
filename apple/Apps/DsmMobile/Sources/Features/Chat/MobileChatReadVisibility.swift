import SwiftUI
import UIKit

/// List 会预加载屏幕外的行。用最新消息底部在当前窗口和滚动容器中的实际位置判断阅读。
struct MobileChatReadVisibility: UIViewRepresentable {
    let identity: String
    let onChange: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {
        if view.identity != identity || view.sceneActive != (scenePhase == .active) { view.lastValue = nil }
        view.identity = identity
        view.sceneActive = scenePhase == .active
        view.onChange = onChange
    }
    static func dismantleUIView(_ view: ProbeView, coordinator: ()) { view.stop() }

    final class ProbeView: UIView {
        var identity = ""
        var sceneActive = false
        var onChange: ((Bool) -> Void)?
        var lastValue: Bool?
        private var displayLink: CADisplayLink?

        init() { super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { super.init(coder: coder); isUserInteractionEnabled = false }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            if window != nil {
                let link = CADisplayLink(target: self, selector: #selector(sample))
                link.preferredFramesPerSecond = 5
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        func stop() {
            displayLink?.invalidate(); displayLink = nil
            if lastValue == true {
                lastValue = false
                Task { @MainActor [onChange] in onChange?(false) }
            }
        }

        @objc private func sample() {
            let value = isActuallyVisible
            guard value != lastValue else { return }
            lastValue = value
            onChange?(value)
        }

        private var isActuallyVisible: Bool {
            guard sceneActive, let window, window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
                  bounds.width > 0, bounds.height > 0 else { return false }
            let rect = convert(bounds, to: window)
            let point = CGPoint(x: rect.midX, y: rect.midY)
            guard window.safeAreaLayoutGuide.layoutFrame.contains(point) else { return false }
            var ancestor: UIView? = self
            var cell: UIView?
            while let view = ancestor {
                if view is UICollectionViewCell || view is UITableViewCell { cell = view }
                guard !view.isHidden, view.alpha > 0.01 else { return false }
                if view.clipsToBounds, !view.convert(view.bounds, to: window).contains(point) { return false }
                ancestor = view.superview
            }
            if let cell {
                guard let visibleSurface = window.hitTest(point, with: nil), visibleSurface.isDescendant(of: cell) else { return false }
            }
            // 表单、预览和菜单遮住聊天时，原页面仍可能留在窗口层级中。
            var responder: UIResponder? = self
            while let value = responder {
                if let controller = value as? UIViewController,
                   let presented = controller.presentedViewController, !presented.isBeingDismissed { return false }
                responder = value.next
            }
            return true
        }
    }
}
