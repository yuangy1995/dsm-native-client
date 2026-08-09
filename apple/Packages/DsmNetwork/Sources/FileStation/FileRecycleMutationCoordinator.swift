import DsmCore
import Foundation

struct FileRecyclePreparedRequest: Sendable {
    let profileID: UUID
    let operation: String
    let source: FileItem
    let sourcePath: String
    let destinationPath: String
}

enum FileRecycleSubmissionFailure: Error, Sendable {
    case network(DsmNetworkError, taskAccepted: Bool)
    case cancelled(taskAccepted: Bool)
    case unexpected(taskAccepted: Bool)
}

struct FileRecycleMutationDependencies: Sendable {
    let submit: @Sendable (
        FileRecyclePreparedRequest,
        @escaping FileTransferProgress
    ) async throws -> Void
    let readItems: @Sendable ([String]) async throws -> [FileItem]
}

private struct FileRecycleReviewKey: Hashable, Sendable {
    let profileID: UUID
    let operation: String
    let sourcePath: String
    let destinationPath: String
}

private struct PendingFileRecycleReview: Sendable {
    let key: FileRecycleReviewKey
    let source: FileItem
    let paths: Set<String>
}

private enum FileRecyclePreflight: Sendable {
    case allowed(FileItem)
    case permission
    case conflict
}

private enum FileRecycleReadback: Sendable {
    case confirmed(FileItem)
    case mismatch
    case unavailable(AppError?)
}

/// 单文件移入回收站的进程会话协调器；只在回读确认 `#recycle` 目标后报告成功。
actor FileRecycleMutationCoordinator {
    static let shared = FileRecycleMutationCoordinator()

    private var activePathsByKey: [FileRecycleReviewKey: Set<String>] = [:]
    private var pendingReviews: [FileRecycleReviewKey: PendingFileRecycleReview] = [:]

    func performMoveToRecycle(
        _ prepared: FileRecyclePreparedRequest,
        dependencies: FileRecycleMutationDependencies,
        progress: @escaping FileTransferProgress
    ) async throws -> FileRecycleMutationOutcome {
        let key = FileRecycleReviewKey(
            profileID: prepared.profileID,
            operation: prepared.operation,
            sourcePath: prepared.sourcePath,
            destinationPath: prepared.destinationPath
        )
        if let review = pendingReviews[key] {
            return try await reviewPending(review, readItems: dependencies.readItems)
        }

        let paths = Set([prepared.sourcePath, prepared.destinationPath])
        guard !hasOverlap(profileID: prepared.profileID, paths: paths) else {
            return try outcome(
                status: .confirmedFailure,
                submitted: false,
                failed: 1,
                errorCategory: .conflict,
                diagnosticTag: "file-station.recycle.move.target-busy",
                prepared: prepared
            )
        }
        activePathsByKey[key] = paths
        defer { activePathsByKey.removeValue(forKey: key) }

        if Task.isCancelled {
            return try outcome(
                status: .cancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "file-station.recycle.move.cancelled-before-preflight",
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
                    submitted: false,
                    failed: 1,
                    errorCategory: .permission,
                    diagnosticTag: "file-station.recycle.move.preflight-rejected",
                    prepared: prepared
                )
            case .conflict:
                return try outcome(
                    status: .confirmedFailure,
                    submitted: false,
                    failed: 1,
                    errorCategory: .conflict,
                    diagnosticTag: "file-station.recycle.move.preflight-rejected",
                    prepared: prepared
                )
            }
        } catch {
            return try preflightOutcome(error, prepared: prepared)
        }

        if Task.isCancelled {
            return try outcome(
                status: .cancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "file-station.recycle.move.cancelled-after-preflight",
                prepared: prepared
            )
        }

        let review = PendingFileRecycleReview(
            key: key,
            source: observedSource,
            paths: paths
        )
        var cancellationRequested = false
        var submissionErrorCategory: MutationErrorCategory?
        var authenticationError: AppError?
        do {
            try await dependencies.submit(prepared, progress)
        } catch let failure as FileRecycleSubmissionFailure {
            switch failure {
            case .cancelled(let taskAccepted):
                if taskAccepted {
                    cancellationRequested = true
                } else {
                    return try outcome(
                        status: .cancelledBeforeSubmission,
                        submitted: false,
                        diagnosticTag: "file-station.recycle.move.cancelled-before-submit",
                        prepared: prepared
                    )
                }
            case .unexpected:
                submissionErrorCategory = .unknown
            case .network(let error, let taskAccepted):
                let disposition = classify(error, taskAccepted: taskAccepted)
                switch disposition {
                case .explicit(let result):
                    return try outcome(
                        status: result.status,
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
            cancellationRequested = true
        } catch {
            submissionErrorCategory = .unknown
        }

        let readback = await independentReadback(review, readItems: dependencies.readItems)
        if case .confirmed(let item) = readback {
            pendingReviews.removeValue(forKey: key)
            return try outcome(
                status: .confirmedSuccess,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "file-station.recycle.move.confirmed",
                review: review,
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
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            errorCategory: cancelled ? nil : submissionErrorCategory,
            diagnosticTag: "file-station.recycle.move.readback-unverified",
            review: review
        )
    }

    private func preflight(
        _ prepared: FileRecyclePreparedRequest,
        dependencies: FileRecycleMutationDependencies
    ) async throws -> FileRecyclePreflight {
        let baseline = try await dependencies.readItems([
            prepared.sourcePath,
            prepared.destinationPath,
        ])
        guard let observedSource = baseline.first(where: { $0.path == prepared.sourcePath }),
              observedSource.profileID == prepared.profileID,
              hasCanonicalIdentity(observedSource),
              observedSource.kind == .file,
              observedSource.sizeBytes == prepared.source.sizeBytes,
              observedSource.times?.modifiedAt == prepared.source.times?.modifiedAt,
              !isRecyclePath(observedSource.path),
              !isRemote(observedSource) else {
            return .conflict
        }
        if observedSource.permissions?.canRead == false ||
            observedSource.permissions?.canDelete == false {
            return .permission
        }
        guard !baseline.contains(where: {
            $0.path == prepared.destinationPath && $0.profileID == prepared.profileID
        }) else {
            return .conflict
        }
        return .allowed(observedSource)
    }

    private func reviewPending(
        _ review: PendingFileRecycleReview,
        readItems: @escaping @Sendable ([String]) async throws -> [FileItem]
    ) async throws -> FileRecycleMutationOutcome {
        let readback = await independentReadback(review, readItems: readItems)
        switch readback {
        case .confirmed(let item):
            pendingReviews.removeValue(forKey: review.key)
            return try outcome(
                status: .confirmedSuccess,
                submitted: true,
                succeeded: 1,
                diagnosticTag: "file-station.recycle.move.review-confirmed",
                review: review,
                item: item
            )
        case .unavailable(let error):
            if let error,
               error.category == .authenticationRequired || error.category == .otpRequired {
                throw error
            }
            return try pendingOutcome(review)
        case .mismatch:
            return try pendingOutcome(review)
        }
    }

    private func independentReadback(
        _ review: PendingFileRecycleReview,
        readItems: @escaping @Sendable ([String]) async throws -> [FileItem]
    ) async -> FileRecycleReadback {
        let task = Task {
            try await readItems([review.key.sourcePath, review.key.destinationPath])
        }
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
              isRecyclePath(destination.path),
              !isRemote(destination) else {
            return .mismatch
        }
        guard !items.contains(where: {
            $0.path == review.key.sourcePath && $0.profileID == review.key.profileID
        }) else {
            return .mismatch
        }
        return .confirmed(destination)
    }

    private func preflightOutcome(
        _ error: Error,
        prepared: FileRecyclePreparedRequest
    ) throws -> FileRecycleMutationOutcome {
        if error is CancellationError ||
            (error as? AppError)?.category == .cancelled ||
            Task.isCancelled {
            return try outcome(
                status: .cancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "file-station.recycle.move.preflight-cancelled",
                prepared: prepared
            )
        }
        guard let mapped = error as? AppError else {
            return try outcome(
                status: .confirmedFailure,
                submitted: false,
                failed: 1,
                errorCategory: .unknown,
                diagnosticTag: "file-station.recycle.move.preflight-failed",
                prepared: prepared
            )
        }
        if mapped.category == .authenticationRequired || mapped.category == .otpRequired {
            throw mapped
        }
        return try outcome(
            status: mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
            submitted: false,
            failed: 1,
            errorCategory: mutationCategory(mapped.category),
            diagnosticTag: "file-station.recycle.move.preflight-failed",
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
                : .explicit((.confirmedFailure, false, .validation, "file-station.recycle.move.invalid-request"))
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
                    "file-station.recycle.move.rejected"
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
                    "file-station.recycle.move.http-rejected"
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
        _ review: PendingFileRecycleReview
    ) throws -> FileRecycleMutationOutcome {
        try outcome(
            status: .submittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            diagnosticTag: "file-station.recycle.move.review-pending",
            review: review
        )
    }

    private func outcome(
        status: MutationResultStatus,
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        prepared: FileRecyclePreparedRequest,
        item: FileItem? = nil
    ) throws -> FileRecycleMutationOutcome {
        try outcome(
            status: status,
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
        submitted: Bool,
        requiresRefresh: Bool = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = nil,
        diagnosticTag: String,
        review: PendingFileRecycleReview,
        item: FileItem? = nil
    ) throws -> FileRecycleMutationOutcome {
        try outcome(
            status: status,
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
    ) throws -> FileRecycleMutationOutcome {
        FileRecycleMutationOutcome(
            result: try MutationResult(
                status: status,
                operation: "moveToRecycle",
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

    private func isRecyclePath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == "#recycle" }
    }

    private func isRemote(_ item: FileItem) -> Bool {
        guard let type = item.mountPointType?.lowercased(), !type.isEmpty else { return false }
        return type != "normal" && type != "shared_folder"
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
