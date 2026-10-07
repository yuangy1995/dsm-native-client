#if DEBUG
import DsmCore
import DsmLocalization
import DsmNetwork
import FileProvider
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor enum MobileFilesUIFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-files-fixture") }

    static func makeModel() -> MobileAppModel {
        do {
            guard let id = ProcessInfo.processInfo.environment["LANSTASH_FILES_RUN_ID"].flatMap(UUID.init(uuidString:)) else { throw CocoaError(.fileReadCorruptFile) }
            let fixture = MobileFilesDebugEnvironment(id: id, mode: ProcessInfo.processInfo.environment["LANSTASH_FILES_MODE"] ?? "success", createdAt: Date())
            let root = try fixture.rootURL()
            try MobileExtensionStorage.prepareDirectory(root)
            try JSONEncoder().encode(fixture).write(to: MobileExtensionStorage.rootURL().appendingPathComponent("ui-files-fixture.json"), options: [.atomic, .completeFileProtection])
            let defaults = UserDefaults(suiteName: "LanStash.Mobile.FilesUITests")!
            defaults.removePersistentDomain(forName: "LanStash.Mobile.FilesUITests")
            let sessions = try MobileExtensionStorage.sessionStore()
            let access = try MobileExtensionAccess(accounts: fixture.accounts, sessions: sessions)
            let model = MobileAppModel(defaults: defaults, sessionStore: sessions,
                transferRecoveryStore: .init(rootURL: root.appendingPathComponent("MainTransfers")), extensionAccess: access)
            let profile = try NasProfile(id: id, displayName: "Sample NAS", host: "files-ui.invalid", port: 5001, usernameHint: "synthetic")
            let session = AuthSession(sid: "synthetic-files", synoToken: nil, did: nil, isPortalPort: false)
            model.profiles = [profile]; model.activeProfile = profile; model.activeConnectionProfile = profile
            model.session = session; model.capabilities = MobileFilesDebugEnvironment.capabilities
            model.isConnected = true
            if ProcessInfo.processInfo.arguments.contains("--ui-dark") { model.settingsStore.appearance = .dark }
            return model
        } catch { preconditionFailure("Synthetic Files fixture initialization failed.") }
    }
}

struct MobileFilesUIFixtureView: View {
    @Bindable var app: MobileAppModel
    @State private var model: MobileFilesSettingsModel?
    @State private var showingPicker = false
    @State private var document: URL?
    @State private var contents = ""
    @State private var status: String?
    @State private var saved = false
    @State private var reading = false
    @State private var cleaned = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    List {
                        NavigationLink(L10n.string("mobile.files-location.title")) { MobileFilesLocationsList(model: model) }
                            .accessibilityIdentifier("mobile.files.test-settings")
                        Button(L10n.string("mobile.files-location.browse")) { showingPicker = true }
                            .accessibilityIdentifier("mobile.files.test-browse")
                        if let document {
                            Text(document.lastPathComponent).accessibilityIdentifier("mobile.files.test-filename")
                            Text(contents).accessibilityIdentifier("mobile.files.test-contents")
                            Button(L10n.string("mobile.files-location.save")) { Task { await edit(document) } }
                                .accessibilityIdentifier("mobile.files.test-edit")
                        }
                        if saved { Text(L10n.string("mobile.files-location.test-saved")).accessibilityIdentifier("mobile.files.test-saved") }
                        if reading { ProgressView() }
                    }
                } else if cleaned {
                    Text(L10n.string("mobile.files-location.test-cleaned")).accessibilityIdentifier("mobile.files.test-cleaned")
                } else { ProgressView() }
            }
            .overlay(alignment: .bottom) {
                if let status { Text(status).accessibilityIdentifier("mobile.files.test-error") }
            }
            .navigationTitle(L10n.string("mobile.files-location.title"))
            .sheet(isPresented: $showingPicker) {
                MobileFilesFixturePicker { url in
                    showingPicker = false
                    if let url { Task { await open(url) } }
                }
            }
            .task {
                guard model == nil, !cleaned, let fixture = MobileFilesDebugEnvironment.active(),
                      let profile = app.activeProfile, let session = app.session, let access = app.extensionAccess else { return }
                do {
                    if ProcessInfo.processInfo.arguments.contains("--ui-clean-files") {
                        for location in try fixture.locations.locations() {
                            guard location.profile.id == fixture.id, location.profile.host == "files-ui.invalid" else { throw CocoaError(.fileReadNoPermission) }
                            try await MobileFilesDomainController().remove(location)
                        }
                        for account in try access.accounts.accounts() { try access.revoke(profileID: account.profile.id) }
                        await access.cleanRetiredSessions()
                        try FileManager.default.removeItem(at: fixture.rootURL())
                        if MobileFilesDebugEnvironment.active()?.id == fixture.id {
                            try FileManager.default.removeItem(at: MobileExtensionStorage.rootURL().appendingPathComponent("ui-files-fixture.json"))
                        }
                        cleaned = true; return
                    }
                    if try access.accounts.accounts().isEmpty {
                        try await access.publish(profile: profile, connection: profile, capabilities: MobileFilesDebugEnvironment.capabilities, session: session)
                    }
                    model = try .init(locations: fixture.locations, accounts: fixture.accounts, currentProfile: { app.activeProfile })
                } catch { status = String(describing: error) }
            }
        }
        .preferredColorScheme(app.settingsStore.appearance.colorScheme)
    }

    private func open(_ url: URL) async {
        reading = true
        defer { reading = false }
        do {
            contents = try await Task.detached { try Self.coordinate(url, editing: false) }.value
            document = url
        } catch { status = String(describing: error) }
    }

    private func edit(_ url: URL) async {
        guard let fixture = MobileFilesDebugEnvironment.active() else { return }
        reading = true
        defer { reading = false }
        do {
            contents = try await Task.detached { try Self.coordinate(url, editing: true) }.value
            let network = try MobileFilesSyntheticTransport(root: fixture.rootURL().appendingPathComponent("Server"))
            for _ in 0..<150 {
                if try await network.snapshot().nodes.first(where: { $0.path == "/Shared/Sample.txt" })?.content == Data("Edited in another app\n".utf8) {
                    saved = true; return
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            status = "Synthetic file edit was not uploaded."
        } catch { status = String(describing: error) }
    }

    private nonisolated static func coordinate(_ url: URL, editing: Bool) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        let coordinator = NSFileCoordinator()
        if editing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &error) { coordinated in
                result = Result {
                    let text = "Edited in another app\n"
                    try Data(text.utf8).write(to: coordinated, options: .atomic)
                    return text
                }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
                result = Result { try String(contentsOf: coordinated, encoding: .utf8) }
            }
        }
        if let error { throw error }
        return try result.get()
    }
}

private struct MobileFilesFixturePicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(_ completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
    }
}
#endif
