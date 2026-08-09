import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileNasHealthModelTests: XCTestCase {
    func test四个分区独立完成且单项失败不阻断其他内容() async {
        let profileID = UUID()
        let repository = NasHealthRepositoryStub(profileID: profileID, marker: "A")
        await repository.setFailure(.performance)
        let model = MobileNasHealthModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.system.phase, .content)
        XCTAssertEqual(model.state.performance.phase, .error)
        XCTAssertEqual(model.state.storage.phase, .content)
        XCTAssertEqual(model.state.update.phase, .content)
        XCTAssertEqual(model.state.system.value?.serverName, "A")
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test刷新失败保留已有分区内容并单独标记错误() async {
        let profileID = UUID()
        let repository = NasHealthRepositoryStub(profileID: profileID, marker: "before")
        let model = MobileNasHealthModel()
        await model.activate(profileID: profileID, repository: repository)
        await repository.setMarker("after")
        await repository.setFailure(.system)

        await model.refresh()

        XCTAssertEqual(model.state.system.phase, .content)
        XCTAssertEqual(model.state.system.value?.serverName, "before")
        XCTAssertTrue(model.state.system.hasRefreshError)
        XCTAssertEqual(model.state.performance.value?.recordedAt, Self.date(marker: "after"))
        XCTAssertFalse(model.state.performance.hasRefreshError)
    }

    func test切换配置档后A的迟到结果不会覆盖B() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = NasHealthRepositoryStub(profileID: profileA, marker: "A", blocked: true)
        let repositoryB = NasHealthRepositoryStub(profileID: profileB, marker: "B")
        let model = MobileNasHealthModel()

        let loadA = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilBlocked(.system)
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.releaseAll()
        await loadA.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.system.value?.serverName, "B")
        XCTAssertEqual(model.state.performance.value?.recordedAt, Self.date(marker: "B"))
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test返回配置档恢复缓存且刷新只使用新绑定仓库() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = NasHealthRepositoryStub(profileID: profileA, marker: "A1")
        let secondA = NasHealthRepositoryStub(profileID: profileA, marker: "A2")
        let repositoryB = NasHealthRepositoryStub(profileID: profileB, marker: "B")
        let model = MobileNasHealthModel(cacheLimit: 2)

        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        await model.activate(profileID: profileA, repository: secondA)

        XCTAssertEqual(model.state.system.value?.serverName, "A1")
        let requestsBeforeRefresh = await secondA.requestCount(.system)
        XCTAssertEqual(requestsBeforeRefresh, 0)

        await model.refresh()

        XCTAssertEqual(model.state.system.value?.serverName, "A2")
        let newRepositoryRequests = await secondA.requestCount(.system)
        let oldRepositoryRequests = await firstA.requestCount(.system)
        XCTAssertEqual(newRepositoryRequests, 1)
        XCTAssertEqual(oldRepositoryRequests, 1)
    }

    func test取消清除忙碌状态且迟到结果零回写() async {
        let profileID = UUID()
        let repository = NasHealthRepositoryStub(profileID: profileID, marker: "late", blocked: true)
        let model = MobileNasHealthModel()

        let load = Task { await model.activate(profileID: profileID, repository: repository) }
        await repository.waitUntilBlocked(.system)
        model.cancelRefresh()
        await repository.releaseAll()
        await load.value

        XCTAssertEqual(model.state.system.phase, .idle)
        XCTAssertNil(model.state.system.value)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func testPurge和PurgeAll清除缓存与活动绑定() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = NasHealthRepositoryStub(profileID: profileA, marker: "A1")
        let secondA = NasHealthRepositoryStub(profileID: profileA, marker: "A2")
        let repositoryB = NasHealthRepositoryStub(profileID: profileB, marker: "B")
        let model = MobileNasHealthModel()

        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        model.purge(profileID: profileA)
        await model.activate(profileID: profileA, repository: secondA)
        XCTAssertEqual(model.state.system.value?.serverName, "A2")
        let secondARequests = await secondA.requestCount(.system)
        XCTAssertEqual(secondARequests, 1)

        model.purgeAll()
        XCTAssertNil(model.activeProfileID)
        XCTAssertEqual(model.state, MobileNasHealthState())
        await model.activate(profileID: profileB, repository: repositoryB)
        let repositoryBRequests = await repositoryB.requestCount(.system)
        XCTAssertEqual(repositoryBRequests, 2)
    }

    func test配置档缓存按上限淘汰最旧内容() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = NasHealthRepositoryStub(profileID: profileA, marker: "A1")
        let secondA = NasHealthRepositoryStub(profileID: profileA, marker: "A2")
        let repositoryB = NasHealthRepositoryStub(profileID: profileB, marker: "B")
        let model = MobileNasHealthModel(cacheLimit: 1)

        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        await model.activate(profileID: profileA, repository: secondA)

        XCTAssertEqual(model.state.system.value?.serverName, "A2")
        let secondARequests = await secondA.requestCount(.system)
        XCTAssertEqual(secondARequests, 1)
    }

    func test更新状态区分可更新与已是最新() {
        let available = MobileNasUpdateHealth(
            NasSystemUpdateInfo(
                isUpdateAvailable: true,
                currentVersion: "1",
                latestVersion: "2",
                releaseNotes: "notes"
            )
        )
        let current = MobileNasUpdateHealth(NasSystemUpdateInfo(isUpdateAvailable: false))

        XCTAssertEqual(available.status, .updateAvailable)
        XCTAssertEqual(available.currentVersion, "1")
        XCTAssertEqual(available.latestVersion, "2")
        XCTAssertEqual(current.status, .upToDate)
    }

    func test未知健康值保持未知且安全展示模型不含敏感字段() {
        let snapshot = Self.storage(marker: "safe", status: "future-state")
        let presentation = MobileNasStorageHealth(snapshot)

        XCTAssertEqual(presentation.overallHealth, .unknown)
        XCTAssertEqual(presentation.disks.first?.health, .unknown)
        XCTAssertEqual(presentation.disks.first?.smartHealth, .unknown)

        let labels = Self.allMirrorLabels(presentation)
        for forbidden in [
            "id", "deviceID", "serialNumber", "firmwareVersion", "path", "poolID",
            "diskIDs", "spareDiskIDs", "usedBy", "realOwner", "account", "log", "address"
        ] {
            XCTAssertFalse(labels.contains(forbidden), "展示模型不应包含敏感字段：\(forbidden)")
        }
    }

    func test只读仓库协议仅暴露四项读取能力() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = appRoot
            .appendingPathComponent("Sources/Features/Administration/MobileReadOnlyNasHealthRepository.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let protocolSource = try XCTUnwrap(
            source.components(separatedBy: "struct MobileReadOnlyNasHealthRepository").first
        )

        XCTAssertEqual(protocolSource.components(separatedBy: "func ").count - 1, 4)
        for required in [
            "loadSystemOverview", "loadPerformanceSnapshot", "loadStorage", "checkSystemUpdate"
        ] {
            XCTAssertTrue(protocolSource.contains("func \(required)"))
        }
        for forbidden in [
            "save", "delete", "start", "stop", "control", "disconnect", "install",
            "reboot", "shutdown", "package", "account", "log", "connection", "diskTest"
        ] {
            XCTAssertFalse(protocolSource.localizedCaseInsensitiveContains("func \(forbidden)"))
        }
    }

    func test配置档与仓库不匹配时零请求且不建立活动绑定() async {
        let repository = NasHealthRepositoryStub(profileID: UUID(), marker: "wrong")
        let model = MobileNasHealthModel()

        await model.activate(profileID: UUID(), repository: repository)

        XCTAssertNil(model.activeProfileID)
        let requestCount = await repository.totalRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test单一分区自行取消不会永久停留在加载状态() async {
        let profileID = UUID()
        let repository = NasHealthRepositoryStub(profileID: profileID, marker: "safe")
        await repository.setCancellation(.performance)
        let model = MobileNasHealthModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.performance.phase, .idle)
        XCTAssertFalse(model.state.performance.isRefreshing)
        XCTAssertFalse(model.state.isRefreshing)
        XCTAssertEqual(model.state.system.phase, .content)
        XCTAssertEqual(model.state.storage.phase, .content)
        XCTAssertEqual(model.state.update.phase, .content)
    }

    private static func allMirrorLabels(_ value: Any) -> Set<String> {
        var labels = Set<String>()
        func visit(_ value: Any) {
            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                if let label = child.label { labels.insert(label) }
                visit(child.value)
            }
        }
        visit(value)
        return labels
    }

    nonisolated fileprivate static func date(marker: String) -> Date {
        Date(timeIntervalSince1970: TimeInterval(abs(marker.hashValue % 10_000) + 1))
    }

    nonisolated fileprivate static func overview(marker: String) -> NasSystemOverview {
        NasSystemOverview(serverName: marker, model: "model", version: "version")
    }

    nonisolated fileprivate static func performance(marker: String) -> NasPerformanceSnapshot {
        NasPerformanceSnapshot(
            recordedAt: date(marker: marker),
            cpuUsage: 12, cpuUserUsage: 5, cpuSystemUsage: 4, cpuOtherUsage: 3,
            memoryUsage: 34, swapUsage: 0,
            networkReceivedBytesPerSecond: 1, networkSentBytesPerSecond: 2,
            diskReadBytesPerSecond: 3, diskWriteBytesPerSecond: 4,
            volumeReadBytesPerSecond: 5, volumeWriteBytesPerSecond: 6,
            diskUtilization: 7,
            nfsReadOperationsPerSecond: 8, nfsWriteOperationsPerSecond: 9
        )
    }

    nonisolated fileprivate static func storage(
        marker: String,
        status: String = "normal"
    ) -> NasStorageSnapshot {
        NasStorageSnapshot(
            overallStatus: status,
            disks: [
                NasDisk(
                    id: "internal-\(marker)", deviceID: "device-\(marker)", name: "Disk 1",
                    vendor: "vendor", model: "disk", type: "SATA", totalBytes: 100,
                    status: status, smartStatus: status, temperatureCelsius: 30,
                    isSSD: false, usedBy: "/secret/path", supportsSmartTest: true,
                    serialNumber: "serial-secret", firmwareVersion: "firmware-secret",
                    location: "private-location"
                )
            ],
            pools: [
                NasStoragePool(
                    id: "pool-secret", name: "Pool 1", raidType: "SHR", status: status,
                    totalBytes: 100, usedBytes: 50, isWritable: true, isScrubbing: false,
                    nextScrubbingDate: nil, diskIDs: ["internal-\(marker)"]
                )
            ],
            volumes: [
                NasVolume(
                    id: "volume-secret", name: "Volume 1", fileSystem: "btrfs",
                    status: status, totalBytes: 100, usedBytes: 50,
                    isEncrypted: false, isWritable: true,
                    poolID: "pool-secret", path: "/volume-secret"
                )
            ]
        )
    }

    nonisolated fileprivate static func update(marker: String) -> NasSystemUpdateInfo {
        NasSystemUpdateInfo(
            isUpdateAvailable: marker.hasSuffix("2"),
            currentVersion: marker,
            latestVersion: marker.hasSuffix("2") ? "next" : marker
        )
    }
}

private enum NasHealthRequest: CaseIterable, Hashable, Sendable {
    case system
    case performance
    case storage
    case update
}

private enum NasHealthStubError: Error { case failed }

private actor NasHealthRepositoryStub: MobileNasHealthReading {
    nonisolated let profileID: UUID
    private var marker: String
    private var failures = Set<NasHealthRequest>()
    private var cancellations = Set<NasHealthRequest>()
    private var blocked: Set<NasHealthRequest>
    private var continuations: [NasHealthRequest: CheckedContinuation<Void, Never>] = [:]
    private var blockedWaiters: [NasHealthRequest: [CheckedContinuation<Void, Never>]] = [:]
    private var requestCounts: [NasHealthRequest: Int] = [:]

    init(profileID: UUID, marker: String, blocked: Bool = false) {
        self.profileID = profileID
        self.marker = marker
        self.blocked = blocked ? Set(NasHealthRequest.allCases) : []
    }

    func loadSystemOverview() async throws -> NasSystemOverview {
        let marker = try await begin(.system)
        return MobileNasHealthModelTests.overview(marker: marker)
    }

    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot {
        let marker = try await begin(.performance)
        return MobileNasHealthModelTests.performance(marker: marker)
    }

    func loadStorage() async throws -> NasStorageSnapshot {
        let marker = try await begin(.storage)
        return MobileNasHealthModelTests.storage(marker: marker)
    }

    func checkSystemUpdate() async throws -> NasSystemUpdateInfo {
        let marker = try await begin(.update)
        return MobileNasHealthModelTests.update(marker: marker)
    }

    func setFailure(_ request: NasHealthRequest) { failures.insert(request) }
    func setCancellation(_ request: NasHealthRequest) { cancellations.insert(request) }
    func setMarker(_ marker: String) { self.marker = marker }
    func requestCount(_ request: NasHealthRequest) -> Int { requestCounts[request, default: 0] }
    func totalRequestCount() -> Int { requestCounts.values.reduce(0, +) }

    func waitUntilBlocked(_ request: NasHealthRequest) async {
        guard continuations[request] == nil else { return }
        await withCheckedContinuation { blockedWaiters[request, default: []].append($0) }
    }

    func releaseAll() {
        blocked.removeAll()
        for continuation in continuations.values { continuation.resume() }
        continuations.removeAll()
    }

    private func begin(_ request: NasHealthRequest) async throws -> String {
        requestCounts[request, default: 0] += 1
        if blocked.contains(request) {
            blockedWaiters.removeValue(forKey: request)?.forEach { $0.resume() }
            await withCheckedContinuation { continuations[request] = $0 }
        }
        if failures.contains(request) { throw NasHealthStubError.failed }
        if cancellations.contains(request) { throw CancellationError() }
        return marker
    }
}
