import AppKit
import SwiftUI

/// 隔离验证真实 SwiftUI WindowGroup；不加载 NAS 配置、凭据或文件扩展。
/// 编译时直接使用产品的 MacAppearance.swift 和 AppContentLayout.swift。
@main
struct MacWindowControlsProbe: App {
    private let hidesToolbar = CommandLine.arguments.contains("--hidden-toolbar")

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            print("window-probe-timeout")
            exit(2)
        }
    }

    var body: some Scene {
        WindowGroup("Window Controls Probe") {
            VStack(spacing: 0) {
                Color.clear.frame(height: 40)
                Text("Synthetic window — no NAS connection")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(MacGlassSurface(role: .sidebar).ignoresSafeArea())
            .background(MacWorkspaceWindowChrome(fullSize: true))
            .ignoresSafeArea(.container, edges: .top)
            .macAppearanceRoot()
            .toolbar(hidesToolbar ? .hidden : .visible, for: .windowToolbar)
            .task {
                try? await Task.sleep(for: .seconds(1))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else {
                    print("window-probe-missing-window")
                    exit(2)
                }
                let visible = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy {
                    guard let button = window.standardWindowButton($0) else { return false }
                    return !button.isHiddenOrHasHiddenAncestor
                }
                let transparent = window.titlebarAppearsTransparent && window.backgroundColor.alphaComponent == 0
                let fullSize = window.styleMask.contains(.fullSizeContentView)
                print("window-probe toolbarHidden=\(hidesToolbar) buttonsVisible=\(visible) transparent=\(transparent) fullSize=\(fullSize)")
                exit((hidesToolbar ? !visible : visible) && transparent && fullSize ? 0 : 1)
            }
        }
        .defaultSize(width: 500, height: 300)
        .windowStyle(.hiddenTitleBar)
    }
}
