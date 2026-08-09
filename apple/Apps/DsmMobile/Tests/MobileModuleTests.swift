import DsmCore
import DsmNetwork
@testable import DsmMobile
import XCTest

private actor MobileTestSessionStore: SessionSecureStoring {
    private let storedSession: AuthSession?

    init(storedSession: AuthSession? = nil) {
        self.storedSession = storedSession
    }

    func save(_ session: AuthSession, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> AuthSession? { storedSession }
    func remove(for profileID: UUID) async throws {}
}

private actor MobileTestPasswordStore: PasswordSecureStoring {
    private var passwords: [UUID: String] = [:]

    func save(_ password: String, for profileID: UUID) async throws {
        passwords[profileID] = password
    }

    func load(for profileID: UUID) async throws -> String? {
        passwords[profileID]
    }

    func remove(for profileID: UUID) async throws {
        passwords.removeValue(forKey: profileID)
    }
}

private actor MobileRecordingAuthRepository: AuthRepository {
    private(set) var discoveredHost: String?
    private(set) var loginHost: String?

    func discover(profile: NasProfile) async throws -> CapabilitySet {
        discoveredHost = profile.host
        return CapabilitySet([:])
    }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        loginHost = profile.host
        return AuthSession(
            sid: "mobile-test-session",
            synoToken: nil,
            did: nil,
            isPortalPort: false
        )
    }

    func restoreSession(for profileID: UUID) async throws -> AuthSession? { nil }
    func clearSession(for profileID: UUID) async throws {}
    func logout(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) async throws {}
}

private actor MobileQuickConnectResolver: QuickConnectResolving {
    private(set) var requestedID: String?

    func resolve(id: String) async throws -> [QuickConnectEndpoint] {
        requestedID = id
        return [
            QuickConnectEndpoint(
                host: "192-168-1-20.mobile-test.direct.quickconnect.to",
                port: 5_001,
                kind: .local
            )
        ]
    }

    func requestRelay(id: String) async throws -> QuickConnectEndpoint {
        QuickConnectEndpoint(
            host: "mobile-test.r1.quickconnect.to",
            port: 443,
            kind: .relay
        )
    }
}

final class MobileModuleTests: XCTestCase {
    func test移动端仅暴露五个顶层入口() {
        XCTAssertEqual(
            MobileTopLevelDestination.allCases.map(\.rawValue),
            [
                "files",
                "photos",
                "chat",
                "activity",
                "more"
            ]
        )
    }

    func test活动与更多承载当前核心和受限入口() {
        XCTAssertEqual(
            MobileTopLevelDestination.activity.childModules,
            [.transfers, .downloads]
        )
        XCTAssertEqual(
            MobileTopLevelDestination.more.childModules,
            [.nasSettings, .containers, .virtualMachines, .settings]
        )
        XCTAssertEqual(
            Set(MobileTopLevelDestination.allCases.flatMap(\.childModules)),
            Set(MobileModule.allCases)
        )
    }

    func test只有四个服务模块允许按设备隐藏() {
        XCTAssertEqual(
            MobileModule.optionalPreferenceModules,
            [.downloads, .containers, .virtualMachines, .nasSettings]
        )
        for module in [.files, .photos, .chat, .transfers, .settings] as [MobileModule] {
            XCTAssertFalse(module.isOptionalPreference)
        }
    }

    func test可选模块使用各自生产读取契约判断可用性() {
        XCTAssertTrue(MobileModule.downloads.isAvailable(in: Self.capabilities([DsmAPIName.downloadStationTask])))
        XCTAssertFalse(MobileModule.downloads.isAvailable(in: Self.capabilities([])))
        XCTAssertTrue(MobileModule.containers.isAvailable(in: Self.capabilities([DsmAPIName.dockerContainer])))
        XCTAssertFalse(MobileModule.containers.isAvailable(in: Self.capabilities([DsmAPIName.dockerImage])))
        XCTAssertTrue(MobileModule.virtualMachines.isAvailable(in: Self.capabilities([DsmAPIName.virtualizationAPIGuest])))
        XCTAssertFalse(MobileModule.virtualMachines.isAvailable(in: Self.capabilities([DsmAPIName.virtualizationGuest])))

        for apiName in [
            DsmAPIName.coreSystem,
            DsmAPIName.coreSystemUtilization,
            DsmAPIName.storageOverview,
            DsmAPIName.coreUpgradeServer,
        ] {
            XCTAssertTrue(MobileModule.nasSettings.isAvailable(in: Self.capabilities([apiName])))
        }
        XCTAssertFalse(MobileModule.nasSettings.isAvailable(in: Self.capabilities([])))
    }

    private static func capabilities(_ names: [String]) -> CapabilitySet {
        CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { name in
            (
                name,
                ApiCapability(
                    name: name,
                    path: "entry.cgi",
                    minVersion: 1,
                    maxVersion: 1,
                    requestFormat: .form,
                    selectedVersion: 1,
                    verified: true
                )
            )
        }))
    }

    func test未完成安全契约的管理写入口保持关闭() {
        XCTAssertFalse(MobileModule.containers.supportsMutatingManagement)
        XCTAssertFalse(MobileModule.virtualMachines.supportsMutatingManagement)
        XCTAssertFalse(MobileModule.downloads.supportsMutatingManagement)
        XCTAssertFalse(MobileModule.chat.supportsMutatingManagement)
        XCTAssertFalse(MobileModule.nasSettings.supportsMutatingManagement)
        XCTAssertTrue(MobileModule.files.supportsMutatingManagement)
    }

    func test模块标题均面向普通用户() {
        XCTAssertTrue(MobileModule.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertFalse(MobileModule.allCases.contains { $0.title.contains("API") })
        XCTAssertTrue(MobileTopLevelDestination.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertFalse(MobileTopLevelDestination.allCases.contains { $0.title.contains("API") })
    }

    @MainActor
    func testQuickConnect登录使用解析地址并保留原始ID() async throws {
        let suiteName = "MobileModuleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = MobileRecordingAuthRepository()
        let resolver = MobileQuickConnectResolver()
        let passwordStore = MobileTestPasswordStore()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: MobileTestSessionStore(),
            passwordStore: passwordStore,
            authRepository: repository,
            quickConnectResolver: resolver
        )
        model.host = "mobile-test"
        model.username = "tester"
        model.password = "password"

        model.connect()
        for _ in 0..<100 where model.isConnecting {
            try await Task.sleep(for: .milliseconds(20))
        }

        let requestedID = await resolver.requestedID
        let discoveredHost = await repository.discoveredHost
        let loginHost = await repository.loginHost
        XCTAssertEqual(requestedID, "mobile-test")
        XCTAssertEqual(
            discoveredHost,
            "192-168-1-20.mobile-test.direct.quickconnect.to"
        )
        XCTAssertEqual(
            loginHost,
            "192-168-1-20.mobile-test.direct.quickconnect.to"
        )
        XCTAssertEqual(model.host, "mobile-test")
        XCTAssertEqual(model.activeProfile?.host, "mobile-test")
        XCTAssertTrue(model.isConnected)
    }

    @MainActor
    func testQuickConnect保存会话恢复时重新解析地址() async throws {
        let suiteName = "MobileModuleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = MobileRecordingAuthRepository()
        let resolver = MobileQuickConnectResolver()
        let passwordStore = MobileTestPasswordStore()
        let storedSession = AuthSession(
            sid: "mobile-restored-session",
            synoToken: nil,
            did: nil,
            isPortalPort: false
        )
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: MobileTestSessionStore(storedSession: storedSession),
            passwordStore: passwordStore,
            authRepository: repository,
            quickConnectResolver: resolver
        )
        let profile = try NasProfile(
            displayName: "移动端恢复测试",
            host: "mobile-test",
            port: 5_001
        )

        model.restore(profile)
        for _ in 0..<100 where model.isConnecting {
            try await Task.sleep(for: .milliseconds(20))
        }

        let requestedID = await resolver.requestedID
        let discoveredHost = await repository.discoveredHost
        XCTAssertEqual(requestedID, "mobile-test")
        XCTAssertEqual(
            discoveredHost,
            "192-168-1-20.mobile-test.direct.quickconnect.to"
        )
    }

    @MainActor
    func test冷启动恢复配置密码并自动登录() async throws {
        let suiteName = "MobileModuleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let passwordStore = MobileTestPasswordStore()

        let firstModel = MobileAppModel(
            defaults: defaults,
            sessionStore: MobileTestSessionStore(),
            passwordStore: passwordStore,
            authRepository: MobileRecordingAuthRepository(),
            quickConnectResolver: MobileQuickConnectResolver()
        )
        firstModel.displayName = "冷启动测试"
        firstModel.host = "mobile-test"
        firstModel.username = "tester"
        firstModel.password = "saved-password"
        firstModel.rememberPassword = true
        firstModel.autoLoginEnabled = true
        firstModel.connect()
        for _ in 0..<100 where firstModel.isConnecting {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(firstModel.isConnected)

        let restartedRepository = MobileRecordingAuthRepository()
        let restartedModel = MobileAppModel(
            defaults: defaults,
            sessionStore: MobileTestSessionStore(),
            passwordStore: passwordStore,
            authRepository: restartedRepository,
            quickConnectResolver: MobileQuickConnectResolver()
        )
        for _ in 0..<150 where !restartedModel.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(restartedModel.displayName, "冷启动测试")
        XCTAssertEqual(restartedModel.host, "mobile-test")
        XCTAssertEqual(restartedModel.username, "tester")
        XCTAssertEqual(restartedModel.password, "saved-password")
        XCTAssertTrue(restartedModel.rememberPassword)
        XCTAssertTrue(restartedModel.autoLoginEnabled)
        XCTAssertTrue(restartedModel.isConnected)
        let restartedLoginHost = await restartedRepository.loginHost
        XCTAssertEqual(
            restartedLoginHost,
            "192-168-1-20.mobile-test.direct.quickconnect.to"
        )

        restartedModel.logout()
        let signedOutModel = MobileAppModel(
            defaults: defaults,
            sessionStore: MobileTestSessionStore(),
            passwordStore: passwordStore,
            authRepository: MobileRecordingAuthRepository(),
            quickConnectResolver: MobileQuickConnectResolver()
        )
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(signedOutModel.isConnected)
        XCTAssertFalse(signedOutModel.autoLoginEnabled)
        XCTAssertTrue(signedOutModel.rememberPassword)
        XCTAssertEqual(signedOutModel.password, "saved-password")
    }
}
