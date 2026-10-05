import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation

extension MobileDownloadsModel {
    var controlContext: String? { activeProfile.map { MobileWorkspaceIdentity($0).storageIdentifier } }
    var controlEntries: [MobileDownloadControlStore.Entry] {
        controlRecovery.entries.filter { $0.context == controlContext }.reversed()
    }
    func controlProtects(_ id: String) -> Bool {
        guard let context = controlContext else { return true }
        return controlRecovery.protects(id, context: context)
    }
    func canStartDownloadControl(_ task: DownloadStationTask) -> Bool {
        !isControllingDownloadTask && !isDeletingDownloadTask && !controlProtects(task.id)
            && !isEditingDownloadTask && !editProtects(task.id)
            && activeProfile != nil && (serviceRepository != nil || downloadStationControlOverride != nil)
    }

    @discardableResult
    func startDownloadControlBatch(_ tasks: [DownloadStationTask], action: DownloadStationTaskAction) -> UUID? {
        guard let action = MobileDownloadControlStore.Action(rawValue: action.rawValue),
              let context = controlContext, !tasks.isEmpty, Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ action == .pause ? canPauseDownloadTask($0) : canResumeDownloadTask($0) }) else { return nil }
        let entry = MobileDownloadControlStore.Entry(id: UUID(), context: context, createdAt: Date(), action: action,
            items: tasks.map(MobileDownloadControlStore.Item.init))
        do {
            try controlRecovery.reserve(entry)
            runDownloadControlBatch(entry.id, continuePlanned: true, originals: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) }))
            return entry.id
        } catch { controlErrorKey = "mobile.downloads.batch.storage-error"; return nil }
    }

    func recoverPendingDownloadControls() {
        guard !isControllingDownloadTask, let entry = controlEntries.first(where: \.hasSubmitted) else { return }
        runDownloadControlBatch(entry.id, continuePlanned: false)
    }

    func runDownloadControlBatch(_ id: UUID, continuePlanned: Bool, originals: [String: DownloadStationTask] = [:]) {
        guard !isControllingDownloadTask, !isDeletingDownloadTask, let context = controlContext,
              !isEditingDownloadTask,
              let entry = controlRecovery.entry(id, context: context), entry.hasUnfinished,
              serviceRepository != nil || downloadStationControlOverride != nil || downloadControlReadOverride != nil,
              controlRecovery.begin(id, context: context) else { return }
        let repository = serviceRepository
        let writeOverride = downloadStationControlOverride
        let readOverride = downloadControlReadOverride
        // 已提交项优先只读，完成查询不能顺带发送剩余项目。
        let allowsNew = continuePlanned && !entry.hasSubmitted
        controlBatchID = id; controlCancelRequestedID = nil; controlErrorKey = nil
        downloadControlGeneration &+= 1
        downloadControlTaskID = entry.items.first { $0.phase == .submitted || $0.phase == .planned }?.taskID
        downloadControlAction = entry.action.taskAction
        if let taskID = downloadControlTaskID {
            downloadControlFeedback = .init(taskID: taskID, action: entry.action.taskAction, kind: .inProgress)
        }
        downloadControlTask = Task { [weak self] in
            guard let self else { return }
            let recovery = self.controlRecovery
            @MainActor func isCurrent() -> Bool {
                self.controlContext == context && self.controlBatchID == id
                    && repository.map(ObjectIdentifier.init) == self.serviceRepository.map(ObjectIdentifier.init)
            }
            defer {
                recovery.end(id)
                if isCurrent() {
                    self.downloadControlGeneration &+= 1
                    self.controlBatchID = nil; self.controlCancelRequestedID = nil
                    self.downloadControlTaskID = nil; self.downloadControlAction = nil; self.downloadControlTask = nil
                }
            }
            for item in entry.items where item.phase == .submitted || (allowsNew && item.phase == .planned) {
                guard isCurrent(), !Task.isCancelled, self.controlCancelRequestedID != id, !recovery.failed else { return }
                self.downloadControlTaskID = item.taskID
                self.downloadControlFeedback = .init(taskID: item.taskID, action: entry.action.taskAction, kind: .inProgress)
                do {
                    if item.phase == .submitted {
                        let current: DownloadStationTask?
                        if let readOverride { current = try await readOverride(item.taskID) }
                        else if let repository { current = try await repository.loadDownloadTaskControlState(id: item.taskID) }
                        else { return }
                        // 完整读取发现任务已移除或编号对应内容变化，不能再针对新任务重放旧动作。
                        if let current, item.matches(current) {
                            if Self.controlIsComplete(action: entry.action, status: current.status) {
                                try recovery.progress(item.id, in: id, context: context, phase: .complete)
                                await repository?.acknowledgeDownloadTaskControlResult(id: item.taskID, action: entry.action.taskAction)
                                if isCurrent() { self.applyDownloadControlTask(current, action: entry.action.taskAction, kind: .success) }
                            } else if isCurrent() {
                                self.downloadControlFeedback = .init(taskID: item.taskID, action: entry.action.taskAction, kind: .needsReview)
                            }
                        } else {
                            try recovery.progress(item.id, in: id, context: context, phase: .failed, failure: .changed)
                            await repository?.acknowledgeDownloadTaskControlResult(id: item.taskID, action: entry.action.taskAction)
                            if isCurrent() { self.downloadControlFeedback = .init(taskID: item.taskID, action: entry.action.taskAction, kind: .conflict) }
                        }
                    } else {
                        let original = originals[item.taskID] ?? self.downloadTask(id: item.taskID)
                        guard let original, item.matches(original), Self.normalizedDownloadTaskStatus(original.status)
                            == Self.normalizedDownloadTaskStatus(item.originalStatus) else {
                            try recovery.progress(item.id, in: id, context: context, phase: .failed, failure: .changed)
                            if isCurrent() { self.downloadControlFeedback = .init(taskID: item.taskID, action: entry.action.taskAction, kind: .conflict) }
                            continue
                        }
                        let request = DownloadTaskControlRequest(task: original, action: entry.action.taskAction)
                        let save: @Sendable (DownloadStationTask) async throws -> Void = { [weak self] baseline in
                            try await MainActor.run {
                                guard let self, self.controlContext == context, self.controlBatchID == id,
                                      repository.map(ObjectIdentifier.init) == self.serviceRepository.map(ObjectIdentifier.init),
                                      !Task.isCancelled, self.controlCancelRequestedID != id else { throw CancellationError() }
                                guard item.matches(baseline) else {
                                    throw AppError(category: .conflict, isRetryable: false,
                                        safeUserMessage: L10n.string("mobile.downloads.control.conflict.message"))
                                }
                                try recovery.progress(item.id, in: id, context: context, phase: .submitted)
                            }
                        }
                        let outcome: DownloadTaskControlOutcome
                        if let writeOverride { try await save(original); outcome = try await writeOverride(request) }
                        else if let repository { outcome = try await repository.controlDownloadTaskResult(request, willSubmit: save) }
                        else { return }
                        if outcome.result.submitted,
                           recovery.entry(id, context: context)?.items.first(where: { $0.id == item.id })?.phase == .planned {
                            try recovery.progress(item.id, in: id, context: context, phase: .submitted)
                        }
                        // 取消或切换账号不会抹去已返回的实际结果；仅页面更新受当前上下文限制。
                        var kind = Self.feedbackKind(for: outcome.result)
                        switch outcome.result.status {
                        case .confirmedSuccess:
                            if let task = outcome.task, outcome.taskID == item.taskID, item.matches(task),
                               Self.controlIsComplete(action: entry.action, status: task.status) {
                                try recovery.progress(item.id, in: id, context: context, phase: .complete)
                                if isCurrent() { self.applyDownloadControlTask(task, action: entry.action.taskAction, kind: .success) }
                            } else { kind = .needsReview }
                        case .cancelledBeforeSubmission:
                            try recovery.progress(item.id, in: id, context: context, phase: .cancelled)
                        case .permissionDenied, .unsupported, .confirmedFailure:
                            let failure: MobileDownloadControlStore.Failure = outcome.result.status == .permissionDenied ? .denied
                                : (outcome.result.errorCategory == .conflict ? .changed : .unavailable)
                            try recovery.progress(item.id, in: id, context: context, phase: .failed, failure: failure)
                        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
                            break
                        }
                        if isCurrent() { self.downloadControlFeedback = .init(taskID: item.taskID, action: entry.action.taskAction, kind: kind) }
                    }
                } catch {
                    let phase = recovery.entry(id, context: context)?.items.first { $0.id == item.id }?.phase
                    // 发送前失败可以结束；发送后的传输错误保留原记录，只能读取结果。
                    if phase == .planned, !recovery.failed {
                        do {
                            if error is CancellationError {
                                try recovery.progress(item.id, in: id, context: context, phase: .cancelled)
                            } else {
                                let category = (error as? AppError)?.category
                                try recovery.progress(item.id, in: id, context: context, phase: .failed,
                                    failure: category == .conflict ? .changed : (category == .permissionDenied ? .denied : .unavailable))
                            }
                        } catch { if isCurrent() { self.controlErrorKey = "mobile.downloads.batch.storage-error" } }
                    }
                    if isCurrent() {
                        if recovery.failed { self.controlErrorKey = "mobile.downloads.batch.storage-error" }
                        else if phase == .submitted, (error as? AppError)?.category == .permissionDenied {
                            self.controlErrorKey = "mobile.downloads.batch.denied"
                        }
                        let kind: MobileDownloadControlFeedbackKind = phase == .submitted ? .needsReview
                            : (error is CancellationError ? .cancelled : .failure)
                        self.downloadControlFeedback = .init(taskID: item.taskID, action: entry.action.taskAction, kind: kind)
                    }
                }
                if isCurrent() { self.downloadControlGeneration &+= 1 }
                guard recovery.entry(id, context: context)?.hasSubmitted == false else { return }
            }
        }
    }

    func cancelRemainingDownloadControls(_ id: UUID) {
        guard let context = controlContext, controlRecovery.entry(id, context: context) != nil else { return }
        if controlBatchID == id { controlCancelRequestedID = id }
        do { try controlRecovery.cancelRemaining(id, context: context); controlErrorKey = nil }
        catch { controlErrorKey = "mobile.downloads.batch.storage-error" }
    }
    func removeDownloadControlRecord(_ id: UUID) {
        guard let context = controlContext else { return }
        do { try controlRecovery.remove(id, context: context); controlErrorKey = nil }
        catch { controlErrorKey = "mobile.downloads.batch.storage-error" }
    }
    private func applyDownloadControlTask(_ task: DownloadStationTask, action: DownloadStationTaskAction,
                                          kind: MobileDownloadControlFeedbackKind) {
        downloadControlGeneration &+= 1
        replaceDownloadTask(task)
        downloadControlFeedback = .init(taskID: task.id, action: action, kind: kind)
    }
    static func controlIsComplete(action: MobileDownloadControlStore.Action, status: String) -> Bool {
        action == .pause ? canResumeDownloadTaskStatus(status) : canPauseDownloadTaskStatus(status)
    }
}
