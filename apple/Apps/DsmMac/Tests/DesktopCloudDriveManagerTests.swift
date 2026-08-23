import DsmCore
import FileProvider
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class DesktopCloudDriveManagerTests: XCTestCase {
    @available(macOS 15.0, *)
    func test外接缓存卷资格检查使用可注入系统边界() async throws {
        let context = try await makeContext()
        var selectedURLs: [URL] = []
        context.operations.eligibleCacheLocation = { url in
            selectedURLs.append(url)
            return .eligibleVolume(id: "eligible-volume")
        }
        let manager = context.makeManager()
        let selectedURL = URL(fileURLWithPath: "/Volumes/Test")

        let location = try manager.eligibleCacheLocation(
            selectedURL: selectedURL
        )

        XCTAssertEqual(location, .eligibleVolume(id: "eligible-volume"))
        XCTAssertEqual(selectedURLs, [selectedURL])
    }

    func test外接缓存卷断开时不泄露卷标识并显示不可用() async throws {
        let context = try await makeContext()
        let privateIdentifier = "private-volume-identifier"
        var inspectedIdentifiers: [String] = []
        context.operations.mountedVolumeName = { identifier in
            inspectedIdentifiers.append(identifier)
            return nil
        }
        let manager = context.makeManager()
        let mapping = context.mapping.replacing(
            cachePolicy: .init(
                location: .eligibleVolume(id: privateIdentifier)
            )
        )

        let text = manager.cacheLocationText(mapping)

        XCTAssertEqual(inspectedIdentifiers, [privateIdentifier])
        XCTAssertFalse(text.contains(privateIdentifier))
        XCTAssertFalse(text.isEmpty)
    }

    func test再次加载配置失败时保留已显示映射() async throws {
        let context = try await makeContext()
        let manager = context.makeManager()
        await manager.load()
        XCTAssertEqual(manager.mappings.map(\.id), [context.mapping.id])
        try Data("{损坏".utf8).write(
            to: context.directoryURL.appendingPathComponent(
                "desktop-drive-config-v1.json"
            )
        )

        await manager.load()

        XCTAssertEqual(manager.mappings.map(\.id), [context.mapping.id])
        XCTAssertEqual(manager.runtimes[context.mapping.id]?.state, .available)
        XCTAssertTrue(manager.statusIsError)
        XCTAssertEqual(manager.statusSource, .backgroundLoad)
    }

    func test用户操作失败状态可在文件浏览器反馈() async throws {
        let context = try await makeContext(cacheEntryCount: 1)
        let faultStore = ManagerStoreFaultStub(
            base: context.store,
            failRemoveCacheEntries: true
        )
        var evictionCount = 0
        context.operations.evict = { _, _ in evictionCount += 1 }
        let manager = context.makeManager(store: faultStore)
        await manager.load()

        await manager.clearCache(context.mapping)

        XCTAssertEqual(evictionCount, 1)
        XCTAssertTrue(manager.statusIsError)
        XCTAssertEqual(manager.statusSource, .userAction)
    }

    func test清理缓存逐项失败时只移除已释放记录() async throws {
        let context = try await makeContext(cacheEntryCount: 2)
        var evictionCount = 0
        context.operations.evict = { _, _ in
            evictionCount += 1
            if evictionCount == 2 {
                throw ManagerTestError.injected
            }
        }
        let manager = context.makeManager()
        await manager.load()

        await manager.clearCache(context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(evictionCount, 2)
        XCTAssertEqual(runtime.cacheEntries.count, 1)
        XCTAssertTrue(manager.statusIsError)
    }

    func test缓存已释放但记录提交失败时保留记录且不显示成功() async throws {
        let context = try await makeContext(cacheEntryCount: 1)
        let faultStore = ManagerStoreFaultStub(
            base: context.store,
            failRemoveCacheEntries: true
        )
        var evictionCount = 0
        context.operations.evict = { _, _ in evictionCount += 1 }
        let manager = context.makeManager(store: faultStore)
        await manager.load()

        await manager.clearCache(context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(evictionCount, 1)
        XCTAssertEqual(runtime.cacheEntries.count, 1)
        XCTAssertTrue(manager.statusIsError)
    }

    func test缓存上限回收记录提交失败时不会显示更新成功() async throws {
        let context = try await makeContext(cacheEntryCount: 1)
        let faultStore = ManagerStoreFaultStub(
            base: context.store,
            failRemoveCacheEntries: true
        )
        var evictionCount = 0
        context.operations.evict = { _, _ in evictionCount += 1 }
        let manager = context.makeManager(store: faultStore)
        await manager.load()

        await manager.setTemporaryCacheLimit(0, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(evictionCount, 1)
        XCTAssertEqual(runtime.cacheEntries.count, 1)
        XCTAssertTrue(manager.statusIsError)
    }

    func test空间不足时不会发起下载请求() async throws {
        let context = try await makeContext()
        var requestCount = 0
        context.operations.volumeCapacity = { _ in
            .init(name: "测试卷", totalBytes: 10_000, availableBytes: 0)
        }
        context.operations.requestDownload = { _, _ in requestCount += 1 }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([context.file])
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(runtime.state, .insufficientLocalSpace)
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .failed
        )
    }

    func test第二项下载前容量骤降会停止后续请求并恢复固定范围() async throws {
        let context = try await makeContext()
        let files = [
            context.file(path: "/test/first.bin", sizeBytes: 10),
            context.file(path: "/test/second.bin", sizeBytes: 10),
        ]
        var capacityReadCount = 0
        var requestedPaths: [String] = []
        context.operations.volumeCapacity = { _ in
            capacityReadCount += 1
            return .init(
                name: "测试卷",
                totalBytes: 100 * ManagerTestContext.gibibyte,
                availableBytes: capacityReadCount < 4
                    ? 90 * ManagerTestContext.gibibyte
                    : 0
            )
        }
        context.operations.requestDownload = { identifier, _ in
            requestedPaths.append(identifier.rawValue)
        }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline(files)
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(requestedPaths.count, 1)
        XCTAssertEqual(runtime.state, .insufficientLocalSpace)
        XCTAssertEqual(runtime.pinnedPaths, [])
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .failed
        )
        XCTAssertNotNil(
            manager.offlineProgress[context.mapping.id]?.shortageBytes
        )
    }

    func test下载轮询中容量骤降会进入空间不足状态() async throws {
        let context = try await makeContext()
        var capacityReadCount = 0
        var requestCount = 0
        context.operations.volumeCapacity = { _ in
            capacityReadCount += 1
            return .init(
                name: "测试卷",
                totalBytes: 100 * ManagerTestContext.gibibyte,
                availableBytes: capacityReadCount < 4
                    ? 90 * ManagerTestContext.gibibyte
                    : 0
            )
        }
        context.operations.requestDownload = { _, _ in requestCount += 1 }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([context.file])
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(requestCount, 1)
        XCTAssertGreaterThanOrEqual(capacityReadCount, 4)
        XCTAssertEqual(runtime.state, .insufficientLocalSpace)
        XCTAssertEqual(runtime.pinnedPaths, [])
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .failed
        )
    }

    func test卷容量读取失败会设置明确空间不足状态与进度() async throws {
        let context = try await makeContext()
        var requestCount = 0
        context.operations.volumeCapacity = { _ in
            throw ManagerTestError.injected
        }
        context.operations.requestDownload = { _, _ in requestCount += 1 }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([context.file])
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        let progress = manager.offlineProgress[context.mapping.id]
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(runtime.state, .insufficientLocalSpace)
        XCTAssertEqual(progress?.phase, .failed)
        XCTAssertEqual(progress?.totalFiles, 1)
        XCTAssertEqual(progress?.totalBytes, 10)
        XCTAssertNil(progress?.availableBytes)
        XCTAssertNil(progress?.shortageBytes)
    }

    func test容量复查会扣除已完成字节且不重复请求() async throws {
        let context = try await makeContext()
        let completedFile = context.file(
            path: "/test/completed.bin",
            sizeBytes: 8 * ManagerTestContext.gibibyte
        )
        let pendingFile = context.file(
            path: "/test/pending.bin",
            sizeBytes: 2 * ManagerTestContext.gibibyte
        )
        try await context.store.recordCacheEntry(
            .init(
                remotePath: completedFile.path,
                kind: .keptOffline,
                logicalSizeBytes: completedFile.sizeBytes ?? 0,
                allocatedSizeBytes: completedFile.sizeBytes ?? 0
            ),
            mappingID: context.mapping.id
        )
        var requestCount = 0
        context.operations.volumeCapacity = { _ in
            .init(
                name: "测试卷",
                totalBytes: 100 * ManagerTestContext.gibibyte,
                availableBytes: 10 * ManagerTestContext.gibibyte
            )
        }
        context.operations.requestDownload = { _, _ in
            requestCount += 1
            try await context.store.recordCacheEntry(
                .init(
                    remotePath: pendingFile.path,
                    kind: .keptOffline,
                    logicalSizeBytes: pendingFile.sizeBytes ?? 0,
                    allocatedSizeBytes: pendingFile.sizeBytes ?? 0
                ),
                mappingID: context.mapping.id
            )
        }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([completedFile, pendingFile])
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(runtime.state, .available)
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.completedBytes,
            10 * ManagerTestContext.gibibyte
        )
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .completed
        )
    }

    func test启动重连失败时映射进入离线状态() async throws {
        let context = try await makeContext()
        context.operations.reconnect = { _ in
            throw ManagerTestError.injected
        }
        let manager = context.makeManager()

        await manager.load()

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(runtime.state, .offline)
        XCTAssertEqual(manager.runtimes[context.mapping.id]?.state, .offline)
    }

    func test暂停本地提交失败时会补偿重连且不显示成功() async throws {
        let context = try await makeContext()
        let faultStore = ManagerStoreFaultStub(
            base: context.store,
            failSetMappingPaused: true
        )
        var disconnectCount = 0
        var reconnectCount = 0
        context.operations.disconnect = { _, _ in disconnectCount += 1 }
        context.operations.reconnect = { _ in reconnectCount += 1 }
        let manager = context.makeManager(store: faultStore)
        await manager.load()
        reconnectCount = 0

        await manager.pause(context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(reconnectCount, 1)
        XCTAssertEqual(runtime.state, .available)
        XCTAssertFalse(runtime.isManuallyPaused)
        XCTAssertTrue(manager.statusIsError)
    }

    func test恢复本地提交失败时会重新断开并保持暂停状态() async throws {
        let context = try await makeContext()
        try await context.store.setMappingPaused(
            true,
            mappingID: context.mapping.id
        )
        let faultStore = ManagerStoreFaultStub(
            base: context.store,
            failSetMappingPaused: true
        )
        var disconnectCount = 0
        var reconnectCount = 0
        context.operations.disconnect = { _, _ in disconnectCount += 1 }
        context.operations.reconnect = { _ in reconnectCount += 1 }
        let manager = context.makeManager(store: faultStore)
        await manager.load()
        disconnectCount = 0
        reconnectCount = 0

        await manager.resume(context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(reconnectCount, 1)
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(runtime.state, .paused)
        XCTAssertTrue(runtime.isManuallyPaused)
        XCTAssertTrue(manager.statusIsError)
    }

    func test释放离线范围通知失败时恢复原固定范围() async throws {
        let context = try await makeContext()
        try await context.store.saveRuntime(
            .init(
                state: .available,
                pinnedPaths: ["/test"],
                cacheEntries: [
                    "/test/offline.bin": .init(
                        remotePath: "/test/offline.bin",
                        kind: .keptOffline,
                        logicalSizeBytes: 10,
                        allocatedSizeBytes: 10
                    ),
                ]
            ),
            mappingID: context.mapping.id
        )
        var signalCount = 0
        context.operations.signalRoot = { _ in
            signalCount += 1
            if signalCount == 1 {
                throw ManagerTestError.injected
            }
        }
        let manager = context.makeManager()
        await manager.load()

        await manager.releaseOffline(context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(signalCount, 2)
        XCTAssertEqual(runtime.pinnedPaths, ["/test"])
        XCTAssertNotNil(runtime.cacheEntries["/test/offline.bin"])
        XCTAssertTrue(manager.statusIsError)
    }

    func test下载请求失败时进入降级状态() async throws {
        let context = try await makeContext()
        var requestCount = 0
        context.operations.requestDownload = { _, _ in
            requestCount += 1
            throw ManagerTestError.injected
        }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([context.file])
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(runtime.state, .degraded)
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .failed
        )
    }

    func test下载长时间无进展会确定性超时并进入降级状态() async throws {
        let context = try await makeContext()
        var timestamp = Date(timeIntervalSince1970: 0)
        context.operations.now = {
            defer { timestamp.addTimeInterval(601) }
            return timestamp
        }
        context.operations.requestDownload = { _, _ in }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([context.file])
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(runtime.state, .degraded)
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .failed
        )
        XCTAssertTrue(manager.statusIsError)
    }

    func test取消下载会停止请求并恢复原有固定范围() async throws {
        let context = try await makeContext()
        let request = ManagerDownloadRequestProbe()
        context.operations.requestDownload = { _, _ in
            await request.markStarted()
            try await Task.sleep(for: .seconds(60))
        }
        let manager = context.makeManager()
        await manager.load()

        manager.keepOffline([context.file])
        await request.waitUntilStarted()
        manager.cancelOffline(context.mapping)
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(runtime.state, .available)
        XCTAssertEqual(runtime.pinnedPaths, [])
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .cancelled
        )
    }

    func test取消时固定范围回滚失败不会误报取消成功() async throws {
        let context = try await makeContext()
        let faultStore = ManagerStoreFaultStub(
            base: context.store,
            failSetPinnedPathsCall: 2
        )
        let request = ManagerDownloadRequestProbe()
        context.operations.requestDownload = { _, _ in
            await request.markStarted()
            try await Task.sleep(for: .seconds(60))
        }
        let manager = context.makeManager(store: faultStore)
        await manager.load()

        manager.keepOffline([context.file])
        await request.waitUntilStarted()
        manager.cancelOffline(context.mapping)
        await waitUntilFinished(manager, mapping: context.mapping)

        let runtime = try await context.store.runtime(
            mappingID: context.mapping.id
        )
        XCTAssertEqual(runtime.pinnedPaths, [context.file.path])
        XCTAssertEqual(runtime.state, .checking)
        XCTAssertEqual(
            manager.offlineProgress[context.mapping.id]?.phase,
            .failed
        )
        XCTAssertTrue(manager.statusIsError)
    }

    private func waitUntilFinished(
        _ manager: DesktopCloudDriveManager,
        mapping: DesktopDriveMapping
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while manager.isKeepingOffline(mapping), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(manager.isKeepingOffline(mapping))
    }

    private func makeContext(
        cacheEntryCount: Int = 0
    ) async throws -> ManagerTestContext {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let profile = try NasProfile(
            id: UUID(),
            displayName: "测试 NAS",
            host: "nas.invalid",
            port: 5_001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "测试映射",
            scope: .folder(path: "/test")
        )
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        try await store.saveConnection(
            profile: profile,
            capabilities: CapabilitySet([:])
        )
        try await store.saveMapping(mapping)
        try await store.setMappingState(.available, mappingID: mapping.id)
        if cacheEntryCount > 0 {
            let entries = Dictionary(uniqueKeysWithValues: (0..<cacheEntryCount).map {
                index in
                let path = "/test/cache-\(index).bin"
                return (
                    path,
                    DesktopDriveCacheEntry(
                        remotePath: path,
                        kind: .temporary,
                        logicalSizeBytes: 10,
                        allocatedSizeBytes: 10
                    )
                )
            })
            try await store.saveRuntime(
                .init(state: .available, cacheEntries: entries),
                mappingID: mapping.id
            )
        }
        let repository = ManagerFileRepositoryStub(profileID: profile.id)
        let domain = ManagerDomainControllerStub(
            registeredIdentifiers: [mapping.id.uuidString]
        )
        return ManagerTestContext(
            directoryURL: directoryURL,
            profile: profile,
            mapping: mapping,
            store: store,
            repository: repository,
            domain: domain,
            operations: .testDefaults()
        )
    }
}

@MainActor
private final class ManagerTestContext {
    static let gibibyte: Int64 = 1_024 * 1_024 * 1_024

    let directoryURL: URL
    let profile: NasProfile
    let mapping: DesktopDriveMapping
    let store: DesktopDriveConfigurationStore
    let repository: ManagerFileRepositoryStub
    let domain: ManagerDomainControllerStub
    var operations: DesktopDriveSystemOperations

    var file: FileItem {
        file(path: "/test/offline.bin", sizeBytes: 10)
    }

    func file(path: String, sizeBytes: Int64) -> FileItem {
        FileItem(
            profileID: profile.id,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            kind: .file,
            sizeBytes: sizeBytes
        )
    }

    init(
        directoryURL: URL,
        profile: NasProfile,
        mapping: DesktopDriveMapping,
        store: DesktopDriveConfigurationStore,
        repository: ManagerFileRepositoryStub,
        domain: ManagerDomainControllerStub,
        operations: DesktopDriveSystemOperations
    ) {
        self.directoryURL = directoryURL
        self.profile = profile
        self.mapping = mapping
        self.store = store
        self.repository = repository
        self.domain = domain
        self.operations = operations
    }

    func makeManager(
        store overrideStore: (any DesktopDriveManagerStoring)? = nil
    ) -> DesktopCloudDriveManager {
        DesktopCloudDriveManager(
            profile: profile,
            repository: repository,
            store: overrideStore ?? store,
            sessionBridge: ManagerSessionBridgeStub(),
            isAvailable: true,
            domainController: domain,
            systemOperations: operations
        )
    }
}

private actor ManagerStoreFaultStub: DesktopDriveManagerStoring {
    private let base: DesktopDriveConfigurationStore
    private let failRemoveCacheEntries: Bool
    private let failSetMappingPaused: Bool
    private let failSetPinnedPathsCall: Int?
    private var setPinnedPathsCallCount = 0

    init(
        base: DesktopDriveConfigurationStore,
        failRemoveCacheEntries: Bool = false,
        failSetMappingPaused: Bool = false,
        failSetPinnedPathsCall: Int? = nil
    ) {
        self.base = base
        self.failRemoveCacheEntries = failRemoveCacheEntries
        self.failSetMappingPaused = failSetMappingPaused
        self.failSetPinnedPathsCall = failSetPinnedPathsCall
    }

    func setProviderAvailable(_ isAvailable: Bool) async throws {
        try await base.setProviderAvailable(isAvailable)
    }

    func saveMapping(_ mapping: DesktopDriveMapping) async throws {
        try await base.saveMapping(mapping)
    }

    func removeMapping(id: UUID) async throws {
        try await base.removeMapping(id: id)
    }

    func mappings(profileID: UUID?) async throws -> [DesktopDriveMapping] {
        try await base.mappings(profileID: profileID)
    }

    func runtime(mappingID: UUID) async throws -> DesktopDriveMappingRuntime {
        try await base.runtime(mappingID: mappingID)
    }

    func setMappingState(
        _ state: DesktopDriveMappingState,
        mappingID: UUID,
        successfulCheckAt: Date?
    ) async throws {
        try await base.setMappingState(
            state,
            mappingID: mappingID,
            successfulCheckAt: successfulCheckAt
        )
    }

    func pendingSessionRemovalProfileIDs() async throws -> Set<UUID> {
        try await base.pendingSessionRemovalProfileIDs()
    }

    func setSessionRemovalPending(
        _ isPending: Bool,
        profileID: UUID
    ) async throws {
        try await base.setSessionRemovalPending(isPending, profileID: profileID)
    }

    func registerItemPaths(
        mappingID: UUID,
        remotePaths: [String]
    ) async throws {
        try await base.registerItemPaths(
            mappingID: mappingID,
            remotePaths: remotePaths
        )
    }

    func setPinnedPaths(_ paths: [String], mappingID: UUID) async throws {
        setPinnedPathsCallCount += 1
        if setPinnedPathsCallCount == failSetPinnedPathsCall {
            throw ManagerTestError.injected
        }
        try await base.setPinnedPaths(paths, mappingID: mappingID)
    }

    func removeCacheEntries(
        remotePaths: [String],
        mappingID: UUID
    ) async throws {
        if failRemoveCacheEntries {
            throw ManagerTestError.injected
        }
        try await base.removeCacheEntries(
            remotePaths: remotePaths,
            mappingID: mappingID
        )
    }

    func setMappingPaused(_ isPaused: Bool, mappingID: UUID) async throws {
        if failSetMappingPaused {
            throw ManagerTestError.injected
        }
        try await base.setMappingPaused(isPaused, mappingID: mappingID)
    }

    func completeRuntimeRecovery(
        mappingID: UUID,
        successfulCheckAt: Date
    ) async throws {
        try await base.completeRuntimeRecovery(
            mappingID: mappingID,
            successfulCheckAt: successfulCheckAt
        )
    }
}

private extension DesktopDriveSystemOperations {
    static func testDefaults() -> Self {
        .init(
            hasDomain: { _ in true },
            userVisibleURL: { _ in URL(fileURLWithPath: "/tmp") },
            reveal: { _ in },
            evict: { _, _ in },
            requestDownload: { _, _ in },
            signalRoot: { _ in },
            disconnect: { _, _ in },
            reconnect: { _ in },
            eligibleCacheLocation: { _ in
                .eligibleVolume(id: "test-volume")
            },
            mountedVolumeName: { _ in "测试卷" },
            volumeCapacity: { _ in
                .init(
                    name: "测试卷",
                    totalBytes: 100 * 1_024 * 1_024 * 1_024,
                    availableBytes: 90 * 1_024 * 1_024 * 1_024
                )
            },
            now: Date.init,
            waitForProgress: { await Task.yield() }
        )
    }
}

private enum ManagerTestError: Error {
    case injected
}

private actor ManagerDownloadRequestProbe {
    private var started = false

    func markStarted() {
        started = true
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }
}

private actor ManagerSessionBridgeStub: DesktopDriveSessionBridging {
    func publish() {}
    func remove() {}
}

@MainActor
private final class ManagerDomainControllerStub:
    DesktopDriveDomainRegistrationControlling {
    private var identifiers: Set<String>

    init(registeredIdentifiers: Set<String>) {
        identifiers = registeredIdentifiers
    }

    func domain(for mapping: DesktopDriveMapping) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: .init(
                mapping.providerDomainIdentifier ?? mapping.id.uuidString
            ),
            displayName: mapping.displayName
        )
    }

    func domainForCreation(
        _ mapping: DesktopDriveMapping
    ) throws -> NSFileProviderDomain {
        domain(for: mapping)
    }

    func add(_ domain: NSFileProviderDomain) {
        identifiers.insert(domain.identifier.rawValue)
    }

    func remove(_ domain: NSFileProviderDomain) {
        identifiers.remove(domain.identifier.rawValue)
    }

    func registeredDomainIdentifiers() -> Set<String> {
        identifiers
    }

    func removeRegisteredDomain(identifier: String) {
        identifiers.remove(identifier)
    }
}

private actor ManagerFileRepositoryStub: FileRepository {
    let profileID: UUID
    let allowsVerifiedRestore = false
    let allowsRemoteMountManagement = false

    init(profileID: UUID) {
        self.profileID = profileID
    }

    func listShares(offset: Int, limit: Int) -> FilePage {
        emptyPage(path: "/", offset: offset)
    }

    func listFolder(path: String, offset: Int, limit: Int) -> FilePage {
        emptyPage(path: path, offset: offset)
    }

    func getInfo(paths: [String]) -> [FileItem] {
        paths.map {
            FileItem(
                profileID: profileID,
                name: URL(fileURLWithPath: $0).lastPathComponent,
                path: $0,
                kind: .directory,
                permissions: .init(
                    canRead: true,
                    canWrite: false,
                    canDelete: false,
                    posixMode: nil
                )
            )
        }
    }

    func getThumbnail(path: String, size: ThumbnailSize) throws -> Data {
        throw ManagerTestError.injected
    }

    func checkWritePermission(
        folderPath: String,
        filename: String,
        createOnly: Bool
    ) throws {
        throw ManagerTestError.injected
    }

    func mediaStreamSource(
        remotePath: String,
        fileExtension: String?,
        expectedContentLength: Int64?
    ) throws -> MediaStreamSource {
        throw ManagerTestError.injected
    }

    func download(
        remotePath: String,
        to localURL: URL,
        expectedSize: Int64?,
        progress: @escaping FileTransferProgress
    ) throws {
        throw ManagerTestError.injected
    }

    func downloadArchive(
        remotePaths: [String],
        to localURL: URL,
        progress: @escaping FileTransferProgress
    ) throws {
        throw ManagerTestError.injected
    }

    func removePartialDownload(to localURL: URL) {}

    func upload(
        localURL: URL,
        to folderPath: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) throws {
        throw ManagerTestError.injected
    }

    func delete(
        paths: [String],
        progress: @escaping FileTransferProgress
    ) throws {
        throw ManagerTestError.injected
    }

    func deleteResult(
        paths: [String],
        progress: @escaping FileTransferProgress
    ) throws -> MutationResult {
        throw ManagerTestError.injected
    }

    func createFolder(parentPath: String, name: String) throws {
        throw ManagerTestError.injected
    }

    func copy(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) throws {
        throw ManagerTestError.injected
    }

    func move(
        paths: [String],
        to destinationFolder: String,
        overwrite: Bool,
        progress: @escaping FileTransferProgress
    ) throws {
        throw ManagerTestError.injected
    }

    func search(folderPath: String, query: String) -> [FileItem] { [] }

    func listFavorites() -> [FavoriteLocation] { [] }

    func addFavorite(path: String, name: String) throws {
        throw ManagerTestError.injected
    }

    func addFavoriteResult(
        path: String,
        name: String
    ) throws -> MutationResult {
        throw ManagerTestError.injected
    }

    func removeFavorite(path: String) throws {
        throw ManagerTestError.injected
    }

    func listShareLinks() -> [FileShareLink] { [] }

    func createShareLink(
        paths: [String],
        password: String?,
        expiresAt: String?
    ) throws -> FileShareLink {
        throw ManagerTestError.injected
    }

    func deleteShareLinks(ids: [String]) throws {
        throw ManagerTestError.injected
    }

    private func emptyPage(path: String, offset: Int) -> FilePage {
        FilePage(
            folderPath: path,
            items: [],
            offset: offset,
            total: 0,
            hasMore: false
        )
    }
}
