@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobilePhotoThumbnailStoreTests: XCTestCase {
    func test调用方取消缩略图会释放槽位且不缓存取消结果() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let first = Task { await store.data(for: "first", priority: .visible) { try await probe.load(name: "first") } }
        await probe.waitUntilFirstIsBlocked()
        first.cancel()
        await probe.releaseFirst()
        let cancelled = await first.value
        let second = await store.data(for: "second", priority: .visible) { try await probe.load(name: "second") }
        let retried = await store.data(for: "first", priority: .visible) { try await probe.load(name: "first") }
        let count = await store.cachedItemCount()
        let names = await probe.startedNames()
        XCTAssertNil(cancelled)
        XCTAssertEqual(second, Data("second".utf8))
        XCTAssertEqual(retried, Data("first".utf8))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(names, ["first", "second", "first"])
    }

    func test缩略图并发峰值受限() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 3)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 30_000_000)

        await withTaskGroup(of: Data?.self) { group in
            for index in 0..<12 {
                group.addTask {
                    await store.data(for: "item-\(index)", priority: .prefetch) {
                        try await probe.load(name: "item-\(index)")
                    }
                }
            }
            for await _ in group {}
        }

        let peak = await probe.peakActiveCount()
        XCTAssertEqual(peak, 3)
    }

    func test可见缩略图优先于已排队的预取() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let first = Task {
            await store.data(for: "first", priority: .prefetch) { try await probe.load(name: "first") }
        }
        await probe.waitUntilFirstIsBlocked()
        let queuedPrefetch = Task {
            await store.data(for: "prefetch", priority: .prefetch) { try await probe.load(name: "prefetch") }
        }
        let visible = Task {
            await store.data(for: "visible", priority: .visible) { try await probe.load(name: "visible") }
        }
        for _ in 0..<100 {
            let pending = await store.pendingRequestCounts()
            if pending.visible == 1, pending.prefetch == 1 { break }
            await Task.yield()
        }
        let pending = await store.pendingRequestCounts()
        XCTAssertEqual(pending.visible, 1)
        XCTAssertEqual(pending.prefetch, 1)
        await probe.releaseFirst()
        _ = await (first.value, queuedPrefetch.value, visible.value)

        let names = await probe.startedNames()
        XCTAssertEqual(names, ["first", "visible", "prefetch"])
    }

    func test缩略图缓存遵守总成本并允许失败重试() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 5, concurrencyLimit: 1)
        let retryProbe = FailingThumbnailProbe()

        let failed = await store.data(for: "retry", priority: .visible) {
            try await retryProbe.load()
        }
        let retried = await store.data(for: "retry", priority: .visible) {
            try await retryProbe.load()
        }
        _ = await store.data(for: "other", priority: .visible) { Data([1, 2, 3, 4]) }

        XCTAssertNil(failed)
        XCTAssertEqual(retried, Data([1, 2, 3, 4]))
        let calls = await retryProbe.callCount()
        let cost = await store.cachedCost()
        let count = await store.cachedItemCount()
        XCTAssertEqual(calls, 2)
        XCTAssertLessThanOrEqual(cost, 5)
        XCTAssertLessThanOrEqual(count, 1)
    }

    func test清理缓存后清理前的迟到加载不会回填() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 1)
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let loading = Task {
            await store.data(for: "late", priority: .visible) {
                try await probe.load(name: "late")
            }
        }
        await probe.waitUntilFirstIsBlocked()

        await store.removeAll()
        await probe.releaseFirst()

        let result = await loading.value
        let cost = await store.cachedCost()
        let count = await store.cachedItemCount()
        XCTAssertNil(result)
        XCTAssertEqual(cost, 0)
        XCTAssertEqual(count, 0)
    }

    func test按Profile清理缩略图保留其他Profile且阻止目标Profile迟到回填() async {
        let store = MobilePhotoThumbnailStore(totalCostLimit: 1_024, concurrencyLimit: 2)
        let firstNamespace = UUID().uuidString
        let secondNamespace = UUID().uuidString
        let probe = ThumbnailLoaderProbe(delayNanoseconds: 0, blocksFirst: true)
        let lateFirst = Task {
            await store.data(
                for: "\(firstNamespace)|late",
                namespace: firstNamespace,
                priority: .visible
            ) {
                try await probe.load(name: "late")
            }
        }
        await probe.waitUntilFirstIsBlocked()
        let secondData = await store.data(
            for: "\(secondNamespace)|kept",
            namespace: secondNamespace,
            priority: .visible
        ) {
            Data("kept".utf8)
        }

        await store.removeAll(namespace: firstNamespace)
        await probe.releaseFirst()

        let lateFirstData = await lateFirst.value
        let cachedSecondData = await store.cachedData(for: "\(secondNamespace)|kept")
        let cachedItemCount = await store.cachedItemCount()
        XCTAssertNil(lateFirstData)
        XCTAssertEqual(secondData, Data("kept".utf8))
        XCTAssertEqual(cachedSecondData, Data("kept".utf8))
        XCTAssertEqual(cachedItemCount, 1)
    }

}

private actor ThumbnailLoaderProbe {
    private let delayNanoseconds: UInt64
    private let blocksFirst: Bool
    private var active = 0
    private var peak = 0
    private var names: [String] = []
    private var firstBlocked = false
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var firstObservers: [CheckedContinuation<Void, Never>] = []

    init(delayNanoseconds: UInt64, blocksFirst: Bool = false) {
        self.delayNanoseconds = delayNanoseconds
        self.blocksFirst = blocksFirst
    }

    func load(name: String) async throws -> Data {
        active += 1
        peak = max(peak, active)
        names.append(name)
        defer { active -= 1 }
        if blocksFirst, names.count == 1 {
            firstBlocked = true
            let observers = firstObservers
            firstObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { firstContinuation = $0 }
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return Data(name.utf8)
    }

    func waitUntilFirstIsBlocked() async {
        guard !firstBlocked else { return }
        await withCheckedContinuation { firstObservers.append($0) }
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func peakActiveCount() -> Int { peak }
    func startedNames() -> [String] { names }
}

private actor FailingThumbnailProbe {
    private var calls = 0

    func load() async throws -> Data {
        calls += 1
        if calls == 1 {
            throw AppError(category: .networkUnavailable, isRetryable: true, safeUserMessage: "测试失败")
        }
        return Data([1, 2, 3, 4])
    }

    func callCount() -> Int { calls }
}
