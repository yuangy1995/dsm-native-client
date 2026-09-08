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
    private let installedVersion: String?
    let driver = AppUpdateUserDriver()

    init(bundle: Bundle = .main, canRestart: @escaping @MainActor () -> Bool) {
        configuredFeedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? Self.feedURL
        installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
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

    var currentVersion: String { installedVersion ?? L10n.string("updates.versionUnknown") }

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
    enum PresentationStage: Equatable {
        case information, permission, checking, available, downloading, preparing, ready, installing, upToDate, completed, failed

        var symbol: String {
            switch self {
            case .information: "info.circle"
            case .permission: "bell.badge"
            case .checking: "arrow.triangle.2.circlepath"
            case .available, .downloading: "arrow.down.app"
            case .preparing: "shippingbox"
            case .ready, .installing: "arrow.clockwise.circle"
            case .upToDate, .completed: "checkmark.seal"
            case .failed: "exclamationmark.triangle"
            }
        }

        var showsReleaseNotes: Bool {
            switch self {
            case .available, .downloading, .ready, .information, .failed, .completed: true
            default: false
            }
        }
    }

    @Published private(set) var stage: PresentationStage = .information
    @Published private(set) var titleKey = "updates.title"
    @Published private(set) var detailKey = "updates.checking.detail"
    @Published private(set) var version: String?
    @Published private(set) var releaseNotes: String?
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

    private func present(_ title: String, detail: String, stage: PresentationStage = .information, working: Bool = false,
                         primary: String? = nil, action: (() -> Void)? = nil,
                         secondary: String? = nil, cancel: (() -> Void)? = nil) {
        titleKey = title
        detailKey = detail
        self.stage = stage
        if [.information, .permission, .checking, .available, .upToDate].contains(stage) {
            version = nil
            releaseNotes = nil
        }
        progress = nil
        isWorking = working
        primaryKey = primary
        secondaryKey = secondary
        primaryAction = action
        secondaryAction = cancel
        guard presentsWindows else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 500, height: 400)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppUpdateView(driver: self).macAppearanceRoot())
            window.center()
            self.window = window
        }
        window?.title = L10n.string("updates.title")
        showUpdateInFocus()
    }

    func performPrimaryAction() {
        guard let action = primaryAction else { return }
        primaryAction = nil
        secondaryAction = nil
        primaryKey = nil
        secondaryKey = nil
        if stage == .available {
            stage = .downloading
            titleKey = "updates.downloading"
            detailKey = "updates.downloading.detail"
            isWorking = true
        }
        action()
    }

    func performSecondaryAction() {
        guard let action = secondaryAction else { return }
        dismissUpdateInstallation()
        action()
    }

    var canDismiss: Bool { secondaryKey != nil || primaryKey == "updates.close" }

    func dismissByUser() {
        if secondaryKey != nil { performSecondaryAction() }
        else if primaryKey == "updates.close" { performPrimaryAction() }
    }

    func showMessage(_ title: String, detail: String, stage: PresentationStage = .information, acknowledgement: @escaping () -> Void) {
        present(title, detail: detail, stage: stage, primary: "updates.close", action: { [weak self] in
            self?.dismissUpdateInstallation()
            acknowledgement()
        })
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        present("updates.automatic", detail: "updates.automatic.detail", stage: .permission, primary: "updates.allow", action: { [weak self] in
            self?.dismissUpdateInstallation()
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        }, secondary: "updates.later", cancel: { [weak self] in
            self?.dismissUpdateInstallation()
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        })
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        present("updates.checking", detail: "updates.checking.detail", stage: .checking, working: true,
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
        showAvailable(version: appcastItem.displayVersionString, notes: appcastItem.itemDescription, reply: reply)
    }

    func showAvailable(version: String, notes: String?, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        present("updates.found", detail: "updates.found.detail", stage: .available, primary: "updates.download", action: {
            reply(.install)
        }, secondary: "updates.later", cancel: { reply(.dismiss) })
        self.version = version
        // 只展示更新源内已有的说明文本，不加载网页、图片或执行 HTML。
        releaseNotes = notes?
            .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|li|div|h[1-6])>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 不额外下载发布说明，完整版本页面仍通过用户点击打开。
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showMessage("updates.none", detail: "updates.none.detail", stage: .upToDate, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        showMessage("updates.failed", detail: "updates.failed.detail", stage: .failed, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        present("updates.downloading", detail: "updates.downloading.detail", stage: .downloading, working: true,
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
        present("updates.preparing", detail: "updates.preparing.detail", stage: .preparing, working: true)
    }

    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        present("updates.ready", detail: "updates.ready.detail", stage: .ready, primary: "updates.install", action: { [weak self] in
            guard let self else { return }
            guard canRestart() else {
                showReady(toInstallAndRelaunch: reply)
                detailKey = "updates.busy"
                return
            }
            isRestartRequested = true
            stage = .installing
            titleKey = "updates.installing"
            detailKey = "updates.installing.detail"
            isWorking = true
            reply(.install)
        }, secondary: "updates.cancel", cancel: { reply(.skip) })
        // .dismiss 会留下退出时自动安装的任务；取消必须使用 .skip。
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        present("updates.installing", detail: "updates.installing.detail", stage: .installing, working: true,
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
        showMessage("updates.installed", detail: "updates.installed.detail", stage: .completed, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        isRestartRequested = false
        isWorking = false
        progress = nil
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

// 保持模块内可见，供隔离窗口检查复用真实更新界面。
struct AppUpdateView: View {
    @ObservedObject var driver: AppUpdateUserDriver
    @State private var language = AppLanguageStore.shared
    @Environment(\.colorScheme) private var scheme

    private var statusColor: Color {
        switch driver.stage {
        case .failed: .red
        case .upToDate, .completed: .green
        default: .accentColor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40).allowsHitTesting(false)
            MacPageHeader(title: language.string("updates.title")) {
                if driver.canDismiss {
                    Button(action: driver.dismissByUser) {
                        Label(language.string("updates.close"), systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .environment(\.macPageNavigation, nil)

            VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: driver.stage.symbol)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(statusColor)
                            .frame(width: 56, height: 56)
                            .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(language.string(driver.titleKey))
                                .font(.title2.weight(.semibold))
                                .accessibilityAddTraits(.isHeader)
                            if [.information, .permission, .ready, .installing, .failed].contains(driver.stage) {
                                Text(language.string(driver.detailKey))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let version = driver.version {
                                Text(language.string("updates.version", version))
                                    .font(.callout.weight(.medium))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if driver.stage == .available {
                        Text(language.string("updates.notes.title"))
                            .font(.callout.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(driver.releaseNotes.flatMap { $0.isEmpty ? nil : $0 } ?? language.string("updates.notes.empty"))
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .scrollIndicators(.visible)
                        .accessibilityIdentifier("updates.notes.scroll")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    }

                    if driver.isWorking {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(language.string(driver.titleKey)).font(.callout)
                                Spacer()
                                if let progress = driver.progress {
                                    Text(progress.formatted(.percent.precision(.fractionLength(0)).locale(language.locale)))
                                        .font(.callout.monospacedDigit())
                                }
                            }
                            if let progress = driver.progress {
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.08))
                                        Capsule().fill(Color.accentColor)
                                            .frame(width: geometry.size.width * progress)
                                    }
                                }
                                .frame(height: 6)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(language.string(driver.titleKey))
                                .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0)).locale(language.locale)))
                            } else {
                                ProgressView()
                                    .progressViewStyle(.linear)
                                    .accessibilityLabel(language.string(driver.titleKey))
                            }
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if driver.stage != .available {
                        Spacer(minLength: 0)
                    }
            }
            .padding(20)
            .fillsAvailableContentArea(alignment: .topLeading)
            .background(MacAppearancePalette(scheme: scheme, increasedContrast: false).content)

            HStack(spacing: 12) {
                if driver.stage.showsReleaseNotes {
                    Link(language.string("updates.releaseNotes"), destination: URL(string: "https://github.com/yuangy1995/dsm-native-client/releases")!)
                        .font(.callout)
                }
                Spacer(minLength: 8)
                if let key = driver.secondaryKey {
                    Button(language.string(key), action: driver.performSecondaryAction)
                        .keyboardShortcut(.cancelAction)
                }
                if let key = driver.primaryKey {
                    Button(language.string(key), action: driver.performPrimaryAction)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(MacToolbarButtonStyle(prominent: true))
                }
            }
            .buttonStyle(MacToolbarButtonStyle())
            .padding(16)
            .background(MacGlassSurface(role: .toolbar))
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacGlassSurface(role: .sidebar).ignoresSafeArea())
        .background(MacWorkspaceWindowChrome(fullSize: true))
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, language.locale)
    }
}

struct AppUpdateSettingsView: View {
    @ObservedObject var controller: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent(L10n.string("updates.currentVersion"), value: controller.currentVersion)
            Divider()
            Toggle(L10n.string("updates.automatic"), isOn: Binding(
                get: { controller.automaticallyChecksForUpdates },
                set: { controller.setAutomaticChecks($0) }
            ))
            .disabled(controller.updater == nil)
            HStack {
                Link(L10n.string("updates.releaseNotes"), destination: URL(string: "https://github.com/yuangy1995/dsm-native-client/releases")!)
                Spacer()
                Button(L10n.string("updates.check"), action: controller.checkForUpdates)
                    .buttonStyle(MacToolbarButtonStyle(prominent: true))
                    .accessibilityIdentifier("settings.updates.check")
            }
        }
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
