import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadSelectionSheet: View {
    @Bindable var model: MobileDownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var batchID: UUID?
    private var candidates: [DownloadStationTask] {
        model.visibleTasks.filter { model.canPauseDownloadTask($0) || model.canResumeDownloadTask($0) }
    }
    private var pauseSelection: [DownloadStationTask] { candidates.filter { selected.contains($0.id) && model.canPauseDownloadTask($0) } }
    private var resumeSelection: [DownloadStationTask] { candidates.filter { selected.contains($0.id) && model.canResumeDownloadTask($0) } }

    var body: some View {
        NavigationStack {
            List {
                if let key = model.controlErrorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                if candidates.isEmpty {
                    Text(L10n.string("mobile.downloads.batch.select-empty"))
                } else {
                    Button(L10n.string("mobile.downloads.batch.select-all")) { selected = Set(candidates.map(\.id)) }
                        .keyboardShortcut("a", modifiers: .command)
                        .accessibilityIdentifier("downloads.select-all")
                    ForEach(candidates) { task in
                        Button {
                            if !selected.insert(task.id).inserted { selected.remove(task.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(task.id) ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(task.title).foregroundStyle(.primary)
                                    Text(MobileDownloadPresentation.status(task.status)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: MobileMetrics.minimumTouchTarget)
                        .accessibilityAddTraits(selected.contains(task.id) ? .isSelected : [])
                        .accessibilityIdentifier("downloads.selection.\(task.id)")
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.downloads.batch.select"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }
                        .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                        .accessibilityIdentifier("downloads.selection.close")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(L10n.string("mobile.downloads.batch.pause-count", pauseSelection.count)) { start(pauseSelection, action: .pause) }
                        .disabled(pauseSelection.isEmpty).accessibilityIdentifier("downloads.batch.pause")
                        .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                    Spacer()
                    Button(L10n.string("mobile.downloads.batch.resume-count", resumeSelection.count)) { start(resumeSelection, action: .resume) }
                        .disabled(resumeSelection.isEmpty).accessibilityIdentifier("downloads.batch.resume")
                        .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                }
            }
            .navigationDestination(item: $batchID) { id in MobileDownloadControlResultView(model: model, id: id) }
            .onChange(of: candidates.map(\.id)) { _, ids in selected.formIntersection(ids) }
        }
    }
    private func start(_ tasks: [DownloadStationTask], action: DownloadStationTaskAction) {
        if let id = model.startDownloadControlBatch(tasks, action: action) { batchID = id; selected = [] }
    }
}

struct MobileDownloadControlRecordsView: View {
    @Bindable var model: MobileDownloadsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if model.controlRecovery.failed {
                    ContentUnavailableView(L10n.string("mobile.downloads.batch.records"), systemImage: "exclamationmark.circle",
                        description: Text(L10n.string("mobile.downloads.batch.storage-error"))).fillsAvailableContentArea()
                } else if model.controlEntries.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.downloads.batch.records-empty"), systemImage: "clock",
                        description: Text(L10n.string("mobile.downloads.batch.records-empty-help"))).fillsAvailableContentArea()
                } else {
                    List(model.controlEntries) { entry in
                        NavigationLink {
                            MobileDownloadControlResultView(model: model, id: entry.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(L10n.string(entry.action == .pause ? "mobile.downloads.batch.pause-count" : "mobile.downloads.batch.resume-count", entry.items.count))
                                Text(entry.createdAt.formatted(.dateTime.locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
                                Text(L10n.string("mobile.downloads.batch.progress", entry.items.filter { $0.phase == .complete }.count, entry.items.count))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("downloads.record.\(entry.id)")
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.downloads.batch.records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("files.common.close")) { dismiss() }
                    .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityIdentifier("downloads.records.close")
            } }
        }
    }
}

struct MobileDownloadControlResultView: View {
    @Bindable var model: MobileDownloadsModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    private var entry: MobileDownloadControlStore.Entry? { model.controlEntries.first { $0.id == id } }
    var body: some View {
        List {
            if model.controlRecovery.failed {
                Text(L10n.string("mobile.downloads.batch.storage-error")).foregroundStyle(.orange)
            } else if let entry {
                if let key = model.controlErrorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                if model.controlRecovery.isExecuting(id) { ProgressView(L10n.string("mobile.downloads.batch.running")) }
                Section {
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(itemTitle(item, index: index)).font(.body)
                            Text(L10n.string(statusKey(item))).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: MobileMetrics.minimumTouchTarget, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("downloads.result.\(item.taskID).\(item.phase.rawValue)")
                    }
                } footer: {
                    if entry.hasSubmitted { Text(L10n.string("mobile.downloads.batch.pending-help")) }
                }
                Section {
                    if entry.hasSubmitted {
                        Button(L10n.string("mobile.downloads.batch.refresh")) { model.runDownloadControlBatch(id, continuePlanned: false) }
                            .disabled(model.isControllingDownloadTask).accessibilityIdentifier("downloads.batch.refresh")
                    } else if entry.hasPlanned {
                        Button(L10n.string("mobile.downloads.batch.continue")) { model.runDownloadControlBatch(id, continuePlanned: true) }
                            .disabled(model.isControllingDownloadTask).accessibilityIdentifier("downloads.batch.continue")
                    }
                    if entry.hasPlanned {
                        Button(L10n.string("mobile.downloads.batch.cancel-remaining")) { model.cancelRemainingDownloadControls(id) }
                            .disabled(model.controlCancelRequestedID == id).accessibilityIdentifier("downloads.batch.cancel")
                    }
                    if !entry.hasUnfinished {
                        Button(L10n.string("mobile.downloads.batch.remove-record")) { model.removeDownloadControlRecord(id); if self.entry == nil { dismiss() } }
                            .disabled(model.controlRecovery.isExecuting(id)).accessibilityIdentifier("downloads.batch.remove-record")
                    }
                }
            }
        }
        .accessibilityIdentifier("downloads.batch.results")
        .navigationTitle(L10n.string("mobile.downloads.batch.records"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func itemTitle(_ item: MobileDownloadControlStore.Item, index: Int) -> String {
        if let task = model.downloadTask(id: item.taskID), item.matches(task) { return task.title }
        return L10n.string("mobile.downloads.batch.task-number", index + 1)
    }
    private func statusKey(_ item: MobileDownloadControlStore.Item) -> String {
        switch item.phase {
        case .planned: return "mobile.downloads.batch.planned"
        case .submitted: return "mobile.downloads.batch.pending"
        case .complete: return entry?.action == .pause ? "mobile.downloads.control.paused.title" : "mobile.downloads.control.resumed.title"
        case .cancelled: return "mobile.downloads.batch.cancelled"
        case .failed:
            switch item.failure {
            case .changed: return "mobile.downloads.batch.changed"
            case .denied: return "mobile.downloads.batch.denied"
            default: return "mobile.downloads.batch.failed"
            }
        }
    }
}
