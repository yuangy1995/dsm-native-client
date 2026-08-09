import DsmCore
import Foundation

enum MobileFilePreviewPhase: Equatable, Sendable {
    case inactive
    case loadingDetails
    case loadingPreview
    case detailsOnly
    case ready
    case failed
    case cancelled
}

enum MobileFilePreviewContent: Equatable, Sendable {
    case none
    case quickLook
    case text(String)
    case emptyText
    case textTooLarge
    case textSizeUnknown
    case textEncodingUnsupported
    case media
}

struct MobileFilePreviewProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64?

    init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.map { max(0, $0) }
    }
}

struct MobileFilePreviewState: Equatable, Sendable {
    var profileID: UUID?
    var selectedItem: FileItem?
    var details: FileItem?
    var previewKind: PreviewKind = .unsupported
    var content: MobileFilePreviewContent = .none
    var phase: MobileFilePreviewPhase = .inactive
    var progress: MobileFilePreviewProgress?
    var artifactURL: URL?
    var detailsFailure: AppErrorCategory?
    var previewFailure: AppErrorCategory?
}
