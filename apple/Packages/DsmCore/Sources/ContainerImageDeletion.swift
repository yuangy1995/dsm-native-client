import Foundation

/// 标签与裸映像分别恢复；原始名称和映像编号只保留于当次确认内存。
public struct ContainerImageDeletionTarget: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let imageID: String
    public let reference: String
    public let isUntagged: Bool

    public init?(_ image: ContainerImage) {
        func stable(_ value: String) -> Bool {
            !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
        guard let source = image.sourceImageID, stable(source), stable(image.repository), stable(image.tag),
              image.id == ContainerImage.selectionID(imageID: source, repository: image.repository, tag: image.tag) else { return nil }
        id = ContainerImagePullRecovery.digest(image.id)
        imageID = ContainerImagePullRecovery.digest(source)
        reference = ContainerImagePullRecovery.target(repository: image.repository, tag: image.tag)
        isUntagged = image.tag == "<none>"
    }
    public var isValid: Bool {
        [id, imageID, reference].allSatisfy { value in
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
    public func matches(_ image: ContainerImage) -> Bool { Self(image) == self }
    public func overlaps(_ other: Self) -> Bool {
        reference == other.reference || ((isUntagged || other.isUntagged) && imageID == other.imageID)
    }
    public func remains(in image: ContainerImage) -> Bool {
        guard let current = Self(image) else { return false }
        return isUntagged ? imageID == current.imageID : reference == current.reference
    }
    public func overlaps(_ pull: ContainerImagePullRecovery) -> Bool {
        reference == pull.target || (isUntagged && pull.baselineImageIDs.contains(imageID))
    }
}

public struct ContainerImageDeletionRequest: Equatable, Sendable {
    public let id: UUID
    public let targets: [ContainerImage]
    public let isConfirmed: Bool
    public init(id: UUID = UUID(), targets: [ContainerImage], isConfirmed: Bool = false) {
        self.id = id; self.targets = targets; self.isConfirmed = isConfirmed
    }
    public var isValid: Bool {
        !targets.isEmpty && targets.allSatisfy { ContainerImageDeletionTarget($0) != nil }
            && Set(targets.map(\.id)).count == targets.count
    }
    public var recovery: ContainerImageDeletionRecovery {
        .init(id: id, targets: targets.compactMap(ContainerImageDeletionTarget.init))
    }
}

public struct ContainerImageDeletionRecovery: Codable, Equatable, Sendable {
    public let id: UUID
    public let targets: [ContainerImageDeletionTarget]
    public init(id: UUID, targets: [ContainerImageDeletionTarget]) { self.id = id; self.targets = targets }
    public var targetIDs: Set<String> { Set(targets.map(\.id)) }
    public var isValid: Bool { !targets.isEmpty && targetIDs.count == targets.count && targets.allSatisfy(\.isValid) }
}

public struct ContainerImageDeletionProgress: Equatable, Sendable {
    public let id: UUID
    public let removedTargetIDs: Set<String>
    public let outcome: MutationResult
    public init(id: UUID, removedTargetIDs: Set<String> = [], outcome: MutationResult) {
        self.id = id; self.removedTargetIDs = removedTargetIDs; self.outcome = outcome
    }
}

public enum ContainerImageDeletionCheckpoint: Sendable {
    case willSubmit(ContainerImageDeletionRecovery)
    case accepted
    case rejected
}
public typealias ContainerImageDeletionObserver = @Sendable (ContainerImageDeletionCheckpoint) async throws -> Void
