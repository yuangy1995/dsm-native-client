import DsmCore
import Foundation

enum MobileFileShareLinkExpiration: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }

    var resourceKey: String {
        switch self {
        case .never: "mobile.files.share-link.expiration.never"
        case .sevenDays: "mobile.files.share-link.expiration.7-days"
        case .thirtyDays: "mobile.files.share-link.expiration.30-days"
        case .ninetyDays: "mobile.files.share-link.expiration.90-days"
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
}

enum MobileFileShareLinkFailure: Equatable, Sendable {
    case generic
    case permission
    case changed
    case unsupported
    case duplicate
}

enum MobileFileShareLinkDeletionFailure: Equatable, Sendable {
    case generic
    case permission
    case changed
    case unsupported
    case duplicate
}

struct MobileFileSharePresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
}

struct MobileFileShareLinkState: Equatable, Sendable {
    var isPresented = false
    var phase: MobileFileShareLinkPhase = .form
    var target: FileItem?
    var password = ""
    var expiration: MobileFileShareLinkExpiration = .never
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
