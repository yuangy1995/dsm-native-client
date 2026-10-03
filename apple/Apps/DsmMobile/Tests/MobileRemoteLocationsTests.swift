import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileRemoteLocationsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; try await super.tearDown() }

    func testVFS完整地址规范化且保存成功后刷新清单() async throws {
        let service = RemoteFixture(), model = try await make(service)
        let draft = configuration(host: "https://server.example.invalid:8443/Remote%20Folder/")
        let success = await model.changeVFS(.create(draft), password: "synthetic-secret")
        XCTAssertTrue(success); XCTAssertTrue(model.pending.isEmpty)
        let calls = await service.vfsCalls
        guard case .create(let saved) = try XCTUnwrap(calls.first) else { return XCTFail("没有创建连接") }
        XCTAssertEqual(saved.protocolID, "davs"); XCTAssertEqual(saved.hostname, "server.example.invalid")
        XCTAssertEqual(saved.port, 8443); XCTAssertEqual(saved.folder, "Remote Folder")
    }

    func test明文连接必须接受明确风险且拒绝缺少权限() async throws {
        let service = RemoteFixture(), model = try await make(service)
        var draft = configuration(); draft.protocolID = "ftp"; draft.port = 21
        let withoutRisk = await model.changeVFS(.create(draft), password: "synthetic-secret")
        XCTAssertFalse(withoutRisk)
        var calls = await service.vfsCalls; XCTAssertTrue(calls.isEmpty)
        await service.setAccess(false); await model.load()
        let denied = await model.changeVFS(.create(draft), confirmedCleartext: true)
        XCTAssertFalse(denied); calls = await service.vfsCalls; XCTAssertTrue(calls.isEmpty)
        await service.setAccess(true); await model.load()
        let allowed = await model.changeVFS(.create(draft), confirmedCleartext: true)
        XCTAssertTrue(allowed)
    }

    func test未知连接只查询原请求且出现的新对象仍禁止重复连接() async throws {
        let service = RemoteFixture(), model = try await make(service)
        await service.setOutcome(.submittedButUnverified)
        let draft = configuration()
        _ = await model.changeVFS(.create(draft), password: "synthetic-secret")
        let entry = try XCTUnwrap(model.pending.first)
        XCTAssertTrue(model.isVFSBlocked(.connect(service.savedProfile)))
        _ = await model.changeVFS(.connect(service.savedProfile))
        _ = await model.changeVFS(.create(draft))
        let before = await service.vfsCalls; XCTAssertEqual(before.count, 1)
        await service.setOutcome(.confirmedSuccess); await model.review(entry)
        let reviews = await service.vfsReviews
        XCTAssertEqual(reviews, before); XCTAssertTrue(model.pending.isEmpty)
    }

    func test重启后未知连接保留限制且不落盘账号密码主机和令牌() async throws {
        let service = RemoteFixture(), root = newRoot(), model = try await make(service, root: root)
        await service.setOutcome(.submittedButUnverified)
        _ = await model.changeVFS(.create(configuration()), password: "synthetic-secret")
        let data = try String(contentsOf: root.appendingPathComponent("remote-locations-v1.json"), encoding: .utf8)
        for secret in ["server.example.invalid", "synthetic-user", "synthetic-secret", "synthetic-token"] { XCTAssertFalse(data.contains(secret)) }
        let restored = try await make(service, root: root)
        XCTAssertTrue(restored.isVFSBlocked(.create(configuration())))
        let entry = try XCTUnwrap(restored.pending.first)
        XCTAssertFalse(restored.canReview(entry)); await restored.review(entry)
        XCTAssertEqual(restored.pending.count, 1)
        let calls = await service.vfsCalls; XCTAssertEqual(calls.count, 1)
    }

    func test损坏或不能保存恢复记录时不提交连接() async throws {
        for corrupt in [true, false] {
            let service = RemoteFixture(), root = newRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = corrupt ? root.appendingPathComponent("remote-locations-v1.json") : root.appendingPathComponent("not-directory")
            let bytes = Data("synthetic-invalid".utf8); try bytes.write(to: target)
            let model = try await make(service, root: corrupt ? root : target)
            _ = await model.changeVFS(.create(configuration()))
            XCTAssertTrue(model.recoveryFailed); XCTAssertEqual(try Data(contentsOf: target), bytes)
            let calls = await service.vfsCalls; XCTAssertTrue(calls.isEmpty)
        }
    }

    func test明确提交前拒绝可修改后再试() async throws {
        let service = RemoteFixture(), model = try await make(service)
        await service.setPreflightFailure(true)
        _ = await model.changeVFS(.create(configuration()))
        XCTAssertTrue(model.pending.isEmpty); XCTAssertNotNil(model.error)
        await service.setPreflightFailure(false)
        let success = await model.changeVFS(.create(configuration()))
        XCTAssertTrue(success)
    }

    func test连接拒绝保留服务器身份或云授权的恢复提示() async throws {
        let service = RemoteFixture(), model = try await make(service)
        await service.setOutcome(.confirmedFailure, message: "files.vfs.identity-check")
        let success = await model.changeVFS(.create(configuration()))
        XCTAssertFalse(success); XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.feedback, L10n.string("files.vfs.identity-check"))
        let calls = await service.vfsCalls; XCTAssertEqual(calls.count, 1)
    }

    func test双击期间只提交一次且换账号的迟到结果不覆盖页面() async throws {
        let service = RemoteFixture(), other = RemoteFixture(), model = try await make(service)
        await service.setWaiting(true)
        let task = Task { await model.changeVFS(.create(configuration())) }
        try await wait { await service.waiting }
        _ = await model.changeVFS(.create(configuration()))
        model.configure(profile: try profile(other.profileID), repository: other); await model.load()
        await service.release(); let lateSuccess = await task.value; XCTAssertFalse(lateSuccess)
        let calls = await service.vfsCalls; XCTAssertEqual(calls.count, 1)
        XCTAssertNil(model.feedback); XCTAssertNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.inventory?.profileID, other.profileID)
    }

    func test相同配置不同账号恢复限制隔离且删除只清理当前配置() async throws {
        let service = RemoteFixture(), second = RemoteFixture(), root = newRoot(), model = try await make(service, root: root)
        await service.setOutcome(.submittedButUnverified); _ = await model.changeVFS(.create(configuration()))
        model.configure(profile: try profile(service.profileID, account: "other"), repository: service); await model.load()
        XCTAssertTrue(model.pending.isEmpty)
        model.configure(profile: try profile(second.profileID), repository: second); await model.load()
        await second.setOutcome(.submittedButUnverified); _ = await model.changeVFS(.create(configuration()))
        model.removeProfile(second.profileID)
        model.configure(profile: try profile(service.profileID), repository: service); await model.load()
        XCTAssertEqual(model.pending.count, 1)
    }

    func testSMB未确认不写且未知阶段锁定父子目标() async throws {
        let service = RemoteFixture(), model = try await make(service)
        let change = MobileRemoteLocationsModel.MountChange.create(setup())
        _ = await model.changeMount(change, confirmed: false)
        var calls = await service.mountCalls; XCTAssertEqual(calls, 0)
        await service.setUnknownMount(true)
        _ = await model.changeMount(change, password: "synthetic-secret", confirmed: true)
        XCTAssertTrue(model.isMountBlocked(["/fixture/mount/child"]))
        XCTAssertTrue(model.isMountBlocked(["/fixture"]))
        XCTAssertFalse(model.isMountBlocked(["/fixture/other"]))
        _ = await model.changeMount(change, confirmed: true)
        calls = await service.mountCalls; XCTAssertEqual(calls, 1)
        let entry = try XCTUnwrap(model.pending.first)
        await service.setReviewedStage(.readyToConnect); await model.review(entry)
        XCTAssertEqual(model.mountOperations[entry.id]?.stage, .readyToConnect)
        let continued = await service.continueCalls; XCTAssertEqual(continued, 0)
    }

    func testSMB继续绑定原任务重新输入密码并保留未知结果() async throws {
        let service = RemoteFixture(), model = try await make(service)
        await service.setUnknownMount(true)
        _ = await model.changeMount(.update(service.mount, setup()), confirmed: true)
        let entry = try XCTUnwrap(model.pending.first)
        await service.setReviewedStage(.readyToConnect); await model.review(entry)
        await model.continueMount(entry, password: "synthetic-new-secret", action: .resume, confirmed: false)
        var continued = await service.continueCalls; XCTAssertEqual(continued, 0)
        await model.continueMount(entry, password: "synthetic-new-secret", action: .resume, confirmed: true)
        continued = await service.continueCalls; XCTAssertEqual(continued, 1)
        let password = await service.continuedPassword; XCTAssertEqual(password, "synthetic-new-secret")
        XCTAssertTrue(model.pending.isEmpty)
    }

    func test未知挂载不能放弃且仅已知剩余步骤可以结束() async throws {
        let service = RemoteFixture(), model = try await make(service)
        await service.setUnknownMount(true)
        _ = await model.changeMount(.create(setup()), confirmed: true)
        let entry = try XCTUnwrap(model.pending.first)
        await model.continueMount(entry, password: "", action: .abandon, confirmed: true)
        var abandoned = await service.abandonCalls; XCTAssertEqual(abandoned, 0)
        await service.setReviewedStage(.readyToDisconnectPrevious); await model.review(entry)
        await model.continueMount(entry, password: "", action: .abandon, confirmed: true)
        abandoned = await service.abandonCalls; XCTAssertEqual(abandoned, 1); XCTAssertTrue(model.pending.isEmpty)
    }

    func testISO未知不重放且与同位置远程挂载互斥() async throws {
        let service = RemoteFixture(), model = try await make(service)
        await service.setOutcome(.submittedButUnverified)
        let change = FileISOMountChange.unmount(.init(profileID: service.profileID, source: "/fixture/synthetic.iso", mountPoint: "/fixture/mount", automaticMount: false))
        _ = await model.changeISO(change); _ = await model.changeISO(change)
        _ = await model.changeMount(.create(setup()), confirmed: true)
        let calls = await service.isoCalls, mounts = await service.mountCalls
        XCTAssertEqual(calls, [change]); XCTAssertEqual(mounts, 0)
        let entry = try XCTUnwrap(model.pending.first)
        await service.setOutcome(.confirmedSuccess); await model.review(entry)
        let reviews = await service.isoReviews; XCTAssertEqual(reviews, [change]); XCTAssertTrue(model.pending.isEmpty)
    }

    func test关闭新挂载后仍可断开已有连接() async throws {
        let service = RemoteFixture(); await service.setMountingEnabled(false)
        let model = try await make(service)
        XCTAssertTrue(model.canManageMounts); XCTAssertFalse(model.canCreateMounts)
        let created = await model.changeMount(.create(setup()), confirmed: true)
        XCTAssertFalse(created)
        let removed = await model.changeMount(.disconnect(service.mount), confirmed: true)
        XCTAssertTrue(removed)
        let calls = await service.mountCalls; XCTAssertEqual(calls, 1)
    }

    func testVFS读取失败不阻断SMB列表且不当作空清单() async throws {
        let service = RemoteFixture(); await service.setVFSReadFailure(true)
        let model = try await make(service)
        XCTAssertNotNil(model.vfsError); XCTAssertNotNil(model.inventory)
        XCTAssertTrue(model.canManageMounts); XCTAssertFalse(model.canManageVFS)
    }

    func test远程目录分页保持URI与筛选并允许进入返回() async throws {
        let service = RemoteFixture(), browser = MobileVFSBrowserModel(repository: service, profile: service.savedProfile)
        await browser.load(reset: true)
        XCTAssertTrue(browser.hasMore); XCTAssertEqual(browser.items.count, 2)
        await browser.load(reset: false)
        XCTAssertEqual(browser.items.count, 3); XCTAssertFalse(browser.hasMore)
        browser.query = "second"; XCTAssertEqual(browser.filtered.count, 1)
        let folder = try XCTUnwrap(browser.items.first(where: \.isDirectory))
        await browser.open(folder); XCTAssertEqual(browser.path, "davs://synthetic-root/folder")
        XCTAssertTrue(browser.query.isEmpty); await browser.back(); XCTAssertEqual(browser.path, "davs://synthetic-root")
        let requests = await service.browseRequests
        XCTAssertEqual(requests.map(\.1), [0, 2, 0, 0])
        XCTAssertEqual(requests[2].0, "davs://synthetic-root/folder")
    }

    private func make(_ service: RemoteFixture, root: URL? = nil) async throws -> MobileRemoteLocationsModel {
        let model = MobileRemoteLocationsModel(rootURL: root ?? newRoot())
        model.configure(profile: try profile(service.profileID), repository: service); await model.load(); return model
    }
    private func newRoot() -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteTests-\(UUID())"); roots.append(url); return url }
    private func profile(_ id: UUID, account: String = "synthetic") throws -> NasProfile {
        try .init(id: id, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: account)
    }
    private func configuration(host: String = "server.example.invalid") -> FileVFSConfiguration {
        .init(protocolID: "davs", hostname: host, port: 443, alias: "Synthetic connection", account: "synthetic-user")
    }
    private func setup() -> RemoteMountSetup {
        .init(.init(protocolType: .smb, server: "server.example.invalid", remotePath: "folder", mountPoint: "/fixture/mount", username: "synthetic-user"))
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTFail("操作未进入等待阶段")
    }
}

private actor RemoteFixture: MobileRemoteLocationServing {
    nonisolated let profileID = UUID()
    nonisolated let allowsRemoteMountManagement = true
    nonisolated var savedProfile: FileVFSProfile {
        .init(profileID: profileID, id: "synthetic-id", protocolID: "davs", protocolName: "WebDAV", uri: "davs://synthetic-root", hostname: "server.example.invalid", port: 443, alias: "Synthetic connection", account: "synthetic-user", codepage: "UTF-8", state: .connected)
    }
    nonisolated var mount: RemoteMountConnection {
        .init(profileID: profileID, mountPoint: "/fixture/mount", source: "//old.example.invalid/folder", protocolType: .smb, automaticMount: false)
    }
    private var allowed = true
    private var preflightFailure = false
    private var outcome: MutationResultStatus = .confirmedSuccess
    private var outcomeMessage: String?
    private var waits = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    private var vfsReadFailure = false
    private var mountingEnabled = true
    private var unknownMount = false
    private var reviewedStage: RemoteMountOperationStage = .verifyingConnection
    private var operation: RemoteMountOperation?
    var vfsCalls: [FileVFSChange] = []
    var vfsReviews: [FileVFSChange] = []
    var isoCalls: [FileISOMountChange] = []
    var isoReviews: [FileISOMountChange] = []
    var mountCalls = 0
    var continueCalls = 0
    var abandonCalls = 0
    var continuedPassword = ""
    var browseRequests: [(String, Int)] = []
    func setAccess(_ value: Bool) { allowed = value }
    func setOutcome(_ value: MutationResultStatus, message: String? = nil) { outcome = value; outcomeMessage = message }
    func setPreflightFailure(_ value: Bool) { preflightFailure = value }
    func setWaiting(_ value: Bool) { waits = value }
    func setMountingEnabled(_ value: Bool) { mountingEnabled = value }
    func setUnknownMount(_ value: Bool) { unknownMount = value }
    func setReviewedStage(_ value: RemoteMountOperationStage) { reviewedStage = value }
    func setVFSReadFailure(_ value: Bool) { vfsReadFailure = value }
    func release() { waits = false; continuation?.resume(); continuation = nil }
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess { .init(isAdministrator: true, writesEnabled: allowed) }
    func remoteMountInventory() async throws -> RemoteMountInventory {
        .init(profileID: profileID, isRemoteMountingEnabled: mountingEnabled, connections: [], isoConnections: [], isISOMountingEnabled: true)
    }
    func listFileVFSProtocols() async throws -> [FileVFSProtocol] {
        [.init(id: "davs", name: "WebDAV", defaultPort: 443, hasConnections: false), .init(id: "ftp", name: "FTP", defaultPort: 21, hasConnections: false)]
    }
    func listFileVFSProfiles() async throws -> [FileVFSProfile] { if vfsReadFailure { throw URLError(.networkConnectionLost) }; return [] }
    func loadFileVFSDetail(_ profile: FileVFSProfile) async throws -> FileVFSDetail {
        .init(profile: profile, configuration: .init(protocolID: "davs", hostname: "server.example.invalid", port: 443, alias: "Synthetic connection", account: "synthetic-user"))
    }
    func listFileVFSFolder(_ profile: FileVFSProfile, path: String, offset: Int, limit: Int) async throws -> FilePage {
        browseRequests.append((path, offset))
        if path.hasSuffix("/folder") { return .init(folderPath: path, items: [], offset: 0, total: 0, hasMore: false) }
        let items: [FileItem] = offset == 0 ? [.init(profileID: profileID, name: "Folder", path: path + "/folder", kind: .directory),
            .init(profileID: profileID, name: "First.txt", path: path + "/first.txt", kind: .file)]
            : [.init(profileID: profileID, name: "Second.txt", path: path + "/second.txt", kind: .file)]
        return .init(folderPath: path, items: items, offset: offset, total: 3, hasMore: offset == 0)
    }
    func changeFileVFS(_ change: FileVFSChange, password: String?, confirmed: Bool) async throws -> MutationResult {
        if preflightFailure { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "Synthetic failure") }
        vfsCalls.append(change)
        if waits { await withCheckedContinuation { continuation = $0 } }
        return try result()
    }
    func reviewFileVFS(_ change: FileVFSChange) async throws -> MutationResult { vfsReviews.append(change); return try result() }
    func prepareFileVFSCloudAuthorization(protocolID: String) async throws -> FileVFSCloudAuthorizationRequest { throw URLError(.unsupportedURL) }
    func authorizeFileVFS(_ change: FileVFSChange, authorization: FileVFSCloudAuthorization, confirmed: Bool) async throws -> MutationResult {
        vfsCalls.append(change); return try result()
    }
    func getInfo(paths: [String]) async throws -> [FileItem] { paths.map { .init(profileID: profileID, name: "Folder", path: $0, kind: .directory) } }
    func changeISOMount(_ change: FileISOMountChange) async throws -> MutationResult { isoCalls.append(change); return try result() }
    func reviewISOMount(_ change: FileISOMountChange) async throws -> MutationResult { isoReviews.append(change); return try result() }
    func createRemoteMount(_ configuration: RemoteMountConfiguration) async throws { try changeMount(.create, old: nil, setup: configuration) }
    func updateRemoteMount(expectedConnection: RemoteMountConnection, configuration: RemoteMountConfiguration) async throws { try changeMount(.update, old: expectedConnection, setup: configuration) }
    func removeRemoteMount(expectedConnection: RemoteMountConnection) async throws { try changeMount(.disconnect, old: expectedConnection, setup: nil) }
    private func changeMount(_ action: RemoteMountOperationAction, old: RemoteMountConnection?, setup: RemoteMountConfiguration?) throws {
        mountCalls += 1
        if unknownMount {
            operation = .init(id: UUID(), profileID: profileID, action: action, baseline: old, setup: setup.map(RemoteMountSetup.init), stage: .verifyingConnection)
            throw URLError(.networkConnectionLost)
        }
    }
    func pendingRemoteMountOperations() async -> [RemoteMountOperation] { operation.map { $0.stage.isTerminal ? [] : [$0] } ?? [] }
    func reviewRemoteMountOperation(id: UUID) async throws -> RemoteMountOperation? {
        guard operation?.id == id else { return nil }; operation = operation?.replacingStage(reviewedStage); return operation
    }
    func continueRemoteMountOperation(id: UUID, password: String, confirmed: Bool) async throws -> RemoteMountOperation? {
        guard operation?.id == id, confirmed else { return nil }
        continueCalls += 1; continuedPassword = password; operation = operation?.replacingStage(.completed); return operation
    }
    func abandonRemoteMountOperation(id: UUID, confirmed: Bool) async throws -> RemoteMountOperation? {
        guard operation?.id == id, confirmed else { return nil }
        abandonCalls += 1; operation = operation?.replacingStage(.cancelled); return operation
    }
    private func result() throws -> MutationResult {
        let unknown = outcome == .submittedButUnverified
        return try .init(status: outcome, operation: "fileStationRemoteConnection", submitted: true, requiresRefresh: unknown,
            counts: .init(succeeded: outcome == .confirmedSuccess ? 1 : 0, failed: outcome == .confirmedFailure ? 1 : 0, unknown: unknown ? 1 : 0),
            localizationKey: outcomeMessage, diagnosticTag: "synthetic.remote")
    }
}
