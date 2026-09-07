import AppKit
import Combine
import DsmCore
import DsmLocalization
import Sparkle
import SwiftUI

/// 更新包交给 Sparkle 校验和安装；这里只管理应用语言、用户确认和重启时机。
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private(set) var updater: SPUUpdater?
    private let configuredFeedURL: String
    let driver = AppUpdateUserDriver()

    init(bundle: Bundle = .main, canRestart: @escaping @MainActor () -> Bool) {
        configuredFeedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? Self.feedURL
        super.init()
        driver.canRestart = canRestart
        guard Self.isConfigured(bundle.infoDictionary ?? [:]) else { return }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        } catch {
            // 不把底层错误及本机路径带入界面；用户仍可使用手动下载安装。
            self.updater = nil
        }
    }

    static let feedURL = "https://github.com/yuangy1995/dsm-native-client/releases/download/macos-updates/appcast.xml"
    static let validationFeedURL = "https://github.com/yuangy1995/dsm-native-client/releases/download/macos-validation-updates/appcast.xml"

    static func isConfigured(_ info: [String: Any]) -> Bool {
        info["LanStashOnlineUpdatesEnabled"] as? Bool == true
            && [feedURL, validationFeedURL].contains(info["SUFeedURL"] as? String ?? "")
            && (info["SUPublicEDKey"] as? String).flatMap { Data(base64Encoded: $0) }?.count == 32
    }

    static func hasUnfinishedTransfers(_ tasks: [ActivityTask]) -> Bool {
        tasks.contains { ![.succeeded, .failed, .cancelled].contains($0.state) }
    }

    func checkForUpdates() {
        guard let updater else {
            driver.showMessage("updates.unavailable", detail: "updates.manual", acknowledgement: {})
            return
        }
        guard canCheckForUpdates else { driver.showUpdateInFocus(); return }
        updater.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func feedURLString(for updater: SPUUpdater) -> String? { configuredFeedURL }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }
}

@MainActor
final class AppUpdateUserDriver: NSObject, ObservableObject, SPUUserDriver {
    @Published private(set) var titleKey = "updates.title"
    @Published private(set) var detailKey = "updates.checking.detail"
    @Published private(set) var version: String?
    @Published private(set) var progress: Double?
    @Published private(set) var isWorking = false
    @Published private(set) var primaryKey: String?
    @Published private(set) var secondaryKey: String?
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var window: NSWindow?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private(set) var isRestartRequested = false
    var canRestart: @MainActor () -> Bool = { true }
    private let presentsWindows: Bool

    init(presentsWindows: Bool = true) {
        self.presentsWindows = presentsWindows
    }

    private func present(_ title: String, detail: String, working: Bool = false,
                         primary: String? = nil, action: (() -> Void)? = nil,
                         secondary: String? = nil, cancel: (() -> Void)? = nil) {
        titleKey = title
        detailKey = detail
        version = nil
        progress = nil
        isWorking = working
        primaryKey = primary
        secondaryKey = secondary
        primaryAction = action
        secondaryAction = cancel
        guard presentsWindows else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 340),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 460, height: 320)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppUpdateView(driver: self))
            window.center()
            self.window = window
        }
        window?.title = L10n.string("updates.title")
        showUpdateInFocus()
    }

    func performPrimaryAction() {
        let action = primaryAction
        primaryAction = nil
        secondaryAction = nil
        primaryKey = nil
        secondaryKey = nil
        action?()
    }

    func performSecondaryAction() {
        let action = secondaryAction
        primaryAction = nil
        secondaryAction = nil
        primaryKey = nil
        secondaryKey = nil
        action?()
    }

    func showMessage(_ title: String, detail: String, acknowledgement: @escaping () -> Void) {
        present(title, detail: detail, primary: "updates.close", action: { [weak self] in
            self?.dismissUpdateInstallation()
            acknowledgement()
        })
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        present("updates.automatic", detail: "updates.automatic.detail", primary: "updates.allow", action: { [weak self] in
            self?.dismissUpdateInstallation()
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        }, secondary: "updates.later", cancel: { [weak self] in
            self?.dismissUpdateInstallation()
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        })
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        present("updates.checking", detail: "updates.checking.detail", working: true,
                secondary: "updates.cancel", cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate {
            showMessage("updates.unavailable", detail: "updates.manual") { reply(.dismiss) }
            return
        }
        if state.stage == .installing {
            showReady(toInstallAndRelaunch: reply)
            return
        }
        present("updates.found", detail: "updates.found.detail", primary: "updates.download", action: {
            reply(.install)
        }, secondary: "updates.later", cancel: { reply(.dismiss) })
        version = appcastItem.displayVersionString
    }

    // 发布说明由 GitHub Release 页面提供，不加载第三方 HTML 或底层诊断文字。
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showMessage("updates.none", detail: "updates.none.detail", acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showMessage("updates.failed", detail: "updates.failed.detail", acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        present("updates.downloading", detail: "updates.downloading.detail", working: true,
                secondary: "updates.cancel", cancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        if expectedBytes > 0 { progress = min(1, Double(receivedBytes) / Double(expectedBytes)) }
    }

    func showDownloadDidStartExtractingUpdate() {
        present("updates.preparing", detail: "updates.preparing.detail", working: true)
    }

    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        present("updates.ready", detail: "updates.ready.detail", primary: "updates.install", action: { [weak self] in
            guard let self else { return }
            guard canRestart() else {
                showReady(toInstallAndRelaunch: reply)
                detailKey = "updates.busy"
                return
            }
            isRestartRequested = true
            reply(.install)
        }, secondary: "updates.cancel", cancel: { reply(.skip) })
        // .dismiss 会留下退出时自动安装的任务；取消必须使用 .skip。
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        present("updates.installing", detail: "updates.installing.detail", working: true,
                primary: applicationTerminated ? nil : "updates.install", action: { [weak self] in
            guard let self else { return }
            if canRestart() { retryTerminatingApplication() }
            else {
                showInstallingUpdate(withApplicationTerminated: false,
                                     retryTerminatingApplication: retryTerminatingApplication)
                detailKey = "updates.busy"
            }
        })
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        showMessage("updates.installed", detail: "updates.installed.detail", acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        isRestartRequested = false
        window?.orderOut(nil)
        window = nil
        primaryAction = nil
        secondaryAction = nil
        primaryKey = nil
        secondaryKey = nil
    }

    func showUpdateInFocus() {
        guard presentsWindows else { return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AppUpdateView: View {
    @ObservedObject var driver: AppUpdateUserDriver
    @State private var language = AppLanguageStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.string(driver.titleKey)).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(language.string(driver.detailKey)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let version = driver.version {
                    Text(language.string("updates.version", version))
                }
                if driver.isWorking {
                    ProgressView(value: driver.progress)
                        .accessibilityLabel(language.string(driver.titleKey))
                }
                Link(language.string("updates.releaseNotes"), destination: URL(string: "https://github.com/yuangy1995/dsm-native-client/releases")!)
                HStack {
                    Spacer()
                    if let key = driver.secondaryKey {
                        Button(language.string(key), action: driver.performSecondaryAction).keyboardShortcut(.cancelAction)
                    }
                    if let key = driver.primaryKey {
                        Button(language.string(key), action: driver.performPrimaryAction).keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .environment(\.locale, language.locale)
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject var controller: AppUpdateController
    @State private var language = AppLanguageStore.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(language.string("updates.check"), action: controller.checkForUpdates)
            Toggle(language.string("updates.automatic"), isOn: Binding(
                get: { controller.automaticallyChecksForUpdates },
                set: { controller.setAutomaticChecks($0) }
            )).disabled(controller.updater == nil)
        }
    }
}
