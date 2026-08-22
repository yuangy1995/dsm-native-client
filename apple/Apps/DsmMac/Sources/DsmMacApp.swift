import AppKit
import DsmCore
import DsmLocalization
import FileProvider
import Foundation
import ServiceManagement
import SwiftUI
// Xcode 16.4 的 UserNotifications SDK 未标注部分结果类型为 Sendable；通知调用仍限定在主线程。
@preconcurrency import UserNotifications

@MainActor
protocol TransferNotifying: AnyObject {
    func prepareAuthorization()
    func notify(task: ActivityTask, profileName: String)
}

@MainActor
final class NoopTransferNotifier: TransferNotifying {
    func prepareAuthorization() {}
    func notify(task: ActivityTask, profileName: String) {}
}

@MainActor
enum TransferNotifierFactory {
    static func makeDefault() -> any TransferNotifying {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return NoopTransferNotifier()
        }
        return SystemTransferNotifier.shared
    }
}

@MainActor
final class SystemTransferNotifier: TransferNotifying {
    static let shared = SystemTransferNotifier()

    private let center: UNUserNotificationCenter
    private var isPreparingAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func prepareAuthorization() {
        guard !Self.isRunningTests, !isPreparingAuthorization else { return }
        isPreparingAuthorization = true
        Task { @MainActor in
            defer { isPreparingAuthorization = false }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func notify(task: ActivityTask, profileName: String) {
        guard !Self.isRunningTests,
              task.state == .succeeded || task.state == .failed else {
            return
        }
        Task { @MainActor in
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
                guard granted else { return }
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle(for: task)
            content.body = notificationBody(for: task, profileName: profileName)
            content.sound = .default
            content.threadIdentifier = "transfer.\(task.kind.rawValue)"
            let request = UNNotificationRequest(
                identifier: "transfer.\(task.id.uuidString).\(task.state.rawValue)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func notificationTitle(for task: ActivityTask) -> String {
        let operation: String
        switch task.kind {
        case .download: operation = L10n.string("ui.4673a23061656125")
        case .upload: operation = L10n.string("ui.9e07e3c0532d4976")
        case .copy: operation = L10n.string("ui.63d90d977348ab1f")
        case .move: operation = L10n.string("ui.fc6bb436b8caf08b")
        case .delete: operation = L10n.string("ui.2f9daa828907b93f")
        case .restore: operation = L10n.string("ui.e0534b8a4e46a0cb")
        case .compress: operation = L10n.string("ui.a22879cda61a8da0")
        case .extract: operation = L10n.string("ui.a147ebf3581ab1ee")
        }
        return task.state == .succeeded
            ? L10n.string("operation.completed", operation)
            : L10n.string("operation.not_completed", operation)
    }

    private func notificationBody(for task: ActivityTask, profileName: String) -> String {
        if task.state == .succeeded {
            return L10n.string("ui.3175795e4bb280b2", String(describing: task.displayName), String(describing: profileName))
        }
        let reason = task.failureMessage ?? L10n.string("ui.954110b2ccd1bacb")
        return L10n.string("ui.3721cf05827b270f", String(describing: task.displayName), String(describing: reason))
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

@MainActor
final class DesktopDriveMenuBarController: NSObject, NSMenuDelegate {
    static let shared = DesktopDriveMenuBarController()

    private let store = DesktopDriveConfigurationStore()
    private var statusItem: NSStatusItem?
    private var mappings: [DesktopDriveMapping] = []
    private var runtimes: [UUID: DesktopDriveMappingRuntime] = [:]
    private var operationInProgress = false

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "externaldrive.connected.to.line.below",
            accessibilityDescription: L10n.string("desktopDrive.menu.accessibility")
        )
        item.button?.toolTip = L10n.string("desktopDrive.menu.tooltip")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        guard DesktopCloudDriveAvailability.isAvailable else {
            return
        }
        Task {
            try? await store.setProviderAvailable(true)
            await reconnectAvailableMappings()
            await refreshState()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(
            withTitle: L10n.string("desktopDrive.menu.open"),
            action: #selector(openApplication),
            keyEquivalent: ""
        ).target = self

        let pausedCount = runtimes.values.filter(\.isManuallyPaused).count
        let toggleTitle = !mappings.isEmpty && pausedCount == mappings.count
            ? L10n.string("desktopDrive.menu.resumeAll")
            : L10n.string("desktopDrive.menu.pauseAll")
        let toggle = menu.addItem(
            withTitle: toggleTitle,
            action: #selector(toggleAllMappings),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = !mappings.isEmpty && !operationInProgress

        let issueCount = runtimes.values.filter {
            ![.available, .paused, .checking].contains($0.state)
        }.count
        let issues = NSMenuItem(
            title: L10n.string("desktopDrive.menu.issues", issueCount),
            action: nil,
            keyEquivalent: ""
        )
        issues.isEnabled = false
        menu.addItem(issues)
        menu.addItem(.separator())

        let launch = menu.addItem(
            withTitle: L10n.string("desktopDrive.menu.launchAtLogin"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("desktopDrive.menu.quit"),
            action: #selector(quitApplication),
            keyEquivalent: "q"
        ).target = self

        if DesktopCloudDriveAvailability.isAvailable {
            Task { await refreshState() }
        }
    }

    func prepareForTermination() async {
        operationInProgress = true
        guard DesktopCloudDriveAvailability.isAvailable else {
            statusItem = nil
            return
        }
        try? await store.setProviderAvailable(false)
        for mapping in mappings {
            guard let manager = NSFileProviderManager(for: Self.domain(for: mapping)) else {
                continue
            }
            try? await Self.disconnect(
                manager,
                reason: L10n.string("desktopDrive.quit.reason")
            )
        }
        statusItem = nil
    }

    @objc private func openApplication() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // WindowGroup 在窗口被关闭后会响应标准的新建窗口动作。
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: self)
        }
    }

    @objc private func toggleAllMappings() {
        guard !operationInProgress else { return }
        operationInProgress = true
        Task {
            defer {
                operationInProgress = false
                statusItem?.menu?.update()
            }
            await refreshState()
            let shouldResume = !mappings.isEmpty
                && runtimes.values.filter(\.isManuallyPaused).count == mappings.count
            for mapping in mappings {
                guard let manager = NSFileProviderManager(for: Self.domain(for: mapping)) else {
                    continue
                }
                if shouldResume {
                    try? await Self.reconnect(manager)
                    try? await store.setMappingPaused(false, mappingID: mapping.id)
                    try? await store.setMappingState(.checking, mappingID: mapping.id)
                } else {
                    try? await Self.disconnect(
                        manager,
                        reason: L10n.string("desktopDrive.pause.reason")
                    )
                    try? await store.setMappingPaused(true, mappingID: mapping.id)
                }
            }
            await refreshState()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        statusItem?.menu?.update()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func refreshState() async {
        mappings = (try? await store.mappings()) ?? []
        var values: [UUID: DesktopDriveMappingRuntime] = [:]
        for mapping in mappings {
            values[mapping.id] = try? await store.runtime(mappingID: mapping.id)
        }
        runtimes = values
        statusItem?.button?.toolTip = L10n.string("desktopDrive.menu.tooltip")
    }

    private func reconnectAvailableMappings() async {
        let mappings = (try? await store.mappings()) ?? []
        for mapping in mappings {
            guard let runtime = try? await store.runtime(mappingID: mapping.id),
                  !runtime.isManuallyPaused,
                  let manager = NSFileProviderManager(for: Self.domain(for: mapping)) else {
                continue
            }
            try? await Self.reconnect(manager)
        }
    }

    private static func domain(
        for mapping: DesktopDriveMapping
    ) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                mapping.providerDomainIdentifier ?? mapping.id.uuidString
            ),
            displayName: mapping.displayName
        )
    }

    private static func disconnect(
        _ manager: NSFileProviderManager,
        reason: String
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.disconnect(reason: reason, options: [.temporary]) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func reconnect(
        _ manager: NSFileProviderManager
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            manager.reconnect { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var isTerminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        DesktopDriveMenuBarController.shared.start()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // App 在前台活动时，通知全部通过 App 内内置悬浮 Toast 展示，取消系统右上角弹出 Banner 打扰
        [.sound]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 自动解除所有附着在窗口上的 Modal Sheet 或弹窗，确保 App 能响应 ⌘Q 和 Dock 菜单退出
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true
        Task { @MainActor in
            await DesktopDriveMenuBarController.shared.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关闭最后一个窗口后继续保持后台运行，只有用户明确退出时才结束应用。
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag,
              let window = sender.windows.first(where: { !($0 is NSPanel) }) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct DsmMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var language = AppLanguageStore.shared

    init() {
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup(language.string("app.name")) {
            RootView(model: model)
                .environment(language)
                .environment(\.locale, language.locale)
                .task {
                    model.load()
                }
        }
        .defaultSize(width: 1_260, height: 780)
        .windowResizability(.contentMinSize)
    }
}
