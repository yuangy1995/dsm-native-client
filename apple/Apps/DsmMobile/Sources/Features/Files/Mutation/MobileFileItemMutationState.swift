import DsmCore
import Foundation

enum MobileFileItemMutationKind: Equatable, Sendable {
    case createFolder
    case rename
}

enum MobileFileItemMutationPhase: Equatable, Sendable {
    case editing
    case submitting
    case review
}

enum MobileFileItemMutationFeedback: Equatable, Sendable {
    case invalidName
    case unavailable
    case permission
    case conflict
    case authentication
    case unknown
}

struct MobileFileItemMutationPresentation: Equatable, Sendable {
    let kind: MobileFileItemMutationKind
    let profileID: UUID
    let parentPath: String
    let sourceItem: FileItem?
    var name: String
    var phase: MobileFileItemMutationPhase = .editing
    var feedback: MobileFileItemMutationFeedback?
    var requiresNameChange = false

    var destinationPath: String? {
        guard MobileFileItemMutationModel.isValidName(name) else { return nil }
        return parentPath + "/" + name
    }
}

struct MobileFileItemMutationSuccess: Equatable, Sendable {
    let profileID: UUID
    let parentPath: String
    let item: FileItem
}
