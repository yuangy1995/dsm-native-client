import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDDNSScreen: View {
    @Bindable var model: MobileDDNSModel
    @State private var query = ""
    @State private var editor: MobileDDNSEditorSource?
    @State private var confirmation: NasDDNSChange?
    @State private var confirmationActivation: UUID?

    var body: some View {
        List {
            if let value = model.directory.value {
                Section {
                    Button(L10n.string("mobile.nas.ddns.add"), systemImage: "plus") {
                        guard let provider = model.availableProviders.first else { return }
                        editor = .init(original: nil, providerID: provider.id, activation: model.activation)
                    }
                    .disabled(!model.canEdit || model.availableProviders.isEmpty)
                    .accessibilityIdentifier("mobile.nas.ddns.add")
                    if !value.records.isEmpty {
                        let change = NasDDNSChange.updateAddress(providerIDs: Set(value.records.map(\.providerID)))
                        Button(L10n.string("mobile.nas.ddns.update"), systemImage: "arrow.triangle.2.circlepath") { confirm(change) }
                            .disabled(!model.canPerform(change))
                            .accessibilityIdentifier("mobile.nas.ddns.update")
                    }
                    if !model.isAdministrator { Text((model.permissionError ?? .denied).message).foregroundStyle(.secondary) }
                }
                if !value.records.isEmpty {
                    Section {
                        TextField(L10n.string("mobile.nas.ddns.search"), text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("mobile.nas.ddns.search")
                    }
                }
            }
            Section {
                MobileNasDetailsSectionContent(section: model.directory,
                    loading: L10n.string("mobile.nas.ddns.loading"),
                    emptyTitle: L10n.string("mobile.nas.ddns.empty"),
                    emptyMessage: L10n.string(model.availableProviders.isEmpty ? "mobile.nas.ddns.noProvider" : "mobile.nas.ddns.addHint"),
                    retry: { Task { await model.refresh() } }) { value in
                    let records = value.records.filter { MobileNasReadFormatting.matches(query, values: [$0.hostname, $0.providerName]) }
                    if records.isEmpty {
                        ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass",
                                               description: Text(L10n.string("mobile.nas.filter.retry")))
                            .accessibilityIdentifier("mobile.nas.ddns.filteredEmpty")
                    }
                    ForEach(records) { record in
                        Button { editor = .init(original: record, providerID: record.providerID, activation: model.activation) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.hostname).font(.headline).foregroundStyle(.primary)
                                Text(record.providerName).foregroundStyle(.secondary)
                                Text(L10n.string(record.isEnabled ? "mobile.nas.ddns.enabled" : "mobile.nas.ddns.disabled"))
                                    .foregroundStyle(.secondary)
                                if let address = record.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mobile.nas.ddns.record.\(record.providerID)")
                    }
                }
            }
            if let error = model.error { Section { Text(error.message).accessibilityIdentifier("mobile.nas.ddns.error") } }
            if !model.entries.isEmpty {
                Section(L10n.string("mobile.nas.ddns.activity")) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.action.title).font(.headline)
                            if entry.provider != nil { Text(model.providerName(for: entry) ?? L10n.string("mobile.nas.ddns.originalProvider")) }
                            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.ddns.working") : entry.message)
                                .accessibilityIdentifier("mobile.nas.ddns.activity.\(entry.phase.rawValue)")
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.isUnfinished {
                                Button(L10n.string("mobile.nas.ddns.reload")) { Task { await model.refresh() } }
                                    .disabled(model.isOperating || model.directory.isRefreshing)
                                    .accessibilityIdentifier("mobile.nas.ddns.recover")
                            } else if !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.nas.ddns.removeRecord")) { model.removeRecord(entry.id) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.nas.ddns.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.activation) { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
        .onDisappear { model.cancelRead() }
        .onChange(of: model.activation) { _, _ in editor = nil; confirmation = nil; query = "" }
        .sheet(item: $editor) { source in NavigationStack { MobileDDNSEditor(model: model, source: source) } }
        .alert(confirmation?.action.title ?? L10n.string("mobile.nas.ddns.title"), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        )) {
            if let confirmation, let token = confirmationActivation {
                Button(confirmation.action.title) { model.perform(confirmation, activation: token); self.confirmation = nil }
                    .accessibilityIdentifier("mobile.nas.ddns.confirm")
            }
            Button(L10n.string("mobile.nas.ddns.cancel"), role: .cancel) { confirmation = nil }
        } message: { if let confirmation { Text(confirmation.confirmationMessage) } }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
    private func confirm(_ change: NasDDNSChange) { confirmation = change; confirmationActivation = model.activation }
}

private struct MobileDDNSEditorSource: Identifiable {
    let id = UUID()
    let original: NasDDNSRecord?
    let providerID: String
    let activation: UUID
}

private struct MobileDDNSEditor: View {
    @Bindable var model: MobileDDNSModel
    let source: MobileDDNSEditorSource
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NasDDNSDraft
    @State private var confirmation: NasDDNSChange?
    @State private var testID: UUID?
    @State private var saveID: UUID?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case hostname, username, password }

    init(model: MobileDDNSModel, source: MobileDDNSEditorSource) {
        self.model = model; self.source = source
        let record = source.original
        _draft = State(initialValue: NasDDNSDraft(originalProviderID: record?.providerID, providerID: source.providerID,
            hostname: record?.hostname ?? "", username: record?.username ?? "", isEnabled: record?.isEnabled ?? true,
            networkType: record?.networkType ?? "auto", ipv4: record?.ipv4 ?? "0.0.0.0", ipv6: record?.ipv6 ?? "0:0:0:0:0:0:0:0",
            interfaceV4: record?.interfaceV4 ?? "", interfaceV6: record?.interfaceV6 ?? "", heartbeat: record?.heartbeat ?? false))
    }
    private var save: NasDDNSChange { .save(original: source.original, draft: draft) }
    private var test: NasDDNSChange { .test(original: source.original, draft: draft) }
    private var providers: [NasDDNSProvider] {
        source.original == nil ? model.availableProviders : model.directory.value?.providers.filter { $0.id == source.providerID } ?? []
    }
    var body: some View {
        Form {
            Section {
                if source.original == nil && providers.count > 1 {
                    Picker(L10n.string("mobile.nas.ddns.provider"), selection: $draft.providerID) {
                        ForEach(providers) { Text($0.displayName).tag($0.id) }
                    }
                    .accessibilityIdentifier("mobile.nas.ddns.provider")
                } else {
                    LabeledContent(L10n.string("mobile.nas.ddns.provider"), value: source.original?.providerName ?? providers.first?.displayName ?? source.providerID)
                }
                TextField(L10n.string("mobile.nas.ddns.hostname"), text: $draft.hostname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .focused($focusedField, equals: .hostname).submitLabel(.done)
                    .accessibilityIdentifier("mobile.nas.ddns.hostname")
                TextField(L10n.string("mobile.nas.ddns.username"), text: $draft.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .username).submitLabel(.done)
                    .accessibilityIdentifier("mobile.nas.ddns.username")
                if draft.providerID != "Synology" {
                    SecureField(L10n.string(source.original == nil ? "mobile.nas.ddns.password" : "mobile.nas.ddns.newPassword"), text: $draft.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .password).submitLabel(.done)
                        .accessibilityIdentifier("mobile.nas.ddns.password")
                } else { Text(L10n.string("mobile.nas.ddns.synologyAccount")).foregroundStyle(.secondary) }
                Toggle(L10n.string("mobile.nas.ddns.enabled"), isOn: $draft.isEnabled)
                    .accessibilityIdentifier("mobile.nas.ddns.enabled")
                Toggle(L10n.string("mobile.nas.ddns.heartbeat"), isOn: $draft.heartbeat)
                    .accessibilityIdentifier("mobile.nas.ddns.heartbeat")
            }
            .disabled(!model.canEdit || model.isOperating)
            if !draft.normalizedHostname.isEmpty && !NasDDNSDraft.isValidHostname(draft.normalizedHostname) {
                Section { Text(L10n.string("ddns.editor.hostname-invalid")).foregroundStyle(.red) }
            }
            if !model.isAdministrator && model.error == nil { Section { Text((model.permissionError ?? .denied).message) } }
            Section {
                Button(L10n.string("ddns.test.action")) { focusedField = nil; testID = model.perform(test, activation: source.activation) }
                    .disabled(!model.canPerform(test))
                    .accessibilityIdentifier("mobile.nas.ddns.test")
                if let id = testID, let entry = model.recovery.entry(id) {
                    Text(model.recovery.isExecuting(id) ? L10n.string("mobile.nas.ddns.working") : entry.message)
                        .accessibilityIdentifier("mobile.nas.ddns.testResult")
                }
                if let id = saveID, let entry = model.recovery.entry(id) {
                    Text(model.recovery.isExecuting(id) ? L10n.string("mobile.nas.ddns.working") : entry.message)
                        .accessibilityIdentifier("mobile.nas.ddns.saveResult")
                }
                if let error = model.error { Text(error.message) }
            } footer: { Text(L10n.string("mobile.nas.ddns.privacy")) }
            if let original = source.original {
                Section {
                    LabeledContent(L10n.string("mobile.nas-details.field.status"), value: original.status == "service_ddns_normal"
                        ? L10n.string("ui.cfea0dce5c5d6d72") : L10n.string("mobile.nas-details.value.unavailable"))
                    if let address = original.address { LabeledContent(L10n.string("mobile.nas.ddns.address"), value: address) }
                    if let updated = MobileNasStorageFormatting.historyTime(original.lastUpdated) {
                        LabeledContent(L10n.string("mobile.nas.ddns.lastUpdated"), value: updated)
                    }
                    Button(L10n.string("mobile.nas.ddns.delete"), role: .destructive) { confirmation = .delete(original) }
                        .disabled(!model.canPerform(.delete(original)))
                        .accessibilityIdentifier("mobile.nas.ddns.delete")
                }
            }
        }
        .navigationTitle(L10n.string(source.original == nil ? "mobile.nas.ddns.add" : "mobile.nas.ddns.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.nas.ddns.done")) { dismiss() }.accessibilityIdentifier("mobile.nas.ddns.done")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("mobile.nas.ddns.save")) { focusedField = nil; confirmation = save }
                    .disabled(!model.canPerform(save)).accessibilityIdentifier("mobile.nas.ddns.save")
            }
        }
        .onSubmit { focusedField = nil }
        .onChange(of: draft) { _, _ in testID = nil }
        .onChange(of: model.activation) { _, _ in draft.password = ""; confirmation = nil; dismiss() }
        .onChange(of: model.recovery.entries) { _, _ in
            if let id = saveID, model.recovery.entry(id)?.phase == .succeeded { dismiss() }
        }
        .onDisappear { draft.password = ""; confirmation = nil }
        .alert(confirmation?.action.title ?? L10n.string("mobile.nas.ddns.title"), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        )) {
            if let confirmation {
                Button(confirmation.action.title, role: confirmation.action == .delete ? .destructive : nil) {
                    saveID = model.perform(confirmation, activation: source.activation); self.confirmation = nil
                }
                .accessibilityIdentifier("mobile.nas.ddns.confirm")
            }
            Button(L10n.string("mobile.nas.ddns.cancel"), role: .cancel) { confirmation = nil }
                .accessibilityIdentifier("mobile.nas.ddns.cancel")
        } message: { if let confirmation { Text(confirmation.confirmationMessage) } }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

extension NasDDNSAction {
    var title: String {
        switch self {
        case .test: L10n.string("ddns.test.action")
        case .save: L10n.string("mobile.nas.ddns.save")
        case .delete: L10n.string("mobile.nas.ddns.delete")
        case .updateAddress: L10n.string("mobile.nas.ddns.update")
        }
    }
}
private extension NasDDNSChange {
    var confirmationMessage: String {
        switch self {
        case .delete(let record): L10n.string("mobile.nas.ddns.deleteMessage", record.hostname)
        case .updateAddress: L10n.string("mobile.nas.ddns.updateMessage")
        default: L10n.string("mobile.nas.ddns.saveMessage")
        }
    }
}
extension MobileDDNSModel.Failure {
    var message: String {
        switch self {
        case .read: L10n.string("mobile.nas.ddns.readError")
        case .denied: L10n.string("ddns.operation.permission-denied")
        case .unavailable: L10n.string("mobile.nas.ddns.unavailable")
        case .changed: L10n.string("mobile.nas.ddns.changed")
        case .storage: L10n.string("mobile.nas.ddns.storageError")
        }
    }
}
extension MobileDDNSOperationStore.Entry {
    var message: String {
        switch phase {
        case .prepared: L10n.string("mobile.nas.ddns.working")
        case .submitted: L10n.string(needsCredentialAcknowledgement && !accepted ? "mobile.nas.ddns.credentialPending" : "mobile.nas.ddns.pending")
        case .cancelled: L10n.string("mobile.nas.ddns.cancelled")
        case .unconfirmed: L10n.string("mobile.nas.ddns.instantUnknown")
        case .failed:
            switch failure {
            case .denied: MobileDDNSModel.Failure.denied.message
            case .unavailable: MobileDDNSModel.Failure.unavailable.message
            case .changed: MobileDDNSModel.Failure.changed.message
            default: L10n.string("mobile.nas.ddns.failed")
            }
        case .succeeded:
            switch action {
            case .test: L10n.string("mobile.nas.ddns.testSucceeded")
            case .save: L10n.string("ddns.save.completed")
            case .delete: L10n.string("ddns.delete.completed")
            case .updateAddress: L10n.string("mobile.nas.ddns.updateAccepted")
            }
        }
    }
}
