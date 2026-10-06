import DsmCore
import DsmLocalization
import SwiftUI

struct MobileContainerActions: View {
    @Bindable var model: MobileContainerControlModel
    let ids: Set<String>
    @State private var confirmation: MobileContainerControlModel.Confirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ids.count == 1, let target = model.targets.first(where: { ids.contains($0.id) }) {
                if target.managedByPackage == true {
                    Text(L10n.string("mobile.containers.control.managed")).font(.subheadline).foregroundStyle(.secondary)
                } else if target.running == nil || target.paused == nil || target.restarting == nil || target.managedByPackage == nil {
                    Text(L10n.string("mobile.containers.control.error.read")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(ContainerAction.allCases, id: \.rawValue) { action in
                Button { confirmation = model.confirmation(ids: ids, action: action) } label: {
                    Text(action.mobileTitle).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canPerform(ids: ids, action: action))
                .accessibilityIdentifier("container.action.\(action.rawValue)")
            }
        }
        .sheet(item: $confirmation) { value in
            MobileContainerConfirmationView(model: model, confirmation: value)
        }
    }
}

struct MobileContainerSelectionView: View {
    @Bindable var model: MobileContainerControlModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var sourceActivation: UUID
    init(model: MobileContainerControlModel) { self.model = model; _sourceActivation = State(initialValue: model.activation) }
    var body: some View {
        NavigationStack {
            List {
                MobileContainerControlNotice(model: model)
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
                        .accessibilityIdentifier("container.select.\(target.id)")
                        .disabled(model.isOperating || !ContainerAction.allCases.contains(where: target.supports))
                    }
                }
                Section { MobileContainerActions(model: model, ids: selection) }
            }
            .navigationTitle(L10n.string("mobile.containers.control.selection"))
            .accessibilityIdentifier("container.selection.list")
            .disabled(sourceActivation != model.activation)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done")) { dismiss() } } }
            .refreshable { await model.refresh() }
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

private struct MobileContainerConfirmationView: View {
    @Bindable var model: MobileContainerControlModel
    let confirmation: MobileContainerControlModel.Confirmation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if confirmation.action != .start {
                    Section {
                        Text(L10n.string(confirmation.action == .stop ? "mobile.containers.control.stop.warning" : "mobile.containers.control.restart.warning"))
                    }
                }
                Section {
                    ForEach(confirmation.targets, id: \.id) { target in Text(target.name) }
                }
                Section {
                    Button(confirmation.action.mobileTitle, role: confirmation.action == .start ? nil : .destructive) {
                        _ = model.perform(confirmation); dismiss()
                    }
                    .frame(minHeight: 44)
                    .disabled(confirmation.activation != model.activation || !model.canPerform(ids: Set(confirmation.targets.map(\.id)), action: confirmation.action))
                    .accessibilityIdentifier("container.confirm")
                }
            }
            .accessibilityIdentifier("container.confirmation")
            .navigationTitle(confirmation.action.mobileTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.containers.control.cancel")) { dismiss() } } }
        }
    }
}

struct MobileContainerControlNotice: View {
    @Bindable var model: MobileContainerControlModel
    var body: some View {
        if model.isRefreshing {
            ProgressView(L10n.string("mobile.containers.loading"))
        } else if let error = model.error {
            let key = switch error {
            case .read: "mobile.containers.control.error.read"
            case .denied: "mobile.containers.control.error.denied"
            case .unavailable: "mobile.containers.control.error.unavailable"
            case .changed: "mobile.containers.control.error.changed"
            case .storage: "mobile.containers.control.error.storage"
            case .trust: "mobile.containers.control.error.trust"
            }
            Label(L10n.string(key), systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.orange)
        }
    }
}

struct MobileContainerControlRecordsView: View {
    @Bindable var model: MobileContainerControlModel
    var body: some View {
        Group {
            if model.entries.isEmpty {
                ContentUnavailableView(L10n.string("mobile.containers.control.records.empty"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.string("mobile.containers.control.records.empty.message")))
            } else {
                List {
                    MobileContainerControlNotice(model: model)
                    ForEach(model.entries) { entry in
                        Section {
                            ForEach(Array(entry.items.enumerated()), id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.targets.first(where: item.matches)?.name ?? L10n.string("mobile.containers.control.target", index + 1))
                                        .font(.body.weight(.medium))
                                    Text(status(item, entry: entry)).font(.subheadline).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("container.record.\(item.phase.rawValue)")
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if !entry.isProtected && !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.containers.control.record.remove")) { model.removeRecord(entry.id) }
                                    .frame(minHeight: 44)
                            }
                        } header: {
                            Text(L10n.string("mobile.containers.control.record.title", entry.action.mobileTitle,
                                entry.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))))
                        }
                    }
                }
                .refreshable { await model.refresh() }
            }
        }
        .navigationTitle(L10n.string("mobile.containers.control.records"))
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: model.entries.isEmpty ? .center : .topLeading)
        .accessibilityIdentifier("container.records")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("mobile.containers.action.retry"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing || model.isOperating)
                    .accessibilityIdentifier("container.records.refresh")
            }
        }
    }
    private func status(_ item: MobileContainerControlStore.Item, entry: MobileContainerControlStore.Entry) -> String {
        switch item.phase {
        case .prepared: return L10n.string("mobile.containers.control.processing")
        case .submitted:
            return L10n.string(model.recovery.isExecuting(entry.id) ? "mobile.containers.control.processing" : "mobile.containers.control.unavailable-result")
        case .succeeded:
            let key = switch entry.action {
            case .start: "mobile.containers.control.start.completed"
            case .stop: "mobile.containers.control.stop.completed"
            case .restart: "mobile.containers.control.restart.completed"
            }
            return L10n.string(key)
        case .skipped: return L10n.string("mobile.containers.control.skipped")
        case .failed:
            switch item.failure {
            case .denied: return L10n.string("mobile.containers.control.error.denied")
            case .unavailable: return L10n.string("mobile.containers.control.error.unavailable")
            case .changed: return L10n.string("mobile.containers.control.error.changed")
            default: return L10n.string("mobile.containers.control.error.failed")
            }
        }
    }
}

extension ContainerAction {
    var mobileTitle: String {
        let key = switch self {
        case .start: "mobile.containers.control.start"
        case .stop: "mobile.containers.control.stop"
        case .restart: "mobile.containers.control.restart"
        }
        return L10n.string(key)
    }
}
