import DsmCore
import Foundation

/// 仅管理当前进程内、用户主动发起的前台单文件任务。
actor MobileTransferCoordinator {
    private let mutationCoordinator: MobileMutationCoordinator
    private var tasksByID: [UUID: MobileActivityTask] = [:]
    private var requestsByID: [UUID: MobileTransferRequest] = [:]
    private var executionsByID: [UUID: Task<Void, Never>] = [:]
    private var executionGenerationsByID: [UUID: UUID] = [:]

    init(mutationCoordinator: MobileMutationCoordinator = MobileMutationCoordinator()) {
        self.mutationCoordinator = mutationCoordinator
    }

    func enqueueUpload(
        _ request: MobileUploadRequest,
        retryPolicy: MobileTransferRetryPolicy = .restartFromBeginning
    ) -> UUID {
        enqueue(.upload(request), retryPolicy: retryPolicy)
    }

    func enqueueDownload(_ request: MobileDownloadRequest) -> UUID {
        enqueue(.download(request), retryPolicy: .restartFromBeginning)
    }

    func registerNasTask(
        profileID: UUID,
        direction: MobileTransferDirection,
        stableTarget: String,
        progress: MobileTransferProgress,
        status: MobileTransferStatus
    ) -> UUID {
        let id = UUID()
        tasksByID[id] = MobileActivityTask(
            id: id,
            createdAt: Date(),
            profileID: profileID,
            source: .nas,
            direction: direction,
            stableTarget: stableTarget,
            progress: progress,
            status: status,
            retryPolicy: .none,
            mutationResult: nil
        )
        return id
    }

    func start(_ id: UUID, using service: any MobileTransferServing) {
        guard executionsByID[id] == nil,
              let task = tasksByID[id],
              task.source == .app,
              task.status == .queued,
              requestsByID[id] != nil else { return }
        tasksByID[id]?.status = .preparing
        let generation = UUID()
        executionGenerationsByID[id] = generation
        executionsByID[id] = Task { [weak self] in
            await self?.execute(id, generation: generation, using: service)
        }
    }

    func cancel(_ id: UUID) {
        guard var task = tasksByID[id], !task.status.isTerminal else { return }
        switch task.status {
        case .queued, .preparing:
            executionsByID[id]?.cancel()
            executionsByID[id] = nil
            executionGenerationsByID[id] = nil
            task.status = .cancelledBeforeSubmission
            task.progress = .zero
            tasksByID[id] = task
        case .running:
            task.status = .cancelling
            tasksByID[id] = task
            executionsByID[id]?.cancel()
        case .cancelling, .succeeded, .failed, .cancelledBeforeSubmission, .cancelled,
             .resultNeedsReview:
            break
        }
    }

    func retryFromBeginning(_ id: UUID, using service: any MobileTransferServing) async {
        guard let task = tasksByID[id],
              task.retryPolicy == .restartFromBeginning,
              task.status.isTerminal,
              let request = requestsByID[id],
              Self.canRetryFromBeginning(request: request, status: task.status) else { return }

        // 终态可能先于旧执行释放同目标提交锁发布；先等待旧执行真正退出，
        // 避免“从头重试”被误判为同目标重复提交。
        let previousExecution = executionsByID[id]
        previousExecution?.cancel()
        if let previousExecution {
            await previousExecution.value
        }

        guard var task = tasksByID[id],
              task.retryPolicy == .restartFromBeginning,
              task.status.isTerminal,
              let request = requestsByID[id],
              Self.canRetryFromBeginning(request: request, status: task.status),
              executionsByID[id] == nil else { return }
        task.progress = .zero
        task.mutationResult = nil
        task.status = .queued
        tasksByID[id] = task
        executionGenerationsByID[id] = nil
        start(id, using: service)
    }

    func task(id: UUID) -> MobileActivityTask? {
        tasksByID[id]
    }

    /// 本地源文件已被清理后，关闭从头重试，避免留下指向失效副本的入口。
    func disableRetry(_ id: UUID) {
        tasksByID[id]?.retryPolicy = .none
    }

    func tasks(profileID: UUID) -> [MobileActivityTask] {
        tasksByID.values
            .filter { $0.profileID == profileID }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func allTasks() -> [MobileActivityTask] {
        Array(tasksByID.values)
    }

    private func enqueue(
        _ request: MobileTransferRequest,
        retryPolicy: MobileTransferRetryPolicy
    ) -> UUID {
        let id = UUID()
        tasksByID[id] = MobileActivityTask(
            id: id,
            createdAt: Date(),
            profileID: request.profileID,
            source: .app,
            direction: request.direction,
            stableTarget: request.stableTarget,
            progress: .zero,
            status: .queued,
            retryPolicy: retryPolicy,
            mutationResult: nil
        )
        requestsByID[id] = request
        return id
    }

    private func execute(
        _ id: UUID,
        generation: UUID,
        using service: any MobileTransferServing
    ) async {
        guard isCurrentExecution(id, generation: generation),
              let request = requestsByID[id],
              tasksByID[id]?.status == .preparing else {
            clearExecution(id, generation: generation)
            return
        }
        await Task.yield()
        guard !Task.isCancelled,
              isCurrentExecution(id, generation: generation),
              tasksByID[id]?.status == .preparing else {
            clearExecution(id, generation: generation)
            return
        }

        do {
            let outcome = try await mutationCoordinator.perform(
                profileID: request.profileID,
                operation: request.direction.rawValue,
                stableTarget: request.stableTarget
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                guard await self.markRunning(id, generation: generation) else {
                    throw CancellationError()
                }
                switch request {
                case .upload(let upload):
                    try await service.upload(upload) { completed, total in
                        Task {
                            await self.updateProgress(
                                id,
                                generation: generation,
                                completed: completed,
                                total: total
                            )
                        }
                    }
                case .download(let download):
                    try await service.download(download) { completed, total in
                        Task {
                            await self.updateProgress(
                                id,
                                generation: generation,
                                completed: completed,
                                total: total
                            )
                        }
                    }
                }
            }
            guard isCurrentExecution(id, generation: generation) else { return }
            switch outcome {
            case .submitted:
                if Task.isCancelled || tasksByID[id]?.status == .cancelling {
                    await finishAfterSubmittedCancellation(
                        id,
                        request: request,
                        service: service
                    )
                } else {
                    complete(id, status: .succeeded)
                }
            case .duplicateInFlight:
                complete(id, status: .cancelledBeforeSubmission, clearsProgress: true)
            }
        } catch {
            guard isCurrentExecution(id, generation: generation) else { return }
            await handleExecutionError(id, request: request, error: error, service: service)
        }
        clearExecution(id, generation: generation)
    }

    private func markRunning(_ id: UUID, generation: UUID) -> Bool {
        guard isCurrentExecution(id, generation: generation),
              tasksByID[id]?.status == .preparing else { return false }
        tasksByID[id]?.status = .running
        return true
    }

    private func updateProgress(
        _ id: UUID,
        generation: UUID,
        completed: Int64,
        total: Int64?
    ) {
        guard isCurrentExecution(id, generation: generation),
              let status = tasksByID[id]?.status,
              status == .running || status == .cancelling else { return }
        tasksByID[id]?.progress = MobileTransferProgress(
            completedBytes: max(0, completed),
            totalBytes: total.map { max(0, $0) }
        )
    }

    private func handleExecutionError(
        _ id: UUID,
        request: MobileTransferRequest,
        error: Error,
        service: any MobileTransferServing
    ) async {
        tasksByID[id]?.failureCategory = Self.failureCategory(for: error)
        let submitted = tasksByID[id]?.status == .running || tasksByID[id]?.status == .cancelling
        guard submitted else {
            complete(id, status: .cancelledBeforeSubmission, clearsProgress: true)
            return
        }
        switch request {
        case .upload(let upload):
            await reviewUnknownUpload(id, request: upload, service: service)
        case .download(let download):
            if Task.isCancelled || tasksByID[id]?.status == .cancelling {
                await service.removePartialDownload(download)
                complete(id, status: .cancelled, clearsProgress: true)
            } else {
                complete(id, status: .failed)
            }
        }
    }

    private func finishAfterSubmittedCancellation(
        _ id: UUID,
        request: MobileTransferRequest,
        service: any MobileTransferServing
    ) async {
        switch request {
        case .upload(let upload):
            await reviewUnknownUpload(id, request: upload, service: service)
        case .download(let download):
            await service.removePartialDownload(download)
            complete(id, status: .cancelled, clearsProgress: true)
        }
    }

    private func reviewUnknownUpload(
        _ id: UUID,
        request: MobileUploadRequest,
        service: any MobileTransferServing
    ) async {
        // 上传调用后的取消/网络未知结果绝不自动重传；最多做一次语义回读。
        let review = await Task.detached {
            try? await service.reviewUpload(request)
        }.value
        tasksByID[id]?.mutationResult = review
        complete(id, status: .resultNeedsReview)
    }

    private func complete(
        _ id: UUID,
        status: MobileTransferStatus,
        clearsProgress: Bool = false
    ) {
        tasksByID[id]?.status = status
        if case .upload = requestsByID[id],
           status == .succeeded || status == .resultNeedsReview {
            tasksByID[id]?.retryPolicy = .none
        }
        if clearsProgress {
            tasksByID[id]?.progress = .zero
        }
    }

    private static func failureCategory(for error: Error) -> AppErrorCategory {
        if let error = error as? AppError {
            return error.category
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .localStorageFull
        }
        if error is URLError {
            return .networkUnavailable
        }
        if error is CancellationError {
            return .cancelled
        }
        return .unknown
    }

    private static func canRetryFromBeginning(
        request: MobileTransferRequest,
        status: MobileTransferStatus
    ) -> Bool {
        switch request {
        case .upload:
            status == .cancelledBeforeSubmission
        case .download:
            status == .failed || status == .cancelled || status == .cancelledBeforeSubmission
        }
    }

    private func isCurrentExecution(_ id: UUID, generation: UUID) -> Bool {
        executionGenerationsByID[id] == generation
    }

    private func clearExecution(_ id: UUID, generation: UUID) {
        guard isCurrentExecution(id, generation: generation) else { return }
        executionsByID[id] = nil
        executionGenerationsByID[id] = nil
    }
}
