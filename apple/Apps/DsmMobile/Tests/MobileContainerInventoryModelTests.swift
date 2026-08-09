import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileContainerInventoryModelTests: XCTestCase {
    func test首次读取生成白名单清单并规范化状态() async {
        let profileID = UUID()
        let repository = ContainerInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot([("A", "running")]))]
        )
        let model = MobileContainerInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertEqual(model.state.items.first?.name, "A")
        XCTAssertEqual(model.state.items.first?.status, .running)
        XCTAssertEqual(model.state.items.first?.image, "demo:latest")
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test筛选和选择只保留当前可见规范对象() async {
        let profileID = UUID()
        let repository = ContainerInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot([
                ("running", "up"),
                ("stopped", "exited"),
                ("attention", "restarting"),
                ("unknown", "future"),
            ]))]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        model.select("container-running")
        XCTAssertEqual(model.state.selectedItem?.name, "running")
        model.setFilter(.stopped)
        XCTAssertEqual(model.state.visibleItems.map(\.name), ["stopped"])
        XCTAssertNil(model.state.selectedItem)
        model.select("container-running")
        XCTAssertNil(model.state.selectedID)
        model.setFilter(.attention)
        XCTAssertEqual(Set(model.state.visibleItems.map(\.name)), ["attention", "unknown"])
    }

    func test刷新失败保留已有内容并显示非阻断提示() async {
        let profileID = UUID()
        let repository = ContainerInventoryRepositoryStub(
            profileID: profileID,
            responses: [
                .success(Self.snapshot([("before", "running")])),
                .failure,
            ]
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.refresh()

        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertEqual(model.state.items.map(\.name), ["before"])
        XCTAssertTrue(model.state.hasRefreshError)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test切换配置档后迟到结果不会覆盖当前清单() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = ContainerInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot([("A", "running")]))],
            startsBlocked: true
        )
        let repositoryB = ContainerInventoryRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot([("B", "stopped")]))]
        )
        let model = MobileContainerInventoryModel()

        let loadA = Task { await model.activate(profileID: profileA, repository: repositoryA) }
        await repositoryA.waitUntilBlocked()
        await model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.release()
        await loadA.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state.items.map(\.name), ["B"])
    }

    func test返回配置档恢复缓存且手动刷新使用替换后的仓库() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = ContainerInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot([("A1", "running")]))]
        )
        let secondA = ContainerInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot([("A2", "running")]))]
        )
        let repositoryB = ContainerInventoryRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot([("B", "stopped")]))]
        )
        let model = MobileContainerInventoryModel(cacheLimit: 2)

        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        await model.activate(profileID: profileA, repository: secondA)
        XCTAssertEqual(model.state.items.map(\.name), ["A1"])
        let secondRequestsBeforeRefresh = await secondA.requestCount()
        XCTAssertEqual(secondRequestsBeforeRefresh, 0)

        await model.refresh()

        XCTAssertEqual(model.state.items.map(\.name), ["A2"])
        let secondRequests = await secondA.requestCount()
        let firstRequests = await firstA.requestCount()
        XCTAssertEqual(secondRequests, 1)
        XCTAssertEqual(firstRequests, 1)
    }

    func testLRU淘汰和Purge强制下次重新读取() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = ContainerInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot([("A1", "running")]))]
        )
        let secondA = ContainerInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot([("A2", "running")]))]
        )
        let repositoryB = ContainerInventoryRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot([("B", "stopped")]))]
        )
        let model = MobileContainerInventoryModel(cacheLimit: 1)

        await model.activate(profileID: profileA, repository: firstA)
        await model.activate(profileID: profileB, repository: repositoryB)
        await model.activate(profileID: profileA, repository: secondA)
        XCTAssertEqual(model.state.items.map(\.name), ["A2"])
        let secondRequests = await secondA.requestCount()
        XCTAssertEqual(secondRequests, 1)

        model.purge(profileID: profileA)
        XCTAssertNil(model.activeProfileID)
        model.purgeAll()
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertEqual(MobileContainerInventoryModel.defaultCacheLimit, 4)
    }

    func test配置档与仓库不匹配时零请求() async {
        let repository = ContainerInventoryRepositoryStub(
            profileID: UUID(),
            responses: [.success(Self.snapshot([("wrong", "running")]))]
        )
        let model = MobileContainerInventoryModel()

        await model.activate(profileID: UUID(), repository: repository)

        XCTAssertNil(model.activeProfileID)
        let requests = await repository.requestCount()
        XCTAssertEqual(requests, 0)
    }

    func test离开页面取消读取且保留已有缓存() async {
        let profileID = UUID()
        let initial = ContainerInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot([("cached", "running")]))]
        )
        let blocked = ContainerInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot([("late", "stopped")]))],
            startsBlocked: true
        )
        let model = MobileContainerInventoryModel()
        await model.activate(profileID: profileID, repository: initial)
        model.deactivate()
        await model.activate(profileID: profileID, repository: blocked)
        let refresh = Task { await model.refresh() }
        await blocked.waitUntilBlocked()

        model.deactivate()
        await blocked.release()
        await refresh.value

        XCTAssertNil(model.activeProfileID)
        XCTAssertEqual(model.profiles[profileID]?.items.map(\.name), ["cached"])
        XCTAssertFalse(model.profiles[profileID]?.isRefreshing ?? true)
    }

    func test移动仓库协议只暴露配置档与单一读取() throws {
        let source = try source(
            "Sources/Features/ReadOnlyServices/Containers/MobileReadOnlyContainerRepository.swift"
        )
        let protocolSource = try XCTUnwrap(
            source.components(separatedBy: "struct MobileReadOnlyContainerRepository").first
        )
        XCTAssertEqual(protocolSource.components(separatedBy: "func ").count - 1, 1)
        XCTAssertTrue(protocolSource.contains("func loadInventory"))
        for forbidden in ["create", "delete", "start", "stop", "restart", "process", "console", "log"] {
            XCTAssertFalse(protocolSource.localizedCaseInsensitiveContains("func \(forbidden)"))
        }
    }

    private func source(_ path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    nonisolated private static func snapshot(
        _ values: [(name: String, status: String)]
    ) -> ContainerInventorySnapshot {
        ContainerInventorySnapshot(
            source: .internalAPI,
            containers: values.map {
                ContainerInventoryItem(
                    id: "container-\($0.name)",
                    name: $0.name,
                    status: $0.status,
                    image: "demo:latest"
                )
            }
        )
    }
}

private actor ContainerInventoryRepositoryStub: MobileContainerInventoryReading {
    enum Response: Sendable {
        case success(ContainerInventorySnapshot)
        case failure
    }

    nonisolated let profileID: UUID
    private var responses: [Response]
    private var requests = 0
    private var isBlocked: Bool
    private var didEnterBlock = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(profileID: UUID, responses: [Response], startsBlocked: Bool = false) {
        self.profileID = profileID
        self.responses = responses
        isBlocked = startsBlocked
    }

    func loadInventory() async throws -> ContainerInventorySnapshot {
        requests += 1
        if isBlocked {
            didEnterBlock = true
            await withCheckedContinuation { continuation = $0 }
        }
        guard !responses.isEmpty else { throw StubError.failed }
        switch responses.removeFirst() {
        case .success(let snapshot): return snapshot
        case .failure: throw StubError.failed
        }
    }

    func waitUntilBlocked() async {
        while !didEnterBlock { await Task.yield() }
    }

    func release() {
        isBlocked = false
        continuation?.resume()
        continuation = nil
    }

    func requestCount() -> Int { requests }

    private enum StubError: Error { case failed }
}
