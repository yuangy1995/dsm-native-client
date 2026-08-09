import DsmCore
import Foundation

struct FileCopyMovePreparedRequest: Sendable {
    let request: FileCopyMoveRequest
    let sourcePath: String
    let destinationFolderPath: String
    let destinationPath: String
}

enum FileCopyMovePreflight: Sendable {
    case allowed(FileItem)
    case permission
    case conflict
}

enum FileCopyMoveSubmissionFailure: Error, Sendable {
    case network(DsmNetworkError, taskAccepted: Bool)
    case cancelled(taskAccepted: Bool)
    case unexpected(taskAccepted: Bool)
}

struct FileCopyMoveMutationDependencies: Sendable {
    let checkWritePermission: @Sendable (_ folderPath: String, _ filename: String) async throws -> Void
    let submit: @Sendable (
        FileCopyMovePreparedRequest,
        @escaping FileTransferProgress
    ) async throws -> Void
    let readItems: @Sendable ([String]) async throws -> [FileItem]
}

private struct FileCopyMoveReviewKey: Hashable, Sendable {
    let profileID: UUID
    let operation: FileCopyMoveOperation
    let sourcePath: String
    let destinationPath: String
}

private struct PendingFileCopyMoveReview: Sendable {
    let key: FileCopyMoveReviewKey
    let source: FileItem
    let paths: Set<String>
}

private enum FileCopyMoveReadback: Sendable {
    case confirmed(FileItem)
    case mismatch
    case unavailable(AppError?)
}

/// 复制/移动的进程会话协调器；集中维护目标锁、提交边界、独立回读和未知结果阻断。
actor FileCopyMoveMutationCoordinator {
    static let shared = FileCopyMoveMutationCoordinator()

    private var activePathsByKey: [FileCopyMoveReviewKey: Set<String>] = [:]
    private var pendingReviews: [FileCopyMoveReviewKey: PendingFileCopyMoveReview] = [:]

    func perform(
        _ prepared: FileCopyMovePreparedRequest,
        dependencies: FileCopyMoveMutationDependencies,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome {
        let operation = prepared.request.operation.rawValue
        let key = FileCopyMoveReviewKey(
            profileID: prepared.request.profileID,
            operation: prepared.request.operation,
            sourcePath: prepared.sourcePath,
            destinationPath: prepared.destinationPath
        )
        if let review = pendingReviews[key] {
            return try await reviewPending(
                review,
                operation: operation,
                readItems: dependencies.readItems
            )
        }

        let paths = Set([
            prepared.sourcePath,
            prepared.destinationFolderPath,
            prepared.destinationPath,
        ])
        guard !hasOverlap(profileID: prepared.request.profileID, paths: paths) else {
            return try outcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                failed: 1,
                errorCategory: .conflict,
                diagnosticTag: "file-station.copy-move.target-busy",
                prepared: prepared
            )
        }
        activePathsByKey[key] = paths
        defer { activePathsByKey.removeValue(forKey: key) }

        if Task.isCancelled {
            return try outcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                diagnosticTag: "file-station.copy-move.cancelled-before-preflight",
                prepared: prepared
            )
        }

        let observedSource: FileItem
        do {
            switch try await preflight(prepared, dependencies: dependencies) {
            case .allowed(let source):
                observedSource = source
            case .permission:
                return try outcome(
                    status: .permissionDenied,
                    operation: operation,
                    submitted: false,
                    failed: 1,
                    errorCategory: .permission,
                    diagnosticTag: "file-station.copy-move.preflight-rejected",
                    prepared: prepared
                )
            case .conflict:
                return try outcome(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    failed: 1,
                    errorCategory: .conflict,
                    diagnosticTag: "file-station.copy-move.preflight-rejected",
                    prepared: prepared
                )
            }
        } catch {
            return try preflightOutcome(error, operation: operation, prepared: prepared)
        }

        if Task.isCancelled {
            return try outcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                diagnosticTag: "file-station.copy-move.cancelled-after-preflight",
                prepared: prepared
            )
        }

        let review = PendingFileCopyMoveReview(
            key: key,
            source: observedSource,
            paths: paths
        )
        var cancellationRequested = false
        var submissionErrorCategory: MutationErrorCategory?
        var authenticationError: AppError?
        do {
            try await dependencies.submit(prepared, progress)
        } catch let failure as FileCopyMoveSubmissionFailure {
            switch failure {
            case .cancelled(let taskAccepted):
                if taskAccepted {
                    cancellationRequested = true
                } else {
                    return try outcome(
                        status: .cancelledBeforeSubmission,
                        operation: operation,
                        submitted: false,
                        diagnosticTag: "file-station.copy-move.cancelled-before-submit",
                        prepared: prepared
                    )
                }
            case .unexpected(let taskAccepted):
                if taskAccepted {
                    submissionErrorCategory = .unknown
                } else {
                    // 写请求一旦开始，未知异常也不能被当作安全重试。
                    submissionErrorCategory = .unknown
                }
            case .network(let error, let taskAccepted):
                let disposition = classify(error, taskAccepted: taskAccepted)
                switch disposition {
                case .explicit(let result):
                    return try outcome(
                        status: result.status,
                        operation: operation,
                        submitted: result.submitted,
                        failed: 1,
                        errorCategory: result.category,
                        diagnosticTag: result.tag,
                        prepared: prepared
                    )
                case .authentication(let error):
                    if !taskAccepted { throw error }
                    authenticationError = error
                case .review(let category):
                    submissionErrorCategory = category
                case .cancelled:
                    cancellationRequested = true
                }
            }
        } catch is CancellationError {
            // submit 闭包在进入网络调用前会把取消包装成明确提交前取消；裸取消保守视为已开始。
            cancellationRequested = true
        } catch {
            submissionErrorCategory = .unknown
        }

        let readback = await independentReadback(review, readItems: dependencies.readItems)
        if case .confirmed(let item) = readback {
            pendingReviews.removeValue(forKey: key)
            return try outcome(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "file-station.copy-move.confirmed",
                prepared: prepared,
                item: item
            )
        }

        pendingReviews[key] = review
        if let authenticationError { throw authenticationError }
        if case .unavailable(let error) = readback,
           let error,
           error.category == .authenticationRequired || error.category == .otpRequired {
            throw error
        }
        let cancelled = cancellationRequested || Task.isCancelled
        return try outcome(
            status: cancelled ? .cancellationRequestedAfterSubmission : .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            errorCategory: cancelled ? nil : submissionErrorCategory,
            diagnosticTag: "file-station.copy-move.readback-unverified",
            prepared: prepared
        )
    }

    private func preflight(
        _ prepared: FileCopyMovePreparedRequest,
        dependencies: FileCopyMoveMutationDependencies
    ) async throws -> FileCopyMovePreflight {
        let baseline = try await dependencies.readItems([
            prepared.sourcePath,
            prepared.destinationFolderPath,
        ])
        guard let observedSource = baseline.first(where: { $0.path == prepared.sourcePath }),
              observedSource.profileID == prepared.request.profileID,
              hasCanonicalIdentity(observedSource),
              observedSource.kind == .file,
              observedSource.sizeBytes == prepared.request.source.sizeBytes,
              observedSource.times?.modifiedAt == prepared.request.source.times?.modifiedAt,
              !isRemote(observedSource),
              let destinationFolder = baseline.first(where: {
                  $0.path == prepared.destinationFolderPath
              }),
              destinationFolder.profileID == prepared.request.profileID,
              hasCanonicalIdentity(destinationFolder),
              destinationFolder.isDirectory,
              !isRemote(destinationFolder),
              !isRecyclePath(destinationFolder.path) else {
            return .conflict
        }
        if observedSource.permissions?.canRead == false ||
            prepared.request.operation == .move && observedSource.permissions?.canDelete == false ||
            destinationFolder.permissions?.canWrite == false {
            return .permission
        }
        guard try await dependencies.readItems([prepared.destinationPath]).isEmpty else {
            return .conflict
        }
        try await dependencies.checkWritePermission(
            prepared.destinationFolderPath,
            prepared.request.source.name
        )
        return .allowed(observedSource)
    }

    private func reviewPending(
        _ review: PendingFileCopyMoveReview,
        operation: String,
        readItems: @escaping @Sendable ([String]) async throws -> [FileItem]
    ) async throws -> FileCopyMoveOutcome {
        let readback = await independentReadback(review, readItems: readItems)
        switch readback {
        case .confirmed(let item):
            pendingReviews.removeValue(forKey: review.key)
            return try outcome(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "file-station.copy-move.review-confirmed",
                review: review,
                item: item
            )
        case .unavailable(let error):
            if let error,
               error.category == .authenticationRequired || error.category == .otpRequired {
                throw error
            }
            return try pendingOutcome(review, operation: operation)
        case .mismatch:
            return try pendingOutcome(review, operation: operation)
        }
    }

    private func independentReadback(
        _ review: PendingFileCopyMoveReview,
        readItems: @escaping @Sendable ([String]) async throws -> [FileItem]
    ) async -> FileCopyMoveReadback {
        let paths = [review.key.sourcePath, review.key.destinationPath]
        let task = Task { try await readItems(paths) }
        let items: [FileItem]
        do {
            items = try await task.value
        } catch let error as AppError {
            return .unavailable(error)
        } catch {
            return .unavailable(nil)
        }
        guard let destination = items.first(where: {
                  $0.path == review.key.destinationPath && $0.profileID == review.key.profileID
              }),
              hasCanonicalIdentity(destination),
              destination.kind == review.source.kind,
              destination.sizeBytes == review.source.sizeBytes,
              !isRemote(destination) else {
            return .mismatch
        }
        let source = items.first(where: {
            $0.path == review.key.sourcePath && $0.profileID == review.key.profileID
        })
        switch review.key.operation {
        case .copy:
            guard let source,
                  hasCanonicalIdentity(source),
                  source.kind == review.source.kind,
                  source.sizeBytes == review.source.sizeBytes,
                  !isRemote(source) else {
                return .mismatch
            }
        case .move:
            guard source == nil else { return .mismatch }
        }
        return .confirmed(destination)
    }

    private func preflightOutcome(
        _ error: Error,
        operation: String,
        prepared: FileCopyMovePreparedRequest
    ) throws -> FileCopyMoveOutcome {
        if error is CancellationError ||
            (error as? AppError)?.category == .cancelled ||
            Task.isCancelled {
            return try outcome(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                diagnosticTag: "file-station.copy-move.preflight-cancelled",
                prepared: prepared
            )
        }
        guard let mapped = error as? AppError else {
            return try outcome(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                failed: 1,
                errorCategory: .unknown,
                diagnosticTag: "file-station.copy-move.preflight-failed",
                prepared: prepared
            )
        }
        if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
            throw mapped
        }
        return try outcome(
            status: mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
            operation: operation,
            submitted: false,
            failed: 1,
            errorCategory: mutationCategory(mapped.category),
            diagnosticTag: "file-station.copy-move.preflight-failed",
            prepared: prepared
        )
    }

    private enum SubmissionDisposition {
        case explicit((status: MutationResultStatus, submitted: Bool, category: MutationErrorCategory, tag: String))
        case authentication(AppError)
        case review(MutationErrorCategory)
        case cancelled
    }

    private func classify(
        _ error: DsmNetworkError,
        taskAccepted: Bool
    ) -> SubmissionDisposition {
        switch error {
        case .invalidRequest:
            return taskAccepted
                ? .review(.validation)
                : .explicit((.confirmedFailure, false, .validation, "file-station.copy-move.invalid-request"))
        case .api:
            let mapped = DsmErrorMapper.map(error)
            if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
                return .authentication(mapped)
            }
            return taskAccepted
                ? .review(mutationCategory(mapped.category))
                : .explicit((
                    mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
                    true,
                    mutationCategory(mapped.category),
                    "file-station.copy-move.rejected"
                ))
        case .httpStatus(let code, _):
            let mapped = DsmErrorMapper.map(error)
            if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
                return .authentication(mapped)
            }
            if (400..<500).contains(code), !taskAccepted {
                return .explicit((
                    mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
                    true,
                    mutationCategory(mapped.category),
                    "file-station.copy-move.http-rejected"
                ))
            }
            return .review(code >= 500 ? .server : mutationCategory(mapped.category))
        case .cancelled:
            return .cancelled
        case .transport, .responseTooLarge, .invalidResponse:
            return .review(mutationCategory(DsmErrorMapper.map(error).category))
        }
    }

    private func pendingOutcome(
        _ review: PendingFileCopyMoveReview,
        operation: String
    ) throws -> FileCopyMoveOutcome {
        try outcome(
            status: .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            diagnosticTag: "file-station.copy-move.review-pending",
            review: review
        )
    }

    private func outcome(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        prepared: FileCopyMovePreparedRequest,
        item: FileItem? = nil
    ) throws -> FileCopyMoveOutcome {
        try outcome(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            succeeded: succeeded,
            failed: failed,
            unknown: unknown,
            errorCategory: errorCategory,
            diagnosticTag: diagnosticTag,
            sourcePath: prepared.sourcePath,
            destinationPath: prepared.destinationPath,
            item: item
        )
    }

    private func outcome(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        review: PendingFileCopyMoveReview,
        item: FileItem? = nil
    ) throws -> FileCopyMoveOutcome {
        try outcome(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            succeeded: succeeded,
            failed: failed,
            unknown: unknown,
            errorCategory: errorCategory,
            diagnosticTag: diagnosticTag,
            sourcePath: review.key.sourcePath,
            destinationPath: review.key.destinationPath,
            item: item
        )
    }

    private func outcome(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory?,
        diagnosticTag: String,
        sourcePath: String,
        destinationPath: String,
        item: FileItem?
    ) throws -> FileCopyMoveOutcome {
        FileCopyMoveOutcome(
            result: try MutationResult(
                status: status,
                operation: operation,
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: MutationResultCounts(
                    succeeded: succeeded,
                    failed: failed,
                    unknown: unknown
                ),
                errorCategory: errorCategory,
                diagnosticTag: diagnosticTag
            ),
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            item: item
        )
    }

    private func hasOverlap(profileID: UUID, paths: Set<String>) -> Bool {
        let occupied = activePathsByKey.compactMap { key, value in
            key.profileID == profileID ? value : nil
        } + pendingReviews.values.compactMap {
            $0.key.profileID == profileID ? $0.paths : nil
        }
        return occupied.contains { existing in
            existing.contains { lhs in paths.contains { rhs in Self.overlap(lhs, rhs) } }
        }
    }

    private static func overlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private func hasCanonicalIdentity(_ item: FileItem) -> Bool {
        canonicalPath(item.path) == item.path &&
            item.name == item.path.split(separator: "/").last.map(String.init)
    }

    private func canonicalPath(_ value: String) -> String? {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        let canonical = "/" + components.joined(separator: "/")
        guard !components.isEmpty,
              value == canonical,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        return canonical
    }

    private func isRemote(_ item: FileItem) -> Bool {
        guard let type = item.mountPointType?.lowercased(), !type.isEmpty else { return false }
        return type != "normal" && type != "shared_folder"
    }

    private func isRecyclePath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == "#recycle" }
    }

    private func mutationCategory(_ category: AppErrorCategory) -> MutationErrorCategory {
        switch category {
        case .authenticationRequired, .otpRequired: .authentication
        case .permissionDenied: .permission
        case .conflict: .conflict
        case .networkUnavailable, .timeout, .tlsUntrusted, .tlsCertificateChanged: .network
        case .apiUnavailable, .versionUnsupported: .unsupported
        case .invalidResponse, .serverBusy, .remoteStorageFull: .server
        case .notFound, .localStorageFull, .partialFailure, .cancelled, .unknown: .unknown
        }
    }
}
