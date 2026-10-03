import DsmCore
import DsmNetwork
@testable import DsmMobile
import XCTest

@MainActor
final class MobileWorkspaceIsolationTests: XCTestCase {
    func test同配置不同账号或地址具有独立身份而改显示名称不改变身份() throws {
        let id = UUID()
        let first = try profile(id, account: "alpha")
        let second = try profile(id, account: "beta")
        let renamed = try NasProfile(id: id, displayName: "Renamed", host: first.host, port: first.port, usernameHint: "alpha")
        let relocated = try NasProfile(id: id, displayName: first.displayName, host: "other.example.invalid", port: first.port, usernameHint: "alpha")
        XCTAssertNotEqual(MobileWorkspaceIdentity(first), MobileWorkspaceIdentity(second))
        XCTAssertNotEqual(MobileWorkspaceIdentity(first), MobileWorkspaceIdentity(relocated))
        XCTAssertEqual(MobileWorkspaceIdentity(first), MobileWorkspaceIdentity(renamed))
        XCTAssertEqual(MobileWorkspaceIdentity(first).storageIdentifier.count, 64)
        XCTAssertFalse(MobileWorkspaceIdentity(first).storageIdentifier.contains(first.host))
    }

    func test更换账号清除同配置旧目录和聊天缓存() async throws {
        let suiteName = "MobileWorkspaceIsolationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = MobileAppModel(defaults: defaults)
        let first = try profile(UUID(), account: "alpha")
        let second = try profile(first.id, account: "beta")
        app.profiles = [first]
        app.activeProfile = first
        await app.fileBrowserModel.activate(profileID: first.id, repository: IdentityFiles(profileID: first.id))
        app.fileBrowserModel.setQuery("account-specific-search")
        await app.chatModel.activate(profileID: first.id, repository: UnverifiedDsmChatRepository())
        XCTAssertNotNil(app.fileBrowserModel.profiles[first.id])
        XCTAssertNotNil(app.chatModel.profiles[first.id])
        await app.prepareWorkspaceContext(for: second)
        XCTAssertNil(app.fileBrowserModel.profiles[first.id])
        XCTAssertNil(app.chatModel.profiles[first.id])
        XCTAssertNil(app.fileBrowserModel.activeProfileID)
    }

    func test下载旧账号迟到读取不会覆盖新账号() async throws {
        let first = try profile(UUID(), account: "alpha")
        let second = try profile(first.id, account: "beta")
        let model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator())
        let held = HeldDownloadSnapshot()
        model.configure(profile: first, repository: nil)
        model.downloadStationLoadOverride = { await held.load() }
        let request = Task { await model.load() }
        await held.waitUntilStarted()
        model.configure(profile: second, repository: nil)
        await held.release()
        await request.value
        XCTAssertNil(model.downloadSnapshot)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.activeProfile?.usernameHint, "beta")
    }

    func test活动记录按账号隔离并拒绝旧账号迟到同步() async throws {
        let first = MobileWorkspaceIdentity(try profile(UUID(), account: "alpha"))
        let second = MobileWorkspaceIdentity(try profile(first.profileID, account: "beta"))
        let coordinator = MobileTransferCoordinator()
        await coordinator.activateContext(first)
        let original = await coordinator.enqueueDownload(.init(profileID: first.profileID, remotePath: "/fixture/one.txt",
            temporaryURL: URL(fileURLWithPath: "/tmp/mobile-fixture-one.txt"), stableTarget: "/fixture/one.txt"))
        await coordinator.activateContext(second)
        let hidden = await coordinator.tasks(profileID: second.profileID)
        XCTAssertTrue(hidden.isEmpty)
        await coordinator.syncDownloadStationTasks(profileID: first.profileID,
            snapshot: .init(source: .official, tasks: [.init(id: "old-account", title: "Fixture", status: "paused")]), context: first)
        let afterLateRead = await coordinator.tasks(profileID: second.profileID)
        XCTAssertTrue(afterLateRead.isEmpty)
        let other = await coordinator.enqueueDownload(.init(profileID: second.profileID, remotePath: "/fixture/two.txt",
            temporaryURL: URL(fileURLWithPath: "/tmp/mobile-fixture-two.txt"), stableTarget: "/fixture/two.txt"))
        await coordinator.activateContext(first)
        let restored = await coordinator.tasks(profileID: first.profileID)
        XCTAssertEqual(restored.map(\.id), [original])
        XCTAssertFalse(restored.contains { $0.id == other })
        XCTAssertEqual(restored.first?.status, .cancelledBeforeSubmission)
    }

    func test离开下载页面只取消读取而保留已提交控制结果() async throws {
        let model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator())
        model.activeProfile = try profile(UUID(), account: "alpha")
        let task = DownloadStationTask(id: "fixture", title: "Fixture", status: "downloading")
        model.downloadSnapshot = .init(source: .official, tasks: [task])
        let control = HeldDownloadControl()
        model.downloadStationControlOverride = { request in try await control.run(request) }
        model.controlDownloadTask(task, action: .pause)
        let operation = try XCTUnwrap(model.downloadControlTask)
        await control.waitUntilStarted()
        model.cancelLoad()
        XCTAssertTrue(model.isControllingDownloadTask)
        await control.release()
        await operation.value
        XCTAssertEqual(model.downloadControlFeedback?.kind, .success)
        XCTAssertEqual(model.downloadTask(id: task.id)?.status, "paused")
    }

    func test改用另一地址或账号生成独立配置并清空旧密码() throws {
        let suiteName = "MobileWorkspaceIsolationTests.credentials.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = MobileAppModel(defaults: defaults)
        let original = try profile(UUID(), account: "alpha")
        app.profiles = [original]
        app.applyProfile(original)
        app.password = "fixture-password"
        app.rememberPassword = true
        app.autoLoginEnabled = true
        app.editConnectionField(.host, value: "other.example.invalid")
        XCTAssertTrue(app.password.isEmpty)
        XCTAssertFalse(app.rememberPassword)
        XCTAssertFalse(app.autoLoginEnabled)
        let changed = try app.makeProfile()
        XCTAssertNotEqual(changed.id, original.id)
        XCTAssertEqual(app.profiles, [original], "提交成功前原配置及其凭据身份保持不变")
        app.applyProfile(original)
        app.editConnectionField(.account, value: "beta")
        XCTAssertNotEqual(try app.makeProfile().id, original.id)
        app.applyProfile(original)
        app.displayName = "Renamed"
        XCTAssertEqual(try app.makeProfile().id, original.id)
    }

    func test迟到密码读取不填入其他目标或覆盖手动输入() async throws {
        for changesTarget in [true, false] {
            let suiteName = "MobileWorkspaceIsolationTests.prefill.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = HeldPasswordStore()
            let app = MobileAppModel(defaults: defaults, passwordStore: store)
            let original = try profile(UUID(), account: "alpha")
            app.profiles = [original]
            app.applyProfile(original)
            let operation = Task { await app.loadSavedPassword(for: original, attemptsAutoLogin: false) }
            await store.waitUntilStarted()
            if changesTarget { app.editConnectionField(.host, value: "other.example.invalid") }
            else { app.password = "manual-fixture" }
            await store.release()
            await operation.value
            XCTAssertEqual(app.password, changesTarget ? "" : "manual-fixture")
            XCTAssertFalse(app.rememberPassword)
        }
    }

    private func profile(_ id: UUID, account: String) throws -> NasProfile {
        try NasProfile(id: id, displayName: "Fixture", host: "fixture.example.invalid", port: 5001, usernameHint: account)
    }
}

private actor IdentityFiles: MobileFileBrowsing {
    nonisolated let profileID: UUID
    init(profileID: UUID) { self.profileID = profileID }
    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        .init(folderPath: "/", items: [], offset: offset, total: 0, hasMore: false)
    }
    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        try await listShares(offset: offset, limit: limit, options: options)
    }
    func search(folderPath: String, query: String) async throws -> [FileItem] { [] }
}

private actor HeldDownloadSnapshot {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    func load() async -> DownloadStationSnapshot {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return .init(source: .official, tasks: [.init(id: "old", title: "Fixture", status: "paused")])
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor HeldDownloadControl {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    func run(_ request: DownloadTaskControlRequest) async throws -> DownloadTaskControlOutcome {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return try .init(result: .init(status: .confirmedSuccess, operation: "downloadPause", submitted: true,
                                      requiresRefresh: true, counts: .init(succeeded: 1, failed: 0, unknown: 0)),
                         taskID: request.task.id, task: .init(id: request.task.id, title: request.task.title, status: "paused"))
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor HeldPasswordStore: PasswordSecureStoring {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    func save(_ password: String, for profileID: UUID) async throws {}
    func remove(for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> String? {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return "stored-fixture"
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
