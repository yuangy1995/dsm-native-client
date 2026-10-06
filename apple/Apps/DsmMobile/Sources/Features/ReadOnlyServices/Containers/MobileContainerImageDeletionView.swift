import DsmCore
import DsmLocalization
import SwiftUI

struct MobileContainerImageDeletionView: View {
    @Bindable var model: MobileContainerImageDeletionModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var showsRecords = false
    @State private var confirmation: MobileContainerImageDeletionModel.Confirmation?
    @State private var sourceActivation: UUID?

    private var visible: [ContainerImage] {
        query.isEmpty ? model.targets : model.targets.filter { MobileContainerImageDeletionModel.name($0).localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.string("mobile.containers.image-delete.title"), selection: $showsRecords) {
                    Text(L10n.string("mobile.containers.section.images")).tag(false)
                    Text(L10n.string("mobile.containers.control.records")).tag(true)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("image-delete.section")
                if showsRecords { records }
                else { images }
            }
            .navigationTitle(L10n.string("mobile.containers.image-delete.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("container-image.pull.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("container-image.delete.review"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing || model.isOperating).accessibilityIdentifier("image-delete.refresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !showsRecords {
                    Button(L10n.string("mobile.containers.image-delete.selected", selection.count), role: .destructive) {
                        confirmation = model.confirmation(ids: selection)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).frame(minHeight: 44)
                    .disabled(sourceActivation != model.activation || !model.canDelete(ids: selection))
                    .accessibilityIdentifier("image-delete.selection.confirm")
                    .frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
            }
            .sheet(item: $confirmation) { value in
                MobileContainerImageDeletionConfirmation(model: model, confirmation: value) {
                    selection = []; showsRecords = true
                }
            }
        }
        .task { sourceActivation = model.activation; await model.refresh() }
        .onChange(of: model.activation) { _, value in if sourceActivation != value { dismiss() } }
        .onChange(of: model.targets) { _, values in selection.formIntersection(Set(values.map(\.id))) }
        .onDisappear { model.cancelRead() }
    }
    private var images: some View {
        Group {
            if !model.hasLoaded && model.isRefreshing {
                ProgressView(L10n.string("mobile.containers.loading")).accessibilityIdentifier("image-delete.loading")
            } else if let error = model.error, model.targets.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("mobile.containers.image-delete.load-failed"), systemImage: "exclamationmark.triangle")
                } description: { Text(error.message) } actions: {
                    Button(L10n.string("mobile.containers.action.retry")) { Task { await model.refresh() } }
                }.accessibilityIdentifier("image-delete.load-error")
            } else if model.targets.isEmpty {
                ContentUnavailableView(L10n.string("mobile.containers.image-delete.empty"), systemImage: "square.stack.3d.up",
                    description: Text(L10n.string("mobile.containers.image-delete.empty-help")))
                    .accessibilityIdentifier("image-delete.empty")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: query).accessibilityIdentifier("image-delete.filtered-empty")
            } else {
                List {
                    if let error = model.error { Text(error.message).foregroundStyle(.secondary) }
                    if model.isRefreshing { ProgressView() }
                    ForEach(visible) { target in
                        Button {
                            if !selection.insert(target.id).inserted { selection.remove(target.id) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(MobileContainerImageDeletionModel.name(target)).foregroundStyle(.primary)
                                    if target.isInUse { Text(L10n.string("mobile.containers.value.in-use")).font(.caption).foregroundStyle(.secondary) }
                                    else if model.containsTaggedAliases(target) {
                                        Text(L10n.string("mobile.containers.image-delete.other-tags")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    else if !model.canDelete(ids: [target.id]) && model.allowed && !model.isRefreshing && !model.isOperating {
                                        Text(L10n.string("mobile.containers.image-delete.protected")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selection.contains(target.id) ? "checkmark.circle.fill" : "circle")
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .disabled(!model.canDelete(ids: [target.id]))
                        .accessibilityAddTraits(selection.contains(target.id) ? .isSelected : [])
                        .accessibilityIdentifier("image-delete.select.\(target.repository).\(target.tag)")
                    }
                }.listStyle(.insetGrouped).accessibilityIdentifier("image-delete.images")
                    .refreshable { await model.refresh() }
            }
        }
        .fillsAvailableContentArea(alignment: model.targets.isEmpty || visible.isEmpty ? .center : .topLeading)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.containers.pull.query"))
    }
    private var records: some View {
        List {
            if let error = model.error { Text(error.message).foregroundStyle(.secondary) }
            if model.isRefreshing { ProgressView() }
            if model.entries.isEmpty {
                ContentUnavailableView(L10n.string("mobile.containers.control.records.empty"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.string("mobile.containers.image-delete.records-help")))
            }
            ForEach(model.entries) { entry in
                Section {
                    ForEach(Array(entry.recovery.targets.enumerated()), id: \.element.id) { index, target in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.names[target.id] ?? L10n.string("mobile.containers.image-delete.target", index + 1)).font(.headline)
                            Text(message(entry, target: target)).font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("image-delete.record.\(entry.removedTargetIDs.contains(target.id) ? "succeeded" : entry.phase.rawValue)")
                        }.padding(.vertical, 4).accessibilityElement(children: .combine)
                    }
                    if !entry.isProtected && !model.recovery.isExecuting(entry.id) {
                        Button(L10n.string("mobile.containers.control.record.remove")) { model.removeRecord(entry.id) }.frame(minHeight: 44)
                    }
                } header: {
                    Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().locale(L10n.locale))
                }
            }
        }.listStyle(.insetGrouped).accessibilityIdentifier("image-delete.records")
            .refreshable { await model.refresh() }
    }
    private func message(_ entry: MobileContainerImageDeletionStore.Entry, target: ContainerImageDeletionTarget) -> String {
        if entry.removedTargetIDs.contains(target.id) { return L10n.string("mobile.containers.image-delete.completed") }
        if entry.phase == .skipped { return L10n.string("mobile.containers.image-delete.not-sent") }
        if let failure = entry.failure {
            switch failure {
            case .denied: return L10n.string("container-image.delete.permission-denied")
            case .unavailable: return L10n.string("container-image.delete.unsupported")
            case .changed: return L10n.string("container-image.delete.selection-changed")
            case .trust: return L10n.string("mobile.containers.control.error.trust")
            case .failed: break
            }
        }
        if entry.phase == .rejected { return L10n.string("container-image.delete.failed") }
        return L10n.string(model.recovery.isExecuting(entry.id) ? "mobile.containers.image-delete.processing" : "mobile.containers.image-delete.unknown")
    }
}

private struct MobileContainerImageDeletionConfirmation: View {
    @Bindable var model: MobileContainerImageDeletionModel
    let confirmation: MobileContainerImageDeletionModel.Confirmation
    let onSubmitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if confirmation.request.targets.contains(where: { $0.tag != "<none>" }) {
                        Text(L10n.string("mobile.containers.image-delete.tag-risk"))
                    }
                    if confirmation.request.targets.contains(where: { $0.tag == "<none>" }) {
                        Text(L10n.string("mobile.containers.image-delete.image-risk"))
                    }
                }
                Section {
                    ForEach(confirmation.request.targets) { target in
                        Text(MobileContainerImageDeletionModel.name(target)).textSelection(.enabled)
                    }
                }
                Section {
                    Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) {
                        guard model.perform(confirmation) != nil else { return }
                        dismiss(); onSubmitted()
                    }
                    .buttonStyle(.borderedProminent).tint(.red).frame(minHeight: 44)
                    .disabled(confirmation.activation != model.activation || !model.canDelete(ids: Set(confirmation.request.targets.map(\.id))))
                    .accessibilityIdentifier("image-delete.submit")
                }
            }.accessibilityIdentifier("image-delete.confirmation")
            .navigationTitle(L10n.string("mobile.containers.image-delete.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.containers.control.cancel")) { dismiss() } } }
        }
    }
}

private extension MobileContainerImageDeletionModel.Failure {
    var message: String {
        switch self {
        case .read: L10n.string("mobile.containers.pull.read-error")
        case .denied: L10n.string("container-image.delete.permission-denied")
        case .unavailable: L10n.string("container-image.delete.unsupported")
        case .changed: L10n.string("container-image.delete.selection-changed")
        case .storage: L10n.string("mobile.containers.control.error.storage")
        case .trust: L10n.string("mobile.containers.control.error.trust")
        }
    }
}
