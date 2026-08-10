import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileNasDetailsModelTests: XCTestCase {
    func test激活不请求且用户进入后仅加载所选分区() async {
        let profileID = UUID()
        let repository = NasDetailsRepositoryStub(profileID: profileID, marker: "packages")
        let model = MobileNasDetailsModel()

        model.activate(profileID: profileID, repository: repository)
        let requestsAfterActivation = await repository.totalRequestCount()
        XCTAssertEqual(requestsAfterActivation, 0)

        await model.loadIfNeeded(.packages)

        XCTAssertEqual(model.state.packages.phase, .content)
        XCTAssertEqual(model.state.packages.value?.items.first?.name, "packages")
        let packageRequests = await repository.requestCount(.packages)
        let taskRequests = await repository.requestCount(.scheduledTasks)
        let logRequests = await repository.requestCount(.logs)
        let connectionRequests = await repository.requestCount(.connections)
        XCTAssertEqual(packageRequests, 1)
        XCTAssertEqual(taskRequests, 0)
        XCTAssertEqual(logRequests, 0)
        XCTAssertEqual(connectionRequests, 0)
    }

    func test四分区独立覆盖正常空错误与不可用() async {
        let profileID = UUID()
        let repository = NasDetailsRepositoryStub(profileID: profileID, marker: "safe")
        await repository.setOutcome(.empty, for: .scheduledTasks)
        await repository.setOutcome(.failure, for: .logs)
        await repository.setOutcome(.unavailable, for: .connections)
        let model = MobileNasDetailsModel()
        model.activate(profileID: profileID, repository: repository)

        await model.refresh(.packages)
        await model.refresh(.scheduledTasks)
        await model.refresh(.logs)
        await model.refresh(.connections)

        XCTAssertEqual(model.state.packages.phase, .content)
        XCTAssertEqual(model.state.scheduledTasks.phase, .empty)
        XCTAssertEqual(model.state.logs.phase, .error)
        XCTAssertEqual(model.state.connections.phase, .unavailable)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test刷新失败保留已有内容并仅标记当前分区() async {
        let profileID = UUID()
        let repository = NasDetailsRepositoryStub(profileID: profileID, marker: "before")
        let model = MobileNasDetailsModel()
        model.activate(profileID: profileID, repository: repository)
        await model.refresh(.packages)
        await repository.setMarker("after")
        await repository.setOutcome(.failure, for: .packages)

        await model.refresh(.packages)

        XCTAssertEqual(model.state.packages.phase, .content)
        XCTAssertEqual(model.state.packages.value?.items.first?.name, "before")
        XCTAssertTrue(model.state.packages.hasRefreshError)
        XCTAssertEqual(model.state.scheduledTasks.phase, .idle)
    }

    func test取消真实传到底层且迟到结果零回写() async {
        let profileID = UUID()
        let repository = NasDetailsRepositoryStub(
            profileID: profileID,
            marker: "late",
            blocked: [.packages]
        )
        let model = MobileNasDetailsModel()
        model.activate(profileID: profileID, repository: repository)

        let load = Task { await model.refresh(.packages) }
        await repository.waitUntilRequested(.packages)
        model.cancel(.packages)
        await repository.waitUntilCancelled(.packages)
        await repository.release(.packages)
        await load.value

        XCTAssertEqual(model.state.packages.phase, .idle)
        XCTAssertNil(model.state.packages.value)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test切换配置档和离页均拒绝迟到结果() async {
        let profileA = UUID()
        let profileB = UUID()
        let repositoryA = NasDetailsRepositoryStub(
            profileID: profileA,
            marker: "A-late",
            blocked: [.packages]
        )
        let repositoryB = NasDetailsRepositoryStub(
            profileID: profileB,
            marker: "B-late",
            blocked: [.logs]
        )
        let model = MobileNasDetailsModel()

        model.activate(profileID: profileA, repository: repositoryA)
        let loadA = Task { await model.refresh(.packages) }
        await repositoryA.waitUntilRequested(.packages)
        model.activate(profileID: profileB, repository: repositoryB)
        await repositoryA.release(.packages)
        await loadA.value

        XCTAssertEqual(model.activeProfileID, profileB)
        XCTAssertEqual(model.state, MobileNasDetailsState())

        let loadB = Task { await model.refresh(.logs) }
        await repositoryB.waitUntilRequested(.logs)
        model.deactivate()
        await repositoryB.release(.logs)
        await loadB.value

        XCTAssertNil(model.activeProfileID)
        XCTAssertEqual(model.state, MobileNasDetailsState())
    }

    func test全局刷新仅重载用户已经进入过的分区() async {
        let profileID = UUID()
        let repository = NasDetailsRepositoryStub(profileID: profileID, marker: "safe")
        await repository.setOutcome(.empty, for: .scheduledTasks)
        let model = MobileNasDetailsModel()
        model.activate(profileID: profileID, repository: repository)
        await model.refresh(.packages)
        await model.refresh(.scheduledTasks)

        await model.refreshLoadedSections()

        let packageRequests = await repository.requestCount(.packages)
        let taskRequests = await repository.requestCount(.scheduledTasks)
        let logRequests = await repository.requestCount(.logs)
        let connectionRequests = await repository.requestCount(.connections)
        XCTAssertEqual(packageRequests, 2)
        XCTAssertEqual(taskRequests, 2)
        XCTAssertEqual(logRequests, 0)
        XCTAssertEqual(connectionRequests, 0)
    }

    func test配置档与仓库不匹配时零请求且无活动绑定() async {
        let repository = NasDetailsRepositoryStub(profileID: UUID(), marker: "wrong")
        let model = MobileNasDetailsModel()

        model.activate(profileID: UUID(), repository: repository)
        await model.refresh(.packages)

        XCTAssertNil(model.activeProfileID)
        let requestCount = await repository.totalRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func test展示模型严格限制为已批准白名单() {
        XCTAssertEqual(
            Self.labels(
                MobileNasPackageDetail(id: 0, name: "Package", version: "1", status: .running)
            ),
            ["id", "name", "status", "version"]
        )
        XCTAssertEqual(
            Self.labels(
                MobileNasScheduledTaskDetail(
                    id: 0,
                    name: "Task",
                    isEnabled: true,
                    nextTriggerDescription: "Tomorrow"
                )
            ),
            ["id", "isEnabled", "name", "nextTriggerDescription"]
        )
        XCTAssertEqual(
            Self.labels(
                MobileNasLogDetail(id: 0, date: nil, source: "System", level: .information)
            ),
            ["date", "id", "level", "source"]
        )
        XCTAssertEqual(
            Self.labels(
                MobileNasConnectionDetail(
                    id: 0,
                    protocolName: "HTTPS",
                    type: "DSM",
                    connectedAt: nil,
                    isCurrentConnection: true
                )
            ),
            ["connectedAt", "id", "isCurrentConnection", "protocolName", "type"]
        )
    }

    func test只读适配协议四项且分页与隐私边界冻结() throws {
        let source = try Self.source("MobileReadOnlyNasDetailsRepository.swift")
        let protocolSource = try XCTUnwrap(
            source.components(separatedBy: "struct MobileReadOnlyNasDetailsRepository").first
        )

        XCTAssertEqual(protocolSource.components(separatedBy: "func ").count - 1, 4)
        for required in ["loadPackages", "loadScheduledTasks", "loadLogs", "loadConnections"] {
            XCTAssertTrue(protocolSource.contains("func \(required)"))
        }
        for forbidden in [
            "save", "delete", "run", "start", "stop", "disconnect", "install", "upgrade",
            "account", "message", "address"
        ] {
            XCTAssertFalse(protocolSource.localizedCaseInsensitiveContains("func \(forbidden)"))
        }

        XCTAssertTrue(source.contains("static let packageLimit = 100"))
        XCTAssertTrue(source.contains("static let scheduledTaskLimit = 100"))
        XCTAssertTrue(source.contains("static let pageLimit = 50"))
        XCTAssertTrue(source.contains("loadLogs(offset: 0, limit: Self.pageLimit)"))
        XCTAssertTrue(source.contains("loadConnections(offset: 0, limit: Self.pageLimit)"))
        XCTAssertTrue(source.contains("prefix(Self.packageLimit)"))
        XCTAssertTrue(source.contains("prefix(Self.scheduledTaskLimit)"))
        for forbiddenProjection in [
            "value.owner", "value.realOwner", "value.action", "value.message", "value.account",
            "value.location", "value.description", "value.processID", "value.deviceID", "value.id",
            "value.installedAt", "value.isUpgradeAvailable"
        ] {
            XCTAssertFalse(source.contains(forbiddenProjection))
        }
    }

    private static func labels(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    private static func source(_ name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: appRoot
                .appendingPathComponent("Sources/Features/Administration")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}

final class MobileNasDetailsPresentationTests: XCTestCase {
    func test界面覆盖独立六态原生适配刷新恢复与离页取消() throws {
        let viewSource = try Self.source("MobileNasDetailsView.swift")
        let settingsSource = try Self.source("MobileNasSettingsView.swift")

        for state in [".idle", ".loading", ".empty", ".error", ".unavailable", ".content"] {
            XCTAssertTrue(viewSource.contains(state), "缺少状态分支：\(state)")
        }
        for required in [
            ".listStyle(.insetGrouped)", ".refreshable", ".navigationBarTitleDisplayMode(.inline)",
            ".fillsAvailableContentArea", "minHeight: 44", ".accessibilityElement",
            ".accessibilityLabel", ".task(id: destination)", ".onDisappear",
            "model.cancel(destination)"
        ] {
            XCTAssertTrue(viewSource.contains(required), "界面缺少：\(required)")
        }
        XCTAssertTrue(settingsSource.contains("horizontalSizeClass == .regular"))
        XCTAssertTrue(settingsSource.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(settingsSource.contains("model.nasDetailsModel.deactivate()"))
        XCTAssertFalse(viewSource.contains(".animation("))
        XCTAssertFalse(viewSource.contains("withAnimation"))
        XCTAssertFalse(viewSource.contains("font(.system(size:"))
    }

    func test界面不引用敏感字段或任何管理入口() throws {
        let source = try Self.source("MobileNasDetailsView.swift")
        for forbidden in [
            ".owner", ".realOwner", ".account", "item.message", "value.message",
            ".address", ".location",
            ".description", ".processID", ".deviceID", "disconnect", "controlPackage",
            "saveScheduledTask", "runScheduledTask", "setScheduledTaskEnabled",
            "deleteScheduledTask", "installedAt", "isUpdateAvailable"
        ] {
            XCTAssertFalse(source.contains(forbidden), "界面不应引用：\(forbidden)")
        }
    }

    func test界面只引用冻结的双语资源键清单() throws {
        let source = try Self.source("MobileNasDetailsView.swift")
        let expression = try NSRegularExpression(pattern: #"mobile\.nas-details\.[a-z0-9.-]+"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let actual = Set(expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        })

        XCTAssertEqual(actual, Self.expectedResourceKeys)
    }

    private static func source(_ name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: appRoot
                .appendingPathComponent("Sources/Features/Administration")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private static let expectedResourceKeys: Set<String> = [
        "mobile.nas-details.connection.current",
        "mobile.nas-details.connections.empty.message",
        "mobile.nas-details.connections.empty.title",
        "mobile.nas-details.error.message",
        "mobile.nas-details.error.title",
        "mobile.nas-details.field.connected-at",
        "mobile.nas-details.field.next-trigger",
        "mobile.nas-details.field.source",
        "mobile.nas-details.field.status",
        "mobile.nas-details.field.time",
        "mobile.nas-details.field.type",
        "mobile.nas-details.field.version",
        "mobile.nas-details.loading.connections",
        "mobile.nas-details.loading.logs",
        "mobile.nas-details.loading.packages",
        "mobile.nas-details.loading.scheduled-tasks",
        "mobile.nas-details.log.level.error",
        "mobile.nas-details.log.level.information",
        "mobile.nas-details.log.level.unknown",
        "mobile.nas-details.log.level.warning",
        "mobile.nas-details.logs.empty.message",
        "mobile.nas-details.logs.empty.title",
        "mobile.nas-details.package.status.needs-attention",
        "mobile.nas-details.package.status.running",
        "mobile.nas-details.package.status.stopped",
        "mobile.nas-details.package.status.unknown",
        "mobile.nas-details.packages.empty.message",
        "mobile.nas-details.packages.empty.title",
        "mobile.nas-details.partial",
        "mobile.nas-details.read-only.notice",
        "mobile.nas-details.refresh.failed",
        "mobile.nas-details.scheduled-tasks.empty.message",
        "mobile.nas-details.scheduled-tasks.empty.title",
        "mobile.nas-details.section.connections",
        "mobile.nas-details.section.logs",
        "mobile.nas-details.section.packages",
        "mobile.nas-details.section.scheduled-tasks",
        "mobile.nas-details.task.disabled",
        "mobile.nas-details.task.enabled",
        "mobile.nas-details.unavailable.message",
        "mobile.nas-details.unavailable.title",
        "mobile.nas-details.value.unavailable"
    ]
}

private enum NasDetailsRequest: CaseIterable, Hashable, Sendable {
    case packages
    case scheduledTasks
    case logs
    case connections
}

private enum NasDetailsOutcome: Equatable, Sendable {
    case content
    case empty
    case failure
    case unavailable
}

private enum NasDetailsStubError: Error { case failed }

private actor NasDetailsRepositoryStub: MobileNasDetailsReading {
    nonisolated let profileID: UUID
    private var marker: String
    private var outcomes: [NasDetailsRequest: NasDetailsOutcome] = [:]
    private var blocked: Set<NasDetailsRequest>
    private var requestCounts: [NasDetailsRequest: Int] = [:]
    private var releases: [NasDetailsRequest: [CheckedContinuation<Void, Never>]] = [:]
    private var requestWaiters: [NasDetailsRequest: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelled = Set<NasDetailsRequest>()
    private var cancellationWaiters: [NasDetailsRequest: [CheckedContinuation<Void, Never>]] = [:]

    init(profileID: UUID, marker: String, blocked: Set<NasDetailsRequest> = []) {
        self.profileID = profileID
        self.marker = marker
        self.blocked = blocked
    }

    func loadPackages() async throws -> MobileNasBoundedPage<MobileNasPackageDetail> {
        let outcome = try await begin(.packages)
        let items = outcome == .empty
            ? []
            : [MobileNasPackageDetail(id: 0, name: marker, version: "1", status: .running)]
        return MobileNasBoundedPage(items: items, total: items.count, isTruncated: false)
    }

    func loadScheduledTasks() async throws -> MobileNasBoundedPage<MobileNasScheduledTaskDetail> {
        let outcome = try await begin(.scheduledTasks)
        let items = outcome == .empty
            ? []
            : [
                MobileNasScheduledTaskDetail(
                    id: 0,
                    name: marker,
                    isEnabled: true,
                    nextTriggerDescription: "Tomorrow"
                )
            ]
        return MobileNasBoundedPage(items: items, total: items.count, isTruncated: false)
    }

    func loadLogs() async throws -> MobileNasBoundedPage<MobileNasLogDetail> {
        let outcome = try await begin(.logs)
        let items = outcome == .empty
            ? []
            : [MobileNasLogDetail(id: 0, date: nil, source: marker, level: .information)]
        return MobileNasBoundedPage(items: items, total: items.count, isTruncated: false)
    }

    func loadConnections() async throws -> MobileNasBoundedPage<MobileNasConnectionDetail> {
        let outcome = try await begin(.connections)
        let items = outcome == .empty
            ? []
            : [
                MobileNasConnectionDetail(
                    id: 0,
                    protocolName: marker,
                    type: "DSM",
                    connectedAt: nil,
                    isCurrentConnection: true
                )
            ]
        return MobileNasBoundedPage(items: items, total: items.count, isTruncated: false)
    }

    func setMarker(_ marker: String) {
        self.marker = marker
    }

    func setOutcome(_ outcome: NasDetailsOutcome, for request: NasDetailsRequest) {
        outcomes[request] = outcome
    }

    func requestCount(_ request: NasDetailsRequest) -> Int {
        requestCounts[request, default: 0]
    }

    func totalRequestCount() -> Int {
        requestCounts.values.reduce(0, +)
    }

    func waitUntilRequested(_ request: NasDetailsRequest) async {
        if requestCounts[request, default: 0] > 0 { return }
        await withCheckedContinuation { continuation in
            requestWaiters[request, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ request: NasDetailsRequest) async {
        if cancelled.contains(request) { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[request, default: []].append(continuation)
        }
    }

    func release(_ request: NasDetailsRequest) {
        blocked.remove(request)
        let continuations = releases.removeValue(forKey: request) ?? []
        for continuation in continuations { continuation.resume() }
    }

    private func begin(_ request: NasDetailsRequest) async throws -> NasDetailsOutcome {
        requestCounts[request, default: 0] += 1
        let waiters = requestWaiters.removeValue(forKey: request) ?? []
        for waiter in waiters { waiter.resume() }

        if blocked.contains(request) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    releases[request, default: []].append(continuation)
                }
            } onCancel: {
                Task { await self.recordCancellation(request) }
            }
        }

        switch outcomes[request, default: .content] {
        case .content, .empty:
            return outcomes[request, default: .content]
        case .failure:
            throw NasDetailsStubError.failed
        case .unavailable:
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: "Unavailable"
            )
        }
    }

    private func recordCancellation(_ request: NasDetailsRequest) {
        cancelled.insert(request)
        let waiters = cancellationWaiters.removeValue(forKey: request) ?? []
        for waiter in waiters { waiter.resume() }
    }
}
