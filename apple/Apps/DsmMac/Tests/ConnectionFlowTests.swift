import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMacExecutable

final class TextDocumentFormatterTests: XCTestCase {
    func testJSON整理会添加缩进并保留中文() throws {
        let formatted = try TextDocumentFormatter.format(
            #"{"name":"岚仓","items":[1,2]}"#,
            fileExtension: "json"
        )

        XCTAssertTrue(formatted.contains("\n  \"items\""))
        XCTAssertTrue(formatted.contains("\"岚仓\""))
        XCTAssertTrue(formatted.hasSuffix("\n"))
    }

    func test错误JSON不会生成可能损坏原文件的内容() {
        XCTAssertThrowsError(
            try TextDocumentFormatter.format("{\"name\":}", fileExtension: "json")
        )
    }

    func testJavaScript整理只调整安全空白() throws {
        let source = "function greet() {\nconsole.log('岚仓 { test }');\nif (true) {\nreturn 1;\n}\n}"
        let formatted = try TextDocumentFormatter.format(source, fileExtension: "js")

        XCTAssertTrue(formatted.contains("    console.log('岚仓 { test }');"))
        XCTAssertTrue(formatted.contains("        return 1;"))
        XCTAssertTrue(formatted.hasSuffix("\n"))
    }
}

private struct CertificateReviewAuthRepository: AuthRepository {
    private enum StubError: Error {
        case unexpectedCall
    }

    func discover(profile: NasProfile) async throws -> CapabilitySet {
        throw DsmCertificateTrustError.untrusted(
            DsmCertificateReview(
                host: profile.host,
                subjectSummary: "NAS",
                sha256Fingerprint: String(repeating: "A", count: 64),
                canBePinned: true
            )
        )
    }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        throw StubError.unexpectedCall
    }

    func restoreSession(for profileID: UUID) async throws -> AuthSession? {
        nil
    }

    func clearSession(for profileID: UUID) async throws {}

    func logout(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) async throws {}
}

private actor RecordingQuickConnectResolver: QuickConnectResolving {
    private(set) var requestedID: String?
    private(set) var relayRequestCount = 0
    private let endpoints: [QuickConnectEndpoint]
    private let relayEndpoint: QuickConnectEndpoint
    private let resolutionError: QuickConnectResolutionError?

    init(
        endpoints: [QuickConnectEndpoint] = [
            QuickConnectEndpoint(
                host: "192-168-1-20.family-nas.direct.quickconnect.to",
                port: 5_001,
                kind: .local
            )
        ],
        relayEndpoint: QuickConnectEndpoint = QuickConnectEndpoint(
            host: "family-nas.r1.quickconnect.to",
            port: 443,
            kind: .relay
        ),
        resolutionError: QuickConnectResolutionError? = nil
    ) {
        self.endpoints = endpoints
        self.relayEndpoint = relayEndpoint
        self.resolutionError = resolutionError
    }

    func resolve(id: String) async throws -> [QuickConnectEndpoint] {
        requestedID = id
        if let resolutionError {
            throw resolutionError
        }
        return endpoints
    }

    func requestRelay(id: String) async throws -> QuickConnectEndpoint {
        requestedID = id
        relayRequestCount += 1
        return relayEndpoint
    }
}

private actor RecordingAuthRepository: AuthRepository {
    private(set) var discoveredHost: String?
    private(set) var discoveredHosts: [String] = []
    private(set) var loginHost: String?
    private(set) var loginPort: Int?
    private(set) var clearSessionCallCount = 0
    private(set) var logoutCallCount = 0
    private(set) var loginCallCount = 0
    private let failingHosts: Set<String>
    private let restoredSession: AuthSession?

    init(failingHosts: Set<String> = [], restoredSession: AuthSession? = nil) {
        self.failingHosts = failingHosts
        self.restoredSession = restoredSession
    }

    func discover(profile: NasProfile) async throws -> CapabilitySet {
        discoveredHost = profile.host
        discoveredHosts.append(profile.host)
        if failingHosts.contains(profile.host) {
            throw AppError(
                category: .networkUnavailable,
                isRetryable: true,
                safeUserMessage: "测试候选不可用。"
            )
        }
        return CapabilitySet([:])
    }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        loginCallCount += 1
        loginHost = profile.host
        loginPort = profile.port
        return AuthSession(sid: "test-session", synoToken: nil, did: nil, isPortalPort: false)
    }

    func restoreSession(for profileID: UUID) async throws -> AuthSession? {
        restoredSession
    }

    func clearSession(for profileID: UUID) async throws {
        clearSessionCallCount += 1
    }

    func logout(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) async throws {
        logoutCallCount += 1
    }
}

private actor MemoryPasswordStore: PasswordSecureStoring {
    private var passwords: [UUID: String] = [:]

    func save(_ password: String, for profileID: UUID) async throws {
        passwords[profileID] = password
    }

    func load(for profileID: UUID) async throws -> String? {
        passwords[profileID]
    }

    func remove(for profileID: UUID) async throws {
        passwords[profileID] = nil
    }
}

/// 故意不响应取消的延迟返回，用来验证旧连接不能覆盖当前 NAS。
private actor DelayedConnectionRepository: AuthRepository {
    enum Phase: Sendable { case discovery, login }
    struct Submission: Sendable {
        let host: String
        let account: String
        let password: String
    }
    let phase: Phase
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var submissions: [Submission] = []
    private(set) var cleared: [UUID] = []
    var isSuspended: Bool { continuation != nil }

    init(phase: Phase) { self.phase = phase }

    func resume() { continuation?.resume(); continuation = nil }

    func discover(profile: NasProfile) async -> CapabilitySet {
        if phase == .discovery, profile.host == "first.example.invalid" {
            await withCheckedContinuation { continuation = $0 }
        }
        return CapabilitySet([:])
    }

    func login(profile: NasProfile, capabilities: CapabilitySet, account: String, password: String, otpCode: String?) async -> AuthSession {
        submissions.append(Submission(host: profile.host, account: account, password: password))
        if phase == .login, profile.host == "first.example.invalid" {
            await withCheckedContinuation { continuation = $0 }
        }
        return AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false)
    }

    func restoreSession(for profileID: UUID) -> AuthSession? { nil }
    func clearSession(for profileID: UUID) { cleared.append(profileID) }
    func logout(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession) {}
}

extension ConnectionFlowTests {
    @MainActor
    func test文件应用不可用时保留恢复的账号登录状态() async throws {
        let suite = "RestoreRestrictedAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = try NasProfile(displayName: "Synthetic NAS", host: "example.invalid", port: 5001, usernameHint: "synthetic-user")
        let store = NasProfileStore(defaults: defaults)
        try store.save([profile])
        store.setAutoLoginEnabled(true, for: profile.id)
        let passwords = MemoryPasswordStore()
        try await passwords.save("synthetic-password", for: profile.id)
        let repository = RecordingAuthRepository(restoredSession: AuthSession(sid: "synthetic-restored-session", synoToken: nil, did: nil, isPortalPort: false))
        let model = AppModel(profileStore: store, authRepository: repository,
                             passwordStore: passwords, desktopDriveSessionStore: MemorySessionStore())
        model.load()
        for _ in 0..<100 {
            if model.workspace != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.workspace?.profile.id, profile.id)
        let clears = await repository.clearSessionCallCount
        let logins = await repository.loginCallCount
        XCTAssertEqual(clears, 0)
        XCTAssertEqual(logins, 0)
        XCTAssertFalse(model.statusIsError)
    }

    @MainActor
    func test等待发现时使用提交的账号快照() async throws {
        let suite = "ConnectionSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = DelayedConnectionRepository(phase: .discovery)
        let model = AppModel(profileStore: NasProfileStore(defaults: defaults), authRepository: repository,
                             passwordStore: MemoryPasswordStore(), desktopDriveSessionStore: MemorySessionStore())
        model.host = "first.example.invalid"
        model.account = "first-user"
        model.password = "synthetic-first-password"
        let connection = Task { await model.connect() }
        for _ in 0..<1_000 {
            if await repository.isSuspended { break }
            await Task.yield()
        }
        let suspended = await repository.isSuspended
        XCTAssertTrue(suspended)
        model.account = "edited-user"
        model.password = "edited-password"
        await repository.resume()
        await connection.value
        let submissions = await repository.submissions
        let submission = try XCTUnwrap(submissions.first)
        XCTAssertEqual(submission.account, "first-user")
        XCTAssertEqual(submission.password, "synthetic-first-password")
        XCTAssertEqual(model.workspace?.profile.usernameHint, "first-user")
    }

    @MainActor
    func test旧设备迟到结果不能覆盖新设备工作区() async throws {
        for phase in [DelayedConnectionRepository.Phase.discovery, .login] {
            let suite = "ConnectionOwnershipTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let repository = DelayedConnectionRepository(phase: phase)
            let model = AppModel(profileStore: NasProfileStore(defaults: defaults), authRepository: repository,
                                 passwordStore: MemoryPasswordStore(), desktopDriveSessionStore: MemorySessionStore())
            model.host = "first.example.invalid"
            model.account = "first-user"
            model.password = "synthetic-password"
            let first = Task { await model.connect() }
            for _ in 0..<1_000 {
                if await repository.isSuspended { break }
                await Task.yield()
            }
            let suspended = await repository.isSuspended
            XCTAssertTrue(suspended)
            model.newProfile()
            model.host = "second.example.invalid"
            model.account = "second-user"
            model.password = "synthetic-password"
            await model.connect()
            let secondWorkspace = try XCTUnwrap(model.workspace)
            let secondStatus = model.statusMessage
            await repository.resume()
            await first.value
            XCTAssertTrue(model.workspace === secondWorkspace)
            XCTAssertEqual(model.workspace?.profile.host, "second.example.invalid")
            XCTAssertEqual(model.workspace?.profile.usernameHint, "second-user")
            XCTAssertEqual(model.statusMessage, secondStatus)
            XCTAssertFalse(model.isBusy)
            XCTAssertFalse(model.statusIsError)
        }
    }

    @MainActor
    func test旧工作区登录弹窗不能退出当前设备() async throws {
        let suite = "SessionIssueOwnershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = RecordingAuthRepository()
        let model = AppModel(profileStore: NasProfileStore(defaults: defaults), authRepository: repository,
                             passwordStore: MemoryPasswordStore(), desktopDriveSessionStore: MemorySessionStore())
        model.host = "first.example.invalid"
        model.account = "first-user"
        model.password = "synthetic-password"
        await model.connect()
        let firstWorkspace = try XCTUnwrap(model.workspace)
        model.newProfile()
        model.host = "second.example.invalid"
        model.account = "second-user"
        model.password = "synthetic-password"
        await model.connect()
        let secondWorkspace = try XCTUnwrap(model.workspace)
        await model.returnToLoginAfterSessionIssue(message: "旧设备的合成错误", from: firstWorkspace)
        XCTAssertTrue(model.workspace === secondWorkspace)
        let clears = await repository.clearSessionCallCount
        XCTAssertEqual(clears, 0)
        XCTAssertFalse(model.statusIsError)
    }
}

private actor MemorySessionStore: SessionSecureStoring {
    private var sessions: [UUID: AuthSession] = [:]

    func save(_ session: AuthSession, for profileID: UUID) async throws {
        sessions[profileID] = session
    }

    func load(for profileID: UUID) async throws -> AuthSession? {
        sessions[profileID]
    }

    func remove(for profileID: UUID) async throws {
        sessions[profileID] = nil
    }
}

private actor UnreadableMountSessionStore: SessionSecureStoring {
    func save(_ session: AuthSession, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> AuthSession? { nil }
    func remove(for profileID: UUID) async throws {}
}

final class ConnectionFlowTests: XCTestCase {
    func test正式版与测试版使用相同的网络创建接线() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LoginViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "let serviceManagementRepository = try DsmServiceManagementRepository("))
        let end = try XCTUnwrap(source.range(of: "let privilegesService", range: start.upperBound..<source.endIndex))
        let composition = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(composition.contains("containerNetworkCreationEnabled: true"))
        XCTAssertFalse(composition.contains("AppStorageNamespace.isLocalTest"), "创建能力不得被包类型再次关闭")
    }
    func test临时签名缺少扩展或共享容器时云盘能力不可用() {
        let containerURL = URL(fileURLWithPath: "/tmp/test-app-group")

        XCTAssertFalse(
            DesktopCloudDriveAvailability.evaluate(
                hasFileProviderExtension: false,
                sharedContainerURL: containerURL
            )
        )
        XCTAssertFalse(
            DesktopCloudDriveAvailability.evaluate(
                hasFileProviderExtension: true,
                sharedContainerURL: nil
            )
        )
        XCTAssertTrue(
            DesktopCloudDriveAvailability.evaluate(
                hasFileProviderExtension: true,
                sharedContainerURL: containerURL
            )
        )
    }

    func test挂载会话桥接先保存连接再发布并清理当前会话() async throws {
        let profileID = UUID()
        let session = AuthSession(
            sid: "test-session",
            synoToken: "test-token",
            did: nil,
            isPortalPort: false
        )
        let store = MemorySessionStore()
        let bridge = DesktopDriveSessionBridge(
            profileID: profileID,
            session: session,
            store: store,
            publishConnection: {
                let existing = try await store.load(for: profileID)
                XCTAssertNil(existing)
            }
        )

        try await bridge.publish()
        let published = try await store.load(for: profileID)
        XCTAssertEqual(published, session)

        try await bridge.remove()
        let removed = try await store.load(for: profileID)
        XCTAssertNil(removed)
    }

    func test连接资料保存失败不会发布共享登录状态() async throws {
        let profileID = UUID()
        let store = MemorySessionStore()
        let bridge = DesktopDriveSessionBridge(
            profileID: profileID,
            session: .init(sid: "test-session", synoToken: nil, did: nil, isPortalPort: false),
            store: store,
            publishConnection: { throw CocoaError(.fileWriteOutOfSpace) }
        )
        do {
            try await bridge.publish()
            XCTFail("连接资料保存失败时不得继续挂载")
        } catch {
            XCTAssertEqual(error as? DesktopDriveSessionBridgeError, .connectionUnavailable)
        }
        let saved = try await store.load(for: profileID)
        XCTAssertNil(saved)
    }

    func test共享登录状态无法读回时不报告发布成功() async throws {
        let bridge = DesktopDriveSessionBridge(
            profileID: UUID(),
            session: .init(sid: "test-session", synoToken: nil, did: nil, isPortalPort: false),
            store: UnreadableMountSessionStore(),
            publishConnection: {}
        )
        do {
            try await bridge.publish()
            XCTFail("无法读回的会话不能视为已就绪")
        } catch {
            XCTAssertEqual(error as? DesktopDriveSessionBridgeError, .sessionUnavailable)
        }
    }

    @MainActor
    func test登录后修改NAS显示名称并同步工作区() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: RecordingAuthRepository(),
            passwordStore: MemoryPasswordStore()
        )
        model.displayName = "修改前"
        model.host = "home-nas.local"
        model.account = "user"
        model.password = "local-test-password"
        await model.connect()

        let error = model.renameCurrentNAS(to: "修改后")

        XCTAssertNil(error)
        XCTAssertEqual(model.profiles.first?.displayName, "修改后")
        XCTAssertEqual(model.workspace?.profile.displayName, "修改后")
        XCTAssertEqual(NasProfileStore(defaults: defaults).load().first?.displayName, "修改后")
    }

    @MainActor
    func test选择记住密码后交给安全存储() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let passwordStore = MemoryPasswordStore()
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: RecordingAuthRepository(),
            passwordStore: passwordStore
        )
        model.host = "home-nas.local"
        model.account = "user"
        model.password = "local-test-password"
        model.rememberPassword = true

        await model.connect()

        let profileID = try XCTUnwrap(model.selectedProfileID)
        let stored = try await passwordStore.load(for: profileID)
        XCTAssertEqual(stored, "local-test-password")
        XCTAssertEqual(model.password, "local-test-password")
    }

    @MainActor
    func test自动登录选项持久化并在下次启动使用保存密码连接() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileStore = NasProfileStore(defaults: defaults)
        let profile = try NasProfile(
            displayName: "家庭 NAS",
            host: "home-nas.local",
            port: 5_001,
            usernameHint: "user"
        )
        try profileStore.save([profile])
        profileStore.setAutoLoginEnabled(true, for: profile.id)
        let passwordStore = MemoryPasswordStore()
        try await passwordStore.save("local-test-password", for: profile.id)
        let authRepository = RecordingAuthRepository()
        let model = AppModel(
            profileStore: profileStore,
            authRepository: authRepository,
            passwordStore: passwordStore
        )

        model.load()
        for _ in 0..<100 {
            if model.workspace != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertNotNil(model.workspace)
        XCTAssertTrue(model.autoLoginEnabled)
        XCTAssertTrue(model.rememberPassword)
        let loginCallCount = await authRepository.loginCallCount
        XCTAssertEqual(loginCallCount, 1)
    }

    @MainActor
    func test关闭记住密码会同时关闭自动登录() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileStore = NasProfileStore(defaults: defaults)
        let model = AppModel(
            profileStore: profileStore,
            authRepository: RecordingAuthRepository(),
            passwordStore: MemoryPasswordStore()
        )
        model.host = "home-nas.local"
        model.account = "user"
        model.password = "local-test-password"
        model.setAutoLoginEnabled(true)
        await model.connect()
        let profileID = try XCTUnwrap(model.selectedProfileID)

        model.setRememberPassword(false)

        XCTAssertFalse(model.rememberPassword)
        XCTAssertFalse(model.autoLoginEnabled)
        XCTAssertFalse(profileStore.isAutoLoginEnabled(for: profileID))
    }

    @MainActor
    func test登录后仍可进入新增NAS表单且保留已有配置() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: RecordingAuthRepository()
        )
        model.displayName = "家庭 NAS"
        model.host = "home-nas.local"
        model.account = "user"
        model.password = "password"
        await model.connect()

        XCTAssertNotNil(model.workspace)
        XCTAssertEqual(model.profiles.count, 1)

        model.newProfile()

        XCTAssertNil(model.workspace)
        XCTAssertNil(model.selectedProfileID)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.displayName, L10n.string("ui.b457fa7f7764aef5"))
        XCTAssertTrue(model.host.isEmpty)
        XCTAssertTrue(model.account.isEmpty)
    }

    @MainActor
    func test登录多台NAS后可以从工作区切换配置() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: RecordingAuthRepository()
        )
        model.displayName = "家庭 NAS"
        model.host = "home-nas.local"
        model.account = "home-user"
        model.password = "password"
        await model.connect()
        let firstProfileID = try XCTUnwrap(model.selectedProfileID)
        let firstWorkspace = try XCTUnwrap(model.workspace)

        model.newProfile()
        model.displayName = "办公室 NAS"
        model.host = "office-nas.local"
        model.account = "office-user"
        model.password = "password"
        await model.connect()

        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertNotNil(model.workspace)

        model.selectProfile(id: firstProfileID)

        XCTAssertTrue(model.workspace === firstWorkspace)
        XCTAssertEqual(model.selectedProfileID, firstProfileID)
        XCTAssertEqual(model.displayName, "家庭 NAS")
        XCTAssertEqual(model.host, "home-nas.local")
        XCTAssertEqual(model.account, "home-user")
    }

    @MainActor
    func test无法自动验证证书时显示核对界面并保留本次密码() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: CertificateReviewAuthRepository()
        )
        model.host = "nas.local"
        model.account = "user"
        model.password = "password"

        await model.connect()

        XCTAssertNotNil(model.pendingCertificate)
        XCTAssertEqual(model.password, "password")
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(model.statusMessage, L10n.string("shared.747b72d0d6fc61f9"))
    }

    @MainActor
    func testQuickConnectID解析后用于登录但界面保留原始ID() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = RecordingQuickConnectResolver()
        let repository = RecordingAuthRepository()
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: repository,
            quickConnectResolver: resolver
        )
        model.host = "family-nas"
        model.account = "user"
        model.password = "password"

        await model.connect()

        let requestedID = await resolver.requestedID
        let discoveredHost = await repository.discoveredHost
        let loginHost = await repository.loginHost
        XCTAssertEqual(requestedID, "family-nas")
        XCTAssertEqual(discoveredHost, "192-168-1-20.family-nas.direct.quickconnect.to")
        XCTAssertEqual(loginHost, "192-168-1-20.family-nas.direct.quickconnect.to")
        XCTAssertEqual(model.host, "family-nas")
        XCTAssertEqual(model.workspace?.profile.host, "family-nas")
        XCTAssertEqual(model.currentConnectionRoute, .local)
    }

    @MainActor
    func test局域网候选失败后尝试公网直连且不向错误候选发送密码() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localHost = "192-168-1-20.family-nas.direct.quickconnect.to"
        let externalHost = "family-nas.direct.quickconnect.to"
        let resolver = RecordingQuickConnectResolver(
            endpoints: [
                QuickConnectEndpoint(host: localHost, port: 5_001, kind: .local),
                QuickConnectEndpoint(host: externalHost, port: 5_001, kind: .external)
            ]
        )
        let repository = RecordingAuthRepository(failingHosts: [localHost])
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: repository,
            quickConnectResolver: resolver
        )
        model.host = "family-nas"
        model.account = "user"
        model.password = "password"

        await model.connect()

        let discoveredHosts = await repository.discoveredHosts
        let loginHost = await repository.loginHost
        XCTAssertEqual(discoveredHosts, [localHost, externalHost])
        XCTAssertEqual(loginHost, externalHost)
        XCTAssertNotNil(model.workspace)
        XCTAssertEqual(model.currentConnectionRoute, .external)
    }

    @MainActor
    func test自定义端口覆盖QuickConnect返回端口() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = RecordingQuickConnectResolver()
        let repository = RecordingAuthRepository()
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: repository,
            quickConnectResolver: resolver
        )
        model.host = "family-nas"
        model.port = "5443"
        model.account = "user"
        model.password = "password"

        await model.connect()

        let loginPort = await repository.loginPort
        XCTAssertEqual(loginPort, 5_443)
        XCTAssertEqual(model.profiles.first?.portOverride, 5_443)
    }

    @MainActor
    func test所有直连候选失败后建立中继再登录() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localHost = "192-168-1-20.family-nas.direct.quickconnect.to"
        let externalHost = "family-nas.direct.quickconnect.to"
        let relayHost = "family-nas.r1.quickconnect.to"
        let resolver = RecordingQuickConnectResolver(
            endpoints: [
                QuickConnectEndpoint(host: localHost, port: 5_001, kind: .local),
                QuickConnectEndpoint(host: externalHost, port: 5_001, kind: .external)
            ],
            relayEndpoint: QuickConnectEndpoint(host: relayHost, port: 443, kind: .relay)
        )
        let repository = RecordingAuthRepository(failingHosts: [localHost, externalHost])
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: repository,
            quickConnectResolver: resolver
        )
        model.host = "family-nas"
        model.account = "user"
        model.password = "password"

        await model.connect()

        let relayRequestCount = await resolver.relayRequestCount
        let discoveredHosts = await repository.discoveredHosts
        let loginHost = await repository.loginHost
        let loginPort = await repository.loginPort
        XCTAssertEqual(relayRequestCount, 1)
        XCTAssertEqual(discoveredHosts, [localHost, externalHost, relayHost])
        XCTAssertEqual(loginHost, relayHost)
        XCTAssertEqual(loginPort, 443)
        XCTAssertNotNil(model.workspace)
        XCTAssertEqual(model.currentConnectionRoute, .quickConnect)
    }

    @MainActor
    func test没有直连候选时直接建立中继() async {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let relayHost = "family-nas.r1.quickconnect.to"
        let resolver = RecordingQuickConnectResolver(
            endpoints: [],
            relayEndpoint: QuickConnectEndpoint(host: relayHost, port: 443, kind: .relay),
            resolutionError: .noDirectRoute
        )
        let repository = RecordingAuthRepository()
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: repository,
            quickConnectResolver: resolver
        )
        model.host = "family-nas"
        model.account = "user"
        model.password = "password"

        await model.connect()

        let relayRequestCount = await resolver.relayRequestCount
        let discoveredHosts = await repository.discoveredHosts
        let loginHost = await repository.loginHost
        XCTAssertEqual(relayRequestCount, 1)
        XCTAssertEqual(discoveredHosts, [relayHost])
        XCTAssertEqual(loginHost, relayHost)
        XCTAssertNotNil(model.workspace)
        XCTAssertEqual(model.currentConnectionRoute, .quickConnect)
    }

    @MainActor
    func test文件会话失效时返回登录页但不执行远程退出() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = RecordingQuickConnectResolver()
        let repository = RecordingAuthRepository()
        let desktopDriveSessionStore = MemorySessionStore()
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: repository,
            quickConnectResolver: resolver,
            desktopDriveSessionStore: desktopDriveSessionStore
        )
        model.host = "family-nas"
        model.account = "user"
        model.password = "password"
        await model.connect()
        let profileID = try XCTUnwrap(model.selectedProfileID)
        try await desktopDriveSessionStore.save(
            AuthSession(
                sid: "shared-session",
                synoToken: nil,
                did: nil,
                isPortalPort: false
            ),
            for: profileID
        )

        await model.returnToLoginAfterSessionIssue(message: "登录状态已失效，请重新登录。")

        let clearCount = await repository.clearSessionCallCount
        let logoutCount = await repository.logoutCallCount
        XCTAssertNil(model.workspace)
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(model.statusMessage, "登录状态已失效，请重新登录。")
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(logoutCount, 0)
        let sharedSession = try? await desktopDriveSessionStore.load(
            for: profileID
        )
        XCTAssertNil(sharedSession)
    }

    @MainActor
    func test主动退出清理云盘共享会话但保留应用内密码() async throws {
        let suiteName = "ConnectionFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let passwordStore = MemoryPasswordStore()
        let desktopDriveSessionStore = MemorySessionStore()
        let model = AppModel(
            profileStore: NasProfileStore(defaults: defaults),
            authRepository: RecordingAuthRepository(),
            passwordStore: passwordStore,
            desktopDriveSessionStore: desktopDriveSessionStore
        )
        model.host = "home-nas.local"
        model.account = "user"
        model.password = "local-test-password"
        model.rememberPassword = true
        await model.connect()
        let profileID = try XCTUnwrap(model.selectedProfileID)
        try await desktopDriveSessionStore.save(
            AuthSession(
                sid: "shared-session",
                synoToken: nil,
                did: nil,
                isPortalPort: false
            ),
            for: profileID
        )

        await model.logout()

        let sharedSession = try await desktopDriveSessionStore.load(
            for: profileID
        )
        let savedPassword = try await passwordStore.load(for: profileID)
        XCTAssertNil(sharedSession)
        XCTAssertEqual(savedPassword, "local-test-password")
        XCTAssertEqual(model.password, "local-test-password")
    }
}
