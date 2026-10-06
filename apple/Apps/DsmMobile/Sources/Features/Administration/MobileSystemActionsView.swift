import DsmCore
import DsmLocalization
import SwiftUI

struct MobileConnectionsScreen: View {
    @Bindable var model: MobileSystemActionsModel
    @State private var query = ""
    @State private var selected: MobileConnectionSelection?
    private var filtered: [NasConnection] {
        (model.connections.value?.connections ?? []).filter {
            MobileNasReadFormatting.matches(query, values: [$0.account, $0.source ?? "", $0.type ?? "", $0.protocolName ?? "", $0.description ?? ""])
        }
    }
    var body: some View {
        List {
            Section {
                TextField(L10n.string("mobile.nas.connection.search"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).accessibilityIdentifier("mobile.nas.connection.search")
            }
            if let error = model.connectionError, ![.error, .unavailable].contains(model.connections.phase) {
                Section { Text(error.message).accessibilityIdentifier("mobile.nas.system.error") }
            }
            if model.connections.value?.isCompleteForManagement == false {
                Section { Text(L10n.string("mobile.nas.connection.incomplete")) }
            }
            Section {
                switch model.connections.phase {
                case .idle, .loading: ProgressView(L10n.string("mobile.nas.connection.loading"))
                case .error, .unavailable:
                    ContentUnavailableView(L10n.string("mobile.nas.connection.unavailable"), systemImage: "network.slash", description: Text((model.connectionError ?? .read).message))
                    Button(L10n.string("mobile.nas-health.action.retry")) { Task { await model.refreshConnections() } }.accessibilityIdentifier("mobile.nas.connection.retry")
                case .empty:
                    ContentUnavailableView(L10n.string("mobile.nas.connection.empty"), systemImage: "network", description: Text(L10n.string("mobile.nas.connection.emptyHint")))
                case .content:
                    if filtered.isEmpty { ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass", description: Text(L10n.string("mobile.nas.filter.retry"))).accessibilityIdentifier("mobile.nas.connection.filteredEmpty") }
                    ForEach(filtered) { value in
                        Button { selected = .init(connection: value, activation: model.activation) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(value.account).font(.headline).foregroundStyle(.primary)
                                if let source = value.source { Text(source).foregroundStyle(.secondary) }
                                if let service = value.type { Text(service).font(.caption).foregroundStyle(.secondary) }
                                if value.isCurrentConnection { Text(L10n.string("mobile.nas.connection.current")).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityIdentifier("mobile.nas.connection.row.\(value.id)")
                    }
                }
            }
            let records = model.entries.filter { $0.action == .disconnect }
            if !records.isEmpty {
                Section(L10n.string("mobile.nas.service.activity")) {
                    ForEach(records) { MobileSystemActionRecord(model: model, entry: $0) }
                }
            }
        }
        .accessibilityIdentifier("mobile.nas.connection.list").listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.nas-details.section.connections")).navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshConnections() }.task(id: model.activation) { await model.loadConnectionsIfNeeded() }
        .onDisappear { model.cancelConnectionRead() }
        .onChange(of: model.activation) { _, _ in selected = nil; query = "" }
        .sheet(item: $selected) { value in MobileConnectionDetail(model: model, connection: value.connection, activation: value.activation) { selected = nil } }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobileConnectionSelection: Identifiable {
    let id = UUID()
    let connection: NasConnection
    let activation: UUID
}

private struct MobileConnectionDetail: View {
    @Bindable var model: MobileSystemActionsModel
    let connection: NasConnection
    let activation: UUID
    let onClose: () -> Void
    @State private var prompt: MobileSystemActionPrompt?
    @State private var confirmed: MobileSystemActionPrompt?
    @State private var operationID: UUID?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(L10n.string("mobile.nas.connection.disconnect"), role: .destructive) {
                        prompt = .init(action: .disconnect(connection), activation: activation)
                    }.disabled(!model.canPerform(.disconnect(connection))).accessibilityIdentifier("mobile.nas.connection.disconnect")
                    if !connection.canDisconnect || !connection.hasDisconnectIdentity { Text(L10n.string("mobile.nas.connection.protected")) }
                }
                Section { MobileConnectionFields(connection: connection) }
                if let error = model.connectionError { Section { Text(error.message) } }
                if let operationID, let entry = model.recovery.entry(operationID) {
                    Section { MobileSystemActionRecord(model: model, entry: entry) }
                }
            }
            .accessibilityIdentifier("mobile.nas.connection.detail")
            .navigationTitle(L10n.string("mobile.nas.connection.details")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.nas.service.done"), action: onClose).accessibilityIdentifier("mobile.nas.connection.done")
            } }
        }
        .sheet(item: $prompt, onDismiss: {
            if let confirmed { operationID = confirmed.perform(on: model); self.confirmed = nil }
        }) { source in
            MobileSystemActionConfirmation(model: model, source: source, cancel: { prompt = nil }, confirm: { confirmed = source; prompt = nil })
        }
        .onChange(of: model.activation) { _, _ in prompt = nil; confirmed = nil; onClose() }
        .onChange(of: model.entries) { _, _ in
            if let operationID, model.recovery.entry(operationID)?.phase == .succeeded { onClose() }
        }
    }
}

private struct MobileConnectionFields: View {
    let connection: NasConnection
    var body: some View {
        LabeledContent(L10n.string("mobile.nas.connection.account"), value: connection.account)
        if let source = connection.source { LabeledContent(L10n.string("mobile.nas.connection.source"), value: source) }
        if let service = connection.type { LabeledContent(L10n.string("mobile.nas.connection.service"), value: service) }
        if let protocolName = connection.protocolName { LabeledContent(L10n.string("mobile.nas.connection.protocol"), value: protocolName) }
        if let location = connection.location, !location.isEmpty { LabeledContent(L10n.string("mobile.nas.connection.location"), value: location) }
        if let description = connection.description, !description.isEmpty { LabeledContent(L10n.string("mobile.nas.connection.description"), value: description) }
        if let date = connection.connectedAt { LabeledContent(L10n.string("mobile.nas.connection.since"), value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))) }
        if connection.isCurrentConnection { Text(L10n.string("mobile.nas.connection.current")) }
    }
}

struct MobileSystemPowerSection: View {
    @Bindable var model: MobileSystemActionsModel
    let request: (NasSystemAction) -> Void
    let restore: () -> Void
    let relogin: () -> Void
    var body: some View {
        Section(L10n.string("mobile.nas.system.power")) {
            if [.idle, .loading].contains(model.power.phase) { ProgressView(L10n.string("mobile.nas.system.loading")) }
            else {
                Button(L10n.string("mobile.nas.system.shutdown"), systemImage: "power", role: .destructive) { request(.power(.shutdown)) }
                    .disabled(!model.canPerform(.power(.shutdown))).accessibilityIdentifier("mobile.nas.system.shutdown")
                Button(L10n.string("mobile.nas.system.reboot"), systemImage: "restart", role: .destructive) { request(.power(.reboot)) }
                    .disabled(!model.canPerform(.power(.reboot))).accessibilityIdentifier("mobile.nas.system.reboot")
            }
            if let error = model.powerError {
                Text(error.message).accessibilityIdentifier("mobile.nas.system.powerError")
                Button(L10n.string("mobile.nas-health.action.retry")) { Task { await model.refreshPower() } }.accessibilityIdentifier("mobile.nas.system.retry")
            }
            if model.hasPendingPower {
                if model.canReleasePower {
                    Button(L10n.string("mobile.nas.system.restore"), action: restore).accessibilityIdentifier("mobile.nas.system.restore")
                } else {
                    Text(L10n.string("mobile.nas.system.reconnectHint"))
                    Button(L10n.string("mobile.nas.system.relogin"), action: relogin).disabled(model.isOperating).accessibilityIdentifier("mobile.nas.system.relogin")
                }
            }
            ForEach(model.entries.filter { $0.action != .disconnect }) { MobileSystemActionRecord(model: model, entry: $0) }
        }
        .task(id: model.activation) { await model.loadPowerIfNeeded() }
        .onDisappear { model.cancelPowerRead() }
    }
}

@MainActor
struct MobileSystemActionPrompt: Identifiable {
    let id = UUID()
    let action: NasSystemAction?
    let activation: UUID
    var nasName = ""
    var title: String { action?.kind.title ?? L10n.string("mobile.nas.system.restore") }
    func isAllowed(by model: MobileSystemActionsModel) -> Bool {
        guard activation == model.activation else { return false }
        if let action { return model.canPerform(action) }
        return model.canReleasePower
    }
    @discardableResult func perform(on model: MobileSystemActionsModel) -> UUID? {
        if let action { return model.perform(action, activation: activation) }
        Task { await model.releasePower(activation: activation) }; return nil
    }
}

struct MobileSystemActionConfirmation: View {
    @Bindable var model: MobileSystemActionsModel
    let source: MobileSystemActionPrompt
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let action = source.action {
                        switch action {
                        case .disconnect(let connection):
                            Text(L10n.string(connection.isCurrentConnection || connection.isWebConnection ? "mobile.nas.connection.webWarning" : "mobile.nas.connection.warning"))
                        case .power(let action): Text(L10n.string(action == .shutdown ? "mobile.nas.system.shutdownWarning" : "mobile.nas.system.rebootWarning", source.nasName))
                        }
                    } else { Text(L10n.string("mobile.nas.system.restoreWarning")) }
                }
                if let connection = source.action?.connection { Section { MobileConnectionFields(connection: connection) } }
            }
            .accessibilityIdentifier("mobile.nas.system.confirmation")
            .navigationTitle(source.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.cancel"), action: cancel).accessibilityIdentifier("mobile.nas.system.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(source.title, role: source.action == nil ? nil : .destructive, action: confirm)
                        .disabled(!source.isAllowed(by: model)).accessibilityIdentifier("mobile.nas.system.confirm")
                }
            }
        }
    }
}

private struct MobileSystemActionRecord: View {
    @Bindable var model: MobileSystemActionsModel
    let entry: MobileSystemActionStore.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.action.title).font(.headline)
            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.service.working") : entry.message)
                .accessibilityIdentifier("mobile.nas.system.activity.\(entry.phase.rawValue)")
            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
            if entry.isProtected && entry.action == .disconnect {
                Button(L10n.string("mobile.nas.service.refresh")) { Task { await model.refreshConnections() } }
                    .disabled(model.isOperating).accessibilityIdentifier("mobile.nas.connection.recover")
            } else if !entry.isProtected {
                Button(L10n.string("mobile.nas.service.removeRecord")) { model.removeRecord(entry.id) }
                    .disabled(model.recovery.isExecuting(entry.id)).accessibilityIdentifier("mobile.nas.system.removeRecord")
            }
        }
    }
}

extension NasSystemActionKind {
    var title: String {
        let key = switch self { case .disconnect: "mobile.nas.connection.disconnect"; case .shutdown: "mobile.nas.system.shutdown"; case .reboot: "mobile.nas.system.reboot" }
        return L10n.string(key)
    }
}
extension MobileSystemActionStore.Entry {
    var message: String {
        let key: String
        switch phase {
        case .prepared: key = "mobile.nas.service.working"
        case .submitted: key = action == .disconnect ? "mobile.nas.connection.pending" : "mobile.nas.system.pending"
        case .accepted: key = action == .shutdown ? "mobile.nas.system.shutdownAccepted" : "mobile.nas.system.rebootAccepted"
        case .succeeded: key = "mobile.nas.connection.disconnected"
        case .released: key = accepted ? "mobile.nas.system.previousAccepted" : "mobile.nas.system.previousUnknown"
        case .cancelled: key = "mobile.nas.system.cancelled"
        case .failed:
            switch failure { case .denied: key = "mobile.nas.system.denied"; case .unavailable: key = "mobile.nas.system.unavailable"; case .changed: key = "mobile.nas.system.changed"; default: key = "mobile.nas.system.failed" }
        }
        return L10n.string(key)
    }
}
extension MobileSystemActionsModel.Failure {
    var message: String {
        let key = switch self { case .read: "mobile.nas.system.readError"; case .denied: "mobile.nas.system.denied"; case .unavailable: "mobile.nas.system.unavailable"; case .changed: "mobile.nas.system.changed"; case .storage: "mobile.nas.system.storageError"; case .trust: "mobile.nas.system.trustError" }
        return L10n.string(key)
    }
}
