import DsmCore
import FileProvider
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class DesktopDriveMappingTransactionCoordinatorTests: XCTestCase {
    nonisolated func test系统回调桥接可从后台队列恢复Continuation() async throws {
        let value = try await DesktopDriveAsyncCallbackBridge.value {
            completion in
            DispatchQueue.global().async {
                completion(.success(42))
            }
        }

        XCTAssertEqual(value, 42)
    }

    nonisolated func test系统错误回调桥接可从后台队列抛出() async {
        do {
            try await DesktopDriveAsyncCallbackBridge.void {
                completion in
                DispatchQueue.global().async {
                    completion(TransactionTestError.injected)
                }
            }
            XCTFail("后台错误回调应被转换为 async throw。")
        } catch {
            XCTAssertEqual(error as? TransactionTestError, .injected)
        }
    }

    func test共享会话保存失败时不会写入映射或注册Domain() async {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub(failPublish: true)
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in }
        }

        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(domain.addCallCount, 0)
        XCTAssertTrue(storedMappings.isEmpty)
        XCTAssertEqual(sessionCounts.remove, 1)
    }

    func testDomain注册失败会回滚映射并清理最后一个共享会话() async {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(failAdd: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in }
        }

        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(domain.addCallCount, 1)
        XCTAssertEqual(domain.removeCallCount, 0)
        XCTAssertTrue(storedMappings.isEmpty)
        XCTAssertEqual(sessionCounts.remove, 1)
    }

    func testDomain注册和本地回滚同时失败会保留Removing状态() async {
        let store = TransactionStoreStub(failRemoveMapping: true)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(failAdd: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in }
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(runtime.state, .removing)
        XCTAssertEqual(storedMappings.map(\.id), [mapping.id])
        XCTAssertEqual(sessionCounts.remove, 0)
    }

    func testDomain注册后可读验证失败会移除Domain和映射() async {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in
                throw TransactionTestError.injected
            }
        }

        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(domain.addCallCount, 1)
        XCTAssertEqual(domain.removeCallCount, 1)
        XCTAssertTrue(storedMappings.isEmpty)
        XCTAssertEqual(sessionCounts.remove, 1)
    }

    func testDomain注册后Runtime保存失败会回滚Domain和映射() async {
        let store = TransactionStoreStub(failState: .available)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in }
        }

        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(domain.addCallCount, 1)
        XCTAssertEqual(domain.removeCallCount, 1)
        XCTAssertTrue(storedMappings.isEmpty)
        XCTAssertEqual(sessionCounts.remove, 1)
    }

    func test创建回滚时Domain移除失败会保留Removing状态供清理() async throws {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(failRemove: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in
                throw TransactionTestError.injected
            }
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(domain.removeCallCount, 1)
        XCTAssertEqual(runtime.state, .removing)
        XCTAssertEqual(storedMappings.map(\.id), [mapping.id])
        XCTAssertEqual(sessionCounts.remove, 0)
    }

    func test删除Domain失败会保留Removing状态和映射() async throws {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .available)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(failRemove: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            try await coordinator.remove(self.mapping)
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(runtime.state, .removing)
        XCTAssertEqual(storedMappings.map(\.id), [mapping.id])
        XCTAssertEqual(sessionCounts.remove, 0)
    }

    func test删除本地配置失败会保留Removing状态供下次启动继续() async throws {
        let store = TransactionStoreStub(failRemoveMapping: true)
        await store.seed(mapping, state: .available)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            try await coordinator.remove(self.mapping)
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        let storedMappings = await store.allMappings()
        XCTAssertEqual(domain.removeCallCount, 1)
        XCTAssertEqual(runtime.state, .removing)
        XCTAssertEqual(storedMappings.map(\.id), [mapping.id])
    }

    func test启动时继续清理Removing映射() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .removing)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in }

        let storedMappings = await store.allMappings()
        let sessionCounts = await session.counts()
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(domain.removeCallCount, 1)
        XCTAssertTrue(storedMappings.isEmpty)
        XCTAssertEqual(sessionCounts.remove, 1)
    }

    func test启动时补注册缺失的系统盘Domain并完成Creating状态() async throws {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .preparing)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )
        var verificationCount = 0

        let result = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: []
        ) { _ in
            verificationCount += 1
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(domain.addCallCount, 1)
        XCTAssertEqual(verificationCount, 1)
        XCTAssertEqual(runtime.state, .available)
    }

    func test启动恢复时先更新已注册Domain再执行可读验证() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .preparing)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            throw TransactionTestError.injected
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(runtime.state, .failed)
        XCTAssertEqual(domain.addCallCount, 1)
    }

    func test启动恢复最终提交失败会进入Failed并在下次启动恢复() async {
        let store = TransactionStoreStub(
            stateFailureCounts: [.available: 1]
        )
        await store.seed(mapping, state: .preparing)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )
        var verificationCount = 0

        let firstResult = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            verificationCount += 1
        }
        let failedRuntime = await store.runtime(mappingID: mapping.id)

        XCTAssertEqual(firstResult, .failed)
        XCTAssertEqual(failedRuntime.state, .failed)

        let secondResult = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            verificationCount += 1
        }
        let recoveredRuntime = await store.runtime(mappingID: mapping.id)

        XCTAssertEqual(secondResult, .activated)
        XCTAssertEqual(recoveredRuntime.state, .available)
        XCTAssertEqual(verificationCount, 2)
        XCTAssertEqual(domain.addCallCount, 2)
    }

    func test启动恢复连续状态提交失败仍保留原状态供下次重试() async {
        let store = TransactionStoreStub(
            stateFailureCounts: [.available: 1, .failed: 1]
        )
        await store.seed(mapping, state: .preparing)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )
        var verificationCount = 0

        let firstResult = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: []
        ) { _ in
            verificationCount += 1
        }
        let retainedRuntime = await store.runtime(mappingID: mapping.id)

        XCTAssertEqual(firstResult, .failed)
        XCTAssertEqual(retainedRuntime.state, .preparing)
        XCTAssertEqual(domain.addCallCount, 1)

        let secondResult = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            verificationCount += 1
        }
        let recoveredRuntime = await store.runtime(mappingID: mapping.id)

        XCTAssertEqual(secondResult, .activated)
        XCTAssertEqual(recoveredRuntime.state, .available)
        XCTAssertEqual(verificationCount, 2)
        XCTAssertEqual(domain.addCallCount, 2)
    }

    func testFailed映射在下次启动时会重新验证并恢复可用() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .failed)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )
        var verificationCount = 0

        let result = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            verificationCount += 1
        }

        let runtime = await store.runtime(mappingID: mapping.id)
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(verificationCount, 1)
        XCTAssertEqual(domain.addCallCount, 1)
        XCTAssertEqual(runtime.state, .available)
    }

    func test已注册可用系统Domain启动时刷新属性但不重复验证() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .available)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )
        var verificationCount = 0

        let result = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            verificationCount += 1
        }

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(domain.addCallCount, 1)
        XCTAssertEqual(verificationCount, 0)
    }

    func test运行时损坏标记不会在启动时自动覆盖() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .recoveryRequired)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )
        var verificationCount = 0

        let result = await coordinator.recover(
            mapping,
            registeredDomainIdentifiers: [mapping.id.uuidString]
        ) { _ in
            verificationCount += 1
        }

        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(verificationCount, 0)
        let runtime = await store.runtime(mappingID: mapping.id)
        XCTAssertEqual(runtime.state, .recoveryRequired)
    }

    func test共享会话发布失败时保留映射并要求重新登录() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .available)
        let session = TransactionSessionStub(failPublish: true)
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.restoreSharedSession(
            for: [mapping],
            profileID: mapping.profileID
        )
        let runtime = await store.runtime(mappingID: mapping.id)
        let storedMappings = await store.allMappings()

        XCTAssertEqual(result, .authenticationRequired)
        XCTAssertEqual(runtime.state, .authenticationRequired)
        XCTAssertEqual(storedMappings.map(\.id), [mapping.id])
    }

    func test重新连接先发布共享会话且不提前清除恢复标记() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .recoveryRequired)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.restoreSharedSession(
            for: [mapping],
            profileID: mapping.profileID
        )
        let runtime = await store.runtime(mappingID: mapping.id)
        let sessionCounts = await session.counts()

        XCTAssertEqual(result, .ready)
        XCTAssertEqual(runtime.state, .recoveryRequired)
        XCTAssertEqual(sessionCounts.publish, 1)
    }

    func test只有Removing映射时启动不会重新发布已清理会话() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .removing)
        let session = TransactionSessionStub(failPublish: true)
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.restoreSharedSession(
            for: [mapping],
            profileID: mapping.profileID
        )
        let runtime = await store.runtime(mappingID: mapping.id)
        let sessionCounts = await session.counts()

        XCTAssertEqual(result, .ready)
        XCTAssertEqual(runtime.state, .removing)
        XCTAssertEqual(sessionCounts.publish, 0)
        XCTAssertEqual(sessionCounts.remove, 0)
    }

    func test删除最后映射时会话清理失败仍移除映射并保留待清理标记() async throws {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .available)
        let failingSession = TransactionSessionStub(failRemove: true)
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        let failingCoordinator = makeCoordinator(
            store: store,
            session: failingSession,
            domain: domain
        )

        try await failingCoordinator.remove(mapping)
        let remainingMappingsAfterRemove = await store.allMappings()
        let pendingAfterFailure = await store.pendingSessionRemovalProfileIDs()
        let failingSessionCounts = await failingSession.counts()

        XCTAssertTrue(remainingMappingsAfterRemove.isEmpty)
        XCTAssertTrue(pendingAfterFailure.contains(mapping.profileID))
        XCTAssertEqual(domain.removeCallCount, 1)
        XCTAssertEqual(failingSessionCounts.remove, 1)

        let recoverySession = TransactionSessionStub()
        let recoveryCoordinator = makeCoordinator(
            store: store,
            session: recoverySession,
            domain: domain
        )
        let result = await recoveryCoordinator.restoreSharedSession(
            for: [],
            profileID: mapping.profileID
        )
        let pendingAfterRecovery = await store.pendingSessionRemovalProfileIDs()
        let recoverySessionCounts = await recoverySession.counts()

        XCTAssertEqual(result, .unused)
        XCTAssertFalse(pendingAfterRecovery.contains(mapping.profileID))
        XCTAssertEqual(recoverySessionCounts.remove, 1)
    }

    func test删除Domain失败会保留Removing和待清理标记供下次重试() async {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .available)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(failRemove: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            try await coordinator.remove(self.mapping)
        }
        let removingRuntime = await store.runtime(mappingID: mapping.id)
        let retainedMappings = await store.allMappings()
        let pendingProfileIDs = await store.pendingSessionRemovalProfileIDs()
        let sessionCounts = await session.counts()

        XCTAssertEqual(removingRuntime.state, .removing)
        XCTAssertEqual(retainedMappings.map(\.id), [mapping.id])
        XCTAssertTrue(pendingProfileIDs.contains(mapping.profileID))
        XCTAssertEqual(sessionCounts.remove, 0)
    }

    func test创建回滚会话删除失败会留下配置级待清理标记() async {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub(failRemove: true)
        let domain = TransactionDomainControllerStub(failAdd: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.create(self.mapping) { _ in }
        }

        let storedMappings = await store.allMappings()
        let pendingProfileIDs = await store.pendingSessionRemovalProfileIDs()
        XCTAssertTrue(storedMappings.isEmpty)
        XCTAssertTrue(pendingProfileIDs.contains(mapping.profileID))
    }

    func test空映射启动会续办待清理会话并在成功后清标记() async {
        let store = TransactionStoreStub()
        await store.setSessionRemovalPending(true, profileID: mapping.profileID)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.restoreSharedSession(
            for: [],
            profileID: mapping.profileID
        )
        let pendingProfileIDs = await store.pendingSessionRemovalProfileIDs()
        let sessionCounts = await session.counts()

        XCTAssertEqual(result, .unused)
        XCTAssertFalse(pendingProfileIDs.contains(mapping.profileID))
        XCTAssertEqual(sessionCounts.remove, 1)
    }

    func test空映射启动会话删除失败保留标记供下次重试() async {
        let store = TransactionStoreStub()
        let failingSession = TransactionSessionStub(failRemove: true)
        let domain = TransactionDomainControllerStub()
        let failingCoordinator = makeCoordinator(
            store: store,
            session: failingSession,
            domain: domain
        )

        let firstResult = await failingCoordinator.restoreSharedSession(
            for: [],
            profileID: mapping.profileID
        )
        let pendingAfterFailure = await store.pendingSessionRemovalProfileIDs()
        XCTAssertEqual(firstResult, .cleanupPending)
        XCTAssertTrue(pendingAfterFailure.contains(mapping.profileID))

        let recoverySession = TransactionSessionStub()
        let recoveryCoordinator = makeCoordinator(
            store: store,
            session: recoverySession,
            domain: domain
        )
        let secondResult = await recoveryCoordinator.restoreSharedSession(
            for: [],
            profileID: mapping.profileID
        )
        let pendingAfterRecovery = await store.pendingSessionRemovalProfileIDs()
        let recoveryCounts = await recoverySession.counts()

        XCTAssertEqual(secondResult, .unused)
        XCTAssertFalse(pendingAfterRecovery.contains(mapping.profileID))
        XCTAssertEqual(recoveryCounts.remove, 1)
    }

    func test空映射重复恢复保持幂等且不会遗留标记() async {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let first = await coordinator.restoreSharedSession(
            for: [],
            profileID: mapping.profileID
        )
        let second = await coordinator.restoreSharedSession(
            for: [],
            profileID: mapping.profileID
        )
        let pendingProfileIDs = await store.pendingSessionRemovalProfileIDs()
        let sessionCounts = await session.counts()

        XCTAssertEqual(first, .unused)
        XCTAssertEqual(second, .unused)
        XCTAssertTrue(pendingProfileIDs.isEmpty)
        XCTAssertEqual(sessionCounts.remove, 2)
    }

    func test外接缓存卷Domain缺失时不会错误注册到系统盘() async throws {
        let externalMapping = DesktopDriveMapping(
            id: mapping.id,
            profileID: mapping.profileID,
            displayName: mapping.displayName,
            scope: mapping.scope,
            cachePolicy: .init(
                location: .eligibleVolume(id: "opaque-volume")
            )
        )
        let store = TransactionStoreStub()
        await store.seed(externalMapping, state: .preparing)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub()
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.recover(
            externalMapping,
            registeredDomainIdentifiers: []
        ) { _ in }

        let runtime = await store.runtime(mappingID: mapping.id)
        XCTAssertEqual(result, .needsCacheVolume)
        XCTAssertEqual(domain.addCallCount, 0)
        XCTAssertEqual(runtime.state, .cacheVolumeUnavailable)
    }

    func test外接缓存卷重新出现后恢复可用状态() async {
        let externalMapping = DesktopDriveMapping(
            id: mapping.id,
            profileID: mapping.profileID,
            displayName: mapping.displayName,
            scope: mapping.scope,
            cachePolicy: .init(
                location: .eligibleVolume(id: "opaque-volume")
            ),
            providerDomainIdentifier: "external-domain"
        )
        let store = TransactionStoreStub()
        await store.seed(externalMapping, state: .cacheVolumeUnavailable)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: ["external-domain"]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = await coordinator.recover(
            externalMapping,
            registeredDomainIdentifiers: ["external-domain"]
        ) { _ in }

        let runtime = await store.runtime(mappingID: mapping.id)
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(runtime.state, .available)
        XCTAssertEqual(domain.addCallCount, 0)
    }

    func test启动时只清理没有任何配置对应的孤立Domain() async throws {
        let store = TransactionStoreStub()
        await store.seed(mapping, state: .available)
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            registeredIdentifiers: [
                mapping.id.uuidString,
                "orphan-domain",
            ]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = try await coordinator.removeOrphanedDomains(
            allMappings: [mapping]
        )
        let identifiers = try domain.registeredDomainIdentifiers()

        XCTAssertEqual(
            result,
            .init(removedCount: 1, failureCount: 0)
        )
        XCTAssertEqual(identifiers, [mapping.id.uuidString])
        XCTAssertEqual(domain.removeRegisteredCallCount, 1)
    }

    func test孤立Domain清理失败会保留Domain并报告失败数量() async throws {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(
            failRemove: true,
            registeredIdentifiers: ["orphan-domain"]
        )
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        let result = try await coordinator.removeOrphanedDomains(
            allMappings: []
        )
        let identifiers = try domain.registeredDomainIdentifiers()

        XCTAssertEqual(
            result,
            .init(removedCount: 0, failureCount: 1)
        )
        XCTAssertEqual(identifiers, ["orphan-domain"])
        XCTAssertEqual(domain.removeRegisteredCallCount, 1)
    }

    func testDomain列表读取失败时不会尝试清理任何Domain() async {
        let store = TransactionStoreStub()
        let session = TransactionSessionStub()
        let domain = TransactionDomainControllerStub(failList: true)
        let coordinator = makeCoordinator(
            store: store,
            session: session,
            domain: domain
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.removeOrphanedDomains(allMappings: [])
        }

        XCTAssertEqual(domain.removeRegisteredCallCount, 0)
    }

    private var mapping: DesktopDriveMapping {
        DesktopDriveMapping(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            profileID: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!,
            displayName: "测试映射",
            scope: .folder(path: "/test")
        )
    }

    private func makeCoordinator(
        store: TransactionStoreStub,
        session: TransactionSessionStub,
        domain: TransactionDomainControllerStub
    ) -> DesktopDriveMappingTransactionCoordinator {
        DesktopDriveMappingTransactionCoordinator(
            store: store,
            sessionBridge: session,
            domainController: domain
        )
    }
}

private enum TransactionTestError: Error {
    case injected
}

private actor TransactionSessionStub: DesktopDriveSessionBridging {
    private let failPublish: Bool
    private let failRemove: Bool
    private(set) var publishCallCount = 0
    private(set) var removeCallCount = 0

    init(failPublish: Bool = false, failRemove: Bool = false) {
        self.failPublish = failPublish
        self.failRemove = failRemove
    }

    func publish() throws {
        publishCallCount += 1
        if failPublish {
            throw TransactionTestError.injected
        }
    }

    func remove() throws {
        removeCallCount += 1
        if failRemove {
            throw TransactionTestError.injected
        }
    }

    func counts() -> (publish: Int, remove: Int) {
        (publishCallCount, removeCallCount)
    }
}

private actor TransactionStoreStub:
    DesktopDriveConfigurationTransactionStoring {
    private var mappingsByID: [UUID: DesktopDriveMapping] = [:]
    private var runtimesByID: [UUID: DesktopDriveMappingRuntime] = [:]
    private var pendingSessionRemovalProfileIDsValue: Set<UUID> = []
    private let failRemoveMapping: Bool
    private let failState: DesktopDriveMappingState?
    private var stateFailureCounts: [DesktopDriveMappingState: Int]

    init(
        failRemoveMapping: Bool = false,
        failState: DesktopDriveMappingState? = nil,
        stateFailureCounts: [DesktopDriveMappingState: Int] = [:]
    ) {
        self.failRemoveMapping = failRemoveMapping
        self.failState = failState
        self.stateFailureCounts = stateFailureCounts
    }

    func seed(
        _ mapping: DesktopDriveMapping,
        state: DesktopDriveMappingState
    ) {
        mappingsByID[mapping.id] = mapping
        runtimesByID[mapping.id] = .init(state: state)
    }

    func saveMapping(_ mapping: DesktopDriveMapping) {
        mappingsByID[mapping.id] = mapping
    }

    func removeMapping(id: UUID) throws {
        if failRemoveMapping {
            throw TransactionTestError.injected
        }
        mappingsByID[id] = nil
        runtimesByID[id] = nil
    }

    func mappings(profileID: UUID?) -> [DesktopDriveMapping] {
        mappingsByID.values
            .filter { profileID == nil || $0.profileID == profileID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func runtime(mappingID: UUID) -> DesktopDriveMappingRuntime {
        runtimesByID[mappingID] ?? .init()
    }

    func setMappingState(
        _ state: DesktopDriveMappingState,
        mappingID: UUID,
        successfulCheckAt: Date?
    ) throws {
        if state == failState {
            throw TransactionTestError.injected
        }
        if let remainingCount = stateFailureCounts[state], remainingCount > 0 {
            stateFailureCounts[state] = remainingCount - 1
            throw TransactionTestError.injected
        }
        guard mappingsByID[mappingID] != nil else { return }
        var runtime = runtimesByID[mappingID] ?? .init()
        runtime.state = state
        runtime.lastSuccessfulCheckAt =
            successfulCheckAt ?? runtime.lastSuccessfulCheckAt
        runtimesByID[mappingID] = runtime
    }

    func pendingSessionRemovalProfileIDs() -> Set<UUID> {
        pendingSessionRemovalProfileIDsValue
    }

    func setSessionRemovalPending(
        _ isPending: Bool,
        profileID: UUID
    ) {
        if isPending {
            pendingSessionRemovalProfileIDsValue.insert(profileID)
        } else {
            pendingSessionRemovalProfileIDsValue.remove(profileID)
        }
    }

    func allMappings() -> [DesktopDriveMapping] {
        mappings(profileID: nil)
    }
}

@MainActor
private final class TransactionDomainControllerStub:
    DesktopDriveDomainRegistrationControlling {
    private let failAdd: Bool
    private let failRemove: Bool
    private let failList: Bool
    private var identifiers: Set<String>
    private(set) var addCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var removeRegisteredCallCount = 0

    init(
        failAdd: Bool = false,
        failRemove: Bool = false,
        failList: Bool = false,
        registeredIdentifiers: Set<String> = []
    ) {
        self.failAdd = failAdd
        self.failRemove = failRemove
        self.failList = failList
        identifiers = registeredIdentifiers
    }

    func domain(for mapping: DesktopDriveMapping) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(
                mapping.providerDomainIdentifier ?? mapping.id.uuidString
            ),
            displayName: mapping.displayName
        )
    }

    func domainForCreation(
        _ mapping: DesktopDriveMapping
    ) -> NSFileProviderDomain {
        domain(for: mapping)
    }

    func add(_ domain: NSFileProviderDomain) throws {
        addCallCount += 1
        if failAdd {
            throw TransactionTestError.injected
        }
        identifiers.insert(domain.identifier.rawValue)
    }

    func remove(_ domain: NSFileProviderDomain) throws {
        removeCallCount += 1
        if failRemove {
            throw TransactionTestError.injected
        }
        identifiers.remove(domain.identifier.rawValue)
    }

    func registeredDomainIdentifiers() throws -> Set<String> {
        if failList {
            throw TransactionTestError.injected
        }
        return identifiers
    }

    func removeRegisteredDomain(identifier: String) throws {
        removeRegisteredCallCount += 1
        if failRemove {
            throw TransactionTestError.injected
        }
        identifiers.remove(identifier)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("预期操作抛出错误。", file: file, line: line)
    } catch {}
}
