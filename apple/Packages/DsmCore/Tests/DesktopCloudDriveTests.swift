import XCTest
@testable import DsmCore

final class DesktopCloudDriveTests: XCTestCase {
    private let gibibyte: Int64 = 1_024 * 1_024 * 1_024

    func test同一NAS的父子目录映射会被识别为重叠() {
        let profileID = UUID()
        let parent = DesktopDriveMapping(
            profileID: profileID,
            displayName: "Parent",
            scope: .folder(path: "/share/projects")
        )
        let child = DesktopDriveMapping(
            profileID: profileID,
            displayName: "Child",
            scope: .folder(path: "//share/projects/design/")
        )

        XCTAssertTrue(parent.overlaps(child))
    }

    func test不同NAS或相邻目录映射不重叠() {
        let first = DesktopDriveMapping(
            profileID: UUID(),
            displayName: "First",
            scope: .folder(path: "/share/project")
        )
        let differentProfile = DesktopDriveMapping(
            profileID: UUID(),
            displayName: "Second",
            scope: .folder(path: "/share/project")
        )
        let sibling = DesktopDriveMapping(
            profileID: first.profileID,
            displayName: "Sibling",
            scope: .folder(path: "/share/project-archive")
        )

        XCTAssertFalse(first.overlaps(differentProfile))
        XCTAssertFalse(first.overlaps(sibling))
    }

    func test全部共享文件夹与同一NAS的任意目录重叠() {
        let profileID = UUID()
        let allShares = DesktopDriveMapping(
            profileID: profileID,
            displayName: "All",
            scope: .allShares
        )
        let folder = DesktopDriveMapping(
            profileID: profileID,
            displayName: "Folder",
            scope: .folder(path: "/share/folder")
        )

        XCTAssertTrue(allShares.overlaps(folder))
    }

    func test空间决策只计算尚未缓存的字节并包含峰值与安全余量() {
        let decision = DesktopDriveCacheSpaceCalculator.evaluate(
            candidates: [
                .init(sizeBytes: 8 * gibibyte, locallyAvailableBytes: 3 * gibibyte),
                .init(sizeBytes: 2 * gibibyte, locallyAvailableBytes: 2 * gibibyte),
            ],
            volumeCapacityBytes: 100 * gibibyte,
            availableCapacityBytes: 20 * gibibyte
        )

        XCTAssertEqual(
            decision,
            .allowed(requiredBytes: 15 * gibibyte, availableBytes: 20 * gibibyte)
        )
    }

    func test空间不足返回明确差额() {
        let decision = DesktopDriveCacheSpaceCalculator.evaluate(
            candidates: [.init(sizeBytes: 8 * gibibyte)],
            volumeCapacityBytes: 100 * gibibyte,
            availableCapacityBytes: 10 * gibibyte
        )

        XCTAssertEqual(
            decision,
            .insufficient(
                requiredBytes: 21 * gibibyte,
                availableBytes: 10 * gibibyte,
                shortageBytes: 11 * gibibyte
            )
        )
    }

    func test未知文件大小时拒绝缓存决策() {
        XCTAssertEqual(
            DesktopDriveCacheSpaceCalculator.evaluate(
                candidates: [.init(sizeBytes: nil)],
                volumeCapacityBytes: 100 * gibibyte,
                availableCapacityBytes: 50 * gibibyte
            ),
            .unknownSize
        )
    }

    func test暂停状态只能检查移除或失败() {
        XCTAssertTrue(DesktopDriveMappingState.paused.canTransition(to: .checking))
        XCTAssertTrue(DesktopDriveMappingState.paused.canTransition(to: .removing))
        XCTAssertFalse(DesktopDriveMappingState.paused.canTransition(to: .available))
        XCTAssertFalse(DesktopDriveMappingState.paused.canTransition(to: .offline))
    }

    func test准备状态允许进入移除以完成创建回滚() {
        XCTAssertTrue(
            DesktopDriveMappingState.preparing.canTransition(to: .removing)
        )
    }

    func test共享容器优先使用Bundle内的AppGroup配置() throws {
        let bundleURL = try makeBundle(
            info: [
                DesktopDriveSharedContainer.appGroupInfoDictionaryKey:
                    "  TEAMID.io.github.lanstash.shared  ",
            ]
        )
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        XCTAssertEqual(
            DesktopDriveSharedContainer.appGroupIdentifier(bundle: bundle),
            "TEAMID.io.github.lanstash.shared"
        )
    }

    func test共享容器配置缺失时使用兼容默认值() throws {
        let bundleURL = try makeBundle(info: [:])
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        XCTAssertEqual(
            DesktopDriveSharedContainer.appGroupIdentifier(bundle: bundle),
            DesktopDriveSharedContainer.fallbackAppGroupIdentifier
        )
    }

    func test共享配置按连接保存并可恢复映射() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let capability = ApiCapability(
            name: "SYNO.FileStation.List",
            path: "entry.cgi",
            minVersion: 1,
            maxVersion: 2,
            requestFormat: .form,
            selectedVersion: 2,
            verified: true
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )

        try await store.saveConnection(
            profile: profile,
            capabilities: CapabilitySet([capability.name: capability])
        )
        try await store.saveMapping(mapping)

        let restored = try await store.configuration(mappingID: mapping.id)
        XCTAssertEqual(restored?.mapping, mapping)
        XCTAssertEqual(restored?.connection.profile, profile)
        XCTAssertEqual(restored?.connection.capabilitySet[capability.name], capability)
        let reopened = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let oldConfigurationPendingIDs = try await reopened
            .pendingSessionRemovalProfileIDs()
        XCTAssertTrue(oldConfigurationPendingIDs.isEmpty)
    }

    func test变更日志持久化更新删除并随映射清理() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)

        let firstIdentifier = "item-first"
        let secondIdentifier = "item-second"
        let baseline = [
            firstIdentifier: Self.file(path: "/share/projects/first.txt", size: 1)
        ]
        let initialRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        let initial = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root",
            currentItems: baseline,
            maximumEntryCount: 10,
            expectedRevision: initialRevision
        )
        XCTAssertEqual(initial.currentRevision, 0)
        XCTAssertTrue(initial.entries.isEmpty)

        let changed = [
            secondIdentifier: Self.file(path: "/share/projects/second.txt", size: 2)
        ]
        let changedRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        let journal = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root",
            currentItems: changed,
            maximumEntryCount: 10,
            expectedRevision: changedRevision
        )
        XCTAssertEqual(journal.currentRevision, 2)
        XCTAssertEqual(journal.entries.map(\.kind), [.deleted, .updated])
        XCTAssertEqual(journal.entries.map(\.itemIdentifier), [
            firstIdentifier,
            secondIdentifier,
        ])

        let reopened = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let persistedJournal = try await reopened.changeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        XCTAssertEqual(persistedJournal, journal)
        try await reopened.removeMapping(id: mapping.id)
        let removedJournal = try await reopened.changeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        XCTAssertNil(removedJournal)
    }

    func test慢扫描不能覆盖较快的新扫描结果() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)

        let identifier = "item-first"
        let oldSnapshot = [
            identifier: Self.file(path: "/share/projects/first.txt", size: 1)
        ]
        let initialRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        _ = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root",
            currentItems: oldSnapshot,
            maximumEntryCount: 10,
            expectedRevision: initialRevision
        )
        let scanStartRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        let newSnapshot = [
            identifier: Self.file(path: "/share/projects/first.txt", size: 2)
        ]
        let gate = ChangeJournalCommitGate()
        let slowCommit = Task {
            await gate.waitBeforeSlowCommit()
            return try await store.refreshChangeJournal(
                mappingID: mapping.id,
                containerIdentifier: "root",
                currentItems: oldSnapshot,
                maximumEntryCount: 10,
                expectedRevision: scanStartRevision
            )
        }
        await gate.waitUntilSlowScanIsReady()

        let fastJournal = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root",
            currentItems: newSnapshot,
            maximumEntryCount: 10,
            expectedRevision: scanStartRevision
        )
        await gate.allowSlowCommit()
        do {
            _ = try await slowCommit.value
            XCTFail("旧扫描不应覆盖已提交的新快照。")
        } catch let error as DesktopDriveConfigurationStoreError {
            XCTAssertEqual(error, .staleChangeJournal)
        }

        let finalJournal = try await store.changeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        XCTAssertEqual(finalJournal, fastJournal)
        XCTAssertEqual(finalJournal?.snapshot[identifier], newSnapshot[identifier])
        XCTAssertEqual(finalJournal?.entries.map(\.kind), [.updated])
    }

    func test工作集收缩不会移除根日志仍引用的路径索引() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)

        let path = "/share/projects/first.txt"
        let identifier = try XCTUnwrap(
            DesktopDriveItemIdentity.identifier(
                mappingID: mapping.id,
                remotePath: path
            )
        )
        let snapshot = [identifier: Self.file(path: path, size: 1)]
        let rootRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "root"
        )
        _ = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "root",
            currentItems: snapshot,
            maximumEntryCount: 10,
            expectedRevision: rootRevision
        )
        let workingSetRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "working-set"
        )
        _ = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "working-set",
            currentItems: snapshot,
            maximumEntryCount: 10,
            expectedRevision: workingSetRevision
        )
        let emptyWorkingSetRevision = try await store.changeJournalRevision(
            mappingID: mapping.id,
            containerIdentifier: "working-set"
        )
        _ = try await store.refreshChangeJournal(
            mappingID: mapping.id,
            containerIdentifier: "working-set",
            currentItems: [:],
            maximumEntryCount: 10,
            expectedRevision: emptyWorkingSetRevision
        )

        let resolvedPath = try await store.remotePath(
            mappingID: mapping.id,
            itemIdentifier: identifier
        )
        XCTAssertEqual(resolvedPath, path)
    }

    func test变更日志修订出现缺口时失效以触发完整重新枚举() {
        let item = Self.file(path: "/share/projects/first.txt", size: 1)
        var journal = DesktopDriveChangeJournal(snapshot: [:])
        journal.currentRevision = 2
        journal.minimumAnchorRevision = 0
        journal.entries = [
            .init(
                revision: 2,
                kind: .updated,
                itemIdentifier: "item-first",
                item: item
            )
        ]

        XCTAssertFalse(journal.isValid)
    }

    func test损坏配置读取失败时不会覆盖原始文件() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let fileURL = directoryURL.appendingPathComponent(
            "desktop-drive-config-v1.json"
        )
        let originalData = Data(
            #"{"version":2,"connections":{},"mappings":"damaged"}"#.utf8
        )
        try originalData.write(to: fileURL)
        let store = DesktopDriveConfigurationStore(
            directoryURL: directoryURL
        )

        do {
            _ = try await store.mappings()
            XCTFail("损坏配置不应被当作空配置读取。")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func test单条运行时损坏时保留映射并只标记该条需要恢复() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let first = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "First",
            scope: .folder(path: "/first")
        )
        let second = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Second",
            scope: .folder(path: "/second")
        )
        try await store.saveConnection(
            profile: profile,
            capabilities: CapabilitySet([:])
        )
        try await store.saveMapping(first)
        try await store.saveMapping(second)
        try await store.saveRuntime(.init(state: .available), mappingID: first.id)
        try await store.saveRuntime(.init(state: .paused), mappingID: second.id)

        let fileURL = directoryURL.appendingPathComponent(
            "desktop-drive-config-v1.json"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        var runtimes = try XCTUnwrap(object["runtimes"] as? [Any])
        let firstIndex = try XCTUnwrap(
            runtimes.firstIndex { ($0 as? String) == first.id.uuidString }
        )
        runtimes[firstIndex + 1] = ["state": "future-state"]
        object["runtimes"] = runtimes
        let orphanRecoveryID =
            "33333333-3333-3333-3333-333333333333"
        object["runtimeRecoveryMappingIDs"] = [orphanRecoveryID]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: fileURL, options: .atomic)

        let restored = try await store.mappings()
        let firstRuntime = try await store.runtime(mappingID: first.id)
        let secondRuntime = try await store.runtime(mappingID: second.id)
        XCTAssertEqual(Set(restored.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(firstRuntime.state, .recoveryRequired)
        XCTAssertEqual(secondRuntime.state, .paused)

        try await store.setProviderAvailable(true)
        let rewritten = String(
            decoding: try Data(contentsOf: fileURL),
            as: UTF8.self
        )
        XCTAssertFalse(rewritten.contains("future-state"))
        XCTAssertFalse(rewritten.contains("\"recoveryRequired\""))
        XCTAssertFalse(rewritten.contains(orphanRecoveryID))
        let legacyView = try JSONDecoder().decode(
            LegacyRuntimeSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(legacyView.runtimes?[first.id]?.state, .failed)

        for operation in [
            { try await store.setMappingState(.checking, mappingID: first.id) },
            { try await store.setMappingPaused(false, mappingID: first.id) },
            {
                try await store.saveRuntime(
                    .init(state: .available),
                    mappingID: first.id
                )
            },
        ] {
            do {
                try await operation()
                XCTFail("需要恢复的运行时不应被普通写入覆盖。")
            } catch let error as DesktopDriveConfigurationStoreError {
                XCTAssertEqual(error, .invalidStateTransition)
            }
        }
        let protectedRuntime = try await store.runtime(mappingID: first.id)
        XCTAssertEqual(protectedRuntime.state, .recoveryRequired)

        try await store.completeRuntimeRecovery(
            mappingID: first.id,
            successfulCheckAt: Date()
        )
        let recoveredRuntime = try await store.runtime(mappingID: first.id)
        XCTAssertEqual(recoveredRuntime.state, .available)
    }

    private func makeBundle(info: [String: String]) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent(
            "LanStashTest.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        var dictionary = info
        dictionary["CFBundleIdentifier"] = "io.github.lanstash.test"
        dictionary["CFBundlePackageType"] = "BNDL"
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(
            to: bundleURL.appendingPathComponent("Info.plist")
        )
        return bundleURL
    }

    func test读取损坏配置时使用最后成功快照但拒绝覆盖磁盘() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        let initialMappingIDs = try await store.mappings().map(\.id)
        XCTAssertEqual(initialMappingIDs, [mapping.id])

        let fileURL = directoryURL.appendingPathComponent(
            "desktop-drive-config-v1.json"
        )
        let damaged = Data(
            #"{"version":2,"connections":{},"mappings":"damaged"}"#.utf8
        )
        try damaged.write(to: fileURL, options: .atomic)

        let fallbackMappingIDs = try await store.mappings().map(\.id)
        let fallbackConfiguration = try await store.configuration(
            mappingID: mapping.id
        )
        XCTAssertEqual(fallbackMappingIDs, [mapping.id])
        XCTAssertEqual(fallbackConfiguration?.mapping.id, mapping.id)
        do {
            try await store.setProviderAvailable(false)
            XCTFail("写入不应基于降级快照覆盖损坏文件。")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fileURL), damaged)

        let coldStore = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        do {
            _ = try await coldStore.mappings()
            XCTFail("没有成功快照时不应把损坏配置当作空配置。")
        } catch {}
    }

    func test配置文件消失时读取保留最后快照且写入失败() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        let fileURL = directoryURL.appendingPathComponent(
            "desktop-drive-config-v1.json"
        )
        try FileManager.default.removeItem(at: fileURL)

        let fallbackMappingIDs = try await store.mappings().map(\.id)
        XCTAssertEqual(fallbackMappingIDs, [mapping.id])
        do {
            try await store.setProviderAvailable(false)
            XCTFail("已有快照时磁盘文件消失不应重建空配置。")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testStore拒绝非法状态转换并保留原状态() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        try await store.setMappingState(.paused, mappingID: mapping.id)

        do {
            try await store.setMappingState(.available, mappingID: mapping.id)
            XCTFail("暂停状态不应直接写回可用。")
        } catch let error as DesktopDriveConfigurationStoreError {
            XCTAssertEqual(error, .invalidStateTransition)
        }
        let retainedState = try await store.runtime(mappingID: mapping.id).state
        XCTAssertEqual(retainedState, .paused)
    }

    func testStore允许启动恢复完成后直接进入可用() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let first = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "First",
            scope: .folder(path: "/first")
        )
        let second = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Second",
            scope: .folder(path: "/second")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(first)
        try await store.saveMapping(second)
        try await store.setMappingState(.failed, mappingID: first.id)
        try await store.setMappingState(.cacheVolumeUnavailable, mappingID: second.id)

        try await store.setMappingState(.available, mappingID: first.id)
        try await store.setMappingState(.available, mappingID: second.id)

        let firstState = try await store.runtime(mappingID: first.id).state
        let secondState = try await store.runtime(mappingID: second.id).state
        XCTAssertEqual(firstState, .available)
        XCTAssertEqual(secondState, .available)
    }

    func testRemoving状态不能被普通写入恢复() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let profile = try NasProfile(
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Projects",
            scope: .folder(path: "/share/projects")
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        try await store.setMappingState(.removing, mappingID: mapping.id)

        for operation in [
            { try await store.setMappingState(.available, mappingID: mapping.id) },
            { try await store.setMappingPaused(false, mappingID: mapping.id) },
            {
                try await store.saveRuntime(
                    .init(state: .checking),
                    mappingID: mapping.id
                )
            },
        ] {
            do {
                try await operation()
                XCTFail("移除中状态不应被普通写入恢复。")
            } catch let error as DesktopDriveConfigurationStoreError {
                XCTAssertEqual(error, .invalidStateTransition)
            }
        }
        let retainedState = try await store.runtime(mappingID: mapping.id).state
        XCTAssertEqual(retainedState, .removing)
    }

    func test会话删除Sidecar持久化排序幂等且不随连接删除() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let first = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let profile = try NasProfile(
            id: first,
            displayName: "NAS",
            host: "nas.example.test",
            port: 5001
        )
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        let initialPendingIDs = try await store.pendingSessionRemovalProfileIDs()
        XCTAssertTrue(initialPendingIDs.isEmpty)

        try await store.setSessionRemovalPending(true, profileID: first)
        try await store.setSessionRemovalPending(true, profileID: second)
        try await store.setSessionRemovalPending(true, profileID: first)
        try await store.removeConnection(profileID: first)
        let pendingAfterConnectionRemoval = try await store
            .pendingSessionRemovalProfileIDs()
        XCTAssertEqual(pendingAfterConnectionRemoval, Set([first, second]))

        let fileURL = directoryURL.appendingPathComponent(
            "desktop-drive-config-v1.json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        XCTAssertEqual(
            object["pendingSessionRemovalProfileIDs"] as? [String],
            [second.uuidString, first.uuidString]
        )

        let restored = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let restoredPendingIDs = try await restored
            .pendingSessionRemovalProfileIDs()
        XCTAssertEqual(restoredPendingIDs, Set([first, second]))
        try await restored.setSessionRemovalPending(false, profileID: first)
        try await restored.setSessionRemovalPending(false, profileID: first)
        let pendingAfterConfirmation = try await restored
            .pendingSessionRemovalProfileIDs()
        XCTAssertEqual(pendingAfterConfirmation, Set([second]))
    }

    func test目录缓存规划递归分页并汇总可信大小() async {
        let rootItems = [
            Self.file(path: "/share/root.txt", size: 3),
            Self.folder(path: "/share/sub"),
        ]
        let subItems = [
            Self.file(path: "/share/sub/a.bin", size: 5),
            Self.file(path: "/share/sub/b.bin", size: 7),
        ]

        let plan = await DesktopDriveTreePlanner.build(
            rootFolders: ["/share"],
            pageSize: 1
        ) { path, offset, limit in
            let source = path == "/share" ? rootItems : subItems
            let items = Array(source.dropFirst(offset).prefix(limit))
            return FilePage(
                folderPath: path,
                items: items,
                offset: offset,
                total: source.count,
                hasMore: offset + items.count < source.count
            )
        }

        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.files.map(\.remotePath), [
            "/share/root.txt",
            "/share/sub/a.bin",
            "/share/sub/b.bin",
        ])
        XCTAssertEqual(plan.totalBytes, 15)
        XCTAssertEqual(plan.largestFileBytes, 7)
        XCTAssertEqual(plan.folderCount, 2)
    }

    func test目录缓存规划遇到未知大小和无权目录时不可确认() async {
        let plan = await DesktopDriveTreePlanner.build(
            rootFolders: ["/share"]
        ) { path, _, _ in
            if path == "/share/private" {
                throw CocoaError(.fileReadNoPermission)
            }
            return FilePage(
                folderPath: path,
                items: [
                    Self.file(path: "/share/unknown.bin", size: nil),
                    Self.folder(path: "/share/private"),
                ],
                offset: 0,
                total: 2,
                hasMore: false
            )
        }

        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(
            Set(plan.issues.map(\.kind)),
            [.unknownFileSize, .inaccessibleFolder]
        )
    }

    func test缓存规划可合并直接文件与目录并去重() async {
        let direct = DesktopDrivePlannedFile(
            remotePath: "/share/direct.bin",
            sizeBytes: 7,
            modifiedAt: nil
        )
        let plan = await DesktopDriveTreePlanner.build(
            rootFolders: ["/share"],
            rootFiles: [direct, direct]
        ) { path, _, _ in
            FilePage(
                folderPath: path,
                items: [
                    Self.file(path: "/share/direct.bin", size: 7),
                    Self.file(path: "/share/nested.bin", size: 5),
                ],
                offset: 0,
                total: 2,
                hasMore: false
            )
        }

        XCTAssertTrue(plan.isComplete)
        XCTAssertEqual(plan.files.map(\.remotePath), [
            "/share/direct.bin",
            "/share/nested.bin",
        ])
        XCTAssertEqual(plan.totalBytes, 12)
        XCTAssertEqual(plan.largestFileBytes, 7)
    }

    func test项目身份稳定且不包含远端路径() {
        let mappingID = UUID()
        let first = DesktopDriveItemIdentity.identifier(
            mappingID: mappingID,
            remotePath: "/share/财务/预算.xlsx"
        )
        let second = DesktopDriveItemIdentity.identifier(
            mappingID: mappingID,
            remotePath: "//share/财务/预算.xlsx"
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first?.hasPrefix("item:") == true)
        XCTAssertFalse(first?.contains("share") == true)
        XCTAssertFalse(first?.contains("预算") == true)
    }

    func test暂存文件身份对同一版本稳定且不暴露路径() {
        let mappingID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = DesktopDriveStagingIdentity.contentFileName(
            mappingID: mappingID,
            remotePath: "/share/财务/预算.xlsx",
            sizeBytes: 8_192,
            modifiedAt: modifiedAt
        )
        let second = DesktopDriveStagingIdentity.contentFileName(
            mappingID: mappingID,
            remotePath: "//share/财务/预算.xlsx",
            sizeBytes: 8_192,
            modifiedAt: modifiedAt
        )
        let changed = DesktopDriveStagingIdentity.contentFileName(
            mappingID: mappingID,
            remotePath: "/share/财务/预算.xlsx",
            sizeBytes: 8_193,
            modifiedAt: modifiedAt
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, changed)
        XCTAssertTrue(first?.hasSuffix(".content") == true)
        XCTAssertFalse(first?.contains("share") == true)
        XCTAssertFalse(first?.contains("预算") == true)
    }

    func test离线保留目录覆盖全部后代但不覆盖相邻目录() {
        let runtime = DesktopDriveMappingRuntime(
            pinnedPaths: ["/share/projects"]
        )

        XCTAssertTrue(runtime.keepsOffline("/share/projects/readme.md"))
        XCTAssertTrue(runtime.keepsOffline("/share/projects/sub/a.bin"))
        XCTAssertFalse(runtime.keepsOffline("/share/projects-old/a.bin"))
    }

    func test临时缓存按最久未访问顺序清理且不影响离线文件() {
        let now = Date()
        let entries = [
            DesktopDriveCacheEntry(
                remotePath: "/old.bin",
                kind: .temporary,
                logicalSizeBytes: 4,
                allocatedSizeBytes: 4,
                lastAccessedAt: now.addingTimeInterval(-30)
            ),
            DesktopDriveCacheEntry(
                remotePath: "/new.bin",
                kind: .temporary,
                logicalSizeBytes: 6,
                allocatedSizeBytes: 6,
                lastAccessedAt: now
            ),
            DesktopDriveCacheEntry(
                remotePath: "/offline.bin",
                kind: .keptOffline,
                logicalSizeBytes: 100,
                allocatedSizeBytes: 100,
                lastAccessedAt: now.addingTimeInterval(-60)
            ),
        ]

        XCTAssertEqual(
            DesktopDriveCacheEvictionPlanner.temporaryPathsToEvict(
                entries: entries,
                limitBytes: 6
            ),
            ["/old.bin"]
        )
    }

    func test共享配置并发更新不会丢失缓存记录() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let profile = try NasProfile(
            id: UUID(),
            displayName: "Test",
            host: "nas.test",
            port: 5001,
            usernameHint: "user",
            pinnedCertificateSHA256: nil
        )
        let mapping = DesktopDriveMapping(
            profileID: profile.id,
            displayName: "Test",
            scope: .folder(path: "/share")
        )
        let firstStore = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        let secondStore = DesktopDriveConfigurationStore(directoryURL: directoryURL)
        try await firstStore.saveConnection(
            profile: profile,
            capabilities: .init([:])
        )
        try await firstStore.saveMapping(mapping)

        async let firstBatch = Self.recordEntries(
            range: 0..<20,
            store: firstStore,
            mappingID: mapping.id
        )
        async let secondBatch = Self.recordEntries(
            range: 20..<40,
            store: secondStore,
            mappingID: mapping.id
        )
        try await firstBatch
        try await secondBatch

        let runtime = try await firstStore.runtime(mappingID: mapping.id)
        XCTAssertEqual(runtime.cacheEntries.count, 40)
    }

    private static func file(path: String, size: Int64?) -> FileItem {
        FileItem(
            profileID: UUID.zero,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            kind: .file,
            sizeBytes: size
        )
    }

    private static func folder(path: String) -> FileItem {
        FileItem(
            profileID: UUID.zero,
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            kind: .directory
        )
    }

    private static func recordEntries(
        range: Range<Int>,
        store: DesktopDriveConfigurationStore,
        mappingID: UUID
    ) async throws {
        for index in range {
            let path = "/share/\(index).bin"
            try await store.recordCacheEntry(
                DesktopDriveCacheEntry(
                    remotePath: path,
                    kind: .temporary,
                    logicalSizeBytes: 1,
                    allocatedSizeBytes: 1
                ),
                mappingID: mappingID
            )
        }
    }
}

private actor ChangeJournalCommitGate {
    private var slowScanIsReady = false
    private var isSlowCommitAllowed = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []

    func waitBeforeSlowCommit() async {
        slowScanIsReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isSlowCommitAllowed else { return }
        await withCheckedContinuation { continuation in
            commitWaiters.append(continuation)
        }
    }

    func waitUntilSlowScanIsReady() async {
        guard !slowScanIsReady else { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    func allowSlowCommit() {
        isSlowCommitAllowed = true
        let waiters = commitWaiters
        commitWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct LegacyRuntimeSnapshot: Decodable {
    let runtimes: [UUID: DesktopDriveMappingRuntime]?
}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
