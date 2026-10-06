import DsmCore
import DsmLocalization
import SwiftUI

struct MobileVirtualMachineNetworksView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let summaries: [MobileVirtualizationResourceItem]
    @State private var search = ""
    @State private var showsSelection = false
    private var visible: [VirtualMachineNetworkState] {
        model.networkInventory.networks.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        Group {
            if !model.networkHasLoaded {
                ProgressView(L10n.string("mobile.virtual-machines.network.loading")).fillsAvailableContentArea()
                    .accessibilityIdentifier("virtual-machine.network.loading")
            } else if model.networkInventory.networks.isEmpty, let error = model.networkError {
                if error == .unavailable && !summaries.isEmpty {
                    let filtered = summaries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        List {
                            MobileVirtualMachineNetworkNotice(model: model)
                            ForEach(filtered) { Text($0.name) }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.virtual-machines.network.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(L10n.string(error.networkKey)) } actions: {
                        if error != .trust && error != .denied {
                            Button(L10n.string("mobile.virtual-machines.action.retry")) { Task { await model.refreshNetworks() } }
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        }
                    }
                    .accessibilityIdentifier("virtual-machine.network.error")
                }
            } else if model.networkInventory.networks.isEmpty {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.network.empty"), systemImage: "network",
                    description: Text(L10n.string("mobile.virtual-machines.network.empty.message")))
                    .accessibilityIdentifier("virtual-machine.network.empty")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search).accessibilityIdentifier("virtual-machine.network.filtered-empty")
            } else {
                List {
                    MobileVirtualMachineNetworkNotice(model: model)
                    ForEach(visible) { network in
                        NavigationLink {
                            MobileVirtualMachineNetworkDetail(model: model, id: network.id, activation: model.activation)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(network.name)
                                Text(L10n.string("mobile.virtual-machines.network.guests-count", network.guests.count))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("virtual-machine.network.\(network.id)")
                    }

                }
                .accessibilityIdentifier("virtual-machine.network.list")
                .refreshable { await model.refreshNetworks() }
            }
        }
        .fillsAvailableContentArea(alignment: visible.isEmpty ? .center : .topLeading)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.virtual-machines.network.search"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    MobileVirtualMachineNetworkRecordsView(model: model)
                } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel(L10n.string("mobile.virtual-machines.control.records"))
                    .accessibilityIdentifier("virtual-machine.network.records.toolbar")
                Button(L10n.string("mobile.virtual-machines.network.refresh"), systemImage: "arrow.clockwise") { Task { await model.refreshNetworks() } }
                    .disabled(model.networkIsRefreshing || model.isOperating)
                    .accessibilityIdentifier("virtual-machine.network.refresh")
                Button(L10n.string("mobile.virtual-machines.network.selection"), systemImage: "checklist") { showsSelection = true }
                    .disabled(!model.networkAllowed || model.networkInventory.networks.isEmpty || model.isOperating)
                    .accessibilityIdentifier("virtual-machine.network.selection")
            }
        }
        .task(id: model.activation) { await model.refreshNetworks() }
        .sheet(isPresented: $showsSelection) { MobileVirtualMachineNetworkSelectionView(model: model) }
    }
}

private struct MobileVirtualMachineNetworkDetail: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let id: String
    let activation: UUID
    @State private var showsRename = false
    @State private var confirmation: MobileVirtualMachineControlModel.NetworkConfirmation?
    private var target: VirtualMachineNetworkState? { model.networkInventory.networks.first { $0.id == id } }
    var body: some View {
        Group {
            if let target, model.activation == activation {
                List {
                    MobileVirtualMachineNetworkNotice(model: model)
                    Section {
                        LabeledContent(L10n.string("mobile.virtual-machines.network.type"), value: L10n.string(target.type == "external"
                            ? "mobile.virtual-machines.network.external" : "mobile.virtual-machines.network.private"))
                        LabeledContent(L10n.string("mobile.virtual-machines.network.vlan"), value: target.vlanID == 0
                            ? L10n.string("mobile.virtual-machines.network.no-vlan") : target.vlanID.formatted(.number.locale(L10n.locale)))
                    }
                    Section(L10n.string("mobile.virtual-machines.network.guests")) {
                        if target.guests.isEmpty { Text(L10n.string("mobile.virtual-machines.network.no-guests")).foregroundStyle(.secondary) }
                        ForEach(target.guests) { guest in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(guest.name)
                                Text(L10n.string(guest.isRunning ? "mobile.virtual-machines.status.running" : "mobile.virtual-machines.status.stopped"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Section {
                        Button { showsRename = true } label: {
                            Text(L10n.string("mobile.virtual-machines.network.rename")).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.canManageNetworks(ids: [id])).accessibilityIdentifier("virtual-machine.network.rename")
                        Button(role: .destructive) {
                            confirmation = model.networkConfirmation(ids: [id])
                        } label: {
                            Text(L10n.string("mobile.virtual-machines.network.delete")).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.canManageNetworks(ids: [id])).accessibilityIdentifier("virtual-machine.network.delete")
                    }
                }
                .navigationTitle(target.name)
                .sheet(isPresented: $showsRename) { MobileVirtualMachineNetworkRenameView(model: model, target: target, activation: activation) }
            } else {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.network.gone"), systemImage: "network",
                    description: Text(L10n.string("mobile.virtual-machines.network.gone.message")))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: .topLeading)
        .sheet(item: $confirmation) { MobileVirtualMachineNetworkConfirmationView(model: model, confirmation: $0) }
    }
}

private struct MobileVirtualMachineNetworkSelectionView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    @State private var selected: Set<String> = []
    @State private var confirmation: MobileVirtualMachineControlModel.NetworkConfirmation?
    @State private var activation: UUID
    @Environment(\.dismiss) private var dismiss
    init(model: MobileVirtualMachineControlModel) { self.model = model; _activation = State(initialValue: model.activation) }
    var body: some View {
        NavigationStack {
            List {
                MobileVirtualMachineNetworkNotice(model: model)
                ForEach(model.networkInventory.networks) { target in
                    Button {
                        if !selected.insert(target.id).inserted { selected.remove(target.id) }
                    } label: {
                        HStack {
                            Text(target.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(target.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(!model.canManageNetworks(ids: [target.id]))
                    .accessibilityAddTraits(selected.contains(target.id) ? .isSelected : [])
                    .accessibilityIdentifier("virtual-machine.network.select.\(target.id)")
                }
                Section {
                    Button(L10n.string("mobile.virtual-machines.network.delete"), role: .destructive) {
                        confirmation = model.networkConfirmation(ids: selected)
                    }
                    .frame(minHeight: 44).disabled(!model.canManageNetworks(ids: selected))
                    .accessibilityIdentifier("virtual-machine.network.selection.delete")
                }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.network.selection"))
            .disabled(activation != model.activation)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done")) { dismiss() }.accessibilityIdentifier("virtual-machine.network.selection.done") } }
            .sheet(item: $confirmation) { MobileVirtualMachineNetworkConfirmationView(model: model, confirmation: $0) }
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

private struct MobileVirtualMachineNetworkConfirmationView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let confirmation: MobileVirtualMachineControlModel.NetworkConfirmation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.string("mobile.virtual-machines.network.delete.warning"))
                    Text(L10n.string("mobile.virtual-machines.network.delete.count", confirmation.targets.count,
                        Set(confirmation.targets.flatMap { $0.guests.map(\.id) }).count)).font(.subheadline)
                }
                ForEach(confirmation.targets) { target in
                    Section(target.name) {
                        if target.guests.isEmpty { Text(L10n.string("mobile.virtual-machines.network.no-guests")).foregroundStyle(.secondary) }
                        ForEach(target.guests) { Text($0.name) }
                    }
                }
                Section {
                    Button(L10n.string("mobile.virtual-machines.network.delete"), role: .destructive) {
                        _ = model.deleteNetworks(confirmation); dismiss()
                    }
                    .frame(minHeight: 44)
                    .disabled(confirmation.activation != model.activation || !model.canManageNetworks(ids: Set(confirmation.targets.map(\.id))))
                    .accessibilityIdentifier("virtual-machine.network.confirm")
                }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.network.delete"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.virtual-machines.control.cancel")) { dismiss() }.accessibilityIdentifier("virtual-machine.network.cancel") } }
            .accessibilityIdentifier("virtual-machine.network.confirmation")
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

private struct MobileVirtualMachineNetworkRenameView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let target: VirtualMachineNetworkState
    let activation: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false
    @State private var recordID: UUID?
    @FocusState private var focused: Bool
    init(model: MobileVirtualMachineControlModel, target: VirtualMachineNetworkState, activation: UUID) {
        self.model = model; self.target = target; self.activation = activation; _name = State(initialValue: target.name)
    }
    var body: some View {
        NavigationStack {
            Form {
                MobileVirtualMachineNetworkNotice(model: model)
                Section {
                    TextField(L10n.string("mobile.virtual-machines.network.name"), text: $name)
                        .focused($focused).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("virtual-machine.network.name")
                }
                if name != target.name && (!VirtualMachineNetworkState.isValidName(name)
                    || model.networkInventory.networks.contains(where: { $0.id != target.id && $0.name.caseInsensitiveCompare(name) == .orderedSame })) && recordID == nil {
                    Section { Text(L10n.string("mobile.virtual-machines.network.name.invalid")).foregroundStyle(.secondary) }
                }
                if !model.networkInventory.networks.contains(target) && recordID == nil {
                    Section { Text(L10n.string("virtual-machine-network.changed")).foregroundStyle(.secondary) }
                }
                if let recordID, let entry = model.networkRecovery.entry(recordID), let item = entry.items.first {
                    Section { MobileVirtualMachineNetworkRecordStatus(model: model, entry: entry, item: item) }
                }
            }
            .disabled(isSaving || activation != model.activation || recordID.flatMap(model.networkRecovery.entry)?.isProtected == true)
            .navigationTitle(L10n.string("mobile.virtual-machines.network.rename"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.virtual-machines.control.cancel")) { dismiss() }.accessibilityIdentifier("virtual-machine.network.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.virtual-machines.settings.save")) {
                        focused = false
                        guard let id = model.renameNetwork(target, name: name, activation: activation) else { return }
                        recordID = id; isSaving = true
                        Task {
                            await model.waitForOperation(id); isSaving = false
                            if model.networkRecovery.entry(id)?.items.first?.phase == .succeeded { dismiss() }
                        }
                    }
                    .disabled(isSaving || activation != model.activation || !model.canRenameNetwork(target, name: name))
                    .accessibilityIdentifier("virtual-machine.network.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.string("mobile.nas.service.done")) { focused = false }.accessibilityIdentifier("virtual-machine.network.keyboardDone")
                }
            }
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

struct MobileVirtualMachineNetworkNotice: View {
    @Bindable var model: MobileVirtualMachineControlModel
    var body: some View {
        if model.networkIsRefreshing {
            ProgressView(L10n.string("mobile.virtual-machines.network.loading"))
        } else if let error = model.networkError {
            Label(L10n.string(error.networkKey), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if model.networkInventory.isFrozen {
            Label(L10n.string("mobile.virtual-machines.network.frozen"), systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }
}

private struct MobileVirtualMachineNetworkRecordsView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    var body: some View {
        Group {
            if model.networkEntries.isEmpty {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.control.records.empty"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.string("mobile.virtual-machines.control.records.empty.message")))
            } else {
                List {
                    MobileVirtualMachineNetworkNotice(model: model)
                    ForEach(model.networkEntries) { entry in
                        Section {
                            ForEach(Array(entry.items.enumerated()), id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.name(for: item) ?? L10n.string("mobile.virtual-machines.network.target", index + 1)).font(.body.weight(.medium))
                                    MobileVirtualMachineNetworkRecordStatus(model: model, entry: entry, item: item)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if !entry.isProtected && !model.networkRecovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.virtual-machines.control.record.remove")) { model.removeNetworkRecord(entry.id) }.frame(minHeight: 44)
                            }
                        } header: {
                            Text(L10n.string("mobile.virtual-machines.control.record.title", L10n.string(entry.action == .rename
                                ? "mobile.virtual-machines.network.rename" : "mobile.virtual-machines.network.delete"),
                                entry.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))))
                        }
                    }
                }
                .refreshable { await model.refreshNetworks() }
            }
        }
        .navigationTitle(L10n.string("mobile.virtual-machines.control.records"))
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: model.networkEntries.isEmpty ? .center : .topLeading)
        .accessibilityIdentifier("virtual-machine.network.records")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button(L10n.string("mobile.virtual-machines.network.refresh"), systemImage: "arrow.clockwise") { Task { await model.refreshNetworks() } }
                .disabled(model.networkIsRefreshing || model.isOperating).accessibilityIdentifier("virtual-machine.network.records.refresh")
        } }
    }
}

private struct MobileVirtualMachineNetworkRecordStatus: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let entry: MobileVirtualMachineNetworkStore.Entry
    let item: MobileVirtualMachineNetworkStore.Item
    var body: some View {
        Text(L10n.string(key)).font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("virtual-machine.network.record.\(item.phase.rawValue)")
    }
    private var key: String {
        switch item.phase {
        case .prepared: "mobile.virtual-machines.control.processing"
        case .submitted: model.networkRecovery.isExecuting(entry.id) ? "mobile.virtual-machines.control.processing" : "virtual-machine-network.pending"
        case .succeeded: entry.action == .rename ? "mobile.virtual-machines.network.rename.completed" : "mobile.virtual-machines.network.delete.completed"
        case .skipped: "mobile.virtual-machines.control.skipped"
        case .failed:
            switch item.failure {
            case .denied: "mobile.virtual-machines.control.error.denied"
            case .unavailable: "virtual-machine-network.unavailable"
            case .changed: "virtual-machine-network.changed"
            default: "mobile.virtual-machines.network.failed"
            }
        }
    }
}

private extension MobileVirtualMachineControlModel.Failure {
    var networkKey: String {
        switch self {
        case .read: "mobile.virtual-machines.network.read-failed"
        case .denied: "mobile.virtual-machines.control.error.denied"
        case .unavailable: "virtual-machine-network.unavailable"
        case .changed: "virtual-machine-network.changed"
        case .storage: "mobile.virtual-machines.control.error.storage"
        case .trust: "mobile.virtual-machines.control.error.trust"
        }
    }
}
