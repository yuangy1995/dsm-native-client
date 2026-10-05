import DsmCore
import Foundation

extension MobileDownloadsModel {
    var removalEntries: [MobileDownloadRemovalStore.Entry] {
        removalRecovery.entries.filter { $0.context == controlContext }.reversed()
    }
    func removalProtects(_ id: String) -> Bool {
        guard let context = controlContext else { return true }
        return removalRecovery.protects(id, context: context)
    }
    func canDeleteDownloadTask(_ task: DownloadStationTask) -> Bool {
        guard let current = downloadTask(id: task.id), DownloadTaskRemoval(task: task, forceComplete: false).matches(current) else { return false }
        return activeProfile != nil && serviceRepository?.supportsDownloadTaskRemoval == true
            && !isDeletingDownloadTask && !isEditingDownloadTask && !isControllingDownloadTask
            && !removalProtects(task.id) && !editProtects(task.id) && !controlProtects(task.id)
    }
    @discardableResult
    func startDownloadRemoval(_ tasks: [DownloadStationTask], forceComplete: Bool, activation: UUID) -> UUID? {
        guard activation == editActivation, let context = controlContext, !tasks.isEmpty,
              Set(tasks.map(\.id)).count == tasks.count, tasks.allSatisfy(canDeleteDownloadTask) else { return nil }
        let items = tasks.map { MobileDownloadRemovalStore.Item(removal: .init(task: $0, forceComplete: forceComplete)) }
        guard items.allSatisfy({ $0.removal.isValid }) else { return nil }
        let entry = MobileDownloadRemovalStore.Entry(id: UUID(), context: context, createdAt: Date(), items: items)
        do { try removalRecovery.reserve(entry); runDownloadRemoval(entry.id, continuePlanned: true); return entry.id }
        catch { removalErrorKey = "download.edit.storage-error"; return nil }
    }
    func recoverPendingDownloadRemovals() {
        if let entry = removalEntries.first(where: \.hasSubmitted) { runDownloadRemoval(entry.id, continuePlanned: false) }
    }
    func runDownloadRemoval(_ id: UUID, continuePlanned: Bool) {
        guard !isDeletingDownloadTask, !isEditingDownloadTask, !isControllingDownloadTask,
              let repository = serviceRepository, let context = controlContext,
              let entry = removalRecovery.entry(id, context: context), entry.hasUnfinished,
              removalRecovery.begin(id, context: context) else { return }
        let token = editActivation, store = removalRecovery, allowNew = continuePlanned && !entry.hasSubmitted
        removalBatchID = id; removalErrorKey = nil; downloadDeleteGeneration &+= 1
        downloadDeleteTask = Task { [weak self] in
            defer {
                store.end(id)
                if let self, self.editActivation == token {
                    self.removalBatchID = nil; self.downloadDeleteTask = nil; self.downloadDeleteGeneration &+= 1
                }
            }
            for item in entry.items {
                guard let self, self.editActivation == token, !Task.isCancelled, !store.failed,
                      let current = store.entry(id, context: context)?.items.first(where: { $0.id == item.id }),
                      current.phase == .submitted || (allowNew && current.phase == .planned) else { continue }
                do {
                    let outcome: DownloadTaskRemovalOutcome
                    if current.phase == .submitted {
                        outcome = try await repository.reviewDownloadTaskRemoval(current.removal)
                    } else {
                        guard !self.controlProtects(item.taskID), !self.editProtects(item.taskID) else { break }
                        outcome = try await repository.removeDownloadTask(current.removal) { [weak self] in
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
                    case .removed:
                        try store.progress(item.id, in: id, context: context, phase: .complete)
                        if self.editActivation == token { self.removeDownloadTask(id: item.taskID) }
                    case .pending: break
                    case .changed: try store.progress(item.id, in: id, context: context, phase: .failed, failure: .changed)
                    case .denied: try store.progress(item.id, in: id, context: context, phase: .failed, failure: .denied)
                    case .rejected: try store.progress(item.id, in: id, context: context, phase: .failed, failure: .unavailable)
                    case .cancelledBeforeSubmission: try store.progress(item.id, in: id, context: context, phase: .cancelled)
                    }
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
                        self.removalErrorKey = store.failed ? "download.edit.storage-error" : "download.removal.read-error"
                    }
                    break
                }
            }
        }
    }
    func cancelRemainingDownloadRemovals(_ id: UUID) {
        guard let context = controlContext else { return }
        do { try removalRecovery.cancelRemaining(id, context: context) }
        catch { removalErrorKey = "download.edit.storage-error" }
    }
    func removeDownloadRemovalRecord(_ id: UUID) {
        guard let context = controlContext else { return }
        do { try removalRecovery.remove(id, context: context) }
        catch { removalErrorKey = "download.edit.storage-error" }
    }
}
