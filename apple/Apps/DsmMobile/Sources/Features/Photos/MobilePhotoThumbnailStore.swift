import Foundation

actor MobilePhotoThumbnailStore {
    enum Priority: Sendable {
        case visible
        case prefetch
    }

    private struct CacheEntry: Sendable {
        let data: Data
        var accessSequence: UInt64
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let totalCostLimit: Int
    private let concurrencyLimit: Int
    private var entries: [String: CacheEntry] = [:]
    private var totalCost = 0
    private var accessSequence: UInt64 = 0
    private var activeCount = 0
    private var visibleWaiters: [Waiter] = []
    private var prefetchWaiters: [Waiter] = []
    private var cancelledWaiterIDs: Set<UUID> = []
    private var generation: UInt64 = 0
    private var namespaceGenerations: [String: UInt64] = [:]

    init(totalCostLimit: Int = 32 * 1_024 * 1_024, concurrencyLimit: Int = 4) {
        self.totalCostLimit = max(1, totalCostLimit)
        self.concurrencyLimit = max(1, concurrencyLimit)
    }

    func data(
        for key: String,
        namespace: String? = nil,
        priority: Priority,
        loader: @escaping @Sendable () async throws -> Data
    ) async -> Data? {
        let requestGeneration = generation
        let requestNamespaceGeneration = namespace.map { namespaceGenerations[$0, default: 0] }
        if let cached = cachedData(for: key) { return cached }
        guard await acquire(priority: priority) else { return nil }
        defer { release() }

        guard isCurrent(
            generation: requestGeneration,
            namespace: namespace,
            namespaceGeneration: requestNamespaceGeneration
        ) else { return nil }
        if let cached = cachedData(for: key) { return cached }
        do {
            let data = try await loader()
            try Task.checkCancellation()
            guard isCurrent(
                generation: requestGeneration,
                namespace: namespace,
                namespaceGeneration: requestNamespaceGeneration
            ), !data.isEmpty else { return nil }
            insert(data, for: key)
            return data
        } catch {
            return nil
        }
    }

    func cachedData(for key: String) -> Data? {
        guard var entry = entries[key] else { return nil }
        accessSequence &+= 1
        entry.accessSequence = accessSequence
        entries[key] = entry
        return entry.data
    }

    func removeAll() {
        generation &+= 1
        namespaceGenerations.removeAll(keepingCapacity: false)
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    func removeAll(namespace: String) {
        namespaceGenerations[namespace, default: 0] &+= 1
        let prefix = "\(namespace)|"
        for key in entries.keys where key.hasPrefix(prefix) {
            if let removed = entries.removeValue(forKey: key) {
                totalCost -= removed.data.count
            }
        }
    }

    func cachedItemCount() -> Int { entries.count }

    func cachedCost() -> Int { totalCost }

    func pendingRequestCounts() -> (visible: Int, prefetch: Int) {
        (visibleWaiters.count, prefetchWaiters.count)
    }

    private func acquire(priority: Priority) async -> Bool {
        if Task.isCancelled { return false }
        if activeCount < concurrencyLimit {
            activeCount += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledWaiterIDs.remove(id) != nil || Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                let waiter = Waiter(id: id, continuation: continuation)
                switch priority {
                case .visible:
                    visibleWaiters.append(waiter)
                case .prefetch:
                    prefetchWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = visibleWaiters.firstIndex(where: { $0.id == id }) {
            visibleWaiters.remove(at: index).continuation.resume(returning: false)
            return
        }
        if let index = prefetchWaiters.firstIndex(where: { $0.id == id }) {
            prefetchWaiters.remove(at: index).continuation.resume(returning: false)
            return
        }
        cancelledWaiterIDs.insert(id)
    }

    private func release() {
        if !visibleWaiters.isEmpty {
            visibleWaiters.removeFirst().continuation.resume(returning: true)
            return
        }
        if !prefetchWaiters.isEmpty {
            prefetchWaiters.removeFirst().continuation.resume(returning: true)
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func insert(_ data: Data, for key: String) {
        guard data.count <= totalCostLimit else { return }
        if let replaced = entries[key] {
            totalCost -= replaced.data.count
        }
        accessSequence &+= 1
        entries[key] = CacheEntry(data: data, accessSequence: accessSequence)
        totalCost += data.count

        while totalCost > totalCostLimit,
              let oldest = entries.min(by: { $0.value.accessSequence < $1.value.accessSequence }) {
            entries[oldest.key] = nil
            totalCost -= oldest.value.data.count
        }
    }

    private func isCurrent(
        generation requestGeneration: UInt64,
        namespace: String?,
        namespaceGeneration requestNamespaceGeneration: UInt64?
    ) -> Bool {
        guard requestGeneration == generation else { return false }
        guard let namespace else { return true }
        return requestNamespaceGeneration == namespaceGenerations[namespace, default: 0]
    }
}
