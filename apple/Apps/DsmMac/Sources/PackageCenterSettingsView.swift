import DsmCore
import DsmLocalization
import SwiftUI

struct PackageCenterSettingsView: View {
    let loadSettings: () async throws -> NasPackageCenterSettings
    let saveSettings: (NasPackageCenterSettings, NasPackageCenterSettings) async throws -> NasPackageCenterSettings
    let loadSources: () async throws -> [NasPackageSource]
    let saveSource: (NasPackageSource, NasPackageSource?) async throws -> [NasPackageSource]
    let deleteSource: (NasPackageSource) async throws -> [NasPackageSource]
    let onClose: () -> Void
    @State private var baseline: NasPackageCenterSettings?
    @State private var draft: NasPackageCenterSettings?
    @State private var sources: [NasPackageSource] = []
    @State private var tab = 0
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var settingsError: String?
    @State private var sourcesError: String?
    @State private var sourceDraft: NasPackageSource?
    @State private var sourceBaseline: NasPackageSource?
    @State private var sourceToDelete: NasPackageSource?
    @State private var confirmAutomatic = false
    @State private var needsRefresh = false
    @State private var confirmClose = false
    private var dirty: Bool { draft != baseline }
    private var canSave: Bool {
        baseline != nil && draft != nil && settingsError == nil && dirty && !needsRefresh && !loading && !saving
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("package.center.settings")).font(.title2.bold())
            Picker(L10n.string("package.center.settings"), selection: $tab) {
                Text(L10n.string("package.center.general")).tag(0)
                Text(L10n.string("package.center.automatic-updates")).tag(1)
                Text(L10n.string("package.center.sources")).tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                if loading { ProgressView() }
                else if tab == 2 { sourceList }
                else if let settingsError {
                    ContentUnavailableView(L10n.string("package.center.settings-load-failed"), systemImage: "exclamationmark.triangle", description: Text(settingsError))
                }
                else if draft != nil { settingsForm }
            }.fillsAvailableContentArea()
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(L10n.string("package.center.refresh")) { Task { await reload() } }.disabled(saving)
                Spacer()
                Button(L10n.string("package.center.close")) { if dirty { confirmClose = true } else { onClose() } }.keyboardShortcut(.cancelAction)
                if tab != 2 {
                    Button(L10n.string("package.center.save-settings")) {
                        if draft?.updatePolicy != .manual && draft?.updatePolicy != baseline?.updatePolicy { confirmAutomatic = true }
                        else { save() }
                    }.buttonStyle(.borderedProminent).disabled(!canSave)
                }
            }.disabled(loading || saving)
        }.padding(24).frame(width: 660, height: 600, alignment: .topLeading)
        .task { await reload() }
        .interactiveDismissDisabled(saving || dirty)
        .sheet(isPresented: Binding(get: { sourceDraft != nil }, set: { if !$0 { sourceDraft = nil } })) {
            if let sourceDraft {
                PackageSourceEditor(source: sourceDraft, isEditing: sourceBaseline != nil,
                    onCancel: { self.sourceDraft = nil }, onSave: { source in
                        do {
                            sources = try await saveSource(source, sourceBaseline); self.sourceDraft = nil
                        } catch { throw error }
                    })
            }
        }
        .alert(L10n.string("package.center.automatic-confirm"), isPresented: $confirmAutomatic) {
            Button(L10n.string("package.center.save-settings")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: { Text(L10n.string("package.center.automatic-warning")) }
        .alert(L10n.string("package.center.source-remove"), isPresented: Binding(get: { sourceToDelete != nil }, set: { if !$0 { sourceToDelete = nil } })) {
            Button(L10n.string("package.center.source-remove"), role: .destructive) {
                if let source = sourceToDelete {
                    sourceToDelete = nil; saving = true
                    Task {
                        defer { saving = false }
                        do { sources = try await deleteSource(source); error = nil }
                        catch { self.error = safeMessage(error); needsRefresh = true }
                    }
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: { Text(L10n.string("package.center.source-remove-warning", sourceToDelete?.name ?? "")) }
        .alert(L10n.string("package.center.discard-title"), isPresented: $confirmClose) {
            Button(L10n.string("package.center.discard"), role: .destructive, action: onClose)
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: { Text(L10n.string("package.center.discard-message")) }
    }
    @ViewBuilder private var settingsForm: some View {
        if let value = draft {
            Form {
                if tab == 0 {
                    if value.volumes.count > 1 {
                        Picker(L10n.string("package.center.default-volume"), selection: settingBinding(\.defaultVolumeID, fallback: "")) {
                            Text(L10n.string("package.center.ask-each-time")).tag("")
                            ForEach(value.volumes) { Text($0.name).tag($0.id) }
                        }
                    }
                    Toggle(L10n.string("package.center.email-notifications"), isOn: settingBinding(\.emailNotifications, fallback: false))
                    Toggle(L10n.string("package.center.desktop-notifications"), isOn: settingBinding(\.desktopNotifications, fallback: false))
                    Toggle(L10n.string("package.center.show-beta"), isOn: settingBinding(\.betaEnabled, fallback: false))
                } else {
                    Picker(L10n.string("package.center.update-policy"), selection: settingBinding(\.updatePolicy, fallback: .manual)) {
                        ForEach(NasPackageCenterSettings.UpdatePolicy.allCases, id: \.self) { Text(packageUpdatePolicyTitle($0.rawValue)).tag($0) }
                    }
                    if value.updatePolicy == .selected {
                        ForEach(value.packageUpdates) { preference in
                            Picker(preference.name, selection: Binding(get: { draft?.packageUpdates.first { $0.id == preference.id }?.policy ?? .manual }, set: { policy in
                                if let index = draft?.packageUpdates.firstIndex(where: { $0.id == preference.id }) { draft?.packageUpdates[index].policy = policy }
                            })) {
                                ForEach(NasPackageUpdatePreference.Policy.allCases, id: \.self) { Text(packageUpdatePolicyTitle($0.rawValue)).tag($0) }
                            }.disabled(!preference.canUpdateAutomatically)
                        }
                    }
                }
            }.formStyle(.grouped).disabled(saving || needsRefresh)
        }
    }
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(L10n.string("package.center.source-add")) { sourceBaseline = nil; sourceDraft = NasPackageSource(name: "", url: "") }
                    .disabled(saving || needsRefresh || sourcesError != nil)
                Spacer()
            }
            if let sourcesError { ContentUnavailableView(L10n.string("package.center.load-failed"), systemImage: "exclamationmark.triangle", description: Text(sourcesError)) }
            else if sources.isEmpty { ContentUnavailableView(L10n.string("package.center.sources-empty"), systemImage: "shippingbox", description: Text(L10n.string("package.center.sources-help"))) }
            else {
                List(sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(source.name).font(.headline); Text(source.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Spacer()
                        Button(L10n.string("package.center.source-edit")) { sourceBaseline = source; sourceDraft = source }
                        Button(L10n.string("package.center.source-remove"), role: .destructive) { sourceToDelete = source }
                    }.disabled(saving || needsRefresh)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func settingBinding<T>(_ path: WritableKeyPath<NasPackageCenterSettings, T>, fallback: T) -> Binding<T> {
        Binding(get: { draft?[keyPath: path] ?? fallback }, set: { draft?[keyPath: path] = $0 })
    }
    private func reload() async {
        loading = true; defer { loading = false }
        do { let value = try await loadSettings(); baseline = value; draft = value; settingsError = nil }
        catch { baseline = nil; draft = nil; settingsError = safeMessage(error) }
        do { sources = try await loadSources(); sourcesError = nil }
        catch { sourcesError = safeMessage(error) }
        needsRefresh = false; error = nil
    }
    private func save() {
        guard canSave, let draft, let baseline else { return }
        saving = true
        Task {
            defer { saving = false }
            do { let saved = try await saveSettings(draft, baseline); self.baseline = saved; self.draft = saved; error = nil }
            catch { self.error = safeMessage(error); needsRefresh = true }
        }
    }
    private func safeMessage(_ error: Error) -> String { (error as? AppError)?.safeUserMessage ?? L10n.string("package.center.failed") }
}

struct PackageSourceEditor: View {
    @State var source: NasPackageSource
    let isEditing: Bool
    let onCancel: () -> Void
    let onSave: (NasPackageSource) async throws -> Void
    @State private var saving = false
    @State private var confirmTrust = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(isEditing ? "package.center.source-edit" : "package.center.source-add")).font(.title2.bold())
            Form {
                TextField(L10n.string("package.center.source-name"), text: $source.name)
                TextField(L10n.string("package.center.source-address"), text: $source.url)
            }.textFieldStyle(.roundedBorder)
            Text(L10n.string("package.center.source-trust-warning")).foregroundStyle(.secondary)
            if source.url.lowercased().hasPrefix("http:") { Text(L10n.string("package.center.source-http-warning")).foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.string("package.center.source-save")) { confirmTrust = true }.buttonStyle(.borderedProminent)
                    .disabled(source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520, height: 340).disabled(saving).interactiveDismissDisabled(saving)
        .alert(L10n.string("package.center.source-trust-title"), isPresented: $confirmTrust) {
            Button(L10n.string("package.center.source-save")) {
                saving = true
                Task {
                    defer { saving = false }
                    do { try await onSave(source) }
                    catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("package.center.failed") }
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: { Text(L10n.string("package.center.source-trust-confirm", source.url)) }
    }
}

private func packageUpdatePolicyTitle(_ value: String) -> String {
    switch value {
    case "important": L10n.string("package.center.policy.important")
    case "latest": L10n.string("package.center.policy.latest")
    case "selected": L10n.string("package.center.policy.selected")
    default: L10n.string("package.center.policy.manual")
    }
}
