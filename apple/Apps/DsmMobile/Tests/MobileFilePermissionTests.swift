import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileFilePermissionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []
        try await super.tearDown()
    }

    func test权限保存只提交显式规则且保留完整继承基线() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await model.load(repository.item)
        XCTAssertEqual(model.rules.count, 1); XCTAssertEqual(model.snapshot?.rules.count, 2)
        model.rules[0].rights.insert(.writeData)
        XCTAssertTrue(model.canSave); model.requestConfirmation(); await model.confirmChanges()
        let calls = await repository.changes
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].explicitRules?.count, 1)
        XCTAssertEqual(calls[0].baseline.rules.last?.level, 1)
        XCTAssertEqual(calls[0].confirmedAccessRemoval, true)
        XCTAssertFalse(calls[0].confirmedScope)
        XCTAssertEqual(model.result?.status, .confirmedSuccess); XCTAssertFalse(model.isBlocked)
        XCTAssertEqual(model.rules.first?.rights.contains(.writeData), true)
    }

    func test只读或高级权限不足不能保存() async throws {
        for editable in [true, false] {
            let repository = PermissionRepository(editable: editable)
            if editable { await repository.setAccess(false) }
            let model = try make(repository); await model.load(repository.item)
            XCTAssertNotNil(model.snapshot); XCTAssertFalse(model.canEdit)
            model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
            let calls = await repository.changes; XCTAssertTrue(calls.isEmpty)
        }
    }

    func test继承规则不可混入草稿且取消确认不写入() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await model.load(repository.item)
        model.rules[0].rights.insert(.writeData); model.requestConfirmation(); model.cancelConfirmation()
        await model.confirmChanges()
        model.rules.append(try XCTUnwrap(model.snapshot?.rules.last)); XCTAssertFalse(model.canSave)
        model.requestConfirmation(); await model.confirmChanges()
        let calls = await repository.changes; XCTAssertTrue(calls.isEmpty)
    }

    func test确认后草稿改变不沿用旧确认() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await model.load(repository.item); model.rules[0].rights.insert(.writeData); model.requestConfirmation()
        model.recursive = true; await model.confirmChanges()
        let calls = await repository.changes; XCTAssertTrue(calls.isEmpty); XCTAssertNil(model.pendingConfirmation)
        model.requestConfirmation(); await model.confirmChanges()
        let confirmed = await repository.changes
        XCTAssertEqual(confirmed.count, 1); XCTAssertTrue(confirmed[0].recursive); XCTAssertTrue(confirmed[0].confirmedScope)
    }

    func test所有者和群组采用实际成员并保持类型限制() async throws {
        let repository = PermissionRepository(acl: false), model = try make(repository)
        await model.load(repository.item)
        model.apply([.init(name: "other-group", kind: .group)], role: .owner)
        XCTAssertNil(model.owner); XCTAssertNotNil(model.error)
        model.apply([.init(name: "other-user", kind: .user)], role: .owner)
        model.apply([.init(name: "other-group", kind: .group)], role: .group)
        XCTAssertTrue(model.canSave); model.requestConfirmation(); await model.confirmChanges()
        let last = await repository.lastChange()
        let request = try XCTUnwrap(last)
        XCTAssertEqual(request.owner?.name, "other-user"); XCTAssertEqual(request.group?.name, "other-group")
        XCTAssertTrue(request.confirmedOwner); XCTAssertNil(request.posixMode)
    }

    func test普通文件不接受应用到子项且权限移除有明确风险() async throws {
        let repository = PermissionRepository(directory: false), model = try make(repository)
        await model.load(repository.item); model.rules[0].rights.remove(.readData)
        XCTAssertTrue(model.removesAccess); model.recursive = true; XCTAssertFalse(model.canSave)
        model.recursive = false; XCTAssertTrue(model.canSave)
        model.rules[0].effect = .deny; XCTAssertTrue(model.removesAccess)
    }

    func testPOSIX三位权限不转换为错误整数并拒绝无效数字() async throws {
        let repository = PermissionRepository(acl: false), model = try make(repository)
        await model.load(repository.item); model.mode = "988"; XCTAssertFalse(model.canSave)
        model.mode = "64"; XCTAssertFalse(model.canSave)
        model.mode = "640"; XCTAssertTrue(model.canSave); XCTAssertTrue(model.removesAccess)
        model.requestConfirmation(); await model.confirmChanges()
        let last = await repository.lastChange()
        let request = try XCTUnwrap(last)
        XCTAssertEqual(request.posixMode, "640"); XCTAssertNil(request.explicitRules)
    }

    func test重复点击不重复提交且只读刷新保留原请求() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await repository.setOutcome(.submittedButUnverified); await repository.setWaiting(true)
        await model.load(repository.item); model.rules[0].rights.insert(.writeData); model.requestConfirmation()
        let operation = Task { await model.confirmChanges() }
        try await wait { await repository.isWaiting }
        await model.confirmChanges(); XCTAssertTrue(model.busy)
        await repository.release(); await operation.value
        XCTAssertTrue(model.isBlocked); XCTAssertTrue(model.canReview); XCTAssertFalse(model.canSave)
        await repository.setOutcome(.confirmedSuccess); await model.refresh(repository.item)
        let changes = await repository.changes, reviews = await repository.reviews
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(reviews, changes)
        XCTAssertEqual(model.result?.status, .confirmedSuccess); XCTAssertFalse(model.isBlocked)
    }

    func test未知权限修改在重启后阻止重放且内部路径不落盘() async throws {
        let repository = PermissionRepository(), root = newRoot(), model = try make(repository, root: root)
        await repository.setOutcome(.submittedButUnverified)
        await model.load(repository.item); model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
        let data = try String(contentsOf: root.appendingPathComponent("permissions-v1.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("volume-synthetic")); XCTAssertFalse(data.contains("synthetic-owner"))
        let restored = try make(repository, root: root); await restored.load(repository.item)
        XCTAssertTrue(restored.isBlocked); XCTAssertFalse(restored.canEdit); XCTAssertFalse(restored.canReview)
        restored.rules[0].rights.insert(.writeData); restored.requestConfirmation(); await restored.confirmChanges()
        let calls = await repository.changes; XCTAssertEqual(calls.count, 1)
    }

    func test保存记录失败零提交且损坏记录不被覆盖() async throws {
        for corrupt in [false, true] {
            let root = newRoot(), repository = PermissionRepository()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let actual = corrupt ? root : root.appendingPathComponent("not-a-directory")
            let file = corrupt ? root.appendingPathComponent("permissions-v1.json") : actual
            let original = Data("synthetic-invalid".utf8); try original.write(to: file)
            let model = try make(repository, root: actual); await model.load(repository.item)
            model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
            XCTAssertTrue(model.recoveryFailed); XCTAssertNotNil(model.snapshot)
            XCTAssertEqual(try Data(contentsOf: file), original)
            let calls = await repository.changes; XCTAssertTrue(calls.isEmpty)
        }
    }

    func test提交前拒绝释放记录并保留草稿供修改() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await repository.setPreflightFailure(true)
        await model.load(repository.item); model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
        XCTAssertFalse(model.isBlocked); XCTAssertTrue(model.canSave); XCTAssertNotNil(model.error)
        await repository.setPreflightFailure(false)
        model.requestConfirmation(); await model.confirmChanges()
        XCTAssertEqual(model.result?.status, .confirmedSuccess)
    }

    func test账号切换后迟到结果不污染新账号() async throws {
        let repository = PermissionRepository(), other = PermissionRepository(), model = try make(repository)
        await repository.setWaiting(true)
        await model.load(repository.item); model.rules[0].rights.insert(.writeData); model.requestConfirmation()
        let operation = Task { await model.confirmChanges() }
        try await wait { await repository.isWaiting }
        model.configure(profile: try profile(other.profileID), repository: other)
        await model.load(other.item); await repository.release(); await operation.value
        XCTAssertEqual(model.snapshot?.target.profileID, other.profileID); XCTAssertNil(model.result)
        XCTAssertFalse(model.busy); XCTAssertFalse(model.isBlocked)
    }

    func test新账号不继承旧限制且移除配置只清理对应记录() async throws {
        let first = PermissionRepository(), second = PermissionRepository(), root = newRoot(), model = try make(first, root: root)
        for repository in [first, second] {
            model.configure(profile: try profile(repository.profileID), repository: repository)
            await repository.setOutcome(.submittedButUnverified); await model.load(repository.item)
            model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
        }
        model.removeProfile(second.profileID)
        let restored = try make(first, root: root); await restored.load(first.item); XCTAssertTrue(restored.isBlocked)
        restored.configure(profile: try profile(second.profileID), repository: second)
        await restored.load(second.item); XCTAssertFalse(restored.isBlocked)
    }

    func test相同配置更换账号不复用原账号的权限记录() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await repository.setOutcome(.submittedButUnverified); await model.load(repository.item)
        model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
        XCTAssertTrue(model.isBlocked)
        let other = try NasProfile(id: repository.profileID, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "other")
        model.configure(profile: other, repository: repository); await model.load(repository.item)
        XCTAssertFalse(model.isBlocked); XCTAssertFalse(model.canReview)
        model.configure(profile: try profile(repository.profileID), repository: repository); await model.load(repository.item)
        XCTAssertTrue(model.isBlocked)
    }

    func test成功后重新读取失败保留成功反馈但不能沿用旧权限继续写() async throws {
        let repository = PermissionRepository(), model = try make(repository)
        await model.load(repository.item); await repository.setFailsAfterSave(true)
        model.rules[0].rights.insert(.writeData); model.requestConfirmation(); await model.confirmChanges()
        XCTAssertEqual(model.result?.status, .confirmedSuccess); XCTAssertNotNil(model.snapshot)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.canEdit)
        await repository.setFailsAfterSave(false); await model.refresh(repository.item)
        XCTAssertNil(model.error); XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.rules[0].rights.contains(.writeData))
    }

    private func newRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionTests-\(UUID())")
        roots.append(root); return root
    }
    private func profile(_ id: UUID) throws -> NasProfile {
        try .init(id: id, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "synthetic")
    }
    private func make(_ repository: PermissionRepository, root: URL? = nil) throws -> MobileFilePermissionModel {
        let model = MobileFilePermissionModel(rootURL: root ?? newRoot())
        model.configure(profile: try profile(repository.profileID), repository: repository); return model
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("权限操作没有到达预期阶段")
    }
}

private actor PermissionRepository: MobileFilePermissionServing {
    nonisolated let profileID: UUID
    nonisolated let item: FileItem
    var changes: [FilePermissionChange] = []
    var reviews: [FilePermissionChange] = []
    private var snapshot: FilePermissionSnapshot
    private var allowed = true
    private var outcome: MutationResultStatus = .confirmedSuccess
    private var preflightFailure = false
    private var failsAfterSave = false
    private var failsRead = false
    private var waits = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    init(acl: Bool = true, editable: Bool = true, directory: Bool = true) {
        let id = UUID(); profileID = id
        item = .init(profileID: id, name: "folder", path: "/synthetic/folder", kind: directory ? .directory : .file,
            owner: "synthetic-owner", group: "synthetic-group", permissions: .init(canRead: true, canWrite: true, canDelete: true, posixMode: 755), mountPointType: "normal")
        snapshot = .init(target: item, resolvedPath: "/volume-synthetic/synthetic/folder", isACL: acl,
            canChangePermissions: editable, isInherited: acl,
            rules: acl ? [.init(ownerType: "user", ownerName: "synthetic-owner", effect: .allow, rights: [.readData], inheritance: [.thisFolder]),
                .init(ownerType: "group", ownerName: "synthetic-group", effect: .allow, rights: [.readData], inheritance: [.thisFolder], level: 1)] : [],
            owner: acl ? .init(name: "synthetic-owner", type: "user", value: "user:synthetic-owner", canChange: editable) : nil,
            posixMode: acl ? nil : "755")
    }
    func setAccess(_ value: Bool) { allowed = value }
    func setOutcome(_ value: MutationResultStatus) { outcome = value }
    func setPreflightFailure(_ value: Bool) { preflightFailure = value }
    func setFailsAfterSave(_ value: Bool) { failsAfterSave = value; if !value { failsRead = false } }
    func setWaiting(_ value: Bool) { waits = value }
    func release() { waits = false; continuation?.resume(); continuation = nil }
    func lastChange() -> FilePermissionChange? { changes.last }
    func loadFilePermissions(_ item: FileItem) async throws -> FilePermissionSnapshot {
        if failsRead { throw URLError(.networkConnectionLost) }
        return snapshot
    }
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess { .init(isAdministrator: true, writesEnabled: allowed) }
    func listFileStationPrincipals(prefix: String, offset: Int, limit: Int) async throws -> FileStationPrincipalPage {
        .init(items: [], total: 0, nextOffset: 0)
    }
    func changeFilePermissions(_ change: FilePermissionChange) async throws -> MutationResult {
        if preflightFailure { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "Synthetic failure") }
        changes.append(change)
        if waits { await withCheckedContinuation { continuation = $0 } }
        return try complete(change)
    }
    func reviewFilePermissions(_ change: FilePermissionChange) async throws -> MutationResult {
        reviews.append(change); return try complete(change)
    }
    private func complete(_ change: FilePermissionChange) throws -> MutationResult {
        if outcome == .confirmedSuccess {
            failsRead = failsAfterSave
            snapshot = .init(target: item, resolvedPath: snapshot.resolvedPath, isACL: snapshot.isACL,
                canChangePermissions: snapshot.canChangePermissions, isInherited: snapshot.isInherited,
                rules: (change.explicitRules ?? snapshot.rules.filter { $0.level == 0 }) + snapshot.rules.filter { $0.level > 0 },
                owner: snapshot.owner, posixMode: change.posixMode ?? snapshot.posixMode)
        }
        let unknown = outcome == .submittedButUnverified
        return try .init(status: outcome, operation: "filePermissions", submitted: true, requiresRefresh: unknown,
            counts: .init(succeeded: outcome == .confirmedSuccess ? 1 : 0, failed: 0, unknown: unknown ? 1 : 0), diagnosticTag: "synthetic.permissions")
    }
}
