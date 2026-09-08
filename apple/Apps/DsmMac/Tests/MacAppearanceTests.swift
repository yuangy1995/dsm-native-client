import SwiftUI
import XCTest
@testable import DsmMacExecutable

@MainActor
final class MacAppearanceTests: XCTestCase {
    func test文件快捷键只接受文件区域焦点() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let fileArea = NSView(frame: NSRect(x: 200, y: 0, width: 400, height: 400))
        root.addSubview(fileArea)
        let coordinator = FileKeyboardShortcutHandler.Coordinator(gridHasKeyboardFocus: false, onAction: { _ in XCTFail("焦点检查不能执行文件操作") })
        coordinator.attach(to: fileArea)
        defer { coordinator.detach() }

        let table = NSTableView(frame: NSRect(x: 220, y: 20, width: 200, height: 200))
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample")))
        root.addSubview(table)
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertTrue(coordinator.ownsKeyboardFocus(in: window), "焦点：\(String(describing: window.firstResponder))，文件区域：\(fileArea.convert(fileArea.bounds, to: nil))，表格：\(table.convert(table.bounds, to: nil))")
        table.frame.origin.x = 0
        XCTAssertFalse(coordinator.ownsKeyboardFocus(in: window))

        coordinator.gridHasKeyboardFocus = true
        let editor = NSTextView(frame: NSRect(x: 220, y: 240, width: 200, height: 60))
        root.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(coordinator.ownsKeyboardFocus(in: window))
        let button = NSButton(title: "", target: nil, action: nil)
        root.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(window.firstResponder === button)
        XCTAssertFalse(coordinator.ownsKeyboardFocus(in: window))

        window.makeFirstResponder(nil)
        XCTAssertTrue(coordinator.ownsKeyboardFocus(in: window))
        coordinator.gridHasKeyboardFocus = false
        XCTAssertFalse(coordinator.ownsKeyboardFocus(in: window))
        XCTAssertFalse(coordinator.ownsKeyboardFocus(in: nil))
    }

    func test毛玻璃窗口不降低正文透明度且保持透明标题栏() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.alphaValue = 0.75
        let host = MacWorkspaceWindowChrome.HostView()
        host.fullSize = true
        window.contentView = host
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertNil(host.hitTest(.zero))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: window)
        XCTAssertEqual(window.alphaValue, 1)
        host.configure()
        XCTAssertEqual(window.alphaValue, 1)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        XCTAssertEqual(window.alphaValue, 1)
        window.contentView = NSView()
        XCTAssertEqual(window.alphaValue, 1)
    }

    func test替换根视图时旧外壳不会覆盖新外壳的标题栏() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let oldChrome = MacWorkspaceWindowChrome.HostView()
        oldChrome.fullSize = true
        root.addSubview(oldChrome)
        let newChrome = MacWorkspaceWindowChrome.HostView()
        newChrome.fullSize = true
        root.addSubview(newChrome)
        oldChrome.removeFromSuperview()
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertFalse(window.isOpaque)
        newChrome.removeFromSuperview()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
    }

    func test工作区窗口外壳离开时恢复原生标题栏() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = MacWorkspaceWindowChrome.HostView()
        host.fullSize = true
        window.contentView = host
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(window.isOpaque)
        window.titleVisibility = .visible
        XCTAssertEqual(window.titleVisibility, .hidden)
        host.fullSize = false
        host.configure()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.isOpaque)
        host.fullSize = true
        host.configure()
        window.contentView = NSView()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.isOpaque)
    }

    func test外观偏好重新创建后保留且恢复默认只移除三个键() throws {
        let suite = "MacAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic", forKey: "UnrelatedSetting")
        let store = MacAppearanceStore(defaults: defaults)
        XCTAssertEqual(store.mode, .system)
        XCTAssertNil(defaults.object(forKey: "LanStash_AppearanceMode"))
        store.mode = .ink
        store.setTransparency(0, for: .light)
        store.setTransparency(0.85, for: .dark)

        let restored = MacAppearanceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.mode, .ink)
        XCTAssertEqual(restored.fogTransparency, 0)
        XCTAssertEqual(restored.inkTransparency, 0.85)
        restored.mode = .fog
        XCTAssertEqual(MacAppearanceStore(defaults: defaults).mode, .fog)
        restored.mode = .system
        XCTAssertEqual(MacAppearanceStore(defaults: defaults).mode, .system)
        restored.reset()
        for key in ["LanStash_AppearanceMode", "LanStash_FogTransparency", "LanStash_InkTransparency"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
        XCTAssertEqual(defaults.string(forKey: "UnrelatedSetting"), "synthetic")
        let reset = MacAppearanceStore(defaults: defaults)
        XCTAssertEqual(reset.mode, .system)
        XCTAssertEqual(reset.fogTransparency, MacAppearanceStore.defaultFogTransparency)
        XCTAssertEqual(reset.inkTransparency, MacAppearanceStore.defaultInkTransparency)
    }

    func test网格与列表排序通过同一比较器识别而不是显示文案() {
        for criterion in FileSortCriterion.allCases {
            for order in [SortOrder.forward, .reverse] {
                let comparator = criterion.comparator(order: order)
                XCTAssertEqual(FileSortCriterion.resolve(comparator), criterion)
                XCTAssertEqual(comparator.order, order)
            }
        }
        XCTAssertEqual(FileSortCriterion.resolve(nil), .name)
    }

    func test文件页面五态优先级与错误恢复() {
        XCTAssertEqual(FileBrowserContentState.resolve(hasItems: false, isBusy: true, hasError: true, hasQuery: true), .loading)
        XCTAssertEqual(FileBrowserContentState.resolve(hasItems: false, isBusy: false, hasError: true, hasQuery: true), .error)
        XCTAssertEqual(FileBrowserContentState.resolve(hasItems: false, isBusy: false, hasError: false, hasQuery: true), .filteredEmpty)
        XCTAssertEqual(FileBrowserContentState.resolve(hasItems: false, isBusy: false, hasError: false, hasQuery: false), .empty)
        XCTAssertEqual(FileBrowserContentState.resolve(hasItems: true, isBusy: false, hasError: false, hasQuery: false), .content)
        XCTAssertEqual(FileBrowserContentState.resolve(hasItems: true, isBusy: true, hasError: true, hasQuery: true), .content)
    }

    func test默认跟随系统并保持独立主题参数() {
        let store = MacAppearanceStore()
        XCTAssertEqual(store.mode, .system)
        XCTAssertNil(store.mode.colorScheme)
        XCTAssertEqual(store.transparency(for: .light), MacAppearanceStore.defaultFogTransparency)
        XCTAssertEqual(store.transparency(for: .dark), MacAppearanceStore.defaultInkTransparency)
    }

    func test固定主题不与文件显示方式绑定() {
        XCTAssertEqual(MacAppearanceMode.fog.colorScheme, .light)
        XCTAssertEqual(MacAppearanceMode.ink.colorScheme, .dark)
        XCTAssertEqual(FileViewMode.allCases.count, 2)
    }

    func test浅深通透度分别调整且不因切换模式丢失() {
        let store = MacAppearanceStore()
        store.setTransparency(0.90, for: .light)
        store.setTransparency(0.35, for: .dark)
        store.mode = .ink
        store.mode = .fog
        store.mode = .system
        XCTAssertEqual(store.transparency(for: .light), 0.90)
        XCTAssertEqual(store.transparency(for: .dark), 0.35)
    }

    func test降低透明度时所有滑杆值使用实底() {
        let store = MacAppearanceStore()
        for scheme in [ColorScheme.light, .dark] {
            for value in [0.0, 0.5, 1.0] {
                store.setTransparency(value, for: scheme)
                XCTAssertEqual(store.glassOverlayOpacity(for: scheme, reducesTransparency: true), 1)
            }
        }
    }

    func test透明度滑杆改变模糊背景遮罩并保留可读下限() {
        let store = MacAppearanceStore()
        store.setTransparency(0, for: .light)
        let solid = store.glassOverlayOpacity(for: .light, reducesTransparency: false)
        store.setTransparency(1, for: .light)
        let clear = store.glassOverlayOpacity(for: .light, reducesTransparency: false)
        XCTAssertGreaterThan(solid, clear)
        XCTAssertEqual(solid, 0.72, accuracy: 0.001)
        XCTAssertEqual(clear, 0.12, accuracy: 0.001)
        XCTAssertEqual(store.glassOverlayOpacity(for: .light, reducesTransparency: true), 1)
    }

    func test恢复默认同时恢复模式和两套参数() {
        let store = MacAppearanceStore()
        store.mode = .ink
        store.setTransparency(0, for: .light)
        store.setTransparency(1, for: .dark)
        store.reset()
        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.fogTransparency, MacAppearanceStore.defaultFogTransparency)
        XCTAssertEqual(store.inkTransparency, MacAppearanceStore.defaultInkTransparency)
    }
}
