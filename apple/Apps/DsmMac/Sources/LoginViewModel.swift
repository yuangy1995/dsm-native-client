import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

struct NASFileClipboard {
    let id = UUID()
    let sourceProfileID: UUID
    let items: [FileItem]
    let movesSource: Bool
}

struct PasteConflictPrompt {
    let clipboardID: UUID
    let destinationProfileID: UUID
    let destinationPath: String
    let conflictingNames: [String]
}

struct CertificatePrompt: Identifiable {
    let id = UUID()
    let error: DsmCertificateTrustError
    let previousFingerprint: String?

    var review: DsmCertificateReview {
        error.review
    }

    var isCertificateChange: Bool {
        if case .changed = error {
            return true
        }
        return false
    }

    var formattedPreviousFingerprint: String? {
        guard let previousFingerprint else {
            return nil
        }
        return stride(from: 0, to: previousFingerprint.count, by: 2).map { offset in
            let start = previousFingerprint.index(previousFingerprint.startIndex, offsetBy: offset)
            let end = previousFingerprint.index(
                start,
                offsetBy: min(2, previousFingerprint.distance(from: start, to: previousFingerprint.endIndex))
            )
            return String(previousFingerprint[start..<end])
        }.joined(separator: ":")
    }
}

@MainActor
final class NasProfileStore {
    private let defaults: UserDefaults
    private let key = "lanstash.nas-profiles.v1"
    private let autoLoginKeyPrefix = "lanstash.auto-login.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [NasProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([NasProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    func save(_ profiles: [NasProfile]) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: key)
    }

    func isAutoLoginEnabled(for profileID: UUID) -> Bool {
        defaults.bool(forKey: autoLoginKeyPrefix + profileID.uuidString)
    }

    func setAutoLoginEnabled(_ enabled: Bool, for profileID: UUID) {
        defaults.set(enabled, forKey: autoLoginKeyPrefix + profileID.uuidString)
    }

    func removeAutoLoginPreference(for profileID: UUID) {
        defaults.removeObject(forKey: autoLoginKeyPrefix + profileID.uuidString)
    }
}

@MainActor
@Observable
final class AppModel {
    enum ConnectionRoute: Equatable {
        case local
        case external
        case quickConnect

        var title: String {
            switch self {
            case .local: L10n.string("ui.30a5ce03914854b9")
            case .external: L10n.string("ui.e4a4560e3836dbf8")
            case .quickConnect: L10n.string("ui.157865e0ff66e717")
            }
        }

        var systemImage: String {
            switch self {
            case .local: "house.and.flag.fill"
            case .external: "globe"
            case .quickConnect: "bolt.horizontal.circle.fill"
            }
        }
    }

    private enum CertificateRetryMode {
        case connect
        case restore
    }

    private enum SessionRestoreOutcome: Equatable {
        case connected
        case credentialsNeeded
        case stopped
    }

    private struct DiscoveredConnection {
        let profile: NasProfile
        let capabilities: CapabilitySet
        let route: ConnectionRoute
    }

    private struct ConnectionContext {
        let connectionProfile: NasProfile
        let capabilities: CapabilitySet
        let session: AuthSession
        let route: ConnectionRoute
    }

    var profiles: [NasProfile] = []
    var selectedProfileID: UUID?
    var workspace: WorkspaceModel?

    var displayName = L10n.string("ui.b457fa7f7764aef5")
    var host = ""
    var port = ""
    var account = ""
    var password = ""
    var rememberPassword = false
    var autoLoginEnabled = false
    var otpCode = ""
    var requiresOTP = false
    var isBusy = false
    var statusMessage = L10n.string("ui.f8f70bd7266e12d3")
    var statusIsError = false
    var pendingCertificate: CertificatePrompt?
    var fileClipboard: NASFileClipboard?
    var pendingPasteConflict: PasteConflictPrompt?
    var isPreparingPaste = false

    private let profileStore: NasProfileStore
    private let authRepository: any AuthRepository
    private let quickConnectResolver: any QuickConnectResolving
    private let passwordStore: any PasswordSecureStoring
    private let desktopDriveSessionStore: any SessionSecureStoring
    private let secureStoreRollbackMigrator:
        DesktopSecureStoreRollbackMigrator?
    private let desktopDriveStore: DesktopDriveConfigurationStore
    private var selectedProfile: NasProfile?
    private var activeConnectionProfile: NasProfile?
    private var capabilities: CapabilitySet?
    private var session: AuthSession?
    private var certificateRetryMode: CertificateRetryMode = .connect
    private var didLoad = false
    private var workspacesByProfileID: [UUID: WorkspaceModel] = [:]
    private var connectionContextsByProfileID: [UUID: ConnectionContext] = [:]
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0

    var connectedWorkspaces: [WorkspaceModel] {
        profiles.compactMap { workspacesByProfileID[$0.id] }
    }

    var currentConnectionRoute: ConnectionRoute? {
        guard let selectedProfileID else { return nil }
        return connectionContextsByProfileID[selectedProfileID]?.route
    }

    init(
        profileStore: NasProfileStore = NasProfileStore(),
        authRepository: (any AuthRepository)? = nil,
        quickConnectResolver: any QuickConnectResolving = DsmQuickConnectResolver(),
        passwordStore: (any PasswordSecureStoring)? = nil,
        desktopDriveSessionStore: (any SessionSecureStoring)? = nil,
        secureStoreRollbackMigrator:
            DesktopSecureStoreRollbackMigrator? = nil,
        desktopDriveStore: DesktopDriveConfigurationStore = .init()
    ) {
        let usesProductionSecureStore = authRepository == nil && passwordStore == nil
        let localSecureStore = LocalFileSecureStore()
        let sharedSessionStore = SharedKeychainSessionStore()
        self.profileStore = profileStore
        self.authRepository = authRepository ?? DsmAuthRepository(
            sessionStore: localSecureStore
        )
        self.quickConnectResolver = quickConnectResolver
        self.passwordStore = passwordStore ?? localSecureStore
        self.desktopDriveSessionStore =
            desktopDriveSessionStore ?? sharedSessionStore
        self.secureStoreRollbackMigrator = secureStoreRollbackMigrator
            ?? (usesProductionSecureStore && !AppStorageNamespace.isLocalTest
                ? DesktopSecureStoreRollbackMigrator(
                    localStore: localSecureStore,
                    sharedSessionStore: sharedSessionStore,
                    configurationStore: desktopDriveStore
                )
                : nil)
        self.desktopDriveStore = desktopDriveStore
    }

    func load() {
        guard !didLoad else {
            return
        }
        didLoad = true
        profiles = profileStore.load()
        if let first = profiles.first {
            chooseProfile(
                first,
                attemptSessionRestore: profileStore.isAutoLoginEnabled(for: first.id)
            )
        }
    }

    func newProfile() {
        closeCurrentWorkspace()
        selectedProfileID = nil
        selectedProfile = nil
        displayName = L10n.string("ui.b457fa7f7764aef5")
        host = ""
        port = ""
        account = ""
        password = ""
        rememberPassword = false
        autoLoginEnabled = false
        otpCode = ""
        requiresOTP = false
        statusIsError = false
        statusMessage = L10n.string("ui.0da5f74db2060eae")
    }

    func selectProfile(id: UUID?) {
        guard let id, let profile = profiles.first(where: { $0.id == id }) else {
            newProfile()
            return
        }
        guard selectedProfile?.id != id else {
            return
        }
        closeCurrentWorkspace()
        chooseProfile(
            profile,
            attemptSessionRestore: profileStore.isAutoLoginEnabled(for: profile.id)
        )
    }

    func setRememberPassword(_ enabled: Bool) {
        rememberPassword = enabled
        if !enabled {
            setAutoLoginEnabled(false)
        }
    }

    func setAutoLoginEnabled(_ enabled: Bool) {
        autoLoginEnabled = enabled
        if enabled {
            rememberPassword = true
        }
        if let profileID = selectedProfile?.id {
            profileStore.setAutoLoginEnabled(enabled, for: profileID)
        }
    }

    func placeOnClipboard(_ items: [FileItem], moveSource: Bool) {
        guard let sourceProfileID = workspace?.profile.id, !items.isEmpty else { return }
        pendingPasteConflict = nil
        fileClipboard = NASFileClipboard(
            sourceProfileID: sourceProfileID,
            items: items,
            movesSource: moveSource
        )
        workspace?.statusIsError = false
        workspace?.statusMessage = moveSource
            ? L10n.string("ui.6392bdd08cbd3403", String(describing: items.count))
            : L10n.string("ui.86ab33b725f7f141", String(describing: items.count))
    }

    func pasteClipboardIntoCurrentFolder() {
        guard let clipboard = fileClipboard,
              let destination = workspace,
              !destination.currentPath.isEmpty,
              workspacesByProfileID[clipboard.sourceProfileID] != nil,
              pendingPasteConflict == nil,
              !isPreparingPaste else {
            return
        }
        isPreparingPaste = true
        destination.statusIsError = false
        destination.statusMessage = L10n.string("ui.091db372930e24ba")
        let destinationPath = destination.currentPath
        Task { [weak self] in
            guard let self else { return }
            defer { isPreparingPaste = false }
            guard let conflictingNames = await destination.pasteConflictNames(
                for: clipboard.items,
                in: destinationPath
            ) else {
                return
            }
            guard fileClipboard?.id == clipboard.id,
                  workspace?.profile.id == destination.profile.id,
                  workspace?.currentPath == destinationPath else {
                return
            }
            if conflictingNames.isEmpty {
                executePaste(clipboard, into: destination, overwrite: false)
            } else {
                destination.statusMessage = L10n.string("ui.536505780664c530")
                pendingPasteConflict = PasteConflictPrompt(
                    clipboardID: clipboard.id,
                    destinationProfileID: destination.profile.id,
                    destinationPath: destinationPath,
                    conflictingNames: conflictingNames
                )
            }
        }
    }

    func cancelPendingPaste() {
        pendingPasteConflict = nil
    }

    func resolvePendingPaste(replaceExisting: Bool) {
        guard let prompt = pendingPasteConflict else { return }
        pendingPasteConflict = nil
        guard let clipboard = fileClipboard,
              clipboard.id == prompt.clipboardID,
              let destination = workspace,
              destination.profile.id == prompt.destinationProfileID,
              destination.currentPath == prompt.destinationPath else {
            workspace?.statusIsError = true
            workspace?.statusMessage = L10n.string("ui.9911bf606b555d2c")
            return
        }
        executePaste(clipboard, into: destination, overwrite: replaceExisting)
    }

    private func executePaste(
        _ clipboard: NASFileClipboard,
        into destination: WorkspaceModel,
        overwrite: Bool
    ) {
        guard let source = workspacesByProfileID[clipboard.sourceProfileID] else { return }
        if source.profile.id == destination.profile.id {
            destination.enqueueFileOperation(
                clipboard.items,
                to: destination.currentPath,
                moveSource: clipboard.movesSource,
                overwrite: overwrite
            )
        } else {
            destination.enqueueCrossNASOperation(
                from: source,
                targets: clipboard.items,
                to: destination.currentPath,
                moveSource: clipboard.movesSource,
                overwrite: overwrite
            )
        }
        if clipboard.movesSource {
            fileClipboard = nil
        }
    }

    func renameCurrentNAS(to newName: String) -> String? {
        guard let profile = selectedProfile else {
            return L10n.string("ui.0c6ae7a01e05577b")
        }
        do {
            let updated = try profile.updating(displayName: newName)
            selectedProfile = updated
            displayName = updated.displayName
            workspace?.updateProfile(updated)
            workspacesByProfileID[updated.id]?.updateProfile(updated)

            if let context = connectionContextsByProfileID[updated.id] {
                let connectionProfile = try context.connectionProfile.updating(
                    displayName: updated.displayName
                )
                let updatedContext = ConnectionContext(
                    connectionProfile: connectionProfile,
                    capabilities: context.capabilities,
                    session: context.session,
                    route: context.route
                )
                connectionContextsByProfileID[updated.id] = updatedContext
                if activeConnectionProfile?.id == updated.id {
                    activeConnectionProfile = connectionProfile
                }
            }
            upsertProfile(updated)
            statusIsError = false
            statusMessage = L10n.string("ui.e2e911b17243c335", String(describing: updated.displayName))
            return nil
        } catch let error as NasProfileValidationError {
            return error.localizedDescription
        } catch {
            return L10n.string("ui.df0571287b74aa73")
        }
    }

    func cancelLogin() {
        invalidateConnectionAttempt()
        statusIsError = false
        statusMessage = L10n.string("ui.56b2a6f3710aedb2")
    }

    private func invalidateConnectionAttempt() {
        connectionGeneration += 1
        loginTask?.cancel()
        loginTask = nil
        isBusy = false
    }

    private func checkConnectionAttempt(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == connectionGeneration else { throw CancellationError() }
    }

    func connect() async {
        guard !isBusy else { return }
        loginTask?.cancel()
        connectionGeneration += 1
        let generation = connectionGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.performConnect(generation: generation)
        }
        loginTask = task
        await task.value
        if generation == connectionGeneration { loginTask = nil }
    }

    private func performConnect(generation: Int) async {
        guard !isBusy, generation == connectionGeneration, !Task.isCancelled else { return }
        isBusy = true
        statusIsError = false
        statusMessage = L10n.string("ui.a50211f01216a878")
        defer { if generation == connectionGeneration { isBusy = false } }

        do {
            if autoLoginEnabled {
                rememberPassword = true
            }
            let profile = try makeProfile()
            let submittedAccount = account
            let submittedPassword = password
            let submittedOTP = requiresOTP ? otpCode : nil
            let savesPassword = rememberPassword
            let enablesAutoLogin = autoLoginEnabled
            selectedProfile = profile
            upsertProfile(profile)

            let connection = try await discoverConnection(for: profile)
            try checkConnectionAttempt(generation)
            capabilities = connection.capabilities
            statusMessage = L10n.string("ui.1bdcf10e68a6e8f3")

            let authenticated = try await authRepository.login(
                profile: connection.profile,
                capabilities: connection.capabilities,
                account: submittedAccount,
                password: submittedPassword,
                otpCode: submittedOTP
            )
            try checkConnectionAttempt(generation)
            session = authenticated
            otpCode = ""
            requiresOTP = false

            let updated = try profile.updating(usernameHint: submittedAccount)
            selectedProfile = updated
            upsertProfile(updated)
            var passwordStorageFailed = false
            do {
                if savesPassword {
                    try await passwordStore.save(submittedPassword, for: updated.id)
                    try checkConnectionAttempt(generation)
                    password = submittedPassword
                } else {
                    try await passwordStore.remove(for: updated.id)
                    try checkConnectionAttempt(generation)
                    password = ""
                }
            } catch {
                try checkConnectionAttempt(generation)
                passwordStorageFailed = true
                password = ""
                rememberPassword = false
                autoLoginEnabled = false
            }
            profileStore.setAutoLoginEnabled(
                enablesAutoLogin && savesPassword && !passwordStorageFailed,
                for: updated.id
            )
            try await openWorkspace(
                profile: updated,
                connectionProfile: connection.profile,
                capabilities: connection.capabilities,
                session: authenticated,
                route: connection.route
            )
            if passwordStorageFailed {
                statusMessage = L10n.string("ui.963767a559c9fde3")
            }
        } catch is CancellationError {
            return
        } catch let error as DsmCertificateTrustError {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            certificateRetryMode = .connect
            pendingCertificate = CertificatePrompt(
                error: error,
                previousFingerprint: selectedProfile?.pinnedCertificateSHA256
            )
            statusIsError = true
            statusMessage = error.localizedDescription
        } catch let error as AppError {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            handleLoginError(error)
        } catch let error as NasProfileValidationError {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            statusIsError = true
            statusMessage = error.localizedDescription
            password = ""
            otpCode = ""
        } catch let error as NasAddressInputError {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            statusIsError = true
            statusMessage = error.localizedDescription
            password = ""
            otpCode = ""
        } catch let error as QuickConnectResolutionError {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            statusIsError = true
            statusMessage = error.localizedDescription
            password = ""
            otpCode = ""
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            statusIsError = true
            statusMessage = L10n.string("ui.94c254feea426d90")
            password = ""
            otpCode = ""
        }
    }

    func acceptPendingCertificate() async {
        guard let prompt = pendingCertificate,
              prompt.review.canBePinned,
              let profile = selectedProfile else {
            return
        }
        do {
            let updated = try profile.updating(
                pinnedCertificateSHA256: prompt.review.sha256Fingerprint,
                clearCertificatePin: false
            )
            selectedProfile = updated
            pendingCertificate = nil
            upsertProfile(updated)
            switch certificateRetryMode {
            case .connect:
                await connect()
            case .restore:
                await restoreSession(for: updated)
            }
        } catch {
            statusIsError = true
            statusMessage = L10n.string("ui.95cb4ccae2af816e")
        }
    }

    func cancelCertificateReview() {
        pendingCertificate = nil
        password = ""
        rememberPassword = false
        otpCode = ""
    }

    func deleteSelectedProfile() async {
        guard let profile = selectedProfile else {
            return
        }
        await clearStoredSessions(profileID: profile.id)
        try? await passwordStore.remove(for: profile.id)
        try? await desktopDriveStore.removeConnection(profileID: profile.id)
        profileStore.removeAutoLoginPreference(for: profile.id)
        workspacesByProfileID[profile.id]?.cancelAllWork()
        workspacesByProfileID[profile.id] = nil
        connectionContextsByProfileID[profile.id] = nil
        profiles.removeAll { $0.id == profile.id }
        try? profileStore.save(profiles)
        newProfile()
    }

    func logout() async {
        let profile = selectedProfile
        let connectionProfile = activeConnectionProfile
        let discovered = capabilities
        let authenticated = session
        workspace?.cancelAllWork()
        if let profile {
            workspacesByProfileID[profile.id] = nil
            connectionContextsByProfileID[profile.id] = nil
        }
        workspace = nil
        session = nil
        activeConnectionProfile = nil
        autoLoginEnabled = false
        otpCode = ""
        requiresOTP = false

        guard let profile else {
            password = ""
            rememberPassword = false
            statusMessage = L10n.string("ui.6e827a1b34d124ce")
            return
        }

        try? await desktopDriveSessionStore.remove(for: profile.id)

        // 主动退出只停用自动登录；已记住的密码保留并重新加载到登录界面，
        // 避免下次需要重新输入。
        profileStore.setAutoLoginEnabled(false, for: profile.id)
        await loadSavedPassword(for: profile)

        guard let discovered, let authenticated else {
            statusMessage = L10n.string("ui.6e827a1b34d124ce")
            return
        }
        do {
            try await authRepository.logout(
                profile: connectionProfile ?? profile,
                capabilities: discovered,
                session: authenticated
            )
            statusIsError = false
            statusMessage = L10n.string("ui.5a6ab4b41b819931")
        } catch {
            statusIsError = true
            statusMessage = L10n.string("ui.848c36deccd7c1bf")
        }
    }

    func returnToLoginAfterSessionIssue(message: String, from expectedWorkspace: WorkspaceModel? = nil) async {
        if let expectedWorkspace, workspace !== expectedWorkspace { return }
        invalidateConnectionAttempt()
        let generation = connectionGeneration
        let profile = selectedProfile
        workspace?.cancelAllWork()
        if let profile {
            workspacesByProfileID[profile.id] = nil
            connectionContextsByProfileID[profile.id] = nil
        }
        workspace = nil
        session = nil
        activeConnectionProfile = nil
        capabilities = nil
        password = ""
        rememberPassword = false
        if let profile {
            profileStore.setAutoLoginEnabled(false, for: profile.id)
        }
        autoLoginEnabled = false
        otpCode = ""
        requiresOTP = false

        if let profile {
            await clearStoredSessions(profileID: profile.id)
        }

        guard generation == connectionGeneration else { return }
        statusIsError = true
        statusMessage = message
    }

    private func chooseProfile(_ profile: NasProfile, attemptSessionRestore: Bool) {
        selectedProfile = profile
        activeConnectionProfile = nil
        selectedProfileID = profile.id
        displayName = profile.displayName
        host = profile.host
        port = profile.portOverride.map(String.init) ?? ""
        account = profile.usernameHint ?? ""
        password = ""
        rememberPassword = false
        autoLoginEnabled = profileStore.isAutoLoginEnabled(for: profile.id)
        otpCode = ""
        requiresOTP = false
        statusIsError = false
        statusMessage = L10n.string("ui.7ac3fe739c83e02d", String(describing: profile.displayName))

        if let cachedWorkspace = workspacesByProfileID[profile.id],
           let context = connectionContextsByProfileID[profile.id] {
            workspace = cachedWorkspace
            activeConnectionProfile = context.connectionProfile
            capabilities = context.capabilities
            session = context.session
            statusMessage = L10n.string("ui.679c2f48d4790cf6", String(describing: profile.displayName))
            Task { await loadSavedPassword(for: profile) }
            return
        }

        guard attemptSessionRestore else {
            Task { await loadSavedPassword(for: profile) }
            return
        }
        let generation = connectionGeneration
        Task {
            await loadSavedPassword(for: profile)
            guard generation == connectionGeneration,
                  selectedProfile?.id == profile.id, autoLoginEnabled, !password.isEmpty else {
                return
            }
            let outcome = await restoreSession(for: profile)
            if outcome == .credentialsNeeded, generation == connectionGeneration,
               selectedProfile?.id == profile.id,
               autoLoginEnabled,
               !password.isEmpty {
                await connect()
            }
        }
    }

    private func closeCurrentWorkspace() {
        invalidateConnectionAttempt()
        workspace = nil
        activeConnectionProfile = nil
        capabilities = nil
        session = nil
        pendingCertificate = nil
    }

    private func loadSavedPassword(for profile: NasProfile) async {
        let generation = connectionGeneration
        await secureStoreRollbackMigrator?.migrateIfNeeded(
            profileID: profile.id
        )
        do {
            let storedPassword = try await passwordStore.load(for: profile.id)
            guard generation == connectionGeneration, selectedProfile?.id == profile.id else {
                return
            }
            password = storedPassword ?? ""
            rememberPassword = storedPassword != nil
            if storedPassword == nil, autoLoginEnabled {
                setAutoLoginEnabled(false)
            }
        } catch {
            guard generation == connectionGeneration, selectedProfile?.id == profile.id else {
                return
            }
            password = ""
            rememberPassword = false
            if autoLoginEnabled {
                setAutoLoginEnabled(false)
            }
        }
    }

    @discardableResult
    private func restoreSession(for profile: NasProfile) async -> SessionRestoreOutcome {
        guard !isBusy else {
            return .stopped
        }
        let generation = connectionGeneration
        isBusy = true
        statusMessage = L10n.string("ui.39887059b5ec8c20")
        defer { if generation == connectionGeneration { isBusy = false } }
        do {
            await secureStoreRollbackMigrator?.migrateIfNeeded(
                profileID: profile.id
            )
            try checkConnectionAttempt(generation)
            let storedSession = try await authRepository.restoreSession(for: profile.id)
            try checkConnectionAttempt(generation)
            guard let restored = storedSession else {
                statusMessage = L10n.string("ui.7eb96b663a116103")
                return .credentialsNeeded
            }
            let connection = try await discoverConnection(for: profile)
            try checkConnectionAttempt(generation)
            session = restored
            capabilities = connection.capabilities

            let isValid = try await validateRestoredSession(
                profile: connection.profile,
                capabilities: connection.capabilities,
                session: restored
            )
            try checkConnectionAttempt(generation)
            if !isValid {
                await clearStoredSessions(profileID: profile.id)
                try checkConnectionAttempt(generation)
                statusIsError = true
                statusMessage = L10n.string("ui.5cdb81f9cb8e5cd7")
                return .credentialsNeeded
            }

            try await openWorkspace(
                profile: profile,
                connectionProfile: connection.profile,
                capabilities: connection.capabilities,
                session: restored,
                route: connection.route
            )
            return .connected
        } catch is CancellationError {
            return .stopped
        } catch let error as DsmCertificateTrustError {
            guard generation == connectionGeneration, !Task.isCancelled else { return .stopped }
            certificateRetryMode = .restore
            pendingCertificate = CertificatePrompt(
                error: error,
                previousFingerprint: profile.pinnedCertificateSHA256
            )
            statusIsError = true
            statusMessage = error.localizedDescription
            return .stopped
        } catch let error as QuickConnectResolutionError {
            guard generation == connectionGeneration, !Task.isCancelled else { return .stopped }
            statusIsError = true
            statusMessage = error.localizedDescription
            return .stopped
        } catch let error as AppError where error.isRetryable || error.category == .tlsUntrusted {
            guard generation == connectionGeneration, !Task.isCancelled else { return .stopped }
            statusIsError = true
            statusMessage = error.safeUserMessage
            return .stopped
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return .stopped }
            statusIsError = true
            statusMessage = L10n.string("ui.5cdb81f9cb8e5cd7")
            await clearStoredSessions(profileID: profile.id)
            return .credentialsNeeded
        }
    }

    private func validateRestoredSession(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) async throws -> Bool {
        // 恢复登录先读取权限摘要；已知没有文件权限时不能通过访问文件来验证身份。
        if capabilities[DsmAPIName.desktopInitData]?.selectedVersion == 1 {
            let transport = URLSessionTransport(
                expectedHost: profile.host,
                pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
                requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
            )
            let service = try DsmDesktopAppPrivilegesService(profile: profile, transport: transport)
            do {
                _ = try await service.read(capabilities: capabilities, session: session)
                return true
            } catch let error as AppError where [.apiUnavailable, .versionUnsupported, .invalidResponse,
                                                 .permissionDenied, .authenticationRequired].contains(error.category) {
                // 摘要不能读取时，仅用原有文件只读检查确认会话，不访问其他套件。
            }
        }
        let probe = try DsmFileRepository(
            profile: profile,
            capabilities: capabilities,
            session: session
        )
        do {
            _ = try await probe.listShares(offset: 0, limit: 1)
            return true
        } catch let error as AppError where error.category == .authenticationRequired {
            return false
        } catch let error as AppError where error.category == .permissionDenied
                    || error.category == .apiUnavailable || error.category == .versionUnsupported {
            // 文件应用不可用不等于整个账号退出；进入工作区后读取应用权限摘要。
            return true
        }
    }

    private func openWorkspace(
        profile: NasProfile,
        connectionProfile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        route: ConnectionRoute
    ) async throws {
        let desktopDriveSessionBridge: DesktopDriveSessionBridge?
        if DesktopCloudDriveAvailability.isAvailable {
            desktopDriveSessionBridge = DesktopDriveSessionBridge(
                profileID: profile.id,
                session: session,
                store: desktopDriveSessionStore,
                publishConnection: { [desktopDriveStore] in
                    try await desktopDriveStore.saveConnection(
                        profile: connectionProfile,
                        capabilities: capabilities
                    )
                }
            )
        } else {
            desktopDriveSessionBridge = nil
        }
        let repository = try DsmFileRepository(
            profile: connectionProfile,
            capabilities: capabilities,
            session: session
        )
        let chatRepository = try DsmChatRepository(
            profile: connectionProfile,
            capabilities: capabilities,
            session: session
        )
        let administrationRepository = try DsmNasAdministrationRepository(
            profile: connectionProfile,
            capabilities: capabilities,
            session: session
        )
        let serviceManagementRepository = try DsmServiceManagementRepository(
            profile: connectionProfile,
            capabilities: capabilities,
            session: session
        )
        let privilegesService = try DsmDesktopAppPrivilegesService(
            profile: connectionProfile,
            transport: URLSessionTransport(
                expectedHost: connectionProfile.host,
                pinnedCertificateSHA256: connectionProfile.pinnedCertificateSHA256,
                requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(connectionProfile.host)
            )
        )
        let accessReader = WorkspaceModuleAccessReader(
            files: repository, capabilities: capabilities,
            readPrivileges: { try await privilegesService.read(capabilities: capabilities, session: session) }
        )
        activeConnectionProfile = connectionProfile
        let openedWorkspace = WorkspaceModel(
            profile: profile,
            repository: repository,
            chatRepository: chatRepository,
            nasSettingsRepository: administrationRepository,
            serviceManagementRepository: serviceManagementRepository,
            desktopDriveSessionBridge: desktopDriveSessionBridge,
            moduleAccessLoader: { await accessReader.read() }
        )
        workspacesByProfileID[profile.id] = openedWorkspace
        connectionContextsByProfileID[profile.id] = ConnectionContext(
            connectionProfile: connectionProfile,
            capabilities: capabilities,
            session: session,
            route: route
        )
        workspace = openedWorkspace
        statusIsError = false
        statusMessage = L10n.string("ui.49263fcae6b8dce3", String(describing: profile.displayName))
    }

    private func clearStoredSessions(profileID: UUID) async {
        try? await authRepository.clearSession(for: profileID)
        try? await desktopDriveSessionStore.remove(for: profileID)
    }

    private func makeProfile() throws -> NasProfile {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let manualPort: Int?
        if trimmedPort.isEmpty {
            manualPort = nil
        } else {
            guard let parsed = Int(trimmedPort), (1...65_535).contains(parsed) else {
                throw NasProfileValidationError.invalidPort
            }
            manualPort = parsed
        }
        let parsedAddress = try NasAddressParser.parse(host, defaultPort: manualPort ?? 5_001)
        let portOverride = parsedAddress.hasExplicitPort ? parsedAddress.port : manualPort
        let effectivePort = portOverride ?? parsedAddress.port
        host = parsedAddress.host
        port = portOverride.map(String.init) ?? ""
        let connectionChanged = selectedProfile.map {
            $0.host != parsedAddress.host || $0.portOverride != portOverride
        } ?? false
        return try NasProfile(
            id: selectedProfile?.id ?? UUID(),
            displayName: displayName,
            host: parsedAddress.host,
            port: effectivePort,
            portOverride: portOverride,
            usernameHint: account,
            pinnedCertificateSHA256: connectionChanged ? nil : selectedProfile?.pinnedCertificateSHA256,
            lastDsmBuild: selectedProfile?.lastDsmBuild
        )
    }

    private func discoverConnection(for profile: NasProfile) async throws -> DiscoveredConnection {
        let generation = connectionGeneration
        let parsedAddress = try NasAddressParser.parse(profile.host, defaultPort: profile.port)
        guard parsedAddress.kind == .quickConnect else {
            let discovered = try await authRepository.discover(profile: profile)
            try checkConnectionAttempt(generation)
            return DiscoveredConnection(
                profile: profile,
                capabilities: discovered,
                route: Self.isLocalHost(profile.host) ? .local : .external
            )
        }

        statusMessage = L10n.string("ui.aa0582cad267718e")
        let endpoints: [QuickConnectEndpoint]
        do {
            endpoints = try await quickConnectResolver.resolve(id: parsedAddress.host)
        } catch let error as QuickConnectResolutionError where error == .noDirectRoute {
            // 没有直连候选时仍可继续请求中继，登录信息尚未发送。
            endpoints = []
        }
        try checkConnectionAttempt(generation)
        var certificateError: DsmCertificateTrustError?

        for endpoint in endpoints {
            try checkConnectionAttempt(generation)
            statusMessage = endpoint.kind == .local
                ? L10n.string("ui.3b38866d76d21239")
                : L10n.string("ui.307e0c332a164ea1")
            let endpointPort = profile.portOverride ?? endpoint.port
            let connectionProfile = try profile.updating(host: endpoint.host, port: endpointPort)
            do {
                let discovered = try await authRepository.discover(profile: connectionProfile)
                try checkConnectionAttempt(generation)
                return DiscoveredConnection(
                    profile: connectionProfile,
                    capabilities: discovered,
                    route: endpoint.kind == .local ? .local : .external
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DsmCertificateTrustError {
                certificateError = error
            } catch {
                // 当前候选不可用时继续尝试下一个候选，登录信息尚未发送。
                continue
            }
        }

        try checkConnectionAttempt(generation)
        statusMessage = L10n.string("ui.85e5d30ce27fc0e5")
        do {
            let relay = try await quickConnectResolver.requestRelay(id: parsedAddress.host)
            try checkConnectionAttempt(generation)
            let relayProfile = try profile.updating(
                host: relay.host,
                port: relay.port,
                clearCertificatePin: true
            )
            let discovered = try await authRepository.discover(profile: relayProfile)
            try checkConnectionAttempt(generation)
            return DiscoveredConnection(
                profile: relayProfile,
                capabilities: discovered,
                route: .quickConnect
            )
        } catch let error as QuickConnectResolutionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let certificateError {
                throw certificateError
            }
            throw error
        }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value == "::1" || value.hasSuffix(".local") || !value.contains(".") {
            return true
        }
        if value.hasPrefix("fc") || value.hasPrefix("fd") || value.hasPrefix("fe80:") {
            return true
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 169 && parts[1] == 254)
    }

    func moveProfile(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        let profileID = profiles[sourceIndex].id
        profiles.move(fromOffsets: source, toOffset: destination)
        if selectedProfileID == profileID {
            selectedProfileID = profileID
        }
        do {
            try profileStore.save(profiles)
        } catch {
            statusIsError = true
            statusMessage = L10n.string("ui.933bbb986cd6fbe8")
        }
    }

    private func upsertProfile(_ profile: NasProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        selectedProfileID = profile.id
        do {
            try profileStore.save(profiles)
        } catch {
            statusIsError = true
            statusMessage = L10n.string("ui.d17c4b8ff0247530")
        }
    }

    private func handleLoginError(_ error: AppError) {
        statusIsError = true
        statusMessage = error.safeUserMessage
        if error.category == .otpRequired {
            requiresOTP = true
            otpCode = ""
        } else {
            password = ""
            otpCode = ""
        }
    }
}
