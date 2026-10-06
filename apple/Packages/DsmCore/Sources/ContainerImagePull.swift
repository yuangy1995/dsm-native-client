import CryptoKit
import Foundation

public enum ContainerImagePullStage: String, Codable, Equatable, Sendable {
    case awaitingReceipt, downloading, needsReview, ready, rejected

    public var isTerminal: Bool { self == .ready || self == .rejected }
}

/// 恢复只保留原任务编号和目标摘要；名称、地址与会话不得进入记录。
public struct ContainerImagePullRecovery: Codable, Equatable, Sendable {
    public enum TaskID: Codable, Equatable, Sendable {
        case text(String), integer(Int)
        public var isValid: Bool {
            switch self {
            case .text(let value): !value.isEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
                && value.rangeOfCharacter(from: .controlCharacters) == nil
            case .integer(let value): value >= 0 && value <= 9_007_199_254_740_991
            }
        }
    }
    public let id: UUID
    public let target: String
    public let baselineImageIDs: Set<String>
    public var taskID: TaskID?
    public init(id: UUID, target: String, baselineImageIDs: Set<String>, taskID: TaskID? = nil) {
        self.id = id; self.target = target; self.baselineImageIDs = baselineImageIDs; self.taskID = taskID
    }
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func target(repository: String, tag: String) -> String {
        digest(ContainerImagePullRequest.referenceKey(repository: repository, tag: tag))
    }
    public func matches(repository: String, tag: String) -> Bool { target == Self.target(repository: repository, tag: tag) }
    public var isValid: Bool {
        func digestIsValid(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return digestIsValid(target) && baselineImageIDs.allSatisfy(digestIsValid) && (taskID?.isValid ?? true)
    }
}

public enum ContainerImagePullCheckpoint: Sendable {
    case willSubmit(ContainerImagePullRecovery)
    case accepted(ContainerImagePullRecovery)
    case rejected
}
public typealias ContainerImagePullObserver = @Sendable (ContainerImagePullCheckpoint) async throws -> Void

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
