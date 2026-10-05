import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadRemovalDraft: Identifiable {
    let id = UUID()
    let activation: UUID
    let tasks: [DownloadStationTask]
    let forceComplete: Bool
}

struct MobileDownloadRemovalView: View {
    @Bindable var model: MobileDownloadsModel
    let draft: MobileDownloadRemovalDraft
    @Environment(\.dismiss) private var dismiss
    @State private var entryID: UUID?
    private var canRemove: Bool {
        draft.activation == model.editActivation && !draft.tasks.isEmpty && draft.tasks.allSatisfy(model.canDeleteDownloadTask)
    }
    var body: some View {
        NavigationStack {
            Group {
                if let entryID { MobileDownloadRemovalResultView(model: model, id: entryID, originalTasks: draft.tasks) }
                else {
                    Form {
                        if let key = model.removalErrorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                        Section {
                            Text(L10n.string(draft.forceComplete ? "download.removal.force-warning" : "download.removal.warning"))
                        }
                        Section(L10n.string("download.removal.selection", draft.tasks.count.formatted(.number.locale(L10n.locale)))) {
                            ForEach(draft.tasks) { task in
                                VStack(alignment: .leading) {
                                    Text(task.title)
                                    if let path = task.destination { Text(path).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Section {
                            Button(L10n.string(draft.forceComplete ? "download.removal.force-confirm" : "download.removal.confirm"), role: .destructive) {
                                entryID = model.startDownloadRemoval(draft.tasks, forceComplete: draft.forceComplete, activation: draft.activation)
                            }
                            .disabled(!canRemove).frame(minHeight: MobileMetrics.minimumTouchTarget)
                            .accessibilityIdentifier("downloads.removal.confirm")
                        }
                    }.accessibilityIdentifier("downloads.removal.confirmation")
                }
            }
            .navigationTitle(L10n.string(draft.forceComplete ? "download.removal.force-title" : "download.removal.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("files.common.close")) { dismiss() }
                    .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityIdentifier("downloads.removal.close")
            } }
            .onChange(of: model.editActivation) { _, _ in dismiss() }
        }
    }
}

struct MobileDownloadRemovalResultView: View {
    @Bindable var model: MobileDownloadsModel
    let id: UUID
    var originalTasks: [DownloadStationTask] = []
    @Environment(\.dismiss) private var dismiss
    private var entry: MobileDownloadRemovalStore.Entry? { model.removalEntries.first { $0.id == id } }
    var body: some View {
        List {
            if model.removalRecovery.failed {
                Text(L10n.string("download.edit.storage-error")).foregroundStyle(.orange)
            } else if let entry {
                if let key = model.removalErrorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                if model.removalRecovery.isExecuting(id) { ProgressView(L10n.string("download.removal.running")) }
                if entry.items.first?.removal.forceComplete == true {
                    Section { Text(L10n.string("download.removal.force-result")) }
                }
                Section {
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(item, index: index))
                            Text(L10n.string(status(item))).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: MobileMetrics.minimumTouchTarget, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("downloads.removal-result.\(item.taskID).\(item.phase.rawValue)")
                    }
                } footer: {
                    if entry.hasSubmitted && !model.removalRecovery.isExecuting(id) { Text(L10n.string("download.removal.pending-help")) }
                }
                Section {
                    if entry.hasSubmitted {
                        Button(L10n.string("mobile.downloads.batch.refresh")) { model.runDownloadRemoval(id, continuePlanned: false) }
                            .disabled(model.isDeletingDownloadTask || model.isControllingDownloadTask)
                            .accessibilityIdentifier("downloads.removal.refresh")
                    } else if entry.hasPlanned {
                        Button(L10n.string("mobile.downloads.batch.continue")) { model.runDownloadRemoval(id, continuePlanned: true) }
                            .disabled(model.isDeletingDownloadTask || model.isControllingDownloadTask)
                            .accessibilityIdentifier("downloads.removal.continue")
                    }
                    if entry.hasPlanned {
                        Button(L10n.string("mobile.downloads.batch.cancel-remaining")) { model.cancelRemainingDownloadRemovals(id) }
                            .accessibilityIdentifier("downloads.removal.cancel")
                    }
                    if !entry.hasUnfinished {
                        Button(L10n.string("mobile.downloads.batch.remove-record")) {
                            model.removeDownloadRemovalRecord(id); if self.entry == nil { dismiss() }
                        }.disabled(model.removalRecovery.isExecuting(id)).accessibilityIdentifier("downloads.removal.remove-record")
                    }
                }
            }
        }
        .accessibilityIdentifier("downloads.removal.results")
        .navigationTitle(L10n.string("download.removal.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func title(_ item: MobileDownloadRemovalStore.Item, index: Int) -> String {
        // 当次确认页保留原名称，关闭后仅从当前目录读取，名称不进入恢复文件。
        if let task = originalTasks.first(where: { item.removal.matches($0) }) ?? model.downloadTask(id: item.taskID), item.removal.matches(task) { return task.title }
        return L10n.string("mobile.downloads.batch.task-number", index + 1)
    }
    private func status(_ item: MobileDownloadRemovalStore.Item) -> String {
        switch item.phase {
        case .planned: "mobile.downloads.batch.planned"
        case .submitted: model.removalRecovery.isExecuting(id) ? "download.removal.running" : "download.removal.pending"
        case .complete: "download.removal.removed"
        case .cancelled: "mobile.downloads.batch.cancelled"
        case .failed:
            switch item.failure {
            case .changed: "download.removal.changed"
            case .denied: "download.removal.denied"
            default: "download.removal.failed"
            }
        }
    }
}
