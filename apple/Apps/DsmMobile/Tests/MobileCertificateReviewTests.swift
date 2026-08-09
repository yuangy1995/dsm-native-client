import DsmCore
import DsmNetwork
@testable import DsmMobile
import XCTest

private actor CertificateSessionStore: SessionSecureStoring {
    private var sessions: [UUID: AuthSession]
    private(set) var removeCount = 0

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
        removeCount += 1
        sessions.removeValue(forKey: profileID)
    }
}

private actor CertificatePasswordStore: PasswordSecureStoring {
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

private actor CertificateAuthRepository: AuthRepository {
    private let firstDiscoveryError: DsmCertificateTrustError
    private(set) var discoverProfiles: [NasProfile] = []
    private(set) var loginCount = 0
    private(set) var loginAccounts: [String] = []
    private(set) var loginPasswords: [String] = []
    private(set) var loginOTPCodes: [String?] = []

    init(firstDiscoveryError: DsmCertificateTrustError) {
        self.firstDiscoveryError = firstDiscoveryError
    }

    func discover(profile: NasProfile) async throws -> CapabilitySet {
        discoverProfiles.append(profile)
        if discoverProfiles.count == 1 {
            throw firstDiscoveryError
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
        loginCount += 1
        loginAccounts.append(account)
        loginPasswords.append(password)
        loginOTPCodes.append(otpCode)
        return AuthSession(
            sid: "certificate-review-test",
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

private actor TransientRestoreAuthRepository: AuthRepository {
    func discover(profile: NasProfile) async throws -> CapabilitySet {
        throw AppError(
            category: .networkUnavailable,
            isRetryable: true,
            safeUserMessage: "Temporary network failure"
        )
    }

    func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        throw CancellationError()
    }

    func restoreSession(for profileID: UUID) async throws -> AuthSession? { nil }
    func clearSession(for profileID: UUID) async throws {}
    func logout(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession) async throws {}
}

final class MobileCertificateReviewTests: XCTestCase {
    private let oldFingerprint = String(repeating: "A1", count: 32)
    private let newFingerprint = String(repeating: "B2", count: 32)

    @MainActor
    func test未受信任证书会暂停连接并显示核对提示() async throws {
        let review = makeReview(fingerprint: newFingerprint, canBePinned: true)
        let repository = CertificateAuthRepository(
            firstDiscoveryError: .untrusted(review)
        )
        let context = try makeModel(repository: repository)

        context.model.connect()
        try await waitUntil { context.model.pendingCertificate != nil }

        XCTAssertFalse(context.model.isConnecting)
        XCTAssertFalse(context.model.isConnected)
        XCTAssertEqual(context.model.pendingCertificate?.review, review)
        XCTAssertTrue(context.model.pendingCertificate?.allowsPinning == true)
        XCTAssertEqual(context.model.password, "test-password")
    }

    @MainActor
    func test证书变化提示同时保留旧指纹与新指纹() throws {
        let prompt = MobileCertificatePrompt(
            error: .changed(makeReview(fingerprint: newFingerprint, canBePinned: true)),
            previousFingerprint: oldFingerprint
        )

        XCTAssertTrue(prompt.isCertificateChange)
        XCTAssertEqual(prompt.review.formattedFingerprint, colonSeparated(newFingerprint))
        XCTAssertEqual(prompt.formattedPreviousFingerprint, colonSeparated(oldFingerprint))
    }

    @MainActor
    func test无效证书不允许确认固定() async throws {
        let repository = CertificateAuthRepository(
            firstDiscoveryError: .invalid(
                makeReview(fingerprint: newFingerprint, canBePinned: true)
            )
        )
        let context = try makeModel(repository: repository)

        context.model.connect()
        try await waitUntil { context.model.pendingCertificate != nil }
        XCTAssertFalse(context.model.pendingCertificate?.allowsPinning == true)

        context.model.acceptPendingCertificate()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertNotNil(context.model.pendingCertificate)
        XCTAssertNil(context.model.profiles.first?.pinnedCertificateSHA256)
        let discoverProfiles = await repository.discoverProfiles
        XCTAssertEqual(discoverProfiles.count, 1)
    }

    @MainActor
    func test接受证书后保存到同一Profile并仅发起一次重试() async throws {
        let repository = CertificateAuthRepository(
            firstDiscoveryError: .changed(
                makeReview(fingerprint: newFingerprint, canBePinned: true)
            )
        )
        let context = try makeModel(
            repository: repository,
            pinnedFingerprint: oldFingerprint
        )

        context.model.connect()
        try await waitUntil { context.model.pendingCertificate != nil }
        context.model.acceptPendingCertificate()
        try await waitUntil { context.model.isConnected }

        XCTAssertNil(context.model.pendingCertificate)
        XCTAssertEqual(context.model.profiles.count, 1)
        XCTAssertEqual(context.model.profiles.first?.id, context.profile.id)
        XCTAssertEqual(
            context.model.profiles.first?.pinnedCertificateSHA256,
            newFingerprint
        )
        let discoverProfiles = await repository.discoverProfiles
        let loginCount = await repository.loginCount
        XCTAssertEqual(discoverProfiles.count, 2)
        XCTAssertEqual(discoverProfiles.last?.pinnedCertificateSHA256, newFingerprint)
        XCTAssertEqual(loginCount, 1)
    }

    @MainActor
    func test取消证书核对不保存Pin且保留密码() async throws {
        let repository = CertificateAuthRepository(
            firstDiscoveryError: .untrusted(
                makeReview(fingerprint: newFingerprint, canBePinned: true)
            )
        )
        let context = try makeModel(repository: repository)
        context.model.persistProfiles()
        let dataBefore = context.defaults.data(forKey: context.model.profileKey)

        context.model.connect()
        try await waitUntil { context.model.pendingCertificate != nil }
        context.model.cancelCertificateReview()

        XCTAssertNil(context.model.pendingCertificate)
        XCTAssertEqual(context.model.password, "test-password")
        XCTAssertNil(context.model.profiles.first?.pinnedCertificateSHA256)
        XCTAssertEqual(
            context.defaults.data(forKey: context.model.profileKey),
            dataBefore
        )
        let discoverProfiles = await repository.discoverProfiles
        XCTAssertEqual(discoverProfiles.count, 1)
    }

    @MainActor
    func test证书提示后编辑资料仍只固定并重试原Profile() async throws {
        let repository = CertificateAuthRepository(
            firstDiscoveryError: .untrusted(
                makeReview(fingerprint: newFingerprint, canBePinned: true)
            )
        )
        let context = try makeModel(repository: repository)

        context.model.connect()
        try await waitUntil { context.model.pendingCertificate != nil }
        context.model.host = "nas-b.test"
        context.model.username = "account-b"
        context.model.password = "password-b"
        context.model.otpCode = "222222"
        context.model.acceptPendingCertificate()
        try await waitUntil { context.model.isConnected }

        let discoveries = await repository.discoverProfiles
        XCTAssertEqual(discoveries.count, 2)
        XCTAssertTrue(discoveries.allSatisfy { $0.id == context.profile.id })
        XCTAssertTrue(discoveries.allSatisfy { $0.host == context.profile.host })
        XCTAssertEqual(discoveries.last?.pinnedCertificateSHA256, newFingerprint)
        XCTAssertEqual(context.model.activeProfile?.id, context.profile.id)
        let loginAccounts = await repository.loginAccounts
        let loginPasswords = await repository.loginPasswords
        let loginOTPCodes = await repository.loginOTPCodes
        XCTAssertEqual(loginAccounts, ["tester"])
        XCTAssertEqual(loginPasswords, ["test-password"])
        XCTAssertEqual(loginOTPCodes, [nil])
    }

    @MainActor
    func test恢复会话遇到证书提示时不删除现有会话() async throws {
        let repository = CertificateAuthRepository(
            firstDiscoveryError: .untrusted(
                makeReview(fingerprint: newFingerprint, canBePinned: true)
            )
        )
        let suiteName = "MobileCertificateReviewTests.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let profile = try NasProfile(
            displayName: "Test NAS",
            host: "nas.test",
            port: 5_001,
            usernameHint: "tester"
        )
        let sessionStore = CertificateSessionStore(
            sessions: [
                profile.id: AuthSession(
                    sid: "existing-session",
                    synoToken: nil,
                    did: nil,
                    isPortalPort: false
                )
            ]
        )
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: sessionStore,
            passwordStore: CertificatePasswordStore(),
            authRepository: repository
        )

        model.restore(profile)
        try await waitUntil { model.pendingCertificate != nil }

        XCTAssertFalse(model.isConnecting)
        let removeCount = await sessionStore.removeCount
        let storedSession = try await sessionStore.load(for: profile.id)
        XCTAssertEqual(removeCount, 0)
        XCTAssertNotNil(storedSession)
    }

    @MainActor
    func test恢复会话遇到临时网络错误不删除现有会话() async throws {
        let suiteName = "MobileCertificateReviewTests.transient-restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = try NasProfile(displayName: "Test NAS", host: "nas.test", port: 5_001)
        let existingSession = AuthSession(
            sid: "existing-session",
            synoToken: nil,
            did: nil,
            isPortalPort: false
        )
        let sessionStore = CertificateSessionStore(sessions: [profile.id: existingSession])
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: sessionStore,
            passwordStore: CertificatePasswordStore(),
            authRepository: TransientRestoreAuthRepository()
        )

        model.restore(profile)
        try await waitUntil { !model.isConnecting }

        let removeCount = await sessionStore.removeCount
        let storedSession = try await sessionStore.load(for: profile.id)
        XCTAssertEqual(removeCount, 0)
        XCTAssertEqual(storedSession, existingSession)
        XCTAssertEqual(model.loginError, "Temporary network failure")
        XCTAssertFalse(model.isConnected)
    }

    @MainActor
    private func makeModel(
        repository: CertificateAuthRepository,
        pinnedFingerprint: String? = nil
    ) throws -> (model: MobileAppModel, profile: NasProfile, defaults: UserDefaults) {
        let suiteName = "MobileCertificateReviewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let profile = try NasProfile(
            displayName: "Test NAS",
            host: "nas.test",
            port: 5_001,
            usernameHint: "tester",
            pinnedCertificateSHA256: pinnedFingerprint
        )
        let model = MobileAppModel(
            defaults: defaults,
            sessionStore: CertificateSessionStore(),
            passwordStore: CertificatePasswordStore(),
            authRepository: repository
        )
        model.profiles = [profile]
        model.applyProfile(profile)
        model.username = "tester"
        model.password = "test-password"
        return (model, profile, defaults)
    }

    private func makeReview(
        fingerprint: String,
        canBePinned: Bool
    ) -> DsmCertificateReview {
        DsmCertificateReview(
            host: "nas.test",
            subjectSummary: "Test NAS Certificate",
            sha256Fingerprint: fingerprint,
            canBePinned: canBePinned
        )
    }

    private func colonSeparated(_ fingerprint: String) -> String {
        fingerprint.enumerated().reduce(into: "") { result, pair in
            if pair.offset > 0, pair.offset.isMultiple(of: 2) {
                result.append(":")
            }
            result.append(pair.element)
        }
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待异步状态超时")
    }
}
