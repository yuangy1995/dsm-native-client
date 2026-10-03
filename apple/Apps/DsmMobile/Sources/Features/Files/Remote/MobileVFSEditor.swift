import DsmCore
import DsmFileFeature
import DsmLocalization
import SwiftUI

struct MobileVFSEditor: View {
    @Bindable var model: MobileRemoteLocationsModel
    let existing: FileVFSProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: FileVFSDetail?
    @State private var draft = FileVFSConfiguration(protocolID: "", hostname: "", port: 0, alias: "", account: "")
    @State private var password = ""
    @State private var replacesPassword = false
    @State private var loading = true
    @State private var error: String?
    @State private var cleartextDraft: FileVFSConfiguration?
    @State private var cloud: FileVFSProtocol?
    private var selected: FileVFSProtocol? { model.protocols.first { $0.id == draft.protocolID } }
    private var blocked: Bool {
        model.isVFSBlocked(baseline.map { .update(baseline: $0, configuration: draft) } ?? .create(draft))
    }
    var body: some View {
        NavigationStack {
            Form {
                MobileRemoteFeedback(model: model)
                if loading { ProgressView() }
                else if model.protocols.isEmpty || existing != nil && baseline == nil {
                    Section {
                        Text(error ?? L10n.string("files.advanced.unavailable"))
                        Button(L10n.string("ui.aee88743413144a2")) { Task { await load() } }
                    }
                } else {
                    Section {
                        Picker(L10n.string("files.vfs.protocol"), selection: $draft.protocolID) {
                            ForEach(model.protocols.filter { $0.supportsServerSetup || $0.supportsCloudAuthorization }) { Text($0.name).tag($0.id) }
                        }.disabled(existing != nil).accessibilityIdentifier("files.remote.vfs.protocol")
                        if selected?.supportsServerSetup == true {
                            TextField(L10n.string("files.vfs.alias"), text: $draft.alias).accessibilityIdentifier("files.remote.vfs.alias")
                            TextField(L10n.string("files.vfs.hostname"), text: $draft.hostname, prompt: Text(L10n.string("files.vfs.addressExample")))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityIdentifier("files.remote.vfs.hostname")
                            TextField(L10n.string("files.vfs.port"), value: $draft.port, format: .number.grouping(.never))
                                .keyboardType(.numberPad).accessibilityIdentifier("files.remote.vfs.port")
                            TextField(L10n.string("files.vfs.account"), text: $draft.account).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if existing != nil { Toggle(L10n.string("files.vfs.replacePassword"), isOn: $replacesPassword) }
                            if existing == nil || replacesPassword { SecureField(L10n.string("files.vfs.password"), text: $password) }
                            if ["dav", "davs"].contains(draft.protocolID) {
                                TextField(L10n.string("files.vfs.folder"), text: $draft.folder)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                            DisclosureGroup(L10n.string("files.vfs.moreOptions")) {
                                TextField(L10n.string("files.vfs.filenameEncoding"), text: $draft.codepage)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                if draft.protocolID == "ftp" {
                                    Toggle(L10n.string("files.vfs.singleConnection"), isOn: $draft.usesOneConnection)
                                }
                            }
                        } else if selected?.supportsCloudAuthorization == true {
                            Button(L10n.string("files.vfs.authorizeCloud")) { cloud = selected }
                        }
                    }.disabled(model.busy || blocked || !model.canManageVFS)
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    if !model.canManageVFS && !model.busy { Section { Text(L10n.string("mobile.remote.read-only")).foregroundStyle(.secondary) } }
                }
            }.navigationTitle(L10n.string(existing == nil ? "files.vfs.add" : "files.vfs.edit"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("files.common.close")) { password = ""; dismiss() }.disabled(model.busy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.busy { ProgressView() }
                        else if selected?.supportsServerSetup == true {
                            Button(L10n.string("files.vfs.saveConnect")) { prepare() }
                                .disabled(loading || !model.canManageVFS || blocked || draft.alias.isEmpty || draft.hostname.isEmpty)
                                .accessibilityIdentifier("files.remote.vfs.save")
                        }
                    }
                }
        }.interactiveDismissDisabled(model.busy)
            .task { await load() }
            .onChange(of: draft.protocolID) { _, value in
                if let selected = model.protocols.first(where: { $0.id == value }), existing == nil { draft.port = selected.defaultPort ?? 0 }
                password = ""
            }
            .onChange(of: replacesPassword) { _, _ in password = "" }
            .onDisappear { password = "" }
            .sheet(item: $cloud) { service in
                MobileVFSCloudView(model: model, protocolID: service.id, protocolName: service.name, existing: nil) { dismiss() }
            }
            .alert(L10n.string("mobile.remote.cleartext-title"), isPresented: Binding(get: { cleartextDraft != nil }, set: { if !$0 { cleartextDraft = nil } })) {
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { cleartextDraft = nil }
                Button(L10n.string("files.vfs.saveConnect"), role: .destructive) {
                    if let value = cleartextDraft { cleartextDraft = nil; submit(value, cleartext: true) }
                }
            } message: { Text(L10n.string("mobile.remote.cleartext-impact")) }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        if model.protocols.isEmpty { await model.load() }
        do {
            if let existing { let value = try await model.detail(existing); baseline = value; draft = value.configuration }
            else if draft.protocolID.isEmpty, let first = model.protocols.first(where: { $0.supportsServerSetup || $0.supportsCloudAuthorization }) {
                draft.protocolID = first.id; draft.port = first.defaultPort ?? 0
            }
        } catch { self.error = MobileRemoteLocationsModel.message(error) }
    }
    private func prepare() {
        do {
            let value = try FileVFSForm.configuration(draft, protocols: model.protocols, editingProtocol: existing?.protocolID)
            error = nil
            if FileVFSForm.usesCleartext(value) { cleartextDraft = value }
            else { submit(value, cleartext: false) }
        } catch { self.error = MobileRemoteLocationsModel.message(error) }
    }
    private func submit(_ value: FileVFSConfiguration, cleartext: Bool) {
        let change = baseline.map { FileVFSChange.update(baseline: $0, configuration: value) } ?? .create(value)
        let secret: String? = existing == nil || replacesPassword ? password : nil
        password = ""
        Task { if await model.changeVFS(change, password: secret, confirmedCleartext: cleartext) { dismiss() } }
    }
}
