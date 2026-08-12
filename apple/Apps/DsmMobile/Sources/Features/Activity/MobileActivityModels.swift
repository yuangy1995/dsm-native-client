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

enum MobileActivityOperation: String, CaseIterable, Equatable, Sendable {
    case appUpload = "app.upload"
    case appDownload = "app.download"
    case downloadStation = "download-station"
    case fileCopyMove = "file.copy-move"
    case fileDelete = "file.delete"
    case fileCompress = "file.compress"
    case fileExtract = "file.extract"

    var isFileStationTask: Bool {
        switch self {
        case .fileCopyMove, .fileDelete, .fileCompress, .fileExtract: true
        case .appUpload, .appDownload, .downloadStation: false
        }
    }
}

enum MobileTransferStatus: String, CaseIterable, Sendable {
    case queued
    case preparing
    case running
    case paused
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
        case .queued, .preparing, .running, .paused, .cancelling:
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
    var completedItems: Int?
    var totalItems: Int?
    var reportedFraction: Double?

    init(
        completedBytes: Int64,
        totalBytes: Int64?,
        completedItems: Int? = nil,
        totalItems: Int? = nil,
        reportedFraction: Double? = nil
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.reportedFraction = reportedFraction
    }

    static let zero = MobileTransferProgress(completedBytes: 0, totalBytes: nil)

    var fraction: Double? {
        if let totalBytes,
           totalBytes > 0,
           completedBytes > 0 || (completedItems == nil && reportedFraction == nil) {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        if let completedItems, let totalItems, totalItems > 0 {
            return min(1, max(0, Double(completedItems) / Double(totalItems)))
        }
        if let reportedFraction {
            return min(1, max(0, reportedFraction))
        }
        if let totalBytes, totalBytes > 0 {
            return 0
        }
        return nil
    }
}

struct MobileActivityTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let profileID: UUID
    let source: MobileActivitySource
    let sourceIdentifier: String?
    let operation: MobileActivityOperation
    let stableTarget: String
    var progress: MobileTransferProgress
    var status: MobileTransferStatus
    var retryPolicy: MobileTransferRetryPolicy
    var mutationResult: MutationResult?
    var failureCategory: AppErrorCategory? = nil

    var canCancel: Bool {
        guard source == .app else { return false }
        return switch status {
        case .queued, .preparing, .running:
            true
        case .paused, .cancelling, .succeeded, .failed, .cancelledBeforeSubmission, .cancelled,
             .resultNeedsReview:
            false
        }
    }

    var canRetryFromBeginning: Bool {
        guard source == .app else { return false }
        guard retryPolicy == .restartFromBeginning else { return false }
        switch operation {
        case .appUpload:
            return status == .cancelledBeforeSubmission
        case .appDownload:
            return status == .failed || status == .cancelled || status == .cancelledBeforeSubmission
        case .downloadStation, .fileCopyMove, .fileDelete, .fileCompress, .fileExtract:
            return false
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

    var activityOperation: MobileActivityOperation {
        switch self {
        case .upload: .appUpload
        case .download: .appDownload
        }
    }

    var stableTarget: String {
        switch self {
        case .upload(let request): request.stableTarget
        case .download(let request): request.stableTarget
        }
    }
}
