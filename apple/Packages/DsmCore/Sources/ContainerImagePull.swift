import Foundation

public enum ContainerImagePullStage: String, Equatable, Sendable {
    case awaitingReceipt, downloading, needsReview, ready, rejected

    public var isTerminal: Bool { self == .ready || self == .rejected }
}

public struct ContainerImagePullRequest: Equatable, Sendable {
    public let id: UUID
    public let repository: String
    public let tag: String
    public let isConfirmed: Bool

    public init(id: UUID = UUID(), repository: String, tag: String, isConfirmed: Bool = false) {
        self.id = id; self.repository = repository; self.tag = tag; self.isConfirmed = isConfirmed
    }

    public var isValid: Bool {
        Self.isValidTarget(repository: repository, tag: tag)
    }

    public static func isValidTarget(repository: String, tag: String) -> Bool {
        !repository.isEmpty && repository.count <= 500 && !repository.contains("://") && !repository.contains("@") &&
        repository.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil &&
        !tag.isEmpty && tag != "<none>" && tag.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil &&
        !tag.contains("/") && !tag.contains(":") && !tag.contains("@")
    }

    public var referenceKey: String {
        Self.referenceKey(repository: repository, tag: tag)
    }

    public static func referenceKey(repository: String, tag: String) -> String {
        var name = repository
        for prefix in ["docker.io/", "index.docker.io/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)); break
        }
        return "\(name):\(tag)"
    }
}

public struct ContainerImagePullProgress: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let repository: String
    public let tag: String
    public let stage: ContainerImagePullStage
    public let percentage: Double?
    public let outcome: MutationResult

    public init(id: UUID, repository: String, tag: String, stage: ContainerImagePullStage, percentage: Double? = nil, outcome: MutationResult) {
        self.id = id; self.repository = repository; self.tag = tag; self.stage = stage; self.percentage = percentage; self.outcome = outcome
    }

    public var referenceKey: String { ContainerImagePullRequest.referenceKey(repository: repository, tag: tag) }

    public static func awaitingReceipt(for request: ContainerImagePullRequest) throws -> Self {
        try Self(id: request.id, repository: request.repository, tag: request.tag, stage: .awaitingReceipt,
            outcome: MutationResult(status: .submittedButUnverified, operation: "containerImagePull", submitted: true, requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 1)))
    }
}
