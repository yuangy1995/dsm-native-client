import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileContainerInventoryModelTests: XCTestCase {
    func test共享快照投影五分区白名单摘要() async {
        let profileID = UUID()
        let repository = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "A"))]
        )
        let model = MobileContainerInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.sectionState(.containers), .content)
        XCTAssertEqual(model.state.sectionState(.images), .content)
        XCTAssertEqual(model.state.sectionState(.networks), .content)
        XCTAssertEqual(model.state.sectionState(.projects), .content)
        XCTAssertEqual(model.state.sectionState(.events), .content)
        XCTAssertEqual(model.state.containers.first?.name, "container-A")
        XCTAssertEqual(model.state.images.first?.name, "repo-A:latest")
        XCTAssertEqual(model.state.networks.first?.connectedContainerCount, 1)
        XCTAssertEqual(model.state.projects.first?.containerCount, 1)
        XCTAssertEqual(model.state.events.first?.level, "info")
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test空分区彼此独立() async {
        let profileID = UUID()
        let snapshot = ContainerManagerSnapshot(
            containers: Self.snapshot(marker: "A").containers,
            images: [], networks: [], projects: [], events: []
        )
        let repository = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(snapshot)]
        )
        let model = MobileContainerInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.sectionState(.containers), .content)
        for section in MobileContainerSection.allCases where section != .containers {
            XCTAssertEqual(model.state.sectionState(section), .empty)
        }
    }

    func test主分区保留全部运行停止关注筛选与FilteredEmpty() async {
        let profileID = UUID()
        let base = Self.snapshot(marker: "filter")
        let snapshot = ContainerManagerSnapshot(
            containers: [
                ContainerInstance(id: "running", name: "running", image: "a", status: "running"),
                ContainerInstance(id: "stopped", name: "stopped", image: "b", status: "stopped"),
                ContainerInstance(id: "attention", name: "attention", image: "c", status: "failed"),
                ContainerInstance(id: "unknown", name: "unknown", image: "d", status: "future")
            ],
            images: base.images,
            networks: base.networks,
            projects: base.projects,
            events: base.events
        )
        let repository = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(snapshot)]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.visibleContainers.count, 4)
        model.setFilter(.running)
        XCTAssertEqual(model.state.visibleContainers.map(\.id), ["running"])
        model.setFilter(.stopped)
        XCTAssertEqual(model.state.visibleContainers.map(\.id), ["stopped"])
        model.setFilter(.attention)
        XCTAssertEqual(Set(model.state.visibleContainers.map(\.id)), ["attention", "unknown"])

        model.setFilter(.running)
        model.selectItem("running")
        model.setFilter(.stopped)
        XCTAssertNil(model.state.selectedContainer)
        model.setFilter(.all)
        XCTAssertEqual(model.state.pageState, .content)

        let emptyFilterRepository = ContainerManagerRepositoryStub(
            profileID: UUID(),
            responses: [.success(Self.snapshot(marker: "only-running"))]
        )
        let emptyFilterModel = MobileContainerInventoryModel()
        await emptyFilterModel.activate(
            profileID: emptyFilterRepository.profileID,
            repository: emptyFilterRepository
        )
        emptyFilterModel.setFilter(.stopped)
        XCTAssertEqual(emptyFilterModel.state.pageState, .filteredEmpty)
    }

    func test首次不可用与失败映射到所有分区() async {
        let unavailableProfile = UUID()
        let unavailable = ContainerManagerRepositoryStub(
            profileID: unavailableProfile,
            responses: [.unavailable]
        )
        let unavailableModel = MobileContainerInventoryModel()
        await unavailableModel.activate(profileID: unavailableProfile, repository: unavailable)
        XCTAssertTrue(MobileContainerSection.allCases.allSatisfy {
            unavailableModel.state.sectionState($0) == .unavailable
        })

        let failedProfile = UUID()
        let failed = ContainerManagerRepositoryStub(profileID: failedProfile, responses: [.failure])
        let failedModel = MobileContainerInventoryModel()
        await failedModel.activate(profileID: failedProfile, repository: failed)
        XCTAssertTrue(MobileContainerSection.allCases.allSatisfy {
            failedModel.state.sectionState($0) == .failed
        })
    }

    func test刷新失败保留各分区旧内容() async {
        let profileID = UUID()
        let repository = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "before")), .failure]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.refresh()

        XCTAssertEqual(model.state.containers.first?.name, "container-before")
        XCTAssertEqual(model.state.sectionState(.events), .content)
        XCTAssertTrue(model.state.hasRefreshError)
    }

    func test认证与OTP进入RequiresReconnect且不自动重放() async {
        let initialProfile = UUID()
        let initialRepository = ContainerManagerRepositoryStub(
            profileID: initialProfile,
            responses: [.authentication, .success(Self.snapshot(marker: "unexpected"))]
        )
        let initialModel = MobileContainerInventoryModel()
        await initialModel.activate(profileID: initialProfile, repository: initialRepository)

        XCTAssertTrue(initialModel.state.requiresReconnect)
        XCTAssertFalse(initialModel.state.hasRefreshError)
        XCTAssertTrue(MobileContainerSection.allCases.allSatisfy {
            initialModel.state.sectionState($0) == .failed
        })
        await initialModel.refresh()
        await initialModel.activate(profileID: initialProfile, repository: initialRepository)
        let initialRequests = await initialRepository.requestCount()
        XCTAssertEqual(initialRequests, 1)

        let refreshProfile = UUID()
        let refreshRepository = ContainerManagerRepositoryStub(
            profileID: refreshProfile,
            responses: [.success(Self.snapshot(marker: "before")), .otp]
        )
        let refreshModel = MobileContainerInventoryModel()
        await refreshModel.activate(profileID: refreshProfile, repository: refreshRepository)
        await refreshModel.refresh()
        XCTAssertTrue(refreshModel.state.requiresReconnect)
        XCTAssertEqual(refreshModel.state.containers.first?.name, "container-before")
        XCTAssertFalse(refreshModel.state.hasRefreshError)
    }

    func test取消不显示错误或重连状态() async {
        let profileID = UUID()
        let repository = ContainerManagerRepositoryStub(profileID: profileID, responses: [.cancelled])
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        XCTAssertFalse(model.state.hasRefreshError)
        XCTAssertFalse(model.state.requiresReconnect)
        XCTAssertEqual(model.state.pageState, .content)
    }

    func test证书安全错误进入RequiresReconnect() async {
        let profileID = UUID()
        let repository = ContainerManagerRepositoryStub(profileID: profileID, responses: [.tls])
        let model = MobileContainerInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertTrue(model.state.requiresReconnect)
        XCTAssertFalse(model.state.hasRefreshError)
    }

    func testTyped分区刷新失败保留旧成功值且首次分别呈现状态() async {
        let profileID = UUID()
        let repository = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [
                .success(Self.snapshot(marker: "before")),
                .success(Self.snapshot(
                    marker: "after",
                    unavailable: [.images],
                    failed: [.networks]
                ))
            ]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: repository)
        await model.refresh()

        XCTAssertEqual(model.state.images.first?.name, "repo-before:latest")
        XCTAssertEqual(model.state.networks.first?.name, "network-before")
        XCTAssertEqual(model.state.projects.first?.name, "project-after")
        XCTAssertEqual(model.state.sectionState(.images), .content)
        XCTAssertEqual(model.state.sectionState(.networks), .content)
        XCTAssertTrue(model.state.hasRefreshError)

        let firstProfile = UUID()
        let firstRepository = ContainerManagerRepositoryStub(
            profileID: firstProfile,
            responses: [.success(Self.snapshot(
                marker: "first",
                unavailable: [.images],
                failed: [.networks]
            ))]
        )
        let firstModel = MobileContainerInventoryModel()
        await firstModel.activate(profileID: firstProfile, repository: firstRepository)
        XCTAssertEqual(firstModel.state.sectionState(.images), .unavailable)
        XCTAssertEqual(firstModel.state.sectionState(.networks), .failed)
    }

    func test同Profile首次失败后更换Repository会自动读取新源() async {
        let profileID = UUID()
        let first = ContainerManagerRepositoryStub(profileID: profileID, responses: [.failure])
        let second = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "new"))]
        )
        let model = MobileContainerInventoryModel()

        await model.activate(profileID: profileID, repository: first)
        await model.activate(profileID: profileID, repository: second)

        XCTAssertEqual(model.state.containers.map(\.name), ["container-new"])
        let firstRequests = await first.requestCount()
        let secondRequests = await second.requestCount()
        XCTAssertEqual(firstRequests, 1)
        XCTAssertEqual(secondRequests, 1)
    }

    func test成功缓存绑定新Repository后手动刷新且请求次数正确() async {
        let profileID = UUID()
        let first = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "old"))]
        )
        let second = ContainerManagerRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "new"))]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: first)
        await model.activate(profileID: profileID, repository: second)
        XCTAssertEqual(model.state.containers.map(\.name), ["container-old"])
        let secondRequestsBeforeRefresh = await second.requestCount()
        XCTAssertEqual(secondRequestsBeforeRefresh, 0)

        await model.refresh()
        XCTAssertEqual(model.state.containers.map(\.name), ["container-new"])
        let firstRequests = await first.requestCount()
        let secondRequests = await second.requestCount()
        XCTAssertEqual(firstRequests, 1)
        XCTAssertEqual(secondRequests, 1)
    }

    func test切换配置档隔离迟到快照() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = ContainerManagerRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A"))],
            startsBlocked: true
        )
        let repositoryB = ContainerManagerRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot(marker: "B"))]
        )
        let model = MobileContainerInventoryModel()

        let loadA = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilBlocked()
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.release()
        await loadA.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.containers.map(\.name), ["container-B"])
    }

    func testProfile不匹配零请求且离页迟到结果被隔离() async {
        let repository = ContainerManagerRepositoryStub(
            profileID: UUID(),
            responses: [.success(Self.snapshot(marker: "wrong"))]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: UUID(), repository: repository)
        XCTAssertNil(model.activeProfileID)
        let mismatchedRequests = await repository.requestCount()
        XCTAssertEqual(mismatchedRequests, 0)

        let profileID = UUID()
        let lateRepository = ContainerManagerRepositoryStub(
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
        let firstA = ContainerManagerRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A1"))]
        )
        let secondA = ContainerManagerRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A2"))]
        )
        let repositoryB = ContainerManagerRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot(marker: "B"))]
        )
        let model = MobileContainerInventoryModel(cacheLimit: 1)
        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        await model.activate(profileID: profileA, repository: secondA)
        XCTAssertEqual(model.state.containers.map(\.name), ["container-A2"])
        let secondRequests = await secondA.requestCount()
        XCTAssertEqual(secondRequests, 1)

        model.purge(profileID: profileA)
        XCTAssertNil(model.activeProfileID)
        model.purgeAll()
        XCTAssertTrue(model.profiles.isEmpty)
    }

    func test白名单事件不保留用户与正文且仓库协议无写能力() throws {
        let item = MobileContainerEventItem(
            ServiceEvent(id: "event", timestamp: nil, level: "warning", user: "private", message: "private")
        )
        XCTAssertEqual(Set(Mirror(reflecting: item).children.compactMap(\.label)), ["id", "timestamp", "level"])

        let source = try source("Sources/Features/ReadOnlyServices/Containers/MobileReadOnlyContainerRepository.swift")
        let protocolSource = try XCTUnwrap(
            source.components(separatedBy: "struct MobileReadOnlyContainerRepository").first
        )
        XCTAssertEqual(protocolSource.components(separatedBy: "func ").count - 1, 1)
        XCTAssertTrue(source.contains("loadContainerManager()"))
        XCTAssertTrue(source.contains("@Sendable () async throws"))
        XCTAssertFalse(source.contains("private let base"))
        for forbidden in ["create", "delete", "start", "stop", "restart", "terminal", "log"] {
            XCTAssertFalse(protocolSource.localizedCaseInsensitiveContains("func \(forbidden)"))
        }
    }

    nonisolated private static func snapshot(
        marker: String,
        unavailable: Set<ContainerManagerSection> = [],
        failed: Set<ContainerManagerSection> = []
    ) -> ContainerManagerSnapshot {
        ContainerManagerSnapshot(
            containers: [ContainerInstance(
                id: "container-\(marker)", name: "container-\(marker)", image: "repo-\(marker):latest",
                project: "private-project", status: "running", cpuUsage: 99, memoryBytes: 1024
            )],
            images: [ContainerImage(
                id: "image-\(marker)", repository: "repo-\(marker)", tag: "latest",
                sizeBytes: 2048, isInUse: true
            )],
            networks: [ContainerNetwork(
                id: "network-\(marker)", name: "network-\(marker)", driver: "bridge",
                connectedContainerCount: 1
            )],
            projects: [ContainerProject(
                id: "project-\(marker)", name: "project-\(marker)", status: "running", containerCount: 1
            )],
            events: [ServiceEvent(
                id: "event-\(marker)", timestamp: Date(timeIntervalSince1970: 1), level: "info",
                user: "private-user", message: "private-message"
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

private actor ContainerManagerRepositoryStub: MobileContainerInventoryReading {
    enum Response: Sendable {
        case success(ContainerManagerSnapshot)
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

    func loadInventory() async throws -> ContainerManagerSnapshot {
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
