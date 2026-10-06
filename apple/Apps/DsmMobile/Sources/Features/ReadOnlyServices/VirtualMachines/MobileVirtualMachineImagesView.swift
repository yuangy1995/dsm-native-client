import DsmCore
import DsmLocalization
import SwiftUI

struct MobileVirtualMachineImagesView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let summaries: [MobileVirtualizationResourceItem]
    @State private var search = ""
    @State private var showsSelection = false
    private var visible: [VirtualMachineImageState] {
        model.imageInventory.images.filter { search.isEmpty || ($0.name ?? "").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        Group {
            if !model.imageHasLoaded {
                ProgressView(L10n.string("mobile.virtual-machines.image.loading")).fillsAvailableContentArea()
                    .accessibilityIdentifier("virtual-machine.image.loading")
            } else if model.imageInventory.images.isEmpty, let error = model.imageError {
                if error == .unavailable && !summaries.isEmpty {
                    let filtered = summaries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        List {
                            MobileVirtualMachineImageNotice(model: model)
                            ForEach(filtered) { Text($0.name) }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.virtual-machines.image.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(L10n.string(error.imageKey)) } actions: {
                        if error != .trust && error != .denied {
                            Button(L10n.string("mobile.virtual-machines.action.retry")) { Task { await model.refreshImages() } }
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        }
                    }
                    .accessibilityIdentifier("virtual-machine.image.error")
                }
            } else if model.imageInventory.images.isEmpty {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.image.empty"), systemImage: "opticaldisc",
                    description: Text(L10n.string("mobile.virtual-machines.image.empty.message")))
                    .accessibilityIdentifier("virtual-machine.image.empty")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search).accessibilityIdentifier("virtual-machine.image.filtered-empty")
            } else {
                List {
                    MobileVirtualMachineImageNotice(model: model)
                    ForEach(visible) { image in
                        NavigationLink {
                            MobileVirtualMachineImageDetail(model: model, id: image.id, activation: model.activation)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(image.displayName)
                                Text(image.detailText)
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("virtual-machine.image.\(image.id)")
                    }

                }
                .accessibilityIdentifier("virtual-machine.image.list")
                .refreshable { await model.refreshImages() }
            }
        }
        .fillsAvailableContentArea(alignment: visible.isEmpty ? .center : .topLeading)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.virtual-machines.image.search"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    MobileVirtualMachineImageRecordsView(model: model)
                } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel(L10n.string("mobile.virtual-machines.control.records"))
                    .accessibilityIdentifier("virtual-machine.image.records.toolbar")
                Button(L10n.string("mobile.virtual-machines.image.refresh"), systemImage: "arrow.clockwise") { Task { await model.refreshImages() } }
                    .disabled(model.imageIsRefreshing || model.isOperating)
                    .accessibilityIdentifier("virtual-machine.image.refresh")
                Button(L10n.string("mobile.virtual-machines.image.selection"), systemImage: "checklist") { showsSelection = true }
                    .disabled(!model.imageAllowed || model.imageInventory.images.isEmpty || model.isOperating)
                    .accessibilityIdentifier("virtual-machine.image.selection")
            }
        }
        .task(id: model.activation) { await model.refreshImages() }
        .sheet(isPresented: $showsSelection) { MobileVirtualMachineImageSelectionView(model: model) }
    }
}

private struct MobileVirtualMachineImageDetail: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let id: String
    let activation: UUID
    @State private var confirmation: MobileVirtualMachineControlModel.ImageConfirmation?
    private var target: VirtualMachineImageState? { model.imageInventory.images.first { $0.id == id } }
    var body: some View {
        Group {
            if let target, model.activation == activation {
                List {
                    MobileVirtualMachineImageNotice(model: model)
                    Section {
                        LabeledContent(L10n.string("mobile.virtual-machines.image.type"), value: target.detailText)
                        if !target.copies.isEmpty {
                            LabeledContent(L10n.string("mobile.virtual-machines.image.copies"), value: target.copies.count.formatted(.number.locale(L10n.locale)))
                        }
                        if target.isInUse == true {
                            Label(L10n.string("mobile.virtual-machines.image.in-use"), systemImage: "lock.fill").foregroundStyle(.secondary)
                        } else if !target.canDelete || target.name == nil {
                            Text(L10n.string("mobile.virtual-machines.image.not-ready")).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button(role: .destructive) { confirmation = model.imageConfirmation(ids: [id]) } label: {
                            Text(L10n.string("mobile.virtual-machines.image.delete")).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.canDeleteImages(ids: [id])).accessibilityIdentifier("virtual-machine.image.delete")
                    }
                }
                .navigationTitle(target.displayName)
            } else {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.image.gone"), systemImage: "opticaldisc",
                    description: Text(L10n.string("mobile.virtual-machines.image.gone.message")))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: .topLeading)
        .sheet(item: $confirmation) { MobileVirtualMachineImageConfirmationView(model: model, confirmation: $0) }
    }
}

private struct MobileVirtualMachineImageSelectionView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    @State private var selected: Set<String> = []
    @State private var confirmation: MobileVirtualMachineControlModel.ImageConfirmation?
    @State private var activation: UUID
    @Environment(\.dismiss) private var dismiss
    init(model: MobileVirtualMachineControlModel) { self.model = model; _activation = State(initialValue: model.activation) }
    var body: some View {
        NavigationStack {
            List {
                MobileVirtualMachineImageNotice(model: model)
                ForEach(model.imageInventory.images) { target in
                    Button {
                        if !selected.insert(target.id).inserted { selected.remove(target.id) }
                    } label: {
                        HStack {
                            Text(target.displayName).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(target.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(!model.canDeleteImages(ids: [target.id]))
                    .accessibilityAddTraits(selected.contains(target.id) ? .isSelected : [])
                    .accessibilityIdentifier("virtual-machine.image.select.\(target.id)")
                }
                Section {
                    Button(L10n.string("mobile.virtual-machines.image.delete"), role: .destructive) {
                        confirmation = model.imageConfirmation(ids: selected)
                    }
                    .frame(minHeight: 44).disabled(!model.canDeleteImages(ids: selected))
                    .accessibilityIdentifier("virtual-machine.image.selection.delete")
                }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.image.selection"))
            .disabled(activation != model.activation)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done")) { dismiss() }.accessibilityIdentifier("virtual-machine.image.selection.done") } }
            .sheet(item: $confirmation) { MobileVirtualMachineImageConfirmationView(model: model, confirmation: $0) }
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

private struct MobileVirtualMachineImageConfirmationView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let confirmation: MobileVirtualMachineControlModel.ImageConfirmation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.string("mobile.virtual-machines.image.delete.warning"))
                    Text(L10n.string("mobile.virtual-machines.image.delete.count", confirmation.targets.count)).font(.subheadline)
                }
                ForEach(confirmation.targets) { target in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(target.displayName)
                        Text(target.detailText).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(L10n.string("mobile.virtual-machines.image.delete"), role: .destructive) {
                        _ = model.deleteImages(confirmation); dismiss()
                    }
                    .frame(minHeight: 44)
                    .disabled(confirmation.activation != model.activation || !model.canDeleteImages(ids: Set(confirmation.targets.map(\.id))))
                    .accessibilityIdentifier("virtual-machine.image.confirm")
                }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.image.delete"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.virtual-machines.control.cancel")) { dismiss() }.accessibilityIdentifier("virtual-machine.image.cancel") } }
            .accessibilityIdentifier("virtual-machine.image.confirmation")
        }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

struct MobileVirtualMachineImageNotice: View {
    @Bindable var model: MobileVirtualMachineControlModel
    var body: some View {
        if model.imageIsRefreshing {
            ProgressView(L10n.string("mobile.virtual-machines.image.loading"))
        } else if let error = model.imageError {
            Label(L10n.string(error.imageKey), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        } else if model.imageInventory.isFrozen {
            Label(L10n.string("mobile.virtual-machines.image.frozen"), systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }
}

private struct MobileVirtualMachineImageRecordsView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    var body: some View {
        Group {
            if model.imageEntries.isEmpty {
                ContentUnavailableView(L10n.string("mobile.virtual-machines.control.records.empty"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.string("mobile.virtual-machines.control.records.empty.message")))
            } else {
                List {
                    MobileVirtualMachineImageNotice(model: model)
                    ForEach(model.imageEntries) { entry in
                        Section {
                            ForEach(Array(entry.items.enumerated()), id: \.offset) { index, item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.name(for: item) ?? L10n.string("mobile.virtual-machines.image.target", index + 1)).font(.body.weight(.medium))
                                    MobileVirtualMachineImageRecordStatus(model: model, entry: entry, item: item)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if !entry.isProtected && !model.imageRecovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.virtual-machines.control.record.remove")) { model.removeImageRecord(entry.id) }.frame(minHeight: 44)
                            }
                        } header: {
                            Text(L10n.string("mobile.virtual-machines.control.record.title", L10n.string("mobile.virtual-machines.image.delete"),
                                entry.createdAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))))
                        }
                    }
                }
                .refreshable { await model.refreshImages() }
            }
        }
        .navigationTitle(L10n.string("mobile.virtual-machines.control.records"))
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: model.imageEntries.isEmpty ? .center : .topLeading)
        .accessibilityIdentifier("virtual-machine.image.records")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button(L10n.string("mobile.virtual-machines.image.refresh"), systemImage: "arrow.clockwise") { Task { await model.refreshImages() } }
                .disabled(model.imageIsRefreshing || model.isOperating).accessibilityIdentifier("virtual-machine.image.records.refresh")
        } }
    }
}

private struct MobileVirtualMachineImageRecordStatus: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let entry: MobileVirtualMachineImageStore.Entry
    let item: MobileVirtualMachineImageStore.Item
    var body: some View {
        Text(L10n.string(key)).font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("virtual-machine.image.record.\(item.phase.rawValue)")
    }
    private var key: String {
        switch item.phase {
        case .prepared: "mobile.virtual-machines.control.processing"
        case .submitted: model.imageRecovery.isExecuting(entry.id) ? "mobile.virtual-machines.control.processing" : "virtual-machine-image.delete.unverified"
        case .succeeded: "mobile.virtual-machines.image.delete.completed"
        case .skipped: "mobile.virtual-machines.control.skipped"
        case .failed:
            switch item.failure {
            case .denied: "mobile.virtual-machines.control.error.denied"
            case .unavailable: "virtual-machine-image.delete.unsupported"
            case .changed: "mobile.virtual-machines.image.changed"
            default: "mobile.virtual-machines.image.failed"
            }
        }
    }
}

private extension MobileVirtualMachineControlModel.Failure {
    var imageKey: String {
        switch self {
        case .read: "mobile.virtual-machines.image.read-failed"
        case .denied: "mobile.virtual-machines.control.error.denied"
        case .unavailable: "virtual-machine-image.delete.unsupported"
        case .changed: "mobile.virtual-machines.image.changed"
        case .storage: "mobile.virtual-machines.control.error.storage"
        case .trust: "mobile.virtual-machines.control.error.trust"
        }
    }
}

private extension VirtualMachineImageState {
    var displayName: String { name ?? L10n.string("mobile.virtual-machines.image.unnamed") }
    var detailText: String {
        L10n.string(type == "iso" ? "mobile.virtual-machines.image.iso" : type == "disk"
            ? "mobile.virtual-machines.image.disk" : "mobile.virtual-machines.image.type.unknown")
    }
}
