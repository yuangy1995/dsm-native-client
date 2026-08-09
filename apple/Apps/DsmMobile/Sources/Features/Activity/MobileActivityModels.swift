import DsmCore
import Foundation

enum MobileActivitySource: String, CaseIterable, Sendable {
    case app
    case nas
}

enum MobileTransferDirection: String, CaseIterable, Sendable {
    case upload
    case download
}

enum MobileTransferStatus: String, CaseIterable, Sendable {
    case queued
    case preparing
    case running
    case cancelling
    case succeeded
    case failed
    case cancelledBeforeSubmission
    case cancelled
    case resultNeedsReview

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelledBeforeSubmission, .cancelled, .resultNeedsReview:
            true
        case .queued, .preparing, .running, .cancelling:
            false
        }
    }
}

enum MobileTransferRetryPolicy: String, CaseIterable, Sendable {
    case restartFromBeginning
    case none
}

enum MobileActivityFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case inProgress
    case ended

    func includes(_ task: MobileActivityTask) -> Bool {
        switch self {
        case .all:
            true
        case .inProgress:
            !task.status.isTerminal
        case .ended:
            task.status.isTerminal
        }
    }
}

enum MobileActivityPresentationState: Equatable, Sendable {
    case loading
    case empty
    case filteredEmpty
    case error
    case content

    static func resolve(
        isLoading: Bool,
        hasError: Bool,
        allTasks: [MobileActivityTask],
        visibleTasks: [MobileActivityTask],
        filter: MobileActivityFilter
    ) -> Self {
        if isLoading { return .loading }
        if hasError { return .error }
        if allTasks.isEmpty { return .empty }
        if visibleTasks.isEmpty, filter != .all { return .filteredEmpty }
        return .content
    }
}

struct MobileTransferProgress: Equatable, Sendable {
    var completedBytes: Int64
    var totalBytes: Int64?

    static let zero = MobileTransferProgress(completedBytes: 0, totalBytes: nil)

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct MobileActivityTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let profileID: UUID
    let source: MobileActivitySource
    let direction: MobileTransferDirection
    let stableTarget: String
    var progress: MobileTransferProgress
    var status: MobileTransferStatus
    var retryPolicy: MobileTransferRetryPolicy
    var mutationResult: MutationResult?
    var failureCategory: AppErrorCategory? = nil

    var canCancel: Bool {
        switch status {
        case .queued, .preparing, .running:
            true
        case .cancelling, .succeeded, .failed, .cancelledBeforeSubmission, .cancelled,
             .resultNeedsReview:
            false
        }
    }

    var canRetryFromBeginning: Bool {
        guard retryPolicy == .restartFromBeginning else { return false }
        switch direction {
        case .upload:
            return status == .cancelledBeforeSubmission
        case .download:
            return status == .failed || status == .cancelled || status == .cancelledBeforeSubmission
        }
    }
}

struct MobileUploadRequest: Equatable, Sendable {
    let profileID: UUID
    let localURL: URL
    let folderPath: String
    let overwrite: Bool
    let stableTarget: String
}

struct MobileDownloadRequest: Equatable, Sendable {
    let profileID: UUID
    let remotePath: String
    let temporaryURL: URL
    let stableTarget: String
}

enum MobileTransferRequest: Equatable, Sendable {
    case upload(MobileUploadRequest)
    case download(MobileDownloadRequest)

    var profileID: UUID {
        switch self {
        case .upload(let request): request.profileID
        case .download(let request): request.profileID
        }
    }

    var direction: MobileTransferDirection {
        switch self {
        case .upload: .upload
        case .download: .download
        }
    }

    var stableTarget: String {
        switch self {
        case .upload(let request): request.stableTarget
        case .download(let request): request.stableTarget
        }
    }
}
