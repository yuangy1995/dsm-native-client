import DsmNetwork
import Observation
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

/// 下载操作属于连接上下文，离开页面只停止读取，不丢弃已提交操作。
@MainActor
@Observable
final class MobileDownloadsModel {
    var activeProfile: NasProfile?
    @ObservationIgnored var serviceRepository: DsmServiceManagementRepository?
    @ObservationIgnored private let transferCoordinator: MobileTransferCoordinator
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    var isLoading = false
    var message: String?
    var searchText = ""
    var taskFilter: MobileDownloadFilter = .all
    var taskSort: MobileDownloadSort = .name
    @ObservationIgnored var downloadDetailsOverride: (@Sendable (String) async throws -> DownloadStationTaskDetails)?
    @ObservationIgnored var downloadStationLoadOverride: (@Sendable () async throws -> DownloadStationSnapshot)?
    @ObservationIgnored var downloadStationControlOverride:
        (@Sendable (DownloadTaskControlRequest) async throws -> DownloadTaskControlOutcome)?
    @ObservationIgnored var downloadStationCreateOverride:
        (@Sendable (DownloadTaskCreateRequest) async throws -> DownloadTaskCreateOutcome)?
    @ObservationIgnored var downloadStationCreateFileOverride:
        (@Sendable (DownloadTaskFileCreateRequest) async throws -> DownloadTaskCreateOutcome)?
    @ObservationIgnored var downloadStationDeleteOverride:
        (@Sendable ([String], Bool) async throws -> MutationResult)?
    @ObservationIgnored var downloadControlTask: Task<Void, Never>?
    @ObservationIgnored var downloadControlGeneration: UInt64 = 0
    @ObservationIgnored var downloadCreateTask: Task<Void, Never>?
    @ObservationIgnored var downloadCreateGeneration: UInt64 = 0
    @ObservationIgnored var downloadDeleteTask: Task<Void, Never>?
    @ObservationIgnored var downloadDeleteGeneration: UInt64 = 0
    var downloadSnapshot: DownloadStationSnapshot?
    var downloadControlTaskID: String?
    var downloadControlAction: DownloadStationTaskAction?
    var downloadControlFeedback: MobileDownloadControlFeedback?
    var downloadCreateFeedback: MobileDownloadCreateFeedback?
    var downloadDeleteTaskID: String?
    var downloadDeleteFeedback: MobileDownloadDeleteFeedback?

    let createRecovery: MobileDownloadCreateStore
    var createErrorKey: String?
    let settings: MobileDownloadSettingsModel
    let rss: MobileDownloadRSSModel
    let editRecovery: MobileDownloadEditStore
    var editActivation = UUID()
    var editBatchID: UUID?
    var editErrorKey: String?
    @ObservationIgnored var downloadEditTask: Task<Void, Never>?
    @ObservationIgnored var downloadEditGeneration: UInt64 = 0
    let controlRecovery: MobileDownloadControlStore
    var controlBatchID: UUID?
    var controlCancelRequestedID: UUID?
    var controlErrorKey: String?
    @ObservationIgnored var downloadControlReadOverride: (@Sendable (String) async throws -> DownloadStationTask?)?

    init(transferCoordinator: MobileTransferCoordinator, controlRoot: URL? = nil) {
        self.transferCoordinator = transferCoordinator
        self.controlRecovery = MobileDownloadControlStore(root: controlRoot)
        self.settings = MobileDownloadSettingsModel(root: controlRoot)
        self.rss = MobileDownloadRSSModel(root: controlRoot)
        self.editRecovery = MobileDownloadEditStore(root: controlRoot)
        self.createRecovery = MobileDownloadCreateStore(root: controlRoot)
    }

    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?) {
        settings.configure(profile: profile, repository: repository)
        rss.configure(profile: profile, repository: repository)
        let identityChanged = profile.map(MobileWorkspaceIdentity.init) != activeProfile.map(MobileWorkspaceIdentity.init)
        let repositoryChanged = repository.map(ObjectIdentifier.init) != serviceRepository.map(ObjectIdentifier.init)
        if identityChanged || repositoryChanged {
            cancelLoad()
            deactivateDownloads()
            downloadSnapshot = nil
            message = nil
            resetPresentation()
        }
        activeProfile = profile
        serviceRepository = repository
    }

    func deactivate() {
        settings.configure(profile: nil, repository: nil)
        rss.configure(profile: nil, repository: nil)
        cancelLoad()
        deactivateDownloads()
        activeProfile = nil
        serviceRepository = nil
        downloadSnapshot = nil
        message = nil
        resetPresentation()
    }

    func cancelLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let identity = activeProfile.map(MobileWorkspaceIdentity.init)
        let mutationGenerations = [downloadControlGeneration, downloadCreateGeneration, downloadDeleteGeneration, downloadEditGeneration]
        guard identity != nil else { return }
        isLoading = true
        message = nil
        do {
            let snapshot: DownloadStationSnapshot
            if let downloadStationLoadOverride { snapshot = try await downloadStationLoadOverride() }
            else if let serviceRepository { snapshot = try await serviceRepository.loadDownloadStationInventory() }
            else { throw AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("ui.38245f0b3e213b62")) }
            try Task.checkCancellation()
            guard generation == loadGeneration, identity == activeProfile.map(MobileWorkspaceIdentity.init) else { return }
            guard mutationGenerations == [downloadControlGeneration, downloadCreateGeneration, downloadDeleteGeneration, downloadEditGeneration] else {
                isLoading = false
                return
            }
            downloadSnapshot = snapshot
            syncDownloadSnapshotToActivity()
            isLoading = false
            recoverPendingDownloadControls()
            recoverPendingDownloadEdits()
        } catch {
            guard generation == loadGeneration, identity == activeProfile.map(MobileWorkspaceIdentity.init) else { return }
            if !(error is CancellationError) {
                message = (error as? AppError)?.safeUserMessage ?? L10n.string("ui.38245f0b3e213b62")
            }
            isLoading = false
        }
    }

    private func syncDownloadSnapshotToActivity() {
        guard let profile = activeProfile, let snapshot = downloadSnapshot else { return }
        let context = MobileWorkspaceIdentity(profile)
        Task { [transferCoordinator] in
            await transferCoordinator.syncDownloadStationTasks(profileID: profile.id, snapshot: snapshot, context: context)
        }
    }

    var downloadPageState: MobilePageState {
        if isLoading, downloadSnapshot == nil {
            return .loading
        }
        guard let downloadSnapshot else {
            return message == nil ? .loading : .error
        }
        if downloadSnapshot.tasks.isEmpty { return .empty }
        return visibleTasks.isEmpty ? .filteredEmpty : .content
    }

    var visibleTasks: [DownloadStationTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (downloadSnapshot?.tasks ?? []).filter {
            taskFilter.includes($0) && (query.isEmpty || $0.title.range(of: query,
                options: [.caseInsensitive, .diacriticInsensitive], locale: L10n.locale) != nil)
        }.sorted { taskSort.precedes($0, $1) }
    }

    func resetPresentation() {
        searchText = ""
        taskFilter = .all
        taskSort = .name
    }

    func loadDetails(id: String) async throws -> DownloadStationTaskDetails {
        let identity = activeProfile.map(MobileWorkspaceIdentity.init)
        let repository = serviceRepository
        let mutationGenerations = [downloadControlGeneration, downloadCreateGeneration, downloadDeleteGeneration, downloadEditGeneration]
        guard identity != nil else { throw CancellationError() }
        let details: DownloadStationTaskDetails
        if let downloadDetailsOverride { details = try await downloadDetailsOverride(id) }
        else if let repository { details = try await repository.loadDownloadTaskDetails(id: id) }
        else { throw AppError(category: .apiUnavailable, isRetryable: false,
                             safeUserMessage: L10n.string("mobile.downloads.details.failed")) }
        try Task.checkCancellation()
        guard identity == activeProfile.map(MobileWorkspaceIdentity.init),
              repository.map(ObjectIdentifier.init) == serviceRepository.map(ObjectIdentifier.init),
              mutationGenerations == [downloadControlGeneration, downloadCreateGeneration, downloadDeleteGeneration, downloadEditGeneration] else {
            throw CancellationError()
        }
        guard details.task.id == id else {
            throw AppError(category: .invalidResponse, isRetryable: true,
                           safeUserMessage: L10n.string("mobile.downloads.details.failed"))
        }
        replaceDownloadTask(details.task)
        return details
    }

    var isControllingDownloadTask: Bool {
        controlBatchID != nil || controlEntries.contains { controlRecovery.isExecuting($0.id) }
    }

    var isCreatingDownloadTask: Bool {
        downloadCreateTask != nil
    }

    var isDeletingDownloadTask: Bool {
        downloadDeleteTaskID != nil
    }

    var canCreateDownloadTask: Bool {
        !createRecovery.failed && !isCreatingDownloadTask &&
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
        cancelLoad()
        loadTask = Task { [weak self] in await self?.load() }
    }

    func deactivateDownloads() {
        editActivation = UUID(); downloadEditGeneration &+= 1
        downloadEditTask?.cancel(); downloadEditTask = nil; editBatchID = nil; editErrorKey = nil
        controlBatchID = nil
        controlCancelRequestedID = nil
        controlErrorKey = nil
        downloadControlGeneration &+= 1
        downloadControlTask?.cancel()
        downloadControlTask = nil
        downloadControlTaskID = nil
        downloadControlAction = nil
        downloadControlFeedback = nil
        downloadCreateGeneration &+= 1
        downloadCreateTask?.cancel()
        downloadCreateTask = nil
        downloadCreateFeedback = nil; createErrorKey = nil
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
        canStartDownloadControl(task) && Self.canPauseDownloadTaskStatus(task.status)
    }

    func canResumeDownloadTask(_ task: DownloadStationTask) -> Bool {
        canStartDownloadControl(task) && Self.canResumeDownloadTaskStatus(task.status)
    }

    func canDeleteDownloadTask(_ task: DownloadStationTask) -> Bool {
        !isDeletingDownloadTask &&
        !isEditingDownloadTask && !editProtects(task.id) &&
        !isControllingDownloadTask &&
        !controlProtects(task.id) &&
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
        _ = startDownloadControlBatch([task], action: action)
    }

    func createDownloadTask(uri rawURI: String) {
        startDownloadCreation(.link(rawURI.trimmingCharacters(in: .whitespacesAndNewlines)), destination: downloadCreateDefaultDestination)
    }

    func createDownloadTask(fileURL: URL) { startDownloadCreation(.file(fileURL), destination: downloadCreateDefaultDestination) }

    /// 草稿冻结打开时的连接；旧表单不能向重连或新账号提交。
    func createDownloadTask(draft: MobileDownloadCreateDraft, uri: String, destination: String?, unzipPassword: String) {
        guard draft.activation == editActivation,
              destination.map(DownloadTaskDestinationChange.validDestination) != false else { return }
        switch draft.source {
        case .link:
            startDownloadCreation(.link(uri.trimmingCharacters(in: .whitespacesAndNewlines)), destination: destination)
        case .file(let url):
            startDownloadCreation(.file(url), destination: destination, unzipPassword: unzipPassword.isEmpty ? nil : unzipPassword)
        }
    }

    private enum CreateSource {
        case link(String), file(URL)
        var displayName: String { switch self { case .link(let uri): uri; case .file(let url): url.lastPathComponent } }
        var kind: MobileDownloadCreateStore.Source { switch self { case .link: .link; case .file: .file } }
    }
    var createEntries: [MobileDownloadCreateStore.Entry] {
        createRecovery.entries.filter { $0.context == controlContext }.reversed()
    }
    func removeDownloadCreation(_ id: UUID) {
        guard let context = controlContext else { return }
        do { try createRecovery.remove(id, context: context) }
        catch { createErrorKey = "download.edit.storage-error" }
    }

    private func startDownloadCreation(_ source: CreateSource, destination: String?, unzipPassword: String? = nil) {
        guard !isCreatingDownloadTask else { return }
        guard canCreateDownloadTask, let context = controlContext, !source.displayName.isEmpty else {
            createErrorKey = createRecovery.failed ? "download.edit.storage-error" : nil
            downloadCreateFeedback = .init(uri: source.displayName, kind: .unsupported); return
        }
        downloadCreateGeneration &+= 1
        let generation = downloadCreateGeneration, id = UUID(), store = createRecovery
        let repository = serviceRepository
        let linkOverride = downloadStationCreateOverride, fileOverride = downloadStationCreateFileOverride
        let name = source.displayName, kind = source.kind
        createErrorKey = nil; downloadCreateFeedback = .init(uri: name, kind: .inProgress)
        let willSubmit: @Sendable (DownloadTaskCreationIdentity) async throws -> Void = { [weak self] identity in
            try await MainActor.run {
                guard let self, self.downloadCreateGeneration == generation, self.controlContext == context else { throw CancellationError() }
                try store.reserve(.init(id: id, context: context, createdAt: Date(), source: kind, identity: identity))
            }
        }
        let didAccept: @Sendable () async throws -> Void = {
            // 迟到的成功回执仍必须写回原账号记录，不能受新页面的代次影响。
            try await store.progress(id, context: context, phase: .accepted)
        }
        downloadCreateTask = Task { [weak self] in
            var input: URL?
            var inputPreparationFailed = false
            defer { if let input { store.removeInput(input) }; store.end(id) }
            do {
                let outcome: DownloadTaskCreateOutcome
                switch source {
                case .link(let uri):
                    let request = DownloadTaskCreateRequest(uri: uri, destination: destination)
                    if let linkOverride { outcome = try await linkOverride(request) }
                    else if let repository { outcome = try await repository.createDownloadTaskResult(request, willSubmit: willSubmit, didAccept: didAccept) }
                    else { throw CancellationError() }
                case .file(let url):
                    if let fileOverride {
                        outcome = try await fileOverride(.init(fileURL: url, destination: destination, unzipPassword: unzipPassword))
                    } else if let repository {
                        let copy: URL
                        do { copy = try await store.copyInput(url, id: id); input = copy }
                        catch { inputPreparationFailed = true; throw error }
                        try Task.checkCancellation()
                        let request = DownloadTaskFileCreateRequest(fileURL: copy, destination: destination, unzipPassword: unzipPassword)
                        outcome = try await repository.createDownloadTaskFileResult(request, willSubmit: willSubmit, didAccept: didAccept)
                    } else { throw CancellationError() }
                }
                if store.entry(id, context: context)?.phase == .submitted {
                    switch outcome.result.status {
                    case .cancelledBeforeSubmission: try store.progress(id, context: context, phase: .cancelled)
                    case .confirmedFailure, .permissionDenied, .unsupported:
                        try store.progress(id, context: context, phase: .failed,
                            failure: outcome.result.status == .permissionDenied ? .denied : .unavailable)
                    default: break
                    }
                }
                self?.finishDownloadCreate(outcome, uri: name, generation: generation)
            } catch {
                guard let self, self.downloadCreateGeneration == generation else { return }
                self.downloadCreateGeneration &+= 1; self.downloadCreateTask = nil
                self.createErrorKey = store.failed ? "download.edit.storage-error"
                    : inputPreparationFailed ? "shared.51bdbefbc0c88421" : nil
                let pending = store.entry(id, context: context)?.phase == .submitted
                let duplicate = (error as? MobileDownloadCreateStore.StoreError) == .duplicate
                self.downloadCreateFeedback = .init(uri: name,
                    kind: pending || duplicate ? .needsReview : error is CancellationError ? .cancelled : .failure)
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
        if let createErrorKey { return L10n.string(createErrorKey) }
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

    private func finishDownloadCreate(
        _ outcome: DownloadTaskCreateOutcome,
        uri: String,
        generation: UInt64
    ) {
        guard generation == downloadCreateGeneration else { return }
        downloadCreateGeneration &+= 1
        downloadCreateTask = nil
        if outcome.result.status == .confirmedSuccess, let task = outcome.task {
            upsertDownloadTask(task)
        }
        downloadCreateFeedback = MobileDownloadCreateFeedback(
            uri: uri,
            kind: outcome.requestAccepted ? .success : Self.feedbackKind(for: outcome.result, confirmedTask: outcome.task)
        )
        if outcome.requestAccepted { reloadDownloads() }
    }

    private func finishDownloadDelete(
        _ result: MutationResult,
        taskID: String,
        generation: UInt64
    ) {
        guard generation == downloadDeleteGeneration else { return }
        downloadDeleteGeneration &+= 1
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
        downloadDeleteGeneration &+= 1
        downloadDeleteTask = nil
        downloadDeleteTaskID = nil
        downloadDeleteFeedback = MobileDownloadDeleteFeedback(
            taskID: taskID,
            kind: .cancelled
        )
    }

    private func finishDownloadDeleteFailure(taskID: String, generation: UInt64) {
        guard generation == downloadDeleteGeneration else { return }
        downloadDeleteGeneration &+= 1
        downloadDeleteTask = nil
        downloadDeleteTaskID = nil
        downloadDeleteFeedback = MobileDownloadDeleteFeedback(
            taskID: taskID,
            kind: .needsReview
        )
    }

    func replaceDownloadTask(_ task: DownloadStationTask) {
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
            defaultDestination: snapshot.defaultDestination,
            isComplete: snapshot.isComplete, statistics: snapshot.statistics
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
            defaultDestination: snapshot.defaultDestination,
            isComplete: snapshot.isComplete, statistics: snapshot.statistics
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
            defaultDestination: snapshot.defaultDestination,
            isComplete: snapshot.isComplete, statistics: snapshot.statistics
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

    static func feedbackKind(for result: MutationResult) -> MobileDownloadControlFeedbackKind {
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

    static func canPauseDownloadTaskStatus(_ status: String) -> Bool {
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

    static func canResumeDownloadTaskStatus(_ status: String) -> Bool {
        normalizedDownloadTaskStatus(status) == "paused"
    }

    static func normalizedDownloadTaskStatus(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
