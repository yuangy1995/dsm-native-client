import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileVirtualMachineInventoryModelTests: XCTestCase {
    func test共享快照投影七分区白名单摘要() async {
        let profileID = UUID()
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "A"))]
        )
        let model = MobileVirtualMachineInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertTrue(MobileVirtualMachineSection.allCases.allSatisfy {
            model.state.sectionState($0) == .content
        })
        XCTAssertEqual(model.state.machines.first?.status, .running)
        XCTAssertEqual(model.state.hosts.first?.name, "host-A")
        XCTAssertEqual(model.state.storages.first?.capacityBytes, 4096)
        XCTAssertEqual(model.state.protection.map(\.kind), [.plan, .schedule, .retention])
        XCTAssertEqual(model.state.events.first?.level, "warning")
    }

    func testTyped不可用只影响对应分区() async {
        let profileID = UUID()
        let snapshot = Self.snapshot(
            marker: "A",
            unavailable: [.hosts, .images, .protection, .logs]
        )
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(snapshot)]
        )
        let model = MobileVirtualMachineInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.sectionState(.machines), .content)
        XCTAssertEqual(model.state.sectionState(.storages), .content)
        XCTAssertEqual(model.state.sectionState(.networks), .content)
        XCTAssertEqual(model.state.sectionState(.hosts), .unavailable)
        XCTAssertEqual(model.state.sectionState(.images), .unavailable)
        XCTAssertEqual(model.state.sectionState(.protection), .unavailable)
        XCTAssertEqual(model.state.sectionState(.events), .unavailable)
    }

    func test主分区保留全部运行停止关注筛选与FilteredEmpty() async {
        let profileID = UUID()
        let base = Self.snapshot(marker: "filter")
        let machines = [
            VirtualMachine(id: "running", name: "running", status: "running"),
            VirtualMachine(id: "stopped", name: "stopped", status: "powered_off"),
            VirtualMachine(id: "attention", name: "attention", status: "failed"),
            VirtualMachine(id: "unknown", name: "unknown", status: "future")
        ]
        let snapshot = VirtualMachineManagerSnapshot(
            source: base.source,
            machines: machines,
            hosts: base.hosts,
            storages: base.storages,
            networks: base.networks,
            images: base.images,
            protectionPlans: base.protectionPlans,
            protectionSchedulePolicies: base.protectionSchedulePolicies,
            protectionRetentionPolicies: base.protectionRetentionPolicies,
            events: base.events
        )
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(snapshot)]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.visibleMachines.count, 4)
        model.setFilter(.running)
        XCTAssertEqual(model.state.visibleMachines.map(\.id), ["running"])
        model.setFilter(.stopped)
        XCTAssertEqual(model.state.visibleMachines.map(\.id), ["stopped"])
        model.setFilter(.attention)
        XCTAssertEqual(Set(model.state.visibleMachines.map(\.id)), ["attention", "unknown"])
        model.setFilter(.running)
        model.selectItem("running")
        model.setFilter(.stopped)
        XCTAssertNil(model.state.selectedMachine)
        model.setFilter(.all)
        XCTAssertEqual(model.state.pageState, .content)

        let emptyProfile = UUID()
        let emptyRepository = VirtualMachineManagerRepositoryStub(
            profileID: emptyProfile,
            responses: [.success(Self.snapshot(marker: "only-running"))]
        )
        let emptyModel = MobileVirtualMachineInventoryModel()
        await emptyModel.activate(profileID: emptyProfile, repository: emptyRepository)
        emptyModel.setFilter(.stopped)
        XCTAssertEqual(emptyModel.state.pageState, .filteredEmpty)
    }

    func test旧状态别名保持规范映射() {
        for alias in ["poweron", "on"] {
            XCTAssertEqual(MobileVirtualMachineStatus(serverValue: alias), .running)
        }
        for alias in ["shutdown", "shutoff", "poweroff", "off"] {
            XCTAssertEqual(MobileVirtualMachineStatus(serverValue: alias), .stopped)
        }
        XCTAssertEqual(MobileVirtualMachineStatus(serverValue: "degraded"), .attention)
    }

    func test首次失败与整体不可用映射所有分区() async {
        let failedProfile = UUID()
        let failed = VirtualMachineManagerRepositoryStub(profileID: failedProfile, responses: [.failure])
        let failedModel = MobileVirtualMachineInventoryModel()
        await failedModel.activate(profileID: failedProfile, repository: failed)
        XCTAssertTrue(MobileVirtualMachineSection.allCases.allSatisfy {
            failedModel.state.sectionState($0) == .failed
        })

        let unavailableProfile = UUID()
        let unavailable = VirtualMachineManagerRepositoryStub(
            profileID: unavailableProfile,
            responses: [.unavailable]
        )
        let unavailableModel = MobileVirtualMachineInventoryModel()
        await unavailableModel.activate(profileID: unavailableProfile, repository: unavailable)
        XCTAssertTrue(MobileVirtualMachineSection.allCases.allSatisfy {
            unavailableModel.state.sectionState($0) == .unavailable
        })
    }

    func test刷新失败保留旧分区内容() async {
        let profileID = UUID()
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "before")), .failure]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.refresh()

        XCTAssertEqual(model.state.machines.first?.name, "vm-before")
        XCTAssertEqual(model.state.sectionState(.events), .content)
        XCTAssertTrue(model.state.hasRefreshError)
    }

    func test认证与OTP进入RequiresReconnect且不自动重放() async {
        let initialProfile = UUID()
        let initialRepository = VirtualMachineManagerRepositoryStub(
            profileID: initialProfile,
            responses: [.authentication, .success(Self.snapshot(marker: "unexpected"))]
        )
        let initialModel = MobileVirtualMachineInventoryModel()
        await initialModel.activate(profileID: initialProfile, repository: initialRepository)

        XCTAssertTrue(initialModel.state.requiresReconnect)
        XCTAssertFalse(initialModel.state.hasRefreshError)
        XCTAssertTrue(MobileVirtualMachineSection.allCases.allSatisfy {
            initialModel.state.sectionState($0) == .failed
        })
        await initialModel.refresh()
        await initialModel.activate(profileID: initialProfile, repository: initialRepository)
        let initialRequests = await initialRepository.requestCount()
        XCTAssertEqual(initialRequests, 1)

        let refreshProfile = UUID()
        let refreshRepository = VirtualMachineManagerRepositoryStub(
            profileID: refreshProfile,
            responses: [.success(Self.snapshot(marker: "before")), .otp]
        )
        let refreshModel = MobileVirtualMachineInventoryModel()
        await refreshModel.activate(profileID: refreshProfile, repository: refreshRepository)
        await refreshModel.refresh()
        XCTAssertTrue(refreshModel.state.requiresReconnect)
        XCTAssertEqual(refreshModel.state.machines.first?.name, "vm-before")
        XCTAssertFalse(refreshModel.state.hasRefreshError)
    }

    func test取消不显示错误或重连状态() async {
        let profileID = UUID()
        let repository = VirtualMachineManagerRepositoryStub(profileID: profileID, responses: [.cancelled])
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertFalse(model.state.hasRefreshError)
        XCTAssertFalse(model.state.requiresReconnect)
        XCTAssertEqual(model.state.pageState, .content)
    }

    func test证书安全错误进入RequiresReconnect() async {
        let profileID = UUID()
        let repository = VirtualMachineManagerRepositoryStub(profileID: profileID, responses: [.tls])
        let model = MobileVirtualMachineInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertTrue(model.state.requiresReconnect)
        XCTAssertFalse(model.state.hasRefreshError)
    }

    func testTyped分区刷新失败保留旧成功值并显示刷新失败() async {
        let profileID = UUID()
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [
                .success(Self.snapshot(marker: "before")),
                .success(Self.snapshot(
                    marker: "after",
                    unavailable: [.hosts],
                    failed: [.storages]
                ))
            ]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh()

        XCTAssertEqual(model.state.hosts.first?.name, "host-before")
        XCTAssertEqual(model.state.storages.first?.name, "storage-before")
        XCTAssertEqual(model.state.networks.first?.name, "network-after")
        XCTAssertEqual(model.state.sectionState(.hosts), .content)
        XCTAssertEqual(model.state.sectionState(.storages), .content)
        XCTAssertTrue(model.state.hasRefreshError)
    }

    func test首次Typed失败只影响对应分区() async {
        let profileID = UUID()
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "A", failed: [.hosts, .logs]))]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.sectionState(.hosts), .failed)
        XCTAssertEqual(model.state.sectionState(.events), .failed)
        XCTAssertEqual(model.state.sectionState(.machines), .content)
        XCTAssertEqual(model.state.sectionState(.storages), .content)
    }

    func test同Profile首次失败后更换Repository会自动读取新源() async {
        let profileID = UUID()
        let first = VirtualMachineManagerRepositoryStub(profileID: profileID, responses: [.failure])
        let second = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "new"))]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: first)
        await model.activate(profileID: profileID, repository: second)

        XCTAssertEqual(model.state.machines.map(\.name), ["vm-new"])
        let firstRequests = await first.requestCount()
        let secondRequests = await second.requestCount()
        XCTAssertEqual(firstRequests, 1)
        XCTAssertEqual(secondRequests, 1)
    }

    func test成功缓存绑定新Repository后手动刷新且请求次数正确() async {
        let profileID = UUID()
        let first = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "old"))]
        )
        let second = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "new"))]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: first)
        await model.activate(profileID: profileID, repository: second)
        XCTAssertEqual(model.state.machines.map(\.name), ["vm-old"])
        let secondRequestsBeforeRefresh = await second.requestCount()
        XCTAssertEqual(secondRequestsBeforeRefresh, 0)

        await model.refresh()
        XCTAssertEqual(model.state.machines.map(\.name), ["vm-new"])
        let firstRequests = await first.requestCount()
        let secondRequests = await second.requestCount()
        XCTAssertEqual(firstRequests, 1)
        XCTAssertEqual(secondRequests, 1)
    }

    func test切换配置档隔离迟到快照() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = VirtualMachineManagerRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A"))],
            startsBlocked: true
        )
        let repositoryB = VirtualMachineManagerRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot(marker: "B"))]
        )
        let model = MobileVirtualMachineInventoryModel()

        let loadA = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilBlocked()
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.release()
        await loadA.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.machines.map(\.name), ["vm-B"])
    }

    func testProfile不匹配零请求且离页迟到结果被隔离() async {
        let repository = VirtualMachineManagerRepositoryStub(
            profileID: UUID(),
            responses: [.success(Self.snapshot(marker: "wrong"))]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: UUID(), repository: repository)
        XCTAssertNil(model.activeProfileID)
        let mismatchedRequests = await repository.requestCount()
        XCTAssertEqual(mismatchedRequests, 0)

        let profileID = UUID()
        let lateRepository = VirtualMachineManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "late"))],
            startsBlocked: true
        )
        let load = Task { await model.activate(profileID: profileID, repository: lateRepository) }
        await lateRepository.waitUntilBlocked()
        model.deactivate()
        await lateRepository.release()
        await load.value
        XCTAssertNil(model.activeProfileID)
    }

    func testLRU_Purge与PurgeAll强制重新读取() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = VirtualMachineManagerRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A1"))]
        )
        let secondA = VirtualMachineManagerRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A2"))]
        )
        let repositoryB = VirtualMachineManagerRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot(marker: "B"))]
        )
        let model = MobileVirtualMachineInventoryModel(cacheLimit: 1)
        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        await model.activate(profileID: profileA, repository: secondA)
        XCTAssertEqual(model.state.machines.map(\.name), ["vm-A2"])
        let secondRequests = await secondA.requestCount()
        XCTAssertEqual(secondRequests, 1)

        model.purge(profileID: profileA)
        XCTAssertNil(model.activeProfileID)
        model.purgeAll()
        XCTAssertTrue(model.profiles.isEmpty)
    }

    func test白名单丢弃绑定与事件隐私且仓库协议无写能力() throws {
        let machine = MobileVirtualMachineItem(VirtualMachine(
            id: "id", name: "name", status: "running", description: "private",
            hostID: "private", host: "private", storageID: "private", ipAddress: "private",
            keyboardLayout: "private", cpuWeight: 99
        ))
        XCTAssertEqual(
            Set(Mirror(reflecting: machine).children.compactMap(\.label)),
            ["id", "name", "status", "cpuCount", "memoryBytes", "storageBytes", "autoStart"]
        )
        let event = MobileVirtualMachineEventItem(
            ServiceEvent(id: "id", timestamp: nil, level: "info", user: "private", message: "private")
        )
        XCTAssertEqual(Set(Mirror(reflecting: event).children.compactMap(\.label)), ["id", "timestamp", "level"])

        let source = try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileReadOnlyVirtualMachineRepository.swift")
        let protocolSource = try XCTUnwrap(
            source.components(separatedBy: "struct MobileReadOnlyVirtualMachineRepository").first
        )
        XCTAssertEqual(protocolSource.components(separatedBy: "func ").count - 1, 1)
        XCTAssertTrue(source.contains("loadVirtualMachineManager()"))
        XCTAssertTrue(source.contains("@Sendable () async throws"))
        XCTAssertFalse(source.contains("private let base"))
        for forbidden in ["create", "delete", "start", "stop", "restart", "console", "log"] {
            XCTAssertFalse(protocolSource.localizedCaseInsensitiveContains("func \(forbidden)"))
        }
    }

    nonisolated private static func snapshot(
        marker: String,
        unavailable: Set<VirtualMachineManagerSection> = [],
        failed: Set<VirtualMachineManagerSection> = []
    ) -> VirtualMachineManagerSnapshot {
        let resource: (String) -> VirtualizationResource = { prefix in
            VirtualizationResource(
                id: "\(prefix)-\(marker)", name: "\(prefix)-\(marker)", status: "healthy",
                detail: "private", hostID: "private", hostName: "private",
                allocatedBytes: 2048, capacityBytes: 4096
            )
        }
        return VirtualMachineManagerSnapshot(
            source: .internalAPI,
            machines: [VirtualMachine(
                id: "vm-\(marker)", name: "vm-\(marker)", status: "powered_on",
                description: "private", hostID: "private", host: "private", storageID: "private",
                cpuCount: 2, memoryBytes: 2048, storageBytes: 4096, ipAddress: "private",
                keyboardLayout: "private", autoStart: true, cpuWeight: 99
            )],
            hosts: [resource("host")],
            storages: [resource("storage")],
            networks: [resource("network")],
            images: [resource("image")],
            protectionPlans: [resource("plan")],
            protectionSchedulePolicies: [resource("schedule")],
            protectionRetentionPolicies: [resource("retention")],
            events: [ServiceEvent(
                id: "event-\(marker)", timestamp: Date(timeIntervalSince1970: 1), level: "warning",
                user: "private", message: "private"
            )],
            unavailableSections: unavailable,
            failedSections: failed
        )
    }

    private func source(_ path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }
}

private actor VirtualMachineManagerRepositoryStub: MobileVirtualMachineInventoryReading {
    enum Response: Sendable {
        case success(VirtualMachineManagerSnapshot)
        case unavailable
        case authentication
        case otp
        case tls
        case cancelled
        case failure
    }
    nonisolated let profileID: UUID
    private var responses: [Response]
    private var requests = 0
    private var blocked: Bool
    private var enteredBlock = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(profileID: UUID, responses: [Response], startsBlocked: Bool = false) {
        self.profileID = profileID
        self.responses = responses
        blocked = startsBlocked
    }

    func loadInventory() async throws -> VirtualMachineManagerSnapshot {
        requests += 1
        if blocked {
            enteredBlock = true
            await withCheckedContinuation { continuation = $0 }
        }
        guard !responses.isEmpty else { throw StubError.failed }
        switch responses.removeFirst() {
        case .success(let snapshot): return snapshot
        case .unavailable:
            throw AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: "")
        case .authentication:
            throw AppError(category: .authenticationRequired, isRetryable: false, safeUserMessage: "")
        case .otp:
            throw AppError(category: .otpRequired, isRetryable: false, safeUserMessage: "")
        case .tls:
            throw AppError(category: .tlsCertificateChanged, isRetryable: false, safeUserMessage: "")
        case .cancelled:
            throw AppError(category: .cancelled, isRetryable: false, safeUserMessage: "")
        case .failure: throw StubError.failed
        }
    }

    func waitUntilBlocked() async { while !enteredBlock { await Task.yield() } }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
    func requestCount() -> Int { requests }
    private enum StubError: Error { case failed }
}
