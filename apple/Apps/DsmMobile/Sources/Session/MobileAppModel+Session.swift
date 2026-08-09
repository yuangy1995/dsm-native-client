import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    func selectProfile(_ profile: NasProfile) {
        cancelConnection()
        applyProfile(profile)
        Task { await loadSavedPassword(for: profile, attemptsAutoLogin: false) }
    }

    func switchProfile(_ profile: NasProfile) {
        guard activeProfile?.id != profile.id else { return }
        cancelConnection()
        saveNavigationState()
        clearWorkspace()
        applyProfile(profile)
        restore(profile, fallbackToPassword: true)
    }

    func beginNewProfile() {
        cancelConnection()
        saveNavigationState()
        clearWorkspace()
        newProfile()
    }

    func applyProfile(_ profile: NasProfile) {
        selectedProfileID = profile.id
        defaults.set(profile.id.uuidString, forKey: lastProfileKey)
        displayName = profile.displayName
        host = profile.host
        port = profile.portOverride.map(String.init) ?? ""
        username = profile.usernameHint ?? ""
        password = ""
        rememberPassword = false
        autoLoginEnabled = defaults.bool(forKey: autoLoginKeyPrefix + profile.id.uuidString)
        otpCode = ""
        loginError = nil
        connectionStatus = nil
        pendingCertificate = nil
        certificateRetryContext = nil
    }

    func newProfile() {
        selectedProfileID = nil
        displayName = L10n.string("ui.b457fa7f7764aef5")
        host = ""
        port = ""
        username = ""
        password = ""
        rememberPassword = false
        autoLoginEnabled = false
        otpCode = ""
        loginError = nil
        connectionStatus = nil
        pendingCertificate = nil
        certificateRetryContext = nil
        defaults.removeObject(forKey: lastProfileKey)
    }

    func removeProfile(_ profile: NasProfile) {
        let removesActiveProfile = activeProfile?.id == profile.id
        if selectedProfileID == profile.id || removesActiveProfile {
            cancelConnection()
        }
        profiles.removeAll { $0.id == profile.id }
        fileShareLinkModel.purge(profileID: profile.id)
        purgeFileLocations(profileID: profile.id)
        Task { await photoLibraryModel.purge(profileID: profile.id) }
        chatModel.purge(profileID: profile.id)
        nasHealthModel.purge(profileID: profile.id)
        containerInventoryModel.purge(profileID: profile.id)
        virtualMachineInventoryModel.purge(profileID: profile.id)
        navigationStates.removeValue(forKey: profile.id)
        persistProfiles()
        defaults.removeObject(forKey: autoLoginKeyPrefix + profile.id.uuidString)
        Task {
            try? await sessionStore.remove(for: profile.id)
            try? await passwordStore.remove(for: profile.id)
        }
        if removesActiveProfile {
            clearWorkspace()
            newProfile()
        } else if selectedProfileID == profile.id {
            newProfile()
        }
    }

    func connect() {
        guard !isConnecting else { return }
        let submission: MobileConnectionSubmission
        do {
            submission = MobileConnectionSubmission(
                profile: try makeProfile(),
                account: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                otpCode: otpCode.isEmpty ? nil : otpCode,
                rememberPassword: rememberPassword,
                autoLoginEnabled: autoLoginEnabled
            )
        } catch {
            loginError = userMessage(error)
            return
        }
        connect(submission: submission)
    }

    private func connect(submission: MobileConnectionSubmission) {
        guard !isConnecting else { return }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isConnecting = true
        loginError = nil
        connectionStatus = L10n.string("ui.a50211f01216a878")
        connectionTask = Task {
            do {
                let connection = try await discoverConnection(for: submission.profile)
                try requireCurrentConnectionAttempt(attemptID)
                connectionStatus = L10n.string("ui.1bdcf10e68a6e8f3")
                let session = try await authRepository.login(
                    profile: connection.profile,
                    capabilities: connection.capabilities,
                    account: submission.account,
                    password: submission.password,
                    otpCode: submission.otpCode
                )
                try requireCurrentConnectionAttempt(attemptID)
                if submission.rememberPassword {
                    try await passwordStore.save(submission.password, for: submission.profile.id)
                } else {
                    try? await passwordStore.remove(for: submission.profile.id)
                }
                try requireCurrentConnectionAttempt(attemptID)
                defaults.set(
                    submission.autoLoginEnabled && submission.rememberPassword,
                    forKey: autoLoginKeyPrefix + submission.profile.id.uuidString
                )
                defaults.set(submission.profile.id.uuidString, forKey: lastProfileKey)
                let workspace = try makeWorkspaceRepositories(
                    profile: connection.profile,
                    capabilities: connection.capabilities,
                    session: session
                )
                try requireCurrentConnectionAttempt(attemptID)
                applyWorkspaceRepositories(workspace)
                saveProfile(submission.profile)
                self.capabilities = connection.capabilities
                self.session = session
                activeConnectionProfile = connection.profile
                activeProfile = submission.profile
                restoreNavigationState(for: submission.profile.id)
                isConnected = true
                finishConnectionAttempt(attemptID)
                if !submission.rememberPassword,
                   selectedProfileID == submission.profile.id {
                    password = ""
                    rememberPassword = false
                    autoLoginEnabled = false
                }
                await loadSelectedModule()
            } catch is CancellationError {
                finishConnectionAttempt(attemptID)
            } catch let error as DsmCertificateTrustError {
                guard connectionAttemptID == attemptID else { return }
                certificateRetryContext = .connect(submission: submission)
                pendingCertificate = MobileCertificatePrompt(
                    error: error,
                    previousFingerprint: submission.profile.pinnedCertificateSHA256
                )
                loginError = nil
                finishConnectionAttempt(attemptID)
            } catch {
                guard connectionAttemptID == attemptID else { return }
                let appError = error as? AppError
                needsOTP = appError?.category == .otpRequired
                loginError = appError?.safeUserMessage
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? L10n.string("ui.0279a181344aee7f")
                finishConnectionAttempt(attemptID)
            }
        }
    }

    func restore(_ profile: NasProfile, fallbackToPassword: Bool = false) {
        guard !isConnecting else { return }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isConnecting = true
        loginError = nil
        connectionStatus = L10n.string("ui.9e10c995ba5971bf")
        connectionTask = Task {
            do {
                guard let session = try await sessionStore.load(for: profile.id) else {
                    throw AppError(
                        category: .authenticationRequired,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.77a666ac48251d37")
                    )
                }
                try requireCurrentConnectionAttempt(attemptID)
                let connection = try await discoverConnection(for: profile)
                try requireCurrentConnectionAttempt(attemptID)
                let workspace = try makeWorkspaceRepositories(
                    profile: connection.profile,
                    capabilities: connection.capabilities,
                    session: session
                )
                _ = try await workspace.file.listShares(offset: 0, limit: 1)
                try requireCurrentConnectionAttempt(attemptID)
                applyWorkspaceRepositories(workspace)
                self.capabilities = connection.capabilities
                self.session = session
                activeConnectionProfile = connection.profile
                activeProfile = profile
                restoreNavigationState(for: profile.id)
                isConnected = true
                finishConnectionAttempt(attemptID)
                await loadSelectedModule()
            } catch is CancellationError {
                finishConnectionAttempt(attemptID)
            } catch let error as DsmCertificateTrustError {
                guard connectionAttemptID == attemptID else { return }
                certificateRetryContext = .restore(
                    profile: profile,
                    fallbackToPassword: fallbackToPassword
                )
                pendingCertificate = MobileCertificatePrompt(
                    error: error,
                    previousFingerprint: profile.pinnedCertificateSHA256
                )
                loginError = nil
                finishConnectionAttempt(attemptID)
            } catch {
                guard connectionAttemptID == attemptID else { return }
                let appError = error as? AppError
                let invalidSession = appError?.category == .authenticationRequired
                    || appError?.category == .otpRequired
                if invalidSession {
                    try? await sessionStore.remove(for: profile.id)
                    do {
                        try requireCurrentConnectionAttempt(attemptID)
                    } catch {
                        finishConnectionAttempt(attemptID)
                        return
                    }
                    finishConnectionAttempt(attemptID)
                    applyProfile(profile)
                    await loadSavedPassword(for: profile, attemptsAutoLogin: false)
                    if fallbackToPassword && autoLoginEnabled && !password.isEmpty {
                        connect()
                    } else {
                        loginError = password.isEmpty
                            ? L10n.string("ui.5a05e9e1ddd2c79b")
                            : L10n.string("ui.c57ce687fd05d636")
                    }
                } else {
                    loginError = userMessage(error)
                    finishConnectionAttempt(attemptID)
                }
            }
        }
    }

    func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionAttemptID = nil
        isConnecting = false
        connectionStatus = nil
        loginError = nil
    }

    func acceptPendingCertificate() {
        guard let prompt = pendingCertificate,
              prompt.allowsPinning,
              let retryContext = certificateRetryContext else {
            return
        }

        let profile: NasProfile
        switch retryContext {
        case .connect(let submission):
            profile = submission.profile
        case .restore(let savedProfile, _):
            profile = savedProfile
        }

        do {
            let updated = try profile.updating(
                pinnedCertificateSHA256: prompt.review.sha256Fingerprint
            )
            saveProfile(updated)
            pendingCertificate = nil
            certificateRetryContext = nil

            switch retryContext {
            case .connect(let submission):
                connect(submission: submission.updating(profile: updated))
            case .restore(_, let fallbackToPassword):
                restore(updated, fallbackToPassword: fallbackToPassword)
            }
        } catch {
            loginError = userMessage(error)
        }
    }

    func cancelCertificateReview() {
        pendingCertificate = nil
        certificateRetryContext = nil
        loginError = nil
    }

    private func finishConnectionAttempt(_ attemptID: UUID) {
        guard connectionAttemptID == attemptID else { return }
        connectionTask = nil
        connectionAttemptID = nil
        isConnecting = false
        connectionStatus = nil
    }

    private func requireCurrentConnectionAttempt(_ attemptID: UUID) throws {
        try Task.checkCancellation()
        guard connectionAttemptID == attemptID else {
            throw CancellationError()
        }
    }

    private typealias WorkspaceRepositories = (
        file: DsmFileRepository,
        service: DsmServiceManagementRepository,
        chat: DsmChatRepository,
        nas: DsmNasAdministrationRepository
    )

    private func makeWorkspaceRepositories(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) throws -> WorkspaceRepositories {
        (
            file: try DsmFileRepository(profile: profile, capabilities: capabilities, session: session),
            service: try DsmServiceManagementRepository(profile: profile, capabilities: capabilities, session: session),
            chat: try DsmChatRepository(profile: profile, capabilities: capabilities, session: session),
            nas: try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities, session: session)
        )
    }

    private func applyWorkspaceRepositories(_ repositories: WorkspaceRepositories) {
        fileRepository = repositories.file
        photoRepository = FileStationPhotoRepository(files: repositories.file)
        serviceRepository = repositories.service
        chatRepository = repositories.chat
        nasRepository = repositories.nas
    }

    func logout() {
        guard let profile = activeProfile else { return }
        let profileID = profile.id
        saveNavigationState()
        let connectionProfile = activeConnectionProfile ?? profile
        let capabilities = capabilities
        let session = session
        autoLoginEnabled = false
        defaults.set(false, forKey: autoLoginKeyPrefix + profileID.uuidString)
        Task {
            if let capabilities, let session {
                try? await authRepository.logout(
                    profile: connectionProfile,
                    capabilities: capabilities,
                    session: session
                )
            }
            try? await sessionStore.remove(for: profileID)
        }
        chatModel.purge(profileID: profileID)
        purgeFileLocations(profileID: profileID)
        Task { await photoLibraryModel.purge(profileID: profileID) }
        nasHealthModel.purge(profileID: profileID)
        containerInventoryModel.purge(profileID: profileID)
        virtualMachineInventoryModel.purge(profileID: profileID)
        clearWorkspace()
    }


    func makeProfile() throws -> NasProfile {
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
        let selectedProfile = profiles.first { $0.id == selectedProfileID }
        let connectionChanged = selectedProfile.map {
            $0.host != parsedAddress.host || $0.portOverride != portOverride
        } ?? false
        return try NasProfile(
            id: selectedProfileID ?? UUID(),
            displayName: displayName,
            host: parsedAddress.host,
            port: effectivePort,
            portOverride: portOverride,
            usernameHint: username,
            pinnedCertificateSHA256: connectionChanged
                ? nil
                : selectedProfile?.pinnedCertificateSHA256,
            lastDsmBuild: selectedProfile?.lastDsmBuild
        )
    }

    func discoverConnection(for profile: NasProfile) async throws -> DiscoveredConnection {
        try Task.checkCancellation()
        let parsedAddress = try NasAddressParser.parse(profile.host, defaultPort: profile.port)
        guard parsedAddress.kind == .quickConnect else {
            return DiscoveredConnection(
                profile: profile,
                capabilities: try await authRepository.discover(profile: profile)
            )
        }

        connectionStatus = L10n.string("ui.aa0582cad267718e")
        let endpoints: [QuickConnectEndpoint]
        do {
            endpoints = try await quickConnectResolver.resolve(id: parsedAddress.host)
        } catch let error as QuickConnectResolutionError where error == .noDirectRoute {
            // 未找到直连地址时仍可尝试中继；此阶段不会发送账号或密码。
            endpoints = []
        }
        try Task.checkCancellation()

        for endpoint in endpoints {
            try Task.checkCancellation()
            connectionStatus = endpoint.kind == .local
                ? L10n.string("ui.3b38866d76d21239")
                : L10n.string("ui.307e0c332a164ea1")
            let endpointPort = profile.portOverride ?? endpoint.port
            let connectionProfile = try profile.updating(host: endpoint.host, port: endpointPort)
            do {
                return DiscoveredConnection(
                    profile: connectionProfile,
                    capabilities: try await authRepository.discover(profile: connectionProfile)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 只做能力发现，当前地址不可用时继续尝试，登录信息尚未发送。
                continue
            }
        }

        connectionStatus = L10n.string("ui.85e5d30ce27fc0e5")
        let relay = try await quickConnectResolver.requestRelay(id: parsedAddress.host)
        try Task.checkCancellation()
        let relayProfile = try profile.updating(
            host: relay.host,
            port: relay.port,
            clearCertificatePin: true
        )
        return DiscoveredConnection(
            profile: relayProfile,
            capabilities: try await authRepository.discover(profile: relayProfile)
        )
    }

    func saveProfile(_ profile: NasProfile) {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        profiles.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        selectedProfileID = profile.id
        persistProfiles()
    }

    func loadSavedPassword(for profile: NasProfile, attemptsAutoLogin: Bool) async {
        do {
            let storedPassword = try await passwordStore.load(for: profile.id)
            guard selectedProfileID == profile.id else { return }
            password = storedPassword ?? ""
            rememberPassword = storedPassword != nil
            autoLoginEnabled = defaults.bool(forKey: autoLoginKeyPrefix + profile.id.uuidString)
            if storedPassword == nil && autoLoginEnabled {
                autoLoginEnabled = false
                defaults.set(false, forKey: autoLoginKeyPrefix + profile.id.uuidString)
            }
            if attemptsAutoLogin && autoLoginEnabled && storedPassword != nil {
                restore(profile, fallbackToPassword: true)
            }
        } catch {
            guard selectedProfileID == profile.id else { return }
            password = ""
            rememberPassword = false
            autoLoginEnabled = false
            defaults.set(false, forKey: autoLoginKeyPrefix + profile.id.uuidString)
            loginError = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("ui.74ef3d57d3207959")
        }
    }

    func loadProfiles() {
        guard let data = defaults.data(forKey: profileKey),
              let saved = try? JSONDecoder().decode([NasProfile].self, from: data) else {
            return
        }
        profiles = saved
    }

    func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profileKey)
    }

    func clearWorkspace() {
        cancelSelectedModuleLoad()
        fileShareLinkModel.deactivate()
        deactivateFileLocations()
        deactivateDownloads()
        photoLibraryModel.deactivate()
        chatModel.deactivate()
        nasHealthModel.deactivate()
        containerInventoryModel.deactivate()
        virtualMachineInventoryModel.deactivate()
        documentTransferController.resetForDisconnectedWorkspace()
        isConnected = false
        activeProfile = nil
        activeConnectionProfile = nil
        capabilities = nil
        session = nil
        fileRepository = nil
        photoRepository = nil
        serviceRepository = nil
        chatRepository = nil
        nasRepository = nil
        currentPath = ""
        pathHistory = []
        files = []
        downloadSnapshot = nil
        conversations = []
        systemOverview = nil
        storageSnapshot = nil
        packages = []
        accountsAndGroups = nil
        logs = nil
        connections = nil
    }

    func userMessage(_ error: Error) -> String {
        (error as? AppError)?.safeUserMessage
            ?? (error as? LocalizedError)?.errorDescription
            ?? L10n.string("ui.0c94990463093268")
    }
}
