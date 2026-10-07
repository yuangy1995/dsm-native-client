#if DEBUG
import DsmCore
import DsmLocalization
import DsmNetwork
import SwiftUI

@MainActor
enum MobileShareUIFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-share-fixture") }

    static func makeModel() -> MobileAppModel {
        do {
            guard let id = ProcessInfo.processInfo.environment["LANSTASH_SHARE_RUN_ID"].flatMap(UUID.init(uuidString:)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let fixture = MobileShareDebugEnvironment(id: id, mode: ProcessInfo.processInfo.environment["LANSTASH_SHARE_MODE"] ?? "success", createdAt: Date(),
                usesLargestDarkText: ProcessInfo.processInfo.arguments.contains("--ui-dark"))
            let root = try fixture.rootURL()
            if !ProcessInfo.processInfo.arguments.contains("--ui-preserve-share") { try? FileManager.default.removeItem(at: root) }
            try MobileExtensionStorage.prepareDirectory(root)
            try JSONEncoder().encode(fixture).write(to: MobileExtensionStorage.rootURL().appendingPathComponent("ui-share-fixture.json"), options: [.atomic, .completeFileProtection])
            let sessions = try MobileExtensionStorage.sessionStore()
            let access = MobileExtensionAccess(accounts: .init(rootURL: root), sessions: sessions)
            let defaults = UserDefaults(suiteName: "LanStash.Mobile.ShareUITests")!
            defaults.removePersistentDomain(forName: "LanStash.Mobile.ShareUITests")
            let model = MobileAppModel(defaults: defaults, sessionStore: sessions,
                transferRecoveryStore: .init(rootURL: root.appendingPathComponent("MainTransfers")), extensionAccess: access)
            let profile = try NasProfile(id: id, displayName: "Sample NAS", host: "share-ui.invalid", port: 5001, usernameHint: "synthetic")
            let session = AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false)
            model.profiles = [profile]; model.activeProfile = profile; model.activeConnectionProfile = profile
            model.session = session; model.capabilities = MobileShareDebugEnvironment.capabilities
            model.fileRepository = try DsmFileRepository(profile: profile, capabilities: MobileShareDebugEnvironment.capabilities,
                session: session, transport: MobileShareSyntheticTransport(root: root, mode: fixture.mode))
            model.isConnected = true
            if ProcessInfo.processInfo.arguments.contains("--ui-dark") { model.settingsStore.appearance = .dark }
            return model
        } catch { preconditionFailure("Synthetic share fixture initialization failed.") }
    }
}

struct MobileShareUIFixtureView: View {
    @Bindable var model: MobileAppModel
    @State private var files: [URL] = []
    @State private var ready = false
    @State private var showingShare = false
    @State private var failure: String?
    @State private var cleaned = false

    var body: some View {
        NavigationStack {
            List {
                Button(L10n.string("mobile.share.title")) { showingShare = true }
                    .frame(minHeight: 44).disabled(!ready).accessibilityIdentifier("mobile.share.test-open")
                NavigationLink(L10n.string("mobile.share.activity-title")) { MobileActivityView(model: model) }
                    .accessibilityIdentifier("mobile.share.test-activity")
                if let failure { Text(failure) }
                if cleaned { Text(L10n.string("mobile.share.completed")).accessibilityIdentifier("mobile.share.test-cleaned") }
            }
            .navigationTitle(L10n.string("mobile.share.title"))
            .sheet(isPresented: $showingShare) { MobileShareSheet(urls: files) { showingShare = false } }
            .task {
                guard !ready, let fixture = MobileShareDebugEnvironment.active(),
                      let profile = model.activeProfile, let session = model.session, let access = model.extensionAccess else { return }
                do {
                    if ProcessInfo.processInfo.arguments.contains("--ui-clean-share") {
                        for account in try access.accounts.accounts() { try access.revoke(profileID: account.profile.id) }
                        await access.cleanRetiredSessions()
                        try FileManager.default.removeItem(at: fixture.rootURL())
                        if MobileShareDebugEnvironment.active()?.id == fixture.id {
                            try FileManager.default.removeItem(at: MobileExtensionStorage.rootURL().appendingPathComponent("ui-share-fixture.json"))
                        }
                        ready = true; cleaned = true
                        return
                    }
                    if try access.accounts.accounts().isEmpty {
                        try await access.publish(profile: profile, connection: profile,
                            capabilities: MobileShareDebugEnvironment.capabilities, session: session)
                    }
                    let root = try fixture.rootURL().appendingPathComponent("Input", isDirectory: true)
                    try MobileExtensionStorage.prepareDirectory(root)
                    files = [root.appendingPathComponent("Sample.txt")]
                    for file in files { try Data().write(to: file, options: [.atomic, .completeFileProtection]) }
                    ready = true
                } catch { failure = L10n.string("mobile.extensions.unavailable") }
            }
        }
        .preferredColorScheme(model.settingsStore.appearance.colorScheme)
    }
}
#endif
