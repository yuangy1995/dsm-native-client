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

    func feedbackForDownloadTask(_ task: DownloadStationTask) -> MobileDownloadControlFeedback? {
        guard downloadControlFeedback?.taskID == task.id else { return nil }
        return downloadControlFeedback
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
            downloadBytesPerSecond: snapshot.downloadBytesPerSecond,
            uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
            defaultDestination: snapshot.defaultDestination
        )
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
