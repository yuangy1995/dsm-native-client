import DsmCore
import DsmLocalization
import SwiftUI

struct MobileVirtualMachineActions: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let ids: Set<String>
    @State private var confirmation: MobileVirtualMachineControlModel.Confirmation?
    @State private var settings: MobileVirtualMachineSettingsRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ids.count == 1, let target = model.targets.first(where: { ids.contains($0.id) }),
               target.status == "running", !target.availableActions.contains(.restart) {
                Text(L10n.string("virtual-machine.power.restart-unavailable")).font(.subheadline).foregroundStyle(.secondary)
            }
            if ids.count == 1, let id = ids.first {
                Button {
                    settings = .init(targetID: id, activation: model.activation)
                } label: {
                    Text(L10n.string("mobile.virtual-machines.settings.title")).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered).disabled(!model.canEdit(id: id))
                .accessibilityIdentifier("virtual-machine.action.edit")
            }
            ForEach(MobileVirtualMachineControlStore.Kind.controlCases, id: \.rawValue) { action in
                Button(role: action == .delete ? .destructive : nil) { confirmation = model.confirmation(ids: ids, kind: action) } label: {
                    Text(action.mobileTitle).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canPerform(ids: ids, kind: action))
                .accessibilityIdentifier("virtual-machine.action.\(action.rawValue)")
            }
        }
        .sheet(item: $confirmation) { value in
            MobileVirtualMachineConfirmationView(model: model, confirmation: value)
        }
        .sheet(item: $settings) { value in MobileVirtualMachineSettingsView(model: model, request: value) }
    }
}

struct MobileVirtualMachineSelectionView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var sourceActivation: UUID
    init(model: MobileVirtualMachineControlModel) { self.model = model; _sourceActivation = State(initialValue: model.activation) }
    var body: some View {
        NavigationStack {
            List {
                MobileVirtualMachineControlNotice(model: model)
                Section {
                    ForEach(model.targets, id: \.id) { target in
                        Button {
                            if !selection.insert(target.id).inserted { selection.remove(target.id) }
                        } label: {
                            HStack {
                                Text(target.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selection.contains(target.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selection.contains(target.id) ? .isSelected : [])
                        .accessibilityIdentifier("virtual-machine.select.\(target.id)")
                        .disabled(model.isOperating || !MobileVirtualMachineControlStore.Kind.allCases.contains(where: { $0.supports(target) }))
                    }
                }
                Section { MobileVirtualMachineActions(model: model, ids: selection) }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.control.selection"))
            .accessibilityIdentifier("virtual-machine.selection.list")
            .disabled(sourceActivation != model.activation)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done")) { dismiss() } } }
            .refreshable { await model.refresh() }
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

private struct MobileVirtualMachineConfirmationView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let confirmation: MobileVirtualMachineControlModel.Confirmation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if confirmation.action != .powerOn {
                    Section {
                        let warningKey = switch confirmation.action {
                        case .powerOn: "mobile.virtual-machines.control.powerOn"
                        case .shutdown: "mobile.virtual-machines.control.shutdown.warning"
                        case .powerOff: "mobile.virtual-machines.control.powerOff.warning"
                        case .restart: "mobile.virtual-machines.control.restart.warning"
                        case .delete: "mobile.virtual-machines.control.delete.warning"
                        case .edit: "mobile.virtual-machines.settings.title"
                        }
                        Text(L10n.string(warningKey))
                    }
                }
                Section {
                    ForEach(confirmation.targets, id: \.id) { target in Text(target.name) }
                }
                Section {
                    Button(confirmation.action.mobileTitle, role: confirmation.action == .powerOn ? nil : .destructive) {
                        _ = model.perform(confirmation); dismiss()
                    }
                    .frame(minHeight: 44)
                    .disabled(confirmation.activation != model.activation || !model.canPerform(ids: Set(confirmation.targets.map(\.id)), kind: confirmation.action))
                    .accessibilityIdentifier("virtual-machine.confirm")
                }
            }
            .accessibilityIdentifier("virtual-machine.confirmation")
            .navigationTitle(confirmation.action.mobileTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.virtual-machines.control.cancel")) { dismiss() } } }
        }
    }
}

struct MobileVirtualMachineControlNotice: View {
    @Bindable var model: MobileVirtualMachineControlModel
    var body: some View {
        if model.isRefreshing {
            ProgressView(L10n.string("mobile.virtual-machines.loading"))
        } else if let error = model.error {
            let key = switch error {
            case .read: "mobile.virtual-machines.control.error.read"
            case .denied: "mobile.virtual-machines.control.error.denied"
            case .unavailable: "mobile.virtual-machines.control.error.unavailable"
            case .changed: "mobile.virtual-machines.control.error.changed"
            case .storage: "mobile.virtual-machines.control.error.storage"
            case .trust: "mobile.virtual-machines.control.error.trust"
            }
            Label(L10n.string(key), systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.orange)
        }
    }
}

struct MobileVirtualMachineControlRecordsView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    var body: some View {
        Group {
            if model.entries.isEmpty && model.creationEntries.isEmpty {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.control.records.empty"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.string("mobile.virtual-machines.control.records.empty.message")))
            } else {
                List {
                    MobileVirtualMachineControlNotice(model: model)
                    ForEach(model.creationEntries) { entry in
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.name(for: entry) ?? L10n.string("mobile.virtual-machines.creation.title"))
                                    .font(.body.weight(.medium))
                                MobileVirtualMachineCreationStatus(entry: entry, isExecuting: model.creations.isExecuting(entry.id))
                            }
                            if !entry.isProtected && !model.creations.isExecuting(entry.id) {
                                Button(L10n.string("mobile.virtual-machines.control.record.remove")) { model.removeCreationRecord(entry.id) }
                                    .frame(minHeight: 44)
                            }
                        } header: {
                            Text(L10n.string("mobile.virtual-machines.control.record.title", L10n.string("mobile.virtual-machines.creation.title"),
                                entry.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))))
                        }
                    }
                    ForEach(model.entries) { entry in
                        Section {
                            ForEach(Array(entry.items.enumerated()), id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.name(for: item) ?? L10n.string("mobile.virtual-machines.control.target", index + 1))
                                        .font(.body.weight(.medium))
                                    Text(status(item, entry: entry)).font(.subheadline).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("virtual-machine.record.\(item.phase.rawValue)")
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if !entry.isProtected && !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.virtual-machines.control.record.remove")) { model.removeRecord(entry.id) }
                                    .frame(minHeight: 44)
                            }
                        } header: {
                            Text(L10n.string("mobile.virtual-machines.control.record.title", entry.action.mobileTitle,
                                entry.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))))
                        }
                    }
                }
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle(L10n.string("mobile.virtual-machines.control.records"))
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: model.entries.isEmpty && model.creationEntries.isEmpty ? .center : .topLeading)
        .accessibilityIdentifier("virtual-machine.records")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("mobile.virtual-machines.action.retry"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing || model.isOperating)
                    .accessibilityIdentifier("virtual-machine.records.refresh")
            }
        }
    }
    private func status(_ item: MobileVirtualMachineControlStore.Item, entry: MobileVirtualMachineControlStore.Entry) -> String {
        switch item.phase {
        case .prepared: return L10n.string("mobile.virtual-machines.control.processing")
        case .submitted:
            if entry.action == .restart && item.accepted && !model.recovery.isExecuting(entry.id) {
                return L10n.string("mobile.virtual-machines.control.restart.accepted")
            }
            return L10n.string(model.recovery.isExecuting(entry.id) ? "mobile.virtual-machines.control.processing" : "mobile.virtual-machines.control.unavailable-result")
        case .succeeded:
            let key = switch entry.action {
            case .powerOn: "mobile.virtual-machines.control.powerOn.completed"
            case .shutdown: "mobile.virtual-machines.control.shutdown.completed"
            case .powerOff: "mobile.virtual-machines.control.powerOff.completed"
            case .restart: "mobile.virtual-machines.control.restart.accepted"
            case .delete: "mobile.virtual-machines.control.delete.completed"
            case .edit: "mobile.virtual-machines.settings.completed"
            }
            return L10n.string(key)
        case .skipped: return L10n.string("mobile.virtual-machines.control.skipped")
        case .failed:
            switch item.failure {
            case .denied: return L10n.string("mobile.virtual-machines.control.error.denied")
            case .unavailable: return L10n.string("mobile.virtual-machines.control.error.unavailable")
            case .changed: return L10n.string("mobile.virtual-machines.control.error.changed")
            default: return L10n.string("mobile.virtual-machines.control.error.failed")
            }
        }
    }
}

extension VirtualMachinePowerAction {
    var mobileTitle: String {
        let key = switch self {
        case .powerOn: "mobile.virtual-machines.control.powerOn"
        case .shutdown: "mobile.virtual-machines.control.shutdown"
        case .powerOff: "mobile.virtual-machines.control.powerOff"
        case .restart: "mobile.virtual-machines.control.restart"
        }
        return L10n.string(key)
    }
}

extension MobileVirtualMachineControlStore.Kind {
    var mobileTitle: String {
        if let controlAction { return controlAction.mobileTitle }
        return L10n.string(self == .edit ? "mobile.virtual-machines.settings.save" : "mobile.virtual-machines.control.delete")
    }
}
