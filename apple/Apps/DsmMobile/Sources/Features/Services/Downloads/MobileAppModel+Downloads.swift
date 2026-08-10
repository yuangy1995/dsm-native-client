import DsmCore
import DsmLocalization
import Foundation

enum MobileDownloadControlFeedbackKind: Equatable {
    case inProgress
    case success
    case needsReview
    case cancelled
    case conflict
    case permission
    case unsupported
    case failure
}

struct MobileDownloadControlFeedback: Equatable {
    let taskID: String
    let action: DownloadStationTaskAction
    let kind: MobileDownloadControlFeedbackKind
}

enum MobileDownloadCreateFeedbackKind: Equatable {
    case inProgress
    case success
    case needsReview
    case cancelled
    case conflict
    case permission
    case unsupported
    case failure
}

struct MobileDownloadCreateFeedback: Equatable {
    let uri: String
    let kind: MobileDownloadCreateFeedbackKind
}

enum MobileDownloadDeleteFeedbackKind: Equatable {
    case inProgress
    case success
    case needsReview
    case cancelled
    case conflict
    case permission
    case unsupported
    case failure
}

struct MobileDownloadDeleteFeedback: Equatable {
    let taskID: String
    let kind: MobileDownloadDeleteFeedbackKind
}

extension MobileAppModel {
    var downloadPageState: MobilePageState {
        if isLoading, downloadSnapshot == nil {
            return .loading
        }
        guard let downloadSnapshot else {
            return message == nil ? .loading : .error
        }
        return downloadSnapshot.tasks.isEmpty ? .empty : .content
    }

    var isControllingDownloadTask: Bool {
        downloadControlTaskID != nil
    }

    var isCreatingDownloadTask: Bool {
        downloadCreateTask != nil
    }

    var isDeletingDownloadTask: Bool {
        downloadDeleteTaskID != nil
    }

    var canCreateDownloadTask: Bool {
        !isCreatingDownloadTask &&
        activeProfile != nil &&
        (
            serviceRepository != nil ||
            downloadStationCreateOverride != nil ||
            downloadStationCreateFileOverride != nil
        )
    }

    var canSearchDownloadBT: Bool {
        activeProfile != nil &&
        downloadSnapshot?.hasBTSearch == true &&
        serviceRepository != nil
    }

    var downloadCreateDefaultDestination: String? {
        let destination = downloadSnapshot?.defaultDestination?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return destination?.isEmpty == false ? destination : nil
    }

    func reloadDownloads() {
        selectModule(.downloads)
    }

    func deactivateDownloads() {
        downloadControlGeneration &+= 1
        downloadControlTask?.cancel()
        downloadControlTask = nil
        downloadControlTaskID = nil
        downloadControlAction = nil
        downloadControlFeedback = nil
        downloadCreateGeneration &+= 1
        downloadCreateTask?.cancel()
        downloadCreateTask = nil
        downloadCreateFeedback = nil
        downloadDeleteGeneration &+= 1
        downloadDeleteTask?.cancel()
        downloadDeleteTask = nil
        downloadDeleteTaskID = nil
        downloadDeleteFeedback = nil
    }

    func downloadTask(id: String) -> DownloadStationTask? {
        downloadSnapshot?.tasks.first { $0.id == id }
    }

    func canPauseDownloadTask(_ task: DownloadStationTask) -> Bool {
        !isControllingDownloadTask && Self.canPauseDownloadTaskStatus(task.status)
    }

    func canResumeDownloadTask(_ task: DownloadStationTask) -> Bool {
        !isControllingDownloadTask && Self.canResumeDownloadTaskStatus(task.status)
    }

    func canDeleteDownloadTask(_ task: DownloadStationTask) -> Bool {
        !isDeletingDownloadTask &&
        !isControllingDownloadTask &&
        downloadTask(id: task.id) != nil &&
        activeProfile != nil &&
        (serviceRepository != nil || downloadStationDeleteOverride != nil)
    }

    func feedbackForDownloadTask(_ task: DownloadStationTask) -> MobileDownloadControlFeedback? {
        guard downloadControlFeedback?.taskID == task.id else { return nil }
        return downloadControlFeedback
    }

    func deleteFeedbackForDownloadTask(_ task: DownloadStationTask) -> MobileDownloadDeleteFeedback? {
        guard downloadDeleteFeedback?.taskID == task.id else { return nil }
        return downloadDeleteFeedback
    }

    func controlDownloadTask(_ task: DownloadStationTask, action: DownloadStationTaskAction) {
        guard !isControllingDownloadTask else { return }
        switch action {
        case .pause where canPauseDownloadTask(task):
            break
        case .resume where canResumeDownloadTask(task):
            break
        default:
            downloadControlFeedback = MobileDownloadControlFeedback(
                taskID: task.id,
                action: action,
                kind: .unsupported
            )
            return
        }
        guard activeProfile != nil,
              serviceRepository != nil || downloadStationControlOverride != nil else {
            downloadControlFeedback = MobileDownloadControlFeedback(
                taskID: task.id,
                action: action,
                kind: .unsupported
            )
            return
        }

        downloadControlGeneration &+= 1
        let generation = downloadControlGeneration
        let request = DownloadTaskControlRequest(task: task, action: action)
        let repository = serviceRepository
        let override = downloadStationControlOverride
        downloadControlTaskID = task.id
        downloadControlAction = action
        downloadControlFeedback = MobileDownloadControlFeedback(
            taskID: task.id,
            action: action,
            kind: .inProgress
        )
        downloadControlTask = Task { [weak self] in
            do {
                let outcome: DownloadTaskControlOutcome
                if let override {
                    outcome = try await override(request)
                } else if let repository {
                    outcome = try await repository.controlDownloadTaskResult(request)
                } else {
                    return
                }
                try Task.checkCancellation()
                await MainActor.run {
                    self?.finishDownloadControl(
                        outcome,
                        action: action,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishDownloadControlCancellation(
                        taskID: task.id,
                        action: action,
                        generation: generation
                    )
                }
            } catch {
                await MainActor.run {
                    self?.finishDownloadControlFailure(
                        taskID: task.id,
                        action: action,
                        generation: generation
                    )
                }
            }
        }
    }

    func createDownloadTask(uri rawURI: String) {
        let uri = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isCreatingDownloadTask else { return }
        guard !uri.isEmpty,
              activeProfile != nil,
              serviceRepository != nil || downloadStationCreateOverride != nil else {
            downloadCreateFeedback = MobileDownloadCreateFeedback(
                uri: uri,
                kind: .unsupported
            )
            return
        }

        downloadCreateGeneration &+= 1
        let generation = downloadCreateGeneration
        let request = DownloadTaskCreateRequest(
            uri: uri,
            destination: downloadCreateDefaultDestination
        )
        let repository = serviceRepository
        let override = downloadStationCreateOverride
        downloadCreateFeedback = MobileDownloadCreateFeedback(uri: uri, kind: .inProgress)
        downloadCreateTask = Task { [weak self] in
            do {
                let outcome: DownloadTaskCreateOutcome
                if let override {
                    outcome = try await override(request)
                } else if let repository {
                    outcome = try await repository.createDownloadTaskResult(request)
                } else {
                    return
                }
                try Task.checkCancellation()
                await MainActor.run {
                    self?.finishDownloadCreate(
                        outcome,
                        uri: uri,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishDownloadCreateCancellation(
                        uri: uri,
                        generation: generation
                    )
                }
            } catch {
                await MainActor.run {
                    self?.finishDownloadCreateFailure(
                        uri: uri,
                        generation: generation
                    )
                }
            }
        }
    }

    func createDownloadTask(fileURL: URL) {
        let displayName = fileURL.lastPathComponent.isEmpty
            ? fileURL.path
            : fileURL.lastPathComponent
        guard !isCreatingDownloadTask else { return }
        guard activeProfile != nil,
              serviceRepository != nil || downloadStationCreateFileOverride != nil else {
            downloadCreateFeedback = MobileDownloadCreateFeedback(
                uri: displayName,
                kind: .unsupported
            )
            return
        }

        downloadCreateGeneration &+= 1
        let generation = downloadCreateGeneration
        let request = DownloadTaskFileCreateRequest(
            fileURL: fileURL,
            destination: downloadCreateDefaultDestination
        )
        let repository = serviceRepository
        let override = downloadStationCreateFileOverride
        downloadCreateFeedback = MobileDownloadCreateFeedback(uri: displayName, kind: .inProgress)
        downloadCreateTask = Task { [weak self] in
            do {
                let outcome: DownloadTaskCreateOutcome
                if let override {
                    outcome = try await override(request)
                } else if let repository {
                    outcome = try await repository.createDownloadTaskFileResult(request)
                } else {
                    return
                }
                try Task.checkCancellation()
                await MainActor.run {
                    self?.finishDownloadCreate(
                        outcome,
                        uri: displayName,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishDownloadCreateCancellation(
                        uri: displayName,
                        generation: generation
                    )
                }
            } catch {
                await MainActor.run {
                    self?.finishDownloadCreateFailure(
                        uri: displayName,
                        generation: generation
                    )
                }
            }
        }
    }

    func deleteDownloadTask(_ task: DownloadStationTask) {
        guard !isDeletingDownloadTask else { return }
        guard canDeleteDownloadTask(task) else {
            downloadDeleteFeedback = MobileDownloadDeleteFeedback(
                taskID: task.id,
                kind: .unsupported
            )
            return
        }

        downloadDeleteGeneration &+= 1
        let generation = downloadDeleteGeneration
        let repository = serviceRepository
        let override = downloadStationDeleteOverride
        downloadDeleteTaskID = task.id
        downloadDeleteFeedback = MobileDownloadDeleteFeedback(
            taskID: task.id,
            kind: .inProgress
        )
        downloadDeleteTask = Task { [weak self] in
            do {
                let result: MutationResult
                if let override {
                    result = try await override([task.id], false)
                } else if let repository {
                    result = try await repository.deleteDownloadTasksResult(
                        ids: [task.id],
                        removeData: false
                    )
                } else {
                    return
                }
                try Task.checkCancellation()
                await MainActor.run {
                    self?.finishDownloadDelete(
                        result,
                        taskID: task.id,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.finishDownloadDeleteCancellation(
                        taskID: task.id,
                        generation: generation
                    )
                }
            } catch {
                await MainActor.run {
                    self?.finishDownloadDeleteFailure(
                        taskID: task.id,
                        generation: generation
                    )
                }
            }
        }
    }

    func dismissDownloadCreateFeedback() {
        guard !isCreatingDownloadTask else { return }
        downloadCreateFeedback = nil
    }

    func title(for feedback: MobileDownloadControlFeedback) -> String {
        switch feedback.kind {
        case .inProgress:
            switch feedback.action {
            case .pause:
                return L10n.string("mobile.downloads.control.pausing.title")
            case .resume:
                return L10n.string("mobile.downloads.control.resuming.title")
            case .finish:
                return L10n.string("mobile.downloads.control.unsupported.title")
            }
        case .success:
            switch feedback.action {
            case .pause:
                return L10n.string("mobile.downloads.control.paused.title")
            case .resume:
                return L10n.string("mobile.downloads.control.resumed.title")
            case .finish:
                return L10n.string("mobile.downloads.control.unsupported.title")
            }
        case .needsReview:
            return L10n.string("mobile.downloads.control.review.title")
        case .cancelled:
            return L10n.string("mobile.downloads.control.cancelled.title")
        case .conflict:
            return L10n.string("mobile.downloads.control.conflict.title")
        case .permission:
            return L10n.string("mobile.downloads.control.permission.title")
        case .unsupported:
            return L10n.string("mobile.downloads.control.unsupported.title")
        case .failure:
            return L10n.string("mobile.downloads.control.failure.title")
        }
    }

    func message(for feedback: MobileDownloadControlFeedback) -> String {
        switch feedback.kind {
        case .inProgress:
            return L10n.string("mobile.downloads.control.in-progress.message")
        case .success:
            return L10n.string("mobile.downloads.control.success.message")
        case .needsReview:
            return L10n.string("mobile.downloads.control.review.message")
        case .cancelled:
            return L10n.string("mobile.downloads.control.cancelled.message")
        case .conflict:
            return L10n.string("mobile.downloads.control.conflict.message")
        case .permission:
            return L10n.string("mobile.downloads.control.permission.message")
        case .unsupported:
            return L10n.string("mobile.downloads.control.unsupported.message")
        case .failure:
            return L10n.string("mobile.downloads.control.failure.message")
        }
    }

    func title(for feedback: MobileDownloadCreateFeedback) -> String {
        switch feedback.kind {
        case .inProgress:
            return L10n.string("mobile.downloads.create.creating.title")
        case .success:
            return L10n.string("mobile.downloads.create.success.title")
        case .needsReview:
            return L10n.string("mobile.downloads.create.review.title")
        case .cancelled:
            return L10n.string("mobile.downloads.create.cancelled.title")
        case .conflict:
            return L10n.string("mobile.downloads.create.conflict.title")
        case .permission:
            return L10n.string("mobile.downloads.create.permission.title")
        case .unsupported:
            return L10n.string("mobile.downloads.create.unsupported.title")
        case .failure:
            return L10n.string("mobile.downloads.create.failure.title")
        }
    }

    func message(for feedback: MobileDownloadCreateFeedback) -> String {
        switch feedback.kind {
        case .inProgress:
            return L10n.string("mobile.downloads.create.creating.message")
        case .success:
            return L10n.string("mobile.downloads.create.success.message")
        case .needsReview:
            return L10n.string("mobile.downloads.create.review.message")
        case .cancelled:
            return L10n.string("mobile.downloads.create.cancelled.message")
        case .conflict:
            return L10n.string("mobile.downloads.create.conflict.message")
        case .permission:
            return L10n.string("mobile.downloads.create.permission.message")
        case .unsupported:
            return L10n.string("mobile.downloads.create.unsupported.message")
        case .failure:
            return L10n.string("mobile.downloads.create.failure.message")
        }
    }

    func title(for feedback: MobileDownloadDeleteFeedback) -> String {
        switch feedback.kind {
        case .inProgress:
            return L10n.string("mobile.downloads.delete.deleting.title")
        case .success:
            return L10n.string("mobile.downloads.delete.success.title")
        case .needsReview:
            return L10n.string("mobile.downloads.delete.review.title")
        case .cancelled:
            return L10n.string("mobile.downloads.delete.cancelled.title")
        case .conflict:
            return L10n.string("mobile.downloads.delete.conflict.title")
        case .permission:
            return L10n.string("mobile.downloads.delete.permission.title")
        case .unsupported:
            return L10n.string("mobile.downloads.delete.unsupported.title")
        case .failure:
            return L10n.string("mobile.downloads.delete.failure.title")
        }
    }

    func message(for feedback: MobileDownloadDeleteFeedback) -> String {
        switch feedback.kind {
        case .inProgress:
            return L10n.string("mobile.downloads.delete.deleting.message")
        case .success:
            return L10n.string("mobile.downloads.delete.success.message")
        case .needsReview:
            return L10n.string("mobile.downloads.delete.review.message")
        case .cancelled:
            return L10n.string("mobile.downloads.delete.cancelled.message")
        case .conflict:
            return L10n.string("mobile.downloads.delete.conflict.message")
        case .permission:
            return L10n.string("mobile.downloads.delete.permission.message")
        case .unsupported:
            return L10n.string("mobile.downloads.delete.unsupported.message")
        case .failure:
            return L10n.string("mobile.downloads.delete.failure.message")
        }
    }

    private func finishDownloadControl(
        _ outcome: DownloadTaskControlOutcome,
        action: DownloadStationTaskAction,
        generation: UInt64
    ) {
        guard generation == downloadControlGeneration else { return }
        downloadControlTask = nil
        downloadControlTaskID = nil
        downloadControlAction = nil
        if outcome.result.status == .confirmedSuccess, let task = outcome.task {
            replaceDownloadTask(task)
        }
        downloadControlFeedback = MobileDownloadControlFeedback(
            taskID: outcome.taskID,
            action: action,
            kind: Self.feedbackKind(for: outcome.result)
        )
    }

    private func finishDownloadControlCancellation(
        taskID: String,
        action: DownloadStationTaskAction,
        generation: UInt64
    ) {
        guard generation == downloadControlGeneration else { return }
        downloadControlTask = nil
        downloadControlTaskID = nil
        downloadControlAction = nil
        downloadControlFeedback = MobileDownloadControlFeedback(
            taskID: taskID,
            action: action,
            kind: .cancelled
        )
    }

    private func finishDownloadControlFailure(
        taskID: String,
        action: DownloadStationTaskAction,
        generation: UInt64
    ) {
        guard generation == downloadControlGeneration else { return }
        downloadControlTask = nil
        downloadControlTaskID = nil
        downloadControlAction = nil
        downloadControlFeedback = MobileDownloadControlFeedback(
            taskID: taskID,
            action: action,
            kind: .needsReview
        )
    }

    private func finishDownloadCreate(
        _ outcome: DownloadTaskCreateOutcome,
        uri: String,
        generation: UInt64
    ) {
        guard generation == downloadCreateGeneration else { return }
        downloadCreateTask = nil
        if outcome.result.status == .confirmedSuccess, let task = outcome.task {
            upsertDownloadTask(task)
        }
        downloadCreateFeedback = MobileDownloadCreateFeedback(
            uri: uri,
            kind: Self.feedbackKind(for: outcome.result, confirmedTask: outcome.task)
        )
    }

    private func finishDownloadCreateCancellation(uri: String, generation: UInt64) {
        guard generation == downloadCreateGeneration else { return }
        downloadCreateTask = nil
        downloadCreateFeedback = MobileDownloadCreateFeedback(uri: uri, kind: .cancelled)
    }

    private func finishDownloadCreateFailure(uri: String, generation: UInt64) {
        guard generation == downloadCreateGeneration else { return }
        downloadCreateTask = nil
        downloadCreateFeedback = MobileDownloadCreateFeedback(uri: uri, kind: .needsReview)
    }

    private func finishDownloadDelete(
        _ result: MutationResult,
        taskID: String,
        generation: UInt64
    ) {
        guard generation == downloadDeleteGeneration else { return }
        downloadDeleteTask = nil
        downloadDeleteTaskID = nil
        if result.status == .confirmedSuccess {
            removeDownloadTask(id: taskID)
        }
        downloadDeleteFeedback = MobileDownloadDeleteFeedback(
            taskID: taskID,
            kind: Self.feedbackKind(forDeleteResult: result)
        )
    }

    private func finishDownloadDeleteCancellation(taskID: String, generation: UInt64) {
        guard generation == downloadDeleteGeneration else { return }
        downloadDeleteTask = nil
        downloadDeleteTaskID = nil
        downloadDeleteFeedback = MobileDownloadDeleteFeedback(
            taskID: taskID,
            kind: .cancelled
        )
    }

    private func finishDownloadDeleteFailure(taskID: String, generation: UInt64) {
        guard generation == downloadDeleteGeneration else { return }
        downloadDeleteTask = nil
        downloadDeleteTaskID = nil
        downloadDeleteFeedback = MobileDownloadDeleteFeedback(
            taskID: taskID,
            kind: .needsReview
        )
    }

    private func replaceDownloadTask(_ task: DownloadStationTask) {
        guard let snapshot = downloadSnapshot,
              let index = snapshot.tasks.firstIndex(where: { $0.id == task.id }) else {
            return
        }
        var tasks = snapshot.tasks
        tasks[index] = task
        downloadSnapshot = DownloadStationSnapshot(
            source: snapshot.source,
            tasks: tasks,
            hasActivitySummary: snapshot.hasActivitySummary,
            hasBTSearch: snapshot.hasBTSearch,
            downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
            uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
            emuleDownloadBytesPerSecond: snapshot.emuleDownloadBytesPerSecond,
            emuleUploadBytesPerSecond: snapshot.emuleUploadBytesPerSecond,
            defaultDestination: snapshot.defaultDestination
        )
        syncDownloadSnapshotToActivity()
    }

    private func upsertDownloadTask(_ task: DownloadStationTask) {
        guard let snapshot = downloadSnapshot else { return }
        var tasks = snapshot.tasks
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        downloadSnapshot = DownloadStationSnapshot(
            source: snapshot.source,
            tasks: tasks,
            hasActivitySummary: snapshot.hasActivitySummary,
            hasBTSearch: snapshot.hasBTSearch,
            downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
            uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
            emuleDownloadBytesPerSecond: snapshot.emuleDownloadBytesPerSecond,
            emuleUploadBytesPerSecond: snapshot.emuleUploadBytesPerSecond,
            defaultDestination: snapshot.defaultDestination
        )
        syncDownloadSnapshotToActivity()
    }

    private func removeDownloadTask(id: String) {
        guard let snapshot = downloadSnapshot else { return }
        let tasks = snapshot.tasks.filter { $0.id != id }
        downloadSnapshot = DownloadStationSnapshot(
            source: snapshot.source,
            tasks: tasks,
            hasActivitySummary: snapshot.hasActivitySummary,
            hasBTSearch: snapshot.hasBTSearch,
            downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
            uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
            emuleDownloadBytesPerSecond: snapshot.emuleDownloadBytesPerSecond,
            emuleUploadBytesPerSecond: snapshot.emuleUploadBytesPerSecond,
            defaultDestination: snapshot.defaultDestination
        )
        syncDownloadSnapshotToActivity()
    }

    private static func feedbackKind(
        for result: MutationResult,
        confirmedTask: DownloadStationTask?
    ) -> MobileDownloadCreateFeedbackKind {
        switch result.status {
        case .confirmedSuccess:
            return confirmedTask == nil ? .needsReview : .success
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            return .needsReview
        case .cancelledBeforeSubmission:
            return .cancelled
        case .permissionDenied:
            return .permission
        case .unsupported:
            return .unsupported
        case .confirmedFailure:
            return result.errorCategory == .conflict ? .conflict : .failure
        }
    }

    private static func feedbackKind(for result: MutationResult) -> MobileDownloadControlFeedbackKind {
        switch result.status {
        case .confirmedSuccess:
            return .success
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            return .needsReview
        case .cancelledBeforeSubmission:
            return .cancelled
        case .permissionDenied:
            return .permission
        case .unsupported:
            return .unsupported
        case .confirmedFailure:
            return result.errorCategory == .conflict ? .conflict : .failure
        case .partialSuccess:
            return .needsReview
        }
    }

    private static func feedbackKind(
        forDeleteResult result: MutationResult
    ) -> MobileDownloadDeleteFeedbackKind {
        switch result.status {
        case .confirmedSuccess:
            return .success
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            return .needsReview
        case .cancelledBeforeSubmission:
            return .cancelled
        case .permissionDenied:
            return .permission
        case .unsupported:
            return .unsupported
        case .confirmedFailure:
            return result.errorCategory == .conflict ? .conflict : .failure
        }
    }

    private static func canPauseDownloadTaskStatus(_ status: String) -> Bool {
        [
            "waiting",
            "downloading",
            "checking",
            "hash_checking",
            "filehosting_waiting",
            "extracting",
            "seeding"
        ].contains(normalizedDownloadTaskStatus(status))
    }

    private static func canResumeDownloadTaskStatus(_ status: String) -> Bool {
        normalizedDownloadTaskStatus(status) == "paused"
    }

    private static func normalizedDownloadTaskStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
