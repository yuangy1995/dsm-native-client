import Foundation

struct MobileMutationKey: Hashable, Sendable {
    let profileID: UUID
    let operation: String
    let stableTarget: String
}

enum MobileMutationExecution<Value: Sendable>: Sendable {
    case submitted(Value)
    case duplicateInFlight
}

/// 进程内按 profile、操作和稳定目标串行化提交，不持久化，也不重放写请求。
actor MobileMutationCoordinator {
    private var activeKeys: Set<MobileMutationKey> = []

    func perform<Value: Sendable>(
        profileID: UUID,
        operation: String,
        stableTarget: String,
        submission: @Sendable () async throws -> Value
    ) async throws -> MobileMutationExecution<Value> {
        let key = MobileMutationKey(
            profileID: profileID,
            operation: operation,
            stableTarget: stableTarget
        )
        guard activeKeys.insert(key).inserted else {
            return .duplicateInFlight
        }
        defer { activeKeys.remove(key) }
        return .submitted(try await submission())
    }

    func isSubmitting(
        profileID: UUID,
        operation: String,
        stableTarget: String
    ) -> Bool {
        activeKeys.contains(
            MobileMutationKey(
                profileID: profileID,
                operation: operation,
                stableTarget: stableTarget
            )
        )
    }
}
