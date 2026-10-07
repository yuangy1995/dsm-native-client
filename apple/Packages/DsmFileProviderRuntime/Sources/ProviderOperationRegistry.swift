import Foundation

final class ProviderOperationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var completedBeforeInsert: Set<UUID> = []

    func insert(_ operation: Task<Void, Never>, id: UUID) {
        lock.lock()
        if completedBeforeInsert.remove(id) == nil {
            operations[id] = operation
        }
        lock.unlock()
    }

    func remove(_ id: UUID) {
        lock.lock()
        if operations.removeValue(forKey: id) == nil {
            completedBeforeInsert.insert(id)
        }
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let pending = Array(operations.values)
        operations.removeAll()
        completedBeforeInsert.removeAll()
        lock.unlock()
        for operation in pending {
            operation.cancel()
        }
    }
}
