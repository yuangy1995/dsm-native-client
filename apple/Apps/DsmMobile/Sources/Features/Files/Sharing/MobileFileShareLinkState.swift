import DsmCore
import Foundation

enum MobileFileShareLinkExpiration: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case custom = -1

    var id: Int { rawValue }

    var resourceKey: String {
        switch self {
        case .never: "mobile.files.share-link.expiration.never"
        case .sevenDays: "mobile.files.share-link.expiration.7-days"
        case .thirtyDays: "mobile.files.share-link.expiration.30-days"
        case .ninetyDays: "mobile.files.share-link.expiration.90-days"
        case .custom: "files.sharing.customDate"
        }
    }
}

enum MobileFileShareLinkPhase: Equatable, Sendable {
    case form
    case creating
    case confirmedSuccess
    case reviewRequired
    case confirmedFailure
    case managementLoading
    case managementEmpty
    case managementContent
    case managementError
    case managementUnsupported
    case deletionConfirm
    case deleting
    case deletionConfirmed
    case deletionReviewRequired
    case deletionFailure
    case managing
    case batchResults
}

struct MobileFileShareItemResult: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: MutationResultStatus
    let link: FileShareLink?
}

enum MobileFileShareLinkFailure: Equatable, Sendable {
    case generic
    case permission
    case changed
    case unsupported
    case duplicate
    case recovery
}

enum MobileFileShareLinkDeletionFailure: Equatable, Sendable {
    case generic
    case permission
    case changed
    case unsupported
    case duplicate
    case recovery
}

struct MobileFileSharePresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
}

struct MobileFileShareLinkState: Equatable, Sendable {
    var isPresented = false
    var phase: MobileFileShareLinkPhase = .form
    var target: FileItem?
    var targets: [FileItem] = []
    var password = ""
    var expiration: MobileFileShareLinkExpiration = .never
    var availableOn: Date?
    var customExpiration = Date()
    var isFileRequest = false
    var requestName = ""
    var requestMessage = ""
    var advancedAccess: FileStationAdvancedAccess?
    var itemResults: [MobileFileShareItemResult] = []
    var blockedLinkIDs: Set<String> = []
    var confirmedLink: FileShareLink?
    var failure: MobileFileShareLinkFailure?
    var canRetry = false
    var copied = false
    var sharePresentation: MobileFileSharePresentation?
    var managedLinks: [FileShareLink] = []
    var managedLinkTotal = 0
    var managedLinksTruncated = false
    var pendingDeletion: FileShareLink?
    var deletionFailure: MobileFileShareLinkDeletionFailure?
    var copiedManagedLinkID: String?
}
