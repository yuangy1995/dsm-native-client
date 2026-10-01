import DsmCore
import SwiftUI
import XCTest
@testable import DsmMacExecutable

@MainActor
private final class ChromeReentrantWindow: NSWindow {
    var onStyleChange: (() -> Void)?
    override var styleMask: NSWindow.StyleMask {
        didSet {
            // 单次回调模拟系统修改窗口样式时同步更新 SwiftUI 视图。
            let callback = onStyleChange
            onStyleChange = nil
            callback?()
        }
    }
}

@MainActor
final class MacAppearanceTests: XCTestCase {
    func test人脸裁剪保持坐标颜色并限制JPEG尺寸() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 2560, bitsPerPixel: 32))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<640 { for x in 0..<640 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = y < 320 ? 255 : 0; bytes[offset + 1] = 0; bytes[offset + 2] = y < 320 ? 0 : 255; bytes[offset + 3] = 255
        } }
        let image = try XCTUnwrap(bitmap.cgImage)
        for (y, red) in [(0.0, true), (0.5, false)] {
            let data = try PhotoFaceEditing.jpeg(image, bounds: .init(x: 0, y: y, width: 0.5, height: 0.5))
            XCTAssertTrue(data.starts(with: [0xff, 0xd8, 0xff]))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(decoded.pixelsWide, 256); XCTAssertEqual(decoded.pixelsHigh, 256)
            let color = try XCTUnwrap(decoded.colorAt(x: 128, y: 128)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(red ? color.redComponent : color.blueComponent, 0.9)
        }
        XCTAssertThrowsError(try PhotoFaceEditing.jpeg(image, bounds: .init(x: 0.9, y: 0, width: 0.5, height: 0.5)))
    }

    func test人脸画框反向拖动边界和无效小框() throws {
        let bounds = try XCTUnwrap(PhotoFaceEditing.square(from: .init(x: 180, y: 140), to: .init(x: 80, y: 40), in: .init(width: 400, height: 200)))
        XCTAssertEqual(bounds.x, 0.2); XCTAssertEqual(bounds.y, 0.2)
        XCTAssertEqual(bounds.width * 400, bounds.height * 200)
        XCTAssertNil(PhotoFaceEditing.square(from: .init(x: 5, y: 5), to: .init(x: 10, y: 10), in: .init(width: 400, height: 200)))
        let edge = try XCTUnwrap(PhotoFaceEditing.square(from: .init(x: 200, y: 100), to: .init(x: 999, y: 999), in: .init(width: 400, height: 200)))
        XCTAssertTrue(edge.isValid); XCTAssertEqual(edge.y + edge.height, 1)
    }

    func test人脸编辑无变化不写入改框成对替换移除可撤销() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "synthetic.jpg", sizeBytes: 1, takenAt: Date(), indexedAt: Date(), folderID: 9, mediaType: "photo")
        let bounds = SynologyPhotoFaceBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let original = SynologyPhotoFaceRegion(id: 71, personID: 0, name: "", bounds: bounds)
        var draft = PhotoFaceDraft(id: "original", original: original, bounds: bounds, personID: 0, name: "")
        XCTAssertTrue(try PhotoFaceEditing.changes(photo: photo, image: image, drafts: [draft], people: []).isEmpty)
        draft.removed = true
        XCTAssertEqual(try PhotoFaceEditing.changes(photo: photo, image: image, drafts: [draft], people: []), [.remove(original)])
        draft.removed = false; draft.name = "Target"; draft.bounds.x = 0.2
        let changes = try PhotoFaceEditing.changes(photo: photo, image: image, drafts: [draft], people: [])
        XCTAssertEqual(changes.count, 2)
        guard case .add(let face) = changes[1] else { return XCTFail("移动框必须生成新脸") }
        XCTAssertEqual(face.temporaryID, "7-0"); XCTAssertEqual(face.name, "Target"); XCTAssertTrue(face.jpeg.starts(with: [0xff, 0xd8, 0xff]))
        draft.bounds = original.bounds
        XCTAssertEqual(try PhotoFaceEditing.changes(photo: photo, image: image, drafts: [draft], people: []), [.reassign(original, person: nil, name: "Target")])
    }

    func test图片预览接收捏合与滚轮但不截获其他窗口或区域() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = host
        var magnifications: [CGFloat] = []
        var scrolls: [CGFloat] = []
        let reader = ImageZoomGestureReader.Coordinator(onScroll: { delta, _ in scrolls.append(delta) }, onMagnify: { magnifications.append($0) })
        reader.attach(to: host)
        defer { reader.detach(); window.contentView = nil; window.close(); other.close() }
        for delta in [CGFloat(0.3), -0.1, -0.2] {
            XCTAssertNil(reader.handle(ImageGestureEvent(window: window, type: .magnify, delta: delta)))
        }
        XCTAssertEqual(magnifications, [0.3, -0.1, -0.2])
        XCTAssertTrue(scrolls.isEmpty)
        XCTAssertNil(reader.handle(ImageGestureEvent(window: window, type: .scrollWheel, delta: 2)))
        XCTAssertEqual(scrolls, [2])
        let outside = ImageGestureEvent(window: window, type: .magnify, delta: 1, point: NSPoint(x: 250, y: 50))
        XCTAssertTrue(reader.handle(outside) === outside)
        let anotherWindow = ImageGestureEvent(window: other, type: .magnify, delta: 1)
        XCTAssertTrue(reader.handle(anotherWindow) === anotherWindow)
        let unrelated = ImageGestureEvent(window: window, type: .leftMouseDown, delta: 1)
        XCTAssertTrue(reader.handle(unrelated) === unrelated)
        XCTAssertEqual(magnifications.count, 3)
    }

    func test照片实际可见面积跨越八成时更新且滚动不重复报告() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        clip.postsBoundsChangedNotifications = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let reader = PhotoPreviewVisibilityReader.VisibilityView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var reports: [Bool] = []
        reader.onChange = { reports.append($0) }
        document.addSubview(reader); clip.documentView = document; window.contentView = clip
        defer { reader.detach(); window.contentView = nil; window.close() }
        await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true])
        clip.scroll(to: NSPoint(x: 20, y: 0)); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true], "恰好80%仍在优先队列，不重复报告")
        clip.scroll(to: NSPoint(x: 21, y: 0)); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true, false])
        clip.scroll(to: NSPoint(x: 15, y: 15)); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true, false], "按面积而不是单边比例判断")
        clip.scroll(to: .zero); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true, false, true])
        reader.setFrameOrigin(NSPoint(x: 150, y: 0)); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true, false, true, false], "布局推到视口外时移除优先级")
        XCTAssertNil(reader.hitTest(.zero), "不能截获缩略图点击")
    }

    func test照片可见登记处理隐藏空尺寸和移除视图() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let reader = PhotoPreviewVisibilityReader.VisibilityView(frame: .zero)
        var reports: [Bool] = []
        reader.onChange = { reports.append($0) }
        host.addSubview(reader); window.contentView = host
        defer { reader.detach(); window.contentView = nil; window.close() }
        await drainVisibilityUpdates(); XCTAssertTrue(reports.isEmpty)
        reader.setFrameSize(NSSize(width: 100, height: 100)); await drainVisibilityUpdates()
        reader.isHidden = true; await drainVisibilityUpdates()
        reader.isHidden = false; await drainVisibilityUpdates()
        reader.removeFromSuperview(); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true, false, true, false])
        host.addSubview(reader); await drainVisibilityUpdates()
        reader.detach(); reader.scheduleReport(); await drainVisibilityUpdates()
        XCTAssertEqual(reports, [true, false, true, false, true, false], "拆卸取消登记，排队回调不能重新登记")
    }

    private func drainVisibilityUpdates() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func test冷启动先恢复外观再创建原生选择框且可切回系统() throws {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        let suite = "MacAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for (mode, expected) in [(MacAppearanceMode.ink, NSAppearance.Name.darkAqua), (.fog, .aqua)] {
            let saved = MacAppearanceStore(defaults: defaults)
            saved.mode = mode
            application.appearance = NSAppearance(named: mode == .ink ? .aqua : .darkAqua)
            MacAppearanceStore(defaults: defaults).mode.applyNativeAppearance()
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            XCTAssertEqual(application.appearance?.name, expected)
            XCTAssertEqual(picker.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
        }
        MacAppearanceMode.system.applyNativeAppearance()
        XCTAssertNil(application.appearance)
    }

    func test卡片底色不使用不透明白底且在两种主题下比选中态更轻() throws {
        for scheme in [ColorScheme.light, .dark] {
            for highContrast in [false, true] {
                let palette = MacAppearancePalette(scheme: scheme, increasedContrast: highContrast)
                let color = try XCTUnwrap(NSColor(palette.card).usingColorSpace(.deviceRGB))
                XCTAssertLessThan(color.alphaComponent, palette.nativeSelection.alphaComponent)
                XCTAssertLessThan(color.redComponent, 0.5)
                XCTAssertGreaterThan(color.alphaComponent, 0)
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                let resolvedPalette = MacAppearancePalette(scheme: scheme, increasedContrast: environment.colorSchemeContrast == .increased)
                XCTAssertEqual(NSColor(MacCardFill().resolve(in: environment)), NSColor(resolvedPalette.card))
            }
        }
    }

    func test选中底色低饱和且浅深主题和增强对比度均可区分() throws {
        for scheme in [ColorScheme.light, .dark] {
            for highContrast in [false, true] {
                let color = try XCTUnwrap(MacAppearancePalette(scheme: scheme, increasedContrast: highContrast).nativeSelection.usingColorSpace(.deviceRGB))
                XCTAssertLessThan(color.saturationComponent, 0.5)
                XCTAssertGreaterThanOrEqual(color.alphaComponent, 0.15)
                XCTAssertLessThanOrEqual(color.alphaComponent, 0.31)
            }
        }
    }

    func test三档网格同步缩放图标单元格和文字且中档小于旧默认() {
        XCTAssertEqual(FileGridSize.allCases, [.small, .medium, .large])
        for (smaller, larger) in [(FileGridSize.small, FileGridSize.medium), (.medium, .large)] {
            XCTAssertLessThan(smaller.iconWidth, larger.iconWidth)
            XCTAssertLessThan(smaller.iconHeight, larger.iconHeight)
            XCTAssertLessThan(smaller.minimumWidth, larger.minimumWidth)
            XCTAssertLessThan(smaller.maximumWidth, larger.maximumWidth)
            XCTAssertLessThan(smaller.itemHeight, larger.itemHeight)
            XCTAssertLessThan(smaller.fontSize, larger.fontSize)
        }
        XCTAssertEqual(FileGridSize.large.itemHeight, 188)
        XCTAssertLessThan(FileGridSize.medium.itemHeight, 188)
    }

    func test本机存储总量包含挂载缓存但可清理量不包含离线文件() {
        let snapshot = AppStorageSnapshot(previewCache: 10, photoCache: 20, systemCache: 30, protectedData: 40,
            mountedCache: .init(temporaryBytes: 50, keptOfflineBytes: 60))
        XCTAssertEqual(snapshot.total, 210)
        XCTAssertEqual(snapshot.reclaimable, 110)
        XCTAssertEqual(snapshot.safeTrash, 40)
        XCTAssertTrue(CacheCleanupOptions.all.contains(.mountedCache))
        XCTAssertFalse(CacheCleanupOptions.safeTrash.contains(.mountedCache))
    }

    func test滚动区域去掉实色轨道且保留可见性和滚动内容() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = true
        scroll.contentView.drawsBackground = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
        scroll.documentView = document

        XCTAssertTrue(MacScrollBackground.HostView.configureScrollViews(in: scroll))
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertFalse(scroll.drawsBackground)
        XCTAssertFalse(scroll.contentView.drawsBackground)
        XCTAssertFalse(scroll.autohidesScrollers)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertTrue(scroll.documentView === document)
        XCTAssertNil(MacScrollBackground.HostView().hitTest(.zero))
    }

    func test浅深主题透明度都降低主题遮罩而不是正文透明度() {
        let store = MacAppearanceStore()
        for scheme in [ColorScheme.light, .dark] {
            var previous = 1.0
            for value in [0.0, 0.25, 0.5, 0.75, 1.0] {
                store.setTransparency(value, for: scheme)
                let opacity = store.glassOverlayOpacity(for: scheme, reducesTransparency: false)
                XCTAssertLessThan(opacity, previous)
                XCTAssertGreaterThanOrEqual(opacity, 0.15)
                previous = opacity
            }
        }
        XCTAssertEqual(MacGlassRole.sidebar.material, .sidebar)
        XCTAssertEqual(MacGlassRole.content.blendingMode, .behindWindow)
    }

    func test视频窗口隐藏系统按钮但保留全屏和缩放并可恢复() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = MacWorkspaceWindowChrome.HostView()
        host.fullSize = true
        host.hidesSystemButtons = true
        window.contentView = host
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(window.standardWindowButton(kind)?.isHidden == true)
        }
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.isMovableByWindowBackground)
        host.hidesSystemButtons = false
        host.configure()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertFalse(window.standardWindowButton(kind)?.isHidden ?? true)
        }
    }
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

    func test窗口销毁时保留外壳也不会重新观察旧窗口() {
        _ = NSApplication.shared
        let host = MacWorkspaceWindowChrome.HostView()
        host.fullSize = true
        weak var releasedWindow: NSWindow?
        autoreleasepool {
            let window = ChromeReentrantWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            releasedWindow = window
            window.contentView = host
            window.onStyleChange = { [weak host] in host?.configure() }
            // 不提前移除内容，覆盖 NSWindow 销毁过程中主动拆除视图的路径。
        }
        XCTAssertNil(releasedWindow)
        XCTAssertNil(host.window)
    }

    func test窗口外壳离开时忽略同步布局重入并可接入新窗口() {
        _ = NSApplication.shared
        let window = ChromeReentrantWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let nextWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        nextWindow.isReleasedWhenClosed = false
        defer {
            window.onStyleChange = nil
            window.contentView = nil
            nextWindow.contentView = nil
            window.close()
            nextWindow.close()
        }
        let host = MacWorkspaceWindowChrome.HostView()
        host.fullSize = true
        window.contentView = host
        var reentryCount = 0
        window.onStyleChange = { [weak host] in
            reentryCount += 1
            host?.configure()
        }
        window.contentView = NSView()
        XCTAssertGreaterThan(reentryCount, 0)
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .visible)
        window.titleVisibility = .hidden
        window.titleVisibility = .visible
        XCTAssertEqual(window.titleVisibility, .visible, "离开时不能重新注册旧窗口的标题监听")

        nextWindow.contentView = host
        XCTAssertTrue(nextWindow.styleMask.contains(.fullSizeContentView))
        nextWindow.titleVisibility = .visible
        XCTAssertEqual(nextWindow.titleVisibility, .hidden, "接入新窗口后应恢复正常配置与监听")
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
        XCTAssertEqual(solid, 0.96, accuracy: 0.001)
        XCTAssertEqual(clear, 0.16, accuracy: 0.001)
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

/// 合成公开NSEvent属性验证事件路由，不伪造系统触控设备或连接真实NAS。
private final class ImageGestureEvent: NSEvent {
    private let targetWindow: NSWindow
    private let eventType: NSEvent.EventType
    private let eventDelta: CGFloat
    private let point: NSPoint
    init(window: NSWindow, type: NSEvent.EventType, delta: CGFloat, point: NSPoint = NSPoint(x: 100, y: 50)) {
        targetWindow = window; eventType = type; eventDelta = delta; self.point = point
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var window: NSWindow? { targetWindow }
    override var type: NSEvent.EventType { eventType }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { eventDelta }
    override var scrollingDeltaY: CGFloat { eventDelta }
    override var hasPreciseScrollingDeltas: Bool { true }
}
