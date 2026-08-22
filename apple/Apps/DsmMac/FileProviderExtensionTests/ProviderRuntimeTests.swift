import DsmCore
import FileProvider
import Foundation
import XCTest
@testable import DsmFileProviderRuntime

final class ProviderRuntimeTests: XCTestCase {
    func test每次内容下载前都会检查容量() async throws {
        let context = try makeContext()
        let capacity = CapacityProbe(results: [.success, .success])
        let dependencies = context.dependencies(capacity: capacity)
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: dependencies
        )

        let firstResult = try await runtime.fetchContents(
            for: .init("item-1"),
            requestedVersion: nil,
            progress: { _, _ in }
        )
        try FileManager.default.removeItem(at: firstResult.0)
        _ = try await runtime.fetchContents(
            for: .init("item-1"),
            requestedVersion: nil,
            progress: { _, _ in }
        )

        let repositorySnapshot = await context.repository.snapshot()
        let recordedEntryCount = await context.store.recordedEntryCount()
        XCTAssertEqual(capacity.snapshot(), [16, 16])
        XCTAssertEqual(repositorySnapshot.downloadCount, 2)
        XCTAssertEqual(recordedEntryCount, 2)
    }

    func test首次允许后容量下降会取消下载清理Partial且不记录完成项() async throws {
        let context = try makeContext(progressValues: [4, 8, 12])
        let capacity = CapacityProbe(results: [.success, .failure])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: capacity,
                recheckIntervalBytes: 8
            )
        )

        let error = await capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }

        let repositorySnapshot = await context.repository.snapshot()
        let recordedEntryCount = await context.store.recordedEntryCount()
        XCTAssertTrue(error is ProviderRuntimeTestError)
        XCTAssertEqual(capacity.snapshot(), [16, 8])
        XCTAssertEqual(repositorySnapshot.reportedProgressValues, [4, 8])
        XCTAssertEqual(repositorySnapshot.partialCleanupCount, 1)
        XCTAssertEqual(recordedEntryCount, 0)
    }

    func test进度未达到阈值时不会重复读取容量() async throws {
        let context = try makeContext(progressValues: [1, 4, 7, 16])
        let capacity = CapacityProbe(results: [.success, .failure])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: capacity,
                recheckIntervalBytes: 8
            )
        )

        let error = await capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }

        let repositorySnapshot = await context.repository.snapshot()
        let recordedEntryCount = await context.store.recordedEntryCount()
        XCTAssertTrue(error is ProviderRuntimeTestError)
        XCTAssertEqual(capacity.snapshot(), [16, 0])
        XCTAssertEqual(repositorySnapshot.reportedProgressValues, [1, 4, 7, 16])
        XCTAssertEqual(repositorySnapshot.partialCleanupCount, 1)
        XCTAssertEqual(recordedEntryCount, 0)
    }

    func test初始容量不可读时不调用下载并清理Partial() async throws {
        let context = try makeContext()
        let capacity = CapacityProbe(results: [.failure])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(capacity: capacity)
        )

        let error = await capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }

        let repositorySnapshot = await context.repository.snapshot()
        let recordedEntryCount = await context.store.recordedEntryCount()
        XCTAssertTrue(error is ProviderRuntimeTestError)
        XCTAssertEqual(repositorySnapshot.downloadCount, 0)
        XCTAssertEqual(repositorySnapshot.partialCleanupCount, 1)
        XCTAssertEqual(recordedEntryCount, 0)
    }

    func test临时缓存成功释放后才允许开始下载() async throws {
        let oldEntry = cacheEntry(path: "/test/old.bin", kind: .temporary, bytes: 10)
        let context = try makeContext(
            temporaryLimitBytes: 20,
            cacheEntries: [oldEntry]
        )
        let eviction = EvictionProbe(results: [.success])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: .init(results: [.success]),
                eviction: eviction
            )
        )

        _ = try await runtime.fetchContents(
            for: .init("item-1"),
            requestedVersion: nil,
            progress: { _, _ in }
        )

        let repositorySnapshot = await context.repository.snapshot()
        let removedPaths = await context.store.removedPaths()
        XCTAssertEqual(eviction.callCount(), 1)
        XCTAssertEqual(removedPaths, [oldEntry.remotePath])
        XCTAssertEqual(repositorySnapshot.downloadCount, 1)
    }

    func test临时缓存逐项释放失败会拒绝下载() async throws {
        let first = cacheEntry(
            path: "/test/first.bin",
            kind: .temporary,
            bytes: 6,
            date: Date(timeIntervalSince1970: 1)
        )
        let second = cacheEntry(
            path: "/test/second.bin",
            kind: .temporary,
            bytes: 6,
            date: Date(timeIntervalSince1970: 2)
        )
        let context = try makeContext(
            temporaryLimitBytes: 20,
            cacheEntries: [first, second]
        )
        let eviction = EvictionProbe(results: [.success, .failure])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: .init(results: [.success]),
                eviction: eviction
            )
        )

        let error = await capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }

        let repositorySnapshot = await context.repository.snapshot()
        let removedPaths = await context.store.removedPaths()
        XCTAssertTrue(error is ProviderRuntimeTestError)
        XCTAssertEqual(eviction.callCount(), 2)
        XCTAssertEqual(removedPaths, [first.remotePath])
        XCTAssertEqual(repositorySnapshot.downloadCount, 0)
    }

    func test始终离线缓存不参与临时缓存驱逐() async throws {
        let keptEntry = cacheEntry(
            path: "/test/kept.bin",
            kind: .keptOffline,
            bytes: 100
        )
        let context = try makeContext(
            temporaryLimitBytes: 20,
            cacheEntries: [keptEntry]
        )
        let eviction = EvictionProbe(results: [])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: .init(results: [.success]),
                eviction: eviction
            )
        )

        _ = try await runtime.fetchContents(
            for: .init("item-1"),
            requestedVersion: nil,
            progress: { _, _ in }
        )

        let repositorySnapshot = await context.repository.snapshot()
        let removedPaths = await context.store.removedPaths()
        XCTAssertEqual(eviction.callCount(), 0)
        XCTAssertEqual(removedPaths, [])
        XCTAssertEqual(repositorySnapshot.downloadCount, 1)
    }

    func test驱逐后存储记录删除失败会保守拒绝下载() async throws {
        let oldEntry = cacheEntry(path: "/test/old.bin", kind: .temporary, bytes: 10)
        let context = try makeContext(
            temporaryLimitBytes: 20,
            cacheEntries: [oldEntry],
            removeCacheEntriesFails: true
        )
        let eviction = EvictionProbe(results: [.success])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: .init(results: [.success]),
                eviction: eviction
            )
        )

        let error = await capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }

        let repositorySnapshot = await context.repository.snapshot()
        let removedPaths = await context.store.removedPaths()
        XCTAssertTrue(error is ProviderRuntimeTestError)
        XCTAssertEqual(eviction.callCount(), 1)
        XCTAssertEqual(removedPaths, [])
        XCTAssertEqual(repositorySnapshot.downloadCount, 0)
    }

    func test并发临时下载会预留额度并拒绝超限请求() async throws {
        let gate = ProviderDownloadGate()
        let context = try makeContext(
            temporaryLimitBytes: 20,
            downloadGate: gate
        )
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: .init(results: [.success, .success])
            )
        )

        async let firstError: Error? = capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }
        await gate.waitUntilStarted()
        let secondError = await capturedError {
            _ = try await runtime.fetchContents(
                for: .init("item-1"),
                requestedVersion: nil,
                progress: { _, _ in }
            )
        }
        await gate.release()
        let resolvedFirstError = await firstError

        let repositorySnapshot = await context.repository.snapshot()
        XCTAssertNil(resolvedFirstError)
        XCTAssertNotNil(secondError)
        XCTAssertEqual(repositorySnapshot.downloadCount, 1)
    }

    func test完整暂存文件也执行准入且不重复计算同路径记录() async throws {
        let currentEntry = cacheEntry(
            path: "/test/offline.bin",
            kind: .temporary,
            bytes: 16
        )
        let oldEntry = cacheEntry(
            path: "/test/old.bin",
            kind: .temporary,
            bytes: 10,
            date: Date(timeIntervalSince1970: -1)
        )
        let context = try makeContext(
            temporaryLimitBytes: 20,
            cacheEntries: [currentEntry, oldEntry]
        )
        let stagingDirectory = context.directory.appendingPathComponent(
            "LanStashStaging",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let fileName = try XCTUnwrap(
            DesktopDriveStagingIdentity.contentFileName(
                mappingID: context.mapping.id,
                remotePath: currentEntry.remotePath,
                sizeBytes: 16,
                modifiedAt: nil
            )
        )
        try Data(repeating: 1, count: 16).write(
            to: stagingDirectory.appendingPathComponent(fileName)
        )
        let eviction = EvictionProbe(results: [.success])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(
                capacity: .init(results: []),
                eviction: eviction
            )
        )

        _ = try await runtime.fetchContents(
            for: .init("item-1"),
            requestedVersion: nil,
            progress: { _, _ in }
        )

        let repositorySnapshot = await context.repository.snapshot()
        let removedPaths = await context.store.removedPaths()
        XCTAssertEqual(repositorySnapshot.downloadCount, 0)
        XCTAssertEqual(eviction.callCount(), 1)
        XCTAssertEqual(removedPaths, [oldEntry.remotePath])
    }

    func test持久变更日志分页返回更新和删除() async throws {
        let context = try makeContext()
        let first = changeItem(
            profileID: context.mapping.profileID,
            name: "first.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let removed = changeItem(
            profileID: context.mapping.profileID,
            name: "removed.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        await context.repository.setListedItems([first, removed])
        let dependencies = context.dependencies(capacity: .init(results: []))
        let initialRuntime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: dependencies
        )
        let initialAnchor = try await initialRuntime.currentChangeAnchor(
            for: .rootContainer
        )

        let modified = changeItem(
            profileID: context.mapping.profileID,
            name: "first.txt",
            size: 2,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let added = changeItem(
            profileID: context.mapping.profileID,
            name: "added.txt",
            size: 3,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        await context.repository.setListedItems([modified, added])

        // 使用新 runtime 验证变化枚举不依赖 Runtime 局部状态；磁盘重启恢复由专用测试覆盖。
        let resumedRuntime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: dependencies
        )
        var anchor = initialAnchor
        var updateNames: Set<String> = []
        var deletedIdentifiers: Set<String> = []
        var pageCount = 0
        var hasMore = true
        while hasMore {
            let page = try await resumedRuntime.enumerateChanges(
                for: .rootContainer,
                from: anchor,
                limit: 1
            )
            XCTAssertNotEqual(page.nextAnchor, anchor)
            updateNames.formUnion(page.updatedItems.map(\.filename))
            deletedIdentifiers.formUnion(
                page.deletedItemIdentifiers.map(\.rawValue)
            )
            anchor = page.nextAnchor
            hasMore = page.moreComing
            pageCount += 1
        }

        XCTAssertEqual(pageCount, 3)
        XCTAssertEqual(updateNames, [modified.name, added.name])
        XCTAssertEqual(
            deletedIdentifiers,
            [
                try XCTUnwrap(
                    DesktopDriveItemIdentity.identifier(
                        mappingID: context.mapping.id,
                        remotePath: removed.path
                    )
                )
            ]
        )
    }

    func test工作集只读取受跟踪项并与根目录日志分离() async throws {
        let profileID = UUID()
        let cached = changeItem(
            profileID: profileID,
            name: "cached.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let pinned = changeItem(
            profileID: profileID,
            name: "pinned.txt",
            size: 2,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let rootOnly = changeItem(
            profileID: profileID,
            name: "root-only.txt",
            size: 3,
            modifiedAt: Date(timeIntervalSince1970: 3)
        )
        let context = try makeContext(
            cacheEntries: [
                cacheEntry(
                    path: cached.path,
                    kind: .temporary,
                    bytes: 1,
                    date: Date(timeIntervalSince1970: 10)
                )
            ],
            pinnedPaths: [pinned.path],
            listedItems: [rootOnly],
            infoItems: [cached, pinned]
        )
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(capacity: .init(results: []))
        )

        let workingSet = try await runtime.enumerate(
            containerIdentifier: .workingSet,
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(workingSet.items.map(\.filename), [
            pinned.name,
            cached.name,
        ])
        XCTAssertNil(workingSet.nextOffset)
        let afterWorkingSet = await context.repository.snapshot()
        XCTAssertEqual(afterWorkingSet.listedRequestCount, 0)
        XCTAssertEqual(afterWorkingSet.getInfoRequests, [[pinned.path, cached.path]])

        let workingSetAnchor = try await runtime.currentChangeAnchor(
            for: .workingSet
        )
        let rootAnchor = try await runtime.currentChangeAnchor(
            for: .rootContainer
        )
        XCTAssertNotEqual(workingSetAnchor, rootAnchor)
        let afterRoot = await context.repository.snapshot()
        XCTAssertEqual(afterRoot.listedRequestCount, 1)
        XCTAssertTrue(
            afterRoot.getInfoRequests.allSatisfy {
                !$0.contains(rootOnly.path)
            }
        )
    }

    func test重启后从磁盘配置快照恢复变更日志() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderRuntimePersistentJournal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
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
        let initialStore = DesktopDriveConfigurationStore(directoryURL: directory)
        try await initialStore.saveConnection(
            profile: profile,
            capabilities: .init([:])
        )
        try await initialStore.saveMapping(mapping)

        let first = changeItem(
            profileID: profile.id,
            name: "first.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let removed = changeItem(
            profileID: profile.id,
            name: "removed.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        let repository = ProviderRepositoryStub(
            item: first,
            progressValues: [],
            listedItems: [first, removed],
            infoItems: [first, removed]
        )
        let initialRuntime = ProviderRuntime(
            mappingIdentifier: mapping.id.uuidString,
            dependencies: persistedDependencies(
                configurationStore: initialStore,
                directory: directory,
                repository: repository
            )
        )
        let anchor = try await initialRuntime.currentChangeAnchor(
            for: .rootContainer
        )

        let modified = changeItem(
            profileID: profile.id,
            name: "first.txt",
            size: 2,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let added = changeItem(
            profileID: profile.id,
            name: "added.txt",
            size: 3,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        await repository.setListedItems([modified, added])

        // 重建配置 Store 和 Runtime，确保锚点日志来自磁盘快照而非同一 Actor 的内存状态。
        let reopenedStore = DesktopDriveConfigurationStore(directoryURL: directory)
        let resumedRuntime = ProviderRuntime(
            mappingIdentifier: mapping.id.uuidString,
            dependencies: persistedDependencies(
                configurationStore: reopenedStore,
                directory: directory,
                repository: repository
            )
        )
        let page = try await resumedRuntime.enumerateChanges(
            for: .rootContainer,
            from: anchor,
            limit: 10
        )

        XCTAssertEqual(Set(page.updatedItems.map(\.filename)), [
            modified.name,
            added.name,
        ])
        XCTAssertEqual(page.deletedItemIdentifiers.map(\.rawValue), [
            try XCTUnwrap(
                DesktopDriveItemIdentity.identifier(
                    mappingID: mapping.id,
                    remotePath: removed.path
                )
            )
        ])
        XCTAssertFalse(page.moreComing)
    }

    func test被裁剪或格式无效的锚点要求完整重新枚举() async throws {
        let context = try makeContext()
        let first = changeItem(
            profileID: context.mapping.profileID,
            name: "first.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        await context.repository.setListedItems([first])
        let dependencies = context.dependencies(
            capacity: .init(results: []),
            changeJournalMaximumEntries: 1
        )
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: dependencies
        )
        let staleAnchor = try await runtime.currentChangeAnchor(
            for: .rootContainer
        )

        let modified = changeItem(
            profileID: context.mapping.profileID,
            name: "first.txt",
            size: 2,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        let added = changeItem(
            profileID: context.mapping.profileID,
            name: "added.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        await context.repository.setListedItems([modified, added])

        let staleError = await capturedError {
            _ = try await runtime.enumerateChanges(
                for: .rootContainer,
                from: staleAnchor,
                limit: 10
            )
        }
        let malformedError = await capturedError {
            _ = try await runtime.enumerateChanges(
                for: .rootContainer,
                from: Data("not-an-anchor".utf8),
                limit: 10
            )
        }
        let expected = NSFileProviderError(.syncAnchorExpired) as NSError
        for error in [staleError, malformedError] {
            let actual = error as? NSError
            XCTAssertEqual(actual?.domain, expected.domain)
            XCTAssertEqual(actual?.code, expected.code)
        }
    }

    func test枚举器入口转发变更并完成锚点() async throws {
        let context = try makeContext()
        let initial = changeItem(
            profileID: context.mapping.profileID,
            name: "entry.txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
        await context.repository.setListedItems([initial])
        let runtime = ProviderRuntime(
            mappingIdentifier: context.mapping.id.uuidString,
            dependencies: context.dependencies(capacity: .init(results: []))
        )
        let anchor = try await runtime.currentChangeAnchor(for: .rootContainer)
        let updated = changeItem(
            profileID: context.mapping.profileID,
            name: "entry.txt",
            size: 2,
            modifiedAt: Date(timeIntervalSince1970: 2)
        )
        await context.repository.setListedItems([updated])

        let completed = expectation(description: "变化枚举完成")
        let observer = ProviderChangeObserverProbe(completion: completed)
        let enumerator = ProviderEnumerator(
            containerIdentifier: .rootContainer,
            runtime: runtime
        )
        enumerator.enumerateChanges(
            for: observer,
            from: NSFileProviderSyncAnchor(anchor)
        )
        await fulfillment(of: [completed], timeout: 2)

        let snapshot = observer.snapshot()
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.updatedNames, [updated.name])
        XCTAssertFalse(snapshot.moreComing)
        XCTAssertNotEqual(snapshot.anchor, anchor)
    }

    private func makeContext(
        progressValues: [Int64] = [],
        temporaryLimitBytes: Int64 = DesktopDriveCachePolicy
            .defaultTemporaryLimitBytes,
        cacheEntries: [DesktopDriveCacheEntry] = [],
        pinnedPaths: [String] = [],
        removeCacheEntriesFails: Bool = false,
        downloadGate: ProviderDownloadGate? = nil,
        listedItems: [FileItem]? = nil,
        infoItems: [FileItem]? = nil
    ) throws -> ProviderRuntimeTestContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderRuntimeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
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
            scope: .folder(path: "/test"),
            cachePolicy: .init(temporaryLimitBytes: temporaryLimitBytes)
        )
        let configuration = DesktopDriveProviderConfiguration(
            mapping: mapping,
            connection: .init(
                profile: profile,
                capabilities: CapabilitySet([:])
            )
        )
        let file = FileItem(
            profileID: profile.id,
            name: "offline.bin",
            path: "/test/offline.bin",
            kind: .file,
            sizeBytes: 16
        )
        return .init(
            directory: directory,
            mapping: mapping,
            store: ProviderConfigurationStoreStub(
                configuration: configuration,
                remotePath: file.path,
                runtime: .init(
                    state: .available,
                    pinnedPaths: pinnedPaths,
                    cacheEntries: Dictionary(
                        uniqueKeysWithValues: cacheEntries.map {
                            ($0.remotePath, $0)
                        }
                    )
                ),
                removeCacheEntriesFails: removeCacheEntriesFails
            ),
            repository: ProviderRepositoryStub(
                item: file,
                progressValues: progressValues,
                downloadGate: downloadGate,
                listedItems: listedItems ?? [file],
                infoItems: infoItems ?? [file]
            )
        )
    }

    private func cacheEntry(
        path: String,
        kind: DesktopDriveCacheEntryKind,
        bytes: Int64,
        date: Date = Date(timeIntervalSince1970: 0)
    ) -> DesktopDriveCacheEntry {
        .init(
            remotePath: path,
            kind: kind,
            logicalSizeBytes: bytes,
            allocatedSizeBytes: bytes,
            lastAccessedAt: date,
            updatedAt: date
        )
    }

    private func persistedDependencies(
        configurationStore: DesktopDriveConfigurationStore,
        directory: URL,
        repository: ProviderRepositoryStub
    ) -> ProviderRuntimeDependencies {
        .init(
            configurationStore: configurationStore,
            makeRepository: { _ in repository },
            temporaryDirectory: { _ in directory },
            ensureCacheSpace: { _, _ in },
            evictItem: { _, _ in },
            removeItem: { try? FileManager.default.removeItem(at: $0) },
            capacityRecheckIntervalBytes: 1_024,
            changeJournalMaximumEntries: 2_048
        )
    }

    private func changeItem(
        profileID: UUID,
        name: String,
        size: Int64,
        modifiedAt: Date
    ) -> FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: "/test/\(name)",
            kind: .file,
            sizeBytes: size,
            times: .init(
                modifiedAt: modifiedAt,
                createdAt: nil,
                accessedAt: nil
            )
        )
    }
}

private struct ProviderRuntimeTestContext {
    let directory: URL
    let mapping: DesktopDriveMapping
    let store: ProviderConfigurationStoreStub
    let repository: ProviderRepositoryStub

    func dependencies(
        capacity: CapacityProbe,
        eviction: EvictionProbe = .init(results: []),
        recheckIntervalBytes: Int64 = 1_024,
        changeJournalMaximumEntries: Int = 2_048
    ) -> ProviderRuntimeDependencies {
        .init(
            configurationStore: store,
            makeRepository: { _ in repository },
            temporaryDirectory: { _ in directory },
            ensureCacheSpace: { expectedSize, _ in
                try capacity.check(expectedSize: expectedSize)
            },
            evictItem: { identifier, mapping in
                try eviction.evict(identifier: identifier, mapping: mapping)
            },
            removeItem: { try? FileManager.default.removeItem(at: $0) },
            capacityRecheckIntervalBytes: recheckIntervalBytes,
            changeJournalMaximumEntries: changeJournalMaximumEntries
        )
    }
}

private final class ProviderChangeObserverProbe:
    NSObject,
    NSFileProviderChangeObserver,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let completion: XCTestExpectation
    private var storedUpdatedNames: [String] = []
    private var storedDeletedIdentifiers: [String] = []
    private var storedAnchor = Data()
    private var storedMoreComing = false
    private var storedError: Error?

    init(completion: XCTestExpectation) {
        self.completion = completion
    }

    func didUpdate(_ updatedItems: [NSFileProviderItem]) {
        lock.withLock {
            storedUpdatedNames.append(contentsOf: updatedItems.map(\.filename))
        }
    }

    func didDeleteItems(
        withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]
    ) {
        lock.withLock {
            storedDeletedIdentifiers.append(
                contentsOf: deletedItemIdentifiers.map(\.rawValue)
            )
        }
    }

    func finishEnumeratingChanges(
        upTo anchor: NSFileProviderSyncAnchor,
        moreComing: Bool
    ) {
        lock.withLock {
            storedAnchor = anchor.rawValue
            storedMoreComing = moreComing
        }
        completion.fulfill()
    }

    func finishEnumeratingWithError(_ error: Error) {
        lock.withLock {
            storedError = error
        }
        completion.fulfill()
    }

    func snapshot() -> (
        updatedNames: [String],
        deletedIdentifiers: [String],
        anchor: Data,
        moreComing: Bool,
        error: Error?
    ) {
        lock.withLock {
            (
                storedUpdatedNames,
                storedDeletedIdentifiers,
                storedAnchor,
                storedMoreComing,
                storedError
            )
        }
    }
}

private enum ProviderRuntimeTestError: Error {
    case capacityUnavailable
    case evictionFailed
    case storageFailed
}

private final class EvictionProbe: @unchecked Sendable {
    enum Result {
        case success
        case failure
    }

    private let lock = NSLock()
    private var results: [Result]
    private var count = 0

    init(results: [Result]) {
        self.results = results
    }

    func evict(
        identifier: NSFileProviderItemIdentifier,
        mapping: DesktopDriveMapping
    ) throws {
        let result = lock.withLock { () -> Result in
            count += 1
            return results.isEmpty ? .success : results.removeFirst()
        }
        if case .failure = result {
            throw ProviderRuntimeTestError.evictionFailed
        }
    }

    func callCount() -> Int {
        lock.withLock { count }
    }
}

private final class CapacityProbe: @unchecked Sendable {
    enum Result {
        case success
        case failure
    }

    private let lock = NSLock()
    private var results: [Result]
    private var requestedBytes: [Int64?] = []

    init(results: [Result]) {
        self.results = results
    }

    func check(expectedSize: Int64?) throws {
        let result = lock.withLock { () -> Result in
            requestedBytes.append(expectedSize)
            return results.isEmpty ? .success : results.removeFirst()
        }
        if case .failure = result {
            throw ProviderRuntimeTestError.capacityUnavailable
        }
    }

    func snapshot() -> [Int64?] {
        lock.withLock { requestedBytes }
    }
}

private actor ProviderConfigurationStoreStub:
    ProviderRuntimeConfigurationStoring {
    let configurationValue: DesktopDriveProviderConfiguration
    let remotePathValue: String
    private(set) var recordedEntries: [DesktopDriveCacheEntry] = []
    private var runtimeValue: DesktopDriveMappingRuntime
    private var removedPathValues: [String] = []
    private var changeJournals: [String: DesktopDriveChangeJournal] = [:]
    private let removeCacheEntriesFails: Bool

    init(
        configuration: DesktopDriveProviderConfiguration,
        remotePath: String,
        runtime: DesktopDriveMappingRuntime = .init(state: .available),
        removeCacheEntriesFails: Bool = false
    ) {
        configurationValue = configuration
        remotePathValue = remotePath
        runtimeValue = runtime
        self.removeCacheEntriesFails = removeCacheEntriesFails
    }

    func configuration(
        mappingID: UUID
    ) -> DesktopDriveProviderConfiguration? {
        configurationValue.mapping.id == mappingID ? configurationValue : nil
    }

    func runtime(mappingID: UUID) -> DesktopDriveMappingRuntime {
        runtimeValue
    }

    func registerItemPaths(mappingID: UUID, remotePaths: [String]) {}

    func remotePath(mappingID: UUID, itemIdentifier: String) -> String? {
        remotePathValue
    }

    func changeJournalRevision(
        mappingID: UUID,
        containerIdentifier: String
    ) -> DesktopDriveChangeJournalRevision? {
        guard let journal = changeJournals[containerIdentifier], journal.isValid else {
            return nil
        }
        return .init(
            generation: journal.generation,
            revision: journal.currentRevision
        )
    }

    func refreshChangeJournal(
        mappingID: UUID,
        containerIdentifier: String,
        currentItems: [String: FileItem],
        maximumEntryCount: Int,
        expectedRevision: DesktopDriveChangeJournalRevision?
    ) throws -> DesktopDriveChangeJournal {
        let currentRevision = changeJournals[containerIdentifier].flatMap {
            $0.isValid
                ? DesktopDriveChangeJournalRevision(
                    generation: $0.generation,
                    revision: $0.currentRevision
                )
                : nil
        }
        guard currentRevision == expectedRevision else {
            throw DesktopDriveConfigurationStoreError.staleChangeJournal
        }
        var journal: DesktopDriveChangeJournal
        if var existing = changeJournals[containerIdentifier], existing.isValid {
            existing.apply(
                snapshot: currentItems,
                maximumEntryCount: maximumEntryCount
            )
            journal = existing.isValid
                ? existing
                : .init(snapshot: currentItems)
        } else {
            journal = .init(snapshot: currentItems)
        }
        changeJournals[containerIdentifier] = journal
        return journal
    }

    func recordCacheEntry(
        _ entry: DesktopDriveCacheEntry,
        mappingID: UUID
    ) {
        recordedEntries.append(entry)
        runtimeValue.cacheEntries[entry.remotePath] = entry
    }

    func removeCacheEntries(
        remotePaths: [String],
        mappingID: UUID
    ) throws {
        if removeCacheEntriesFails {
            throw ProviderRuntimeTestError.storageFailed
        }
        for path in remotePaths {
            runtimeValue.cacheEntries[path] = nil
            removedPathValues.append(path)
        }
    }

    func isProviderAvailable() -> Bool { true }

    func recordedEntryCount() -> Int { recordedEntries.count }

    func removedPaths() -> [String] { removedPathValues }
}

private actor ProviderRepositoryStub: ProviderRuntimeRepository {
    let item: FileItem
    let progressValues: [Int64]
    let downloadGate: ProviderDownloadGate?
    private var listedItems: [FileItem]
    private var infoItems: [FileItem]
    private var listedRequestCount = 0
    private var getInfoRequests: [[String]] = []
    private(set) var downloadCount = 0
    private(set) var partialCleanupCount = 0
    private(set) var reportedProgressValues: [Int64] = []

    init(
        item: FileItem,
        progressValues: [Int64],
        downloadGate: ProviderDownloadGate? = nil,
        listedItems: [FileItem],
        infoItems: [FileItem]
    ) {
        self.item = item
        self.progressValues = progressValues
        self.downloadGate = downloadGate
        self.listedItems = listedItems
        self.infoItems = infoItems
    }

    func listShares(offset: Int, limit: Int) -> FilePage {
        listedRequestCount += 1
        return page(folderPath: "/", offset: offset, limit: limit)
    }

    func listFolder(path: String, offset: Int, limit: Int) -> FilePage {
        listedRequestCount += 1
        return page(folderPath: path, offset: offset, limit: limit)
    }

    func setListedItems(_ items: [FileItem]) {
        listedItems = items
    }

    private func page(folderPath: String, offset: Int, limit: Int) -> FilePage {
        let safeOffset = min(max(offset, 0), listedItems.count)
        let safeLimit = max(limit, 1)
        let end = min(safeOffset + safeLimit, listedItems.count)
        return .init(
            folderPath: folderPath,
            items: Array(listedItems[safeOffset..<end]),
            offset: safeOffset,
            total: listedItems.count,
            hasMore: end < listedItems.count
        )
    }

    func getInfo(paths: [String]) -> [FileItem] {
        getInfoRequests.append(paths)
        let requested = Set(paths)
        return infoItems.filter { requested.contains($0.path) }
    }

    func download(
        remotePath: String,
        to localURL: URL,
        expectedSize: Int64?,
        progress: @escaping FileTransferProgress
    ) async throws {
        downloadCount += 1
        if let downloadGate {
            await downloadGate.waitBeforeDownload()
        }
        if progressValues.isEmpty {
            try Data(repeating: 1, count: Int(expectedSize ?? 0)).write(to: localURL)
            return
        }
        for value in progressValues {
            reportedProgressValues.append(value)
            progress(value, expectedSize)
            try Task.checkCancellation()
        }
        try Data(repeating: 1, count: Int(expectedSize ?? 0)).write(to: localURL)
    }

    func removePartialDownload(to localURL: URL) {
        partialCleanupCount += 1
    }

    func snapshot() -> (
        downloadCount: Int,
        partialCleanupCount: Int,
        reportedProgressValues: [Int64],
        listedRequestCount: Int,
        getInfoRequests: [[String]]
    ) {
        (
            downloadCount,
            partialCleanupCount,
            reportedProgressValues,
            listedRequestCount,
            getInfoRequests
        )
    }
}

private actor ProviderDownloadGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitBeforeDownload() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private func capturedError(
    _ expression: () async throws -> Void
) async -> Error? {
    do {
        try await expression()
        return nil
    } catch {
        return error
    }
}
