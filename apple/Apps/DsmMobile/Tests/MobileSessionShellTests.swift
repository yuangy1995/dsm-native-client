import DsmCore
import DsmNetwork
@testable import DsmMobile
import XCTest

private actor SessionShellSessionStore: SessionSecureStoring {
    private var sessions: [UUID: AuthSession]

    init(sessions: [UUID: AuthSession] = [:]) {
        self.sessions = sessions
    }

    func save(_ session: AuthSession, for profileID: UUID) async throws {
        sessions[profileID] = session
    }

    func load(for profileID: UUID) async throws -> AuthSession? {
        sessions[profileID]
    }

    func remove(for profileID: UUID) async throws {
        sessions.removeValue(forKey: profileID)
    }
}

private actor SessionShellPasswordStore: PasswordSecureStoring {
    private var passwords: [UUID: String]

    init(passwords: [UUID: String] = [:]) {
        self.passwords = passwords
    }

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

private actor SuspendedSessionShellPasswordStore: PasswordSecureStoring {
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private(set) var saveStarted = false

    func save(_ password: String, for profileID: UUID) async throws {
        saveStarted = true
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
    }

    func load(for profileID: UUID) async throws -> String? { nil }
    func remove(for profileID: UUID) async throws {}

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

private actor SuspendedDiscoveryAuthRepository: AuthRepository {
    struct Login: Equatable {
        let profileID: UUID
        let account: String
        let password: String
        let otpCode: String?
    }

    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    private(set) var discoveryStarted = false
    private(set) var logins: [Login] = []

    func discover(profile: NasProfile) async throws -> CapabilitySet {
        discoveryStarted = true
        await withCheckedContinuation { continuation in
            discoveryContinuation = continuation
        }
        return CapabilitySet([:])
    }

    func releaseDiscovery() {
        discoveryContinuation?.resume()
        discoveryContinuation = nil
    }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        logins.append(Login(
            profileID: profile.id,
            account: account,
            password: password,
            otpCode: otpCode
        ))
        return AuthSession(sid: "snapshot-test", synoToken: nil, did: nil, isPortalPort: false)
    }

    func restoreSession(for profileID: UUID) async throws -> AuthSession? { nil }
    func clearSession(for profileID: UUID) async throws {}
    func logout(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession) async throws {}
}

private actor ImmediateSessionShellAuthRepository: AuthRepository {
    func discover(profile: NasProfile) async throws -> CapabilitySet { CapabilitySet([:]) }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        AuthSession(sid: "password-save-test", synoToken: nil, did: nil, isPortalPort: false)
    }

    func restoreSession(for profileID: UUID) async throws -> AuthSession? { nil }
    func clearSession(for profileID: UUID) async throws {}
    func logout(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession) async throws {}
}

private actor SessionShellAuthRepository: AuthRepository {
    private(set) var loginStarted = false
    private(set) var logoutCount = 0

    func discover(profile: NasProfile) async throws -> CapabilitySet {
        CapabilitySet([:])
    }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        loginStarted = true
        try await Task.sleep(for: .seconds(30))
        return AuthSession(
            sid: "session-shell-test",
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
    ) async throws {
        logoutCount += 1
    }
}

private actor SuspendedDownloadStationLoader {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    func load() async -> DownloadStationSnapshot {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return DownloadStationSnapshot(
            source: .official,
            tasks: [DownloadStationTask(id: "late", title: "late", status: "downloading")]
        )
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct SessionPhotoRepository: PhotoLibraryRepository {
    func discoverSpaces() async throws -> [PhotoSpace] { [] }

    func listFolder(
        in space: PhotoSpace,
        path: String,
        offset: Int,
        limit: Int
    ) async throws -> PhotoLibraryPage {
        PhotoLibraryPage(
            folderPath: path,
            items: [],
            offset: offset,
            nextOffset: offset,
            sourceTotal: 0,
            hasMore: false
        )
    }

    func getThumbnail(for item: PhotoLibraryItem, size: ThumbnailSize) async throws -> Data {
        Data()
    }

    func scanTimeline(
        in space: PhotoSpace,
        startingAt folderPaths: [String],
        existingFolderItemPaths: [String: [String]],
        onUpdate: @escaping @Sendable (PhotoTimelineScanUpdate) async -> Void
    ) async throws {}
}

private actor SessionContainerInventoryRepository: MobileContainerInventoryReading {
    nonisolated let profileID: UUID

    init(profileID: UUID) {
        self.profileID = profileID
    }

    func loadInventory() async throws -> ContainerInventorySnapshot {
        ContainerInventorySnapshot(
            source: .internalAPI,
            containers: [
                ContainerInventoryItem(
                    id: "container-session-test",
                    name: "Container session test",
                    status: "running",
                    image: "synthetic:latest"
                )
            ]
        )
    }
}

final class MobileSessionShellTests: XCTestCase {
    @MainActor
    func test离开容器模块和切换活动Profile都会解绑但保留分区缓存() async throws {
        let suiteName = "MobileSessionShellTests.container-deactivate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let second = try NasProfile(displayName: "NAS B", host: "nas-b.test", port: 5_001)
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.activeProfile = first
        await model.containerInventoryModel.activate(
            profileID: first.id,
            repository: SessionContainerInventoryRepository(profileID: first.id)
        )
        model.selectedModule = .containers

        model.selectModule(.settings)

        XCTAssertNil(model.containerInventoryModel.activeProfileID)
        XCTAssertEqual(
            model.containerInventoryModel.profiles[first.id]?.items.map(\.name),
            ["Container session test"]
        )

        await model.containerInventoryModel.activate(
            profileID: first.id,
            repository: SessionContainerInventoryRepository(profileID: first.id)
        )
        model.activeProfile = second
        XCTAssertNil(model.containerInventoryModel.activeProfileID)
        XCTAssertNotNil(model.containerInventoryModel.profiles[first.id])
    }

    @MainActor
    func test删除Profile会清除对应容器缓存() async throws {
        let suiteName = "MobileSessionShellTests.container-remove.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.profiles = [profile]
        model.activeProfile = profile
        await model.containerInventoryModel.activate(
            profileID: profile.id,
            repository: SessionContainerInventoryRepository(profileID: profile.id)
        )

        model.removeProfile(profile)

        XCTAssertNil(model.containerInventoryModel.activeProfileID)
        XCTAssertNil(model.containerInventoryModel.profiles[profile.id])
    }

    @MainActor
    func test登出清除当前容器缓存而普通clear只解绑() async throws {
        let suiteName = "MobileSessionShellTests.container-logout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.activeProfile = profile
        await model.containerInventoryModel.activate(
            profileID: profile.id,
            repository: SessionContainerInventoryRepository(profileID: profile.id)
        )

        model.clearWorkspace()
        XCTAssertNil(model.containerInventoryModel.activeProfileID)
        XCTAssertNotNil(model.containerInventoryModel.profiles[profile.id])

        model.activeProfile = profile
        await model.containerInventoryModel.activate(
            profileID: profile.id,
            repository: SessionContainerInventoryRepository(profileID: profile.id)
        )
        model.logout()
        XCTAssertNil(model.containerInventoryModel.profiles[profile.id])
    }

    @MainActor
    func test连接提交后编辑字段仍只使用冻结凭据() async throws {
        let suiteName = "MobileSessionShellTests.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try NasProfile(
            displayName: "NAS A",
            host: "nas-a.test",
            port: 5_001,
            usernameHint: "account-a"
        )
        let repository = SuspendedDiscoveryAuthRepository()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: repository
        )
        model.profiles = [profile]
        model.applyProfile(profile)
        model.username = "account-a"
        model.password = "password-a"
        model.otpCode = "111111"

        model.connect()
        try await waitUntilAsync { await repository.discoveryStarted }
        model.username = "account-b"
        model.password = "password-b"
        model.otpCode = "222222"
        await repository.releaseDiscovery()
        try await waitUntil { model.isConnected }

        XCTAssertNotNil(model.photoRepository)

        let logins = await repository.logins
        XCTAssertEqual(logins, [
            .init(
                profileID: profile.id,
                account: "account-a",
                password: "password-a",
                otpCode: "111111"
            )
        ])
    }

    @MainActor
    func test发现挂起时切换Profile会取消旧提交且绝不发送新凭据() async throws {
        let suiteName = "MobileSessionShellTests.snapshot-switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let second = try NasProfile(displayName: "NAS B", host: "nas-b.test", port: 5_001)
        let repository = SuspendedDiscoveryAuthRepository()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: repository
        )
        model.profiles = [first, second]
        model.applyProfile(first)
        model.username = "account-a"
        model.password = "password-a"

        model.connect()
        try await waitUntilAsync { await repository.discoveryStarted }
        model.selectProfile(second)
        model.username = "account-b"
        model.password = "password-b"
        await repository.releaseDiscovery()
        try await Task.sleep(for: .milliseconds(30))

        let logins = await repository.logins
        XCTAssertEqual(logins, [])
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.selectedProfileID, second.id)
    }

    @MainActor
    func test密码保存挂起后取消不会回写连接状态() async throws {
        let suiteName = "MobileSessionShellTests.password-save-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let passwordStore = SuspendedSessionShellPasswordStore()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: passwordStore,
            authRepository: ImmediateSessionShellAuthRepository()
        )
        model.profiles = [profile]
        model.applyProfile(profile)
        model.username = "account-a"
        model.password = "password-a"
        model.rememberPassword = true

        model.connect()
        try await waitUntilAsync { await passwordStore.saveStarted }
        model.cancelConnection()
        await passwordStore.releaseSave()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.activeProfile)
        XCTAssertNil(model.fileRepository)
        XCTAssertNil(model.photoRepository)
        XCTAssertEqual(model.profiles, [profile])
    }

    @MainActor
    func test取消连接保留资料和密码且不显示登录错误() async throws {
        let suiteName = "MobileSessionShellTests.cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try NasProfile(
            displayName: "NAS A",
            host: "nas-a.test",
            port: 5_001,
            usernameHint: "tester"
        )
        let authRepository = SessionShellAuthRepository()
        let passwordStore = SessionShellPasswordStore(
            passwords: [profile.id: "saved-password"]
        )
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: passwordStore,
            authRepository: authRepository
        )
        model.profiles = [profile]
        model.applyProfile(profile)
        model.password = "saved-password"
        model.rememberPassword = true

        model.connect()
        for _ in 0..<100 {
            if await authRepository.loginStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let loginStarted = await authRepository.loginStarted
        XCTAssertTrue(loginStarted)

        model.cancelConnection()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(model.isConnecting)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.loginError)
        XCTAssertNil(model.connectionStatus)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertEqual(model.password, "saved-password")
        XCTAssertTrue(model.rememberPassword)
        let storedPassword = try await passwordStore.load(for: profile.id)
        XCTAssertEqual(storedPassword, "saved-password")
    }

    @MainActor
    func test切换NAS只结束本地工作区而不调用远程退出() async throws {
        let suiteName = "MobileSessionShellTests.switch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let second = try NasProfile(displayName: "NAS B", host: "nas-b.test", port: 5_001)
        let authRepository = SessionShellAuthRepository()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: authRepository
        )
        model.profiles = [first, second]
        model.activeProfile = first
        model.activeConnectionProfile = first
        model.capabilities = CapabilitySet([:])
        model.session = AuthSession(
            sid: "active-session",
            synoToken: nil,
            did: nil,
            isPortalPort: false
        )
        model.isConnected = true

        model.switchProfile(second)
        try await Task.sleep(for: .milliseconds(100))

        let logoutCount = await authRepository.logoutCount
        XCTAssertEqual(logoutCount, 0)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.selectedProfileID, second.id)
        XCTAssertEqual(model.displayName, second.displayName)
        XCTAssertEqual(model.profiles, [first, second])
    }

    @MainActor
    func test两个Profile的顶层与模块导航状态互不串用() throws {
        let suiteName = "MobileSessionShellTests.navigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let second = try NasProfile(displayName: "NAS B", host: "nas-b.test", port: 5_001)
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )

        model.activeProfile = first
        model.selectedTopLevel = .activity
        model.selectedModule = .downloads
        model.saveNavigationState()

        model.activeProfile = second
        model.restoreNavigationState(for: second.id)
        XCTAssertEqual(model.selectedTopLevel, .files)
        XCTAssertEqual(model.selectedModule, .files)
        model.selectedTopLevel = .more
        model.selectedModule = .settings
        model.saveNavigationState()

        model.restoreNavigationState(for: first.id)
        XCTAssertEqual(model.selectedTopLevel, .activity)
        XCTAssertEqual(model.selectedModule, .downloads)

        model.restoreNavigationState(for: second.id)
        XCTAssertEqual(model.selectedTopLevel, .more)
        XCTAssertEqual(model.selectedModule, .settings)
    }

    @MainActor
    func test关闭当前可选模块确定回退且隐藏模块不能再次选择() {
        let suiteName = "MobileSessionShellTests.settings-navigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.selectedTopLevel = .more
        model.selectedModule = .containers

        model.setModule(.containers, isVisible: false)

        XCTAssertEqual(model.selectedTopLevel, .more)
        XCTAssertEqual(model.selectedModule, .nasSettings)
        XCTAssertFalse(model.visibleChildModules(for: .more).contains(.containers))

        model.selectModule(.containers)
        XCTAssertEqual(model.selectedModule, .nasSettings)
    }

    @MainActor
    func test隐藏默认模块后进入分组使用首个可见安全入口() {
        let suiteName = "MobileSessionShellTests.settings-fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.setModule(.nasSettings, isVisible: false)

        model.selectTopLevel(.more)

        XCTAssertEqual(model.selectedTopLevel, .more)
        XCTAssertEqual(model.selectedModule, .containers)
    }

    @MainActor
    func test可见子模块同时受本机偏好与当前NAS能力约束() {
        let suiteName = "MobileSessionShellTests.capability-preference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.capabilities = Self.capabilities([
            DsmAPIName.downloadStationTask,
            DsmAPIName.coreSystem,
        ])

        XCTAssertEqual(model.visibleChildModules(for: .activity), [.transfers, .downloads])
        XCTAssertEqual(model.visibleChildModules(for: .more), [.nasSettings, .settings])

        model.setModule(.downloads, isVisible: false)
        XCTAssertEqual(model.visibleChildModules(for: .activity), [.transfers])
    }

    @MainActor
    func test隐藏Downloads后忽略不响应取消的迟到结果() async {
        let suiteName = "MobileSessionShellTests.download-hidden.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try! NasProfile(displayName: "NAS", host: "nas.test", port: 5_001)
        let loader = SuspendedDownloadStationLoader()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.activeProfile = profile
        model.isConnected = true
        model.capabilities = Self.capabilities([DsmAPIName.downloadStationTask])
        model.selectedTopLevel = .activity
        model.selectedModule = .transfers
        model.downloadStationLoadOverride = { await loader.load() }

        model.selectModule(.downloads)
        await loader.waitUntilStarted()
        model.setModule(.downloads, isVisible: false)
        await loader.release()
        await Task.yield()

        XCTAssertEqual(model.selectedModule, .transfers)
        XCTAssertNil(model.downloadSnapshot)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func test退出时忽略不响应取消的Downloads迟到结果() async {
        let suiteName = "MobileSessionShellTests.download-logout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try! NasProfile(displayName: "NAS", host: "nas.test", port: 5_001)
        let loader = SuspendedDownloadStationLoader()
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.activeProfile = profile
        model.isConnected = true
        model.capabilities = Self.capabilities([DsmAPIName.downloadStationTask])
        model.selectedTopLevel = .activity
        model.selectedModule = .transfers
        model.downloadStationLoadOverride = { await loader.load() }

        model.selectModule(.downloads)
        await loader.waitUntilStarted()
        model.logout()
        await loader.release()
        await Task.yield()

        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.downloadSnapshot)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func test退出和删除Profile显式清除对应照片状态() async throws {
        let suiteName = "MobileSessionShellTests.photo-purge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try NasProfile(displayName: "NAS A", host: "nas-a.test", port: 5_001)
        let second = try NasProfile(displayName: "NAS B", host: "nas-b.test", port: 5_001)
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: SessionShellSessionStore(),
            passwordStore: SessionShellPasswordStore(),
            authRepository: SessionShellAuthRepository()
        )
        model.profiles = [first, second]
        model.activeProfile = first
        model.isConnected = true
        await model.photoLibraryModel.activate(profileID: first.id, repository: SessionPhotoRepository())
        XCTAssertNotNil(model.photoLibraryModel.profiles[first.id])

        model.logout()
        try await waitUntil { model.photoLibraryModel.profiles[first.id] == nil }

        await model.photoLibraryModel.activate(profileID: second.id, repository: SessionPhotoRepository())
        XCTAssertNotNil(model.photoLibraryModel.profiles[second.id])
        model.removeProfile(second)
        try await waitUntil { model.photoLibraryModel.profiles[second.id] == nil }
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

    @MainActor
    private func waitUntilAsync(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待异步状态超时")
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待主线程状态超时")
    }
}
