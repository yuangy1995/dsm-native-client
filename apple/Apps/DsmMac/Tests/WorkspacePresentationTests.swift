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

    /// 通过公开辅助功能属性读取 SwiftUI 与 AppKit 节点，不依赖具体实现类。
    private struct UIElement {
        let object: NSObject
        func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func accessibilityRole() -> NSAccessibility.Role? {
            (value("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
        }
        func accessibilityLabel() -> String? { value("accessibilityLabel") as? String }
        func accessibilityTitle() -> String? { value("accessibilityTitle") as? String }
        func accessibilityFrame() -> CGRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }
    private func uiElements(_ item: NSObject, depth: Int = 0) -> [UIElement] {
        guard depth < 18 else { return [] }
        let children = (UIElement(object: item).value("accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        return children.map { UIElement(object: $0) } + children.flatMap { uiElements($0, depth: depth + 1) }
    }

    private func remoteFlowElements(_ view: NSView) -> [UIElement] {
        nativeViews(view, of: NSView.self).flatMap { uiElements($0) }
    }

    func test远程连接直接点击无确认弹窗且行内显示结果双语主题() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute); NSApp.setActivationPolicy(.accessory) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for status in [MutationResultStatus.confirmedSuccess, .confirmedFailure, .submittedButUnverified] {
                    let fixture = try WorkspaceViewFixture(count: 0)
                    await fixture.repository.configureAdvanced(state: "ready")
                    let profile = remoteFlowProfile(fixture.model.profile.id, protocolID: "davs", state: .disconnected)
                    await fixture.repository.configureVFS(profiles: [profile], status: status)
                    await fixture.repository.holdNextVFSChange()
                    let host = NSHostingView(rootView: RemoteLocationsView(model: fixture.model, onOpen: { _ in })
                        .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: .init(width: 1000, height: 650))
                    defer { window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    try await settle(host)
                    let connect = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.connect") })
                    let point = window.convertPoint(fromScreen: .init(x: connect.accessibilityFrame().midX, y: connect.accessibilityFrame().midY))
                    try click(window, at: point); try await settle(host)
                    XCTAssertNil(window.attachedSheet, "普通连接必须直接执行，不能再次确认")
                    XCTAssertEqual(fixture.model.fileVFSConnectionActivities[profile.id]?.isBusy, true)
                    try click(window, at: point); try await settle(host)
                    let during = await fixture.repository.writeCalls; XCTAssertEqual(during, 1)
                    if status == .confirmedSuccess { try snapshot(host, name: "file-direct-connect-busy-\(language.rawValue)-\(scheme)") }
                    await fixture.repository.releaseVFSChange()
                    for _ in 0..<25 where fixture.model.fileVFSConnectionActivities[profile.id]?.isBusy == true { try await settle(host) }
                    XCTAssertNil(window.attachedSheet)
                    try snapshot(host, name: "file-direct-connect-\(status.rawValue)-\(language.rawValue)-\(scheme)")
                    if status == .confirmedSuccess {
                        XCTAssertEqual(fixture.model.remoteVFSProfiles.first?.state, .connected)
                        XCTAssertNil(fixture.model.fileVFSConnectionActivities[profile.id])
                    } else if status == .confirmedFailure {
                        XCTAssertTrue(remoteFlowElements(host).contains { ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.connection-failed") })
                        XCTAssertTrue(remoteFlowElements(host).contains { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.connect") })
                    } else {
                        let review = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.checkConnection") })
                        XCTAssertFalse(remoteFlowElements(host).contains { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.connect") })
                        try click(window, at: window.convertPoint(fromScreen: .init(x: review.accessibilityFrame().midX, y: review.accessibilityFrame().midY)))
                        for _ in 0..<25 where fixture.model.fileVFSConnectionActivities[profile.id] != nil { try await settle(host) }
                        XCTAssertEqual(fixture.model.remoteVFSProfiles.first?.state, .connected)
                        XCTAssertNil(window.attachedSheet)
                        let reviews = await fixture.repository.vfsReviews; XCTAssertEqual(reviews, 1)
                    }
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 1)
                }
            }
        }
    }

    func test远程连接主页直接展示筛选与浏览双语主题() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute); NSApp.setActivationPolicy(.accessory) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 0)
                await fixture.repository.configureAdvanced(state: "ready")
                await fixture.repository.configureVFS(profiles: remoteFlowProfiles(fixture.model.profile.id))
                let host = NSHostingView(rootView: RemoteLocationsView(model: fixture.model, onOpen: { _ in })
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                let window = attach(host, size: .init(width: 1000, height: 650))
                defer { window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                let rows = remoteFlowElements(host).compactMap { $0.value("accessibilityIdentifier") as? String }
                for item in remoteFlowProfiles(fixture.model.profile.id) { XCTAssertTrue(rows.contains("remote-vfs.row." + item.id)) }
                XCTAssertFalse(rows.contains("remote-vfs.browse.synthetic-ftp"), "未连接时不显示浏览按钮")
                XCTAssertNil(window.attachedSheet)
                try snapshot(host, name: "file-remote-flow-overview-\(language.rawValue)-\(scheme)")
                let webdav = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("remote-locations.protocol.webdav") })
                try click(window, at: window.convertPoint(fromScreen: .init(x: webdav.accessibilityFrame().midX, y: webdav.accessibilityFrame().midY)))
                try await settle(host)
                XCTAssertFalse(remoteFlowElements(host).contains { $0.value("accessibilityIdentifier") as? String == "remote-vfs.row.synthetic-sftp" })
                let row = try XCTUnwrap(remoteFlowElements(host).first { $0.value("accessibilityIdentifier") as? String == "remote-vfs.row.synthetic-davs" })
                let browse = try XCTUnwrap(remoteFlowElements(host).first { $0.value("accessibilityIdentifier") as? String == "remote-vfs.browse.synthetic-davs" })
                XCTAssertGreaterThan(browse.accessibilityFrame().midX, row.accessibilityFrame().midX)
                XCTAssertGreaterThanOrEqual(browse.accessibilityFrame().height, 36)
                try click(window, at: window.convertPoint(fromScreen: .init(x: browse.accessibilityFrame().midX, y: browse.accessibilityFrame().midY)))
                try await settle(host)
                XCTAssertNil(window.attachedSheet, "应在主页内容区浏览，不再打开管理弹窗")
                let back = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("remote-locations.back") })
                XCTAssertTrue(remoteFlowElements(host).contains { ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel() ?? $0.accessibilityTitle())?.contains("Readme.txt") == true })
                try snapshot(host, name: "file-remote-flow-browse-\(language.rawValue)-\(scheme)")
                try click(window, at: window.convertPoint(fromScreen: .init(x: back.accessibilityFrame().midX, y: back.accessibilityFrame().midY)))
                try await settle(host)
                XCTAssertTrue(remoteFlowElements(host).contains { $0.value("accessibilityIdentifier") as? String == "remote-vfs.row.synthetic-davs" })
                let search = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("remote-locations.search") })
                window.makeFirstResponder(search); try await settle(host)
                let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
                editor.insertText("No matching remote connection", replacementRange: editor.selectedRange())
                try await settle(host)
                XCTAssertFalse(remoteFlowElements(host).contains { $0.value("accessibilityIdentifier") as? String == "remote-vfs.row.synthetic-davs" })
                XCTAssertTrue(remoteFlowElements(host).contains { ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("remote-locations.filtered-empty.title") })
                try snapshot(host, name: "file-remote-flow-filtered-\(language.rawValue)-\(scheme)")
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
            }
        }
    }

    func test远程连接主页加载空内容错误双语主题() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["loading", "empty", "error"] {
                    let fixture = try WorkspaceViewFixture(count: 0)
                    await fixture.repository.configureAdvanced(state: state)
                    let host = NSHostingView(rootView: RemoteLocationsView(model: fixture.model, onOpen: { _ in })
                        .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: .init(width: 1000, height: 650))
                    try await settle(host)
                    if state == "loading" { XCTAssertTrue(fixture.model.isLoadingRemoteLocations) }
                    else { XCTAssertTrue(fixture.model.remoteLocationsHasLoaded); XCTAssertTrue(fixture.model.remoteVFSProfiles.isEmpty) }
                    if state == "error" { XCTAssertNotNil(fixture.model.remoteVFSProfilesError) }
                    try snapshot(host, name: "file-remote-flow-\(state)-\(language.rawValue)-\(scheme)")
                    await fixture.repository.releaseAdvancedReads(); try await settle(host)
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                    window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences()
                }
            }
        }
    }

    func test远程连接成功自动关闭表单失败保留且只读确认后关闭() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute); NSApp.setActivationPolicy(.accessory) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let cases: [(MutationResultStatus, Bool)] = [(.confirmedSuccess, false), (.confirmedFailure, false), (.submittedButUnverified, false), (.confirmedSuccess, true)]
                for (status, editing) in cases {
                    let fixture = try WorkspaceViewFixture(count: 0)
                    await fixture.repository.configureAdvanced(state: "ready")
                    let existing = remoteFlowProfile(fixture.model.profile.id, protocolID: "davs")
                    await fixture.repository.configureVFS(profiles: editing ? [existing] : [], status: status)
                    await fixture.repository.holdNextVFSChange()
                    let presentation = PageTabSelectionProbe()
                    let host = NSHostingView(rootView: Color.clear.frame(width: 1000, height: 720)
                        .macSheet(isPresented: Binding(get: { presentation.value == 1 }, set: { presentation.value = $0 ? 1 : 0 })) {
                            FileVFSEditor(model: fixture.model, profile: editing ? existing : nil)
                        }.environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: .init(width: 1000, height: 720))
                    defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    presentation.value = 1; try await settle(host)
                    for _ in 0..<25 {
                        if let content = window.attachedSheet?.contentView, !nativeViews(content, of: NSTextField.self).isEmpty { break }
                        try await settle(host)
                    }
                    let sheet = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                    // 分组表单的标签在输入框外，名称字段是第一个可编辑文本框。
                    let nameField = try XCTUnwrap(nativeViews(content, of: NSTextField.self).first { $0.isEditable })
                    let addressField = try XCTUnwrap(nativeViews(content, of: NSTextField.self).first { $0.placeholderString == L10n.string("files.vfs.addressExample") })
                    for (field, text) in [(nameField, "Sample WebDAV"), (addressField, "https://example.invalid/photos")] {
                        sheet.makeFirstResponder(field); field.selectText(nil); try await settle(host)
                        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                        editor.insertText(text, replacementRange: editor.selectedRange()); try await settle(host)
                        sheet.makeFirstResponder(nil); try await settle(host)
                    }
                    let save = try XCTUnwrap(remoteFlowElements(content).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.saveConnect") })
                    try click(sheet, at: sheet.convertPoint(fromScreen: .init(x: save.accessibilityFrame().midX, y: save.accessibilityFrame().midY)))
                    try await settle(host)
                    let progress = try XCTUnwrap(remoteFlowElements(content).first { $0.value("accessibilityIdentifier") as? String == "files.vfs.saveProgress" })
                    XCTAssertGreaterThan(progress.accessibilityFrame().width, 0)
                    XCTAssertTrue(remoteFlowElements(content).contains { ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.savingConnect") })
                    let busySave = try XCTUnwrap(remoteFlowElements(content).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.vfs.saveConnect") })
                    XCTAssertEqual(busySave.value("isAccessibilityEnabled") as? Bool, false)
                    let during = await fixture.repository.writeCalls; XCTAssertEqual(during, 1)
                    try snapshot(content, name: "file-save-feedback-\(editing ? "edit" : "new")-\(status.rawValue)-\(language.rawValue)-\(scheme)")
                    await fixture.repository.releaseVFSChange()
                    for _ in 0..<25 {
                        try await settle(host)
                        if window.attachedSheet == nil || !remoteFlowElements(content).contains(where: { $0.value("accessibilityIdentifier") as? String == "files.vfs.saveProgress" }) { break }
                    }
                    if status == .confirmedSuccess {
                        for _ in 0..<25 where presentation.value != 0 || window.attachedSheet != nil { try await settle(host) }
                        XCTAssertEqual(presentation.value, 0); XCTAssertNil(window.attachedSheet)
                        XCTAssertEqual(fixture.model.remoteVFSProfiles.map(\.alias), ["Sample WebDAV"])
                    } else {
                        XCTAssertEqual(presentation.value, 1); XCTAssertNotNil(window.attachedSheet)
                        try snapshot(content, name: "file-remote-flow-result-\(status.rawValue)-\(language.rawValue)-\(scheme)")
                        if status == .submittedButUnverified {
                            let review = try XCTUnwrap(remoteFlowElements(content).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.permissions.review") })
                            try click(sheet, at: sheet.convertPoint(fromScreen: .init(x: review.accessibilityFrame().midX, y: review.accessibilityFrame().midY)))
                            for _ in 0..<25 where presentation.value != 0 || window.attachedSheet != nil { try await settle(host) }
                            XCTAssertEqual(presentation.value, 0); XCTAssertNil(window.attachedSheet)
                            let reviews = await fixture.repository.vfsReviews; XCTAssertEqual(reviews, 1)
                        }
                    }
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 1, "自动结束或查看结果不能重复连接")
                }
            }
        }
    }

    func test界面修正路径整块可点击并合并底栏双语主题() async throws {
        NSApp.setActivationPolicy(.regular)
        let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(accessibilityAttribute)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityAttribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: accessibilityAttribute); NSApp.setActivationPolicy(.accessory) }
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 3)
                fixture.model.currentPath = "/synthetic/Archive/Reports"
                let host = makeHost(fixture: fixture, mode: .grid, scheme: scheme, largeText: true)
                let window = attach(host, size: .init(width: 640, height: 560))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                let elements = uiElements(host)
                let parent = try XCTUnwrap(elements.first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == "Archive" })
                let rect = parent.accessibilityFrame()
                XCTAssertGreaterThanOrEqual(rect.height, 32)
                XCTAssertGreaterThanOrEqual(rect.width, 32)
                let point = window.convertPoint(fromScreen: NSPoint(x: rect.minX + 3, y: rect.midY))
                XCTAssertLessThan(point.y, 50, "路径应位于现有底栏")
                window.makeKeyAndOrderFront(nil)
                try snapshot(host, name: "file-ui-fixes-file-path-\(language.rawValue)-\(scheme)")
                try click(window, at: point)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                XCTAssertEqual(fixture.model.currentPath, "/synthetic/Archive", "点击文字外侧仍应导航")
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences()
            }
        }
    }

    func test界面修正照片单来源无重复标签且路径与操作共用一行() async throws {
        NSApp.setActivationPolicy(.regular)
        let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(accessibilityAttribute)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityAttribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: accessibilityAttribute); NSApp.setActivationPolicy(.accessory) }
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let model = SynologyPhotosModel(repository: SynologyPhotosPresentationFixture(image: Data()))
                await model.refresh(); await model.selectSection(.folders)
                let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                    .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                let window = attach(host, size: .init(width: 1100, height: 720))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                let labels = uiElements(host).compactMap { ($0.accessibilityLabel() ?? $0.accessibilityTitle()) }
                XCTAssertFalse(labels.contains(L10n.string("photos.source.switch")))
                XCTAssertFalse(labels.contains(L10n.string("shared.51fcaa8035fc61e2")))
                let root = try XCTUnwrap(uiElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("photos.folders.root") })
                let selection = try XCTUnwrap(uiElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("photos.selection.start") })
                XCTAssertEqual(root.accessibilityFrame().midY, selection.accessibilityFrame().midY, accuracy: 2)
                XCTAssertGreaterThanOrEqual(root.accessibilityFrame().height, 32)
                try snapshot(host, name: "file-ui-fixes-photos-folders-\(language.rawValue)-\(scheme)")
                window.contentView = nil; window.close()
            }
        }
    }

    func test界面修正普通连接无重复确认且工具按钮保持统一尺寸() async throws {
        NSApp.setActivationPolicy(.regular)
        let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(accessibilityAttribute)
        NSApp.accessibilitySetValue(true, forAttribute: accessibilityAttribute)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: accessibilityAttribute); NSApp.setActivationPolicy(.accessory) }
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 3)
                await fixture.repository.configureAdvanced(state: "ready")
                let forms: [(String, AnyView, NSSize)] = [
                    ("vfs", AnyView(FileVFSEditor(model: fixture.model, profile: nil)), .init(width: 650, height: 620)),
                    ("remote", AnyView(RemoteMountEditorView(existingItem: nil, initialMountPoint: "/synthetic", onSave: { _ in XCTFail("不能自动连接"); return nil })), .init(width: 600, height: 620))]
                for (name, view, size) in forms {
                    let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: size)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    try await settle(host)
                    let labels = uiElements(host).compactMap { ($0.accessibilityLabel() ?? $0.accessibilityTitle()) }
                    XCTAssertFalse(labels.contains(L10n.string("remote-mount.confirm")))
                    XCTAssertFalse(labels.contains(L10n.string("files.vfs.confirmSave")))
                    if name == "vfs" {
                        let address = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("files.vfs.addressExample") })
                        window.makeFirstResponder(address); address.selectText(nil)
                        try await settle(host)
                        let editor = try XCTUnwrap(address.currentEditor() as? NSTextView)
                        editor.insertText("https://example.invalid:5006/webdav/photos", replacementRange: editor.selectedRange())
                        try await settle(host)
                        window.makeFirstResponder(nil)
                        try await settle(host)
                        let folder = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("files.vfs.folderExample") })
                        XCTAssertEqual(address.stringValue, "example.invalid")
                        XCTAssertEqual(folder.stringValue, "webdav/photos")
                        XCTAssertTrue(nativeViews(host, of: NSTextField.self).contains { $0.stringValue == "5006" })
                        XCTAssertFalse(uiElements(host).compactMap { $0.accessibilityLabel() ?? $0.accessibilityTitle() }.contains(L10n.string("files.vfs.confirmCleartext")))
                    }
                    try snapshot(host, name: "file-ui-fixes-form-\(name)-\(language.rawValue)-\(scheme)")
                    window.contentView = nil; window.close()
                }
                let host = makeWorkspaceHost(fixture: fixture)
                let window = attach(host, size: .init(width: 1200, height: 740))
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                for key in ["files.pending.title", "files.office.sessions"] {
                    let button = try XCTUnwrap(uiElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string(key) })
                    let rect = button.accessibilityFrame()
                    XCTAssertGreaterThanOrEqual(rect.height, 36)
                    XCTAssertLessThanOrEqual(rect.width, 48, "应与相邻图标按钮保持一致")
                }
                try snapshot(host, name: "file-ui-fixes-toolbar-\(language.rawValue)-\(scheme)")
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences()
            }
        }
    }

    func testOffice自动保存准备正常暂停冲突与未知结果双语主题() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let repository = OfficeEditingTestRepository()
                let item = await repository.currentItem()
                let coordinator = OfficeEditingCoordinator()
                let url = root.appendingPathComponent(UUID().uuidString + ".docx")
                await repository.holdDownload()
                let preparing = Task { try await coordinator.begin(item: item, localURL: url, repository: repository, monitor: false) }
                for _ in 0..<100 {
                    if await repository.isDownloadHeld { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let host = NSHostingView(rootView: OfficeEditingSessionsView(profileID: item.profileID, coordinator: coordinator)
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                    .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 780, height: 490))
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                func capture(_ state: String) async throws {
                    try await settle(host)
                    try snapshot(host, name: "file-office-sessions-\(state)-\(language.rawValue)-\(scheme)")
                }
                try await capture("preparing")
                await repository.releaseDownload()
                let session = try await preparing.value
                defer { session.stop() }
                try await capture("watching")
                try Data("edited".utf8).write(to: url)
                await repository.setWritable(false)
                await session.poll(); await session.poll(now: Date().addingTimeInterval(3))
                XCTAssertEqual(session.phase, .paused)
                try await capture("paused")
                await repository.setWritable(true)
                await repository.setBehavior(.timeoutBeforeWrite)
                await session.retry(); await session.poll(now: Date().addingTimeInterval(3))
                XCTAssertEqual(session.phase, .needsReview)
                try await capture("review")
                await repository.replaceRemote(Data("edited".utf8))
                await session.review()
                XCTAssertEqual(session.phase, .saved)
                try await capture("saved")
                await repository.replaceRemote(Data("remote-changed".utf8))
                try Data("local-changed".utf8).write(to: url)
                await session.poll(); await session.poll(now: Date().addingTimeInterval(3))
                XCTAssertEqual(session.phase, .conflict)
                try await capture("conflict")
                window.contentView = nil; window.close()
            }
        }
    }

    func testOffice文档原生预览三格式双语主题与自动保存空状态() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for ext in ["docx", "xlsx", "pptx"] {
                    let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: ext, subdirectory: "Office"))
                    let host = NSHostingView(rootView: OfficeDocumentPreview(url: url)
                        .environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 900, height: 650))
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    try await settle(host)
                    // 系统 Quick Look 异步载入文件，额外等待本机渲染，不启动外部应用。
                    try await Task.sleep(for: .seconds(2))
                    try snapshot(host, name: "file-office-\(ext)-\(language.rawValue)-\(scheme)")
                    window.contentView = nil; window.close()
                }
                let host = NSHostingView(rootView: OfficeEditingSessionsView(profileID: UUID())
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                    .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 780, height: 490))
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                try await settle(host)
                try snapshot(host, name: "file-office-sessions-empty-\(language.rawValue)-\(scheme)")
                window.contentView = nil; window.close()
            }
        }
    }

    func test文件远程浏览图片选择与云盘表单四态双语主题() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "empty", "error", "loading"] {
                    let fixture = try WorkspaceViewFixture(count: state == "empty" ? 0 : 1)
                    await fixture.repository.configureAdvanced(state: state)
                    let profile = FileVFSProfile(profileID: fixture.model.profile.id, id: "synthetic-vfs", protocolID: "sftp", protocolName: "SFTP",
                        uri: "sftp://synthetic", hostname: "example.invalid", port: 22, alias: "远程位置 Remote", account: "synthetic", codepage: "UTF-8", state: .connected)
                    let views: [(String, AnyView, NSSize)] = [
                        ("vfs-browser", AnyView(FileVFSBrowserView(model: fixture.model, profile: profile)), .init(width: 700, height: 540)),
                        ("theme-images", AnyView(FileStationThemeImagePicker(model: fixture.model, kind: .background, onSelect: { _ in XCTFail("不能自动选择") })), .init(width: 760, height: 570)),
                        ("cloud-form", AnyView(FileVFSCloudConnectionView(model: fixture.model, protocolID: "google", protocolName: "Google Drive", existing: nil)), .init(width: 560, height: 390))]
                    for (name, view, size) in views {
                        let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                            .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                        let window = attach(host, size: size)
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        try await settle(host); window.makeKeyAndOrderFront(nil)
                        try snapshot(host, name: "file-complete-\(name)-\(state)-\(language.rawValue)-\(scheme)")
                        await fixture.repository.releaseAdvancedReads(); try await settle(host)
                        window.contentView = nil; window.close()
                        await fixture.repository.configureAdvanced(state: state)
                    }
                    await fixture.repository.releaseAdvancedReads()
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                    fixture.model.cancelAllWork(); fixture.cleanPreferences()
                }
            }
        }
    }

    func test账号选择隐藏单一来源并靠左保留多来源与用户群组切换() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute); NSApp.setActivationPolicy(.accessory) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for multiple in [false, true] {
                    for state in ["ready", "empty", "error", "loading", "filtered"] {
                        let fixture = try WorkspaceViewFixture(count: 0)
                        await fixture.repository.configureAdvanced(state: state == "filtered" ? "ready" : state)
                        await fixture.repository.configureMountDirectories(multiple
                            ? [.init(source: .local, name: ""), .init(source: .ldap, name: "")]
                            : [.init(source: .local, name: "")])
                        let host = NSHostingView(rootView: FileStationMountAccountList(model: fixture.model)
                            .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                            .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                        let window = attach(host, size: .init(width: 620, height: 500))
                        defer { window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                        try await settle(host)
                        if state == "filtered" {
                            let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("files.principals.search") })
                            XCTAssertTrue(window.makeFirstResponder(field))
                            let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                            editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0))
                            try await settle(host)
                        }
                        let elements = remoteFlowElements(host)
                        let hasSource = elements.contains { $0.value("accessibilityIdentifier") as? String == "files.settings.accountSource" }
                        XCTAssertEqual(hasSource, multiple && state != "loading" && state != "error")
                        let control = try XCTUnwrap(nativeViews(host, of: NSSegmentedControl.self).first { $0.segmentCount == 2 })
                        let controlFrame = control.convert(control.bounds, to: host)
                        XCTAssertEqual(controlFrame.minX, 24, accuracy: 8, "用户/群组按钮组应与内容左边缘对齐")
                        if state == "ready" {
                            control.selectedSegment = 1; control.sendAction(control.action, to: control.target)
                            try await settle(host)
                            let kinds = await fixture.repository.mountAccountKinds
                            XCTAssertEqual(kinds.last, .group)
                            let buttons = remoteFlowElements(host).filter { $0.accessibilityRole() == .button }
                            XCTAssertTrue(buttons.contains { ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.settings.editAccountPermissions") })
                            XCTAssertFalse(buttons.contains { ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.sharing.edit") })
                        }
                        try snapshot(host, name: "file-account-controls-\(multiple ? "multiple" : "single")-\(state)-\(language.rawValue)-\(scheme)")
                        await fixture.repository.releaseAdvancedReads(); try await settle(host)
                        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                    }
                }
            }
        }
    }

    func test未配置限速正确显示群组继承且打开编辑器不产生保存() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute); NSApp.setActivationPolicy(.accessory) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 0)
                await fixture.repository.configureAdvanced(state: "ready", access: .init(isAdministrator: true, writesEnabled: true))
                await fixture.repository.configureBandwidth(policy: .notConfigured)
                defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                let list = NSHostingView(rootView: FileStationBandwidthView(model: fixture.model)
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                let listWindow = attach(list, size: .init(width: 760, height: 550))
                listWindow.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                listWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await settle(list)
                let labels = remoteFlowElements(list).flatMap { [$0.accessibilityLabel(), $0.accessibilityTitle(), $0.value("accessibilityValue") as? String].compactMap { $0 } }
                XCTAssertTrue(labels.contains(L10n.string("files.settings.groupBandwidth")))
                XCTAssertFalse(labels.contains(L10n.string("files.settings.unlimited")))
                try snapshot(list, name: "file-bandwidth-unconfigured-list-\(language.rawValue)-\(scheme)")
                listWindow.contentView = nil; listWindow.close()
                for owner in [FileStationBandwidthEntry.OwnerType.localUser, .localGroup] {
                    let page = try await fixture.repository.listFileStationBandwidth(ownerType: owner, offset: 0, limit: 100)
                    let baseline = try XCTUnwrap(page.items.first)
                    let host = NSHostingView(rootView: FileStationBandwidthEditor(model: fixture.model, baseline: baseline)
                        .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                        .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                    let window = attach(host, size: .init(width: 760, height: 680))
                    defer { window.contentView = nil; window.close() }
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.makeKeyAndOrderFront(nil); try await settle(host)
                    let elements = remoteFlowElements(host)
                    let texts = elements.flatMap { [$0.accessibilityLabel(), $0.accessibilityTitle(), $0.value("accessibilityValue") as? String].compactMap { $0 } }
                    XCTAssertTrue(texts.contains(L10n.string(owner == .localUser ? "files.settings.groupBandwidth" : "files.settings.noBandwidthConfiguration")))
                    XCTAssertFalse(texts.contains(L10n.string("files.settings.rateUnits")))
                    let save = try XCTUnwrap(elements.first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.settings.save") })
                    XCTAssertEqual(save.value("isAccessibilityEnabled") as? Bool ?? save.value("accessibilityEnabled") as? Bool, false)
                    try snapshot(host, name: "file-bandwidth-unconfigured-\(owner.rawValue)-\(language.rawValue)-\(scheme)")
                }
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
            }
        }
    }

    func test权限读取加载错误空内容和共享根只读双语主题() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute); NSApp.setActivationPolicy(.accessory) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "readonly", "empty", "error", "loading"] {
                    let fixture = try WorkspaceViewFixture(count: 0)
                    let readOnly = state == "readonly"
                    await fixture.repository.configureAdvanced(state: readOnly ? "ready" : state,
                        access: .init(isAdministrator: true, writesEnabled: true), permissionEditable: !readOnly)
                    let item = FileItem(profileID: fixture.model.profile.id, name: "Synthetic folder",
                        path: readOnly ? "/synthetic" : "/synthetic/folder", kind: .directory,
                        mountPointType: readOnly ? "shared_folder" : "normal")
                    let host = NSHostingView(rootView: FilePermissionEditor(model: fixture.model, item: item)
                        .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                        .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                    let window = attach(host, size: .init(width: 720, height: 680))
                    defer { window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    try await settle(host)
                    let elements = remoteFlowElements(host)
                    let labels = elements.compactMap { $0.value("accessibilityValue") as? String ?? $0.accessibilityLabel() ?? $0.accessibilityTitle() }
                    if readOnly {
                        XCTAssertTrue(labels.contains(L10n.string("files.permissions.readOnly")))
                        XCTAssertTrue(labels.contains(L10n.string("files.permissions.owner", "示例账号 Synthetic user")))
                        let recursive = try XCTUnwrap(elements.first { $0.accessibilityRole() == .checkBox && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.permissions.recursive") })
                        XCTAssertEqual(recursive.value("isAccessibilityEnabled") as? Bool ?? recursive.value("accessibilityEnabled") as? Bool, false)
                        let disclosure = try XCTUnwrap(elements.first { $0.accessibilityRole() == .disclosureTriangle })
                        XCTAssertEqual(disclosure.value("isAccessibilityEnabled") as? Bool ?? disclosure.value("accessibilityEnabled") as? Bool, true, "只读规则必须允许展开")
                        XCTAssertEqual(disclosure.value("accessibilityPerformPress") as? Bool, true, "只读规则必须响应辅助功能展开操作")
                        try await settle(host)
                        try snapshot(host, name: "file-permissions-expanded-\(language.rawValue)-\(scheme)")
                        let right = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .checkBox && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("files.permissions.right.read") })
                        XCTAssertEqual(right.value("isAccessibilityEnabled") as? Bool ?? right.value("accessibilityEnabled") as? Bool, false)
                    } else if state == "error" {
                        XCTAssertTrue(labels.contains(L10n.string("files.permissions.loadFailed")))
                        XCTAssertTrue(labels.contains(L10n.string("files.advanced.readFailed")))
                    } else if state == "empty" {
                        XCTAssertTrue(labels.contains(L10n.string("files.permissions.noExplicit")))
                    }
                    let save = try XCTUnwrap(elements.first { $0.value("accessibilityIdentifier") as? String == "filePermissions.save" })
                    XCTAssertEqual(save.value("isAccessibilityEnabled") as? Bool ?? save.value("accessibilityEnabled") as? Bool, false)
                    try click(window, at: window.convertPoint(fromScreen: .init(x: save.accessibilityFrame().midX, y: save.accessibilityFrame().midY)))
                    try await settle(host)
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                    try snapshot(host, name: "file-permissions-read-\(state)-\(language.rawValue)-\(scheme)")
                    await fixture.repository.releaseAdvancedReads(); try await settle(host)
                }
            }
        }
    }

    func test文件高级管理四态双语主题且权限受限账号不提交() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "empty", "error", "loading"] {
                    let fixture = try WorkspaceViewFixture(count: 1)
                    await fixture.repository.configureAdvanced(state: state)
                    let views: [(String, AnyView, NSSize)] = [
                        ("permissions", AnyView(FilePermissionEditor(model: fixture.model, item: fixture.model.items[0])), .init(width: 720, height: 680)),
                        ("iso", AnyView(FileISOMountManagerView(model: fixture.model, onClose: {})), .init(width: 640, height: 460)),
                        ("vfs", AnyView(RemoteLocationsView(model: fixture.model, onOpen: { _ in })), .init(width: 740, height: 560)),
                        ("settings", AnyView(FileStationSettingsView(model: fixture.model)), .init(width: 800, height: 700)),
                        ("mount-accounts", AnyView(FileStationMountAccountList(model: fixture.model)), .init(width: 620, height: 500)),
                        ("bandwidth", AnyView(FileStationBandwidthView(model: fixture.model)), .init(width: 760, height: 550))
                    ]
                    for (name, view, size) in views {
                        let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                            .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                        let window = attach(host, size: size)
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        try await settle(host); window.makeKeyAndOrderFront(nil)
                        try snapshot(host, name: "file-advanced-\(name)-\(state)-\(language.rawValue)-\(scheme)")
                        if name == "permissions", state == "ready" || state == "empty" {
                            // 固定 720×680 合成窗口右下角的保存按钮；已用原生截图核对两种语言的位置。
                            let before = await fixture.repository.writeCalls
                            try click(window, at: NSPoint(x: 654, y: 36)); try await settle(host)
                            let after = await fixture.repository.writeCalls
                            XCTAssertEqual(after, before, "权限受限账号点击后不得提交权限写入")
                        }
                        // 只释放合成读取，关闭窗口不会进行网络写入。
                        await fixture.repository.releaseAdvancedReads(); try await settle(host)
                        window.contentView = nil; window.close()
                        await fixture.repository.configureAdvanced(state: state)
                    }
                    await fixture.repository.releaseAdvancedReads()
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                    fixture.model.cancelAllWork(); fixture.cleanPreferences()
                }
            }
        }
    }

    func test文件高级管理筛选空状态可用键盘到达() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            let fixture = try WorkspaceViewFixture(count: 0)
            await fixture.repository.configureAdvanced(state: "ready")
            let views: [(String, AnyView, String)] = [
                ("vfs", AnyView(RemoteLocationsView(model: fixture.model, onOpen: { _ in })), "remote-locations.search"),
                ("accounts", AnyView(FileStationMountAccountList(model: fixture.model)), "files.principals.search"),
                ("bandwidth", AnyView(FileStationBandwidthView(model: fixture.model)), "files.principals.search")
            ]
            for (name, view, key) in views {
                let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).environment(\.locale, L10n.locale))
                let window = attach(host, size: .init(width: 760, height: 560))
                try await settle(host); window.makeKeyAndOrderFront(nil)
                let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string(key) })
                XCTAssertTrue(window.makeFirstResponder(field))
                let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await settle(host)
                try snapshot(host, name: "file-advanced-\(name)-filtered-\(language.rawValue)")
                window.contentView = nil; window.close()
            }
            let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
            fixture.model.cancelAllWork(); fixture.cleanPreferences()
        }
    }

    func test文件高级设置各标签与核查入口不自动提交() async throws {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 1)
                await fixture.repository.configureAdvanced(state: "ready")
                let host = NSHostingView(rootView: FileStationSettingsView(model: fixture.model)
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                let window = attach(host, size: .init(width: 800, height: 700))
                try await settle(host); window.makeKeyAndOrderFront(nil)
                try snapshot(host, name: "file-settings-initial-layout-\(language.rawValue)")
                NSApp.activate(ignoringOtherApps: true)
                for index in 0..<4 {
                    let frame = try XCTUnwrap(window.contentView?.superview)
                    let tabs = try XCTUnwrap(nativeViews(frame, of: NSSegmentedControl.self).first { $0.segmentCount == 4 })
                    // 系统按本地化标题分配宽度；通过辅助功能位置发送真实鼠标事件，避免猜测等宽坐标。
                    func descendants(_ item: NSAccessibilityProtocol, depth: Int = 0) -> [NSAccessibilityProtocol] {
                        guard depth < 8 else { return [] }
                        let children = (item.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
                        return children + children.flatMap { descendants($0, depth: depth + 1) }
                    }
                    let all = descendants(tabs)
                    let segments = all.filter { $0.accessibilityRole() == .radioButton }
                    XCTAssertEqual(segments.count, 4)
                    let segment = try XCTUnwrap(segments.indices.contains(index) ? segments[index] : nil)
                    let rect = segment.accessibilityFrame()
                    XCTAssertGreaterThan(rect.width, 0)
                    let point = window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
                    try click(window, at: point)
                    try await settle(host)
                    let refreshed = try XCTUnwrap(nativeViews(frame, of: NSSegmentedControl.self).first { $0.segmentCount == 4 })
                    XCTAssertEqual(refreshed.selectedSegment, index)
                    try snapshot(host, name: "file-settings-tab-\(index)-\(language.rawValue)-\(scheme)")
                }
                window.contentView = nil; window.close()
                for state in ["ready", "empty"] {
                    await fixture.repository.configureAdvanced(state: state)
                    let pending = NSHostingView(rootView: FileStationPendingChangesView(model: fixture.model)
                        .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let pendingWindow = attach(pending, size: .init(width: 700, height: 460))
                    try await settle(pending); pendingWindow.makeKeyAndOrderFront(nil)
                    try snapshot(pending, name: "file-pending-\(state)-\(language.rawValue)-\(scheme)")
                    pendingWindow.contentView = nil; pendingWindow.close()
                }
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                fixture.model.cancelAllWork(); fixture.cleanPreferences()
            }
        }
    }

    func test文件归档浏览四态双语浅深色不提交() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "empty", "error", "loading"] {
                    let fixture = try WorkspaceViewFixture(count: 0)
                    let archive = FileItem(profileID: fixture.model.profile.id, name: "示例 Sample.zip", path: "/synthetic/Sample.zip", kind: .file, sizeBytes: 42)
                    let rows = state == "empty" ? [] : [ArchiveItem(id: 1, name: "资料 Folder", path: "资料 Folder", isDirectory: true),
                        ArchiveItem(id: 2, name: "零字节.txt", path: "零字节.txt", isDirectory: false, sizeBytes: 0)]
                    await fixture.repository.configureArchive(archive, entries: [-1: rows], fails: state == "error", held: state == "loading")
                    var submitted = false
                    let host = NSHostingView(rootView: ArchiveExtractionView(model: fixture.model, item: archive,
                        onExtract: { _, _ in submitted = true }, onCancel: {})
                        .environment(MacAppearanceStore()).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 720, height: 620))
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "file-archive-\(state)-\(language.rawValue)-\(scheme)")
                    await fixture.repository.releaseArchive(); try await settle(host)
                    XCTAssertFalse(submitted)
                    let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
                    window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences()
                }
            }
        }
    }

    func test文件分享管理五态双语浅深色与筛选键盘() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 0)
                let host = NSHostingView(rootView: ShareLinksView(model: fixture.model)
                    .environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                    .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 900, height: 580))
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                defer { window.contentView = nil; window.close(); fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                try await settle(host); window.makeKeyAndOrderFront(nil)
                for state in ["loading", "empty", "error", "normal", "filtered"] {
                    fixture.model.isLoadingShareLinks = state == "loading"
                    fixture.model.shareLinksError = state == "error" ? L10n.string("files.sharing.loadFailed") : nil
                    fixture.model.shareLinks = ["normal", "filtered"].contains(state)
                        ? [.init(id: "synthetic", name: "共享示例 Sample.txt", path: "/synthetic/Sample.txt",
                                 url: "https://example.invalid/sharing/synthetic", hasPassword: true,
                                 expiresAt: "2026-10-31", availableAt: "2026-10-01", availabilityDateKnown: true, status: .valid)] : []
                    try await settle(host)
                    if state == "filtered" {
                        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first {
                            $0.placeholderString == L10n.string("files.sharing.filter")
                        })
                        XCTAssertTrue(window.makeFirstResponder(field))
                        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                        editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0))
                        try await settle(host)
                    }
                    try snapshot(host, name: "file-sharing-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(host.bounds.size, NSSize(width: 900, height: 580))
                }
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
            }
        }
    }

    func test文件新表单双语浅深色大字与取消不提交() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try WorkspaceViewFixture(count: 1)
                defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
                var closed = false
                let link = FileShareLink(id: "synthetic", name: "Sample", path: "/synthetic/Sample",
                    url: "https://example.invalid/shared", availabilityDateKnown: true)
                let views: [(String, AnyView, NSSize)] = [
                    ("create", AnyView(ShareCreationView(model: fixture.model, targets: fixture.model.items, onClose: { closed = true })), NSSize(width: 520, height: 380)),
                    ("edit", AnyView(FileShareEditView(model: fixture.model, links: [link], onClose: { closed = true })), NSSize(width: 540, height: 390)),
                    ("search", AnyView(FileAdvancedSearchView(model: fixture.model)), NSSize(width: 1000, height: 420)),
                    ("uploads", AnyView(FileUploadQueueView(model: fixture.model)), NSSize(width: 680, height: 560))
                ]
                for (name, view, size) in views {
                    let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).environment(\.locale, L10n.locale)
                        .dynamicTypeSize(.accessibility3).preferredColorScheme(scheme))
                    let window = attach(host, size: size)
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    defer { window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "file-form-\(name)-\(language.rawValue)-\(scheme)")
                    if name == "create" || name == "edit" {
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
                        window.sendEvent(event); try await settle(host)
                        XCTAssertTrue(closed, "\(name) 应响应 Esc"); closed = false
                    }
                }
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
            }
        }
    }

    func test冻结相册恢复中英浅深色表单与确认操作() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ordinary", "rebuild", "noRules", "error", "loading", "cancel"] {
                    let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await service.configure(fails: mode == "error", bare: mode == "noRules", held: mode == "loading")
                    await model.selectSection(.albums)
                    let album = await service.fixture()
                    var cancelled = false
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .restoreFrozenAlbum, photos: [], album: album), onCancel: { cancelled = true })
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 660)); window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    defer { window.contentView = nil; window.close(); model.cancel() }
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-frozen-\(mode)-\(language.rawValue)-\(scheme)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    if mode == "loading" { await service.release(); try await settle(host) }
                    if mode == "rebuild" {
                        try click(window, at: NSPoint(x: 150, y: 431)); try await settle(host)
                        try snapshot(host, name: "photos-frozen-edit-\(language.rawValue)-\(scheme)")
                    }
                    if mode == "cancel" {
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
                        window.sendEvent(event); try await settle(host)
                        XCTAssertTrue(cancelled)
                        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    }
                    if mode == "ordinary" || mode == "rebuild" {
                        try click(window, at: NSPoint(x: 578, y: 32)); try await settle(host)
                        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
                        if mode == "ordinary", let command = commands.first { guard case .unfreezeAlbum = command else { XCTFail(); continue } }
                        if mode == "rebuild", let command = commands.first { guard case .rebuildFrozenAlbum = command else { XCTFail(); continue } }
                    }
                }
            }
        }
    }

    func test后台任务窗口中英浅深色五状态与错误详情() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["normal", "empty", "filtered", "failure", "loading"] {
                    let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh()
                    if mode == "empty" { await service.setTasks([]) }
                    if mode == "failure" { await service.configureList(fails: true) }
                    if mode == "loading" { await service.configureList(held: true) }
                    if mode == "normal" {
                        await service.setTasks([service.fixture(id: 42, status: .waiting), service.fixture(id: 43, status: .processing), service.fixture(id: 44, status: .done)])
                    }
                    let host = NSHostingView(rootView: PhotoBackgroundTasksPanel(model: model).background(scheme == .dark ? Color(white: 0.13) : .white).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 580)); window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    if mode == "filtered" {
                        let control = try XCTUnwrap(nativeViews(host, of: NSSegmentedControl.self).first)
                        control.selectedSegment = 2; control.sendAction(control.action, to: control.target)
                        try await settle(host)
                    }
                    try snapshot(host, name: "photos-background-\(mode)-\(language.rawValue)-\(scheme)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty, "查看任务及筛选不会取消或清理任务")
                    if mode == "loading" { await service.releaseList() }
                    window.contentView = nil; window.close(); model.cancel()
                }
                for mode in ["normal", "empty", "failure"] {
                    let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
                    await model.refresh(); await service.configureErrors(fails: mode == "failure", empty: mode == "empty")
                    let task = await service.fixture(status: .done)
                    let host = NSHostingView(rootView: PhotoBackgroundTaskErrorsPanel(model: model, task: task).background(scheme == .dark ? Color(white: 0.13) : .white).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 600, height: 460)); window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); try await settle(host)
                    try snapshot(host, name: "photos-background-errors-\(mode)-\(language.rawValue)-\(scheme)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    window.contentView = nil; window.close(); model.cancel()
                }
            }
        }
    }

    func test后台任务确认取消与固定范围清理中英浅深色() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["dismiss", "cancel", "clear"] {
                    let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let task = await service.fixture(status: mode == "clear" ? .done : .waiting)
                    await service.setTasks([task]); await model.refresh()
                    let host = NSHostingView(rootView: PhotoBackgroundTasksPanel(model: model)
                        .background(scheme == .dark ? Color(white: 0.13) : .white).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 580)); window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    defer { if let alert = window.attachedSheet { window.endSheet(alert) }; window.contentView = nil; window.close(); model.cancel() }
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-background-before-\(mode)-\(language.rawValue)-\(scheme)")
                    try click(window, at: mode == "clear" ? NSPoint(x: 90, y: 32) : NSPoint(x: 50, y: 384))
                    try await settle(host)
                    let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                    let key = mode == "dismiss" ? "photos.delete.cancel" : mode == "cancel" ? "photos.tasks.cancel" : "photos.tasks.clear"
                    let button = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string(key) })
                    let before = await service.commands; XCTAssertTrue(before.isEmpty, "必须在确认后才改变任务")
                    if mode == "clear" { await service.setTasks([task, service.fixture(id: 43, status: .done)]) }
                    button.performClick(nil); try await settle(host)
                    let commands = await service.commands
                    XCTAssertEqual(commands.count, mode == "dismiss" ? 0 : 1)
                    if mode == "cancel" { XCTAssertEqual(commands, [.cancelBackgroundTask(task)]) }
                    if mode == "clear" {
                        XCTAssertEqual(commands, [.clearBackgroundTasks([task])])
                        let remaining = try await service.backgroundTasks(); XCTAssertEqual(remaining.map(\.id), [43])
                    }
                    try snapshot(host, name: "photos-background-after-\(mode)-\(language.rawValue)-\(scheme)")
                }
            }
        }
    }

    func test由我共享列表直接管理双语浅深色取消只读及停止更新() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = DatePhotoServiceStub(); await service.enableManagement(); await service.configureSharing(.view)
                await service.configureSharedAlbumSort(.init(field: .shareModified, direction: .descending))
                await service.configureSharedAlbumEntries([.init(id: "9", title: "Synthetic shared album", albumID: 9)])
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.selectSection(.sharing); await model.selectShareScope(.withOthers)
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1400, height: 820))
                defer { window.contentView = nil; window.close(); model.cancel() }
                try await settle(host); window.makeKeyAndOrderFront(nil)
                try snapshot(host, name: "photos-sharing-row-\(language.rawValue)-\(scheme)")
                for saving in [false, true] {
                    try click(window, at: NSPoint(x: 1290, y: 658)); try await settle(host)
                    let sheet = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                    try await settle(content); XCTAssertNil(model.selectedAlbum)
                    let before = await service.managementWriteCount; XCTAssertEqual(before, 0, "打开管理只读，不创建链接或修改分享")
                    try snapshot(content, name: "photos-sharing-direct-\(saving)-\(language.rawValue)-\(scheme)")
                    if saving {
                        await service.configureSharedAlbumEntries([])
                        try click(sheet, at: NSPoint(x: 140, y: 539)); try await settle(content)
                        try click(sheet, at: NSPoint(x: 610, y: 32))
                    } else { try click(sheet, at: NSPoint(x: 490, y: 32)) }
                    try await settle(host)
                    for _ in 0..<100 where model.isManaging { try await Task.sleep(for: .milliseconds(2)) }
                }
                XCTAssertEqual(model.section, .sharing); XCTAssertEqual(model.shareScope, .withOthers); XCTAssertNil(model.selectedAlbum)
                XCTAssertTrue(model.sharedEntries.isEmpty); XCTAssertFalse(model.needsSharedListRefresh)
                let writes = await service.managementWriteCount; XCTAssertEqual(writes, 1)
                try snapshot(host, name: "photos-sharing-stopped-\(language.rawValue)-\(scheme)")
            }
        }
    }

    func test照片缩略图五档中英浅深色按钮键盘及历史位置保持() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = ThumbnailSizingPhotoService(), model = SynologyPhotosModel(repository: service)
                await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
                model.toggleSelection(try XCTUnwrap(model.items.first))
                let ids = model.items.map(\.id), selected = model.selectedPhotoIDs
                let host = NSHostingView(rootView: PhotoThumbnailSizeControls(model: model)
                    .frame(width: 300, height: 80).background(Color(nsColor: .windowBackgroundColor))
                    .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 300, height: 80))
                try await settle(host); window.makeKeyAndOrderFront(nil)
                try snapshot(host, name: "photos-thumbnail-controls-\(language.rawValue)-\(scheme)")
                for _ in 0..<4 { try click(window, at: NSPoint(x: 238, y: 40)) }
                try await settle(host); XCTAssertEqual(model.thumbnailSize, .extraLarge)
                for _ in 0..<5 { try click(window, at: NSPoint(x: 62, y: 40)) }
                try await settle(host); XCTAssertEqual(model.thumbnailSize, .small)
                try click(window, at: NSPoint(x: 90, y: 40))
                try await settle(host)
                let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124))
                window.sendEvent(key); try await settle(host)
                XCTAssertEqual(model.thumbnailSize, .medium, "原生滑杆可通过方向键调整")
                for positions in [[120.0, 160, 210], [210.0, 160, 120]] {
                    for (index, x) in positions.enumerated() {
                        let type: NSEvent.EventType = index == 0 ? .leftMouseDown : .leftMouseDragged
                        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 40), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: 1))
                        window.sendEvent(event)
                    }
                    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: positions.last!, y: 40), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 0))
                    window.sendEvent(up); try await settle(host)
                    XCTAssertEqual(model.thumbnailSize, positions.last == 210 ? .extraLarge : .medium, "拖动滑杆改变尺寸")
                }
                window.contentView = nil; window.close()

                let gallery = NSHostingView(rootView: SynologyPhotosView(model: model)
                    .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let galleryWindow = attach(gallery, size: NSSize(width: 1400, height: 820))
                try await settle(gallery)
                let scroll = try XCTUnwrap(nativeViews(gallery, of: NSScrollView.self).max { $0.bounds.height < $1.bounds.height })
                let document = try XCTUnwrap(scroll.documentView)
                document.scroll(NSPoint(x: 0, y: 400)); try await settle(gallery)
                let originalHeight = document.bounds.height, reads = await service.pageReads
                XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 300)
                galleryWindow.makeKeyAndOrderFront(nil)
                try click(galleryWindow, at: NSPoint(x: 1375, y: 19)); try await settle(gallery)
                XCTAssertEqual(model.thumbnailSize, .comfortable)
                XCTAssertGreaterThan(document.bounds.height, originalHeight)
                XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 200, "改变尺寸不回到照片列表开头")
                XCTAssertEqual(model.items.map(\.id), ids); XCTAssertEqual(model.selectedPhotoIDs, selected)
                XCTAssertEqual(model.selectedTimelineMonthID, 202003)
                let finalReads = await service.pageReads; XCTAssertEqual(finalReads, reads, "调整布局不重新请求列表")
                try snapshot(gallery, name: "photos-thumbnail-gallery-\(language.rawValue)-\(scheme)")
                galleryWindow.contentView = nil; galleryWindow.close(); model.cancel()
            }
        }
    }

    func test照片旋转预览中英浅深色保存状态和原位置保持() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        func fixture(width: Int, height: Int) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(NSColor.systemOrange.cgColor); context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = SlideshowPhotoServiceStub()
                await service.enableRotation(pending: true)
                await service.setImage(try fixture(width: 160, height: 120)); await service.setRotatedImage(try fixture(width: 120, height: 160))
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
                let ids = model.items.map(\.id)
                model.showPreview(try XCTUnwrap(model.items.first))
                for _ in 0..<100 where model.isPreparingPreview { try await Task.sleep(for: .milliseconds(2)) }
                let host = NSHostingView(rootView: SynologyPhotoPreview(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1040, height: 720))
                try await settle(host)
                XCTAssertTrue(model.canRotatePreview)
                try snapshot(host, name: "photos-rotate-ready-\(language.rawValue)-\(scheme)")
                model.rotatePreview()
                for _ in 0..<100 where model.isManaging { try await Task.sleep(for: .milliseconds(2)) }
                XCTAssertNotNil(model.pendingMutationID); XCTAssertFalse(model.canRotatePreview)
                await service.resolveRotation(); model.reviewPendingMutation()
                for _ in 0..<100 where model.isManaging || model.isPreparingPreview { try await Task.sleep(for: .milliseconds(2)) }
                try await settle(host)
                XCTAssertEqual(model.previewPhoto?.orientation, 8); XCTAssertEqual(model.items.map(\.id), ids)
                try snapshot(host, name: "photos-rotate-saved-\(language.rawValue)-\(scheme)")
                model.closePreview(); window.contentView = nil; window.close()
            }
        }
    }

    func test相册列表范围与分享排序中英浅深色原生菜单() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await service.configureLists([.init(id: 21, name: "Fixture album")]); await model.selectSection(.albums)
                let host = NSHostingView(rootView: PhotoAlbumListControls(model: model).padding(20).frame(width: 600, height: 140)
                    .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 600, height: 140))
                defer { window.contentView = nil; window.close() }
                try await settle(host); window.makeKeyAndOrderFront(nil)
                for (key, x) in [("photos.albumList.my_album", 80.0), ("photos.albumList.create_time", 550.0), ("workspace.sort.descending", 550.0)] {
                    let chosen = expectation(description: "列表菜单实际选择")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let tracked = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            DispatchQueue.main.async {
                                let index = menu.indexOfItem(withTitle: L10n.string(key))
                                XCTAssertGreaterThanOrEqual(index, 0); menu.cancelTrackingWithoutAnimation()
                                if index >= 0 { menu.performActionForItem(at: index) }; chosen.fulfill()
                            }
                        }
                    }
                    try click(window, at: NSPoint(x: x, y: 70)); await fulfillment(of: [chosen], timeout: 2)
                    NotificationCenter.default.removeObserver(observer); try await settle(host)
                }
                XCTAssertEqual(model.albumListDisplay, .mine); XCTAssertEqual(model.albumListSort, .init(field: .created, direction: .descending))
                let commands = await service.commands; XCTAssertEqual(commands.count, 3)
                try snapshot(host, name: "photos-list-preferences-\(language.rawValue)-\(scheme)")
                let albumGallery = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let albumWindow = attach(albumGallery, size: NSSize(width: 1040, height: 680))
                try await settle(albumGallery); try snapshot(albumGallery, name: "photos-album-list-gallery-\(language.rawValue)-\(scheme)")
                albumWindow.contentView = nil; albumWindow.close(); window.makeKeyAndOrderFront(nil)
                await model.selectSection(.sharing); try await settle(host)
                XCTAssertNil(model.albumListDisplay); XCTAssertEqual(model.albumListSort?.field, .name)
                let checked = expectation(description: "分享菜单不含创建时间和分享状态")
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                    nonisolated(unsafe) let tracked = notification.object as? NSMenu
                    MainActor.assumeIsolated {
                        guard let menu = tracked else { return }
                        DispatchQueue.main.async {
                            XCTAssertEqual(menu.indexOfItem(withTitle: L10n.string("photos.albumList.create_time")), -1)
                            XCTAssertEqual(menu.indexOfItem(withTitle: L10n.string("photos.albumList.share_status")), -1)
                            let index = menu.indexOfItem(withTitle: L10n.string("photos.albumList.share_modify_time"))
                            XCTAssertGreaterThanOrEqual(index, 0); menu.cancelTrackingWithoutAnimation()
                            if index >= 0 { menu.performActionForItem(at: index) }; checked.fulfill()
                        }
                    }
                }
                try click(window, at: NSPoint(x: 550, y: 70)); await fulfillment(of: [checked], timeout: 2)
                NotificationCenter.default.removeObserver(observer); try await settle(host)
                XCTAssertEqual(model.albumListSort, .init(field: .shareModified, direction: .ascending))
                try snapshot(host, name: "photos-sharing-list-preferences-\(language.rawValue)-\(scheme)")
                let gallery = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let galleryWindow = attach(gallery, size: NSSize(width: 1040, height: 680))
                try await settle(gallery); try snapshot(gallery, name: "photos-sharing-list-gallery-\(language.rawValue)-\(scheme)")
                galleryWindow.contentView = nil; galleryWindow.close()
            }
        }
    }

    func test相册排序双语浅深色原生菜单保存并显示当前相册() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await service.configureAlbumSort(.init())
                await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: false, canContribute: false))
                await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
                for key in ["photos.folderSort.filesize", "workspace.sort.descending"] {
                    let current = try XCTUnwrap(model.currentSortAlbum)
                    let host = NSHostingView(rootView: PhotoFolderSortMenu(accessibilityID: "photos.albumSort", sort: current.sort, changeSort: model.changeCurrentAlbumSort)
                        .frame(width: 240, height: 120).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 240, height: 120))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-album-sort-menu-\(key)-\(language.rawValue)-\(scheme)")
                    let inspected = expectation(description: "相册排序选择")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let tracked = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            DispatchQueue.main.async {
                                for field in SynologyPhotoSort.Field.allCases { XCTAssertTrue(menu.items.contains { $0.title == L10n.string("photos.folderSort." + field.rawValue) }) }
                                let index = menu.indexOfItem(withTitle: L10n.string(key))
                                XCTAssertGreaterThanOrEqual(index, 0); menu.cancelTrackingWithoutAnimation()
                                if index >= 0 { menu.performActionForItem(at: index) }; inspected.fulfill()
                            }
                        }
                    }
                    // 测试宿主将实际菜单固定在240×120内容区域中央。
                    try click(window, at: NSPoint(x: 120, y: 60))
                    await fulfillment(of: [inspected], timeout: 2); NotificationCenter.default.removeObserver(observer)
                    try await settle(host)
                }
                let commands = await service.commands
                XCTAssertEqual(commands, [.setAlbumSort(id: 21, original: .init(), sort: .init(field: .filesize)),
                    .setAlbumSort(id: 21, original: .init(field: .filesize), sort: .init(field: .filesize, direction: .descending))])
                XCTAssertEqual(model.selectedAlbum?.id, 21); XCTAssertEqual(model.currentSortAlbum?.sort, .init(field: .filesize, direction: .descending))
                let gallery = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(gallery, size: NSSize(width: 1040, height: 680))
                try await settle(gallery); try snapshot(gallery, name: "photos-album-sort-gallery-\(language.rawValue)-\(scheme)")
                window.contentView = nil; window.close()
            }
        }
    }

    func test照片空闲预览不占底部且删除成功弹窗关闭后不再显示() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub(), idle = SynologyPhotosModel(repository: service,
                    previewConversionSupport: .init(hevc: true, vc1: false, video: true))
                await service.configureAutomatic(enabled: true, tasks: [])
                await idle.refresh(); await idle.processAutomaticPreview()
                let idleHost = NSHostingView(rootView: SynologyPhotosView(model: idle).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let idleWindow = attach(idleHost, size: NSSize(width: 1100, height: 720))
                defer { idle.cancel(); idleWindow.contentView = nil; idleWindow.close() }
                try await settle(idleHost)
                XCTAssertEqual(idle.automaticPreviewEnabled, true); XCTAssertEqual(idle.automaticPreviewCompleted, 0)
                XCTAssertFalse(idle.showsAutomaticPreviewStatus)
                XCTAssertFalse(nativeViews(idleHost, of: NSButton.self).contains { $0.title == L10n.string("photos.automatic.pause") })
                try snapshot(idleHost, name: "photos-preview-idle-\(language.rawValue)-\(scheme)")

                let repository = DatePhotoServiceStub()
                let model = SynologyPhotosModel(repository: repository, pageSize: 6, deletionReviewDelay: { _ in })
                await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1100, height: 720))
                defer { if let alert = window.attachedSheet { window.endSheet(alert) }; model.cancel(); window.contentView = nil; window.close() }
                try await settle(host)
                model.requestDeletion(model.items[0])
                for _ in 0..<100 where model.isCheckingDeletion { try await Task.sleep(for: .milliseconds(5)) }
                try await settle(host)
                let confirmation = try XCTUnwrap(window.attachedSheet?.contentView)
                let delete = try XCTUnwrap(nativeViews(confirmation, of: NSButton.self).first { $0.title == L10n.string("photos.delete.action") })
                delete.performClick(nil)
                for _ in 0..<100 where model.isDeleting { try await Task.sleep(for: .milliseconds(5)) }
                try await settle(host)
                XCTAssertNil(model.deletionMessage); XCTAssertEqual(model.deletionSuccessMessage, L10n.string("photos.selection.deleted", 1))
                let success = try XCTUnwrap(window.attachedSheet?.contentView)
                try snapshot(success, name: "photos-delete-success-\(language.rawValue)-\(scheme)")
                let close = try XCTUnwrap(nativeViews(success, of: NSButton.self).first { $0.title == L10n.string("photos.media.close") })
                close.performClick(nil); try await settle(host)
                XCTAssertNil(model.deletionSuccessMessage); XCTAssertNil(window.attachedSheet)
                XCTAssertEqual(model.items.map(\.id.unitID), [5, 6]); XCTAssertEqual(model.selectedTimelineMonthID, 201408)
                await model.continueAutomaticDeletionReview(); try await settle(host)
                XCTAssertNil(window.attachedSheet, "关闭后不重新弹出，也不留下成功状态行")
                try snapshot(host, name: "photos-delete-dismissed-\(language.rawValue)-\(scheme)")
                let deletes = await repository.deleteIDs; XCTAssertEqual(deletes, [4])
            }
        }
    }

    func test自动预览失败恢复提示中英浅深色保持历史月份() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
                    previewConversionSupport: .init(hevc: true, vc1: false, video: true))
                let profile = UUID(), filename = "Fixture-preview.heic"
                let task = SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: 701, filename: filename,
                    typeCode: 0, needsThumbnail: true, needsVideo: false)
                let photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: filename, sizeBytes: 8,
                    takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
                await service.configureDisplay(.init(), photos: [photo]); await service.configureAutomatic(enabled: true, tasks: [task])
                await service.recordNextAutomaticFailure(); await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
                await model.processAutomaticPreview()
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1040, height: 720))
                defer { model.cancel(); window.contentView = nil; window.close() }
                try await settle(host)
                try snapshot(host, name: "photos-failure-recovery-\(language.rawValue)-\(scheme)")
                XCTAssertEqual(model.automaticPreviewError, L10n.string("photos.automatic.failureRecorded", filename))
                XCTAssertEqual(model.automaticPreviewCompleted, 0); XCTAssertEqual(model.selectedTimelineMonthID, 202003)
                let commands = await service.commands; XCTAssertEqual(commands.count, 1)
            }
        }
    }

    func test自动预览设置中英浅深色正常加载错误与无转换器() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "loading", "error", "unsupported"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in },
                        previewConversionSupport: .init(hevc: mode != "unsupported", vc1: false, video: mode != "unsupported"))
                    await service.configureAutomatic(enabled: true, tasks: [])
                    await service.configureAutomaticRead(fails: mode == "error", held: mode == "loading")
                    await model.refresh()
                    let host = NSHostingView(rootView: PhotoAutomaticPreviewSettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 340))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-automatic-\(language.rawValue)-\(scheme)-\(mode)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "ready" || mode == "unsupported" {
                        // 560×340合成窗口，开关位置由本轮中英浅深色截图核对。
                        try click(window, at: NSPoint(x: 512, y: 240)); try await settle(host)
                        try snapshot(host, name: "photos-automatic-\(language.rawValue)-\(scheme)-\(mode)-edited")
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        let commands = await service.commands
                        XCTAssertEqual(commands, [.setAutomaticPreview(original: true, enabled: false)])
                        XCTAssertEqual(model.automaticPreviewEnabled, false)
                    }
                }
            }
        }
    }

    func test共享成员中英浅深色正常空关闭加载错误与筛选() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "empty", "disabled", "loading", "error", "candidatesError"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let member = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture member"), role: .entry)
                    let protected = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "group", value: .integer(12)), name: "administrators"), role: .management)
                    let unknown = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "group", value: .integer(15)), name: "Fixture unknown"), role: "future", autoBackup: false)
                    let original = SynologyPhotoSharedMembers(profileID: UUID(), administratorID: 12, isEnabled: mode != "disabled", members: mode == "empty" ? [] : [member, protected, unknown])
                    await service.configureMembers(original, fails: mode == "error", candidatesFail: mode == "candidatesError", held: mode == "loading")
                    await model.refresh()
                    let host = NSHostingView(rootView: PhotoSharedMembersPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 780, height: 620))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-members-\(language.rawValue)-\(scheme)-\(mode)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "ready" {
                        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.members.search") })
                        window.makeFirstResponder(field)
                        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                        editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0)); try await settle(host)
                        try snapshot(host, name: "photos-members-\(language.rawValue)-\(scheme)-filtered-empty")
                        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
                        window.makeFirstResponder(nil); try await settle(host)
                        // 坐标来自780×620合成窗口首行复选框，分别覆盖两种语言布局。
                        try click(window, at: NSPoint(x: language == .english ? 570 : 594, y: 470)); try await settle(host)
                        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }; try await settle(host)
                        let before = await service.commands; XCTAssertTrue(before.isEmpty)
                        let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                        let save = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string("photos.duplicates.save") })
                        save.performClick(nil); try await settle(host)
                        var changed = member; changed.autoBackup = true
                        let saved = await service.commands
                        XCTAssertEqual(saved, [.setSharedMembers(original: original, members: [changed, protected, unknown], folderEdits: [])])
                    }
                }
            }
        }
    }

    func test共享成员目录中英浅深色正常空错误与筛选完成不写入() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "empty", "loading", "error"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let profile = UUID(), member = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture member"), role: .entry)
                    let original = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: [member])
                    let root = SynologyPhotoMemberFolder(profileID: profile, memberID: member.id, rootID: 1,
                        folder: .init(id: 9, name: "Fixture folder", parentID: 1, space: .shared), depth: 0, privacy: "public-download", directRole: "view", revision: "fixture")
                    let child = SynologyPhotoMemberFolder(profileID: profile, memberID: member.id, rootID: 1,
                        folder: .init(id: 10, name: "Fixture child", parentID: 9, space: .shared), depth: 1, privacy: "private", directRole: nil, revision: "fixture")
                    await service.configureMembers(original, folders: mode == "empty" ? [] : [root, child], foldersFail: mode == "error", foldersHeld: mode == "loading")
                    await model.refresh()
                    var completed = false
                    let host = NSHostingView(rootView: PhotoMemberFolderPermissionsPanel(model: model, member: member, initial: nil) { edit in
                        if mode == "ready" { XCTAssertEqual(edit?.expectedRole(for: root), "upload"); XCTAssertTrue(edit?.canSave == true) }
                        else { XCTAssertNil(edit) }
                        completed = true
                    }.environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 700, height: 570))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-member-folders-\(language.rawValue)-\(scheme)-\(mode)")
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "ready" {
                        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.members.folderSearch") })
                        window.makeFirstResponder(field)
                        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                        editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0)); try await settle(host)
                        try snapshot(host, name: "photos-member-folders-\(language.rawValue)-\(scheme)-filtered-empty")
                        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
                        window.makeFirstResponder(nil); try await settle(host)
                        let chosen = expectation(description: "选择文件夹上传权限")
                        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                            nonisolated(unsafe) let tracked = notification.object as? NSMenu
                            MainActor.assumeIsolated {
                                guard let menu = tracked else { return }
                                DispatchQueue.main.async {
                                    let index = menu.indexOfItem(withTitle: L10n.string("photos.members.folderRole.upload"))
                                    menu.cancelTrackingWithoutAnimation(); XCTAssertGreaterThanOrEqual(index, 0)
                                    if index >= 0 { menu.performActionForItem(at: index) }; chosen.fulfill()
                                }
                            }
                        }
                        try click(window, at: NSPoint(x: 600, y: 406))
                        await fulfillment(of: [chosen], timeout: 2); NotificationCenter.default.removeObserver(observer)
                        try await settle(host)
                        try click(window, at: NSPoint(x: 24, y: 406)); try await settle(host)
                        try snapshot(host, name: "photos-member-folders-\(language.rawValue)-\(scheme)-edited-expanded")
                    }
                    if mode != "error" {
                        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }; try await settle(host)
                        XCTAssertTrue(completed)
                    }
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                }
            }
        }
    }

    func test全局设置中英浅深色正常受限空加载错误与缓存状态() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "restricted", "empty", "loading", "error", "cacheError", "clearing", "zero"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let profile = UUID()
                    let original = SynologyPhotoGlobalSettings(profileID: profile, administratorID: 12,
                        values: mode == "empty" ? [:] : [.person: true, .concept: false, .similar: true, .userSharing: true, .guestInfo: false, .originalJPEG: true],
                        excludedExtensions: mode == "empty" ? nil : ["RAW"], hasHEVC: mode != "restricted",
                        personalRecognition: [.person: true, .similar: true], sharedRecognition: [.person: true, .similar: true],
                        personalSpaceEnabled: true, sharedSpaceEnabled: true, sharedRole: .management)
                    await service.configureGlobal(original, fails: mode == "error", held: mode == "loading")
                    await service.configureCache(.init(profileID: profile, administratorID: 12, sizeBytes: mode == "zero" ? 0 : 2048, isClearing: mode == "clearing"), fails: mode == "cacheError")
                    await model.refresh()
                    let host = NSHostingView(rootView: PhotoGlobalSettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 620, height: 680))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-global-\(language.rawValue)-\(scheme)-\(mode)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "ready" || mode == "cacheError" {
                        // 620×680的合成原生表单，坐标沿本轮截图中的首项开关。
                        try click(window, at: NSPoint(x: 573, y: 554)); try await settle(host)
                        try snapshot(host, name: "photos-global-\(language.rawValue)-\(scheme)-\(mode)-edited")
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        let sheet = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                        let button = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string("photos.duplicates.save") })
                        button.performClick(nil); try await settle(host)
                        let saved = await service.commands
                        XCTAssertEqual(saved, [.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions)])
                    }

                }
            }
        }
    }

    func test新格式提示中英浅深色范围已读受限加载错误与最终提交() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["admin", "personal", "submitted", "none", "unavailable", "loading", "error"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let prompt = SynologyPhotoCodecPrompt(profileID: UUID(), userID: 12,
                        isAdministrator: mode == "admin", shouldShow: mode != "none", personalSpaceEnabled: mode != "unavailable",
                        generationAlreadySubmitted: mode == "submitted")
                    await service.configureCodec(prompt, fails: mode == "error", held: mode == "loading"); await model.refresh()
                    let host = NSHostingView(rootView: PhotoCodecPromptPanel(model: model, initial: nil).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 580, height: 300))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-codec-\(language.rawValue)-\(scheme)-\(mode)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "admin" || mode == "personal" {
                        try click(window, at: NSPoint(x: 510, y: 32)); try await settle(host)
                        let commands = await service.commands
                        XCTAssertEqual(commands, [.respondToCodecPrompt(prompt, generate: true)])
                    } else if mode == "submitted" || mode == "unavailable" {
                        // Esc与“稍后/关闭提示”使用同一取消快捷键，只保存提示状态。
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
                        window.sendEvent(event); try await settle(host)
                        let commands = await service.commands
                        XCTAssertEqual(commands, [.respondToCodecPrompt(prompt, generate: false)])
                    }
                }
            }
        }
    }

    func test整库维护中英浅深色空闲运行受限加载与错误() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "running", "unsupported", "loading", "error"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let original = SynologyPhotoLibraryMaintenanceStatus(profileID: UUID(), userID: 12, space: .personal,
                        indexingCount: mode == "running" ? 2 : 0, previewCount: mode == "running" ? 3 : 0,
                        supportsPreviewGeneration: mode != "unsupported")
                    await service.configureMaintenance(original, fails: mode == "error", held: mode == "loading"); await model.refresh()
                    let host = NSHostingView(rootView: PhotoLibraryMaintenancePanel(model: model, space: .personal).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 620, height: 400))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-maintenance-\(language.rawValue)-\(scheme)-\(mode)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "ready" {
                        // 620×400合成窗口：先取消确认，再次开始只产生一个固定维护命令。
                        try click(window, at: NSPoint(x: 572, y: 267)); try await settle(host)
                        let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                        let before = await service.commands; XCTAssertTrue(before.isEmpty)
                        let cancel = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string("photos.delete.cancel") })
                        cancel.performClick(nil); try await settle(host)
                        let cancelled = await service.commands; XCTAssertTrue(cancelled.isEmpty)
                        try click(window, at: NSPoint(x: 572, y: 267)); try await settle(host)
                        let nextAlert = try XCTUnwrap(window.attachedSheet), nextContent = try XCTUnwrap(nextAlert.contentView)
                        try snapshot(nextContent, name: "photos-maintenance-confirm-\(language.rawValue)-\(scheme)")
                        let start = try XCTUnwrap(nativeViews(nextContent, of: NSButton.self).first { $0.title == L10n.string("photos.maintenance.start") })
                        start.performClick(nil); try await settle(host)
                        let saved = await service.commands; XCTAssertEqual(saved, [.maintainLibrary(original, .reindex)])
                    }
                }
            }
        }
    }

    func test共享空间设置中英浅深色正常关闭受限空加载与错误() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "disabled", "last", "restricted", "empty", "loading", "error"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let original = SynologyPhotoSharedSpaceSettings(profileID: UUID(), administratorID: 12,
                        isEnabled: mode != "disabled", personalSpaceEnabled: mode != "last", role: .management,
                        values: mode == "empty" ? [:] : [.person: true, .concept: false, .similar: true, .publicRoot: false],
                        globallyEnabled: mode == "restricted" ? [] : [.person, .concept, .similar])
                    await service.configureSharedSettings(original, fails: mode == "error", held: mode == "loading"); await model.refresh()
                    let host = NSHostingView(rootView: PhotoSharedSpaceSettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 580, height: 480))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-shared-settings-\(language.rawValue)-\(scheme)-\(mode)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    if mode == "loading" { await service.releasePage(); try await settle(host) }
                    if mode == "ready" || mode == "restricted" {
                        // 坐标来自580×480的本轮合成截图；确认实际开关和键盘保存路径。
                        try click(window, at: NSPoint(x: 532, y: 243)); try await settle(host)
                        if mode == "ready" { try snapshot(host, name: "photos-shared-settings-\(language.rawValue)-\(scheme)-edited") }
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        let saved = await service.commands
                        XCTAssertEqual(saved, mode == "ready" ? [.setSharedSpaceSettings(original: original, enabled: [.similar])] : [])
                    }
                }
            }
        }
    }

    func test个人照片识别中英浅深色可编辑受限空与错误() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["ready", "admin", "home", "empty", "error"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let original = SynologyPhotoRecognitionSettings(values: mode == "empty" ? [:] : [.person: true, .concept: false, .similar: true],
                        globallyEnabled: mode == "admin" ? [.person, .similar] : [.person, .concept, .similar], personalSpaceEnabled: mode != "home")
                    await service.configureRecognition(original, fails: mode == "error"); await model.refresh()
                    let host = NSHostingView(rootView: PhotoRecognitionSettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 380))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-recognition-\(language.rawValue)-\(scheme)-\(mode)")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    if mode == "ready" || mode == "admin" || mode == "home" {
                        // 560×380窗口的开关位置来自本轮合成截图。
                        try click(window, at: NSPoint(x: 512, y: 243))
                        if mode == "ready" { try click(window, at: NSPoint(x: 512, y: 280)) }
                        try await settle(host)
                        if mode == "ready" { try snapshot(host, name: "photos-recognition-\(language.rawValue)-\(scheme)-edited") }
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        let saved = await service.commands
                        XCTAssertEqual(saved, mode == "ready" ? [.setRecognitionSettings(original: original, enabled: [.concept, .similar])] : [])
                    }
                }
            }
        }
    }

    func test照片显示偏好在预览和幻灯片显示底部信息() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 420, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
        let image = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for info in [false, true] {
                    let service = SlideshowPhotoServiceStub(displayPreferences: .init(dateFormat: .daySlash, showsPreviewInfo: info))
                    await service.setImage(image)
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
                    model.showPreview(try XCTUnwrap(model.items.first))
                    for _ in 0..<100 where model.isPreparingPreview { try await Task.sleep(for: .milliseconds(2)) }
                    XCTAssertEqual(model.displayPreferences?.showsPreviewInfo, info)
                    XCTAssertEqual(model.previewPhoto?.description, "Fixture description")
                    for slideshow in [false, true] {
                        let view = slideshow ? AnyView(PhotoSlideshowView(model: model)) : AnyView(SynologyPhotoPreview(model: model))
                        let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).preferredColorScheme(scheme))
                        let window = attach(host, size: NSSize(width: 1040, height: 720))
                        try await settle(host)
                        try snapshot(host, name: "photos-display-preview-\(language.rawValue)-\(scheme)-\(info)-\(slideshow)")
                        window.contentView = nil; window.close()
                    }
                    model.closePreview(); XCTAssertEqual(model.selectedTimelineMonthID, 202003)
                }
            }
        }
    }

    func test照片默认排序字段和方向改变确认取消保留草稿再保存() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for directionOnly in [false, true] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let original = SynologyPhotoDisplaySettings()
                    var updated = original
                    if directionOnly { updated.defaultSort.direction = .descending } else { updated.defaultSort.field = .filename }
                    await service.configureDisplay(original); await model.refresh()
                    let host = NSHostingView(rootView: PhotoDisplaySettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 600, height: 500))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    let chosen = expectation(description: "更改默认排序")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let tracked = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            DispatchQueue.main.async {
                                let title = L10n.string(directionOnly ? "workspace.sort.descending" : "photos.folderSort.filename")
                                let index = menu.indexOfItem(withTitle: title)
                                menu.cancelTrackingWithoutAnimation(); XCTAssertGreaterThanOrEqual(index, 0)
                                if index >= 0 { menu.performActionForItem(at: index) }; chosen.fulfill()
                            }
                        }
                    }
                    // 位置来自600×500的显示设置截图，分别点默认字段和排序方向。
                    try click(window, at: NSPoint(x: 550, y: directionOnly ? 247 : 285))
                    await fulfillment(of: [chosen], timeout: 2); NotificationCenter.default.removeObserver(observer)
                    try await settle(host)
                    let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }; try await settle(host)
                    let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                    try snapshot(content, name: "photos-sort-confirm-\(language.rawValue)-\(scheme)-\(directionOnly ? "direction" : "field")")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    let cancel = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string("photos.delete.cancel") })
                    cancel.performClick(nil); try await settle(host)
                    let cancelled = await service.commands; XCTAssertTrue(cancelled.isEmpty); XCTAssertEqual(model.displayPreferences, original)
                    // 取消只关闭确认，编辑值仍保留，再次保存不需要重选菜单。
                    if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }; try await settle(host)
                    let nextAlert = try XCTUnwrap(window.attachedSheet), nextContent = try XCTUnwrap(nextAlert.contentView)
                    let save = try XCTUnwrap(nativeViews(nextContent, of: NSButton.self).first { $0.title == L10n.string("photos.duplicates.save") })
                    save.performClick(nil); try await settle(host)
                    let saved = await service.commands; XCTAssertEqual(saved, [.setDisplaySettings(original: original, updated: updated)])
                    XCTAssertEqual(model.displayPreferences, updated)
                }
            }
        }
    }

    func test照片显示设置中英浅深色读取保存和错误() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for fails in [false, true] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await service.configureDisplay(.init(), fails: fails); await model.refresh()
                    let host = NSHostingView(rootView: PhotoDisplaySettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 600, height: 500))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-display-\(language.rawValue)-\(scheme)-\(fails ? "error" : "form")")
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    if !fails {
                        let chosen = expectation(description: "切换月份分组")
                        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                            nonisolated(unsafe) let tracked = notification.object as? NSMenu
                            MainActor.assumeIsolated {
                                guard let menu = tracked else { return }
                                DispatchQueue.main.async {
                                    let index = menu.indexOfItem(withTitle: L10n.string("photos.display.month"))
                                    menu.cancelTrackingWithoutAnimation(); XCTAssertGreaterThanOrEqual(index, 0)
                                    if index >= 0 { menu.performActionForItem(at: index) }; chosen.fulfill()
                                }
                            }
                        }
                        // 600×500窗口控件位置来自本轮合成截图。
                        try click(window, at: NSPoint(x: 550, y: 400))
                        await fulfillment(of: [chosen], timeout: 2); NotificationCenter.default.removeObserver(observer)
                        try click(window, at: NSPoint(x: 550, y: 172)); try await settle(host)
                        try snapshot(host, name: "photos-display-\(language.rawValue)-\(scheme)-edited")
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        let saved = await service.commands
                        XCTAssertEqual(saved, [.setDisplaySettings(original: .init(), updated: .init(grouping: .month, showsPreviewInfo: true))])
                        XCTAssertEqual(model.displayPreferences?.grouping, .month)
                        XCTAssertEqual(model.displayPreferences?.showsPreviewInfo, true)
                    }
                }
            }
        }
    }

    func test重复项设置双语浅深色读取保存取消与失败() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["read", "save", "overwrite", "cancelOverwrite", "error"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh(); await service.failDuplicateRead(mode == "error")
                    let host = NSHostingView(rootView: PhotoDuplicateSettingsPanel(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 340))
                    defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-duplicate-settings-\(mode)-\(language.rawValue)-\(scheme)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    if ["save", "overwrite", "cancelOverwrite"].contains(mode) {
                        let overwrite = mode != "save"
                        let chosen = expectation(description: "更改重复项处理规则")
                        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                            nonisolated(unsafe) let tracked = notification.object as? NSMenu
                            MainActor.assumeIsolated {
                                guard let menu = tracked else { return }
                                DispatchQueue.main.async {
                                    let index = menu.indexOfItem(withTitle: L10n.string(overwrite ? "photos.duplicates.overwrite" : "photos.duplicates.ignore"))
                                    menu.cancelTrackingWithoutAnimation(); XCTAssertGreaterThanOrEqual(index, 0)
                                    if index >= 0 { menu.performActionForItem(at: index) }; chosen.fulfill()
                                }
                            }
                        }
                        // 560×340窗口中的原生菜单位置依据本轮渲染截图，SwiftUI Picker并非NSPopUpButton。
                        try click(window, at: NSPoint(x: overwrite ? (language == .english ? 420 : 240) : 250, y: overwrite ? 202 : 247))
                        await fulfillment(of: [chosen], timeout: 2); NotificationCenter.default.removeObserver(observer)
                        try await settle(host)
                        try snapshot(host, name: "photos-duplicate-settings-edited-\(mode)-\(language.rawValue)-\(scheme)")
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        if overwrite {
                            let beforeConfirm = await service.commands; XCTAssertTrue(beforeConfirm.isEmpty)
                            let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                            try snapshot(content, name: "photos-duplicate-default-confirm-\(mode)-\(language.rawValue)-\(scheme)")
                            let button = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string(mode == "cancelOverwrite" ? "photos.delete.cancel" : "photos.duplicates.save") })
                            button.performClick(nil); try await settle(host)
                        }
                        let commands = await service.commands
                        let expected: [SynologyPhotosMutation] = mode == "cancelOverwrite" ? [] : [.setDuplicateSettings(original: .init(upload: .rename, transfer: .skip), updated: .init(upload: overwrite ? .rename : .ignore, transfer: overwrite ? .overwrite : .skip))]
                        XCTAssertEqual(commands, expected)
                    } else {
                        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    }
                }
            }
        }
    }

    func test移动覆盖规则双语浅深色确认前不提交且取消无写入() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for confirm in [true, false] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let folder = SynologyPhotoCollection(id: 11, name: "Destination", parentID: 1, path: "/Destination")
                    await service.addFolder(folder); await service.setDuplicateDefaults(.init(upload: .ignore, transfer: .overwrite))
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
                        takenAt: .distantPast, indexedAt: .distantPast, folderID: 1, mediaType: "photo")
                    await service.setFolderPhotos([photo]); await model.refresh(); await model.selectSection(.folders)
                    let path = try XCTUnwrap(model.photoDropPath(to: folder))
                    let sheet = PhotoManagementSheet(kind: .move, photos: [photo], transferPath: path)
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 470))
                    defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    try snapshot(host, name: "photos-duplicate-move-\(confirm)-\(language.rawValue)-\(scheme)")
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }; try await settle(host)
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                    try snapshot(content, name: "photos-duplicate-warning-\(confirm)-\(language.rawValue)-\(scheme)")
                    let button = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string(confirm ? "photos.duplicates.overwriteConfirm" : "photos.delete.cancel") })
                    button.performClick(nil); try await settle(host)
                    let commands = await service.commands
                    XCTAssertEqual(commands, confirm ? [.move([photo], folderID: 11, destinationSpace: .personal, duplicate: .overwrite)] : [])
                }
            }
        }
    }

    func test拖放预选目标双语浅深色固定混选确认取消与无效路径() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["confirm", "cancel", "invalid"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    let folders = [10, 11].map { SynologyPhotoCollection(id: $0, name: "Folder \($0)", parentID: 1, path: "/Folder \($0)") }
                    for folder in folders { await service.addFolder(folder) }
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
                        takenAt: .distantPast, indexedAt: .distantPast, folderID: 1, mediaType: "photo")
                    await service.setFolderPhotos([photo]); await model.refresh(); await model.selectSection(.folders)
                    model.toggleSelection(photo); model.toggleFolderSelection(folders[0])
                    let token = try XCTUnwrap(model.beginPhotoDrag(photo: photo))
                    let selection = try XCTUnwrap(model.takePhotoDrop(token: token, to: folders[1]))
                    var path = try XCTUnwrap(model.photoDropPath(to: folders[1]))
                    if state == "invalid" { path[0] = .init(id: 99, name: "Changed root", path: "/") }
                    let sheet = PhotoManagementSheet(kind: .move, photos: selection.photos, folders: selection.folders, transferPath: path)
                    model.clearSelection()
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 470)); try await settle(host)
                    window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-drag-confirm-\(state)-\(language.rawValue)-\(scheme)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    let cancel = state == "cancel"
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: cancel ? "\u{1b}" : "\r", charactersIgnoringModifiers: cancel ? "\u{1b}" : "\r", isARepeat: false, keyCode: cancel ? 53 : 36))
                    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                    try await settle(host)
                    let commands = await service.commands
                    XCTAssertEqual(commands, state == "confirm" ? [.move([photo], folderID: 11, destinationSpace: .personal, folders: [folders[0]])] : [])
                    window.contentView = nil; window.close()
                }
                let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
                await model.refresh(); await model.selectSection(.folders); await model.open(try XCTUnwrap(model.collections.first))
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1100, height: 720)); try await settle(host)
                try snapshot(host, name: "photos-drag-navigation-\(language.rawValue)-\(scheme)")
                XCTAssertEqual(model.folderHistory.count, 2)
                let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                window.contentView = nil; window.close()
            }
        }
    }

    func test目录权限保存双语浅深色确认取消和父目录限制() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["save", "edit", "cancel", "restricted"] {
                    let service = FolderSharingServiceStub(mode: mode == "restricted" ? .parentRestricted : .normal)
                    let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh()
                    let folder = SynologyPhotoCollection(id: 9, name: "Fixture folder", parentID: mode == "restricted" ? 8 : 1,
                        path: mode == "restricted" ? "/Parent/Fixture" : "/Fixture", space: .shared)
                    let host = NSHostingView(rootView: PhotoFolderSharingPanel(model: model, folder: folder).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 620, height: 540))
                    defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    if mode == "edit" {
                        func choose(_ title: String, at point: NSPoint) async throws {
                            let chosen = expectation(description: "选择目录权限选项")
                            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                                nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
                                MainActor.assumeIsolated {
                                    guard let menu = trackedMenu else { return }
                                    DispatchQueue.main.async {
                                        let index = menu.indexOfItem(withTitle: title)
                                        menu.cancelTrackingWithoutAnimation()
                                        XCTAssertGreaterThanOrEqual(index, 0)
                                        if index >= 0 { menu.performActionForItem(at: index) }
                                        chosen.fulfill()
                                    }
                                }
                            }
                            defer { NotificationCenter.default.removeObserver(observer) }
                            try click(window, at: point); await fulfillment(of: [chosen], timeout: 2)
                        }
                        // 固定620×540测试窗口，菜单位置来自同轮实际渲染截图。
                        try await choose(L10n.string("photos.manage.link.download"), at: NSPoint(x: 250, y: 425))
                        try await choose(L10n.string("photos.sharing.passwordRemove"), at: NSPoint(x: 180, y: 288))
                        try await choose(L10n.string("photos.sharing.role.upload"), at: NSPoint(x: 460, y: 211))
                        try await settle(host)
                    }
                    try snapshot(host, name: "photos-permission-save-\(mode)-\(language.rawValue)-\(scheme)")
                    let before = await service.writes; XCTAssertEqual(before, 0)
                    let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                    try await settle(host)
                    let beforeConfirmation = await service.writes; XCTAssertEqual(beforeConfirmation, 0)
                    if mode == "restricted" { XCTAssertNil(window.attachedSheet); continue }
                    let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                    try snapshot(content, name: "photos-permission-confirm-\(mode)-\(language.rawValue)-\(scheme)")
                    let title = L10n.string(mode != "cancel" ? "photos.folderSharing.save" : "photos.delete.cancel")
                    let button = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == title })
                    button.performClick(nil); try await settle(host)
                    let commands = await service.commands
                    if mode == "cancel" { XCTAssertTrue(commands.isEmpty) }
                    else {
                        XCTAssertEqual(commands.count, 1)
                        guard case .setFolderSharing(let original, let access, let members, let password, let applies) = commands.first else { XCTFail("确认后应保存目录权限"); continue }
                        XCTAssertEqual(original.folder, folder); XCTAssertEqual(access, mode == "edit" ? .download : .invited); XCTAssertEqual(members?.count, 2)
                        if mode == "edit" { XCTAssertEqual(password, ""); XCTAssertEqual(members?.first?.role, "upload") }
                        else { XCTAssertNil(password) }
                        XCTAssertTrue(applies)
                    }
                }
            }
        }
    }

    func test共享目录权限查看双语浅深色成员空未知父目录限制及错误均无写入() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in [FolderSharingServiceStub.Mode.normal, .empty, .unreadableMembers, .parentRestricted, .failure] {
                    let service = FolderSharingServiceStub(mode: mode), model = SynologyPhotosModel(repository: service)
                    await model.refresh()
                    let folder = SynologyPhotoCollection(id: 9, name: "Fixture folder", parentID: mode == .parentRestricted ? 8 : 1,
                        path: mode == .parentRestricted ? "/Parent/Fixture" : "/Fixture", space: .shared)
                    let host = NSHostingView(rootView: PhotoFolderSharingPanel(model: model, folder: folder).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 620, height: 540)); try await settle(host)
                    try snapshot(host, name: "photos-folder-permissions-\(mode)-\(language.rawValue)-\(scheme)")
                    let targets = await service.targets, writes = await service.writes
                    XCTAssertEqual(targets, [folder]); XCTAssertEqual(writes, 0)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test文件夹移动复制双语浅深色固定混合目标且无效目录与读取失败不提交() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["move", "copy", "same-parent", "failure"] {
                    let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh(); await model.selectSection(.folders)
                    if state != "same-parent" { await model.open(try XCTUnwrap(model.collections.first)) }
                    let folders = model.collections, photos = model.items
                    if state == "failure" { await service.configure(.failure) }
                    let kind: PhotoManagementKind = state == "copy" ? .copy : .move
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: kind, photos: photos, folders: folders))
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 470)); try await settle(host)
                    window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-folder-transfer-\(state)-\(language.rawValue)-\(scheme)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    model.clearSelection()
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                    try await settle(host)
                    let commands = await service.commands
                    let expected: [SynologyPhotosMutation] = state == "move" ? [.move(photos, folderID: 1, destinationSpace: .personal, folders: folders)] : state == "copy" ? [.copy(photos, folderID: 1, destinationSpace: .personal, folders: folders)] : []
                    XCTAssertEqual(commands, expected)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test文件夹删除确认双语浅深色空选择取消及混合目标固定() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["folder", "mixed", "empty", "cancel"] {
                    let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh(); await model.selectSection(.folders)
                    let folders = state == "empty" ? [] : model.collections
                    let photos = state == "mixed" ? model.items : []
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .deleteFolders, photos: photos, folders: folders))
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 360)); try await settle(host)
                    window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-folder-delete-\(state)-\(language.rawValue)-\(scheme)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    model.clearSelection()
                    let key = state == "cancel" ? "\u{1b}" : "\r"
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: state == "cancel" ? 53 : 36))
                    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                    try await settle(host)
                    let commands = await service.commands
                    XCTAssertEqual(commands, state == "empty" || state == "cancel" ? [] : [.deleteFolderItems(photos: photos, folders: folders)])
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test文件夹主页面混合选择双语浅深色显示选择数量与目录勾选() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
                await model.refresh(); await model.selectSection(.folders); model.selectLoadedItems()
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1100, height: 720)); try await settle(host)
                XCTAssertEqual(model.selectedItemCount, 2); XCTAssertTrue(model.canDeleteSelection); XCTAssertFalse(model.canManageSelection)
                try snapshot(host, name: "photos-folder-selection-\(language.rawValue)-\(scheme)")
                let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                window.contentView = nil; window.close()
            }
        }
    }

    func test独立新建目录双语浅深色空名称及回车提交() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh(); await model.selectSection(.folders)
                let folder = try XCTUnwrap(model.currentCreationFolder)
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .createFolder, photos: [], folder: folder, space: folder.space))
                    .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 560, height: 270)); try await settle(host)
                window.makeKeyAndOrderFront(nil)
                let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.folder.name") })
                XCTAssertEqual(field.stringValue, "")
                try snapshot(host, name: "photos-create-folder-empty-\(language.rawValue)-\(scheme)")
                try click(window, at: NSPoint(x: 465, y: 32)); try await settle(host)
                let emptyCommands = await service.commands; XCTAssertTrue(emptyCommands.isEmpty)
                window.makeFirstResponder(field)
                let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                editor.insertText("New folder", replacementRange: NSRange(location: NSNotFound, length: 0))
                window.makeFirstResponder(nil); try await settle(host)
                try snapshot(host, name: "photos-create-folder-ready-\(language.rawValue)-\(scheme)")
                let before = await service.commands; XCTAssertTrue(before.isEmpty)
                let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                try await settle(host)
                let commands = await service.commands; XCTAssertEqual(commands, [.createFolder(parentID: folder.id, name: "New folder", space: folder.space)])
                XCTAssertTrue(model.collections.contains { $0.name == "New folder" }); XCTAssertEqual(model.currentCreationFolder, folder)
                window.contentView = nil; window.close()
            }
        }
    }

    func test目录重命名双语浅深色编辑并回车提交固定目录() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh(); await model.selectSection(.folders)
                let folder = try XCTUnwrap(model.collections.first)
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .renameFolder, photos: [], folder: folder))
                    .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 560, height: 220)); try await settle(host)
                window.makeKeyAndOrderFront(nil)
                let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.folder.name") })
                XCTAssertEqual(field.stringValue, folder.name)
                window.makeFirstResponder(field)
                let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                editor.selectAll(nil); editor.insertText("Renamed", replacementRange: NSRange(location: NSNotFound, length: 0))
                window.makeFirstResponder(nil); try await settle(host)
                try snapshot(host, name: "photos-folder-rename-\(language.rawValue)-\(scheme)")
                let before = await service.commands; XCTAssertTrue(before.isEmpty)
                let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                try await settle(host)
                let commands = await service.commands; XCTAssertEqual(commands, [.renameFolder(folder: folder, name: "Renamed")])
                XCTAssertEqual(model.collections.first?.name, "Renamed"); XCTAssertEqual(model.section, .folders)
                window.contentView = nil; window.close()
            }
        }
    }

    func test主文件夹页面双语浅深色根目录显示排序且无封面入口() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
                await model.refresh(); await model.selectSection(.folders)
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1100, height: 720)); try await settle(host)
                XCTAssertEqual(model.currentSortFolder?.folder.id, 1); XCTAssertNil(model.currentCoverFolder)
                try snapshot(host, name: "photos-main-folder-sort-\(language.rawValue)-\(scheme)")
                let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                window.contentView = nil; window.close()
            }
        }
    }

    func test封面排序菜单中英浅深色实际选择字段方向并保存固定目录() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh()
                let folder = SynologyPhotoCollection(id: 9, name: "Fixture folder", path: "/Fixture")
                let host = NSHostingView(rootView: PhotoFolderCoverPanel(model: model, target: .init(folder: folder)).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 680, height: 620)); try await settle(host)
                window.makeKeyAndOrderFront(nil)
                for key in ["photos.folderSort.filesize", "workspace.sort.descending"] {
                    let inspected = expectation(description: "排序菜单实际选择")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = trackedMenu else { return }
                            DispatchQueue.main.async {
                                for field in SynologyPhotoSort.Field.allCases { XCTAssertTrue(menu.items.contains { $0.title == L10n.string("photos.folderSort." + field.rawValue) }) }
                                let index = menu.items.firstIndex { $0.title == L10n.string(key) }
                                XCTAssertNotNil(index)
                                menu.cancelTrackingWithoutAnimation()
                                if let index { menu.performActionForItem(at: index) }
                                inspected.fulfill()
                            }
                        }
                    }
                    try click(window, at: NSPoint(x: 625, y: 512))
                    await fulfillment(of: [inspected], timeout: 2)
                    NotificationCenter.default.removeObserver(observer)
                    try await settle(host)
                }
                let commands = await service.commands
                XCTAssertEqual(commands, [.setFolderSort(folder: folder, sort: .init(field: .filesize)), .setFolderSort(folder: folder, sort: .init(field: .filesize, direction: .descending))])
                let reads = await service.photoReads
                XCTAssertEqual(reads.last?.0, .folder(id: 9, sort: .init(field: .filesize, direction: .descending)))
                try snapshot(host, name: "photos-folder-sort-\(language.rawValue)-\(scheme)")
                window.contentView = nil; window.close()
            }
        }
    }

    func test目录封面选择器中英浅深色五种状态且回车只提交固定目标() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        let image = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["normal", "selected", "empty", "error", "loading"] {
                    let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh()
                    let photo = try XCTUnwrap(model.items.first)
                    let mode: FolderCoverServiceStub.Mode = state == "empty" ? .empty : state == "error" ? .failure : state == "loading" ? .loading : .normal
                    await service.configure(mode, image: image)
                    let folder = SynologyPhotoCollection(id: 9, name: "Fixture folder", path: "/Fixture")
                    let target = PhotoFolderCoverTarget(folder: folder, photo: state == "selected" ? photo : nil)
                    let host = NSHostingView(rootView: PhotoFolderCoverPanel(model: model, target: target).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 620)); try await settle(host)
                    try snapshot(host, name: "photos-folder-cover-\(state)-\(language.rawValue)-\(scheme)")
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    if state == "selected" {
                        window.makeKeyAndOrderFront(nil)
                        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                        try await settle(host)
                        let calls = await service.commands; XCTAssertEqual(calls, [.setFolderCover(folder: folder, photo: photo)])
                    }
                    window.contentView = nil; window.close(); await service.release()
                }
            }
        }
    }

    func test幻灯片中英浅深色播放暂停加载失败并且退出保留位置() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 420, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
        let image = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["playing", "paused", "loading", "error"] {
                    let service = SlideshowPhotoServiceStub(), clock = SlideshowTestClock()
                    await service.setImage(image)
                    if state == "loading" { await service.holdPreview() }
                    let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
                    await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.startSlideshow()
                    if state != "loading" {
                        for _ in 0..<1000 where model.isPreparingPreview { try await Task.sleep(for: .milliseconds(1)) }
                    }
                    if state == "paused" { model.toggleSlideshowPlayback() }
                    if state == "error" { model.slideshowPlaybackFailed() }
                    let host = NSHostingView(rootView: PhotoSlideshowView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1000, height: 720)); try await settle(host)
                    try snapshot(host, name: "photos-slideshow-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(model.isPreparingPreview, state == "loading")
                    XCTAssertEqual(model.isSlideshowPlaying, state == "playing" || state == "loading")
                    window.makeKeyAndOrderFront(nil)
                    let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    if !window.performKeyEquivalent(with: escape) { window.sendEvent(escape) }
                    try await settle(host)
                    XCTAssertFalse(model.isSlideshowPresented); XCTAssertEqual(model.selectedTimelineMonthID, 202003)
                    model.closePreview(); await service.releasePreview(); await clock.tick()
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test共享人物管理表单中英浅深色沿共享读取且不提前写入() async throws {
        let language = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = language }
        for locale in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = locale
            for scheme in [ColorScheme.light, .dark] {
                for kind in [PhotoManagementKind.renamePerson, .mergePeople, .peopleVisibility, .removeFaces, .reassignFaces, .personCover] {
                    let service = DatePhotoServiceStub(space: .shared)
                    await service.enableManagement(); await service.configureRequestAccess(spaces: [.shared], manager: true)
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh()
                    let person = SynologyPhotoCollection(id: 31, name: "Fixture shared person", itemCount: 2, space: .shared)
                    let photos = kind == .personCover ? Array(model.items.prefix(1)) : ([PhotoManagementKind.removeFaces, .reassignFaces].contains(kind) ? model.items : [])
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
                        sheet: .init(kind: kind, photos: photos, person: person, space: .shared)).preferredColorScheme(scheme))
                    let large = [.mergePeople, .peopleVisibility, .removeFaces, .reassignFaces].contains(kind)
                    let size = large ? NSSize(width: 680, height: 660) : NSSize(width: 560, height: 470)
                    let window = attach(host, size: size)
                    try await settle(host)
                    try snapshot(host, name: "photos-shared-people-\(kind.rawValue)-\(locale.rawValue)-\(scheme)")
                    let reads = await service.peopleReadSpaces, writes = await service.managementWriteCount
                    XCTAssertTrue(reads.allSatisfy { $0 == .shared }); XCTAssertEqual(writes, 0)
                    if [.mergePeople, .peopleVisibility, .reassignFaces].contains(kind) { XCTAssertFalse(reads.isEmpty) }
                    XCTAssertEqual(host.bounds.size, size)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test共享人物显示窗口回车只提交共享目标() async throws {
        let service = DatePhotoServiceStub(space: .shared)
        await service.enableManagement(); await service.configureRequestAccess(spaces: [.shared], manager: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.person)
        let person = try XCTUnwrap(model.collections.first)
        let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
            sheet: .init(kind: .peopleVisibility, photos: [], person: person, space: .shared)))
        let window = attach(host, size: NSSize(width: 680, height: 660))
        defer { window.contentView = nil; window.close() }
        try await settle(host); window.makeKeyAndOrderFront(nil)
        let before = await service.managementCommands; XCTAssertTrue(before.isEmpty)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
        try await settle(host)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands.first?.space, .shared)
        guard case .setPeopleVisibility(let people, let visible) = commands.first else { return XCTFail("应提交共享人物显示设置") }
        XCTAssertEqual(people.first?.person, person); XCTAssertFalse(visible)
        XCTAssertEqual(model.selectedSpace, .shared); XCTAssertFalse(model.collections.contains { $0.id == person.id })
    }

    func test未完成预览恢复中英浅深色四种状态且打开不写入() async throws {
        let language = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = language }
        for locale in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = locale
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "empty", "error", "loading"] {
                    let service = DatePhotoServiceStub()
                    await service.enableManagement(); await service.configureRequestAccess(spaces: [.personal, .shared], manager: true)
                    let model = SynologyPhotosModel(repository: service); await model.refresh()
                    await service.setPreviewRecovery(state == "empty" ? [] : Array(model.items.prefix(2)), in: .personal,
                        failure: state == "error", delay: state == "loading" ? .seconds(5) : nil)
                    let host = NSHostingView(rootView: PhotoPreviewRecoveryPanel(model: model, initialSpace: .personal).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 640, height: 540))
                    try await settle(host)
                    try snapshot(host, name: "photos-preview-recovery-\(state)-\(locale.rawValue)-\(scheme)")
                    let writes = await service.managementWriteCount, reads = await service.previewRecoveryReads
                    XCTAssertEqual(writes, 0); XCTAssertEqual(reads, [.personal])
                    if state != "loading" {
                        let picker = try XCTUnwrap(nativeViews(host, of: NSSegmentedControl.self).first)
                        XCTAssertEqual(picker.segmentCount, 2)
                        picker.selectedSegment = 1; XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                        try await settle(host)
                        let switchedReads = await service.previewRecoveryReads
                        XCTAssertEqual(switchedReads, [.personal, .shared])
                        let afterWrites = await service.managementWriteCount; XCTAssertEqual(afterWrites, 0)
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test恢复预览窗口回车仅继续原所选照片且保持相册位置() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in }); await model.refresh()
        let targets = Array(model.items.prefix(2)); await service.setPreviewRecovery(targets, in: .personal)
        let originalItems = model.items
        let host = NSHostingView(rootView: PhotoPreviewRecoveryPanel(model: model, initialSpace: .personal))
        let window = attach(host, size: NSSize(width: 640, height: 540))
        defer { window.contentView = nil; window.close() }
        try await settle(host); window.makeKeyAndOrderFront(nil)
        let before = await service.managementWriteCount; XCTAssertEqual(before, 0)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
        try await settle(host)
        let commands = await service.managementCommands
        XCTAssertEqual(commands, [.regeneratePreviews(targets, resuming: true)])
        XCTAssertEqual(model.items, originalItems); XCTAssertFalse(model.isManaging); XCTAssertNil(model.pendingMutationID)
    }

    func test混合来源编辑表单中英浅深色保留两空间目标且不提前提交() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = DatePhotoServiceStub()
                await service.enableManagement(); await service.configureRequestAccess(spaces: [.personal, .shared], manager: true)
                let model = SynologyPhotosModel(repository: service); await model.refresh()
                let personal = try XCTUnwrap(model.items.first)
                let shared = SynologyPhoto(id: .init(profileID: personal.id.profileID, space: .shared, unitID: personal.id.unitID),
                    filename: "Fixture shared.jpg", sizeBytes: 128, takenAt: personal.takenAt, indexedAt: personal.indexedAt, folderID: 109, mediaType: "photo")
                XCTAssertTrue(model.canEditSelection([personal, shared], supportsMixedSpaces: true))
                XCTAssertFalse(model.canEditSelection([personal, shared], supportsMixedSpaces: false))
                for kind in [PhotoManagementKind.rating, .date, .shiftDates, .regeneratePreviews] {
                    let sheet = PhotoManagementSheet(kind: kind, photos: [personal, shared])
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 470))
                    try await settle(host)
                    try snapshot(host, name: "photos-mixed-\(kind.rawValue)-\(language.rawValue)-\(scheme)")
                    let commands = await service.managementCommands
                    XCTAssertTrue(commands.isEmpty); XCTAssertEqual(sheet.photos.map(\.id.space), [.personal, .shared])
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test相册移动后读取失败中英浅深色保持相册并可只读重试() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
                let personal = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 128,
                    takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo",
                    albumContext: .init(albumID: 21, ownerUserID: 12, providerUserID: 12))
                let shared = SynologyPhoto(id: .init(profileID: personal.id.profileID, space: .shared, unitID: 107), filename: personal.filename,
                    sizeBytes: personal.sizeBytes, takenAt: personal.takenAt, indexedAt: personal.indexedAt, folderID: 109, mediaType: "photo",
                    albumContext: .init(albumID: 21, ownerUserID: 0, providerUserID: 12))
                await service.setAlbumPhotos([personal]); await service.setMovedAlbumPhotos([shared], failures: 3)
                await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1100, height: 720))
                try await settle(host)
                model.submitMutation(.move([personal], folderID: 109, destinationSpace: .shared))
                for _ in 0..<2000 where model.isManaging { await Task.yield() }
                try await settle(host)
                XCTAssertFalse(model.isManaging); XCTAssertTrue(model.needsAlbumRefresh); XCTAssertEqual(model.items, [personal])
                XCTAssertEqual(model.errorMessage, L10n.string("photos.manage.albumRefreshFailed"))
                try snapshot(host, name: "photos-album-refresh-error-\(language.rawValue)-\(scheme)")
                // 自定义 SwiftUI 按钮没有 NSButton；合成绘制检查文案，调用同一重试动作检查恢复。
                await model.retryAlbumRefresh()
                try await settle(host)
                XCTAssertFalse(model.needsAlbumRefresh); XCTAssertEqual(model.items, [shared]); XCTAssertNil(model.errorMessage)
                XCTAssertEqual(model.selectedAlbum?.id, 21)
                let commands = await service.commands; XCTAssertEqual(commands.count, 1)
                try snapshot(host, name: "photos-album-refresh-recovered-\(language.rawValue)-\(scheme)")
                window.contentView = nil; window.close()
            }
        }
    }

    func test跨空间移动复制表单中英浅深色切换目标且不提前提交() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for kind in [PhotoManagementKind.move, .copy] {
                    let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
                    await service.addFolder(.init(id: 9, name: "Fixture personal folder", parentID: 1))
                    await service.addFolder(.init(id: 109, name: "Fixture shared folder", parentID: 101, space: .shared))
                    let model = SynologyPhotosModel(repository: service); await model.refresh()
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 128,
                        takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo")
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: kind, photos: [photo])).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 470))
                    try await settle(host)
                    try snapshot(host, name: "photos-space-transfer-\(kind.rawValue)-personal-\(language.rawValue)-\(scheme)")
                    let picker = try XCTUnwrap(nativeViews(host, of: NSSegmentedControl.self).first)
                    XCTAssertEqual(picker.segmentCount, 2)
                    picker.selectedSegment = 1
                    XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                    try await settle(host)
                    let reads = await service.conditionFolderSpaces, commands = await service.commands
                    XCTAssertEqual(reads, [.personal, .shared]); XCTAssertTrue(commands.isEmpty)
                    try snapshot(host, name: "photos-space-transfer-\(kind.rawValue)-shared-\(language.rawValue)-\(scheme)")
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test相册转加确认中英浅深色显示可添加目标且不提前写入() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub()
                await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
                await service.setAddableAlbums([.init(id: 22, name: "Fixture owned album"), .init(id: 23, name: "Fixture contributor album")])
                let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture shared photo.jpg", sizeBytes: 128,
                    takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo",
                    albumContext: .init(albumID: 21, ownerUserID: 99, providerUserID: 12))
                await service.setAlbumPhoto(photo)
                let model = SynologyPhotosModel(repository: service)
                await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture source"))
                XCTAssertTrue(model.canAddToAlbum([photo])); XCTAssertFalse(model.canModifyOriginal(photo))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .addAlbum, photos: [photo], album: model.selectedAlbum)).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 720, height: 620))
                try await settle(host)
                try snapshot(host, name: "photos-album-transfer-\(language.rawValue)-\(scheme)")
                let reads = await service.addableAlbumReads, commands = await service.commands
                XCTAssertEqual(reads, 1); XCTAssertTrue(commands.isEmpty)
                window.contentView = nil; window.close()
            }
        }
    }

    func test相册协作角色与直接上传表单中英浅深色布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for role in ["view", "download", "upload"] {
                    let service = PhotoUploadServiceStub(); await service.setSpaces([])
                    await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: role != "view", canContribute: role == "upload"))
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture shared photo.jpg", sizeBytes: 128,
                        takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo",
                        albumContext: .init(albumID: 21, ownerUserID: 99, providerUserID: 12))
                    await service.setAlbumPhoto(photo)
                    let model = SynologyPhotosModel(repository: service)
                    await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album")); model.toggleSelection(photo)
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-collaboration-\(role)-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(model.canUploadPhotos, role == "upload"); XCTAssertEqual(model.canDownload(photo), role != "view")
                    XCTAssertEqual(model.canRemoveAlbumSelection, role == "upload"); XCTAssertFalse(model.canDeleteSelection)
                    window.contentView = nil; window.close()
                    if role == "upload" {
                        let panel = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .upload, photos: [], album: model.selectedAlbum)).preferredColorScheme(scheme))
                        let panelWindow = attach(panel, size: NSSize(width: 720, height: 620))
                        try await settle(panel)
                        try snapshot(panel, name: "photos-collaboration-upload-panel-\(language.rawValue)-\(scheme)")
                        let folders = await service.conditionFolderSpaces; XCTAssertTrue(folders.isEmpty)
                        panelWindow.contentView = nil; panelWindow.close()
                    }
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                }
            }
        }
    }

    func test相册来源不可直接访问时中英浅深色浏览及错误布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for albumID in [21, 22] {
                    let service = PhotoUploadServiceStub(); await service.setSpaces([])
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .shared, unitID: 7), filename: "Fixture shared photo.jpg", sizeBytes: 128,
                        takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo",
                        albumContext: .init(albumID: albumID, ownerUserID: 0))
                    await service.setAlbumPhoto(photo)
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh(); await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-album-context-\(albumID == 21 ? "normal" : "error")-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(host.bounds.height, 720, accuracy: 1)
                    XCTAssertEqual(model.items.count, albumID == 21 ? 1 : 0)
                    XCTAssertEqual(model.errorMessage == nil, albumID == 21)
                    XCTAssertTrue(model.managementFeatures.isEmpty)
                    let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test整册与文件夹下载菜单中英浅深色且打开不下载() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for kind in ["album", "folder", "folders", "mixed"] {
                    let service = PhotoUploadServiceStub()
                    let model = SynologyPhotosModel(repository: service); await model.refresh()
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
                        takenAt: .distantPast, indexedAt: .distantPast, folderID: 1, mediaType: "photo")
                    let folders = [10, 11].map { SynologyPhotoCollection(id: $0, name: "Child\($0)", parentID: 1, path: "/Child\($0)") }
                    let target: SynologyPhotoArchiveTarget = kind == "album" ? .album(id: 21) : kind == "folder" ? .folder(id: 1, space: .personal) :
                        .selection(photos: kind == "mixed" ? [photo] : [], folders: folders)
                    let host = NSHostingView(rootView: PhotoArchiveDownloadMenu(target: target, name: "Fixture", model: model)
                        .frame(width: 320, height: 120).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 320, height: 120)); try await settle(host)
                    window.makeKeyAndOrderFront(nil)
                    let inspected = expectation(description: "检查整集合下载菜单")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = trackedMenu else { return }
                            DispatchQueue.main.async {
                                let titles = menu.items.map { $0.title }
                                XCTAssertTrue(titles.contains(L10n.string("photos.download.original")))
                                XCTAssertTrue(titles.contains(L10n.string("photos.download.jpeg")))
                                menu.cancelTrackingWithoutAnimation(); inspected.fulfill()
                            }
                        }
                    }
                    try click(window, at: NSPoint(x: 160, y: 60))
                    await fulfillment(of: [inspected], timeout: 2)
                    NotificationCenter.default.removeObserver(observer)
                    try snapshot(host, name: "photos-archive-menu-\(kind)-\(language.rawValue)-\(scheme)")
                    let calls = await service.archiveCalls; XCTAssertTrue(calls.isEmpty)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test文件夹混选下载工具栏中英浅深色保留整组选项() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["unselected", "folders", "mixed", "empty"] {
                    let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
                    if state != "empty" {
                        for id in [10, 11] { await service.addFolder(.init(id: id, name: "Fixture \(id)", parentID: 1, path: "/Fixture \(id)")) }
                        if state == "mixed" {
                            let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
                                takenAt: .distantPast, indexedAt: .distantPast, folderID: 1, mediaType: "photo")
                            await service.setFolderPhotos([photo])
                        }
                    }
                    await model.refresh(); await model.selectSection(.folders)
                    if ["folders", "mixed"].contains(state) { model.selectLoadedItems() }
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720)); try await settle(host)
                    try snapshot(host, name: "photos-mixed-download-\(state)-\(language.rawValue)-\(scheme)")
                    if case .selection(let photos, let folders) = model.selectedArchive {
                        XCTAssertEqual(folders.count, 2); XCTAssertEqual(photos.count, state == "mixed" ? 1 : 0)
                        XCTAssertTrue(model.canDownloadArchive(try XCTUnwrap(model.selectedArchive)))
                    } else { XCTAssertTrue(["unselected", "empty"].contains(state)) }
                    XCTAssertEqual(host.bounds.height, 720, accuracy: 1)
                    let calls = await service.archiveCalls; XCTAssertTrue(calls.isEmpty)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test整集合下载页面中英浅深色与相册只读权限布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["album", "folder", "denied"] {
                    let service = PhotoUploadServiceStub()
                    await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: state != "denied", canContribute: true))
                    let model = SynologyPhotosModel(repository: service)
                    if state == "folder" { await model.selectSection(.folders) }
                    else { await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album")) }
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720)); try await settle(host)
                    try snapshot(host, name: "photos-archive-page-\(state)-\(language.rawValue)-\(scheme)")
                    let target = try XCTUnwrap(model.currentArchive?.target)
                    XCTAssertEqual(model.canDownloadArchive(target), state != "denied")
                    XCTAssertEqual(host.bounds.height, 720, accuracy: 1)
                    let calls = await service.archiveCalls; XCTAssertTrue(calls.isEmpty)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test照片下载格式菜单中英浅深色且打开不下载() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for (ext, video, enabled) in [("heic", false, true), ("heic", false, false), ("jpg", false, true), ("mov", true, true)] {
                    let service = SharedCategoryServiceStub()
                    await service.setOriginalSizeJPEG(enabled)
                    let subject = SynologyPhotosModel(repository: service); await subject.refresh()
                    let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.\(ext)",
                        sizeBytes: 128, takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: video ? "video" : "photo")
                    let host = NSHostingView(rootView: PhotoDownloadMenu(photo: photo, model: subject).frame(width: 320, height: 120).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 320, height: 120)); try await settle(host)
                    window.makeKeyAndOrderFront(nil)
                    let inspected = expectation(description: "检查下载格式菜单")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = trackedMenu else { return }
                            DispatchQueue.main.async {
                                let titles = menu.items.map { $0.title }
                                XCTAssertTrue(titles.contains(L10n.string("photos.download.original")))
                                XCTAssertEqual(titles.contains(L10n.string("photos.download.jpeg")), !video)
                                XCTAssertEqual(titles.contains(L10n.string("photos.download.originalSizeJPEG")), enabled && ext == "heic")
                                menu.cancelTrackingWithoutAnimation(); inspected.fulfill()
                            }
                        }
                    }
                    try click(window, at: NSPoint(x: 160, y: 60))
                    await fulfillment(of: [inspected], timeout: 2)
                    NotificationCenter.default.removeObserver(observer)
                    try snapshot(host, name: "photos-download-menu-\(ext)-\(enabled)-\(language.rawValue)-\(scheme)")
                    let requests = await service.downloadRequests; XCTAssertTrue(requests.isEmpty)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test相似识别状态中英浅深色运行等待与完成布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["running", "waiting", "done"] {
                    let service = SharedCategoryServiceStub()
                    await service.configureSimilarStatus(.init(waitingCount: state == "done" ? 0 : 12, stage: state, migrationComplete: true))
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
                    await model.refreshSimilarStatus()
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-similar-status-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(model.similarStatus?.isVisible, state != "done")
                    XCTAssertEqual(model.similarStatus?.isRunning, state == "running")
                    XCTAssertEqual(model.items.count, 1)
                    let commands = await service.similarCommands; XCTAssertTrue(commands.isEmpty)
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test相似照片预览中英浅深色加载错误与组内正常布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let image = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "error", "loading"] {
                    let service = SharedCategoryServiceStub()
                    let subject = SynologyPhotosModel(repository: service)
                    await service.configurePreviews([image]); await service.configureSimilar(fails: state == "error", hold: state == "loading")
                    await subject.refresh(); await subject.selectSection(.albums); await subject.openCategory(.similar)
                    subject.showPreview(try XCTUnwrap(subject.items.first))
                    if state == "loading" { await service.waitForSimilar() }
                    else { for _ in 0..<100 where subject.isPreparingPreview || subject.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) } }
                    let host = NSHostingView(rootView: SynologyPhotoPreview(model: subject).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1000, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-similar-preview-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertNotNil(subject.previewData)
                    if state == "ready" { XCTAssertEqual(subject.previewSimilarDetail?.photos.count, 2) }
                    if state == "error" { XCTAssertNotNil(subject.similarPreviewError) }
                    subject.closePreview(); if state == "loading" { await service.releaseSimilar() }
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test分类拼图中英浅深色正常空错误加载且保持分类入口() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let images = try [NSColor.systemRed, .systemGreen, .systemBlue, .systemOrange].map { color in
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "empty", "error", "loading"] {
                    let service = SharedCategoryServiceStub()
                    await service.configurePreviews(state == "empty" ? [] : images, fails: state == "error", delay: state == "loading" ? 10_000_000_000 : 0)
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums)
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-category-collage-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertTrue(model.showsCategories); XCTAssertNil(model.errorMessage)
                    let reads = await service.previewReads
                    XCTAssertEqual(Set(reads.map { $0.0 }), Set(SynologyPhotoCategory.allCases))
                    XCTAssertTrue(reads.allSatisfy { $0.1 == .shared })
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test共享分类中英浅深色正常空错误与权限布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["categories", "people", "empty", "error", "entry"] {
                    let service = SharedCategoryServiceStub()
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh(); await model.selectSpace(.shared)
                    await service.configure(manager: state != "entry", fails: state == "error", empty: state == "empty")
                    await model.selectSection(.albums)
                    if state == "people" { await model.openCategory(.person) }
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1100, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-shared-categories-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(model.selectedSpace, .shared)
                    XCTAssertEqual(host.bounds.height, 720, accuracy: 1)
                    let albumReads = await service.albumReads; XCTAssertEqual(albumReads, 1)
                    if state == "categories" { XCTAssertTrue(model.showsCategories) }
                    if state == "people" { XCTAssertEqual(model.collections.count, 2); XCTAssertTrue(model.collections.allSatisfy { $0.space == .shared }) }
                    if state == "entry" { XCTAssertTrue(model.sharedCategoriesRequireManagement) }
                    if state == "error" { XCTAssertNotNil(model.errorMessage) }
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test上传恢复中英浅深色待核对重新选择错误与继续布局() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["ready", "pending", "source", "error", "empty"] {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-recovery-ui-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let source = root.appendingPathComponent("Fixture photograph.jpg")
                    try Data(repeating: 1, count: 128).write(to: source)
                    var file = try XCTUnwrap(PhotoUploadPreparation.prepare([source]).files.first)
                    if state == "source" { file.recoveryBookmark = Data("invalid bookmark".utf8) }
                    let service = PhotoUploadServiceStub(), identity = try await service.uploadRecoveryIdentity(), operationID = UUID()
                    let store = PhotoUploadRecoveryStore(url: root.appendingPathComponent("journal/queue.json"))
                    if state != "empty" {
                        try store.save(identity: identity, entries: [PhotoUploadEntry(file: file, album: nil, folder: .init(id: 9, name: "Fixture folder"))],
                            directories: [], pendingEntryID: state == "pending" ? file.id : nil, pendingDirectory: nil,
                            pendingOperationID: state == "pending" ? operationID : nil)
                        if state == "pending" {
                            try store.checkpoint(.init(mutation: .upload(file: source, size: file.size, modifiedAt: file.modifiedAt, folderID: 9), operationID: operationID, profileID: service.profile, userID: 12))
                        }
                        if state == "error" { try Data("invalid".utf8).write(to: store.url) }
                    }
                    let model = SynologyPhotosModel(repository: service, uploadRecoveryStore: .init(url: store.url), deletionReviewDelay: { _ in })
                    await model.refresh()
                    let host = NSHostingView(rootView: PhotoUploadQueuePanel(model: model).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 620, height: 480))
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-upload-recovery-\(state)-\(language.rawValue)-\(scheme)")
                    XCTAssertEqual(model.canResumeUploads, state == "ready")
                    XCTAssertEqual(model.uploadPersistenceError != nil, state == "error")
                    XCTAssertEqual(model.pendingMutationID != nil, state == "pending")
                    if state == "source" { XCTAssertEqual(model.uploadQueue.first?.file.requiresSourceSelection, true) }
                    let before = await service.commands; XCTAssertTrue(before.isEmpty)
                    if state == "ready" {
                        try click(window, at: NSPoint(x: 504, y: 34))
                        for _ in 0..<200 where model.isManaging || model.uploadQueue.first?.state != .completed { try await Task.sleep(for: .milliseconds(5)) }
                        XCTAssertEqual(model.uploadQueue.first?.state, .completed)
                        let calls = await service.commands; XCTAssertEqual(calls.count, 1)
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test预览直接操作中英浅深色菜单打开表单并固定当前照片() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for personContext in [false, true] {
                    let service = DatePhotoServiceStub(); await service.enableManagement()
                    let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh()
                    if personContext {
                        await model.selectSection(.albums); await model.openCategory(.person)
                        await model.open(try XCTUnwrap(model.collections.first))
                    }
                    let photo = try XCTUnwrap(model.items.first), other = try XCTUnwrap(model.items.last)
                    model.showPreview(photo); model.toggleSelection(other)
                    let person = model.selectedCategoryItem
                    let host = NSHostingView(rootView: SynologyPhotoPreview(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1040, height: 720))
                    defer { model.closePreview(); window.contentView = nil; window.close() }
                    try await settle(host); window.makeKeyAndOrderFront(nil)
                    try snapshot(host, name: "photos-preview-actions-before-\(personContext)-\(language.rawValue)-\(scheme)")
                    let kind: PhotoManagementKind = personContext ? .personCover : .rating
                    let chosen = expectation(description: "预览更多菜单打开编辑表单")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let tracked = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = tracked else { return }
                            DispatchQueue.main.async {
                                for expected in [PhotoManagementKind.addAlbum, .createAlbum, .rating, .description, .date, .shiftDates, .tagsCreate, .tagsAdd, .tagsRemove, .move, .copy] {
                                    let item = menu.item(withTitle: expected.title)
                                    XCTAssertNotNil(item, expected.rawValue); XCTAssertEqual(item?.isEnabled, true, expected.rawValue)
                                }
                                XCTAssertEqual(menu.item(withTitle: PhotoManagementKind.removeAlbum.title)?.isEnabled, false)
                                XCTAssertEqual(menu.item(withTitle: PhotoManagementKind.cover.title)?.isEnabled, false)
                                for expected in [PhotoManagementKind.removeFaces, .reassignFaces, .personCover] {
                                    XCTAssertEqual(menu.item(withTitle: expected.title)?.isEnabled, personContext ? true : nil)
                                }
                                let index = menu.indexOfItem(withTitle: kind.title)
                                XCTAssertGreaterThanOrEqual(index, 0); menu.cancelTrackingWithoutAnimation()
                                if index >= 0 { menu.performActionForItem(at: index) }; chosen.fulfill()
                            }
                        }
                    }
                    // 同尺寸合成截图中“更多”按钮位于分享按钮左侧。
                    try click(window, at: NSPoint(x: 820, y: 686)); await fulfillment(of: [chosen], timeout: 2)
                    NotificationCenter.default.removeObserver(observer); try await settle(host)
                    let sheet = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
                    try snapshot(content, name: "photos-preview-actions-confirm-\(personContext)-\(language.rawValue)-\(scheme)")
                    let before = await service.managementCommands; XCTAssertTrue(before.isEmpty)
                    model.clearSelection(); model.toggleSelection(other)
                    sheet.makeKeyAndOrderFront(nil); try await settle(content)
                    XCTAssertTrue(model.canEditSelection([photo], supportsMixedSpaces: false))
                    let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    if language == .english { try click(sheet, at: NSPoint(x: 490, y: 32)) }
                    else if !sheet.performKeyEquivalent(with: enter) { sheet.sendEvent(enter) }
                    try await settle(host)
                    for _ in 0..<200 where model.isManaging { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertFalse(model.isManaging)
                    let commands = await service.managementCommands
                    let expected: SynologyPhotosMutation = personContext ? .setPersonCover(person: try XCTUnwrap(person), photo: photo) : .edit([photo], .rating(0))
                    XCTAssertEqual(commands, [expected]); XCTAssertNil(window.attachedSheet)
                    XCTAssertEqual(model.selectedPhotoIDs, [other.id])
                }
            }
        }
    }

    func test预览重建工具栏中英浅深色显示并打开确认() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = DatePhotoServiceStub(); await service.enableManagement(); await service.enablePreviewDetails(); await service.setPreviewFixture(data)
                let model = SynologyPhotosModel(repository: service)
                await model.refresh()
                let photo = try XCTUnwrap(model.items.first); model.showPreview(photo)
                for _ in 0..<100 where model.isPreparingPreview { try await Task.sleep(for: .milliseconds(2)) }
                let host = NSHostingView(rootView: SynologyPhotoPreview(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1040, height: 720))
                defer { model.closePreview(); window.contentView = nil; window.close() }
                try await settle(host)
                XCTAssertTrue(model.canRegeneratePreviews([photo])); XCTAssertNotNil(model.previewData)
                try snapshot(host, name: "photos-preview-role-toolbar-\(language.rawValue)-\(scheme)")
                let before = await service.managementCommands; XCTAssertTrue(before.isEmpty)
                // 实际入口点击位置由同尺寸的合成截图核对。
                window.makeKeyAndOrderFront(nil)
                try click(window, at: NSPoint(x: 913, y: 686)); try await settle(host)
                let sheet = try XCTUnwrap(window.attachedSheet)
                let content = try XCTUnwrap(sheet.contentView)
                try snapshot(content, name: "photos-preview-role-confirm-\(language.rawValue)-\(scheme)")
                let after = await service.managementCommands; XCTAssertTrue(after.isEmpty)
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                if !sheet.performKeyEquivalent(with: escape) { sheet.sendEvent(escape) }
                try await settle(host)
                XCTAssertNil(window.attachedSheet)
                let cancelled = await service.managementCommands; XCTAssertTrue(cancelled.isEmpty)
            }
        }
    }

    func test预览重建中英浅深色确认只提交打开表单时的选择() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = DatePhotoServiceStub()
                await service.enableManagement()
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
                let photo = try XCTUnwrap(model.items.first)
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
                    sheet: .init(kind: .regeneratePreviews, photos: [photo])).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 560, height: 470))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                try snapshot(host, name: "photos-preview-rebuild-\(language.rawValue)-\(scheme)")
                let initial = await service.managementWriteCount
                XCTAssertEqual(initial, 0)
                model.clearSelection(); window.makeKeyAndOrderFront(nil)
                let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                try await settle(host)
                let commands = await service.managementCommands
                XCTAssertEqual(commands, [.regeneratePreviews([photo])])
                XCTAssertEqual(model.selectedTimelineMonthID, 201408)
            }
        }
    }

    func test人脸编辑居中新增填写姓名回车保存含裁剪图() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        for space in SynologyPhotoSpace.allCases {
        let service = DatePhotoServiceStub(space: space)
        await service.configureRequestAccess(spaces: [space], manager: space == .shared)
        await service.enableManagement(); await service.configureFaces(empty: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let photo = try XCTUnwrap(model.items.first)
        let host = NSHostingView(rootView: PhotoFaceEditor(model: model, target: .init(photo: photo, data: data)))
        let window = attach(host, size: NSSize(width: 1040, height: 720))
        defer { window.contentView = nil; window.close() }
        try await settle(host); window.makeKeyAndOrderFront(nil)
        try click(window, at: NSPoint(x: 850, y: 94))
        try await settle(host)
        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.people.name") })
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        editor.insertText("Synthetic person", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        try await settle(host)
        try snapshot(host, name: "photos-manual-face-center-before-save-\(space.rawValue)")
        let initial = await service.managementCommands
        XCTAssertTrue(initial.isEmpty)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
        try await settle(host)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 1)
        guard case .editPhotoFaces(let savedPhoto, let changes) = commands.first, case .add(let face) = changes.first else { return XCTFail("应提交完整人脸保存") }
        XCTAssertEqual(savedPhoto.id.space, space); XCTAssertEqual(commands.first?.space, space)
        let readSpaces = await service.peopleReadSpaces; XCTAssertEqual(readSpaces, [space])
        XCTAssertEqual(savedPhoto.id, photo.id); XCTAssertEqual(changes.count, 1); XCTAssertEqual(face.name, "Synthetic person")
        let jpeg = try XCTUnwrap(NSBitmapImageRep(data: face.jpeg))
        XCTAssertLessThanOrEqual(max(jpeg.pixelsWide, jpeg.pixelsHigh), 256)
        XCTAssertEqual(face.bounds.width * 640, face.bounds.height * 480, accuracy: 0.001)
        }
    }

    func test图片内人脸编辑中英浅深色正常空错误布局不提前写入() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["normal", "empty", "error"] {
                    let service = DatePhotoServiceStub()
                    await service.enableManagement(); await service.configureFaces(empty: mode == "empty"); await service.configurePeople(fails: mode == "error")
                    let model = SynologyPhotosModel(repository: service)
                    await model.refresh()
                    let photo = try XCTUnwrap(model.items.first)
                    let host = NSHostingView(rootView: PhotoFaceEditor(model: model, target: .init(photo: photo, data: data)).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 1040, height: 720))
                    try await settle(host)
                    try snapshot(host, name: "photos-manual-face-\(language.rawValue)-\(scheme)-\(mode)")
                    let writes = await service.managementWriteCount
                    XCTAssertEqual(writes, 0); XCTAssertEqual(host.bounds.size, NSSize(width: 1040, height: 720))
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test主题封面和误分类移出双语浅深色确认与错误恢复() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["cover", "remove", "error"] {
                    let service = DatePhotoServiceStub()
                    await service.enableManagement(); await service.configureConcepts(count: 2)
                    let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh(); await model.selectSection(.albums); await model.openCategory(.concept)
                    await model.open(try XCTUnwrap(model.collections.first))
                    await model.jumpToMonth(try XCTUnwrap(model.timelineMonths.last))
                    let concept = try XCTUnwrap(model.selectedCategoryItem), photo = try XCTUnwrap(model.items.first), month = model.selectedTimelineMonthID
                    if mode == "error" { await service.configureConcepts(fails: true) }
                    let kind: PhotoManagementKind = mode == "cover" ? .conceptCover : .removeConceptItems
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
                        sheet: .init(kind: kind, photos: [photo], concept: concept)).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 470))
                    try await settle(host)
                    try snapshot(host, name: "photos-concept-management-\(language)-\(scheme)-\(mode)")
                    let initial = await service.managementCommands
                    XCTAssertTrue(initial.isEmpty); XCTAssertEqual(host.bounds.size, NSSize(width: 560, height: 470))
                    if mode != "error" {
                        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                        try await settle(host)
                        let commands = await service.managementCommands
                        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands.first?.photos.map(\.id), [photo.id])
                        XCTAssertEqual(model.selectedTimelineMonthID, month)
                        if mode == "cover" { XCTAssertEqual(model.selectedCategoryItem?.thumbnail?.unitID, photo.id.unitID) }
                        else { XCTAssertFalse(model.items.contains { $0.id == photo.id }) }
                        XCTAssertTrue(model.collections.isEmpty)
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test主题显示隐藏中英浅深色正常空错误和搜索确认() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["normal", "empty", "error"] {
                    let service = DatePhotoServiceStub()
                    await service.enableManagement()
                    let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh(); await model.openCategory(.concept)
                    let concept = try XCTUnwrap(model.collections.first)
                    await service.configureConcepts(empty: mode == "empty", fails: mode == "error")
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
                        sheet: .init(kind: .conceptVisibility, photos: [], concept: concept)).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 660))
                    try await settle(host)
                    try snapshot(host, name: "photos-concepts-\(language)-\(scheme)-\(mode)")
                    let initial = await service.managementCommands
                    XCTAssertTrue(initial.isEmpty); XCTAssertEqual(host.bounds.size, NSSize(width: 680, height: 660))
                    if mode == "normal" {
                        window.makeKeyAndOrderFront(nil)
                        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.concepts.search") })
                        window.makeFirstResponder(field)
                        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                        editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0))
                        try await settle(host)
                        try snapshot(host, name: "photos-concepts-\(language)-\(scheme)-search-empty")
                        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
                        window.makeFirstResponder(nil); try await settle(host)
                        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                        try await settle(host)
                        let commands = await service.managementCommands
                        XCTAssertEqual(commands.count, 1)
                        guard case .setConceptVisibility(let originals, let visible) = commands.first else { return XCTFail("必须提交主题显示操作") }
                        XCTAssertEqual(originals.map(\.id), [concept.id]); XCTAssertFalse(visible)
                        XCTAssertFalse(model.collections.contains { $0.id == concept.id })
                    }
                    window.contentView = nil; window.close()
                }
            }
        }
    }

    func test人物显示隐藏表单正常空错误浅深色布局不提前写入() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in ["normal", "empty", "error"] {
                let service = DatePhotoServiceStub()
                await service.enableManagement()
                await service.configurePeople(empty: mode == "empty", fails: mode == "error")
                let model = SynologyPhotosModel(repository: service)
                await model.refresh()
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
                    sheet: .init(kind: .peopleVisibility, photos: [])).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 680, height: 660))
                try await settle(host)
                try snapshot(host, name: "photos-people-visibility-\(mode)-\(scheme)")
                XCTAssertEqual(host.bounds.size, NSSize(width: 680, height: 660))
                let writes = await service.managementWriteCount
                XCTAssertEqual(writes, 0)
                window.contentView = nil; window.close()
            }
        }
    }

    func test人物显示搜索空状态保留选择并回车只隐藏目标() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.openCategory(.person)
        let person = try XCTUnwrap(model.collections.first)
        let host = NSHostingView(rootView: PhotoManagementPanel(model: model,
            sheet: .init(kind: .peopleVisibility, photos: [], person: person)))
        let window = attach(host, size: NSSize(width: 680, height: 660))
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        window.makeKeyAndOrderFront(nil)
        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.people.search") })
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle(host)
        try snapshot(host, name: "photos-people-visibility-search-empty")
        let initial = await service.managementCommands
        XCTAssertTrue(initial.isEmpty)
        editor.selectAll(nil); editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(nil)
        try await settle(host)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
        try await settle(host)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 1)
        guard case .setPeopleVisibility(let originals, let visible) = commands.first else { return XCTFail("必须提交人物显示操作") }
        XCTAssertEqual(originals.map(\.id), [person.id]); XCTAssertFalse(visible)
        XCTAssertFalse(model.collections.contains { $0.id == person.id })
    }

    func test人脸选择纠正封面和空错误浅深色布局不提前写入() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in ["remove", "reassign", "cover", "empty", "error"] {
                let service = DatePhotoServiceStub()
                await service.enableManagement()
                await service.configurePeople(fails: mode == "error")
                await service.configureFaces(empty: mode == "empty")
                let model = SynologyPhotosModel(repository: service)
                await model.refresh()
                let photos = mode == "cover" ? Array(model.items.prefix(1)) : model.items
                let kind: PhotoManagementKind = mode == "cover" ? .personCover : mode == "reassign" ? .reassignFaces : .removeFaces
                let sheet = PhotoManagementSheet(kind: kind, photos: photos, person: .init(id: 31, name: "Fixture person", itemCount: 2))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let size = mode == "cover" ? NSSize(width: 560, height: 470) : NSSize(width: 680, height: 660)
                let window = attach(host, size: size)
                try await settle(host)
                try snapshot(host, name: "photos-faces-\(mode)-\(scheme)")
                let writes = await service.managementWriteCount
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(host.bounds.size, size)
                window.contentView = nil; window.close()
            }
        }
    }

    func test人脸窗口取消一张后回车只提交其余人脸() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let photos = model.items
        XCTAssertGreaterThan(photos.count, 1)
        let sheet = PhotoManagementSheet(kind: .removeFaces, photos: photos, person: .init(id: 31, name: "Fixture person", itemCount: 6))
        let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(.light))
        let window = attach(host, size: NSSize(width: 680, height: 660))
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        window.makeKeyAndOrderFront(nil)
        try click(window, at: NSPoint(x: 44, y: 371))
        try await settle(host)
        try snapshot(host, name: "photos-faces-after-uncheck")
        let initial = await service.managementCommands
        XCTAssertTrue(initial.isEmpty)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }

        try await settle(host)
        try snapshot(host, name: "photos-faces-after-submit")
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 1)
        guard case .removePersonFaces(let person, let faces) = commands.first else { return XCTFail("应提交人脸移出命令") }
        XCTAssertEqual(person.id, 31)
        XCTAssertEqual(faces.map { $0.photo.id }, photos.dropFirst().map(\.id))
        XCTAssertEqual(faces.map(\.id), photos.dropFirst().map { $0.id.unitID + 70 })
    }

    func test人物命名合并空列表和错误浅深色布局() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in ["rename", "merge", "empty", "error"] {
                let repository = DatePhotoServiceStub()
                await repository.enableManagement()
                await repository.configurePeople(empty: mode == "empty", fails: mode == "error")
                let model = SynologyPhotosModel(repository: repository)
                await model.refresh()
                let sheet = PhotoManagementSheet(kind: mode == "rename" ? .renamePerson : .mergePeople, photos: [], person: .init(id: 31, name: "Fixture person", itemCount: 2))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let size = mode == "rename" ? NSSize(width: 560, height: 470) : NSSize(width: 680, height: 660)
                let window = attach(host, size: size)
                try await settle(host)
                try snapshot(host, name: "photos-people-\(mode)-\(scheme)")
                let writes = await repository.managementWriteCount
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(host.bounds.size, size)
                window.contentView = nil; window.close()
            }
        }
    }

    func test条件相册来源中英浅深色切换并按来源读取() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let repository = PhotoUploadServiceStub()
                await repository.setSpaces([.personal, .shared]); await repository.setConditionSpace(.shared)
                let model = SynologyPhotosModel(repository: repository); await model.refresh()
                let sheet = PhotoManagementSheet(kind: .editConditionAlbum, photos: [], album: .init(id: 21, name: "Fixture rule album", isConditional: true))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 680, height: 660))
                try await settle(host)
                let shared = L10n.string("shared.17d2e16862f16829"), personal = L10n.string("shared.51fcaa8035fc61e2")
                window.makeKeyAndOrderFront(nil)
                try snapshot(host, name: "photos-condition-source-\(language.rawValue)-\(scheme)")
                for title in [personal, shared] {
                    let selected = expectation(description: "切换条件照片来源")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                        nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
                        MainActor.assumeIsolated {
                            guard let menu = trackedMenu else { return }
                            DispatchQueue.main.async {
                                let index = menu.indexOfItem(withTitle: title)
                                menu.cancelTrackingWithoutAnimation()
                                if index >= 0 { menu.performActionForItem(at: index) }
                                XCTAssertGreaterThanOrEqual(index, 0)
                                selected.fulfill()
                            }
                        }
                    }
                    try click(window, at: NSPoint(x: 145, y: 535))
                    await fulfillment(of: [selected], timeout: 2)
                    NotificationCenter.default.removeObserver(observer)
                    try await settle(host)
                }
                let reads = await repository.conditionSuggestionSpaces
                XCTAssertEqual(reads, [.shared, .personal, .shared])
                let folders = await repository.conditionFolderSpaces
                XCTAssertEqual(folders, [.shared, .personal, .shared])
                let before = await repository.commands; XCTAssertTrue(before.isEmpty)
                // 来回切换后回车沿既有保存语义提交，规则必须完整恢复，不能提交空草稿。
                let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                try await settle(host)
                let writes = await repository.commands
                XCTAssertEqual(writes.count, 1)
                guard case .setAlbumCondition(let id, let originalCondition, let condition) = writes.first else { return XCTFail("应保存完整条件") }
                XCTAssertEqual(id, 21); XCTAssertEqual(condition, originalCondition); XCTAssertEqual(condition.sourceSpace, .shared)
                XCTAssertEqual(condition.values("general_tag"), [.integer(8)])
                window.contentView = nil; window.close()
            }
        }
    }

    func test条件相册表单创建编辑错误浅深色布局() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in ["create", "edit", "error"] {
                let repository = PhotoUploadServiceStub()
                if mode == "error" { await repository.failConditionRead() }
                let model = SynologyPhotosModel(repository: repository)
                await model.refresh()
                let sheet = PhotoManagementSheet(kind: mode == "create" ? .createConditionAlbum : .editConditionAlbum, photos: [],
                    album: mode == "create" ? nil : .init(id: 21, name: "Fixture rule album", isConditional: true))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 680, height: 660))
                try await settle(host)
                try snapshot(host, name: "photos-condition-\(mode)-\(scheme)")
                XCTAssertEqual(host.bounds.size.width, 680, accuracy: 1)
                XCTAssertEqual(host.bounds.size.height, 660, accuracy: 1)
                let writes = await repository.commands
                XCTAssertTrue(writes.isEmpty, "打开和读取条件不能修改相册")
                window.contentView = nil; window.close()
            }
        }
    }

    func test目录上传确认浅深色布局() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("Fixture folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Fixture-photo.png", "Fixture-video.mov", "Fixture-notes.txt"] {
            try Data(repeating: 0, count: 128).write(to: nested.appendingPathComponent(name))
        }
        let prepared = try PhotoUploadPreparation.prepare([directory])
        XCTAssertEqual(prepared.files.count, 2)
        XCTAssertEqual(prepared.skippedCount, 1)
        for scheme in [ColorScheme.light, .dark] {
            let repository = PhotoUploadServiceStub()
            let model = SynologyPhotosModel(repository: repository, deletionReviewDelay: { _ in })
            await model.refresh()
            let sheet = PhotoManagementSheet(kind: .upload, photos: [], files: [directory])
            let form = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
            let window = attach(form, size: NSSize(width: 560, height: 470))
            try await settle(form)
            try snapshot(form, name: "photos-directory-upload-\(scheme)")
            let writes = await repository.commands.count
            XCTAssertEqual(writes, 0)
            window.contentView = nil; window.close()
        }
    }

    func test上传任务后续操作中英浅深色完成错误和空队列() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await service.setAlbumAccess(.init(albumID: 30, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
                await model.refresh()
                let file = PhotoUploadFile(url: URL(fileURLWithPath: "/synthetic/Fixture-photo.png"), size: 128, modifiedAt: .distantPast)
                model.enqueueUploads([file], album: .init(id: 30, name: "Fixture album"), folder: nil)
                for _ in 0..<2000 where model.isManaging { await Task.yield() }
                XCTAssertEqual(model.uploadQueue.first?.state, .completed)
                var host = NSHostingView(rootView: PhotoUploadQueuePanel(model: model).preferredColorScheme(scheme))
                var window = attach(host, size: NSSize(width: 620, height: 480))
                defer { window.contentView = nil; window.close(); model.cancel() }
                try await settle(host); window.makeKeyAndOrderFront(nil)
                try snapshot(host, name: "photos-upload-actions-completed-\(language.rawValue)-\(scheme)")
                try click(window, at: NSPoint(x: 70, y: 324)); try await settle(host)
                XCTAssertNotNil(model.uploadNavigationError); XCTAssertEqual(model.section, .timeline)
                try await settle(host); try snapshot(host, name: "photos-upload-actions-error-\(language.rawValue)-\(scheme)")
                await service.addFolder(.init(id: 9, name: "Fixture folder", parentID: 1, path: "/Fixture folder"))
                await service.addFolder(.init(id: 1, name: "/", parentID: 0, path: "/"))
                try click(window, at: NSPoint(x: 70, y: 324)); try await settle(host)
                XCTAssertEqual(model.folderHistory.map(\.id), [1, 9]); XCTAssertNil(model.uploadNavigationError)
                // 成功导航会关闭任务窗口，后续操作按用户重新打开队列的路径验证。
                window.contentView = nil; window.close()
                host = NSHostingView(rootView: PhotoUploadQueuePanel(model: model).preferredColorScheme(scheme))
                window = attach(host, size: NSSize(width: 620, height: 480))
                try await settle(host); window.makeKeyAndOrderFront(nil)
                try click(window, at: NSPoint(x: 170, y: 324)); try await settle(host)
                XCTAssertEqual(model.selectedAlbum?.id, 30)
                // 成功导航会关闭任务窗口，后续操作按用户重新打开队列的路径验证。
                window.contentView = nil; window.close()
                host = NSHostingView(rootView: PhotoUploadQueuePanel(model: model).preferredColorScheme(scheme))
                window = attach(host, size: NSSize(width: 620, height: 480))
                try await settle(host); window.makeKeyAndOrderFront(nil)
                try click(window, at: NSPoint(x: 550, y: 324))
                try await settle(host); XCTAssertTrue(model.uploadQueue.isEmpty)
                try snapshot(host, name: "photos-upload-actions-empty-\(language.rawValue)-\(scheme)")
                let commands = await service.commands.count; XCTAssertEqual(commands, 2, "导航和移除任务记录不写NAS")
            }
        }
    }

    func test多文件上传确认与队列浅深色布局() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["Fixture-blue.png", "Fixture-red.png"].map { directory.appendingPathComponent($0) }
        for file in files { try Data(repeating: 0, count: 128).write(to: file) }
        for scheme in [ColorScheme.light, .dark] {
            let repository = PhotoUploadServiceStub()
            let model = SynologyPhotosModel(repository: repository, deletionReviewDelay: { _ in })
            await model.refresh()
            let album = SynologyPhotoCollection(id: 30, name: "Fixture album")
            let sheet = PhotoManagementSheet(kind: .upload, photos: [], album: album, files: files)
            let form = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
            let formWindow = attach(form, size: NSSize(width: 560, height: 470))
            try await settle(form)
            try snapshot(form, name: "photos-upload-confirm-\(scheme)")
            let writes = await repository.commands.count
            XCTAssertEqual(writes, 0, "打开多选上传确认不能提前上传")
            formWindow.contentView = nil; formWindow.close()
            await repository.makeFirstUploadPending()
            let snapshots = try files.map { file in
                PhotoUploadFile(url: file, size: 128, modifiedAt: try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
            }
            model.enqueueUploads(snapshots, album: album, folder: nil)
            for _ in 0..<2000 where model.isManaging { await Task.yield() }
            XCTAssertEqual(model.uploadQueue.map(\.state), [.pendingReview, .queued])
            let queue = NSHostingView(rootView: PhotoUploadQueuePanel(model: model).preferredColorScheme(scheme))
            let queueWindow = attach(queue, size: NSSize(width: 620, height: 480))
            try await settle(queue)
            try snapshot(queue, name: "photos-upload-queue-\(scheme)")
            XCTAssertEqual(queue.bounds.width, 620, accuracy: 1)
            XCTAssertEqual(queue.bounds.height, 480, accuracy: 1)
            queueWindow.contentView = nil; queueWindow.close()
        }
    }

    func test分享窗口读取现状与错误浅深色布局且不写入() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in ["disabled", "invited", "download", "error", "membersError", "empty", "uploadRole", "noExpiration", "unknownExpiration", "expired"] {
                let repository = DatePhotoServiceStub()
                await repository.enableManagement()
                await repository.configureSharing(mode == "invited" ? .invited : mode == "disabled" ? .disabled : .download, fails: mode == "error", role: mode == "uploadRole" ? "upload" : "view", recipientsFail: mode == "membersError", empty: mode == "empty", expiration: mode == "unknownExpiration" ? nil : mode == "noExpiration" ? 0 : mode == "expired" ? 100 : 2_000_000_000)
                let model = SynologyPhotosModel(repository: repository)
                await model.refresh()
                let sheet = PhotoManagementSheet(kind: .sharing, photos: [], album: .init(id: 3, name: "Fixture album"))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let size = sheet.kind == .sharing ? NSSize(width: 680, height: 660) : NSSize(width: 560, height: 470)
                let window = attach(host, size: size)
                try await settle(host)
                try snapshot(host, name: "photos-sharing-\(mode)-\(scheme)")
                let writes = await repository.managementWriteCount
                XCTAssertEqual(writes, 0)
                window.contentView = nil; window.close()
            }
        }
    }

    func test共享收集默认目录和成员选目录中英浅深色确认() async throws {
        let original = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = original }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for mode in ["manager", "entry", "selected", "personalFirst"] {
                    let service = DatePhotoServiceStub(space: .shared)
                    await service.enableManagement()
                    await service.configureRequestAccess(spaces: mode == "personalFirst" ? [.shared, .personal] : [.shared], manager: mode == "manager")
                    let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                    await model.refresh()
                    let sheet = PhotoManagementSheet(kind: .createRequest, photos: [],
                        folder: mode == "selected" ? .init(id: 9, name: "Sample", path: "/Sample") : nil, space: .shared)
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 660))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "photos-request-destination-\(mode)-\(language.rawValue)-\(scheme)")
                    let before = await service.managementWriteCount
                    XCTAssertEqual(before, 0)
                    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
                    let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                    if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                    try await settle(host)
                    let commands = await service.managementCommands
                    if mode == "entry" {
                        XCTAssertTrue(commands.isEmpty, "未选择目录不能发送无权创建的默认路径")
                        try click(window, at: NSPoint(x: 100, y: 318))
                        try await settle(host)
                        try click(window, at: NSPoint(x: 320, y: 210))
                        try await settle(host)
                        if !window.performKeyEquivalent(with: enter) { window.sendEvent(enter) }
                        try await settle(host)
                        let selectedCommands = await service.managementCommands
                        XCTAssertEqual(selectedCommands.count, 1)
                        guard case .createPhotoRequest(let settings) = selectedCommands.first else { return XCTFail("成员选定目录后应可创建") }
                        XCTAssertEqual(settings.space, .shared)
                        XCTAssertEqual(settings.folderID, 9)
                        XCTAssertEqual(settings.folderPath, "/Sample")
                    } else {
                        XCTAssertEqual(commands.count, 1)
                        guard case .createPhotoRequest(let settings) = commands.first else { return XCTFail("确认后应创建照片收集") }
                        XCTAssertEqual(settings.space, mode == "personalFirst" ? .personal : .shared)
                        XCTAssertEqual(settings.folderID, mode == "selected" ? 9 : nil)
                        XCTAssertEqual(settings.folderPath, mode == "selected" ? "/Sample" : SynologyPhotoRequestSettings.defaultFolderPath(subject: settings.subject))
                    }
                }
            }
        }
    }

    func test照片收集创建编辑删除和错误浅深色布局不提前写入() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in ["create", "folder", "album", "edit", "delete", "error", "albumError", "invalidFolder", "shared"] {
                let repository = DatePhotoServiceStub(space: mode == "shared" ? .shared : .personal)
                await repository.enableManagement()
                await repository.configureRequests(fails: mode == "error", albumsFail: mode == "albumError", invalidFolder: mode == "invalidFolder")
                let model = SynologyPhotosModel(repository: repository)
                await model.refresh()
                let kind: PhotoManagementKind = ["create", "folder", "album"].contains(mode) ? .createRequest : mode == "delete" ? .deleteRequest : .editRequest
                let sheet = PhotoManagementSheet(kind: kind, photos: [],
                    album: mode == "album" ? .init(id: 3, name: "Fixture private album") : nil,
                    folder: mode == "folder" ? .init(id: 9, name: "Sample", path: "/Sample") : nil,
                    requestID: kind == .createRequest ? nil : "fixture-request")
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 680, height: 660))
                try await settle(host)
                try snapshot(host, name: "photos-request-\(mode)-\(scheme)")
                XCTAssertEqual(host.bounds.size, NSSize(width: 680, height: 660))
                let writes = await repository.managementWriteCount
                XCTAssertEqual(writes, 0)
                window.contentView = nil; window.close()
            }
        }
    }

    func test照片收集搜索跨页自动加载及空错误浅深色布局() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let repository = DatePhotoServiceStub()
            await repository.enableManagement()
            await repository.configureRequestTitles(["First request", "Second request", "Trip request"])
            let model = SynologyPhotosModel(repository: repository, pageSize: 2)
            await model.selectShareScope(.requests)
            await model.selectSection(.sharing)
            model.requestSearchText = "Trip"
            let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                .environment(MacAppearanceStore()).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 1180, height: 780))
            try await settle(host)
            XCTAssertEqual(model.visibleSharedEntries.map(\.title), ["Trip request"])
            XCTAssertFalse(model.hasMoreCollections)
            try snapshot(host, name: "photos-request-search-\(scheme)")
            model.requestSearchText = "No match"
            try await settle(host)
            try snapshot(host, name: "photos-request-no-results-\(scheme)")
            model.requestSearchText = ""
            await repository.configureRequestTitles([])
            await model.refresh()
            try await settle(host)
            try snapshot(host, name: "photos-request-empty-\(scheme)")
            await repository.configureRequests(fails: true)
            await model.refresh()
            try await settle(host)
            XCTAssertNotNil(model.errorMessage)
            try snapshot(host, name: "photos-request-list-error-\(scheme)")
            let writes = await repository.managementWriteCount
            XCTAssertEqual(writes, 0)
            window.contentView = nil; window.close()
        }
    }

    func test临时分享停止确认双语浅深色保留副本及取消() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for action in ["stop", "keep", "cancel"] {
                    let repository = DatePhotoServiceStub(); await repository.enableManagement(); await repository.configureTemporarySharing()
                    let model = SynologyPhotosModel(repository: repository, deletionReviewDelay: { _ in }); await model.refresh()
                    let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: .init(kind: .sharing, photos: [], album: .init(id: 9, name: "Synthetic temporary share")))
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 680, height: 660)); try await settle(host)
                    defer { if let alert = window.attachedSheet { window.endSheet(alert) }; window.contentView = nil; window.close() }
                    window.makeKeyAndOrderFront(nil)
                    try click(window, at: NSPoint(x: 140, y: 539)); try await settle(host)
                    try snapshot(host, name: "photos-temporary-stop-settings-\(action)-\(language)-\(scheme)")
                    try click(window, at: NSPoint(x: 610, y: 32)); try await settle(host)
                    let alert = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(alert.contentView)
                    try snapshot(content, name: "photos-temporary-stop-confirm-\(action)-\(language)-\(scheme)")
                    let key = action == "cancel" ? "photos.delete.cancel" : (action == "keep" ? "photos.temporary.keep" : "photos.temporary.stop")
                    let button = try XCTUnwrap(nativeViews(content, of: NSButton.self).first { $0.title == L10n.string(key) })
                    let before = await repository.managementCommands; XCTAssertTrue(before.isEmpty)
                    button.performClick(nil); try await settle(host)
                    let commands = await repository.managementCommands
                    XCTAssertEqual(commands.count, action == "cancel" ? 0 : (action == "keep" ? 3 : 2))
                    if action != "cancel" {
                        guard case .deleteTemporaryAlbum(9, _, let copy) = commands.last else { return XCTFail("只清理目标临时相册") }
                        XCTAssertEqual(copy, action == "keep" ? 10 : nil)
                        XCTAssertFalse(model.hasTemporarySharingCleanup)
                    }
                }
            }
        }
    }

    func test临时分享创建窗口关闭及设置窗口Esc自动清理() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for pending in [true, false] {
                    let repository = DatePhotoServiceStub(); await repository.enableManagement(pending: pending)
                    let model = SynologyPhotosModel(repository: repository, deletionReviewDelay: { _ in }); await model.refresh()
                    let host = NSHostingView(rootView: PhotoSelectionSharingPanel(model: model, photos: Array(model.items.prefix(2)))
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 580, height: 330)); try await settle(host)
                    defer { window.contentView = nil; window.close() }
                    window.makeKeyAndOrderFront(nil)
                    let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.manage.albumName") })
                    window.makeFirstResponder(field)
                    let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                    editor.insertText("Synthetic temporary share", replacementRange: NSRange(location: NSNotFound, length: 0))
                    window.makeFirstResponder(nil); try await settle(host)
                    try click(window, at: NSPoint(x: 465, y: 32)); try await settle(host)
                    if pending {
                        XCTAssertNotNil(model.pendingMutationID)
                        try snapshot(host, name: "photos-temporary-cancel-pending-\(language)-\(scheme)")
                        try click(window, at: NSPoint(x: 550, y: 300)); try await settle(host)
                        await repository.enableManagement(); model.reviewPendingMutation()
                    } else {
                        window.setContentSize(NSSize(width: 680, height: 660)); try await settle(host)
                        try snapshot(host, name: "photos-temporary-cancel-settings-\(language)-\(scheme)")
                        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                        if !window.performKeyEquivalent(with: escape) { window.sendEvent(escape) }
                    }
                    try await settle(host)
                    XCTAssertFalse(model.hasTemporarySharingCleanup); XCTAssertNil(model.pendingMutationID)
                    let commands = await repository.managementCommands; XCTAssertEqual(commands.count, 3)
                    guard case .deleteTemporaryAlbum(9, _, nil) = commands.last else { return XCTFail("关闭后不保留临时相册，也不重复创建") }
                }
            }
        }
    }

    func test选片直接分享中英浅深色预检失败重试待核对及同窗分享() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
              for space in [SynologyPhotoSpace.personal, .shared] {
                let repository = DatePhotoServiceStub(space: space)
                await repository.configureRequestAccess(spaces: [.personal, .shared], manager: true)
                await repository.limitSharingToPersonal()
                await repository.enableManagement(pending: true)
                await repository.configureSharing(.disabled, empty: true, expiration: 0)
                let model = SynologyPhotosModel(repository: repository, deletionReviewDelay: { _ in })
                await model.refresh(); await model.selectSpace(space); await model.jumpToMonth(.init(year: 2014, month: 8))
                let photos = Array(model.items.prefix(2))
                XCTAssertEqual(photos.count, 2)
                let ids = model.items.map(\.id), month = model.selectedTimelineMonthID
                let host = NSHostingView(rootView: PhotoSelectionSharingPanel(model: model, photos: photos).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 580, height: 330))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                let initial = await repository.managementCommands
                XCTAssertTrue(initial.isEmpty, "打开窗口不创建相册或公开照片")
                try snapshot(host, name: "photos-selection-share-initial-\(language)-\(scheme)-\(space)")
                window.makeKeyAndOrderFront(nil)
                let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.manage.albumName") })
                window.makeFirstResponder(field)
                let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                editor.selectAll(nil)
                editor.insertText("Synthetic selection", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await settle(host)
                await repository.failNextManagementPreparation()
                try click(window, at: NSPoint(x: 465, y: 32))
                try await settle(host)
                XCTAssertFalse(model.isManaging); XCTAssertNil(model.pendingMutationID)
                let failed = await repository.managementCommands
                XCTAssertTrue(failed.isEmpty)
                try snapshot(host, name: "photos-selection-share-failed-\(language)-\(scheme)-\(space)")
                try click(window, at: NSPoint(x: 465, y: 32))
                try await settle(host)
                XCTAssertNotNil(model.pendingMutationID)
                XCTAssertEqual(model.automaticMutationReviewID, model.pendingMutationID)
                let pending = await repository.managementCommands
                XCTAssertEqual(pending, [.createTemporaryAlbum(name: "Synthetic selection", photos: photos)])
                try snapshot(host, name: "photos-selection-share-pending-\(language)-\(scheme)-\(space)")
                try click(window, at: NSPoint(x: 465, y: 32))
                await repository.enableManagement()
                model.reviewPendingMutation()
                try await settle(host)
                window.setContentSize(NSSize(width: 680, height: 660))
                try await settle(host)
                XCTAssertNil(model.pendingMutationID)
                XCTAssertTrue(nativeViews(host, of: NSTextField.self).filter(\.isEditable).allSatisfy { $0.placeholderString != L10n.string("photos.manage.albumName") }, "核对后直接进入同窗分享设置")
                let commands = await repository.managementCommands
                XCTAssertEqual(commands, [.createTemporaryAlbum(name: "Synthetic selection", photos: photos)], "读取分享设置不改变访问范围，待核对也不重复创建")
                XCTAssertEqual(model.items.map(\.id), ids); XCTAssertEqual(model.selectedTimelineMonthID, month)
                try snapshot(host, name: "photos-selection-share-settings-\(language)-\(scheme)-\(space)")
                window.makeFirstResponder(nil)
                try click(window, at: NSPoint(x: 200, y: 495))
                try await settle(host)
                try snapshot(host, name: "photos-selection-share-access-\(language)-\(scheme)-\(space)")
                try click(window, at: NSPoint(x: 610, y: 32))
                try await settle(host)
                let final = await repository.managementCommands
                XCTAssertEqual(final.count, 2)
                guard case .shareAlbum(let id, let access, let original, let members, let expiration, let password) = final.last else {
                    return XCTFail("最后确认才写入分享设置")
                }
                XCTAssertEqual(id, 9); XCTAssertEqual(access, .view); XCTAssertEqual(original?.access, .invited)
                XCTAssertNil(members); XCTAssertNil(expiration); XCTAssertNil(password)
                XCTAssertEqual(model.managementLink?.absoluteString, "https://example.invalid/share/fixture")
                XCTAssertEqual(model.items.map(\.id), ids); XCTAssertEqual(model.selectedTimelineMonthID, month)

              }
            }
        }
    }

    func test收集窗口回车新建相册后自动选中且不提前创建收集() async throws {
        let repository = DatePhotoServiceStub()
        await repository.enableManagement()
        let model = SynologyPhotosModel(repository: repository, deletionReviewDelay: { _ in })
        await model.refresh()
        let sheet = PhotoManagementSheet(kind: .createRequest, photos: [], album: .init(id: 3, name: "Fixture private album"))
        let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(.dark))
        let window = attach(host, size: NSSize(width: 680, height: 660))
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        window.makeKeyAndOrderFront(nil)
        try click(window, at: NSPoint(x: 24, y: 221))
        try await Task.sleep(for: .milliseconds(250))
        try await settle(host)
        try snapshot(host, name: "photos-request-new-album-expanded-dark")
        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("photos.manage.albumName") })
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Synthetic target", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(250))
        try await settle(host)
        let firstCommands = await repository.managementCommands
        XCTAssertEqual(firstCommands, [.createAlbum(name: "Synthetic target", photos: [])])
        try snapshot(host, name: "photos-request-new-album-selected-dark")
        try click(window, at: NSPoint(x: 555, y: 30))
        try await settle(host)
        let commands = await repository.managementCommands
        XCTAssertEqual(commands.count, 2)
        guard case .createPhotoRequest(let settings) = commands.last else { return XCTFail("确认后才创建收集") }
        XCTAssertEqual(settings.albumID, 9)
        XCTAssertNil(settings.albumPassphrase)
    }

    func test分享密码选择显示安全输入且不提前写入() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let repository = DatePhotoServiceStub()
            await repository.enableManagement()
            await repository.configureSharing(.download)
            let model = SynologyPhotosModel(repository: repository)
            await model.refresh()
            let sheet = PhotoManagementSheet(kind: .sharing, photos: [], album: .init(id: 3, name: "Fixture album"))
            let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 680, height: 660))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            XCTAssertTrue(nativeViews(host, of: NSSecureTextField.self).isEmpty)
            window.makeKeyAndOrderFront(nil)
            func selectPasswordOption(_ title: String) async throws {
                let selected = expectation(description: "选择密码操作")
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
                    // 通知限定主队列，AppKit菜单仅在主线程访问。
                    nonisolated(unsafe) let trackedMenu = notification.object as? NSMenu
                    MainActor.assumeIsolated {
                        guard let menu = trackedMenu else { return }
                        DispatchQueue.main.async {
                            let index = menu.indexOfItem(withTitle: title)
                            menu.cancelTrackingWithoutAnimation()
                            if index >= 0 { menu.performActionForItem(at: index) }
                            XCTAssertGreaterThanOrEqual(index, 0)
                            selected.fulfill()
                        }
                    }
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                try click(window, at: NSPoint(x: 170, y: 371))
                await fulfillment(of: [selected], timeout: 2)
            }
            try await selectPasswordOption(L10n.string("photos.sharing.passwordSet"))
            try await settle(host)
            XCTAssertEqual(nativeViews(host, of: NSSecureTextField.self).count, 1)
            try snapshot(host, name: "photos-sharing-password-new-\(scheme)")
            try await selectPasswordOption(L10n.string("photos.sharing.passwordRemove"))
            try await settle(host)
            XCTAssertTrue(nativeViews(host, of: NSSecureTextField.self).isEmpty)
            let writes = await repository.managementWriteCount
            XCTAssertEqual(writes, 0, "切换密码编辑选项不能提前修改分享")
        }
    }

    func test照片管理表单标题内容与操作区对齐() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let repository = DatePhotoServiceStub()
            await repository.enableManagement()
            let model = SynologyPhotosModel(repository: repository)
            await model.refresh()
            for kind in [PhotoManagementKind.rating, .createAlbum, .date, .shiftDates, .tagsCreate, .sharing, .cover] {
                let sheet = PhotoManagementSheet(kind: kind, photos: kind == .cover ? Array(model.items.prefix(1)) : model.items, album: .init(id: 3, name: "Fixture album"))
                let host = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
                let size = sheet.kind == .sharing ? NSSize(width: 680, height: 660) : NSSize(width: 560, height: 470)
                let window = attach(host, size: size)
                try await settle(host)
                try snapshot(host, name: "photos-management-\(kind.rawValue)-\(scheme)")
                XCTAssertEqual(host.bounds.size.width, size.width, accuracy: 1)
                XCTAssertEqual(host.bounds.size.height, size.height, accuracy: 1)
                window.contentView = nil; window.close()
            }
            let writes = await repository.managementWriteCount
            XCTAssertEqual(writes, 0, "仅打开表单不能发出修改或创建分享链接")
        }
    }

    func test共享照片批量管理和评级表单浅深色布局() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let service = DatePhotoServiceStub(space: .shared)
            await service.enableManagement()
            let model = SynologyPhotosModel(repository: service, pageSize: 6)
            await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
            model.selectGroup(Array(model.items.prefix(2)))
            let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                .environment(MacAppearanceStore()).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 1100, height: 720))
            try await settle(host)
            try snapshot(host, name: "photos-shared-management-\(scheme)")
            XCTAssertTrue(model.canManageSelection); XCTAssertTrue(model.canDeleteSelection)
            window.contentView = nil; window.close()
            let sheet = PhotoManagementSheet(kind: .rating, photos: model.selectedPhotos, space: .shared)
            let form = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
            let formWindow = attach(form, size: NSSize(width: 560, height: 470))
            try await settle(form)
            try snapshot(form, name: "photos-shared-rating-\(scheme)")
            formWindow.contentView = nil; formWindow.close()
            let writes = await service.managementWriteCount
            XCTAssertEqual(writes, 0, "打开共享管理表单不能修改照片")
        }
    }

    func test照片空间选择和共享上传目标浅深色布局() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let service = PhotoUploadServiceStub()
            await service.setSpaces([.personal, .shared])
            let model = SynologyPhotosModel(repository: service)
            await model.refresh()
            await model.selectSpace(.shared)
            let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                .environment(MacAppearanceStore()).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 1100, height: 720))
            try await settle(host)
            try snapshot(host, name: "photos-shared-space-\(scheme)")
            XCTAssertEqual(model.selectedSpace, .shared)
            XCTAssertEqual(host.bounds.width, 1100, accuracy: 1)
            window.contentView = nil; window.close()
            let sheet = PhotoManagementSheet(kind: .upload, photos: [], folder: .init(id: 9, name: "Fixture shared folder"), space: .shared)
            let form = NSHostingView(rootView: PhotoManagementPanel(model: model, sheet: sheet).preferredColorScheme(scheme))
            let formWindow = attach(form, size: NSSize(width: 560, height: 470))
            try await settle(form)
            try snapshot(form, name: "photos-shared-upload-\(scheme)")
            XCTAssertEqual(form.bounds.height, 470, accuracy: 1)
            formWindow.contentView = nil; formWindow.close()
            let commands = await service.commands
            XCTAssertTrue(commands.isEmpty, "仅查看空间和上传确认不能上传文件")
        }
    }

    func test照片长断线删除显示自动继续且不要求手动核对() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let repository = DatePhotoServiceStub(); await repository.failReviews(true)
                let model = SynologyPhotosModel(repository: repository, pageSize: 6, deletionReviewDelay: { seconds in
                    if seconds == 15 { try await Task.sleep(for: .seconds(60)) }
                })
                await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
                model.confirmDeletion(model.items[0])
                for _ in 0..<100 where model.isDeleting { try await Task.sleep(for: .milliseconds(5)) }
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1100, height: 720))
                defer { model.cancel(); window.contentView = nil; window.close() }
                try await settle(host)
                XCTAssertEqual(model.deletionMessage, L10n.string("photos.selection.reviewContinuing"))
                XCTAssertFalse(nativeViews(host, of: NSButton.self).contains { $0.title == L10n.string("photos.selection.retryReview") })
                XCTAssertEqual(model.selectedTimelineMonthID, 201408); XCTAssertFalse(model.isDeleting)
                try snapshot(host, name: "photos-delete-continuing-\(language.rawValue)-\(scheme)")
                let deletes = await repository.deleteIDs; XCTAssertEqual(deletes, [4])
            }
        }
    }

    func test照片月份跳转静置不触发向前加载且删除不回到最新月份() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let repository = DatePhotoServiceStub()
            let model = SynologyPhotosModel(repository: repository, pageSize: 6, deletionReviewDelay: { _ in })
            await model.refresh()
            await model.jumpToMonth(.init(year: 2014, month: 8))
            let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                .environment(MacAppearanceStore()).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 1100, height: 720))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            try await Task.sleep(for: .milliseconds(300))
            try await settle(host)
            XCTAssertEqual(model.previousMonthID, 201408, "没有主动向上滚动不能预加载较新月份")
            XCTAssertEqual(model.items.map(\.id.unitID), [4, 5, 6])
            let requests = await repository.requests
            XCTAssertEqual(requests.count, 2)
            model.selectGroup(Array(model.items.prefix(2)))
            try await settle(host)
            try snapshot(host, name: "photos-batch-selection-\(scheme)")
            model.requestDeletion(model.selectedPhotos)
            for _ in 0..<100 where model.isCheckingDeletion { try await Task.sleep(for: .milliseconds(5)) }
            let targets = model.deletionCandidates
            XCTAssertEqual(targets.count, 2)
            model.confirmDeletion(targets)
            for _ in 0..<100 where model.isDeleting { try await Task.sleep(for: .milliseconds(5)) }
            try await settle(host)
            XCTAssertFalse(model.isDeleting)
            XCTAssertEqual(model.items.map(\.id.unitID), [6])
            XCTAssertEqual(model.selectedTimelineMonthID, 201408)
            XCTAssertEqual(model.previousMonthID, 201408)
            let after = await repository.requests
            XCTAssertEqual(after.count, 2, "自动删除核对不能重建图库或向上加载")
            try snapshot(host, name: "photos-delete-preserved-month-\(scheme)")
        }
    }

    func test照片时间轴获得焦点不显示整框且保留方向键() async throws {
        let months = (2012...2026).reversed().flatMap { year in
            (1...12).reversed().map { SynologyPhotoMonth(year: year, month: $0) }
        }
        for scheme in [ColorScheme.light, .dark] {
            var selected: SynologyPhotoMonth?
            let host = NSHostingView(rootView: PhotoTimelineRail(months: months, selectedID: months[0].id) { selected = $0 }
                .padding(8).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 108, height: 680))
            defer { window.contentView = nil; window.close() }
            window.makeKeyAndOrderFront(nil)
            try await settle(host)
            window.selectNextKeyView(nil)
            try await settle(host)
            let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
            window.sendEvent(down)
            try await settle(host)
            XCTAssertEqual(selected?.id, months[1].id, "取消整块焦点框不能禁用方向键定位")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            for x in Int(4 * scale)...Int(10 * scale) {
                let bluePixels = (0..<bitmap.pixelsHigh).filter { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.blueComponent > color.redComponent + 0.15 && color.blueComponent > color.greenComponent + 0.05
                }.count
                XCTAssertLessThan(bluePixels, bitmap.pixelsHigh / 3, "时间轴左边缘不应出现贯穿高度的蓝色焦点框")
            }
            try snapshot(host, name: "photos-rail-focused-\(scheme)")
        }
    }

    func test照片背景复用工作区并显示完整年月侧轴() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        for language in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let fixture = SynologyPhotosPresentationFixture(image: Data(), empty: true)
                let emptyModel = SynologyPhotosModel(repository: fixture)
                await emptyModel.refresh()
                let host = NSHostingView(rootView: HStack(spacing: 0) {
                    Color.clear.frame(width: 180).background(MacGlassSurface(role: .content))
                    SynologyPhotosView(model: emptyModel)
                }.background(MacGlassSurface(role: .sidebar))
                    .environment(MacAppearanceStore()).environment(\.macUsesContentBackground, true).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 1120, height: 680))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let reference = try XCTUnwrap(bitmap.colorAt(x: 40, y: bitmap.pixelsHigh - 24)?.usingColorSpace(.deviceRGB))
                let photoBackground = try XCTUnwrap(bitmap.colorAt(x: 420, y: bitmap.pixelsHigh - 24)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(reference.redComponent, photoBackground.redComponent, accuracy: 0.015)
                XCTAssertEqual(reference.greenComponent, photoBackground.greenComponent, accuracy: 0.015)
                XCTAssertEqual(reference.blueComponent, photoBackground.blueComponent, accuracy: 0.015)
                try snapshot(host, name: "photos-workspace-background-\(language.rawValue)-\(scheme)")

                let months = (2012...2026).reversed().flatMap { year in (1...12).reversed().map { SynologyPhotoMonth(year: year, month: $0) } }
                let rail = NSHostingView(rootView: PhotoTimelineRail(months: months, selectedID: 202510, onSelect: { _ in XCTFail("绘制不得跳转") })
                    .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                let railWindow = attach(rail, size: NSSize(width: 92, height: 680))
                defer { railWindow.contentView = nil; railWindow.close() }
                try await settle(rail)
                try snapshot(rail, name: "photos-year-month-rail-\(language.rawValue)-\(scheme)")
            }
        }
    }

    func test照片筛选详情与更新弹窗圆角双语主题() async throws {
        let oldLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = oldLanguage }
        let image = NSImage(size: NSSize(width: 300, height: 200), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let data = try XCTUnwrap(image.tiffRepresentation)
        for language in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let model = SynologyPhotosModel(repository: SynologyPhotosPresentationFixture(image: data))
                await model.refresh()
                let photo = try XCTUnwrap(model.items.first)
                model.showPreview(photo)
                for _ in 0..<50 where model.isPreparingPreview { await Task.yield() }
                XCTAssertNotNil(model.previewData)
                let driver = AppUpdateUserDriver(presentsWindows: false)
                driver.showMessage("updates.unavailable", detail: "updates.manual") { XCTFail("绘制不能确认更新") }
                let views: [(String, AnyView, NSSize)] = [
                    ("details", AnyView(SynologyPhotoPreview(model: model, showsInfo: true)), NSSize(width: 1000, height: 720)),
                    ("filters", AnyView(PhotoFilterPanel(model: model, draft: SynologyPhotoFilter())), NSSize(width: 460, height: 600)),
                    ("update-rounded", AnyView(AppUpdateView(driver: driver)), NSSize(width: 500, height: 520))
                ]
                for (name, view, size) in views {
                    let host = NSHostingView(rootView: view.environment(MacAppearanceStore()).environment(AppLanguageStore.shared).preferredColorScheme(scheme))
                    let window = attach(host, size: size)
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "photos-feedback-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    if name == "filters" {
                        let popups = nativeViews(host, of: NSPopUpButton.self)
                        XCTAssertGreaterThanOrEqual(popups.count, 11)
                        let width = try XCTUnwrap(popups.first).bounds.width
                        XCTAssertGreaterThan(width, 200)
                        for popup in popups { XCTAssertEqual(popup.bounds.width, width, accuracy: 1) }
                        let scroll = try XCTUnwrap(nativeViews(host, of: NSScrollView.self).first)
                        let document = try XCTUnwrap(scroll.documentView)
                        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try await settle(host)
                        try snapshot(host, name: "photos-feedback-filters-capture-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    }
                }
                model.cancel()
            }
        }
    }

    func test挂载写回设置双语主题状态绘制() async throws {
        let oldLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = oldLanguage }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WritebackPresentation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopDriveWritebackStore(directory: directory)
        for state in ["empty", "conflict", "submitted", "error", "multiple", "readOnly", "allShares", "allSharesReadOnly",
                      "deleteConflict", "deleteSubmitted", "allSharesDelete"] {
            let scope: DesktopDriveScope = state.hasPrefix("allShares") ? .allShares : .folder(path: "/share/test")
            let mapping = DesktopDriveMapping(profileID: UUID(), displayName: "My NAS", scope: scope)
            try store.setEnabled(!["empty", "error", "readOnly", "allSharesReadOnly"].contains(state), mappingID: mapping.id)
            if state.hasPrefix("delete") || state == "allSharesDelete" {
                try store.setDeletionEnabled(true, mappingID: mapping.id)
            }
            if state == "error" {
                let path = directory.appendingPathComponent("desktop-drive-writeback-v1").appendingPathComponent(mapping.id.uuidString).appendingPathComponent("broken.json")
                try Data("invalid".utf8).write(to: path)
            } else if state != "empty", !state.hasPrefix("allShares") {
                var record = DesktopDriveWritebackRecord(mappingID: mapping.id, itemIdentifier: "synthetic", sourcePath: nil,
                    destinationPath: "/share/test/旅行计划.md", isDirectory: false,
                    contentHash: state.hasPrefix("delete") ? nil : String(repeating: "0", count: 64), contentSize: 0, baseContentVersion: nil,
                    operation: state.hasPrefix("delete") ? .delete : .save)
                record.phase = state == "conflict" || state == "deleteConflict" ? .conflict : .submitted
                try store.save(record)
                if state == "multiple" {
                    var second = DesktopDriveWritebackRecord(mappingID: mapping.id, itemIdentifier: "second", sourcePath: nil,
                        destinationPath: "/share/test/Project-notes-and-reference-materials-for-the-next-release.md", isDirectory: false,
                        contentHash: String(repeating: "0", count: 64), contentSize: 0, baseContentVersion: nil)
                    second.phase = .conflict
                    try store.save(second)
                }
            }
            for language in [AppLanguageSelection.english, .simplifiedChinese] {
                AppLanguageStore.shared.selection = language
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(rootView: DesktopDriveWritebackSettingsSheet(mapping: mapping, store: store, writebackAvailable: true)
                        .environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                        .environment(\.controlActiveState, .active).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 580, height: 400))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "writeback-\(state)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                }
            }
        }
    }

    func test新增Photos加载空内容筛选为空和错误状态() async throws {
        let language = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = language }
        for selection in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = selection
            for scheme in [ColorScheme.light, .dark] {
                for state in ["loading", "empty", "filtered", "error"] {
                    let model = SynologyPhotosModel(repository: SynologyPhotosPresentationFixture(image: Data(),
                        empty: state == "empty", fails: state == "error", waits: state == "loading"))
                    if state == "filtered" { model.searchText = "no-match" }
                    let load = Task { await model.loadIfNeeded() }
                    if state == "loading" {
                        for _ in 0..<20 where !model.isLoading { await Task.yield() }
                        XCTAssertTrue(model.isLoading)
                    } else { await load.value }
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, L10n.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 900, height: 660))
                    try await settle(host)
                    try snapshot(host, name: "photos-service-\(selection.rawValue)-\(scheme == .dark ? "dark" : "light")-\(state)")
                    XCTAssertTrue(model.items.isEmpty)
                    if state == "error" { XCTAssertNotNil(model.errorMessage) }
                    if state == "filtered" { XCTAssertTrue(model.isFiltering) }
                    load.cancel()
                    model.cancel()
                    window.contentView = nil
                    window.close()
                }
            }
        }
    }

    func test新增Photos双语主题和三种浏览入口() async throws {
        let language = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = language }
        let image = NSImage(size: NSSize(width: 160, height: 120), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let data = try XCTUnwrap(image.tiffRepresentation)
        for selection in [AppLanguageSelection.english, .simplifiedChinese] {
            AppLanguageStore.shared.selection = selection
            for scheme in [ColorScheme.light, .dark] {
                for section in SynologyPhotosSection.allCases {
                    let model = SynologyPhotosModel(repository: SynologyPhotosPresentationFixture(image: data))
                    await model.selectSection(section)
                    let host = NSHostingView(rootView: SynologyPhotosView(model: model)
                        .environment(MacAppearanceStore())
                        .environment(AppLanguageStore.shared)
                        .environment(\.locale, L10n.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 900, height: 660))
                    defer { model.cancel(); window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "photos-service-\(selection.rawValue)-\(scheme == .dark ? "dark" : "light")-\(section)")
                    XCTAssertEqual(host.bounds.width, 900, accuracy: 1)
                    XCTAssertEqual(model.section, section)
                    XCTAssertNil(model.errorMessage)
                    if section == .albums { XCTAssertEqual(model.collections.count, 1) }
                    else if section == .sharing { XCTAssertEqual(model.sharedEntries.count, 1) }
                    else { XCTAssertEqual(model.items.count, 1) }
                }
            }
        }
    }

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

    func test语言与文件排序菜单双语双主题不铺原生白底() async throws {
        let originalAppearance = NSApp.appearance
        let originalLanguage = AppLanguageStore.shared.selection
        defer {
            NSApp.appearance = originalAppearance
            AppLanguageStore.shared.selection = originalLanguage
        }
        let suite = "MenuAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageStore(defaults: defaults)
        for selection in [AppLanguageSelection.english, .simplifiedChinese] {
            language.selection = selection
            AppLanguageStore.shared.selection = selection
            for mode in [MacAppearanceMode.ink, .fog] {
                mode.applyNativeAppearance()
                let scheme = try XCTUnwrap(mode.colorScheme)
                let palette = MacAppearancePalette(scheme: scheme, increasedContrast: false)
                let host = NSHostingView(rootView: HStack(spacing: 20) {
                    AppLanguagePicker(store: language).macThemedMenu().frame(width: 180)
                    FileSortMenu(sortOrder: .constant([FileSortCriterion.name.comparator(order: .forward)]))
                }
                .padding(20)
                .frame(width: 400, height: 90)
                .background(palette.content)
                .environment(language)
                .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 400, height: 90))
                defer { window.contentView = nil; window.close() }
                try await settle(host)
                let buttons = nativeViews(host, of: NSPopUpButton.self)
                XCTAssertFalse(buttons.isEmpty)
                XCTAssertTrue(buttons.allSatisfy { !$0.isBordered })
                window.makeKeyAndOrderFront(nil)
                for button in buttons {
                    let inspected = expectation(description: "打开菜单后检查直接选项")
                    let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                        MainActor.assumeIsolated {
                            DispatchQueue.main.async {
                                guard let menu = button.menu else { return }
                                let options = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
                                XCTAssertGreaterThanOrEqual(options.count, 3)
                                XCTAssertTrue(options.allSatisfy { $0.submenu == nil }, "语言和排序选项应直接展开")
                                XCTAssertFalse(options.contains { $0.title == language.string("settings.language.title") }, "不得保留多余的语言标签")
                                menu.cancelTrackingWithoutAnimation()
                                inspected.fulfill()
                            }
                        }
                    }
                    button.performClick(nil)
                    await fulfillment(of: [inspected], timeout: 2)
                    NotificationCenter.default.removeObserver(observer)
                }
                XCTAssertTrue(buttons.allSatisfy {
                    $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (mode == .ink ? .darkAqua : .aqua)
                })
                try snapshot(host, name: "theme-menus-\(selection.rawValue)-\(mode.rawValue)")
            }
        }
    }

    func test连接卡片与容器统计卡片沿用主题底色而不铺白底() async throws {
        let connections = (0..<6).map { index in
            NasConnection(id: "synthetic-\(index)", account: "Sample \(index)", source: "example.invalid",
                location: nil, protocolName: "HTTPS", type: nil, connectedAt: nil,
                description: "Synthetic connection", isCurrentConnection: false, canDisconnect: true)
        }
        for scheme in [ColorScheme.light, .dark] {
            let palette = MacAppearancePalette(scheme: scheme, increasedContrast: false)
            let summary = NSHostingView(rootView: SummaryCard(title: "Synthetic", value: "2", icon: "shippingbox", tint: .blue)
                .frame(width: 240, height: 100).background(palette.glassTint).preferredColorScheme(scheme))
            let summaryWindow = attach(summary, size: NSSize(width: 240, height: 100))
            defer { summaryWindow.contentView = nil; summaryWindow.close() }
            try await settle(summary)
            let bitmap = try XCTUnwrap(summary.bitmapImageRepForCachingDisplay(in: summary.bounds))
            summary.cacheDisplay(in: summary.bounds, to: bitmap)
            let sample = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 9 / 10, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(sample.redComponent, scheme == .dark ? 0.3 : 0.94)
            try snapshot(summary, name: "card-summary-\(scheme == .dark ? "dark" : "light")")

            let host = NSHostingView(rootView: ConnectionList(page: .init(connections: connections, total: connections.count), busyConnectionIDs: [], onDisconnect: { _ in XCTFail("切换卡片不能断开连接") })
                .environment(MacAppearanceStore()).environment(\.macUsesContentBackground, true)
                .background(palette.glassTint).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 900, height: 600))
            defer { window.contentView = nil; window.close() }
            window.makeKeyAndOrderFront(nil)
            try await settle(host)
            XCTAssertFalse(nativeViews(host, of: NSTableView.self).isEmpty)
            try click(window, at: NSPoint(x: 841, y: 566))
            try await settle(host)
            XCTAssertTrue(nativeViews(host, of: NSTableView.self).isEmpty)
            let cardsBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: cardsBitmap)
            let cardSample = try XCTUnwrap(cardsBitmap.colorAt(x: cardsBitmap.pixelsWide * 3 / 10, y: cardsBitmap.pixelsHigh / 5)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(cardSample.redComponent, scheme == .dark ? 0.3 : 0.94)
            try snapshot(host, name: "card-connections-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func test文件夹详情自动统计且重新打开会刷新结果() async throws {
        let fixture = try WorkspaceViewFixture(count: 1)
        defer { fixture.cleanPreferences() }
        fixture.model.isFileModuleEnabled = true
        let item = try XCTUnwrap(fixture.model.items.first)
        for (index, scheme) in [ColorScheme.light, .dark].enumerated() {
            let host = NSHostingView(rootView: FilePropertiesView(item: item, model: fixture.model)
                .macSheetSurface().environment(MacAppearanceStore()).preferredColorScheme(scheme))
            let window = attach(host, size: NSSize(width: 560, height: 420))
            defer { window.contentView = nil; window.close() }
            try await settle(host)
            XCTAssertEqual(fixture.model.folderStatisticsResults[item.id]?.sizeBytes, Int64(index + 1) * 125_000)
            let requests = await fixture.repository.directorySizeCalls
            XCTAssertEqual(requests, index + 1)
            XCTAssertFalse(fixture.model.calculatingFolderStatisticsIDs.contains(item.id))
            try snapshot(host, name: "properties-compact-auto-\(scheme == .dark ? "dark" : "light")")
        }
        let writes = await fixture.repository.writeCalls
        XCTAssertEqual(writes, 0)
    }

    func test文件面包屑从长目录返回时显示目标目录首项() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for mode in [FileViewMode.grid, .list] {
                let fixture = try WorkspaceViewFixture(count: 160)
                fixture.model.isFileModuleEnabled = true
                fixture.model.currentPath = "/synthetic/child"
                fixture.model.section = .files("/synthetic/child")
                let destination = (0..<80).map { index in
                    FileItem(profileID: fixture.model.profile.id, name: String(format: "Destination-%02d", index),
                        path: "/synthetic/destination-\(index)", kind: .directory)
                }
                await fixture.repository.setFolderItems(destination, path: "/synthetic")
                fixture.model.shares = Array(destination.prefix(12))
                let host = makeHost(fixture: fixture, mode: mode, scheme: scheme, showsInspector: .constant(true))
                let window = attach(host, size: NSSize(width: 1100, height: 640))
                defer { fixture.model.cancelAllWork(); window.contentView = nil; window.close(); fixture.cleanPreferences() }
                window.makeKeyAndOrderFront(nil); try await settle(host)
                let scroll = try XCTUnwrap(nativeViews(host, of: NSScrollView.self).first)
                let document = try XCTUnwrap(scroll.documentView)
                let topOrigin = scroll.contentView.bounds.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView); try await settle(host)
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 100, "先滚动长目录，再通过真实面包屑跳转")
                try snapshot(host, name: "files-before-breadcrumb-\(mode)-\(scheme)")
                // 1100×640合成窗口底栏中可见的父目录按钮。
                try click(window, at: NSPoint(x: 105, y: 21))
                try await settle(host)
                XCTAssertEqual(fixture.model.currentPath, "/synthetic")
                XCTAssertEqual(fixture.model.filteredItems, destination)
                let currentScroll = try XCTUnwrap(nativeViews(host, of: NSScrollView.self).first)
                XCTAssertEqual(currentScroll.contentView.bounds.minY, topOrigin, accuracy: 1, "切换目录不能沿用旧目录底部的滚动位置")
                try snapshot(host, name: "files-breadcrumb-parent-\(mode)-\(scheme)")
                currentScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
                currentScroll.reflectScrolledClipView(currentScroll.contentView); try await settle(host)
                let beforeRefresh = currentScroll.contentView.bounds.minY
                await fixture.model.refresh(); try await settle(host)
                XCTAssertEqual(currentScroll.contentView.bounds.minY, beforeRefresh, accuracy: 1, "刷新同一目录应保留浏览位置")
                // 返回只有12项的根目录，不能留下旧网格的空白区域。
                try click(window, at: NSPoint(x: 85, y: 21)); try await settle(host)
                XCTAssertEqual(fixture.model.currentPath, "/"); XCTAssertEqual(fixture.model.filteredItems.count, 12)
                let rootScroll = try XCTUnwrap(nativeViews(host, of: NSScrollView.self).first)
                XCTAssertEqual(rootScroll.contentView.bounds.minY, topOrigin, accuracy: 1)
                try snapshot(host, name: "files-breadcrumb-root-\(mode)-\(scheme)")
                let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
            }
        }
    }

    func test三档文件网格保持选择且文件与文件夹共同缩放() async throws {
        let previousSize = UserDefaults.standard.object(forKey: "LanStash_FileGridSize")
        defer {
            if let previousSize { UserDefaults.standard.set(previousSize, forKey: "LanStash_FileGridSize") }
            else { UserDefaults.standard.removeObject(forKey: "LanStash_FileGridSize") }
        }
        let fixture = try WorkspaceViewFixture(count: 12)
        defer { fixture.cleanPreferences() }
        fixture.model.items[1] = FileItem(profileID: fixture.model.profile.id, name: "Document.pdf", path: "/synthetic/Document.pdf", kind: .file, sizeBytes: 1234)
        fixture.model.items[2] = FileItem(profileID: fixture.model.profile.id, name: "Photo.jpg", path: "/synthetic/Photo.jpg", kind: .file, sizeBytes: 4321)
        let selected = Set(fixture.model.items.prefix(3).map(\.id))
        fixture.model.selection = selected
        for scheme in [ColorScheme.light, .dark] {
            let host = makeHost(fixture: fixture, mode: .grid, scheme: scheme)
            let window = attach(host, size: NSSize(width: 900, height: 560))
            defer { window.contentView = nil; window.close() }
            for size in FileGridSize.allCases {
                UserDefaults.standard.set(size.rawValue, forKey: "LanStash_FileGridSize")
                try await settle(host)
                XCTAssertEqual(fixture.model.selection, selected)
                XCTAssertEqual(fixture.model.currentPath, "/synthetic")
                try snapshot(host, name: "grid-size-\(size.rawValue)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func test下载与虚拟机选中行使用低饱和主题色并保留原生选择() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for module in [ServiceManagementModel.Module.downloads, .virtualMachines] {
                let model = ServiceManagementModel(repository: ServiceManagementRepositoryStub())
                await model.activate(module)
                let palette = MacAppearancePalette(scheme: scheme, increasedContrast: false)
                let host = NSHostingView(rootView: ServiceManagementView(module: module, model: model)
                    .environment(MacAppearanceStore()).environment(\.macUsesContentBackground, true)
                    .background(palette.glassTint).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 900, height: 620))
                defer { window.contentView = nil; window.close() }
                window.makeKeyAndOrderFront(nil)
                try await settle(host)
                if module == .downloads { model.downloadSelection = [try XCTUnwrap(model.downloads?.tasks.first?.id)] }
                else { model.virtualMachineSelection = [try XCTUnwrap(model.virtualMachines?.machines.first?.id)] }
                try await settle(host)
                // 下载页现有分类侧栏与任务表格；只核对任务表，不把分类选择误当任务选择。
                func currentTaskTable() throws -> NSTableView {
                    try XCTUnwrap(nativeViews(host, of: NSTableView.self).first { module != .downloads || $0.numberOfColumns > 1 })
                }
                let table = try currentTaskTable()
                window.makeFirstResponder(table)
                try await settle(host)
                XCTAssertEqual(table.selectionHighlightStyle, .none)
                let index = try XCTUnwrap(table.selectedRowIndexes.first)
                let row = try XCTUnwrap(table.rowView(atRow: index, makeIfNecessary: false))
                XCTAssertEqual(row.backgroundColor, palette.nativeSelection)
                try snapshot(host, name: "selection-\(module == .downloads ? "downloads" : "virtual-machine")-\(scheme == .dark ? "dark" : "light")")
                window.makeFirstResponder(nil)
                try await settle(host)
                XCTAssertEqual(row.backgroundColor, palette.nativeSelection)
                if module == .downloads { model.downloadSelection.removeAll() }
                else { model.virtualMachineSelection.removeAll() }
                try await settle(host)
                // 清空任务选择会收起详情并重建表格，核对当前可见实例。
                let clearedTable = try currentTaskTable()
                XCTAssertTrue(clearedTable.selectedRowIndexes.isEmpty)
                let clearedRow = try XCTUnwrap(clearedTable.rowView(atRow: index, makeIfNecessary: false))
                XCTAssertEqual(clearedRow.backgroundColor, .clear)
            }
        }
    }

    func test原生弹窗不继承工作区透明叠色且取消不清理缓存() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for isCache in [true, false] {
                let presentation = PageTabSelectionProbe()
                let sheet = isCache
                    ? AnyView(SelectiveCacheCleanupSheet(storage: .init(previewCache: 10, photoCache: 20, systemCache: 30, protectedData: 40, mountedCache: .init(temporaryBytes: 50, keptOfflineBytes: 60))) { _ in XCTFail("不得自动清理缓存"); return false })
                    : AnyView(CreateVirtualMachineSheet(snapshot: nil) { _ in XCTFail("不得自动创建虚拟机"); return false })
                let host = NSHostingView(rootView: Color.clear
                    .macSheet(isPresented: Binding(get: { presentation.value == 1 }, set: { presentation.value = $0 ? 1 : 0 })) { sheet }
                    .environment(MacAppearanceStore()).environment(\.macUsesContentBackground, true)
                    .preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 900, height: 780))
                defer { window.contentView = nil; window.close() }
                window.makeKeyAndOrderFront(nil)
                presentation.value = 1
                try await settle(host)
                let modal = try XCTUnwrap(window.attachedSheet)
                let content = try XCTUnwrap(modal.contentView)
                try await settle(content)
                XCTAssertTrue(nativeViews(content, of: NSVisualEffectView.self).contains { $0.blendingMode == .behindWindow })
                try snapshot(content, name: "modal-\(isCache ? "cache" : "virtual-machine")-\(scheme == .dark ? "dark" : "light")")
                presentation.value = 0
                try await settle(host)
                if window.attachedSheet != nil { window.endSheet(modal) }
            }
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
                let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
                    let data = Data(#"{"tag_name":"macos/v0.3.0","body":"","draft":false,"prerelease":false,"assets":[]}"#.utf8)
                    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                })
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

    func test更新窗口原生外框系统关闭与Escape有效() async throws {
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
                XCTAssertTrue(window.styleMask.contains(.titled))
                XCTAssertTrue(window.canBecomeKey)
                XCTAssertTrue(window.isMovable)
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
                    let button = try XCTUnwrap(window.standardWindowButton(kind))
                    XCTAssertFalse(button.isHidden)
                    XCTAssertTrue(button.isEnabled)
                }
                XCTAssertEqual(window.titleVisibility, .hidden)
                XCTAssertTrue(window.titlebarAppearsTransparent)
                XCTAssertEqual(window.titlebarSeparatorStyle, .none)
                XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
                XCTAssertEqual(host.bounds.height, window.frame.height, accuracy: 1)
                XCTAssertLessThanOrEqual(host.bounds.height - 28, 210)
                driver.showUserInitiatedUpdateCheck { XCTFail("绘制不得取消检查") }
                try await settle(host)
                try snapshot(host, name: "update-compact-checking-\(mode.rawValue)")
                driver.showDownloadInitiated { XCTFail("绘制不得取消下载") }
                driver.showDownloadDidReceiveExpectedContentLength(100)
                driver.showDownloadDidReceiveData(ofLength: 40)
                try await settle(host)
                XCTAssertLessThanOrEqual(host.bounds.height - 28, 250)
                XCTAssertEqual(driver.progress, 0.4)
                try snapshot(host, name: "update-compact-download-\(mode.rawValue)")
                driver.showMessage("updates.none", detail: "updates.none.detail", stage: .upToDate) { closes += 1 }
                try await settle(host)
                try snapshot(host, name: "update-titled-\(mode.rawValue)-\(usesEscape ? "escape" : "close")")
                if usesEscape {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                } else {
                    window.standardWindowButton(.closeButton)?.performClick(nil)
                }
                try await settle(host)
                XCTAssertEqual(closes, 1, "\(mode.rawValue), usesEscape=\(usesEscape)")
                XCTAssertFalse(window.isVisible, "\(mode.rawValue), usesEscape=\(usesEscape)")
            }
        }
    }

    func test更新弹窗内日志加载结果双语主题() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for state in ["loading", "loaded", "empty", "failed"] {
                    let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
                        if state == "loading" {
                            try await Task.sleep(for: .seconds(30))
                            throw CancellationError()
                        }
                        if state == "failed" { throw URLError(.notConnectedToInternet) }
                        let body = state == "empty" ? "" : "## macOS 0.3.0\n\n- 修复挂载设置闪退\n- 完善文件操作\n\n## English — macOS 0.3.0\n\n- Fixed a crash in mount settings\n- Improved file operations"
                        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "macos/v0.3.0", "body": body,
                            "draft": false, "prerelease": false, "assets": []])
                        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    })
                    driver.showAvailable(version: "0.3.0", notes: nil) { _ in XCTFail("读取说明不能安装更新") }
                    let host = NSHostingView(rootView: AppUpdateView(driver: driver)
                        .environment(MacAppearanceStore()).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 500, height: 460))
                    defer { driver.dismissUpdateInstallation(); window.contentView = nil; window.close() }
                    try await settle(host)
                    XCTAssertEqual(driver.isLoadingNotes, state == "loading")
                    XCTAssertEqual(driver.notesLoadFailed, state == "failed")
                    XCTAssertEqual(driver.primaryKey, "updates.download")
                    if state == "loaded" {
                        let rendered = nativeViews(host, of: NSTextField.self).map(\.stringValue).joined(separator: " ")
                        if language == .simplifiedChinese {
                            XCTAssertFalse(rendered.contains("English"))
                            XCTAssertFalse(rendered.contains("Fixed a crash"))
                            XCTAssertTrue(rendered.contains("修复挂载设置闪退"))
                        } else {
                            XCTAssertFalse(rendered.contains("修复挂载设置闪退"))
                            XCTAssertTrue(rendered.contains("Fixed a crash"))
                        }
                        driver.showDownloadInitiated {}
                        driver.showDownloadDidReceiveExpectedContentLength(100)
                        driver.showDownloadDidReceiveData(ofLength: 9)
                        try await settle(host)
                        let downloading = nativeViews(host, of: NSTextField.self).map(\.stringValue).joined(separator: " ")
                        if language == .simplifiedChinese {
                            XCTAssertFalse(downloading.contains("English"))
                            XCTAssertFalse(downloading.contains("Fixed a crash"))
                            XCTAssertTrue(downloading.contains("修复挂载设置闪退"))
                        } else {
                            XCTAssertFalse(downloading.contains("修复挂载设置闪退"))
                            XCTAssertTrue(downloading.contains("Fixed a crash"))
                        }
                    }
                    try snapshot(host, name: "update-inline-\(state)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                }
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

    func test容器下载恢复与搜索错误双语主题使用普通文案() async throws {
        let previous = AppLanguageStore.shared.selection
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { AppLanguageStore.shared.selection = previous; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for stage in [ContainerImagePullStage.needsReview, .downloading, .ready, .rejected] {
                    let repository = ServiceManagementRepositoryStub()
                    await repository.configurePull(stage: stage)
                    let model = ContainerImagePullModel(repository: repository)
                    await model.activate(); model.setTarget(repository: "synthetic/web", tag: "stable"); model.confirm(true); await model.submit()
                    let host = NSHostingView(rootView: PullImageSheet(search: { _ in [] }, loadTags: { _ in [] }, tracking: model)
                        .macSheetSurface().environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: .init(width: 620, height: 640))
                    defer { model.deactivate(); window.contentView = nil; window.close() }
                    try await settle(host)
                    let values = remoteFlowElements(host).flatMap { [$0.accessibilityLabel(), $0.accessibilityTitle(), $0.value("accessibilityValue") as? String].compactMap { $0 } }
                    XCTAssertTrue(values.contains { $0.contains(ContainerImagePullModel.statusText(model.results[0])) })
                    XCTAssertTrue(values.contains(L10n.string("container-image.pull.review")))
                    XCTAssertFalse(values.contains { $0.contains("检查下载状态") || $0.contains("不要再次提交") || $0.contains("Check download status") })
                    let calls = await repository.pullRequests; XCTAssertEqual(calls.count, 1)
                    try snapshot(host, name: "container-pull-\(stage.rawValue)-\(language.rawValue)-\(scheme)")
                }
                let repository = ServiceManagementRepositoryStub(), model = ContainerImagePullModel(repository: repository)
                let host = NSHostingView(rootView: PullImageSheet(search: { _ in throw PresentationRepositoryError.unexpectedOperation }, loadTags: { _ in [] }, tracking: model)
                    .macSheetSurface().environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                    .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(scheme))
                let window = attach(host, size: .init(width: 620, height: 640))
                defer { model.deactivate(); window.contentView = nil; window.close() }
                try await settle(host); window.makeKeyAndOrderFront(nil)
                let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.isEditable })
                field.selectText(nil)
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                editor.insertText("synthetic", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await settle(host)
                let search = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("ui.44ce7ae909bbb28b") })
                try click(window, at: window.convertPoint(fromScreen: .init(x: search.accessibilityFrame().midX, y: search.accessibilityFrame().midY)))
                try await settle(host)
                let values = remoteFlowElements(host).flatMap { [$0.accessibilityLabel(), $0.accessibilityTitle(), $0.value("accessibilityValue") as? String].compactMap { $0 } }
                XCTAssertTrue(values.contains(L10n.string("container-image.search.failed")))
                XCTAssertTrue(values.contains(L10n.string("container-image.search.retry")))
                XCTAssertFalse(values.contains(L10n.string("ui.fd4d26c833ae1a5f")), "读取失败不能冒充没有匹配项")
                let calls = await repository.pullRequests; XCTAssertTrue(calls.isEmpty)
                try snapshot(host, name: "container-search-failed-\(language.rawValue)-\(scheme)")
            }
        }
    }

    func test下载辅助弹窗双语主题不自动创建或保存() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let pullRepository = ServiceManagementRepositoryStub()
                let pullTracking = ContainerImagePullModel(repository: pullRepository)
                let pages: [(String, NSSize, AnyView)] = [
                    ("pull-image", NSSize(width: 620, height: 540), AnyView(PullImageSheet(search: { _ in [] }, loadTags: { _ in [] }, tracking: pullTracking))),
                    ("create-vm", NSSize(width: 620, height: 500), AnyView(CreateVirtualMachineSheet(snapshot: nil, submit: { _ in XCTFail("不能自动创建虚拟机"); return false }))),
                    ("edit-vm-stopped", NSSize(width: 560, height: 460), AnyView(EditVirtualMachineSheet(machine: VirtualMachine(id: "synthetic-vm", name: "Synthetic virtual machine", status: "stopped", cpuCount: 2, memoryBytes: 2_147_483_648), submit: { _ in XCTFail("不能自动修改虚拟机"); return false }))),
                    ("edit-vm-running", NSSize(width: 560, height: 460), AnyView(EditVirtualMachineSheet(machine: VirtualMachine(id: "synthetic-vm", name: "Synthetic virtual machine", status: "running", cpuCount: 2, memoryBytes: 2_147_483_648), submit: { _ in XCTFail("不能自动修改运行中虚拟机"); return false }))),
                    ("create-network", NSSize(width: 560, height: 540), AnyView(CreateNetworkSheet(submit: { _ in XCTFail("不能自动创建网络"); return nil }))),
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
                    let pullRequests = await pullRepository.pullRequests
                    XCTAssertTrue(pullRequests.isEmpty, "不能自动下载镜像")
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

    func test容器日志网络正常空失败不可用双语主题绘制() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let normal = ContainerManagerSnapshot(containers: [], images: [],
            networks: [.init(id: "synthetic-network", name: "Synthetic bridge", driver: "bridge", connectedContainerCount: 2,
                             subnet: "192.0.2.0/24", gateway: "192.0.2.1", isIPv6Enabled: false,
                             connectedContainerNames: ["Synthetic A", "Synthetic B"])],
            projects: [.init(id: "synthetic-project", name: "Synthetic project", status: "running", containerCount: 2)],
            events: [.init(id: "synthetic-event", timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                                        level: "info", user: "Synthetic user", message: "Synthetic container started.")])
        let empty = ContainerManagerSnapshot(containers: [], images: [], networks: [], projects: [], events: [])
        let failed = ContainerManagerSnapshot(containers: [], images: [], networks: [], projects: [], events: [], failedSections: [.logs, .networks, .projects])
        let unavailable = ContainerManagerSnapshot(containers: [], images: [], networks: [], projects: [], events: [], unavailableSections: [.logs, .networks, .projects])
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for (name, snapshot) in [("normal", normal), ("empty", empty), ("failed", failed), ("unavailable", unavailable)] {
                    for pane in [ContainerManagerPane.events, .networks, .projects] {
                        let model = ServiceManagementModel(repository: ServiceManagementRepositoryStub(containerSnapshot: snapshot))
                        await model.activate(.containers)
                        let host = NSHostingView(rootView: ServiceManagementView(module: .containers, model: model, containerPane: pane)
                            .environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                            .environment(\.locale, AppLanguageStore.shared.locale)
                            .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                            .preferredColorScheme(scheme))
                        let window = attach(host, size: NSSize(width: 900, height: 640))
                        defer { window.contentView = nil; window.close() }
                        try await settle(host)
                        try self.snapshot(host, name: "container-read-\(pane.rawValue)-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                        XCTAssertEqual(model.containers, snapshot)
                        XCTAssertTrue(model.networkSelection.isEmpty)
                        XCTAssertEqual(host.bounds.height, 640, accuracy: 1)
                        if pane == .networks, name == "normal" {
                            // 固定尺寸合成窗口中点击已绘制的原生展开箭头，不调用网络配置动作。
                            window.makeKeyAndOrderFront(nil)
                            try await settle(host)
                            try click(window, at: NSPoint(x: 39, y: 423))
                            try await Task.sleep(for: .milliseconds(350))
                            try await settle(host)
                            try self.snapshot(host, name: "container-network-expanded-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                            XCTAssertEqual(model.containers, snapshot)
                            XCTAssertFalse(model.isPerformingAction)
                        }
                    }
                }
            }
        }
    }

    func test容器网络详情只读字段双语主题绘制() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        let networks = [
            ContainerNetwork(id: "synthetic-bridge", name: "Synthetic bridge", driver: "bridge", connectedContainerCount: 2,
                subnet: "192.0.2.0/24", gateway: "192.0.2.1", isIPv6Enabled: false, connectedContainerNames: ["Synthetic A", "Synthetic B"]),
            ContainerNetwork(id: "synthetic-host", name: "Synthetic host", driver: "host", isIPv6Enabled: true, connectedContainerNames: []),
            ContainerNetwork(id: "synthetic-unknown", name: "Synthetic unknown", driver: "bridge", connectedContainerCount: 2)
        ]
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for network in networks {
                    let host = NSHostingView(rootView: ContainerNetworkDetailsView(network: network).padding(20)
                        .environment(AppLanguageStore.shared).environment(\.locale, AppLanguageStore.shared.locale)
                        .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 600, height: 300))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "container-network-details-\(network.id)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(host.bounds.width, 600, accuracy: 1)
                }
            }
        }
    }

    func test新建网络完整表单自动手动双语主题绘制() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        var manual = ContainerNetworkCreation(name: "synthetic-network")
        manual.usesManualIPv4 = true
        manual.subnet = "192.0.2.0/24"
        manual.gateway = "192.0.2.1"
        manual.isIPv6Enabled = true
        manual.ipv6Subnet = "2001:db8::/64"
        manual.ipv6Gateway = "2001:db8::1"
        manual.disableMasquerade = true
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for (name, configuration, enabled) in [("automatic", ContainerNetworkCreation(), false),
                                                      ("automatic-enabled", ContainerNetworkCreation(name: "test"), true),
                                                      ("manual", manual, true)] {
                    let host = NSHostingView(rootView: CreateNetworkSheet(canSubmit: enabled, configuration: configuration) { _ in
                        XCTFail("合成表单不得提交创建")
                        return nil
                    }.environment(MacAppearanceStore()).environment(AppLanguageStore.shared).environment(\.locale, AppLanguageStore.shared.locale)
                        .preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 560, height: 540))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    try snapshot(host, name: "create-network-full-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    XCTAssertEqual(host.bounds.height, 540, accuracy: 1)
                }
            }
        }
    }

    func test关于窗口只显示版本不显示构建次数() async throws {
        let url = artifacts.appendingPathComponent("SyntheticAbout.bundle", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "example.synthetic.about", "CFBundleName": "Synthetic About",
                                   "CFBundleShortVersionString": "1.0.3", "CFBundleVersion": "14"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let controller = AppUpdateController(bundle: try XCTUnwrap(Bundle(url: url)), canRestart: { true })
        var options = controller.aboutPanelOptions
        options[.applicationName] = "Synthetic About"
        let previousWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: options)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !previousWindows.contains(ObjectIdentifier($0)) })
        defer { panel.orderOut(nil) }
        let content = try XCTUnwrap(panel.contentView)
        try await settle(content)
        let text = nativeViews(content, of: NSTextField.self).map(\.stringValue).joined(separator: " ")
        XCTAssertTrue(text.contains("1.0.3"))
        XCTAssertFalse(text.contains("(14)"))
        try snapshot(content, name: "about-version-only")
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

    func test消息新增操作面板双语主题不自动发送或录音() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer {
            AppLanguageStore.shared.selection = previousLanguage
            NSApp.accessibilitySetValue(previousAX, forAttribute: attribute)
        }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let conversation = ChatConversation(id: "27", kind: .direct, title: "Synthetic conversation", memberIDs: [])
                let root = ChatMessage(id: "root", conversationID: "27", senderID: "self", senderDisplayName: "Synthetic self",
                    isFromCurrentUser: true, sentAt: Date(timeIntervalSince1970: 1_800_000_000), text: "Synthetic original message", kind: .normal, threadID: "root", replyCount: 1)
                let reply = ChatMessage(id: "reply", conversationID: "27", senderID: "peer", senderDisplayName: "Synthetic peer",
                    isFromCurrentUser: false, sentAt: Date(timeIntervalSince1970: 1_800_000_100), text: "Synthetic threaded reply", kind: .normal, threadID: "root")
                let poll = ChatMessage(id: "poll", conversationID: "27", senderID: "peer", sentAt: Date(), text: "Synthetic poll",
                    poll: ChatPoll(id: "poll", question: "Synthetic poll", allowsMultipleSelection: true, isAnonymous: false,
                        options: [ChatPollOption(id: "a", text: "Synthetic first choice", voteCount: 2), ChatPollOption(id: "b", text: "Synthetic second choice", voteCount: 1, isSelectedByCurrentUser: true)]))
                let repository = ChatRepositoryStub(conversations: [conversation], messagesByConversation: [conversation.id: [root, reply, poll]], availableFeatures: Set(ChatFeature.allCases))
                let model = ChatWorkspaceModel(repository: repository)
                await model.loadIfNeeded()
                for panel in ["search", "edit", "voice", "vote", "thread"] {
                    let view: AnyView
                    let expected: String
                    switch panel {
                    case "search": view = AnyView(ChatSearchSheet(model: model, conversation: conversation)); expected = L10n.string("chat.search.title")
                    case "edit": view = AnyView(ChatEditSheet(model: model, message: root)); expected = L10n.string("chat.edit.save")
                    case "voice": view = AnyView(ChatVoiceSheet(model: model, conversation: conversation)); expected = L10n.string("chat.voice.start")
                    case "vote": view = AnyView(ChatVotingSheet(model: model, initialMessage: poll)); expected = L10n.string("chat.vote.submit")
                    default: view = AnyView(ChatDiscussionSheet(model: model, initialMessage: root)); expected = "Synthetic threaded reply"
                    }
                    let host = NSHostingView(rootView: view.macSheetSurface().environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 700, height: 620))
                    defer { window.contentView = nil; window.close() }
                    try await settle(host)
                    let values = remoteFlowElements(host).flatMap { element in
                        [element.accessibilityLabel(), element.accessibilityTitle(), element.value("accessibilityValue") as? String].compactMap { $0 }
                    }
                    XCTAssertTrue(values.contains(where: { $0.contains(expected) }), "\(panel): \(expected)")
                    let previewName = "chat-five-\(panel)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")"
                    try snapshot(host, name: previewName)
                    let sent = await repository.sentTexts()
                    XCTAssertTrue(sent.isEmpty)
                }
                model.cancelAllWork()
            }
        }
    }

    func test消息恢复使用普通操作且辅助功能包含正文() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer {
            AppLanguageStore.shared.selection = previousLanguage
            NSApp.accessibilitySetValue(previousAX, forAttribute: attribute)
        }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let conversation = ChatConversation(id: "sample", kind: .direct, title: "Synthetic conversation", memberIDs: [])
                let repository = ChatRepositoryStub(conversations: [conversation])
                let model = ChatWorkspaceModel(repository: repository)
                await model.loadIfNeeded()
                await repository.makeNextSendUnconfirmed()
                _ = await model.send(text: "Synthetic accessible message")
                let host = NSHostingView(rootView: ChatWorkspaceView(model: model)
                    .environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                    .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(scheme))
                let window = attach(host, size: NSSize(width: 900, height: 650))
                defer { model.cancelAllWork(); window.contentView = nil; window.close() }
                try await settle(host)
                let elements = remoteFlowElements(host)
                XCTAssertTrue(elements.contains { ($0.value("accessibilityValue") as? String) == "Synthetic accessible message" })
                XCTAssertTrue(elements.contains {
                    $0.accessibilityRole() == .link && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("chat.send.check")
                })
                try snapshot(host, name: "chat-recovery-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                let requests = await repository.sendRequestIDs()
                XCTAssertEqual(Set(requests).count, 1)
            }
        }
    }

    func test消息读取错误与加密聊天显示原因而不是空会话() async throws {
        let previous = AppLanguageStore.shared.selection
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer {
            AppLanguageStore.shared.selection = previous
            NSApp.accessibilitySetValue(previousAX, forAttribute: attribute)
        }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                for encrypted in [false, true] {
                    let conversation = ChatConversation(id: "sample", kind: .direct, title: "Synthetic conversation", memberIDs: [], isEncrypted: encrypted)
                    let repository = ChatRepositoryStub(conversations: [conversation])
                    await repository.setMessageReadsFailing(true)
                    let model = ChatWorkspaceModel(repository: repository)
                    await model.loadIfNeeded()
                    let host = NSHostingView(rootView: ChatWorkspaceView(model: model)
                        .environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: NSSize(width: 900, height: 650))
                    defer { model.cancelAllWork(); window.contentView = nil; window.close() }
                    try await settle(host)
                    let visibleText = remoteFlowElements(host).flatMap {
                        [$0.value("accessibilityValue") as? String, $0.accessibilityLabel(), $0.accessibilityTitle()].compactMap { $0 }
                    }.joined(separator: " ")
                    XCTAssertTrue(visibleText.contains(L10n.string(encrypted ? "chat.encrypted.title" : "chat.messages.loadFailed")), visibleText)
                    XCTAssertEqual(model.canSendText, !encrypted)
                    try snapshot(host, name: "chat-\(encrypted ? "encrypted" : "read-error")-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
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

    func test新建聊天按钮点击可打开表单且不会自动提交() async throws {
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        AppLanguageStore.shared.selection = .simplifiedChinese
        let conversation = ChatConversation(id: "sample", kind: .direct, title: "Sample conversation",
            memberIDs: ["user-1"], lastMessageSummary: nil, lastActivityAt: nil)
        let repository = ChatRepositoryStub(conversations: [conversation],
            users: [ChatUser(id: "user-1", displayName: "Synthetic contact")])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        XCTAssertTrue(model.canCreateDirectConversation)
        let host = NSHostingView(rootView: ChatWorkspaceView(model: model)
            .environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
            .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(.dark))
        let window = attach(host, size: NSSize(width: 720, height: 640))
        defer {
            model.setModuleEnabled(false)
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await settle(host)
        // 坐标对应本测试固定中文布局中的“会话”右侧加号。
        try click(window, at: NSPoint(x: 76, y: 550))
        try await settle(host)
        let sheet = try XCTUnwrap(window.attachedSheet)
        try snapshot(try XCTUnwrap(sheet.contentView), name: "chat-new-button-opened")
        let sent = await repository.sentTexts()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.conversations.map(\.id), ["sample"])
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
                    ("power-schedule", NSSize(width: 480, height: 610), AnyView(PowerScheduleEntryEditor(entry: NasPowerScheduleEntry(id: "synthetic", action: .shutdown, isEnabled: true, hour: 23, minute: 30, recurrence: .weekly([.monday, .friday]))) { _ in XCTFail("不能自动修改电源计划") })),
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

    func test照片局部错误双语主题不误报图库且刷新清除提示() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let service = DatePhotoServiceStub()
                await service.enableManagement()
                let model = SynologyPhotosModel(repository: service)
                await model.refresh()
                await service.failNextManagementPreparation(error: AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: L10n.string("photos.service.invalidResponse")))
                model.submitMutation(.createAlbum(name: "Synthetic album", photos: []))
                for _ in 0..<1000 where model.isManaging { try await Task.sleep(for: .milliseconds(1)) }
                let host = NSHostingView(rootView: SynologyPhotosView(model: model).environment(MacAppearanceStore())
                    .environment(AppLanguageStore.shared).environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                let window = attach(host, size: .init(width: 1040, height: 700))
                defer { window.contentView = nil; window.close(); model.setModuleEnabled(false) }
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                XCTAssertEqual(model.managementMessage, L10n.string("photos.manage.failed"))
                XCTAssertNil(model.errorMessage)
                XCTAssertFalse(model.items.isEmpty)
                try snapshot(host, name: "photos-operation-error-\(language.rawValue)-\(scheme)")
                let refresh = try XCTUnwrap(remoteFlowElements(host).first { $0.value("accessibilityIdentifier") as? String == "photos.refresh" })
                try click(window, at: window.convertPoint(fromScreen: .init(x: refresh.accessibilityFrame().midX, y: refresh.accessibilityFrame().midY)))
                try await settle(host)
                XCTAssertNil(model.managementMessage)
                XCTAssertNil(model.errorMessage)
                XCTAssertFalse(model.items.isEmpty)
                try snapshot(host, name: "photos-refreshed-\(language.rawValue)-\(scheme)")
                let writes = await service.managementWriteCount
                XCTAssertEqual(writes, 0)
            }
        }
    }

    func test套件准备窗口双语主题可取消且不提交安装() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage; NSApp.accessibilitySetValue(previousAX, forAttribute: attribute) }
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let repository = NasAdministrationRepositoryStub()
                await repository.holdNextPackagePreparation()
                let model = NasSettingsModel(repository: repository)
                model.setModuleEnabled(true)
                let preparation = Task { try await model.preparePackageInstallation(["Synthetic:stable"]) }
                for _ in 0..<100 {
                    if await repository.isPackagePreparationWaiting() { break }
                    await Task.yield()
                }
                var closed = false
                let host = NSHostingView(rootView: PackageInstallationSheet(model: model, onClose: { closed = true })
                    .environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                    .environment(\.locale, L10n.locale).preferredColorScheme(scheme))
                let window = attach(host, size: .init(width: 620, height: 600))
                defer { window.contentView = nil; window.close(); model.setModuleEnabled(false) }
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await settle(host)
                let button = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("ui.2cd0f3be8738a86c") })
                XCTAssertEqual(button.value("isAccessibilityEnabled") as? Bool ?? button.value("accessibilityEnabled") as? Bool, true)
                try snapshot(host, name: "package-prepare-cancel-\(language.rawValue)-\(scheme)")
                if scheme == .dark {
                    let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                    if !window.performKeyEquivalent(with: escape) { window.sendEvent(escape) }
                } else {
                    try click(window, at: window.convertPoint(fromScreen: .init(x: button.accessibilityFrame().midX, y: button.accessibilityFrame().midY)))
                }
                try await settle(host)
                XCTAssertTrue(closed)
                XCTAssertFalse(model.isPreparingPackageInstallation)
                await repository.releasePackagePreparation()
                do { try await preparation.value; XCTFail("取消后不能交付计划") }
                catch is CancellationError { }
                XCTAssertNil(model.packageInstallPlan)
                let counts = await repository.packageInstallationCounts()
                XCTAssertEqual(counts.0, 0)
            }
        }
    }

    func test套件中心目录搜索与安装设置双语主题不自动写入() async throws {
        NSApp.setActivationPolicy(.regular)
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previousLanguage = AppLanguageStore.shared.selection
        defer {
            AppLanguageStore.shared.selection = previousLanguage
            NSApp.accessibilitySetValue(previousAX, forAttribute: attribute)
        }
        let package = NasPackage(id: "Synthetic", name: "Synthetic Backup", version: "1.0", status: "running", statusDescription: "Synthetic running", packageDescription: "Synthetic package description", installType: "user", installedAt: nil, canStart: false, canStop: true, canUninstall: true)
        let volume = NasPackageInstallVolume(id: "synthetic-volume", name: "Synthetic Volume")
        let settings = NasPackageCenterSettings(betaEnabled: false, emailNotifications: false, desktopNotifications: true, updatePolicy: .selected,
            defaultVolumeID: volume.id, volumes: [volume], packageUpdates: [NasPackageUpdatePreference(id: package.id, name: package.name, canUpdateAutomatically: true, policy: .important)])
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for scheme in [ColorScheme.light, .dark] {
                let repository = NasAdministrationRepositoryStub(packages: [package])
                let model = NasSettingsModel(repository: repository)
                model.setModuleEnabled(true)
                await model.activate(.packages)
                await model.loadPackageCatalog()
                let entry = try XCTUnwrap(model.packageCatalog?.entries.first)
                let plan = NasPackageInstallPlan(items: [NasPackageInstallItem(package: entry, volumes: [volume], defaultVolumeID: volume.id)], affectedPackages: ["Synthetic dependency"])
                let configuration = NasPackageInstallConfiguration(packageName: entry.name, version: entry.version, license: "Synthetic license text. Only fixture content.", fields: [
                    NasPackageInstallField(id: "text", label: "Synthetic account", kind: .text, required: true),
                    NasPackageInstallField(id: "password", label: "Synthetic password", kind: .password, required: true),
                    NasPackageInstallField(id: "flag", label: "Synthetic option", kind: .toggle, defaultValue: .flag(true))
                ], volumes: [volume], defaultVolumeID: volume.id)
                let pages: [(String, NSSize, AnyView)] = [
                    ("center", NSSize(width: 900, height: 660), AnyView(PackageCenterView(model: model))),
                    ("details", NSSize(width: 620, height: 550), AnyView(PackageDetailsView(installed: package, available: entry, isBusy: false, onInstall: { XCTFail("不能自动安装") }, onControl: { _ in XCTFail("不能自动控制") }, onClose: {}))),
                    ("plan", NSSize(width: 620, height: 600), AnyView(PackageInstallPlanView(plan: plan, isBusy: false, onCancel: {}, onConfirm: { _, _ in XCTFail("不能自动确认") }).padding(24))),
                    ("options", NSSize(width: 620, height: 600), AnyView(PackageInstallOptionsView(configuration: configuration, isBusy: false, onCancel: {}, onConfirm: { _, _, _, _ in XCTFail("不能自动接受协议或安装") }).padding(24))),
                    ("settings", NSSize(width: 660, height: 600), AnyView(PackageCenterSettingsView(loadSettings: { settings }, saveSettings: { _, _ in XCTFail("不能自动保存"); return settings }, loadSources: { [] }, saveSource: { _, _ in XCTFail("不能自动添加来源"); return [] }, deleteSource: { _ in XCTFail("不能自动移除来源"); return [] }, onClose: {}))),
                    ("settings-error", NSSize(width: 660, height: 600), AnyView(PackageCenterSettingsView(loadSettings: { throw AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: L10n.string("package.center.incomplete")) }, saveSettings: { _, _ in XCTFail("读取失败不能保存"); return settings }, loadSources: { [] }, saveSource: { _, _ in XCTFail("不能自动添加来源"); return [] }, deleteSource: { _ in XCTFail("不能自动移除来源"); return [] }, onClose: {}))),
                    ("source", NSSize(width: 520, height: 340), AnyView(PackageSourceEditor(source: NasPackageSource(name: "Synthetic source", url: "https://packages.example.invalid/feed"), isEditing: false, onCancel: {}, onSave: { _ in XCTFail("不能自动信任来源") })))
                ]
                for (name, size, page) in pages {
                    let host = NSHostingView(rootView: page.environment(MacAppearanceStore()).environment(AppLanguageStore.shared)
                        .environment(\.locale, AppLanguageStore.shared.locale).preferredColorScheme(scheme))
                    let window = attach(host, size: size)
                    defer { window.contentView = nil; window.close() }
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    try await settle(host)
                    try snapshot(host, name: "package-\(name)-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    if name == "center" {
                        let detailButton = try XCTUnwrap(remoteFlowElements(host).first { $0.value("accessibilityIdentifier") as? String == "packageCenter.details.Synthetic" })
                        try click(window, at: window.convertPoint(fromScreen: NSPoint(x: detailButton.accessibilityFrame().midX, y: detailButton.accessibilityFrame().midY)))
                        try await settle(host)
                        let detailsWindow = try XCTUnwrap(window.attachedSheet)
                        let detailsContent = try XCTUnwrap(detailsWindow.contentView)
                        let stopButton = try XCTUnwrap(remoteFlowElements(detailsContent).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.stop") })
                        try click(detailsWindow, at: detailsWindow.convertPoint(fromScreen: NSPoint(x: stopButton.accessibilityFrame().midX, y: stopButton.accessibilityFrame().midY)))
                        try await settle(host)
                        let confirmation = try XCTUnwrap(window.attachedSheet)
                        let cancel = try XCTUnwrap(remoteFlowElements(try XCTUnwrap(confirmation.contentView)).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("ui.2cd0f3be8738a86c") })
                        try click(confirmation, at: confirmation.convertPoint(fromScreen: NSPoint(x: cancel.accessibilityFrame().midX, y: cancel.accessibilityFrame().midY)))
                        try await settle(host)
                        XCTAssertNil(window.attachedSheet)
                        let controls = await repository.packageControlRequestCount(); XCTAssertEqual(controls, 0)
                        let settingsButton = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.settings") })
                        try click(window, at: window.convertPoint(fromScreen: NSPoint(x: settingsButton.accessibilityFrame().midX, y: settingsButton.accessibilityFrame().midY)))
                        try await settle(host)
                        let settingsSheet = try XCTUnwrap(window.attachedSheet), settingsContent = try XCTUnwrap(settingsSheet.contentView)
                        for _ in 0..<25 {
                            if remoteFlowElements(settingsContent).contains(where: { ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel()) == L10n.string("package.center.settings-load-failed") }) { break }
                            try await settle(settingsContent)
                        }
                        let settingsElements = remoteFlowElements(settingsContent)
                        XCTAssertTrue(settingsElements.contains { ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel()) == L10n.string("package.center.settings-load-failed") })
                        let settingsTitle = try XCTUnwrap(settingsElements.first { $0.accessibilityRole() == .staticText && ($0.value("accessibilityValue") as? String ?? $0.accessibilityLabel()) == L10n.string("package.center.settings") })
                        let save = try XCTUnwrap(settingsElements.first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.save-settings") })
                        XCTAssertLessThan(settingsSheet.frame.maxY - settingsTitle.accessibilityFrame().maxY, 90, "错误内容不能把整个弹窗推到中间")
                        XCTAssertLessThan(save.accessibilityFrame().minY - settingsSheet.frame.minY, 70, "底部按钮应固定在弹窗下方")
                        XCTAssertEqual(save.value("isAccessibilityEnabled") as? Bool ?? save.value("accessibilityEnabled") as? Bool, false)
                        try snapshot(settingsContent, name: "package-settings-error-sheet-\(language.rawValue)-\(scheme)")
                        let close = try XCTUnwrap(settingsElements.first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.close") })
                        try click(settingsSheet, at: settingsSheet.convertPoint(fromScreen: NSPoint(x: close.accessibilityFrame().midX, y: close.accessibilityFrame().midY)))
                        for _ in 0..<20 where window.attachedSheet != nil { try await settle(host) }
                        XCTAssertNil(window.attachedSheet)
                        let all = try XCTUnwrap(remoteFlowElements(host).first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.section.all") })
                        try click(window, at: window.convertPoint(fromScreen: NSPoint(x: all.accessibilityFrame().midX, y: all.accessibilityFrame().midY)))
                        try await settle(host)
                        try snapshot(host, name: "package-catalog-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                        let field = try XCTUnwrap(nativeViews(host, of: NSTextField.self).first { $0.placeholderString == L10n.string("package.center.search") })
                        XCTAssertTrue(window.makeFirstResponder(field))
                        let editor = try XCTUnwrap(window.fieldEditor(true, for: field) as? NSTextView)
                        editor.insertText("No fixture matches", replacementRange: NSRange(location: NSNotFound, length: 0))
                        try await settle(host)
                        try snapshot(host, name: "package-search-empty-\(language.rawValue)-\(scheme == .dark ? "dark" : "light")")
                    }
                    if name.hasPrefix("settings") {
                        let elements = remoteFlowElements(host)
                        let save = try XCTUnwrap(elements.first { $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.save-settings") })
                        XCTAssertEqual(save.value("isAccessibilityEnabled") as? Bool ?? save.value("accessibilityEnabled") as? Bool, false)
                        XCTAssertFalse(elements.contains { ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == L10n.string("package.center.default-volume") }, "只有一个存储位置时不显示选择器")
                    }
                    XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                }
                model.setModuleEnabled(false)
                let counts = await repository.packageInstallationCounts(); XCTAssertEqual(counts.0, 0)
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
        func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? [])
                + view.subviews.flatMap { descendants($0, of: type) }
        }
        for mode in [MacAppearanceMode.fog, .ink, .system] {
            appearance.mode = mode
            try await settle(host)
            let scrolls = descendants(host, of: NSScrollView.self)
            XCTAssertFalse(scrolls.isEmpty)
            for scroll in scrolls {
                XCTAssertFalse(scroll.drawsBackground)
                XCTAssertFalse(scroll.contentView.drawsBackground)
                XCTAssertEqual(scroll.scrollerStyle, .overlay)
            }
            let effects = descendants(host, of: NSVisualEffectView.self).filter { $0.blendingMode == .behindWindow }
            XCTAssertEqual(effects.count, NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0 : 1)
            XCTAssertEqual(window.alphaValue, 1)
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
                    ("cache-cleanup", AnyView(SelectiveCacheCleanupSheet(storage: AppStorageSnapshot(previewCache: 200_000, photoCache: 800_000, systemCache: 100_000, protectedData: 20_000), onClean: { _ in XCTFail("不能自动清理缓存"); return false }))),
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
                    ("archive-extract", AnyView(ArchiveExtractionView(model: fixture.model, item: item, onExtract: { _, _ in }, onCancel: {}))),
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

    private func nativeViews<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { nativeViews($0, of: type) }
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
        if ProcessInfo.processInfo.environment["LANSTASH_UI_NATIVE_SCREENSHOTS"] == "1",
           let window = view.window {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l\(window.windowNumber)", artifacts.appendingPathComponent("native-" + name + ".png").path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0, "仅截取合成窗口；无屏幕录制权限时不能算视觉验收通过")
        }
    }
}

@MainActor
@Observable
private final class PageTabSelectionProbe {
    var value = 0
}

private actor ThumbnailSizingPhotoService: SynologyPhotosServing {
    let profileID = UUID()
    var pageReads = 0
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal], packageVersion: "fixture") }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        [.init(year: 2020, month: 3, day: 15, itemCount: 80)]
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] {
        try await timeline(in: space)
    }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        pageReads += 1
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2020, month: 3, day: 15))!
        let all = (1...80).map { SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: $0),
            filename: "Synthetic-\($0).jpg", sizeBytes: 128, takenAt: date, indexedAt: date, folderID: 1, mediaType: "photo") }
        let items = Array(all.dropFirst(offset).prefix(limit))
        return .init(items: items, offset: offset, nextOffset: offset + items.count, hasMore: offset + items.count < all.count)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
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
final class WorkspaceRemoteConnectionsTests: XCTestCase {
    func test直接连接在忙碌期间拒绝重复点击并刷新状态() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profile = remoteFlowProfile(fixture.model.profile.id, protocolID: "davs", state: .disconnected)
        await fixture.repository.configureVFS(profiles: [profile], status: .confirmedSuccess)
        await fixture.repository.holdNextVFSChange()
        let first = Task { await fixture.model.connectFileVFS(profile) }
        for _ in 0..<100 {
            if await fixture.repository.hasHeldVFSChange { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.model.fileVFSConnectionActivities[profile.id]?.isBusy, true)
        await fixture.model.connectFileVFS(profile)
        let during = await fixture.repository.writeCalls; XCTAssertEqual(during, 1)
        await fixture.repository.releaseVFSChange(); await first.value
        XCTAssertNil(fixture.model.fileVFSConnectionActivities[profile.id])
        XCTAssertEqual(fixture.model.remoteVFSProfiles.first?.state, .connected)
    }

    func test直接连接未知结果只能查看状态不能再次连接() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profile = remoteFlowProfile(fixture.model.profile.id, protocolID: "davs", state: .disconnected)
        await fixture.repository.configureVFS(profiles: [profile], status: .submittedButUnverified)
        await fixture.model.connectFileVFS(profile)
        XCTAssertEqual(fixture.model.fileVFSConnectionActivities[profile.id]?.result?.requiresRefresh, true)
        await fixture.model.refreshRemoteLocations()
        await fixture.model.connectFileVFS(profile)
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 1)
        await fixture.model.connectFileVFS(profile, review: true)
        XCTAssertNil(fixture.model.fileVFSConnectionActivities[profile.id])
        XCTAssertEqual(fixture.model.remoteVFSProfiles.first?.state, .connected)
        let after = await fixture.repository.writeCalls; XCTAssertEqual(after, 1)
        let reviews = await fixture.repository.vfsReviews; XCTAssertEqual(reviews, 1)
    }

    func test直接连接明确失败允许用户重试() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profile = remoteFlowProfile(fixture.model.profile.id, protocolID: "davs", state: .disconnected)
        await fixture.repository.configureVFS(profiles: [profile], status: .confirmedFailure)
        await fixture.model.connectFileVFS(profile)
        XCTAssertEqual(fixture.model.fileVFSConnectionActivities[profile.id]?.result?.status, .confirmedFailure)
        XCTAssertEqual(fixture.model.fileVFSConnectionActivities[profile.id]?.isBusy, false)
        await fixture.repository.configureVFS(profiles: [profile], status: .confirmedSuccess)
        await fixture.model.connectFileVFS(profile)
        XCTAssertNil(fixture.model.fileVFSConnectionActivities[profile.id])
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 2)
    }

    func test直接连接不接受其他NAS条目已连接条目或关闭文件模块() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.model.connectFileVFS(remoteFlowProfile(UUID(), protocolID: "davs", state: .disconnected))
        await fixture.model.connectFileVFS(remoteFlowProfile(fixture.model.profile.id, protocolID: "davs"))
        fixture.model.isFileModuleEnabled = false
        await fixture.model.connectFileVFS(remoteFlowProfile(fixture.model.profile.id, protocolID: "davs", state: .disconnected))
        XCTAssertTrue(fixture.model.fileVFSConnectionActivities.isEmpty)
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
    }

    func test主页同时加载共享文件夹和协议连接且排除分享占位() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profiles = remoteFlowProfiles(fixture.model.profile.id)
        await fixture.repository.configureVFS(profiles: profiles + [remoteFlowProfile(fixture.model.profile.id, protocolID: "sharing")])
        await fixture.repository.configureVirtualFolders([.init(item: .init(profileID: fixture.model.profile.id, name: "SMB Sample", path: "/synthetic/mount", kind: .directory), protocolType: .cifs)])
        await fixture.model.refreshRemoteLocations()
        XCTAssertEqual(fixture.model.remoteLocations.count, 1)
        XCTAssertEqual(fixture.model.remoteVFSProfiles, profiles)
        XCTAssertTrue(fixture.model.remoteLocationsHasLoaded)
        XCTAssertFalse(fixture.model.isLoadingRemoteLocations)
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
    }

    func test连接读取失败保留其他来源和之前可见连接并提示刷新() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profiles = remoteFlowProfiles(fixture.model.profile.id)
        fixture.model.remoteVFSProfiles = profiles
        await fixture.repository.configureVirtualFolders([.init(item: .init(profileID: fixture.model.profile.id, name: "SMB Sample", path: "/synthetic/mount", kind: .directory), protocolType: .cifs)])
        await fixture.repository.configureVFS(profiles: [], readFails: true)
        await fixture.model.refreshRemoteLocations()
        XCTAssertEqual(fixture.model.remoteLocations.count, 1)
        XCTAssertEqual(fixture.model.remoteVFSProfiles, profiles)
        XCTAssertNotNil(fixture.model.remoteVFSProfilesError)
        XCTAssertNil(fixture.model.remoteLocationsError)
    }

    func test连接成功返回前自动更新主页列表() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        await fixture.repository.configureVFS(profiles: [], status: .confirmedSuccess)
        let result = try await fixture.model.changeFileVFS(.create(remoteFlowConfiguration))
        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(fixture.model.remoteVFSProfiles.map(\.alias), [remoteFlowConfiguration.alias])
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 1)
        let reads = await fixture.repository.vfsReads; XCTAssertEqual(reads, 1)
    }

    func test失败与结果未知不触发成功刷新或自动重试() async throws {
        for status in [MutationResultStatus.confirmedFailure, .submittedButUnverified] {
            let fixture = try WorkspaceViewFixture(count: 0)
            defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
            await fixture.repository.configureAdvanced(state: "ready")
            await fixture.repository.configureVFS(profiles: [], status: status)
            let result = try await fixture.model.changeFileVFS(.create(remoteFlowConfiguration))
            XCTAssertEqual(result.status, status)
            XCTAssertFalse(fixture.model.remoteLocationsHasLoaded)
            let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 1)
            let reads = await fixture.repository.vfsReads; XCTAssertEqual(reads, 0)
        }
    }

    func test只读查看结果确认成功后更新主页而不重新连接() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profiles = remoteFlowProfiles(fixture.model.profile.id)
        await fixture.repository.configureVFS(profiles: profiles)
        let result = try await fixture.model.changeFileVFS(.create(remoteFlowConfiguration), review: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(fixture.model.remoteVFSProfiles, profiles)
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
        let reviews = await fixture.repository.vfsReviews; XCTAssertEqual(reviews, 1)
    }

    func test云盘授权保存成功也更新主页() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        let profile = remoteFlowProfile(fixture.model.profile.id, protocolID: "google")
        await fixture.repository.configureVFS(profiles: [profile], status: .confirmedSuccess)
        let auth = FileVFSCloudAuthorization(requestID: UUID(), profileID: fixture.model.profile.id, protocolID: "google",
            account: "synthetic", clientID: nil, accessToken: "synthetic-token", refreshToken: nil, expiresIn: nil)
        let result = try await fixture.model.authorizeFileVFS(.createCloud(.init(protocolID: "google", alias: profile.alias, account: "synthetic")), authorization: auth)
        XCTAssertEqual(result.status, .confirmedSuccess)
        XCTAssertEqual(fixture.model.remoteVFSProfiles, [profile])
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 1)
    }

    func test旧刷新晚到不覆盖连接成功后的新列表() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        await fixture.repository.configureAdvanced(state: "ready")
        await fixture.repository.configureVFS(profiles: [])
        await fixture.repository.holdNextVFSRead()
        let oldRefresh = Task { await fixture.model.refreshRemoteLocations() }
        for _ in 0..<100 {
            if await fixture.repository.hasHeldVFSRead { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let held = await fixture.repository.hasHeldVFSRead; XCTAssertTrue(held)
        let profiles = remoteFlowProfiles(fixture.model.profile.id)
        await fixture.repository.configureVFS(profiles: profiles)
        await fixture.model.refreshRemoteLocations()
        await fixture.repository.releaseVFSRead(); await oldRefresh.value
        XCTAssertEqual(fixture.model.remoteVFSProfiles, profiles)
        XCTAssertFalse(fixture.model.isLoadingRemoteLocations)
    }
}

private var remoteFlowConfiguration: FileVFSConfiguration {
    .init(protocolID: "davs", hostname: "example.invalid", port: 443, alias: "Sample WebDAV", account: "synthetic", folder: "photos")
}
private func remoteFlowProfile(_ profileID: UUID, protocolID: String, state: FileVFSProfile.State = .connected) -> FileVFSProfile {
    .init(profileID: profileID, id: "synthetic-" + protocolID, protocolID: protocolID, protocolName: protocolID.uppercased(),
        uri: protocolID + "://synthetic", hostname: "example.invalid", port: 443, alias: "Sample " + protocolID.uppercased(),
        account: "synthetic", codepage: "UTF-8", state: state)
}
private func remoteFlowProfiles(_ profileID: UUID) -> [FileVFSProfile] {
    ["ftp", "sftp", "davs", "google"].map { remoteFlowProfile(profileID, protocolID: $0, state: $0 == "ftp" ? .disconnected : .connected) }
}
private func remoteFlowResult(_ status: MutationResultStatus) throws -> MutationResult {
    let success = status == .confirmedSuccess, unknown = status == .submittedButUnverified
    return try .init(status: status, operation: "fileStationRemoteConnection", submitted: true, requiresRefresh: unknown,
        counts: .init(succeeded: success ? 1 : 0, failed: success || unknown ? 0 : 1, unknown: unknown ? 1 : 0))
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
    private(set) var shareEdits: [FileShareLinkEditRequest] = []
    private(set) var readCalls = 0
    private(set) var directorySizeCalls = 0
    private var advancedState: String?
    private var advancedAccessOverride: FileStationAdvancedAccess?
    private var permissionEditable = true
    private var mountDirectoriesOverride: [FileStationMountDirectory]?
    private var bandwidthPolicyOverride: FileStationBandwidthPolicy?
    func configureBandwidth(policy: FileStationBandwidthPolicy) { bandwidthPolicyOverride = policy }
    private(set) var mountAccountKinds: [FileStationPrincipal.Kind] = []
    func configureMountDirectories(_ directories: [FileStationMountDirectory]) { mountDirectoriesOverride = directories }
    private var advancedWaiters: [CheckedContinuation<Void, Never>] = []
    private var vfsProfilesOverride: [FileVFSProfile]?
    private var virtualFolders: [FileVirtualFolder] = []
    func configureVirtualFolders(_ folders: [FileVirtualFolder]) { virtualFolders = folders }
    func listVirtualFolders(offset: Int, limit: Int) -> FileVirtualFolderPage {
        .init(folders: virtualFolders, offset: 0, total: virtualFolders.count, hasMore: false)
    }
    private var vfsMutationStatus: MutationResultStatus?
    private var vfsReviewStatus: MutationResultStatus = .confirmedSuccess
    private var vfsReadFails = false
    private var holdsNextVFSRead = false
    private var vfsReadWaiter: CheckedContinuation<Void, Never>?
    private var holdsNextVFSChange = false
    private var vfsChangeWaiter: CheckedContinuation<Void, Never>?
    var hasHeldVFSChange: Bool { vfsChangeWaiter != nil }
    func holdNextVFSChange() { holdsNextVFSChange = true }
    func releaseVFSChange() { vfsChangeWaiter?.resume(); vfsChangeWaiter = nil }
    private(set) var vfsReads = 0
    private(set) var vfsReviews = 0
    var hasHeldVFSRead: Bool { vfsReadWaiter != nil }
    func configureVFS(profiles: [FileVFSProfile], status: MutationResultStatus? = nil, readFails: Bool = false) {
        vfsProfilesOverride = profiles; vfsMutationStatus = status; vfsReadFails = readFails
    }
    func holdNextVFSRead() { holdsNextVFSRead = true }
    func releaseVFSRead() { vfsReadWaiter?.resume(); vfsReadWaiter = nil }
    func configureAdvanced(state: String, access: FileStationAdvancedAccess? = nil, permissionEditable: Bool = true) {
        advancedState = state; advancedAccessOverride = access; self.permissionEditable = permissionEditable
    }
    func releaseAdvancedReads() {
        if advancedState == "loading" { advancedState = "ready" }
        let waiters = advancedWaiters; advancedWaiters = []; waiters.forEach { $0.resume() }
    }
    private func advancedRead() async throws {
        readCalls += 1
        if advancedState == "loading" { await withCheckedContinuation { advancedWaiters.append($0) } }
        if advancedState == nil || advancedState == "error" { throw PresentationRepositoryError.unexpectedOperation }
    }
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess {
        try await advancedRead(); return advancedAccessOverride ?? .init(isAdministrator: true, writesEnabled: vfsMutationStatus != nil)
    }
    func loadFilePermissions(_ item: FileItem) async throws -> FilePermissionSnapshot {
        try await advancedRead()
        return .init(target: item, resolvedPath: "/volume-synthetic" + item.path, isACL: true, canChangePermissions: permissionEditable,
            isInherited: true, rules: advancedState == "empty" ? [] : [
                .init(ownerType: "user", ownerName: "示例账号 Synthetic user", effect: .allow, rights: [.readData, .readAttributes, .readPermissions], inheritance: [.thisFolder]),
                .init(ownerType: "group", ownerName: "示例群组 Synthetic group", effect: .allow, rights: [.readData], inheritance: [.childFiles], level: 1)],
            owner: .init(name: "示例账号 Synthetic user", type: "user", value: "user:synthetic", canChange: permissionEditable), posixMode: nil)
    }
    func remoteMountInventory() async throws -> RemoteMountInventory {
        try await advancedRead()
        return .init(profileID: profileID, isRemoteMountingEnabled: true, connections: [],
            isoConnections: advancedState == "empty" ? [] : [.init(profileID: profileID, source: "/synthetic/示例 Sample.iso", mountPoint: "/synthetic/mount", automaticMount: false)],
            isISOMountingEnabled: true)
    }
    func listFileVFSProtocols() async throws -> [FileVFSProtocol] {
        try await advancedRead()
        return [.init(id: "dav", name: "WebDAV", defaultPort: 80, hasConnections: false),
                .init(id: "davs", name: "WebDAV HTTPS", defaultPort: 443, hasConnections: false)]
    }
    func listFileVFSProfiles() async throws -> [FileVFSProfile] {
        vfsReads += 1
        try await advancedRead()
        if vfsReadFails { throw PresentationRepositoryError.unexpectedOperation }
        if let profiles = vfsProfilesOverride {
            if holdsNextVFSRead {
                holdsNextVFSRead = false
                await withCheckedContinuation { vfsReadWaiter = $0 }
            }
            return profiles
        }
        return advancedState == "empty" ? [] : [.init(profileID: profileID, id: "synthetic-vfs", protocolID: "sftp", protocolName: "SFTP",
            uri: "sftp://synthetic", hostname: "example.invalid", port: 22, alias: "远程位置 Remote", account: "synthetic", codepage: "UTF-8", state: .connected)]
    }
    func loadFileVFSDetail(_ profile: FileVFSProfile) async throws -> FileVFSDetail {
        try await advancedRead()
        return .init(profile: profile, configuration: .init(protocolID: profile.protocolID,
            hostname: profile.hostname ?? "", port: profile.port ?? 443, alias: profile.alias,
            account: profile.account ?? "", codepage: profile.codepage ?? "UTF-8", folder: "photos"))
    }
    func prepareFileVFSCloudAuthorization(protocolID: String) async throws -> FileVFSCloudAuthorizationRequest {
        try await advancedRead()
        return .init(profileID: profileID, protocolID: protocolID, loginURL: URL(string: "https://authorization.invalid/signin")!,
            callbackName: "_webfmOAuthCallback")
    }
    func listFileVFSFolder(_ profile: FileVFSProfile, path: String, offset: Int, limit: Int) async throws -> FilePage {
        try await advancedRead()
        let items: [FileItem] = advancedState == "empty" ? [] : [
            .init(profileID: profileID, name: "资料 Folder", path: path + "/folder", kind: .directory),
            .init(profileID: profileID, name: "说明 Readme.txt", path: path + "/readme.txt", kind: .file)]
        return .init(folderPath: path, items: items, offset: 0, total: items.count, hasMore: false)
    }
    func loadFileStationMountDirectories() async throws -> FileStationMountDirectories {
        try await advancedRead(); return .init(items: mountDirectoriesOverride ?? [.init(source: .local, name: ""), .init(source: .ldap, name: ""), .init(source: .domain("SYNTHETIC"), name: "SYNTHETIC")], hasUnavailableSources: false)
    }
    func loadFileStationSettings() async throws -> FileStationSettings {
        try await advancedRead()
        return .init(profileID: profileID, recordsTransfers: true, usesDefaultPermissions: false, showsAccounts: true, sharing: .administrators,
            fileRequests: .administrators, remoteMounts: .administrators, isoMounts: .administrators, sharingAccounts: [], requestAccounts: [],
            defaultLinkLimit: 1000, bandwidth: .scheduled, schedule: String(repeating: "1", count: 168), usesCustomSharingPage: true)
    }
    func loadFileStationMountAccess() async throws -> FileStationMountAccessScope { try await advancedRead(); return .selected }
    func listFileStationBandwidth(ownerType: FileStationBandwidthEntry.OwnerType, offset: Int, limit: Int) async throws -> FileStationBandwidthPage {
        try await advancedRead()
        let rows: [FileStationBandwidthEntry] = advancedState == "empty" ? [] : [.init(profileID: profileID, name: "示例账号 Synthetic user", ownerType: ownerType,
            policy: bandwidthPolicyOverride ?? .scheduled, schedule: String(repeating: "1", count: 168), uploadLimit: 42, downloadLimit: 84, alternateUploadLimit: 24, alternateDownloadLimit: 48)]
        return .init(items: rows, total: rows.count, nextOffset: rows.count)
    }
    func loadFileStationSharingTheme() async throws -> FileStationSharingTheme {
        try await advancedRead()
        return .init(profileID: profileID, customLogo: true, customBackground: true, logoPosition: .topLeft,
            backgroundPosition: .fill, backgroundColor: "#FFFFFF", footer: "分享示例 Shared sample", footerUsesHTML: false)
    }
    func listFileStationMountAccounts(kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationMountAccountPage {
        try await advancedRead()
        mountAccountKinds.append(kind)
        let rows: [FileStationMountAccount] = advancedState == "empty" || !query.isEmpty ? [] : [.init(profileID: profileID, id: .init(kind: kind, value: 1001),
            name: "示例账号 Synthetic user", enabled: true, canModify: true)]
        return .init(items: rows, total: rows.count, nextOffset: rows.count)
    }
    func pendingFileStationChanges() async -> [FileStationPendingChange] {
        advancedState == "empty" ? [] : [.init(id: "settings:general", kind: .general), .init(id: "permissions:synthetic", kind: .permissions, target: "/synthetic/资料 Folder")]
    }
    func changeFilePermissions(_ change: FilePermissionChange) throws -> MutationResult { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func changeFileStationSettings(_ change: FileStationSettingsChange, confirmed: Bool) throws -> MutationResult { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func changeISOMount(_ change: FileISOMountChange) throws -> MutationResult { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func changeFileVFS(_ change: FileVFSChange, password: String?, confirmed: Bool) async throws -> MutationResult {
        writeCalls += 1
        guard confirmed, let status = vfsMutationStatus else { throw PresentationRepositoryError.unexpectedOperation }
        if holdsNextVFSChange {
            holdsNextVFSChange = false
            await withCheckedContinuation { vfsChangeWaiter = $0 }
        }
        if status == .confirmedSuccess, case .create(let value) = change {
            vfsProfilesOverride = [.init(profileID: profileID, id: "created-vfs", protocolID: value.protocolID,
                protocolName: "WebDAV HTTPS", uri: "davs://synthetic", hostname: value.hostname, port: value.port,
                alias: value.alias, account: value.account, codepage: value.codepage, state: .connected)]
        }
        if status == .confirmedSuccess, case .update(let baseline, let value) = change {
            vfsProfilesOverride = [.init(profileID: profileID, id: baseline.profile.id, protocolID: value.protocolID,
                protocolName: baseline.profile.protocolName, uri: baseline.profile.uri, hostname: value.hostname,
                port: value.port, alias: value.alias, account: value.account, codepage: value.codepage, state: .connected)]
        }
        if status == .confirmedSuccess { completeSyntheticConnection(change) }
        return try remoteFlowResult(status)
    }
    func reviewFileVFS(_ change: FileVFSChange) throws -> MutationResult {
        vfsReviews += 1
        if vfsReviewStatus == .confirmedSuccess { completeSyntheticConnection(change) }
        return try remoteFlowResult(vfsReviewStatus)
    }
    private func completeSyntheticConnection(_ change: FileVFSChange) {
        guard case .connect(let profile) = change else { return }
        vfsProfilesOverride = vfsProfilesOverride?.map { item in
            guard item.id == profile.id else { return item }
            return .init(profileID: item.profileID, id: item.id, protocolID: item.protocolID, protocolName: item.protocolName,
                uri: item.uri, hostname: item.hostname, port: item.port, alias: item.alias, account: item.account,
                codepage: item.codepage, state: .connected)
        }
    }
    func authorizeFileVFS(_ change: FileVFSChange, authorization: FileVFSCloudAuthorization, confirmed: Bool) async throws -> MutationResult {
        try await changeFileVFS(change, password: nil, confirmed: confirmed)
    }
    private var nextFolderError: AppError?
    private var archiveItem: FileItem?
    private var archiveEntries: [Int: [ArchiveItem]] = [:]
    private var archiveFails = false
    private var archiveHeld = false
    private var archiveWaiter: CheckedContinuation<Void, Never>?
    func configureArchive(_ item: FileItem, entries: [Int: [ArchiveItem]], fails: Bool = false, held: Bool = false) {
        archiveItem = item; archiveEntries = entries; archiveFails = fails; archiveHeld = held
    }
    func releaseArchive() { archiveHeld = false; archiveWaiter?.resume(); archiveWaiter = nil }
    func listArchivePage(filePath: String, parentID: Int, offset: Int, limit: Int, codepage: String?, password: String?) async throws -> ArchiveItemPage {
        readCalls += 1
        if archiveHeld { await withCheckedContinuation { archiveWaiter = $0 } }
        if archiveFails || archiveItem == nil { throw PresentationRepositoryError.unexpectedOperation }
        let all = archiveEntries[parentID] ?? [], page = Array(all.dropFirst(offset).prefix(limit))
        return .init(items: page, offset: offset, total: all.count, hasMore: offset + page.count < all.count)
    }
    private var searchWaiters: [String: CheckedContinuation<[FileItem], Never>] = [:]
    func isSearchPending(_ name: String) -> Bool { searchWaiters[name] != nil }
    func finishSearch(_ name: String) {
        searchWaiters.removeValue(forKey: name)?.resume(returning: [FileItem(profileID: profileID, name: name,
            path: "/synthetic/" + name, kind: .file)])
    }
    func search(_ request: FileSearchRequest) async -> [FileItem] {
        await withCheckedContinuation { searchWaiters[request.name] = $0 }
    }
    init(profileID: UUID) { self.profileID = profileID }
    func listShares(offset: Int, limit: Int) async throws -> FilePage {
        if advancedState != nil { try await advancedRead() }
        readCalls += 1; return page(path: "/", offset: offset)
    }
    func failNextFolderRead(_ error: AppError) { nextFolderError = error }
    private var folderItems: [String: [FileItem]] = [:]
    func setFolderItems(_ items: [FileItem], path: String) { folderItems[path] = items }
    func listFolder(path: String, offset: Int, limit: Int) throws -> FilePage {
        readCalls += 1
        if let error = nextFolderError { nextFolderError = nil; throw error }
        if let items = folderItems[path] {
            let pageItems = Array(items.dropFirst(offset).prefix(limit))
            return FilePage(folderPath: path, items: pageItems, offset: offset, total: items.count, hasMore: offset + pageItems.count < items.count)
        }
        return page(path: path, offset: offset)
    }
    func getInfo(paths: [String]) -> [FileItem] {
        readCalls += 1
        return archiveItem.map { paths.contains($0.path) ? [$0] : [] } ?? []
    }
    func calculateDirectorySize(path: String) -> FileDirectorySizeSummary {
        readCalls += 1
        directorySizeCalls += 1
        return .init(totalBytes: Int64(directorySizeCalls) * 125_000, fileCount: 10, directoryCount: 2)
    }
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
    func editShareLink(_ request: FileShareLinkEditRequest) throws -> FileShareLinkEditOutcome {
        shareEdits.append(request)
        throw PresentationRepositoryError.unexpectedOperation
    }
    func createShareLink(paths: [String], password: String?, expiresAt: String?) throws -> FileShareLink { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    func deleteShareLinks(ids: [String]) throws { try rejectWrite() }
    private func rejectWrite() throws { writeCalls += 1; throw PresentationRepositoryError.unexpectedOperation }
    private func page(path: String, offset: Int) -> FilePage { FilePage(folderPath: path, items: [], offset: offset, total: 0, hasMore: false) }
}
private struct SynologyPhotosPresentationFixture: SynologyPhotosServing {
    let image: Data
    var empty = false
    var fails = false
    var waits = false
    func categories() async throws -> Set<SynologyPhotoCategory> { Set(SynologyPhotoCategory.allCases) }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        var result = photo
        result.camera = "Sample camera"; result.lens = "Sample lens"; result.aperture = "2.8"
        result.exposureTime = "1/125"; result.focalLength = "35"; result.iso = "100"; result.rating = 4
        return result
    }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { image }
    func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions {
        SynologyPhotoFilterOptions(people: [SynologyPhotoCollection(id: 8, name: "Sample person")],
            locations: [SynologyPhotoLocation(id: 9, name: "Sample place", level: 1)],
            tags: [.init(id: 1, name: "Sample tag")], cameras: [.init(id: 2, name: "Sample camera")],
            lenses: [.init(id: 3, name: "Sample lens")], isoValues: [.init(id: 4, name: "100")],
            apertures: [.init(id: 5, name: "2.8")], focalRanges: [.init(start: 22, end: 35)],
            exposureRanges: [.init(start: .init(num: 1, den: 500), end: .init(num: 1, den: 60))])
    }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry] {
        [SynologyPhotoSharedEntry(id: "sample", title: "Sample shared album", albumID: 71)]
    }
    private let profileID = UUID()
    func access() async throws -> SynologyPhotosAccess {
        if fails { throw URLError(.notConnectedToInternet) }
        if waits { try await Task.sleep(for: .seconds(30)) }
        return SynologyPhotosAccess(spaces: [.personal], packageVersion: "1.8.2-10090")
    }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        empty ? [] : [SynologyPhotoDay(year: 2026, month: 1, day: 1, itemCount: 1)]
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { [] }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        let photo = SynologyPhoto(id: SynologyPhotoID(profileID: profileID, space: space, unitID: 1),
            filename: "Sample.jpg", sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 100),
            indexedAt: Date(timeIntervalSince1970: 100), folderID: 42, mediaType: "photo",
            thumbnail: SynologyPhotoThumbnail(unitID: 1, revision: "fixture"))
        return SynologyPhotoPage(items: [photo], offset: offset, nextOffset: offset + 1, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { image }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { SynologyPhotoCollection(id: 42, name: "/") }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        [SynologyPhotoCollection(id: 43, name: "Sample folder", parentID: 42)]
    }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        [SynologyPhotoCollection(id: 71, name: "Sample album", itemCount: 1)]
    }
}

@MainActor
final class FileStationSearchWorkflowTests: XCTestCase {
    func test正文结果不按文件名二次过滤且正则保留名称语义() throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        let model = fixture.model
        model.searchText = "contents-only"
        model.advancedSearch = .init(folders: ["/synthetic"], name: model.searchText, searchesContents: true)
        model.recursiveSearchResults = [.init(profileID: model.profile.id, name: "report.txt", path: "/synthetic/report.txt", kind: .file)]
        XCTAssertEqual(model.filteredItems.map(\.name), ["report.txt"])
        model.searchText = "/report.*/"
        XCTAssertNotNil(model.searchErrorMessage)
        model.advancedSearch?.searchesContents = false
        XCTAssertNil(model.searchErrorMessage)
        XCTAssertEqual(model.filteredItems.count, 1)
    }

    func test旧搜索晚返回不能覆盖新搜索且取消不接受结果() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        let model = fixture.model
        model.searchScope = .subfolders
        model.searchText = "old"; model.updateSearch()
        try await waitForSearch("old", repository: fixture.repository)
        model.searchText = "new"; model.updateSearch()
        try await waitForSearch("new", repository: fixture.repository)
        await fixture.repository.finishSearch("new")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.recursiveSearchResults.map(\.name), ["new"])
        await fixture.repository.finishSearch("old")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.recursiveSearchResults.map(\.name), ["new"])
        model.searchText = "cancel"; model.updateSearch()
        try await waitForSearch("cancel", repository: fixture.repository)
        model.cancelSearch(); await fixture.repository.finishSearch("cancel")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.recursiveSearchResults.isEmpty)
        XCTAssertFalse(model.isSearching)
    }

    private func waitForSearch(_ name: String, repository: PresentationFileRepository) async throws {
        for _ in 0..<120 {
            if await repository.isSearchPending(name) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("搜索未发起")
    }
}

@MainActor
final class FileArchiveWorkflowTests: XCTestCase {
    func test重复上传目标在传输列表中立即失败且不能重试() throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        let sources = ["a", "b"].map { name in
            let url = URL(fileURLWithPath: "/synthetic-local/" + name)
            return FileUploadSource(url: url, relativePath: "duplicate", kind: .file, size: 0, modifiedAt: nil, access: .init(url))
        }
        fixture.model.beginUploadBatch(sources: sources, destination: "/synthetic", overwrite: false)
        XCTAssertEqual(fixture.model.transfers.count, 2)
        XCTAssertTrue(fixture.model.transfers.allSatisfy { $0.state == .failed && !fixture.model.canRetryTransfer($0.id) })
        XCTAssertFalse(fixture.model.uploadBatches[0].isRunning)
    }

    func test目录浏览分页选择子树且空选择不解压() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        let item = FileItem(profileID: fixture.model.profile.id, name: "archive.zip", path: "/synthetic/archive.zip", kind: .file, sizeBytes: 42)
        let folder = ArchiveItem(id: 1, name: "folder", path: "folder", isDirectory: true)
        let children = (2...202).map { ArchiveItem(id: $0, name: "\($0).txt", path: "folder/\($0).txt", isDirectory: false, sizeBytes: 0) }
        await fixture.repository.configureArchive(item, entries: [-1: [folder, .init(id: 300, name: "outside.txt", path: "outside.txt", isDirectory: false)], 1: children])
        let browser = fixture.model.makeArchiveBrowser(item)
        await browser.reload(); browser.extractAll = false
        XCTAssertFalse(browser.canExtract)
        do { _ = try await browser.prepare(); XCTFail("空选择不能变成全部") } catch {}
        browser.selected[folder.id] = folder
        await browser.enter(folder)
        XCTAssertEqual(browser.items.count, 200); XCTAssertTrue(browser.hasMore)
        await browser.more(); XCTAssertEqual(browser.items.count, 201); XCTAssertFalse(browser.hasMore)
        await browser.back()
        let (request, inventory) = try await browser.prepare()
        XCTAssertEqual(request.selection, .items([folder]))
        XCTAssertEqual(inventory.count, 202); XCTAssertFalse(inventory.contains { $0.id == 300 })
        await fixture.repository.configureArchive(item, entries: [-1: [.init(id: 1, name: "renamed", path: "renamed", isDirectory: true)]])
        do { _ = try await browser.prepare(); XCTFail("所选项变化必须重新选择") } catch {}
        let writes = await fixture.repository.writeCalls; XCTAssertEqual(writes, 0)
    }

    func test覆盖与移除密码不再被实测开关阻断() async throws {
        let fixture = try WorkspaceViewFixture(count: 0)
        defer { fixture.model.cancelAllWork(); fixture.cleanPreferences() }
        let item = FileItem(profileID: fixture.model.profile.id, name: "archive.zip", path: "/synthetic/archive.zip", kind: .file)
        fixture.model.enqueueVerifiedExtraction(item, request: .init(filePath: item.path, destination: "/synthetic", overwrite: true), inventory: [])
        let url = URL(fileURLWithPath: "/synthetic-local-file")
        fixture.model.beginUploadBatch(sources: [.init(url: url, relativePath: "file", kind: .file, size: 0, modifiedAt: nil, access: .init(url))], destination: "/synthetic", overwrite: true)
        let link = FileShareLink(id: "synthetic", name: "item", path: "/synthetic/item", url: "https://example.invalid/shared", hasPassword: true)
        await fixture.model.editShareLinks([try .init(baseline: link, password: .remove, availableOn: nil, expiresOn: nil)])
        XCTAssertFalse(fixture.model.transfers.isEmpty); XCTAssertEqual(fixture.model.uploadBatches.count, 1)
        let edits = await fixture.repository.shareEdits
        XCTAssertEqual(edits.count, 1)
        guard case .remove = edits.first?.password else { return XCTFail("移除密码意图必须传递给仓库") }
    }
}
