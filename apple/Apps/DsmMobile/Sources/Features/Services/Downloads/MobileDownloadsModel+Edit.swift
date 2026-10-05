import DsmCore
import Foundation

extension MobileDownloadsModel {
    var editEntries: [MobileDownloadEditStore.Entry] {
        editRecovery.entries.filter { $0.context == controlContext }.reversed()
    }
    var isEditingDownloadTask: Bool { editBatchID != nil || editEntries.contains { editRecovery.isExecuting($0.id) } }
    func editProtects(_ id: String) -> Bool {
        guard let context = controlContext else { return true }
        return editRecovery.protects(id, context: context)
    }
    func canEditDownloadTask(_ task: DownloadStationTask) -> Bool {
        guard let current = downloadTask(id: task.id), current.destination == task.destination,
              DownloadTaskDestinationChange(task: task, destination: "").matchesIdentity(current) else { return false }
        return activeProfile != nil && serviceRepository?.supportsDownloadDestinationEditing == true
            && !isEditingDownloadTask && !isControllingDownloadTask && !isDeletingDownloadTask
            && !editProtects(task.id) && !controlProtects(task.id)
            && DownloadTaskDestinationChange.validDestination(task.destination ?? "")
    }
    @discardableResult
    func startDownloadEdit(_ tasks: [DownloadStationTask], destination: String, activation: UUID) -> UUID? {
        guard activation == editActivation, let context = controlContext, !tasks.isEmpty,
              Set(tasks.map(\.id)).count == tasks.count, tasks.allSatisfy(canEditDownloadTask) else { return nil }
        let changes = tasks.filter { $0.destination != destination }.map { DownloadTaskDestinationChange(task: $0, destination: destination) }
        guard !changes.isEmpty, changes.allSatisfy(\.isValid) else { return nil }
        let entry = MobileDownloadEditStore.Entry(id: UUID(), context: context, createdAt: Date(),
            items: changes.map(MobileDownloadEditStore.Item.init))
        do { try editRecovery.reserve(entry); runDownloadEdit(entry.id, continuePlanned: true); return entry.id }
        catch { editErrorKey = "download.edit.storage-error"; return nil }
    }
    func recoverPendingDownloadEdits() {
        if let entry = editEntries.first(where: \.hasSubmitted) { runDownloadEdit(entry.id, continuePlanned: false) }
    }
    func runDownloadEdit(_ id: UUID, continuePlanned: Bool) {
        guard !isEditingDownloadTask, !isControllingDownloadTask, !isDeletingDownloadTask,
              let repository = serviceRepository, let context = controlContext,
              let entry = editRecovery.entry(id, context: context), entry.hasUnfinished,
              editRecovery.begin(id, context: context) else { return }
        let token = editActivation, store = editRecovery, allowNew = continuePlanned && !entry.hasSubmitted
        editBatchID = id; editErrorKey = nil; downloadEditGeneration &+= 1
        downloadEditTask = Task { [weak self] in
            defer {
                store.end(id)
                if let self, self.editActivation == token {
                    self.editBatchID = nil; self.downloadEditTask = nil; self.downloadEditGeneration &+= 1
                }
            }
            for item in entry.items {
                guard let self, self.editActivation == token, !Task.isCancelled, !store.failed,
                      let current = store.entry(id, context: context)?.items.first(where: { $0.id == item.id }),
                      current.phase == .submitted || (allowNew && current.phase == .planned) else { continue }
                do {
                    let outcome: DownloadTaskDestinationOutcome
                    if current.phase == .submitted {
                        outcome = try await repository.reviewDownloadTaskDestination(current.change)
                    } else {
                        guard !self.controlProtects(item.taskID) else { break }
                        outcome = try await repository.changeDownloadTaskDestination(current.change) { [weak self] in
                            try await MainActor.run {
                                guard let self, self.editActivation == token, !Task.isCancelled,
                                      store.entry(id, context: context)?.items.first(where: { $0.id == item.id })?.phase == .planned else {
                                    throw CancellationError()
                                }
                                try store.progress(item.id, in: id, context: context, phase: .submitted)
                            }
                        }
                    }
                    switch outcome {
                    case .complete(let task):
                        try store.progress(item.id, in: id, context: context, phase: .complete)
                        if self.editActivation == token { self.replaceDownloadTask(task) }
                    case .pending: break
                    case .changed: try store.progress(item.id, in: id, context: context, phase: .failed, failure: .changed)
                    case .denied: try store.progress(item.id, in: id, context: context, phase: .failed, failure: .denied)
                    case .rejected: try store.progress(item.id, in: id, context: context, phase: .failed, failure: .unavailable)
                    case .cancelledBeforeSubmission: try store.progress(item.id, in: id, context: context, phase: .cancelled)
                    }
                    // 明确的逐项拒绝不隐藏其他项目；未知状态停止后续提交。
                    if case .pending = outcome { break }
                } catch {
                    if store.entry(id, context: context)?.items.first(where: { $0.id == item.id })?.phase == .planned {
                        if error is CancellationError { try? store.progress(item.id, in: id, context: context, phase: .cancelled) }
                        else {
                            let category = (error as? AppError)?.category
                            try? store.progress(item.id, in: id, context: context, phase: .failed,
                                failure: category == .permissionDenied ? .denied : category == .conflict ? .changed : .unavailable)
                        }
                    }
                    if self.editActivation == token, !(error is CancellationError) {
                        self.editErrorKey = store.failed ? "download.edit.storage-error" : "download.edit.read-error"
                    }
                    break
                }
            }
        }
    }
    func cancelRemainingDownloadEdits(_ id: UUID) {
        guard let context = controlContext else { return }
        do { try editRecovery.cancelRemaining(id, context: context) }
        catch { editErrorKey = "download.edit.storage-error" }
    }
    func removeDownloadEditRecord(_ id: UUID) {
        guard let context = controlContext else { return }
        do { try editRecovery.remove(id, context: context) }
        catch { editErrorKey = "download.edit.storage-error" }
    }
}
