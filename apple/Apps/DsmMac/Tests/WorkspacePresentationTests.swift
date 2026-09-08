import AppKit
import AVKit
import DsmCore
import DsmLocalization
import DsmNetwork
import OSLog
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import DsmMacExecutable

/// 使用合成 profile 绘制真实文件视图；不连接 NAS，也不触发生产缓存清理、通知或系统挂载。
/// 运行方式见 tools/codex/run_macos_ui_checks.sh。普通单测不自动执行昂贵的绘制检查。
@MainActor
final class WorkspacePresentationTests: XCTestCase {
    private var artifacts: URL!
    private static var preparedApplication = false

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LANSTASH_UI_TEST_ISOLATED"] == "1",
              let directory = environment["LANSTASH_UI_ARTIFACTS"] else {
            throw XCTSkip("合成 UI 检查需要指定输出目录，请使用 tools/codex/run_macos_ui_checks.sh。")
        }
        artifacts = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        _ = NSApplication.shared
        if !Self.preparedApplication {
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            Self.preparedApplication = true
        }
    }

    func test虚拟机资源可用时无需先选择旧机器即可打开新建() async throws {
        let repository = ServiceManagementRepositoryStub(virtualMachineStorages: [VirtualizationResource(id: "synthetic-storage", name: "Synthetic storage")])
        let model = ServiceManagementModel(repository: repository)
        await model.activate(.virtualMachines)
        XCTAssertTrue(model.virtualMachineSelection.isEmpty)
        let host = NSHostingView(rootView: ServiceManagementView(module: .virtualMachines, model: model)
            .environment(MacAppearanceStore())
            .preferredColorScheme(.light))
        let window = attach(host, size: NSSize(width: 720, height: 640))
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try click(window, at: NSPoint(x: 55, y: 486))
        try await settle(host)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertTrue(model.virtualMachineSelection.isEmpty)
    }

    func test统一页签点击传递稳定选择值() async throws {
        let selection = PageTabSelectionProbe()
        let host = NSHostingView(rootView: MacPageTabs(options: [0, 1, 2], selection: Binding(get: { selection.value }, set: { selection.value = $0 }), title: { String($0) })
            .environment(MacAppearanceStore())
            .background(Color.white)
            .preferredColorScheme(.light))
        let window = attach(host, size: NSSize(width: 280, height: 60))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try snapshot(host, name: "page-tabs-hit-regions")
        try click(window, at: NSPoint(x: 47, y: 30))
        try await settle(host)
        XCTAssertEqual(selection.value, 1)
        try click(window, at: NSPoint(x: 80, y: 30))
        try await settle(host)
        XCTAssertEqual(selection.value, 2)
        try click(window, at: NSPoint(x: 13, y: 30))
        try await settle(host)
        XCTAssertEqual(selection.value, 0)
    }

    func test预览空格不抢占控件焦点但仍可关闭预览() async throws {
        var closeCount = 0
        let host = NSHostingView(rootView: Color.clear.background(PreviewSpaceShortcutHandler { closeCount += 1 }))
        let window = attach(host, size: NSSize(width: 640, height: 480))
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let button = NSButton(title: "Synthetic control", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 120, height: 32)
        host.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertTrue(window.firstResponder === button)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        NSApp.sendEvent(space)
        XCTAssertEqual(closeCount, 0)
        window.makeFirstResponder(nil)
        NSApp.sendEvent(space)
        XCTAssertEqual(closeCount, 1)
    }

    func test真实附着确认前后窗口保持清晰且背景使用原生模糊() async throws {
        let appearance = MacAppearanceStore()
        let host = NSHostingView(rootView: MacGlassSurface(role: .sidebar)
            .environment(appearance)
            .background(MacWorkspaceWindowChrome(fullSize: true)))
        let window = attach(host, size: NSSize(width: 640, height: 480))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        func findEffect(_ view: NSView) -> NSVisualEffectView? {
            if let effect = view as? NSVisualEffectView { return effect }
            return view.subviews.lazy.compactMap(findEffect).first
        }
        let effect = try XCTUnwrap(findEffect(host))
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.state, .active)
        for value in [0.0, 0.5, 1.0] {
            appearance.setTransparency(value, for: .light)
            try await settle(host)
            XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
            XCTAssertEqual(effect.alphaValue, 1, accuracy: 0.001)
        }
        let alert = NSAlert()
        alert.messageText = "Synthetic confirmation"
        alert.informativeText = "No operation will be performed."
        alert.addButton(withTitle: "Cancel")
        var completed = false
        alert.beginSheetModal(for: window) { _ in completed = true }
        try await settle(host)
        XCTAssertTrue(window.attachedSheet === alert.window)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(alert.window.alphaValue, 1, accuracy: 0.001)
        window.endSheet(alert.window, returnCode: .cancel)
        for _ in 0..<10 where !completed {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
        alert.window.orderOut(nil)
    }

    func test音频播放器双语主题加载失败显示恢复入口() async throws {
        XCTAssertNotNil(NSImage(systemSymbolName: "music.note", accessibilityDescription: nil))
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        // URLSession 不支持此测试专用协议，不产生网络请求；覆盖真实失败处理，不代表成功播放。
        let source = MediaStreamSource(
            request: URLRequest(url: try XCTUnwrap(URL(string: "synthetic-audio-test://unavailable/sample.mp3"))),
            fileExtension: "mp3", expectedContentLength: nil, expectedHost: "unavailable", pinnedCertificateSHA256: nil)
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: AudioPlayerView(source: source)
                    .environment(MacAppearanceStore())
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 600, height: 480))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                try await Task.sleep(for: .milliseconds(300))
                try await settle(host)
                try snapshot(host, name: "audio-unavailable-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                XCTAssertEqual(host.bounds.width, 600, accuracy: 1)
            }
        }
    }

    func test控制台窗口双语主题保留非持久网页且不连接设备() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        // 无主机地址，命中现有的无效会话分支；只检查真实窗口外壳，不伪造控制台内容。
        let session = VirtualMachineConsoleSession(url: try XCTUnwrap(URL(string: "about:blank")), sessionCookieValue: "")
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: VirtualMachineConsoleWindowView(
                    machineName: "Synthetic virtual machine with a long display name", session: session,
                    close: { XCTFail("绘制不能关闭控制台") },
                    toggleFullScreen: { XCTFail("绘制不能切换全屏") })
                    .environment(MacAppearanceStore())
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 720, height: 480))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                try snapshot(host, name: "console-shell-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                func findWebView(_ view: NSView) -> WKWebView? {
                    if let webView = view as? WKWebView { return webView }
                    return view.subviews.lazy.compactMap(findWebView).first
                }
                let webView = try XCTUnwrap(findWebView(host))
                XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
                XCTAssertNil(webView.url)
                XCTAssertFalse(webView.isLoading)
                XCTAssertGreaterThan(webView.bounds.height, 300)
                XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
            }
        }
    }

    func test更新窗口双语主题各阶段不自动下载或重启() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let driver = AppUpdateUserDriver(presentsWindows: false)
                let host = NSHostingView(rootView: AppUpdateView(driver: driver)
                    .environment(MacAppearanceStore())
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 500, height: 400))
                defer { window.contentView = nil; window.close() }
                let suffix = "\(language.rawValue)-\(scheme == .dark ? "dark" : "light")"
                let note = language == .english ? "Improved file browsing and clearer update status." : "改善文件浏览体验，让更新状态更加清晰。"
                driver.showAvailable(version: "0.3.0", notes: Array(repeating: note, count: 24).joined(separator: "\n\n")) { _ in
                    XCTFail("滚动更新说明不能开始安装")
                }
                try await settle(host)
                try snapshot(host, name: "update-notes-\(suffix)")
                func findNotesScroll(_ view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    return view.subviews.lazy.compactMap(findNotesScroll).first
                }
                let scroll = try XCTUnwrap(findNotesScroll(host))
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertTrue(scroll.hasVerticalScroller)
                XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                XCTAssertGreaterThan(scroll.contentView.bounds.height, 40)
                let initialOrigin = scroll.contentView.bounds.origin.y
                scroll.contentView.scroll(to: NSPoint(x: 0, y: initialOrigin + 120))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertNotEqual(scroll.contentView.bounds.origin.y, initialOrigin)
                XCTAssertEqual(driver.primaryKey, "updates.download")
                XCTAssertFalse(driver.isWorking)
                driver.showAvailable(version: "0.3.0", notes: nil) { _ in XCTFail("空说明不能自动安装") }
                try await settle(host)
                try snapshot(host, name: "update-notes-empty-\(suffix)")
                driver.showUserInitiatedUpdateCheck { XCTFail("绘制不能取消更新") }
                try await settle(host)
                try snapshot(host, name: "update-checking-\(suffix)")
                XCTAssertTrue(driver.isWorking)
                driver.showDownloadInitiated { XCTFail("绘制不能取消下载") }
                driver.showDownloadDidReceiveExpectedContentLength(100)
                driver.showDownloadDidReceiveData(ofLength: 40)
                try await settle(host)
                try snapshot(host, name: "update-downloading-\(suffix)")
                XCTAssertEqual(driver.progress, 0.4)
                driver.showDownloadDidStartExtractingUpdate()
                driver.showExtractionReceivedProgress(0.7)
                try await settle(host)
                try snapshot(host, name: "update-preparing-\(suffix)")
                XCTAssertFalse(driver.canDismiss)
                driver.showUpdaterError(NSError(domain: "Synthetic", code: 1)) {
                    XCTFail("绘制不能自动关闭错误")
                }
                try await settle(host)
                try snapshot(host, name: "update-error-\(suffix)")
                XCTAssertEqual(driver.titleKey, "updates.failed")
                driver.showReady { _ in XCTFail("绘制不能安装或跳过更新") }
                try await settle(host)
                try snapshot(host, name: "update-ready-\(suffix)")
                XCTAssertFalse(driver.isRestartRequested)
                XCTAssertEqual(driver.primaryKey, "updates.install")
                XCTAssertEqual(driver.secondaryKey, "updates.cancel")
                driver.showInstallingUpdate(withApplicationTerminated: true) {
                    XCTFail("绘制不能重试重启")
                }
                try await settle(host)
                try snapshot(host, name: "update-installing-\(suffix)")
                XCTAssertFalse(driver.canDismiss)
                driver.showUpdateNotFoundWithError(NSError(domain: "Synthetic", code: 0)) {
                    XCTFail("绘制不能确认检查结果")
                }
                try await settle(host)
                try snapshot(host, name: "update-current-\(suffix)")
                XCTAssertEqual(driver.stage, .upToDate)
                XCTAssertEqual(host.bounds.width, 500, accuracy: 1)
            }
        }
    }

    func test更新窗口无系统外框且自带关闭与Escape有效() async throws {
        let previousMode = MacAppearanceStore.shared.mode
        defer { MacAppearanceStore.shared.mode = previousMode }
        for mode in [MacAppearanceMode.fog, .ink] {
            MacAppearanceStore.shared.mode = mode
            for usesEscape in [false, true] {
                let before = Set(NSApp.windows.map(\.windowNumber))
                let driver = AppUpdateUserDriver()
                var closes = 0
                driver.showMessage("updates.none", detail: "updates.none.detail", stage: .upToDate) { closes += 1 }
                let window = try XCTUnwrap(NSApp.windows.first {
                    $0 is AppUpdateWindow && !before.contains($0.windowNumber) && $0.isVisible
                })
                let host = try XCTUnwrap(window.contentView)
                defer { driver.dismissUpdateInstallation(); window.contentView = nil; window.close() }
                try await settle(host)
                XCTAssertFalse(window.styleMask.contains(.titled))
                XCTAssertTrue(window.canBecomeKey)
                XCTAssertTrue(window.isMovableByWindowBackground)
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    XCTAssertTrue(window.standardWindowButton(kind) == nil || window.standardWindowButton(kind)?.isHidden == true)
                }
                XCTAssertEqual(host.bounds.height, window.frame.height, accuracy: 1)
                XCTAssertLessThanOrEqual(window.frame.height, 210)
                driver.showUserInitiatedUpdateCheck { XCTFail("绘制不得取消检查") }
                try await settle(host)
                try snapshot(host, name: "update-compact-checking-\(mode.rawValue)")
                driver.showDownloadInitiated { XCTFail("绘制不得取消下载") }
                driver.showDownloadDidReceiveExpectedContentLength(100)
                driver.showDownloadDidReceiveData(ofLength: 40)
                try await settle(host)
                XCTAssertLessThanOrEqual(window.frame.height, 250)
                XCTAssertEqual(driver.progress, 0.4)
                try snapshot(host, name: "update-compact-download-\(mode.rawValue)")
                driver.showMessage("updates.none", detail: "updates.none.detail", stage: .upToDate) { closes += 1 }
                try await settle(host)
                try snapshot(host, name: "update-borderless-\(mode.rawValue)-\(usesEscape ? "escape" : "close")")
                if usesEscape {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                } else {
                    try click(window, at: NSPoint(x: window.frame.width / 2, y: 43))
                }
                try await settle(host)
                XCTAssertEqual(closes, 1, "\(mode.rawValue), usesEscape=\(usesEscape)")
                XCTAssertFalse(window.isVisible, "\(mode.rawValue), usesEscape=\(usesEscape)")
            }
        }
    }

    func testNAS后台任务双语主题加载空错误与内容() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 0)
                defer { fixture.cleanPreferences() }
                fixture.model.serverBackgroundTaskHasLoaded = true
                let host = NSHostingView(rootView: NASBackgroundTaskCenter(workspaces: [fixture.model])
                    .environment(MacAppearanceStore())
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 640, height: 520))
                defer { window.contentView = nil; window.close() }
                for state in ["loading", "empty", "error", "content"] {
                    fixture.model.isLoadingServerBackgroundTasks = state == "loading"
                    fixture.model.serverBackgroundTaskError = state == "error" ? L10n.string("background-tasks.error-description") : nil
                    fixture.model.serverBackgroundTasks = state == "content" ? [
                        FileBackgroundTaskSummary(id: "synthetic-active", kind: .copyOrMove, state: .active, progress: 0.4, createdAt: nil, processedItemCount: 4, totalItemCount: 10, processedBytes: 400_000, totalBytes: 1_000_000),
                        FileBackgroundTaskSummary(id: "synthetic-finished", kind: .compress, state: .finished, progress: nil, createdAt: nil, processedItemCount: nil, totalItemCount: nil, processedBytes: nil, totalBytes: nil)
                    ] : []
                    try await settle(host)
                    try snapshot(host, name: "background-tasks-\(state)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                }
                let writes = await fixture.repository.writeCalls
                XCTAssertEqual(writes, 0)
            }
        }
    }

    func test传输中心双语主题及多NAS窄窗口不执行任务操作() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let first = try WorkspaceViewFixture(count: 0)
                let second = try WorkspaceViewFixture(count: 0, displayName: "Another synthetic NAS with a long display name")
                defer { first.cleanPreferences(); second.cleanPreferences() }
                first.model.transfers = [
                    ActivityTask(kind: .upload, displayName: "Sample upload", remotePath: "/synthetic/upload", totalUnits: 100, completedUnits: 25, state: .running),
                    ActivityTask(kind: .download, displayName: "Sample download", remotePath: "/synthetic/download", state: .paused),
                    ActivityTask(kind: .copy, displayName: "Sample copy", remotePath: "/synthetic/copy", state: .succeeded),
                    ActivityTask(kind: .compress, displayName: "Sample archive", remotePath: "/synthetic/archive", state: .failed)
                ]
                let original = first.model.transfers
                let host = NSHostingView(rootView: TransferCenterView(model: first.model, connectedWorkspaces: [first.model, second.model])
                    .environment(MacAppearanceStore())
                    .environment(AppLanguageStore.shared)
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 720, height: 640))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                try snapshot(host, name: "transfers-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                XCTAssertEqual(first.model.transfers, original)
                let writes = await first.repository.writeCalls
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
            }
        }
    }

    func test下载辅助弹窗双语主题不自动创建或保存() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let pages: [(String, NSSize, AnyView)] = [
                    ("pull-image", NSSize(width: 620, height: 540), AnyView(PullImageSheet(search: { _ in [] }, loadTags: { _ in [] }, submit: { _, _ in XCTFail("不能自动下载镜像"); return nil }))),
                    ("create-vm", NSSize(width: 620, height: 500), AnyView(CreateVirtualMachineSheet(snapshot: nil, submit: { _ in XCTFail("不能自动创建虚拟机"); return false }))),
                    ("edit-vm-stopped", NSSize(width: 560, height: 460), AnyView(EditVirtualMachineSheet(machine: VirtualMachine(id: "synthetic-vm", name: "Synthetic virtual machine", status: "stopped", cpuCount: 2, memoryBytes: 2_147_483_648), submit: { _ in XCTFail("不能自动修改虚拟机"); return false }))),
                    ("edit-vm-running", NSSize(width: 560, height: 460), AnyView(EditVirtualMachineSheet(machine: VirtualMachine(id: "synthetic-vm", name: "Synthetic virtual machine", status: "running", cpuCount: 2, memoryBytes: 2_147_483_648), submit: { _ in XCTFail("不能自动修改运行中虚拟机"); return false }))),
                    ("create-network", NSSize(width: 440, height: 300), AnyView(CreateNetworkSheet(submit: { _, _ in XCTFail("不能自动创建网络"); return false }))),
                    ("edit-vm-network", NSSize(width: 440, height: 300), AnyView(EditVirtualMachineNetworkSheet(network: VirtualizationResource(id: "synthetic-network", name: "Synthetic network"), submit: { _ in XCTFail("不能自动保存虚拟网络"); return false }))),
                    ("create", NSSize(width: 620, height: 440), AnyView(CreateDownloadSheet(defaultDestination: nil, loadFolders: { _ in [] }, submitURL: { _, _ in XCTFail("不能自动创建下载"); return false }, submitFile: { _, _, _ in XCTFail("不能自动上传任务"); return false }))),
                    ("settings", NSSize(width: 680, height: 650), AnyView(DownloadSettingsSheet(loadFolders: { _ in [] }, load: { DownloadStationSettings() }, save: { _ in XCTFail("不能自动保存设置"); return false }))),
                    ("settings-error", NSSize(width: 680, height: 650), AnyView(DownloadSettingsSheet(loadFolders: { _ in [] }, load: { throw PresentationRepositoryError.unexpectedOperation }, save: { _ in XCTFail("不能保存未读取设置"); return false }))),
                    ("destination-empty", NSSize(width: 540, height: 440), AnyView(DownloadDestinationPicker(selectedDestination: "", loadFolders: { _ in [] }, onSelect: { _ in XCTFail("不能自动选目录") }, onCancel: { XCTFail("不能自动取消") }))),
                    ("destination-error", NSSize(width: 540, height: 440), AnyView(DownloadDestinationPicker(selectedDestination: "", loadFolders: { _ in throw PresentationRepositoryError.unexpectedOperation }, onSelect: { _ in XCTFail("不能选择未读取目录") }, onCancel: { XCTFail("不能自动取消") })))
                ]
                for (name, size, page) in pages {
                    let host = NSHostingView(rootView: page
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: size)
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "download-sheet-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                    if name == "create-vm" {
                        func findEditableField(_ view: NSView) -> NSTextField? {
                            if let field = view as? NSTextField, field.isEditable { return field }
                            return view.subviews.lazy.compactMap(findEditableField).first
                        }
                        window.makeKeyAndOrderFront(nil)
                        let field = try XCTUnwrap(findEditableField(host))
                        field.selectText(nil)
                        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                        editor.insertText("Synthetic VM", replacementRange: NSRange(location: NSNotFound, length: 0))
                        try await settle(host)
                        XCTAssertEqual(field.stringValue, "Synthetic VM")
                        // 只走前两次“下一步”；绝不触发最终创建及其确认。
                        for step in 2...3 {
                            try click(window, at: NSPoint(x: 550, y: 38))
                            try await settle(host)
                            try snapshot(host, name: "download-sheet-create-vm-step\(step)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                        }
                    }
                }
            }
        }
    }

    func test套件各子页面双语主题绘制() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let pages: [(String, ServiceManagementModel.Module, ContainerManagerPane, VirtualMachineManagerPane)] =
            [("downloads", .downloads, .overview, .machines)]
            + ContainerManagerPane.allCases.map { ("containers-\($0.rawValue)", .containers, $0, .machines) }
            + VirtualMachineManagerPane.allCases.map { ("virtual-machines-\($0.rawValue)", .virtualMachines, .overview, $0) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for (name, module, container, machine) in pages {
                    let model = ServiceManagementModel(repository: ServiceManagementRepositoryStub())
                    await model.activate(module)
                    let host = NSHostingView(rootView: ServiceManagementView(module: module, model: model, containerPane: container, virtualMachinePane: machine)
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 720, height: 640))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "service-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
                    XCTAssertTrue(model.downloadSelection.isEmpty)
                    XCTAssertTrue(model.containerSelection.isEmpty)
                    XCTAssertTrue(model.virtualMachineSelection.isEmpty)
                }
            }
        }
    }

    func test原生文件列表焦点保留复制快捷键() async throws {
        let fixture = try WorkspaceViewFixture(count: 4)
        defer { fixture.cleanPreferences() }
        fixture.model.selection = [try XCTUnwrap(fixture.model.items.first).id]
        var copied = 0
        let host = makeHost(fixture: fixture, mode: .list, scheme: .light, onCopy: { copied += $0.count })
        let window = attach(host, size: NSSize(width: 720, height: 640))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        let table = try XCTUnwrap(findTable(host))
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(window.firstResponder === table)
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        NSApp.sendEvent(copy)
        try await settle(host)
        XCTAssertEqual(copied, 1)
    }

    func test网格获取焦点后可复制而按钮焦点不会复制文件() async throws {
        let fixture = try WorkspaceViewFixture(count: 4)
        defer { fixture.cleanPreferences() }
        var copied = 0
        let host = makeHost(fixture: fixture, mode: .grid, scheme: .light, onCopy: { copied += $0.count })
        let window = attach(host, size: NSSize(width: 720, height: 640))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try click(window, at: NSPoint(x: 100, y: 470))
        try await settle(host)
        XCTAssertEqual(fixture.model.selection.count, 1)
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        NSApp.sendEvent(copy)
        try await settle(host)
        XCTAssertEqual(copied, 1)
        let button = NSButton(title: "", target: nil, action: nil)
        button.frame = NSRect(x: 600, y: 595, width: 80, height: 32)
        host.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        NSApp.sendEvent(copy)
        try await settle(host)
        XCTAssertEqual(copied, 1)
    }

    func test页面操作栏不遮挡原生分栏标题() async throws {
        var leftTitle: NSView?
        var rightTitle: NSView?
        let host = NSHostingView(rootView: HSplitView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 44).background(PresentationLayoutMarker { leftTitle = $0 })
                Color.clear.frame(maxHeight: .infinity)
            }
            VStack(spacing: 0) {
                Color.clear.frame(height: 44).background(PresentationLayoutMarker { rightTitle = $0 })
                Color.clear.frame(maxHeight: .infinity)
            }
        }
        .macPageActions { Color.clear.frame(width: 32, height: 36) }
        .environment(MacAppearanceStore()))
        let window = attach(host, size: NSSize(width: 720, height: 640))
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        for marker in [leftTitle, rightTitle] {
            let marker = try XCTUnwrap(marker)
            let frame = marker.convert(marker.bounds, to: nil)
            XCTAssertGreaterThan(frame.height, 40)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            // 操作栏36点高，上下各10点留白；分栏标题不能进入这56点区域。
            XCTAssertLessThanOrEqual(frame.maxY, 640 - 56 + 1)
        }
    }

    func test照片页双语主题与窄窗口筛选保留选择() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        context.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 30, y: 20, width: 100, height: 80))
        let thumbnail = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoPresentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let profileID = UUID()
                let item = try XCTUnwrap(PhotoLibraryItem(FileItem(profileID: profileID, name: "Sample.jpg", path: "/home/Photos/Sample.jpg", kind: .file, times: FileTimes(modifiedAt: Date(timeIntervalSince1970: 1_788_800_000), createdAt: nil, accessedAt: nil))))
                let repository = PhotoLibraryRepositoryStub(spaces: [.personal, .shared], pages: [0: PhotoLibraryPage(folderPath: "/home/Photos", items: [item], offset: 0, nextOffset: 1, sourceTotal: 1, hasMore: false)], fixtureThumbnailData: thumbnail)
                let model = PhotoLibraryModel(repository: repository, profileID: profileID, cacheStore: PhotoLibraryCacheStore(baseURL: cache), thumbnailDiskCacheStore: PhotoThumbnailDiskCacheStore(baseURL: cache.appendingPathComponent("thumbnails")))
                await model.loadIfNeeded()
                let thumbnailResult = await model.thumbnailData(for: item)
                let loadedThumbnail = try XCTUnwrap(thumbnailResult)
                XCTAssertNotNil(NSImage(data: loadedThumbnail))
                model.selection = [item.id]
                let host = NSHostingView(rootView: PhotoLibraryView(model: model, onPreview: { _ in XCTFail("不能自动预览") }, onDownload: { _ in XCTFail("不能自动下载") }, onDelete: { _ in XCTFail("不能自动删除") }, onRestore: { _ in XCTFail("不能自动恢复") }, onMove: { _, _ in XCTFail("不能自动移动") }, onBrowseModeChange: { model.browseMode = $0 })
                    .environment(MacAppearanceStore())
                    .environment(AppLanguageStore.shared)
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 720, height: 640))
                defer { model.setModuleEnabled(false); window.contentView = nil; window.close() }
                for state in ["timeline", "filtered", "albums"] {
                    model.searchText = state == "filtered" ? "no-match" : ""
                    model.browseMode = state == "albums" ? .albums : .timeline
                    try await settle(host)
                    try snapshot(host, name: "photo-library-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(state)")
                    XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
                    XCTAssertEqual(model.selection, [item.id])
                    if state == "filtered" { XCTAssertTrue(model.displayedItems.isEmpty) }
                }
            }
        }
    }

    func test消息辅助列表双语主题保留选择且不自动转发() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let conversation = ChatConversation(id: "sample", kind: .group, title: "Synthetic group", memberIDs: ["user-1"], lastMessageSummary: nil, lastActivityAt: nil)
                let repository = ChatRepositoryStub(conversations: [conversation])
                let model = ChatWorkspaceModel(repository: repository)
                await model.loadIfNeeded()
                await model.selectConversation(id: conversation.id)
                defer { model.setModuleEnabled(false) }
                let pages: [(String, AnyView)] = [
                    ("forward", AnyView(ForwardMessagesSheet(model: model, messageIDs: ["sample-message"], onComplete: { XCTFail("不能自动转发") }))),
                    ("members", AnyView(GroupMembersSheet(model: model, conversation: conversation))),
                    ("pinned", AnyView(PinnedMessagesSheet(model: model, conversation: conversation))),
                    ("scheduled", AnyView(ScheduledMessageListSheet(model: model))),
                    ("reminders", AnyView(ReminderListSheet(model: model))),
                    ("schedule-editor", AnyView(ScheduledMessageComposerSheet(model: model, conversation: conversation))),
                    ("reminder-editor", AnyView(ReminderEditorSheet(model: model, message: ChatMessage(id: "sample-message", conversationID: conversation.id, senderID: "user-1", sentAt: Date(timeIntervalSince1970: 1_788_800_000), text: "Synthetic reminder message")))),
                    ("poll-editor", AnyView(CreatePollSheet(model: model, conversation: conversation))),
                    ("new-chat", AnyView(NewChatSheet(model: model))),
                    ("image-loading", AnyView(ChatImagePreviewSheet(image: nil))),
                    ("image", AnyView(ChatImagePreviewSheet(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil))))
                ]
                for (name, page) in pages {
                    let host = NSHostingView(rootView: page
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let size: NSSize
                    switch name {
                    case "schedule-editor": size = NSSize(width: 460, height: 300)
                    case "reminder-editor": size = NSSize(width: 420, height: 220)
                    case "poll-editor": size = NSSize(width: 460, height: 390)
                    case "new-chat": size = NSSize(width: 460, height: 460)
                    case "image", "image-loading": size = NSSize(width: 720, height: 520)
                    default: size = NSSize(width: 540, height: 520)
                    }
                    let window = attach(host, size: size)
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "chat-sheet-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(model.selectedConversationID, conversation.id)
                    XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                }
                let sent = await repository.sentTexts()
                let forwarded = await repository.forwardedMessageIDs()
                XCTAssertTrue(sent.isEmpty)
                XCTAssertTrue(forwarded.isEmpty)
            }
        }
    }

    func test消息页双语主题保留草稿且不自动发送() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for hasMessages in [false, true] {
                let conversation = ChatConversation(id: "sample", kind: .direct, title: "Sample conversation", memberIDs: ["user-1"], lastMessageSummary: "Sample message", lastActivityAt: Date(timeIntervalSince1970: 1_788_800_000))
                let messages: [ChatMessage] = hasMessages ? [
                    ChatMessage(id: "incoming", conversationID: conversation.id, senderID: "user-1", sentAt: Date(timeIntervalSince1970: 1_788_800_000), text: "Synthetic incoming message with enough words to verify wrapping inside the narrow conversation pane."),
                    ChatMessage(id: "outgoing", conversationID: conversation.id, senderID: "self", sentAt: Date(timeIntervalSince1970: 1_788_800_060), text: "Synthetic reply — 测试回复")
                ] : []
                let repository = ChatRepositoryStub(conversations: [conversation], users: [ChatUser(id: "user-1", displayName: "Synthetic contact"), ChatUser(id: "self", displayName: "Synthetic self", isCurrentUser: true)], messagesByConversation: [conversation.id: messages])
                let model = ChatWorkspaceModel(repository: repository)
                await model.loadIfNeeded()
                await model.selectConversation(id: conversation.id)
                model.updateDraft("Sample draft", for: conversation.id)
                let host = NSHostingView(rootView: ChatWorkspaceView(model: model)
                    .environment(MacAppearanceStore())
                    .environment(AppLanguageStore.shared)
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 720, height: 640))
                defer { model.setModuleEnabled(false); window.contentView = nil; window.close() }
                try await settle(host)
                try snapshot(host, name: "chat-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(hasMessages ? "content" : "empty")")
                XCTAssertEqual(Set(model.messages.map(\.id)), Set(messages.map(\.id)))
                XCTAssertEqual(model.selectedConversationID, conversation.id)
                XCTAssertEqual(model.draftText(for: conversation.id), "Sample draft")
                let sent = await repository.sentTexts()
                XCTAssertTrue(sent.isEmpty)
                XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
                }
            }
        }
    }

    func test存储池与磁盘测试状态可滚动查看且不触发测试() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let disk = NasDisk(id: "synthetic-disk", name: "Synthetic disk", model: "Synthetic model", type: "SSD", totalBytes: 1_000_000_000, status: "normal", smartStatus: "normal", temperatureCelsius: 30, isSSD: true, usedBy: nil, supportsSmartTest: true)
        let pool = NasStoragePool(id: "synthetic-pool", name: "Synthetic pool", raidType: "RAID1", status: "normal", totalBytes: 1_000_000_000, usedBytes: 200_000_000, isWritable: true, isScrubbing: false, nextScrubbingDate: nil)
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["pool", "idle", "running", "busy", "error"] {
                    let status: NasDiskTestStatus? = state == "error" ? nil : NasDiskTestStatus(diskID: disk.id, isRunning: state == "running", isBusyWithOtherTest: state == "busy", runningType: state == "running" ? .extended : nil, progressDescription: state == "running" ? "40%" : nil)
                    let host = NSHostingView(rootView: StorageDetailSheet(selection: state == "pool" ? .pool(pool) : .disk(disk), snapshot: nil, testStatus: status, isDiskBusy: false, loadTestStatus: { id in
                        XCTAssertEqual(id, disk.id)
                        if state == "error" { throw PresentationRepositoryError.unexpectedOperation }
                    }, startTest: { _, _ in XCTFail("不能自动启动磁盘测试") }, stopTest: { _ in XCTFail("不能自动停止磁盘测试") })
                        .environment(MacAppearanceStore())
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 600, height: 580))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "storage-\(state)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    if state != "pool" {
                        func findScroll(_ view: NSView) -> NSScrollView? {
                            if let scroll = view as? NSScrollView { return scroll }
                            return view.subviews.lazy.compactMap(findScroll).first
                        }
                        let scroll = try XCTUnwrap(findScroll(host))
                        let document = try XCTUnwrap(scroll.documentView)
                        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                        let y = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : 0
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try await settle(host)
                        try snapshot(host, name: "storage-\(state)-controls-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    }
                }
            }
        }
    }

    func testNAS网络与账号弹窗双语主题不保存配置() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let interface = NasEthernetInterface(id: "synthetic", displayName: "Synthetic interface", status: nil, usesDHCP: true, address: "", subnetMask: "", gateway: "", dnsServers: "", isDefaultGateway: false, mtu: 1500, isVLANEnabled: false, vlanID: nil)
        let task = NasScheduledTask(id: "synthetic", name: "Synthetic task", owner: nil, type: nil, action: nil, isEnabled: false, nextTriggerDescription: nil, canRun: false, canEdit: false)
        let result = NasScheduledTaskResult(id: "synthetic-result", taskName: task.name, startedAt: Date(timeIntervalSince1970: 1_788_800_000), stoppedAt: Date(timeIntervalSince1970: 1_788_800_060), exitType: nil, exitCode: 0, triggerEvent: nil)
        let volume = NasVolume(id: "synthetic-volume", name: "Synthetic volume", fileSystem: "btrfs", status: "normal", totalBytes: 1_000_000, usedBytes: 200_000, isEncrypted: false, isWritable: true)
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let pages: [(String, NSSize, AnyView)] = [
                    ("task-new", NSSize(width: 560, height: 520), AnyView(ScheduledTaskEditor(initialDraft: NasScheduledTaskDraft(owner: ""), isReadOnly: false, onCancel: { XCTFail("不能自动取消") }, onSave: { _ in XCTFail("不能自动保存任务"); return nil }))),
                    ("task-readonly", NSSize(width: 560, height: 520), AnyView(ScheduledTaskEditor(initialDraft: NasScheduledTaskDraft(id: 1, name: "Synthetic task", owner: "Synthetic user"), isReadOnly: true, onCancel: { XCTFail("不能自动关闭") }, onSave: { _ in XCTFail("不能保存只读任务"); return nil }))),
                    ("task-results", NSSize(width: 720, height: 480), AnyView(ScheduledTaskResultsSheet(task: task, loadResults: { [result] }, loadOutput: { _ in NasScheduledTaskResultOutput(command: "Synthetic command display only", output: "Synthetic output") }))),
                    ("task-results-empty", NSSize(width: 720, height: 480), AnyView(ScheduledTaskResultsSheet(task: task, loadResults: { [] }, loadOutput: { _ in XCTFail("空记录不应读取输出"); throw PresentationRepositoryError.unexpectedOperation }))),
                    ("task-results-error", NSSize(width: 720, height: 480), AnyView(ScheduledTaskResultsSheet(task: task, loadResults: { throw PresentationRepositoryError.unexpectedOperation }, loadOutput: { _ in XCTFail("失败记录不应读取输出"); throw PresentationRepositoryError.unexpectedOperation }))),
                    ("storage-volume", NSSize(width: 560, height: 480), AnyView(StorageDetailSheet(selection: .volume(volume), snapshot: nil, testStatus: nil, isDiskBusy: false, loadTestStatus: { _ in XCTFail("卷详情不能读取磁盘测试") }, startTest: { _, _ in XCTFail("不能自动启动磁盘测试") }, stopTest: { _ in XCTFail("不能自动停止磁盘测试") }))),
                    ("ethernet", NSSize(width: 560, height: 520), AnyView(EthernetInterfaceEditor(interface: interface, onCancel: { XCTFail("不能自动取消") }, onSave: { _ in XCTFail("不能自动修改网络") }))),
                    ("ddns", NSSize(width: 520, height: 420), AnyView(DDNSRecordEditor(draft: NasDDNSDraft(providerID: "Synology", hostname: "", username: ""), providers: [NasDDNSProvider(id: "Synology", displayName: "Synology")], onCancel: { XCTFail("不能自动取消") }, onTest: { _ in XCTFail("不能自动测试域名") }, onSave: { _ in XCTFail("不能自动保存域名") }))),
                    ("new-account", NSSize(width: 540, height: 560), AnyView(AccountEditor(initialDraft: NasAccountDraft(groups: []), availableGroups: ["Synthetic group"], onCancel: { XCTFail("不能自动取消") }, onSave: { _ in XCTFail("不能自动创建用户"); return nil }))),
                    ("edit-account", NSSize(width: 540, height: 560), AnyView(AccountEditor(initialDraft: NasAccountDraft(originalName: "Synthetic user", name: "Synthetic user", groups: ["Synthetic group"]), availableGroups: ["Synthetic group"], onCancel: { XCTFail("不能自动取消") }, onSave: { _ in XCTFail("不能自动修改用户"); return nil }))),
                    ("new-group", NSSize(width: 480, height: 320), AnyView(GroupEditor(initialDraft: NasGroupDraft(), onCancel: { XCTFail("不能自动取消") }, onSave: { _ in XCTFail("不能自动创建群组"); return nil }))),
                    ("edit-group", NSSize(width: 480, height: 320), AnyView(GroupEditor(initialDraft: NasGroupDraft(originalName: "Synthetic group", name: "Synthetic group"), onCancel: { XCTFail("不能自动取消") }, onSave: { _ in XCTFail("不能自动修改群组"); return nil })))
                ]
                for (name, size, page) in pages {
                    let host = NSHostingView(rootView: page
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: size)
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "nas-editor-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                }
            }
        }
    }

    func testNAS各二级页面双语主题绘制不触发控制操作() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let repository = NasAdministrationRepositoryStub()
                let model = NasSettingsModel(repository: repository)
                model.setModuleEnabled(true)
                await model.activate(.overview)
                model.isLiveUpdatesPaused = true
                let host = NSHostingView(rootView: NasSettingsView(model: model)
                    .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                    .environment(MacAppearanceStore())
                    .environment(AppLanguageStore.shared)
                    .environment(\.locale, AppLanguageStore.shared.locale)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1000, height: 700))
                defer { model.setModuleEnabled(false); window.contentView = nil; window.close() }
                for page in NasSettingsPage.allCases {
                    await model.activate(page)
                    try await settle(host)
                    try snapshot(host, name: "nas-\(page.rawValue)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(model.selectedPage, page)
                    XCTAssertEqual(host.bounds.width, 1000, accuracy: 1)
                }
                let packageWrites = await repository.packageControlRequestCount()
                let diskWrites = await repository.diskTestRequestCount()
                let powerWrites = await repository.powerActionRequestCount()
                XCTAssertEqual(packageWrites, 0)
                XCTAssertEqual(diskWrites, 0)
                XCTAssertEqual(powerWrites, 0)
            }
        }
    }

    func test登录双语双主题及连接状态不触发认证() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["empty", "ready", "busy", "otp", "error"] {
                    let suite = "LoginPresentation.\(UUID().uuidString)"
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                    defer { defaults.removePersistentDomain(forName: suite) }
                    let authentication = PresentationAuthentication()
                    let model = AppModel(profileStore: NasProfileStore(defaults: defaults), authRepository: authentication, passwordStore: authentication)
                    if state != "empty" {
                        let profile = try NasProfile(displayName: "Sample NAS", host: "example.invalid", port: 5001)
                        model.profiles = [profile]
                        model.selectedProfileID = profile.id
                        model.displayName = profile.displayName
                        model.host = profile.host
                        model.account = "sample"
                    }
                    model.isBusy = state == "busy"
                    model.requiresOTP = state == "otp"
                    model.statusIsError = state == "error"
                    let host = NSHostingView(rootView: LoginView(model: model)
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 980, height: 740))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "login-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(state)")
                    let calls = await authentication.calls
                    XCTAssertEqual(calls, 0)
                    XCTAssertEqual(host.bounds.width, 980, accuracy: 1)
                }
            }
        }
    }

    func test照片预览与视频控制区继承主题且不发起写操作() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
        context.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 30, y: 100, width: 260, height: 220))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 0)
                defer { fixture.cleanPreferences() }
                let item = FileItem(profileID: fixture.model.profile.id, name: "Sample.png", path: "/synthetic/Sample.png", kind: .file)
                fixture.model.items = [item]
                fixture.model.selection = [item.id]
                fixture.model.preview = .image(data)
                fixture.model.resolvedPreviewKind = .image
                let host = NSHostingView(rootView: FileDetailView(model: fixture.model, windowState: PreviewWindowPresentationState(), onDownload: { _, _ in XCTFail("预览不能自动下载") }, onDelete: { _ in XCTFail("预览不能自动删除") }, onRestore: { _ in XCTFail("预览不能自动恢复") })
                    .environment(MacAppearanceStore())
                    .environment(AppLanguageStore.shared)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 980, height: 700))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                try await settle(host)
                try snapshot(host, name: "photo-preview-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                XCTAssertEqual(fixture.model.selection, [item.id])
                let writes = await fixture.repository.writeCalls
                XCTAssertEqual(writes, 0)
            }
        }
        let playerHost = NSHostingView(rootView: VideoPlayerRepresentable(player: .constant(nil), controlsStyle: .inline))
        let playerWindow = attach(playerHost, size: NSSize(width: 800, height: 500))
        defer { playerWindow.contentView = nil; playerWindow.close() }
        try await settle(playerHost)
        func playerView(in view: NSView) -> AVPlayerView? {
            if let player = view as? AVPlayerView { return player }
            return view.subviews.lazy.compactMap { playerView(in: $0) }.first
        }
        let player = try XCTUnwrap(playerView(in: playerHost))
        XCTAssertEqual(player.controlsStyle, .inline)
        XCTAssertTrue(player.showsFrameSteppingButtons)
        XCTAssertTrue(player.showsSharingServiceButton)
    }

    func test视频预览没有外层系统按钮和留白且自带关闭有效() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let fixture = try WorkspaceViewFixture(count: 0)
            defer { fixture.cleanPreferences() }
            let item = FileItem(profileID: fixture.model.profile.id, name: "Synthetic.mp4", path: "/synthetic/video.mp4", kind: .file)
            fixture.model.items = [item]
            fixture.model.selection = [item.id]
            fixture.model.resolvedPreviewKind = .video
            fixture.model.preview = .failed("Synthetic playback state")
            fixture.model.isPreviewPresented = true
            let host = NSHostingView(rootView: FileDetailView(model: fixture.model, windowState: PreviewWindowPresentationState(), onDownload: { _, _ in XCTFail("不得自动下载") }, onDelete: { _ in XCTFail("不得删除") }, onRestore: { _ in XCTFail("不得恢复") })
                .environment(MacAppearanceStore()).environment(AppLanguageStore.shared).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 980, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable])
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertTrue(window.standardWindowButton(kind)?.isHidden == true)
            }
            XCTAssertTrue(window.isMovableByWindowBackground)
            try snapshot(host, name: "video-compact-chrome-\(scheme == .dark ? "dark" : "light")")
            try click(window, at: NSPoint(x: 948, y: 672))
            try await settle(host)
            XCTAssertFalse(fixture.model.isPreviewPresented)
        }
    }

    func test文件五态与双语双主题快照() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["content", "empty", "filtered", "loading", "error"] {
                    let fixture = try WorkspaceViewFixture(count: state == "empty" ? 0 : 8)
                    defer { fixture.cleanPreferences() }
                    if state == "filtered" { fixture.model.searchText = "no-synthetic-match" }
                    if state == "loading" { fixture.model.isLoading = true }
                    if state == "error" {
                        fixture.model.items = []
                        fixture.model.statusMessage = L10n.string("auth.reauthentication.default")
                        fixture.model.statusIsError = true
                    }
                    if state == "content" {
                        fixture.model.selection = Set(fixture.model.items.prefix(2).map(\.id))
                    }
                    let host = makeHost(fixture: fixture, mode: .grid, scheme: scheme)
                    let window = attach(host, size: NSSize(width: 1_020, height: 730))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "files-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")-\(state)")
                    XCTAssertEqual(host.bounds.size, NSSize(width: 1_020, height: 730))
                    let writeCalls = await fixture.repository.writeCalls
                    XCTAssertEqual(writeCalls, 0)
                }
            }
        }
    }

    func test千项万项文件绘制与过滤基线() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        AppLanguageStore.shared.selection = .english
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let signposter = OSSignposter(subsystem: "lanstash.ui-checks", category: "PointsOfInterest")
        let profilesIntervals = ProcessInfo.processInfo.environment["LANSTASH_UI_PROFILE_INTERVALS"] == "1"
        var measurements: [[String: Any]] = []
        for count in [1_000, 10_000] {
            for mode in [FileViewMode.list, .grid] {
                for sample in 1...3 {
                    let fixture = try WorkspaceViewFixture(count: count)
                    defer { fixture.cleanPreferences() }
                    let start = CFAbsoluteTimeGetCurrent()
                    let host = makeHost(fixture: fixture, mode: mode, scheme: .light)
                    let window = attach(host, size: NSSize(width: 1_020, height: 730))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    let interval = profilesIntervals ? signposter.beginInterval(
                        "FileFilter", id: signposter.makeSignpostID(), "items=\(count) mode=\(mode.rawValue, privacy: .public) sample=\(sample)"
                    ) : nil
                    let rendered = CFAbsoluteTimeGetCurrent()
                    fixture.model.searchText = "0001"
                    host.layoutSubtreeIfNeeded()
                    let filtered = fixture.model.filteredItems
                    let searched = CFAbsoluteTimeGetCurrent()
                    if let interval { signposter.endInterval("FileFilter", interval) }
                    XCTAssertFalse(filtered.isEmpty)
                    XCTAssertTrue(filtered.allSatisfy { $0.name.contains("0001") })
                    let writeCalls = await fixture.repository.writeCalls
                    XCTAssertEqual(writeCalls, 0)
                    measurements.append([
                        "items": count, "mode": mode.rawValue, "sample": sample,
                        "initialLayoutSeconds": rendered - start,
                        "filterAndLayoutSeconds": searched - rendered,
                    ])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifacts.appendingPathComponent("file-layout-measurements.json"))
        print("合成文件布局基线：\(measurements.count) 组。测量含固定等待，不代表屏幕滚动帧率。")
    }

    func test工作区主题切换保持选择路径且不增加请求() async throws {
        let fixture = try WorkspaceViewFixture(count: 8, displayName: "我的 NAS")
        defer { fixture.cleanPreferences() }
        let sampleNames = ["文档", "图片", "视频", "音乐", "项目", "备份", "共享", "归档"]
        fixture.model.items = sampleNames.enumerated().map { index, name in
            FileItem(profileID: fixture.model.profile.id, name: name, path: "/synthetic/folder-\(index)", kind: .directory)
        }
        fixture.model.shares = fixture.model.items
        fixture.model.storageSpaceSummary = StorageSpaceSummary(totalBytes: 8_000_000_000_000, remainingBytes: 5_600_000_000_000, volumeCount: 1)
        let appearance = MacAppearanceStore.shared
        let previousMode = appearance.mode
        let previousNativeAppearance = NSApp.appearance
        let previousLanguage = AppLanguageStore.shared.selection
        defer {
            appearance.mode = previousMode
            NSApp.appearance = previousNativeAppearance
            AppLanguageStore.shared.selection = previousLanguage
        }
        AppLanguageStore.shared.selection = .simplifiedChinese
        let host = makeWorkspaceHost(fixture: fixture)
        let window = attach(host, size: NSSize(width: 1_260, height: 780))
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        fixture.model.selection = Set(fixture.model.items.prefix(2).map(\.id))
        let selection = fixture.model.selection
        let currentPath = fixture.model.currentPath
        let reads = await fixture.repository.readCalls
        for mode in [MacAppearanceMode.fog, .ink, .system] {
            appearance.mode = mode
            try await settle(host)
            XCTAssertEqual(fixture.model.selection, selection)
            XCTAssertEqual(fixture.model.currentPath, currentPath)
            let currentReads = await fixture.repository.readCalls
            let currentWrites = await fixture.repository.writeCalls
            XCTAssertEqual(currentReads, reads)
            XCTAssertEqual(currentWrites, 0)
            try snapshot(host, name: "workspace-\(mode.rawValue)")
            if ProcessInfo.processInfo.environment["LANSTASH_UI_NATIVE_SCREENSHOTS"] == "1" {
                NSApp.setActivationPolicy(.regular)
                defer { NSApp.setActivationPolicy(.accessory) }
                window.center()
                let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -24, dy: -24), styleMask: .borderless, backing: .buffered, defer: false)
                backdrop.isReleasedWhenClosed = false
                backdrop.contentView = NSHostingView(rootView: SyntheticDesktopBackdrop(isDark: mode == .ink))
                backdrop.orderFront(nil)
                defer { backdrop.contentView = nil; backdrop.close() }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(300))
                print("原生窗口检查：active=\(NSApp.isActive)，key=\(window.isKeyWindow)，opaque=\(window.isOpaque)")
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                let rect = window.frame
                let screenTop = NSScreen.screens.first?.frame.maxY ?? rect.maxY
                capture.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(screenTop - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))", artifacts.appendingPathComponent("native-workspace-\(mode.rawValue).png").path]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0, "原生窗口截图需要屏幕录制权限；失败时不能视为视觉验收通过。")
            }
            if ProcessInfo.processInfo.environment["LANSTASH_UI_PREVIEW_MODE"] == mode.rawValue {
                NSApp.setActivationPolicy(.regular)
                window.title = "LanStash UI Sample — Synthetic Data"
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let marker = "UI_PREVIEW_WINDOW_ID=\(window.windowNumber)\n"
                FileHandle.standardOutput.write(Data(marker.utf8))
                // 给本机窗口截图与人工检查留出时间；普通自动化运行不会进入此分支。
                for _ in 0..<12 { try await Task.sleep(for: .seconds(15)) }
            }
        }
    }

    func test完整工作区跨模块切换保留文件选择和窗口标题区() async throws {
        let previousMode = MacAppearanceStore.shared.mode
        let previousLanguage = AppLanguageStore.shared.selection
        defer { MacAppearanceStore.shared.mode = previousMode; AppLanguageStore.shared.selection = previousLanguage }
        let pages: [WorkspaceSection] = [.chat, .downloadStation, .containerManager(.overview), .virtualMachineManager(.machines), .nasSettings, .transfers, .settings]
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for mode in [MacAppearanceMode.fog, .ink] {
                MacAppearanceStore.shared.mode = mode
                let fixture = try WorkspaceViewFixture(count: 4, chatRepository: ChatRepositoryStub(conversations: []), nasSettingsRepository: NasAdministrationRepositoryStub(), serviceManagementRepository: ServiceManagementRepositoryStub())
                defer { fixture.model.chat.setModuleEnabled(false); fixture.model.nasSettings.setModuleEnabled(false); fixture.cleanPreferences() }
                fixture.model.isNasSettingsModuleEnabled = true
                fixture.model.nasSettings.isLiveUpdatesPaused = true
                fixture.model.serverBackgroundTaskHasLoaded = true
                let loadedItems = fixture.model.items
                let host = makeWorkspaceHost(fixture: fixture)
                let window = attach(host, size: NSSize(width: 1100, height: 740))
                defer { window.contentView = nil; window.close() }
                // 工作区首次显示会正常打开根目录；启动完成后再建立本测试的已浏览状态。
                try await settle(host)
                fixture.model.shares = loadedItems
                fixture.model.items = loadedItems
                fixture.model.currentPath = "/synthetic"
                fixture.model.section = .files("/synthetic")
                try await settle(host)
                fixture.model.selection = [try XCTUnwrap(loadedItems.first).id]
                let originalSelection = fixture.model.selection
                let originalPath = fixture.model.currentPath
                for page in pages {
                    fixture.model.section = page
                    switch page {
                    case .chat: await fixture.model.chat.loadIfNeeded()
                    case .downloadStation: await fixture.model.serviceManagement.activate(.downloads)
                    case .containerManager: await fixture.model.serviceManagement.activate(.containers)
                    case .virtualMachineManager: await fixture.model.serviceManagement.activate(.virtualMachines)
                    case .nasSettings: await fixture.model.nasSettings.activate(.overview)
                    default: break
                    }
                    try await settle(host)
                    try snapshot(host, name: "whole-module-\(page.id)-\(language.rawValue)-\(mode.rawValue)")
                    XCTAssertEqual(fixture.model.section, page)
                    XCTAssertEqual(fixture.model.selection, originalSelection)
                    XCTAssertEqual(fixture.model.currentPath, originalPath)
                    XCTAssertEqual(window.titleVisibility, .hidden)
                    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
                }
                let writes = await fixture.repository.writeCalls
                XCTAssertEqual(writes, 0)
            }
        }
    }

    func test文件与设置往返保持窗口及当前目录() async throws {
        guard !DesktopCloudDriveAvailability.isAvailable else {
            XCTFail("合成设置检查不得在带有可用真实文件扩展的宿主中运行。")
            return
        }
        for size in [NSSize(width: 1_260, height: 780), NSSize(width: 980, height: 640)] {
            let fixture = try WorkspaceViewFixture(count: 8)
            defer { fixture.cleanPreferences() }
            fixture.model.shares = fixture.model.items
            let host = makeWorkspaceHost(fixture: fixture)
            let window = attach(host, size: size)
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            let path = fixture.model.currentPath
            fixture.model.selection = Set(fixture.model.items.prefix(2).map(\.id))
            let selection = fixture.model.selection
            let reads = await fixture.repository.readCalls
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
            for iteration in 0..<2 {
                fixture.model.section = .settings
                try await settle(host)
                XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
                XCTAssertEqual(window.titleVisibility, .hidden)
                XCTAssertEqual(fixture.model.currentPath, path)
                XCTAssertEqual(fixture.model.selection, selection)
                XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                try snapshot(host, name: "settings-transition-\(Int(size.width))-\(iteration)")
                fixture.model.section = fixture.model.currentFileSection
                try await settle(host)
                XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
                XCTAssertEqual(fixture.model.currentPath, path)
                XCTAssertEqual(fixture.model.selection, selection)
                XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                try snapshot(host, name: "files-transition-\(Int(size.width))-\(iteration)")
            }
            let writes = await fixture.repository.writeCalls
            let finalReads = await fixture.repository.readCalls
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(finalReads, reads)
        }
    }

    func test宽窗口详情与最小文件区域绘制() async throws {
        let fixture = try WorkspaceViewFixture(count: 8)
        defer { fixture.cleanPreferences() }
        fixture.model.selection = [try XCTUnwrap(fixture.model.items.first).id]
        for scheme in [ColorScheme.light, .dark] {
            let host = makeHost(fixture: fixture, mode: .grid, scheme: scheme, showsInspector: .constant(true))
            let window = attach(host, size: NSSize(width: 1_020, height: 730))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            try snapshot(host, name: "inspector-\(scheme == .dark ? "dark" : "light")")
            XCTAssertEqual(host.frame.size.width, 1_020)
        }
        let narrowHost = makeHost(fixture: fixture, mode: .grid, scheme: .light)
        let narrowWindow = attach(narrowHost, size: NSSize(width: 480, height: 640))
        defer { narrowWindow.contentView = nil; narrowWindow.close() }
        try await settle(narrowHost)
        try snapshot(narrowHost, name: "files-narrow-selection")
        XCTAssertEqual(narrowHost.bounds.width, 480)
        var inspectorPresented = true
        let adaptiveHost = makeHost(fixture: fixture, mode: .grid, scheme: .light, showsInspector: Binding(
            get: { inspectorPresented }, set: { inspectorPresented = $0 }
        ))
        let adaptiveWindow = attach(adaptiveHost, size: NSSize(width: 1_020, height: 730))
        defer { adaptiveWindow.contentView = nil; adaptiveWindow.close() }
        adaptiveWindow.makeKeyAndOrderFront(nil)
        try await settle(adaptiveHost)
        XCTAssertTrue(inspectorPresented)
        adaptiveWindow.setContentSize(NSSize(width: 740, height: 730))
        try await settle(adaptiveHost)
        try await settle(adaptiveHost)
        XCTAssertFalse(inspectorPresented)
        XCTAssertEqual(adaptiveHost.bounds.width, 740)
    }

    func test大字号文件布局() async throws {
        let fixture = try WorkspaceViewFixture(count: 8)
        defer { fixture.cleanPreferences() }
        fixture.model.selection = Set(fixture.model.items.prefix(2).map(\.id))
        for scheme in [ColorScheme.light, .dark] {
            let host = makeHost(fixture: fixture, mode: .grid, scheme: scheme, largeText: true)
            let window = attach(host, size: NSSize(width: 480, height: 640))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            XCTAssertEqual(host.bounds.width, 480)
            try snapshot(host, name: "files-accessible-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func test底部分享与清除选择使用当前全部选中项() async throws {
        let fixture = try WorkspaceViewFixture(count: 8)
        defer { fixture.cleanPreferences() }
        let previousLanguage = AppLanguageStore.shared.selection
        AppLanguageStore.shared.selection = .simplifiedChinese
        defer { AppLanguageStore.shared.selection = previousLanguage }
        fixture.model.selection = Set(fixture.model.items.prefix(2).map(\.id))
        var sharedIDs: [FileItem.ID] = []
        var shareCalls = 0
        let host = makeHost(fixture: fixture, mode: .grid, scheme: .light, onShare: { sharedIDs = $0.map(\.id); shareCalls += 1 })
        let window = attach(host, size: NSSize(width: 480, height: 640))
        defer { window.contentView = nil; window.close() }
        window.title = "LanStash UI Actions — Synthetic Data"
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try snapshot(host, name: "actions-before")
        // 此固定中文窄窗口布局的按钮位置同时由截图校验；发送真实窗口事件而非直接调用回调。
        try click(window, at: NSPoint(x: 267, y: 78))
        try await settle(host)
        XCTAssertEqual(Set(sharedIDs), fixture.model.selection)
        XCTAssertEqual(sharedIDs.count, 2)
        XCTAssertEqual(shareCalls, 1)
        try click(window, at: NSPoint(x: 334, y: 78))
        try await settle(host)
        XCTAssertTrue(fixture.model.selection.isEmpty)
        try click(window, at: NSPoint(x: 267, y: 78))
        try await settle(host)
        XCTAssertEqual(shareCalls, 1)
        try snapshot(host, name: "actions-cleared")
    }

    func test文件辅助页面和弹窗继承双语主题且不提交操作() async throws {
        let fixture = try WorkspaceViewFixture(count: 2)
        defer { fixture.cleanPreferences() }
        let isolatedStoreURL = FileManager.default.temporaryDirectory.appendingPathComponent("MappingPresentation-\(UUID().uuidString)")
        let mappingManager = DesktopCloudDriveManager(profile: fixture.model.profile, repository: fixture.repository, store: DesktopDriveConfigurationStore(directoryURL: isolatedStoreURL), isAvailable: false)
        defer { if FileManager.default.fileExists(atPath: isolatedStoreURL.path) { try? FileManager.default.removeItem(at: isolatedStoreURL) } }
        let item = try XCTUnwrap(fixture.model.items.first)
        let oldLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = oldLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let samples: [(String, AnyView)] = [
                    ("photo-destination-empty", AnyView(PhotoFolderDestinationPicker(repository: PhotoLibraryRepositoryStub(spaces: [.personal], pages: [0: PhotoLibraryPage(folderPath: "/home/Photos", items: [], offset: 0, nextOffset: 0, sourceTotal: 0, hasMore: false)]), profileID: nil, sourcePath: "/home/Photos/Synthetic.jpg", onSelect: { _ in XCTFail("不能自动选择移动位置") }, onCancel: { XCTFail("不能自动取消") }))),
                    ("photo-destination-error", AnyView(PhotoFolderDestinationPicker(repository: PhotoLibraryRepositoryStub(spaces: [.personal], pages: [:]), profileID: nil, sourcePath: "/home/Photos/Synthetic.jpg", onSelect: { _ in XCTFail("不能自动选择移动位置") }, onCancel: { XCTFail("不能自动取消") }))),
                    ("mapping-create", AnyView(DesktopDriveMappingCreatorSheet(manager: mappingManager, profileName: "Synthetic NAS", currentPath: "/synthetic"))),
                    ("cache-cleanup", AnyView(SelectiveCacheCleanupSheet(storage: AppStorageSnapshot(previewCache: 200_000, photoCache: 800_000, systemCache: 100_000, protectedData: 20_000), onClean: { _ in XCTFail("不能自动清理缓存") }))),
                    ("certificate-new", AnyView(CertificateReviewView(prompt: CertificatePrompt(error: .untrusted(DsmCertificateReview(host: "example.invalid", subjectSummary: "Synthetic certificate", sha256Fingerprint: String(repeating: "A", count: 64), canBePinned: true)), previousFingerprint: nil), onCancel: { XCTFail("不能自动取消核对") }, onTrust: { XCTFail("不能自动信任证书") }))),
                    ("certificate-changed", AnyView(CertificateReviewView(prompt: CertificatePrompt(error: .changed(DsmCertificateReview(host: "example.invalid", subjectSummary: "Synthetic certificate", sha256Fingerprint: String(repeating: "B", count: 64), canBePinned: true)), previousFingerprint: String(repeating: "A", count: 64)), onCancel: { XCTFail("不能自动取消核对") }, onTrust: { XCTFail("不能自动信任变化证书") }))),
                    ("certificate-rejected", AnyView(CertificateReviewView(prompt: CertificatePrompt(error: .invalid(DsmCertificateReview(host: "example.invalid", subjectSummary: "Synthetic certificate", sha256Fingerprint: String(repeating: "C", count: 64), canBePinned: false)), previousFingerprint: nil), onCancel: { XCTFail("不能自动取消核对") }, onTrust: { XCTFail("不能信任无效证书") }))),
                    ("diagnostics", AnyView(DesktopDriveDiagnosticExportSheet(preview: "{\"synthetic\": true}"))),
                    ("community-report", AnyView(CommunityCompatibilitySubmissionSheet())),
                    ("favorites", AnyView(LocationCollectionView(title: L10n.string("ui.60a53514eb9228a2"), locations: [], emptyMessage: L10n.string("ui.827428ead1987b8a"), onOpen: { _ in }))),
                    ("recent", AnyView(RecentLocationsView(locations: [], onOpen: { _ in }, onRemove: { _ in }, onClearAll: {}))),
                    ("remote", AnyView(RemoteLocationsView(model: fixture.model, onOpen: { _ in }))),
                    ("remote-editor", AnyView(RemoteMountEditorView(existingItem: nil, initialMountPoint: "/synthetic", onSave: { _ in nil }))),
                    ("share-links", AnyView(ShareLinksView(model: fixture.model))),
                    ("share-create", AnyView(ShareCreationView(model: fixture.model, targets: fixture.model.items, onClose: {}))),
                    ("archive-create", AnyView(ArchiveCreationView(targets: fixture.model.items, onCreate: { _, _, _, _ in }, onCancel: {}))),
                    ("archive-extract", AnyView(ArchiveExtractionView(item: item, onExtract: { _, _, _ in }, onCancel: {}))),
                    ("archive-password", AnyView(ArchivePasswordView(archiveName: "synthetic.zip", errorMessage: nil, isChecking: false, onSubmit: { _ in }, onCancel: {}))),
                    ("properties", AnyView(FilePropertiesView(item: item, model: fixture.model))),
                    ("delete-confirm", AnyView(ModernDeleteConfirmationDialog(targets: fixture.model.items, profileName: fixture.model.profile.displayName, currentPath: "/synthetic", onConfirm: {}, onCancel: {}))),
                    ("appearance", AnyView(MacAppearanceSettingsView().padding(24))),
                ]
                for (name, view) in samples {
                    let host = NSHostingView(rootView: view
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                        .environment(MacAppearanceStore.shared)
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 680))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "aux-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    if name == "appearance" {
                        XCTAssertLessThanOrEqual(host.bounds.height, 680)
                    }
                    let writes = await fixture.repository.writeCalls
                    XCTAssertEqual(writes, 0)
                    XCTAssertTrue(mappingManager.mappings.isEmpty)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedStoreURL.path))
                }
            }
        }
    }

    func test设置窗口保留原生按钮且不恢复白色标题栏() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        let previousMode = MacAppearanceStore.shared.mode
        AppLanguageStore.shared.selection = .simplifiedChinese
        MacAppearanceStore.shared.mode = .fog
        defer {
            AppLanguageStore.shared.selection = previousLanguage
            MacAppearanceStore.shared.mode = previousMode
        }
        guard !DesktopCloudDriveAvailability.isAvailable else {
            XCTFail("合成设置检查不得运行真实文件扩展。")
            return
        }
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.cleanPreferences() }
        let updates = AppUpdateController(bundle: Bundle(for: Self.self), canRestart: { false })
        XCTAssertNil(updates.updater)
        defer { updates.driver.dismissUpdateInstallation() }
        let host = makeWorkspaceHost(fixture: fixture, updates: updates)
        let window = attach(host, size: NSSize(width: 1100, height: 740))
        window.styleMask.insert(.miniaturizable)
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        fixture.model.section = .settings
        try await settle(host)

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        }
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.backgroundColor, .clear)
        try snapshot(host, name: "settings-window-native-controls")
        try click(window, at: NSPoint(x: 420, y: 487))
        try await settle(host)
        try snapshot(host, name: "settings-appearance-concise")
        try click(window, at: NSPoint(x: 420, y: 445))
        try await settle(host)
        try snapshot(host, name: "settings-features-concise")
        try click(window, at: NSPoint(x: 420, y: 318))
        try await settle(host)
        try snapshot(host, name: "settings-updates-integrated")
        try click(window, at: NSPoint(x: 990, y: 452))
        try await settle(host)
        XCTAssertEqual(updates.driver.titleKey, "updates.unavailable", "设置按钮必须调用注入的同一更新控制器")
        XCTAssertFalse(updates.driver.isRestartRequested)
        updates.driver.dismissUpdateInstallation()
        window.makeKeyAndOrderFront(nil)
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for mode in [MacAppearanceMode.fog, .ink] {
                MacAppearanceStore.shared.mode = mode
                try await settle(host)
                try snapshot(host, name: "settings-updates-\(language.rawValue)-\(mode.rawValue)")
            }
        }
    }

    func test设置分类左右空白区域单击即可切换() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        AppLanguageStore.shared.selection = .simplifiedChinese
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let selection = PageTabSelectionProbe()
        let categories = SettingsCategory.allCases
        let host = NSHostingView(rootView: SettingsCategorySidebar(selection: Binding(
            get: { categories[selection.value] },
            set: { selection.value = categories.firstIndex(of: $0)! }
        )).environment(MacAppearanceStore()).background(Color.white).preferredColorScheme(.light))
        let window = attach(host, size: NSSize(width: 200, height: 410))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        try snapshot(host, name: "settings-sidebar-hit-regions")
        for x in [CGFloat(12), CGFloat(188)] {
            for index in Array(categories.indices.dropFirst()) + [0] {
                try click(window, at: NSPoint(x: x, y: 410 - (64 + 42 * CGFloat(index))))
                try await settle(host)
                XCTAssertEqual(selection.value, index, "整行单击应切换到\(categories[index].rawValue)")
            }
        }
    }

    private func click(_ window: NSWindow, at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    func test受限账号菜单功能设置与多NAS列表双语主题绘制() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        let previousMode = MacAppearanceStore.shared.mode
        defer {
            AppLanguageStore.shared.selection = previousLanguage
            MacAppearanceStore.shared.mode = previousMode
        }
        for language in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = language
            for mode in [MacAppearanceMode.fog, .ink] {
                MacAppearanceStore.shared.mode = mode
                let fixture = try WorkspaceViewFixture(count: 3, moduleAccessLoader: {
                    WorkspaceModuleAccessSnapshot(modules: [.files: .available, .photos: .available])
                })
                defer { fixture.cleanPreferences() }
                fixture.model.shares = fixture.model.items
                await fixture.model.refreshModuleAccess()
                let second = try NasProfile(displayName: "Synthetic NAS", host: "second.example.invalid", port: 5001)
                var selectedProfileID: UUID?
                let host = makeWorkspaceHost(fixture: fixture, profiles: [fixture.model.profile, second], onSelectNAS: { selectedProfileID = $0 })
                let window = attach(host, size: NSSize(width: 1100, height: 740))
                window.makeKeyAndOrderFront(nil)
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                try click(window, at: NSPoint(x: 600, y: 350))
                try await settle(host)
                let suffix = "\(language.rawValue)-\(mode.rawValue)"
                try snapshot(host, name: "restricted-files-focus-\(suffix)")
                XCTAssertFalse(fixture.model.isDownloadStationModuleEnabled)
                XCTAssertFalse(fixture.model.isContainerManagerModuleEnabled)
                XCTAssertFalse(fixture.model.isVirtualMachineManagerModuleEnabled)
                fixture.model.section = .settings
                try await settle(host)
                try click(window, at: NSPoint(x: 420, y: 445))
                try await settle(host)
                try snapshot(host, name: "restricted-settings-\(suffix)")
                let existingWindows = Set(NSApp.windows.map(\.windowNumber))
                try click(window, at: NSPoint(x: 120, y: 655))
                try await settle(host)
                let popover = try XCTUnwrap(NSApp.windows.first { !existingWindows.contains($0.windowNumber) && $0.isVisible })
                try snapshot(try XCTUnwrap(popover.contentView), name: "nas-selector-\(suffix)")
                try click(popover, at: NSPoint(x: 160, y: 110))
                try await settle(host)
                XCTAssertEqual(selectedProfileID, second.id)
                let writes = await fixture.repository.writeCalls
                XCTAssertEqual(writes, 0)
            }
        }
    }

    func test无应用权限时保留本机设置并隐藏应用入口() async throws {
        let previousMode = MacAppearanceStore.shared.mode
        defer { MacAppearanceStore.shared.mode = previousMode }
        for mode in [MacAppearanceMode.fog, .ink] {
            MacAppearanceStore.shared.mode = mode
            let fixture = try WorkspaceViewFixture(count: 0, moduleAccessLoader: { WorkspaceModuleAccessSnapshot(modules: [:]) })
            defer { fixture.cleanPreferences() }
            await fixture.model.refreshModuleAccess()
            let host = makeWorkspaceHost(fixture: fixture)
            let window = attach(host, size: NSSize(width: 1100, height: 740))
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            XCTAssertEqual(fixture.model.section, .settings)
            for module in WorkspaceModule.allCases { XCTAssertFalse(fixture.model.isModuleVisible(module)) }
            try click(window, at: NSPoint(x: 420, y: 445))
            try await settle(host)
            try snapshot(host, name: "restricted-no-modules-\(mode.rawValue)")
            let reads = await fixture.repository.readCalls
            let writes = await fixture.repository.writeCalls
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(writes, 0)
        }
    }

    private func makeWorkspaceHost(fixture: WorkspaceViewFixture, updates: AppUpdateController? = nil, profiles: [NasProfile]? = nil, onSelectNAS: @escaping (UUID) -> Void = { _ in }) -> NSHostingView<some View> {
        NSHostingView(rootView: WorkspaceView(
            model: fixture.model,
            profiles: profiles ?? [fixture.model.profile],
            selectedProfileID: fixture.model.profile.id,
            connectedWorkspaces: [fixture.model],
            connectionRoute: .local,
            onAddNAS: {}, onSelectNAS: onSelectNAS, onMoveProfiles: { _, _ in },
            hasFileClipboard: false, onCopy: { _ in }, onCut: { _ in }, onPaste: {},
            onRenameNAS: { _ in nil }, onLogout: {}, onSessionExpired: { _ in }
        )
        .macAppearanceRoot()
        .environmentObject(updates ?? AppUpdateController(bundle: Bundle(for: Self.self), canRestart: { false }))
        .environment(AppLanguageStore.shared)
        .environment(\.locale, AppLanguageStore.shared.locale))
    }

    private func makeHost(fixture: WorkspaceViewFixture, mode: FileViewMode, scheme: ColorScheme, showsInspector: Binding<Bool> = .constant(false), onShare: @escaping ([FileItem]) -> Void = { _ in }, onCopy: @escaping ([FileItem]) -> Void = { _ in }, largeText: Bool = false) -> NSHostingView<some View> {
        NSHostingView(rootView: FileBrowserView(
            model: fixture.model,
            viewMode: .constant(mode),
            fileGrouping: .constant(.none),
            showingInfoItem: .constant(nil),
            onDownload: { _, _ in },
            onDownloadBatch: { _ in },
            onShare: onShare,
            onDelete: { _ in },
            onRestore: { _ in },
            onCopy: onCopy,
            onCut: { _ in },
            hasFileClipboard: false,
            onPaste: {},
            showsInspector: showsInspector
        )
        .environment(AppLanguageStore.shared)
        .environment(MacAppearanceStore.shared)
        .environment(\.locale, AppLanguageStore.shared.locale)
        .dynamicTypeSize(largeText ? .accessibility5 : .large)
        .preferredColorScheme(scheme))
    }

    private func attach<Content: View>(_ host: NSHostingView<Content>, size: NSSize, styleMask: NSWindow.StyleMask = [.titled, .closable]) -> NSWindow {
        // 用明确的窗口尺寸检查布局，不让测试宿主按组件理想尺寸自行扩大窗口。
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func snapshot(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)
        try data.write(to: artifacts.appendingPathComponent(name + ".png"))
    }
}

@MainActor
@Observable
private final class PageTabSelectionProbe {
    var value = 0
}

private struct PresentationLayoutMarker: NSViewRepresentable {
    let onCreate: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onCreate(view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 只为窗口材质检查提供无用户内容的桌面底图，不修改系统壁纸。
private struct SyntheticDesktopBackdrop: View {
    let isDark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: isDark
                ? [Color(red: 0.03, green: 0.12, blue: 0.21), Color(red: 0.10, green: 0.20, blue: 0.32), Color(red: 0.15, green: 0.10, blue: 0.27)]
                : [Color(red: 0.69, green: 0.79, blue: 0.96), Color(red: 0.88, green: 0.90, blue: 0.99), Color(red: 0.64, green: 0.68, blue: 0.91)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(Color.white.opacity(isDark ? 0.08 : 0.3))
                .frame(width: 940, height: 180)
                .rotationEffect(.degrees(-30))
                .offset(x: -190, y: 210)
            // 细文字用于检查背景是否真正模糊，全部为合成内容，不采集用户桌面。
            VStack(spacing: 12) {
                ForEach(0..<30, id: \.self) { _ in
                    Text(String(repeating: "SYNTHETIC BACKDROP 0123456789   ", count: 5))
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isDark ? .white : .black)
            .opacity(0.7)
        }
        .ignoresSafeArea()
    }
}

@MainActor
private struct WorkspaceViewFixture {
    let model: WorkspaceModel
    let repository: PresentationFileRepository

    init(count: Int, displayName: String = "Synthetic NAS", chatRepository: any ChatRepository = UnverifiedDsmChatRepository(), nasSettingsRepository: any NasSettingsRepository = UnavailableNasAdministrationRepository(), serviceManagementRepository: any ServiceManagementRepository = UnavailableServiceManagementRepository(), moduleAccessLoader: (@Sendable () async -> WorkspaceModuleAccessSnapshot)? = nil) throws {
        let profile = try NasProfile(displayName: displayName, host: "example.invalid", port: 5001)
        repository = PresentationFileRepository(profileID: profile.id)
        model = WorkspaceModel(profile: profile, repository: repository, chatRepository: chatRepository, nasSettingsRepository: nasSettingsRepository, serviceManagementRepository: serviceManagementRepository, transferNotifier: NoopTransferNotifier(), preparePreviewCache: {}, moduleAccessLoader: moduleAccessLoader)
        // 综合界面样例显式开启所测模块；首次默认开关由 WorkspaceModuleAccessTests 单独验证。
        model.isChatModuleEnabled = true
        model.isDownloadStationModuleEnabled = true
        model.isContainerManagerModuleEnabled = true
        model.isVirtualMachineManagerModuleEnabled = true
        model.currentPath = "/synthetic"
        model.section = .files("/synthetic")
        model.items = (0..<count).map { index in
            FileItem(profileID: profile.id, name: String(format: "Folder-%05d", index), path: String(format: "/synthetic/folder-%05d", index), kind: .directory)
        }
        model.totalItemCount = count
    }

    func cleanPreferences() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix(model.profile.id.uuidString) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private enum PresentationRepositoryError: Error { case unexpectedOperation }

private actor PresentationAuthentication: AuthRepository, PasswordSecureStoring {
    private(set) var calls = 0
    func discover(profile: NasProfile) throws -> CapabilitySet { calls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func login(profile: NasProfile, capabilities: CapabilitySet, account: String, password: String, otpCode: String?) throws -> AuthSession { calls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func restoreSession(for profileID: UUID) -> AuthSession? { calls += 1; return nil }
    func clearSession(for profileID: UUID) { calls += 1 }
    func logout(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession) { calls += 1 }
    func save(_ password: String, for profileID: UUID) throws { calls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func load(for profileID: UUID) -> String? { calls += 1; return nil }
    func remove(for profileID: UUID) { calls += 1 }
}

@MainActor
final class WorkspaceConnectionRecoveryTests: XCTestCase {
    func test已有共享列表时重试仍重新读取当前目录并清除旧认证错误() async throws {
        let fixture = try WorkspaceViewFixture(count: 1)
        defer { fixture.cleanPreferences() }
        fixture.model.isFileModuleEnabled = true
        fixture.model.shares = fixture.model.items
        let error = AppError(category: .authenticationRequired, isRetryable: false, safeUserMessage: "合成认证失败", dsmCode: 119)
        await fixture.repository.failNextFolderRead(error)
        await fixture.model.navigate(to: "/synthetic/child")
        XCTAssertTrue(fixture.model.requiresReauthentication)
        XCTAssertNotNil(fixture.model.statusMessage)
        let reads = await fixture.repository.readCalls
        await fixture.model.retryAfterSessionIssue()
        let finalReads = await fixture.repository.readCalls
        XCTAssertEqual(finalReads, reads + 1, "不能因为已有共享目录缓存而跳过重试")
        XCTAssertFalse(fixture.model.requiresReauthentication)
        XCTAssertFalse(fixture.model.statusIsError)
        XCTAssertNil(fixture.model.statusMessage)
        let writes = await fixture.repository.writeCalls
        XCTAssertEqual(writes, 0)
    }
}

private actor PresentationFileRepository: FileRepository {
    let profileID: UUID
    let allowsVerifiedRestore = false
    private(set) var writeCalls = 0
    private(set) var readCalls = 0
    private var nextFolderError: AppError?
    init(profileID: UUID) { self.profileID = profileID }
    func listShares(offset: Int, limit: Int) -> FilePage { readCalls += 1; return page(path: "/", offset: offset) }
    func failNextFolderRead(_ error: AppError) { nextFolderError = error }
    func listFolder(path: String, offset: Int, limit: Int) throws -> FilePage {
        readCalls += 1
        if let error = nextFolderError { nextFolderError = nil; throw error }
        return page(path: path, offset: offset)
    }
    func getInfo(paths: [String]) -> [FileItem] { readCalls += 1; return [] }
    func getThumbnail(path: String, size: ThumbnailSize) throws -> Data { readCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func checkWritePermission(folderPath: String, filename: String, createOnly: Bool) throws { try rejectWrite() }
    func mediaStreamSource(remotePath: String, fileExtension: String?, expectedContentLength: Int64?) throws -> MediaStreamSource { throw PresentationRepositoryError.unexpectedOperation }
    func download(remotePath: String, to localURL: URL, expectedSize: Int64?, progress: @escaping FileTransferProgress) throws { try rejectWrite() }
    func downloadArchive(remotePaths: [String], to localURL: URL, progress: @escaping FileTransferProgress) throws { try rejectWrite() }
    func removePartialDownload(to localURL: URL) { writeCalls += 1 }
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) throws { try rejectWrite() }
    func delete(paths: [String], progress: @escaping FileTransferProgress) throws { try rejectWrite() }
    func deleteResult(paths: [String], progress: @escaping FileTransferProgress) throws -> MutationResult { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func createFolder(parentPath: String, name: String) throws { try rejectWrite() }
    func copy(paths: [String], to destinationFolder: String, overwrite: Bool, progress: @escaping FileTransferProgress) throws { try rejectWrite() }
    func move(paths: [String], to destinationFolder: String, overwrite: Bool, progress: @escaping FileTransferProgress) throws { try rejectWrite() }
    func search(folderPath: String, query: String) -> [FileItem] { [] }
    func listFavorites() -> [FavoriteLocation] { [] }
    func addFavorite(path: String, name: String) throws { try rejectWrite() }
    func addFavoriteResult(path: String, name: String) throws -> MutationResult { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func removeFavorite(path: String) throws { try rejectWrite() }
    func listShareLinks() -> [FileShareLink] { [] }
    func createShareLink(paths: [String], password: String?, expiresAt: String?) throws -> FileShareLink { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func deleteShareLinks(ids: [String]) throws { try rejectWrite() }
    private func rejectWrite() throws { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    private func page(path: String, offset: Int) -> FilePage { FilePage(folderPath: path, items: [], offset: offset, total: 0, hasMore: false) }
}
