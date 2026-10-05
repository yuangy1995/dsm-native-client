import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadEditDraft: Identifiable {
    let id = UUID()
    let activation: UUID
    let tasks: [DownloadStationTask]
}

struct MobileDownloadEditView: View {
    @Bindable var model: MobileDownloadsModel
    let draft: MobileDownloadEditDraft
    private var tasks: [DownloadStationTask] { draft.tasks }
    let fileRepository: (any MobileFileBrowsing)?
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var choosingFolder = false
    @State private var entryID: UUID?
    private var canSave: Bool {
        draft.activation == model.editActivation && !tasks.isEmpty && tasks.allSatisfy(model.canEditDownloadTask)
            && DownloadTaskDestinationChange.validDestination(destination) && tasks.contains { $0.destination != destination }
    }
    var body: some View {
        NavigationStack {
            Group {
                if let entryID {
                    MobileDownloadEditResultView(model: model, id: entryID)
                } else {
                    Form {
                        if let key = model.editErrorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                        Section {
                            Button { choosingFolder = true } label: {
                                LabeledContent(L10n.string("download.edit.destination"),
                                    value: destination.isEmpty ? L10n.string("mobile.files.choose-folder") : destination)
                            }
                            .disabled(fileRepository == nil || draft.activation != model.editActivation)
                            .frame(minHeight: MobileMetrics.minimumTouchTarget)
                            .accessibilityIdentifier("downloads.edit.destination")
                        }
                        Section(L10n.string("download.edit.tasks", tasks.count)) {
                            ForEach(tasks) { task in
                                VStack(alignment: .leading) {
                                    Text(task.title)
                                    if let path = task.destination { Text(path).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("downloads.edit.form")
                }
            }
            .navigationTitle(L10n.string("download.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.accessibilityIdentifier("downloads.edit.close")
                }
                if entryID == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("ui.991bb7cfe5a81550")) {
                            entryID = model.startDownloadEdit(tasks, destination: destination, activation: draft.activation)
                        }
                        .disabled(!canSave).keyboardShortcut("s", modifiers: .command)
                        .accessibilityIdentifier("downloads.edit.save")
                    }
                }
            }
            .sheet(isPresented: $choosingFolder) {
                if let fileRepository {
                    MobileFileFolderPicker(repository: fileRepository) { path in
                        guard draft.activation == model.editActivation, path.hasPrefix("/"), path.count > 1 else { return }
                        destination = String(path.dropFirst())
                    }
                }
            }
            .onChange(of: model.editActivation) { _, _ in dismiss() }
        }
    }
}

struct MobileDownloadEditResultView: View {
    @Bindable var model: MobileDownloadsModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    private var entry: MobileDownloadEditStore.Entry? { model.editEntries.first { $0.id == id } }
    var body: some View {
        List {
            if model.editRecovery.failed {
                Text(L10n.string("download.edit.storage-error")).foregroundStyle(.orange)
            } else if let entry {
                if let key = model.editErrorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                if model.editRecovery.isExecuting(id) { ProgressView(L10n.string("download.edit.saving")) }
                Section {
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(item, index: index))
                            Text(item.change.desired).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.string(status(item))).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: MobileMetrics.minimumTouchTarget, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("downloads.edit-result.\(item.taskID).\(item.phase.rawValue)")
                    }
                } footer: {
                    if entry.hasSubmitted && !model.editRecovery.isExecuting(id) { Text(L10n.string("download.edit.pending-help")) }
                }
                Section {
                    if entry.hasSubmitted {
                        Button(L10n.string("mobile.downloads.batch.refresh")) { model.runDownloadEdit(id, continuePlanned: false) }
                            .disabled(model.isEditingDownloadTask || model.isControllingDownloadTask)
                            .accessibilityIdentifier("downloads.edit.refresh")
                    } else if entry.hasPlanned {
                        Button(L10n.string("mobile.downloads.batch.continue")) { model.runDownloadEdit(id, continuePlanned: true) }
                            .disabled(model.isEditingDownloadTask || model.isControllingDownloadTask)
                            .accessibilityIdentifier("downloads.edit.continue")
                    }
                    if entry.hasPlanned {
                        Button(L10n.string("mobile.downloads.batch.cancel-remaining")) { model.cancelRemainingDownloadEdits(id) }
                            .accessibilityIdentifier("downloads.edit.cancel")
                    }
                    if !entry.hasUnfinished {
                        Button(L10n.string("mobile.downloads.batch.remove-record")) {
                            model.removeDownloadEditRecord(id); if self.entry == nil { dismiss() }
                        }.disabled(model.editRecovery.isExecuting(id)).accessibilityIdentifier("downloads.edit.remove-record")
                    }
                }
            }
        }
        .accessibilityIdentifier("downloads.edit.results")
        .navigationTitle(L10n.string("download.edit.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func title(_ item: MobileDownloadEditStore.Item, index: Int) -> String {
        if let task = model.downloadTask(id: item.taskID), item.change.matchesIdentity(task) { return task.title }
        return L10n.string("mobile.downloads.batch.task-number", index + 1)
    }
    private func status(_ item: MobileDownloadEditStore.Item) -> String {
        switch item.phase {
        case .planned: "mobile.downloads.batch.planned"
        case .submitted: model.editRecovery.isExecuting(id) ? "download.edit.saving" : "mobile.downloads.batch.pending"
        case .complete: "download.settings.saved"
        case .cancelled: "mobile.downloads.batch.cancelled"
        case .failed:
            switch item.failure {
            case .changed: "download.edit.changed"
            case .denied: "download.edit.denied"
            default: "download.edit.failed"
            }
        }
    }
}
