import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileVirtualMachineInventoryModelTests: XCTestCase {
    func test首次读取生成安全清单并规范化状态() async {
        let profileID = UUID()
        let repository = VirtualMachineInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "A", status: "powered_on"))]
        )
        let model = MobileVirtualMachineInventoryModel()

        await model.activate(profileID: profileID, repository: repository)

        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertEqual(model.state.items.first?.name, "A")
        XCTAssertEqual(model.state.items.first?.status, .running)
        XCTAssertEqual(model.state.items.first?.cpuCount, 2)
        XCTAssertEqual(model.state.items.first?.memoryBytes, 2_048)
        XCTAssertEqual(model.state.items.first?.storageBytes, 4_096)
        XCTAssertEqual(model.state.items.first?.autoStart, true)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test筛选为空与恢复全部使用稳定枚举() async {
        let profileID = UUID()
        let repository = VirtualMachineInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "A", status: "running"))]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        model.setFilter(.stopped)
        XCTAssertEqual(model.state.pageState, .filteredEmpty)
        XCTAssertTrue(model.state.visibleItems.isEmpty)

        model.setFilter(.all)
        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertEqual(model.state.visibleItems.map(\.name), ["A"])
    }

    func test筛选移除已选虚拟机时详情同步清空() async {
        let profileID = UUID()
        let repository = VirtualMachineInventoryRepositoryStub(
            profileID: profileID,
            responses: [.success(Self.snapshot(marker: "A", status: "running"))]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)
        model.select("vm-A")

        model.setFilter(.stopped)

        XCTAssertNil(model.state.selectedID)
        XCTAssertNil(model.state.selectedItem)
        model.setFilter(.all)
        XCTAssertNil(model.state.selectedItem)
    }

    func test刷新失败保留已有内容并显示非阻断提示() async {
        let profileID = UUID()
        let repository = VirtualMachineInventoryRepositoryStub(
            profileID: profileID,
            responses: [
                .success(Self.snapshot(marker: "before")),
                .failure
            ]
        )
        let model = MobileVirtualMachineInventoryModel()
        await model.activate(profileID: profileID, repository: repository)

        await model.refresh()

        XCTAssertEqual(model.state.pageState, .content)
        XCTAssertEqual(model.state.items.first?.name, "before")
        XCTAssertTrue(model.state.hasRefreshError)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test切换配置档后迟到结果不会覆盖当前清单() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = VirtualMachineInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A"))],
            startsBlocked: true
        )
        let repositoryB = VirtualMachineInventoryRepositoryStub(
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
        XCTAssertEqual(model.state.items.map(\.name), ["B"])
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test返回配置档恢复缓存且手动刷新使用新绑定仓库() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = VirtualMachineInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A1"))]
        )
        let secondA = VirtualMachineInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A2"))]
        )
        let repositoryB = VirtualMachineInventoryRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot(marker: "B"))]
        )
        let model = MobileVirtualMachineInventoryModel(cacheLimit: 2)

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

    func testPurge和缓存上限都会强制下次重新读取() async {
        let profileA = UUID()
        let profileB = UUID()
        let firstA = VirtualMachineInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A1"))]
        )
        let secondA = VirtualMachineInventoryRepositoryStub(
            profileID: profileA,
            responses: [.success(Self.snapshot(marker: "A2"))]
        )
        let repositoryB = VirtualMachineInventoryRepositoryStub(
            profileID: profileB,
            responses: [.success(Self.snapshot(marker: "B"))]
        )
        let model = MobileVirtualMachineInventoryModel(cacheLimit: 1)

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
    }

    func test配置档与仓库不匹配时零请求() async {
        let repository = VirtualMachineInventoryRepositoryStub(
            profileID: UUID(),
            responses: [.success(Self.snapshot(marker: "wrong"))]
        )
        let model = MobileVirtualMachineInventoryModel()

        await model.activate(profileID: UUID(), repository: repository)

        XCTAssertNil(model.activeProfileID)
        let requests = await repository.requestCount()
        XCTAssertEqual(requests, 0)
    }

    func test展示模型只保留移动端允许字段() {
        let item = MobileVirtualMachineItem(
            VirtualMachineInventoryItem(
                id: "id", name: "安全名称", status: "future", cpuCount: 1,
                memoryBytes: 2, storageBytes: 3, autoStart: false
            )
        )

        XCTAssertEqual(item.status, .unknown)
        let labels = Set(Mirror(reflecting: item).children.compactMap(\.label))
        XCTAssertEqual(
            labels,
            ["id", "name", "status", "cpuCount", "memoryBytes", "storageBytes", "autoStart"]
        )
    }

    func test移动仓库协议只暴露配置档与单一读取() throws {
        let source = try source(
            "Sources/Features/ReadOnlyServices/VirtualMachines/MobileReadOnlyVirtualMachineRepository.swift"
        )
        let protocolSource = try XCTUnwrap(
            source.components(separatedBy: "struct MobileReadOnlyVirtualMachineRepository").first
        )
        XCTAssertEqual(protocolSource.components(separatedBy: "func ").count - 1, 1)
        XCTAssertTrue(protocolSource.contains("func loadInventory"))
        for forbidden in ["create", "delete", "start", "stop", "restart", "console", "log"] {
            XCTAssertFalse(protocolSource.localizedCaseInsensitiveContains("func \(forbidden)"))
        }
    }

    private func source(_ path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    nonisolated private static func snapshot(
        marker: String,
        status: String = "running"
    ) -> VirtualMachineInventorySnapshot {
        VirtualMachineInventorySnapshot(
            source: .official,
            machines: [
                VirtualMachineInventoryItem(
                    id: "vm-\(marker)", name: marker, status: status,
                    cpuCount: 2, memoryBytes: 2_048, storageBytes: 4_096, autoStart: true
                )
            ]
        )
    }
}

private actor VirtualMachineInventoryRepositoryStub: MobileVirtualMachineInventoryReading {
    enum Response: Sendable {
        case success(VirtualMachineInventorySnapshot)
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

    func loadInventory() async throws -> VirtualMachineInventorySnapshot {
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
