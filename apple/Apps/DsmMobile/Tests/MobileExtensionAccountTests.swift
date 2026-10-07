import DsmCore
import DsmNetwork
@testable import DsmMobile
import XCTest

@MainActor
final class MobileExtensionAccountTests: XCTestCase {
    func test发布只共享短期会话且磁盘不含凭据() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let account = try await fixture.publish()
        XCTAssertNotEqual(account.id, fixture.profile.id)
        let session = try await fixture.sessions.load(for: account.id)
        XCTAssertEqual(session?.sid, "synthetic-session")
        XCTAssertNil(session?.did)
        let originalID = try await fixture.sessions.load(for: fixture.profile.id)
        XCTAssertNil(originalID)
        let raw = try String(contentsOf: fixture.store.recordsURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("synthetic-session"))
        XCTAssertFalse(raw.contains("synthetic-token"))
        XCTAssertFalse(raw.contains("synthetic-device"))
        XCTAssertEqual(try fixture.store.accounts(), [account])
        let excluded = try fixture.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
    }

    func test凭据未保存前账号不可见() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.sessions.suspendNextSave()
        let task = Task { try await fixture.publish() }
        try await fixture.waitForSave()
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
        await fixture.sessions.releaseSave()
        let account = try await task.value
        XCTAssertEqual(try fixture.store.accounts(), [account])
    }

    func test发布期间撤销不会被迟到保存重新激活() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.sessions.suspendNextSave()
        let task = Task { try await fixture.publish() }
        try await fixture.waitForSave()
        try fixture.access.revoke(profileID: fixture.profile.id)
        await fixture.sessions.releaseSave()
        do { _ = try await task.value; XCTFail("已撤销发布不得成功") } catch {}
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
        let count = await fixture.sessions.count
        XCTAssertEqual(count, 0)
    }

    func test同配置更换账号后迟到旧发布不影响新会话() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.sessions.suspendNextSave()
        let oldTask = Task { try await fixture.publish() }
        try await fixture.waitForSave()
        let newProfile = try fixture.profile.updating(usernameHint: "replacement")
        let active = try await fixture.access.publish(profile: newProfile, connection: newProfile,
            capabilities: .init([:]), session: fixture.session)
        await fixture.sessions.releaseSave()
        do { _ = try await oldTask.value; XCTFail("旧发布不得接管新账号") } catch {}
        XCTAssertEqual(try fixture.store.accounts(), [active])
        let saved = try await fixture.sessions.load(for: active.id)
        XCTAssertNotNil(saved)
    }

    func test凭据保存失败不发布账号() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await fixture.sessions.failSave()
        do { _ = try await fixture.publish(); XCTFail("保存失败不得发布") } catch {}
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
    }

    func test取消发布保留其他账号() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let other = try NasProfile(displayName: "Other", host: "other.invalid", port: 5001, usernameHint: "synthetic")
        let active = try await fixture.access.publish(profile: other, connection: other, capabilities: .init([:]), session: fixture.session)
        await fixture.sessions.suspendNextSave()
        let task = Task { try await fixture.publish() }
        try await fixture.waitForSave()
        task.cancel()
        await fixture.sessions.releaseSave()
        do { _ = try await task.value; XCTFail("已取消发布不得成功") } catch is CancellationError {} catch { XCTFail("应保留取消语义") }
        XCTAssertEqual(try fixture.store.accounts(), [active])
    }

    func test等待旧凭据清理时取消不提前开放新会话() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.publish()
        await fixture.sessions.suspendNextRemove()
        let task = Task { try await fixture.publish() }
        for _ in 0..<100 {
            if await fixture.sessions.removalSuspended { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await fixture.sessions.removalSuspended
        XCTAssertTrue(waiting)
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
        task.cancel()
        await fixture.sessions.releaseRemove()
        do { _ = try await task.value; XCTFail("取消后不得发布新会话") } catch is CancellationError {} catch { XCTFail("应保留取消语义") }
        await fixture.access.cleanRetiredSessions()
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
        let count = await fixture.sessions.count
        XCTAssertEqual(count, 0)
    }

    func test跨实例读写不丢失其他账号且撤销立即可见() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let peer = MobileExtensionAccountStore(rootURL: fixture.root)
        let accounts = try await withThrowingTaskGroup(of: MobileExtensionAccount.self) { group in
            for index in 0..<12 {
                let profile = try NasProfile(displayName: "Synthetic \(index)", host: "nas.invalid", port: 5001, usernameHint: "\(index)")
                group.addTask {
                    let store = MobileExtensionAccountStore(rootURL: fixture.root)
                    return try store.activate(store.reserve(profile: profile, connection: profile, capabilities: .init([:])))
                }
            }
            var values: [MobileExtensionAccount] = []
            for try await account in group { values.append(account) }
            return values
        }
        XCTAssertEqual(try peer.accounts().count, 12)
        try fixture.store.revoke(profileID: accounts[0].profile.id)
        XCTAssertThrowsError(try peer.requireCurrent(accounts[0]))
        XCTAssertEqual(try peer.accounts().count, 11)
    }

    func test旧连接不能在重新登录后继续发请求() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let old = try await fixture.publish()
        _ = try await fixture.publish()
        let network = ExtensionNetwork()
        let transport = fixture.transport(account: old, network: network)
        do { _ = try await transport.send(fixture.request); XCTFail("旧会话不应发出请求") } catch {}
        let count = await network.count
        XCTAssertEqual(count, 0)
    }

    func test撤销取消进行中的上传且不误报成功() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let active = try await fixture.publish()
        let network = ExtensionNetwork(delay: true)
        let transport = fixture.transport(account: active, network: network)
        let task = Task { try await transport.upload(fixture.request, from: fixture.root.appendingPathComponent("synthetic"), progress: { _, _ in }) }
        for _ in 0..<100 {
            if await network.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try fixture.access.revoke(profileID: fixture.profile.id)
        do { _ = try await task.value; XCTFail("撤销后不得误报上传成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .authenticationRequired) }
        let cancelled = await network.cancelled
        let count = await network.count
        XCTAssertTrue(cancelled)
        XCTAssertEqual(count, 1)
    }

    func test会话缺失时下载不会触达网络() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let active = try await fixture.publish()
        try await fixture.sessions.remove(for: active.id)
        let network = ExtensionNetwork()
        do { _ = try await fixture.transport(account: active, network: network).download(fixture.request,
            to: fixture.root.appendingPathComponent("synthetic"), progress: { _, _ in }); XCTFail("无会话不允许下载") } catch {}
        let count = await network.count
        XCTAssertEqual(count, 0)
    }

    func test磁盘损坏时不覆盖且请求失败关闭() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let active = try await fixture.publish()
        let broken = Data("invalid-record".utf8)
        try broken.write(to: fixture.store.recordsURL)
        XCTAssertThrowsError(try fixture.store.revoke(profileID: fixture.profile.id))
        let network = ExtensionNetwork()
        do { _ = try await fixture.transport(account: active, network: network).send(fixture.request); XCTFail("损坏快照不得发请求") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.store.recordsURL), broken)
        let count = await network.count
        XCTAssertEqual(count, 0)
    }

    func test清理失败仍立即撤销并在下次补清理() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let active = try await fixture.publish()
        await fixture.sessions.setRemoveFailure(true)
        try fixture.access.revoke(profileID: fixture.profile.id)
        await fixture.access.cleanRetiredSessions()
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
        XCTAssertTrue(try fixture.store.retiredSessionIDs().contains(active.id))
        await fixture.sessions.setRemoveFailure(false)
        await fixture.access.cleanRetiredSessions()
        XCTAssertTrue(try fixture.store.retiredSessionIDs().isEmpty)
        let remaining = await fixture.sessions.count
        XCTAssertEqual(remaining, 0)
    }

    func test主应用退出和删除连接同步撤销扩展访问() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let suite = "ExtensionAccount-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MobileAppModel(defaults: defaults, sessionStore: fixture.sessions, extensionAccess: fixture.access)
        let active = try await fixture.publish()
        model.activeProfile = fixture.profile
        model.profiles = [fixture.profile]
        model.logout()
        XCTAssertThrowsError(try fixture.store.requireCurrent(active))
        let replacement = try await fixture.publish()
        model.removeProfile(fixture.profile)
        XCTAssertThrowsError(try fixture.store.requireCurrent(replacement))
        XCTAssertTrue(model.profiles.isEmpty)
    }

    func test启动撤销未保存账号和未完成发布但保留同身份重命名() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let active = try await fixture.publish()
        let abandoned = try NasProfile(displayName: "Abandoned", host: "abandoned.invalid", port: 5001, usernameHint: "synthetic")
        _ = try fixture.store.reserve(profile: abandoned, connection: abandoned, capabilities: .init([:]))
        try fixture.store.reconcileProfiles([fixture.profile.updating(displayName: "Renamed")])
        XCTAssertEqual(try fixture.store.accounts(), [active])
        XCTAssertEqual(try fixture.store.retiredSessionIDs().count, 1)
        try fixture.store.reconcileProfiles([])
        XCTAssertTrue(try fixture.store.accounts().isEmpty)
        XCTAssertTrue(try fixture.store.retiredSessionIDs().contains(active.id))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionAccounts-\(UUID().uuidString)")
        let profile: NasProfile
        let sessions = ExtensionSessions()
        let session = AuthSession(sid: "synthetic-session", synoToken: "synthetic-token", did: "synthetic-device", isPortalPort: false)
        var store: MobileExtensionAccountStore { .init(rootURL: root) }
        @MainActor var access: MobileExtensionAccess { .init(accounts: store, sessions: sessions) }
        var request: URLRequest { URLRequest(url: URL(string: "https://nas.invalid/synthetic")!) }

        init() throws { profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001, usernameHint: "synthetic") }
        @MainActor func publish() async throws -> MobileExtensionAccount {
            try await access.publish(profile: profile, connection: profile, capabilities: .init([:]), session: session)
        }
        func transport(account: MobileExtensionAccount, network: ExtensionNetwork) -> MobileExtensionTransport {
            .init(account: account, accounts: store, sessions: sessions, transport: network)
        }
        func waitForSave() async throws {
            for _ in 0..<100 {
                if await sessions.suspended { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("合成会话保存未进入等待")
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor ExtensionSessions: SessionSecureStoring {
    private var values: [UUID: AuthSession] = [:]
    private var nextSaveSuspends = false
    private var savingFails = false
    private var removalFails = false
    private var nextRemoveSuspends = false
    private var removalContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    var suspended: Bool { continuation != nil }
    var count: Int { values.count }
    var removalSuspended: Bool { removalContinuation != nil }
    func suspendNextRemove() { nextRemoveSuspends = true }
    func releaseRemove() { removalContinuation?.resume(); removalContinuation = nil }
    func suspendNextSave() { nextSaveSuspends = true }
    func failSave() { savingFails = true }
    func setRemoveFailure(_ fails: Bool) { removalFails = fails }
    func releaseSave() { continuation?.resume(); continuation = nil }
    func save(_ session: AuthSession, for profileID: UUID) async throws {
        if savingFails { throw CocoaError(.fileWriteNoPermission) }
        if nextSaveSuspends { nextSaveSuspends = false; await withCheckedContinuation { continuation = $0 } }
        values[profileID] = session
    }
    func load(for profileID: UUID) async throws -> AuthSession? { values[profileID] }
    func remove(for profileID: UUID) async throws {
        if nextRemoveSuspends { nextRemoveSuspends = false; await withCheckedContinuation { removalContinuation = $0 } }
        if removalFails { throw CocoaError(.fileWriteNoPermission) }
        values[profileID] = nil
    }
}

private actor ExtensionNetwork: DsmBinaryHTTPTransport {
    private let delay: Bool
    private(set) var count = 0
    private(set) var cancelled = false
    init(delay: Bool = false) { self.delay = delay }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        count += 1
        do { if delay { try await Task.sleep(for: .seconds(30)) } }
        catch { cancelled = true; throw error }
        return .init(data: Data(), statusCode: 200)
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { try await send(request) }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { try await send(request) }
}
