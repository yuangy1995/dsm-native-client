import Foundation

enum MobilePhotoImportPhase: Equatable, Sendable {
    case idle
    case preparing
    case queued(taskID: UUID)
    case failed(MobilePhotoImportFailure)
}

enum MobilePhotoImportFailure: Equatable, Sendable {
    case unavailable
    case itemUnavailable
    case preparationFailed
}

struct MobilePhotoImportDestination: Equatable, Sendable {
    let profileID: UUID
    let folderPath: String
    let spaceRootPath: String
}
