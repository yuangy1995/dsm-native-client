import DsmCore
import Foundation
import DsmLocalization

/// DSM 的 NAS 管理内部接口适配器。所有写操作都先执行能力与可行性检查。
public actor DsmNasAdministrationRepository: NasSettingsRepository {
    private let profileName: String
    let currentUsername: String?
    let capabilities: CapabilitySet
    let credential: DsmSessionCredential
    let client: DsmAPIClient
    let transport: any DsmHTTPTransport
    private let isConnectedThroughQuickConnectRelay: Bool
    var packageControlMetadata: [String: PackageControlMetadata] = [:]
    var packageIconCache: [String: Data] = [:]
    private var activePackageMutationIDs: Set<String> = []
    private var activeAccountDeletionNames: Set<String> = []
    private var activeGroupDeletionNames: Set<String> = []
    private var activeEthernetUpdateIDs: Set<String> = []
    private var isFileServiceSettingsUpdateActive = false
    private var isTerminalSettingsUpdateActive = false
    private var isProxySettingsUpdateActive = false
    private var isSecuritySettingsUpdateActive = false
    private var isHardwareSettingsUpdateActive = false
    private var isRemoteAccessSettingsUpdateActive = false
    private var isRegionSettingsUpdateActive = false
    private var activeDDNSProviderIDs: Set<String> = []
    private var isDDNSRefreshActive = false
    var isPowerActionActive = false
    private var activeDiskTestIDs: Set<String> = []
    var storageDisks: [String: NasDisk] = [:]
    private var diskTestHistories: [String: DiskTestHistorySnapshot] = [:]
    private var beepVolumeFieldName: String?

    private enum SecuritySettingsMutationStep: Sendable {
        case autoBlock
        case denialOfService
        case portScanProtection
        case firewall
    }

    private enum HardwareSettingsMutationStep: Sendable {
        case powerRecovery
        case ledBrightness
        case fanMode
        case beep
        case hibernation
        case ups
    }

    private enum RemoteAccessSettingsMutationStep: Sendable {
        case relay
        case routerConfiguration
    }

    private enum FileServiceSettingsMutationStep: Sendable {
        case smb
        case nfs
        case ftp
        case sftp
        case webDiscovery
        case fileDiscovery
    }

    private enum TerminalSettingsMutationStep: Sendable {
        case ssh
        case telnet
        case sshPort
    }

    private enum ProxySettingsMutationStep: Sendable {
        case enabled
        case host
        case port
    }

    private enum RegionSettingsMutationStep: Sendable {
        case dateFormat
        case timeFormat
        case timeZone
        case mode
        case servers
        case manualDate
        case synchronize
    }

    public init(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        transport: (any DsmHTTPTransport)? = nil
    ) throws {
        let resolvedTransport = transport ?? URLSessionTransport(
            expectedHost: profile.host,
            pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
            requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        )
        profileName = profile.displayName
        currentUsername = profile.usernameHint
        isConnectedThroughQuickConnectRelay =
            DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        self.capabilities = capabilities
        credential = DsmSessionCredential(sid: session.sid, synoToken: session.synoToken)
        self.transport = resolvedTransport
        client = DsmAPIClient(
            baseURL: try DsmEndpoint.baseURL(for: profile),
            transport: resolvedTransport
        )
    }

    public func loadSystemOverview() async throws -> NasSystemOverview {
        let value = try await call(DsmAPIName.coreSystem, method: "info")
        let coreCount = value.string(["cpu_cores"]).flatMap(Int.init)
            ?? value.number(["cpu_cores"]).map(Int.init)
        let rawMemory = value.integer(["ram_size"])
        let temperatureWarning = value.boolean([
            "temperature_warning",
            "sys_tempwarn",
            "systempwarn"
        ]) ?? false

        return NasSystemOverview(
            serverName: profileName,
            model: value.string(["model"]),
            version: value.string(["firmware_ver"]),
            uptimeSeconds: Self.uptimeSeconds(from: value.string(["up_time"])),
            cpuModel: value.string(["cpu_series", "cpu_family"]),
            cpuCoreCount: coreCount,
            cpuClockMHz: value.number(["cpu_clock_speed"]).map(Int.init),
            memoryBytes: rawMemory.map(Self.memoryBytes),
            temperatureCelsius: value.number(["sys_temp"]),
            hasTemperatureWarning: temperatureWarning
        )
    }

    public func saveFileServiceSettings(_ settings: NasFileServiceSettings) async throws {
        let result = try await saveFileServiceSettingsResult(settings)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw fileServiceSettingsError(for: result)
        }
    }

    /// 文件服务设置跨越多个内部接口；先完整预检，再逐项提交并整体回读。
    public func saveFileServiceSettingsResult(
        _ settings: NasFileServiceSettings
    ) async throws -> MutationResult {
        let operation = "fileServiceSettingsUpdate"
        let prefix = "file-services.settings"
        if Task.isCancelled {
            return try fileServiceMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !isFileServiceSettingsUpdateActive else {
            return try fileServiceMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isFileServiceSettingsUpdateActive = true
        defer { isFileServiceSettingsUpdateActive = false }

        let current: NasFileServiceSettings
        do {
            current = try await loadFileServiceSettings()
        } catch let error as AppError {
            return try fileServicePreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try fileServiceMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        do {
            try validateFileServiceSettings(settings, current: current)
        } catch {
            return try fileServiceMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).invalid",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        let steps = Self.fileServiceMutationSteps(from: current, to: settings)
        guard !steps.isEmpty else {
            return try fileServiceMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        guard fileServiceCapabilitiesSupport(steps) else {
            return try fileServiceMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: steps.count,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        if Task.isCancelled {
            return try fileServiceMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var acceptedCount = 0
        for step in steps {
            if Task.isCancelled {
                if acceptedCount == 0 {
                    return try fileServiceMutationResult(
                        status: .cancelledBeforeSubmission,
                        operation: operation,
                        submitted: false,
                        requiresRefresh: false,
                        succeeded: 0,
                        failed: 0,
                        unknown: 0,
                        diagnosticTag: "\(prefix).cancelled-before-first-submission"
                    )
                }
                return try fileServiceMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - acceptedCount,
                    unknown: acceptedCount,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).cancelled-after-submission"
                )
            }
            do {
                try await submitFileServiceMutationStep(
                    step,
                    settings: settings
                )
                acceptedCount += 1
            } catch let error as AppError {
                return try await fileServiceSubmissionFailureResult(
                    error,
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            } catch {
                return try await fileServiceUnknownSubmissionResult(
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            }
        }

        if Task.isCancelled {
            return try fileServiceMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }
        do {
            let verified = try await loadFileServiceSettings()
            return try fileServiceVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch let error as AppError {
            return try fileServiceMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try fileServiceMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private func validateFileServiceSettings(
        _ settings: NasFileServiceSettings,
        current: NasFileServiceSettings
    ) throws {
        if let port = settings.ftpPort {
            try Self.validatePort(port)
        }
        if let port = settings.sftpPort {
            try Self.validatePort(port)
        }
        let smbEnabled = settings.isSMBEnabled ?? current.isSMBEnabled
        let timeMachineEnabled =
            settings.isSMBTimeMachineEnabled ?? current.isSMBTimeMachineEnabled
        guard timeMachineEnabled != true || smbEnabled != false else {
            throw verificationError(
                L10n.string("file-services.settings.invalid")
            )
        }
        let ftpEnabled =
            settings.isFTPEnabled ?? current.isFTPEnabled ?? false
        let ftpsEnabled =
            settings.isFTPSEnabled ?? current.isFTPSEnabled ?? false
        let sftpEnabled =
            settings.isSFTPEnabled ?? current.isSFTPEnabled ?? false
        let ftpPort = settings.ftpPort ?? current.ftpPort
        let sftpPort = settings.sftpPort ?? current.sftpPort
        guard !(ftpEnabled || ftpsEnabled)
                || !sftpEnabled
                || ftpPort == nil
                || sftpPort == nil
                || ftpPort != sftpPort else {
            throw verificationError(
                L10n.string("file-services.settings.invalid")
            )
        }
    }

    private static func fileServiceMutationSteps(
        from current: NasFileServiceSettings,
        to expected: NasFileServiceSettings
    ) -> [FileServiceSettingsMutationStep] {
        var steps: [FileServiceSettingsMutationStep] = []
        if expected.isSMBEnabled != nil,
           expected.isSMBEnabled != current.isSMBEnabled {
            steps.append(.smb)
        }
        if expected.isNFSEnabled != nil,
           expected.isNFSEnabled != current.isNFSEnabled {
            steps.append(.nfs)
        }
        if (expected.isFTPEnabled != nil
                && expected.isFTPEnabled != current.isFTPEnabled)
            || (expected.isFTPSEnabled != nil
                && expected.isFTPSEnabled != current.isFTPSEnabled)
            || (expected.ftpPort != nil
                && expected.ftpPort != current.ftpPort) {
            steps.append(.ftp)
        }
        if (expected.isSFTPEnabled != nil
                && expected.isSFTPEnabled != current.isSFTPEnabled)
            || (expected.sftpPort != nil
                && expected.sftpPort != current.sftpPort) {
            steps.append(.sftp)
        }
        if (expected.isSSDPEnabled != nil
                && expected.isSSDPEnabled != current.isSSDPEnabled)
            || (expected.isBonjourEnabled != nil
                && expected.isBonjourEnabled != current.isBonjourEnabled) {
            steps.append(.webDiscovery)
        }
        if expected.isSMBTimeMachineEnabled != nil,
           expected.isSMBTimeMachineEnabled
                != current.isSMBTimeMachineEnabled {
            steps.append(.fileDiscovery)
        }
        return steps
    }

    private func fileServiceCapabilitiesSupport(
        _ steps: [FileServiceSettingsMutationStep]
    ) -> Bool {
        steps.allSatisfy { step in
            switch step {
            case .smb:
                capabilitySupports(DsmAPIName.coreFileServiceSMB)
            case .nfs:
                capabilitySupports(DsmAPIName.coreFileServiceNFS)
            case .ftp:
                capabilitySupports(DsmAPIName.coreFileServiceFTP)
            case .sftp:
                capabilitySupports(DsmAPIName.coreFileServiceSFTP)
            case .webDiscovery:
                capabilitySupports(DsmAPIName.coreWebDSM, version: 2)
            case .fileDiscovery:
                capabilitySupports(DsmAPIName.coreFileServiceDiscovery)
            }
        }
    }

    private func submitFileServiceMutationStep(
        _ step: FileServiceSettingsMutationStep,
        settings: NasFileServiceSettings
    ) async throws {
        switch step {
        case .smb:
            guard let enabled = settings.isSMBEnabled else {
                throw verificationError(
                    L10n.string("file-services.settings.failed")
                )
            }
            try await callVoid(
                DsmAPIName.coreFileServiceSMB,
                method: "set",
                parameters: ["enable_samba": .boolean(enabled)]
            )
        case .nfs:
            guard let enabled = settings.isNFSEnabled else {
                throw verificationError(
                    L10n.string("file-services.settings.failed")
                )
            }
            try await callVoid(
                DsmAPIName.coreFileServiceNFS,
                method: "set",
                parameters: ["enable_nfs": .boolean(enabled)]
            )
        case .ftp:
            try await callVoid(
                DsmAPIName.coreFileServiceFTP,
                method: "set",
                parameters: Self.fileServiceFTPParameters(
                    settings
                )
            )
        case .sftp:
            try await callVoid(
                DsmAPIName.coreFileServiceSFTP,
                method: "set",
                parameters: Self.fileServiceSFTPParameters(
                    settings
                )
            )
        case .webDiscovery:
            try await callVoid(
                DsmAPIName.coreWebDSM,
                method: "set",
                version: 2,
                parameters: Self.fileServiceWebDiscoveryParameters(
                    settings
                )
            )
        case .fileDiscovery:
            guard let enabled = settings.isSMBTimeMachineEnabled else {
                throw verificationError(
                    L10n.string("file-services.settings.failed")
                )
            }
            try await callVoid(
                DsmAPIName.coreFileServiceDiscovery,
                method: "set",
                parameters: ["enable_smb_time_machine": .boolean(enabled)]
            )
        }
    }

    private static func fileServiceFTPParameters(
        _ settings: NasFileServiceSettings
    ) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [:]
        if let enabled = settings.isFTPEnabled {
            parameters["enable_ftp"] = .boolean(enabled)
        }
        if let enabled = settings.isFTPSEnabled {
            parameters["enable_ftps"] = .boolean(enabled)
        }
        if let port = settings.ftpPort {
            parameters["portnum"] = .integer(port)
        }
        return parameters
    }

    private static func fileServiceSFTPParameters(
        _ settings: NasFileServiceSettings
    ) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [:]
        if let enabled = settings.isSFTPEnabled {
            parameters["enable"] = .boolean(enabled)
        }
        if let port = settings.sftpPort {
            parameters["portnum"] = .integer(port)
        }
        return parameters
    }

    private static func fileServiceWebDiscoveryParameters(
        _ settings: NasFileServiceSettings
    ) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [:]
        if let enabled = settings.isSSDPEnabled {
            parameters["enable_ssdp"] = .boolean(enabled)
        }
        if let enabled = settings.isBonjourEnabled {
            parameters["enable_avahi"] = .boolean(enabled)
        }
        return parameters
    }

    private func fileServiceSubmissionFailureResult(
        _ submissionError: AppError,
        settings: NasFileServiceSettings,
        steps: [FileServiceSettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        let isAmbiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        if submissionError.category == .cancelled {
            return try fileServiceMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: max(0, steps.count - acceptedCount - 1),
                unknown: min(steps.count, acceptedCount + 1),
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        do {
            let verified = try await loadFileServiceSettings()
            return try fileServiceVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: submissionError.category,
                uncertainCount: isAmbiguous
                    ? min(steps.count, acceptedCount + 1)
                    : acceptedCount
            )
        } catch {
            if acceptedCount > 0 || isAmbiguous {
                let unknown = min(
                    steps.count,
                    acceptedCount + (isAmbiguous ? 1 : 0)
                )
                return try fileServiceMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - unknown,
                    unknown: unknown,
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).partial-readback-unverified"
                )
            }
            return try fileServiceRejectedResult(
                submissionError,
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
    }

    private func fileServiceUnknownSubmissionResult(
        settings: NasFileServiceSettings,
        steps: [FileServiceSettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadFileServiceSettings()
            return try fileServiceVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown,
                uncertainCount: min(steps.count, acceptedCount + 1)
            )
        } catch {
            let unknown = min(steps.count, acceptedCount + 1)
            return try fileServiceMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: steps.count - unknown,
                unknown: unknown,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func fileServiceVerifiedResult(
        _ actual: NasFileServiceSettings,
        expected: NasFileServiceSettings,
        steps: [FileServiceSettingsMutationStep],
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil,
        uncertainCount: Int = 0
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.fileServiceMutationStep($0, matches: actual, expected: expected)
        }.count
        let remaining = steps.count - succeeded
        if succeeded == steps.count {
            return try fileServiceMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        let unknown = min(remaining, max(0, uncertainCount - succeeded))
        if succeeded > 0 {
            return try fileServiceMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if unknown > 0 {
            return try fileServiceMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                },
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unchanged"
            )
        }
        if let failureCategory {
            return try fileServiceRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string(
                        "file-services.settings.failed"
                    )
                ),
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
        return try fileServiceMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: remaining,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func fileServiceRejectedResult(
        _ error: AppError,
        totalCount: Int,
        submitted: Bool,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try fileServiceMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func fileServicePreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try fileServiceMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        }
        return try fileServiceRejectedResult(
            error,
            totalCount: 1,
            submitted: false,
            operation: operation,
            prefix: prefix
        )
    }

    private static func fileServiceMutationStep(
        _ step: FileServiceSettingsMutationStep,
        matches actual: NasFileServiceSettings,
        expected: NasFileServiceSettings
    ) -> Bool {
        switch step {
        case .smb:
            actual.isSMBEnabled == expected.isSMBEnabled
        case .nfs:
            actual.isNFSEnabled == expected.isNFSEnabled
        case .ftp:
            (expected.isFTPEnabled == nil
                || actual.isFTPEnabled == expected.isFTPEnabled)
                && (expected.isFTPSEnabled == nil
                    || actual.isFTPSEnabled == expected.isFTPSEnabled)
                && (expected.ftpPort == nil
                    || actual.ftpPort == expected.ftpPort)
        case .sftp:
            (expected.isSFTPEnabled == nil
                || actual.isSFTPEnabled == expected.isSFTPEnabled)
                && (expected.sftpPort == nil
                    || actual.sftpPort == expected.sftpPort)
        case .webDiscovery:
            (expected.isSSDPEnabled == nil
                || actual.isSSDPEnabled == expected.isSSDPEnabled)
                && (expected.isBonjourEnabled == nil
                    || actual.isBonjourEnabled == expected.isBonjourEnabled)
        case .fileDiscovery:
            actual.isSMBTimeMachineEnabled
                == expected.isSMBTimeMachineEnabled
        }
    }

    private func fileServiceMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func fileServiceSettingsError(for result: MutationResult) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? "file-services.settings.failed"
            )
        )
    }

    public func saveTerminalSettings(_ settings: NasTerminalSettings) async throws {
        let result = try await saveTerminalSettingsResult(settings)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw terminalSettingsError(for: result)
        }
    }

    /// 远程终端设置按实际变化字段回读；提交后的未知结果不得自动重放。
    public func saveTerminalSettingsResult(
        _ settings: NasTerminalSettings
    ) async throws -> MutationResult {
        let operation = "terminalSettingsUpdate"
        let prefix = "terminal.settings"
        if Task.isCancelled {
            return try terminalMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !isTerminalSettingsUpdateActive else {
            return try terminalMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isTerminalSettingsUpdateActive = true
        defer { isTerminalSettingsUpdateActive = false }

        do {
            if let port = settings.sshPort {
                try Self.validatePort(port)
            }
        } catch {
            return try terminalMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).invalid",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        guard capabilitySupports(DsmAPIName.coreTerminal) else {
            return try terminalMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }

        let current: NasTerminalSettings
        do {
            current = try await loadTerminalSettings()
        } catch let error as AppError {
            return try terminalPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try terminalMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        let steps = Self.terminalMutationSteps(from: current, to: settings)
        guard !steps.isEmpty else {
            return try terminalMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        if Task.isCancelled {
            return try terminalMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var parameters: [String: DsmParameterValue] = [
            "enable_ssh": .boolean(settings.isSSHEnabled),
            "enable_telnet": .boolean(settings.isTelnetEnabled)
        ]
        if let port = settings.sshPort {
            parameters["ssh_port"] = .integer(port)
        }
        do {
            try await callVoid(
                DsmAPIName.coreTerminal,
                method: "set",
                parameters: parameters
            )
        } catch let error as AppError {
            return try await terminalSubmissionFailureResult(
                error,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try await terminalUnknownSubmissionResult(
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        }

        if Task.isCancelled {
            return try terminalMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }
        do {
            let verified = try await loadTerminalSettings()
            return try terminalVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch let error as AppError {
            return try terminalMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try terminalMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private static func terminalMutationSteps(
        from current: NasTerminalSettings,
        to expected: NasTerminalSettings
    ) -> [TerminalSettingsMutationStep] {
        var steps: [TerminalSettingsMutationStep] = []
        if current.isSSHEnabled != expected.isSSHEnabled {
            steps.append(.ssh)
        }
        if current.isTelnetEnabled != expected.isTelnetEnabled {
            steps.append(.telnet)
        }
        if expected.sshPort != nil, current.sshPort != expected.sshPort {
            steps.append(.sshPort)
        }
        return steps
    }

    private func terminalSubmissionFailureResult(
        _ submissionError: AppError,
        expected: NasTerminalSettings,
        steps: [TerminalSettingsMutationStep],
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled {
            return try terminalMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        let isAmbiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        do {
            let verified = try await loadTerminalSettings()
            return try terminalVerifiedResult(
                verified,
                expected: expected,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: submissionError.category,
                treatsMismatchAsUnknown: isAmbiguous
            )
        } catch {
            if isAmbiguous {
                return try terminalMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: steps.count,
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).readback-unverified"
                )
            }
            return try terminalRejectedResult(
                submissionError,
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
    }

    private func terminalUnknownSubmissionResult(
        expected: NasTerminalSettings,
        steps: [TerminalSettingsMutationStep],
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadTerminalSettings()
            return try terminalVerifiedResult(
                verified,
                expected: expected,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown,
                treatsMismatchAsUnknown: true
            )
        } catch {
            return try terminalMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func terminalVerifiedResult(
        _ actual: NasTerminalSettings,
        expected: NasTerminalSettings,
        steps: [TerminalSettingsMutationStep],
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil,
        treatsMismatchAsUnknown: Bool = false
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.terminalMutationStep($0, matches: actual, expected: expected)
        }.count
        let remaining = steps.count - succeeded
        if succeeded == steps.count {
            return try terminalMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        let unknown = treatsMismatchAsUnknown ? remaining : 0
        if succeeded > 0 {
            return try terminalMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if unknown > 0 {
            return try terminalMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: unknown,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                },
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unchanged"
            )
        }
        if let failureCategory {
            return try terminalRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string("terminal.settings.failed")
                ),
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
        return try terminalMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: remaining,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func terminalRejectedResult(
        _ error: AppError,
        totalCount: Int,
        submitted: Bool,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try terminalMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func terminalPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try terminalMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        }
        return try terminalRejectedResult(
            error,
            totalCount: 1,
            submitted: false,
            operation: operation,
            prefix: prefix
        )
    }

    private static func terminalMutationStep(
        _ step: TerminalSettingsMutationStep,
        matches actual: NasTerminalSettings,
        expected: NasTerminalSettings
    ) -> Bool {
        switch step {
        case .ssh:
            actual.isSSHEnabled == expected.isSSHEnabled
        case .telnet:
            actual.isTelnetEnabled == expected.isTelnetEnabled
        case .sshPort:
            actual.sshPort == expected.sshPort
        }
    }

    private func terminalMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func terminalSettingsError(for result: MutationResult) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? "terminal.settings.failed"
            )
        )
    }

    public func saveProxySettings(_ settings: NasProxySettings) async throws {
        let result = try await saveProxySettingsResult(settings)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw proxySettingsError(for: result)
        }
    }

    /// 代理设置按实际变化字段回读；提交后的未知结果不得自动重放。
    public func saveProxySettingsResult(
        _ settings: NasProxySettings
    ) async throws -> MutationResult {
        let operation = "proxySettingsUpdate"
        let prefix = "proxy.settings"
        if Task.isCancelled {
            return try proxyMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !isProxySettingsUpdateActive else {
            return try proxyMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isProxySettingsUpdateActive = true
        defer { isProxySettingsUpdateActive = false }

        guard settings.isValidForSaving else {
            return try proxyMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).invalid",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        guard capabilitySupports(DsmAPIName.coreNetworkProxy) else {
            return try proxyMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }

        let normalized = NasProxySettings(
            isEnabled: settings.isEnabled,
            host: settings.normalizedHost,
            port: settings.port
        )
        let current: NasProxySettings
        do {
            current = try await loadProxySettings()
        } catch let error as AppError {
            return try proxyPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try proxyMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        let steps = Self.proxyMutationSteps(from: current, to: normalized)
        guard !steps.isEmpty else {
            return try proxyMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        if Task.isCancelled {
            return try proxyMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var parameters: [String: DsmParameterValue] = [
            "enable": .boolean(normalized.isEnabled)
        ]
        if normalized.isEnabled, let port = normalized.port {
            parameters["http_host"] = .string(normalized.host)
            parameters["http_port"] = .integer(port)
        }
        do {
            try await callVoid(
                DsmAPIName.coreNetworkProxy,
                method: "set",
                parameters: parameters
            )
        } catch let error as AppError {
            return try await proxySubmissionFailureResult(
                error,
                expected: normalized,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try await proxyUnknownSubmissionResult(
                expected: normalized,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        }

        if Task.isCancelled {
            return try proxyMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }
        do {
            let verified = try await loadProxySettings()
            return try proxyVerifiedResult(
                verified,
                expected: normalized,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch let error as AppError {
            return try proxyMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try proxyMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private static func proxyMutationSteps(
        from current: NasProxySettings,
        to expected: NasProxySettings
    ) -> [ProxySettingsMutationStep] {
        var steps: [ProxySettingsMutationStep] = []
        if current.isEnabled != expected.isEnabled {
            steps.append(.enabled)
        }
        if expected.isEnabled {
            if current.host != expected.host {
                steps.append(.host)
            }
            if current.port != expected.port {
                steps.append(.port)
            }
        }
        return steps
    }

    private func proxySubmissionFailureResult(
        _ submissionError: AppError,
        expected: NasProxySettings,
        steps: [ProxySettingsMutationStep],
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled {
            return try proxyMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        let isAmbiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        do {
            let verified = try await loadProxySettings()
            return try proxyVerifiedResult(
                verified,
                expected: expected,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: submissionError.category,
                treatsMismatchAsUnknown: isAmbiguous
            )
        } catch {
            if isAmbiguous {
                return try proxyMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: steps.count,
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).readback-unverified"
                )
            }
            return try proxyRejectedResult(
                submissionError,
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
    }

    private func proxyUnknownSubmissionResult(
        expected: NasProxySettings,
        steps: [ProxySettingsMutationStep],
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadProxySettings()
            return try proxyVerifiedResult(
                verified,
                expected: expected,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown,
                treatsMismatchAsUnknown: true
            )
        } catch {
            return try proxyMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func proxyVerifiedResult(
        _ actual: NasProxySettings,
        expected: NasProxySettings,
        steps: [ProxySettingsMutationStep],
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil,
        treatsMismatchAsUnknown: Bool = false
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.proxyMutationStep($0, matches: actual, expected: expected)
        }.count
        let remaining = steps.count - succeeded
        if succeeded == steps.count {
            return try proxyMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        let unknown = treatsMismatchAsUnknown ? remaining : 0
        if succeeded > 0 {
            return try proxyMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if unknown > 0 {
            return try proxyMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: unknown,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                },
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unchanged"
            )
        }
        if let failureCategory {
            return try proxyRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string("proxy.settings.failed")
                ),
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
        return try proxyMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: remaining,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func proxyRejectedResult(
        _ error: AppError,
        totalCount: Int,
        submitted: Bool,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try proxyMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func proxyPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try proxyMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        }
        return try proxyRejectedResult(
            error,
            totalCount: 1,
            submitted: false,
            operation: operation,
            prefix: prefix
        )
    }

    private static func proxyMutationStep(
        _ step: ProxySettingsMutationStep,
        matches actual: NasProxySettings,
        expected: NasProxySettings
    ) -> Bool {
        switch step {
        case .enabled:
            actual.isEnabled == expected.isEnabled
        case .host:
            actual.host == expected.host
        case .port:
            actual.port == expected.port
        }
    }

    private func proxyMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func proxySettingsError(for result: MutationResult) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? "proxy.settings.failed"
            )
        )
    }

    public func saveEthernetInterface(_ interface: NasEthernetInterface) async throws {
        try Self.validateEthernetInterface(interface)
        let current = try await loadEthernetInterfaces()
        guard let existing = current.first(where: { $0.id == interface.id }) else {
            throw verificationError(L10n.string("shared.f0a75be9d773f2a6"))
        }
        guard existing != interface else { return }
        try await callVoid(
            DsmAPIName.coreNetworkEthernet,
            method: "set",
            version: 1,
            parameters: [
                "configs": .objectArray([
                    Self.ethernetConfiguration(interface)
                ])
            ]
        )
        let verifiedValue = try await call(
            DsmAPIName.coreNetworkEthernet,
            method: "get",
            version: 1,
            parameters: ["ifname": .string(interface.id)]
        )
        guard let verified = Self.ethernetInterface(
            from: verifiedValue,
            fallback: [:],
            id: interface.id
        ), Self.ethernetInterface(verified, matches: interface) else {
            throw verificationError(L10n.string("shared.648300d4688b5c30"))
        }
    }

    /// 网卡配置可能在提交后中断当前连接；未知结果必须重新连接并回读，不得自动重放。
    public func saveEthernetInterfaceResult(
        _ interface: NasEthernetInterface
    ) async throws -> MutationResult {
        let operation = "ethernetUpdate"
        let prefix = "network.ethernet"
        if Task.isCancelled {
            return try ethernetMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }

        do {
            try Self.validateEthernetInterface(interface)
        } catch {
            return try ethernetMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        guard capabilities[DsmAPIName.coreNetworkEthernet]?.selectedVersion != nil else {
            return try ethernetMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        guard activeEthernetUpdateIDs.insert(interface.id).inserted else {
            return try ethernetMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        defer { activeEthernetUpdateIDs.remove(interface.id) }

        do {
            let current = try await loadEthernetInterfaces()
            guard let existing = current.first(where: { $0.id == interface.id }) else {
                return try ethernetMutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .conflict,
                    localizationKey: "\(prefix).failed",
                    diagnosticTag: "\(prefix).target-not-found"
                )
            }
            guard !Self.ethernetInterface(existing, matches: interface) else {
                return try ethernetMutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .validation,
                    localizationKey: "\(prefix).failed",
                    diagnosticTag: "\(prefix).no-changes"
                )
            }
        } catch let error as AppError {
            return try ethernetPreflightResult(error, operation: operation, prefix: prefix)
        } catch {
            return try ethernetMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }

        if Task.isCancelled {
            return try ethernetMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        do {
            try await callVoid(
                DsmAPIName.coreNetworkEthernet,
                method: "set",
                version: 1,
                parameters: [
                    "configs": .objectArray([
                        Self.ethernetConfiguration(interface)
                    ])
                ]
            )
        } catch let error as AppError {
            return try ethernetSubmissionResult(error, operation: operation, prefix: prefix)
        } catch {
            return try ethernetMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }

        if Task.isCancelled {
            return try ethernetMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-after-submission"
            )
        }

        do {
            let verifiedValue = try await call(
                DsmAPIName.coreNetworkEthernet,
                method: "get",
                version: 1,
                parameters: ["ifname": .string(interface.id)]
            )
            guard let verified = Self.ethernetInterface(
                from: verifiedValue,
                fallback: [:],
                id: interface.id
            ) else {
                return try ethernetMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    errorCategory: .server,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).readback-invalid"
                )
            }
            guard Self.ethernetInterface(verified, matches: interface) else {
                return try ethernetMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).readback-mismatch"
                )
            }
            return try ethernetMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        } catch let error as AppError {
            return try ethernetReadbackResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try ethernetMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    public func loadHardwareSettings() async throws -> NasHardwareSettings {
        let hasPowerRecovery =
            capabilities[DsmAPIName.coreHardwarePowerRecovery]?.selectedVersion != nil
        let hasLED =
            capabilities[DsmAPIName.coreHardwareLEDBrightness]?.selectedVersion != nil
        let hasFan = capabilities[DsmAPIName.coreHardwareFanSpeed]?.selectedVersion != nil
        let hasBeep = capabilities[DsmAPIName.coreHardwareBeepControl]?.selectedVersion != nil
        let hasHibernation =
            capabilities[DsmAPIName.coreHardwareHibernation]?.selectedVersion != nil
        let hasUPS = capabilities[DsmAPIName.coreExternalDeviceUPS]?.selectedVersion != nil
        guard hasPowerRecovery || hasLED || hasFan || hasBeep || hasHibernation || hasUPS else {
            throw unavailableError()
        }

        let power = hasPowerRecovery
            ? try await call(DsmAPIName.coreHardwarePowerRecovery, method: "get")
            : nil
        let led = hasLED
            ? try await call(DsmAPIName.coreHardwareLEDBrightness, method: "get")
            : nil
        let ledStatic = hasLED
            ? try await call(
                DsmAPIName.coreHardwareLEDBrightness,
                method: "get_static_data"
            )
            : nil
        let fan = hasFan
            ? try await call(DsmAPIName.coreHardwareFanSpeed, method: "get")
            : nil
        let beep = hasBeep
            ? try await call(DsmAPIName.coreHardwareBeepControl, method: "get")
            : nil
        let hibernation = hasHibernation
            ? try await call(DsmAPIName.coreHardwareHibernation, method: "get")
            : nil
        let ups = hasUPS
            ? try await call(DsmAPIName.coreExternalDeviceUPS, method: "get")
            : nil
        if beep?["volume_or_cache_crash"] != nil {
            beepVolumeFieldName = "volume_or_cache_crash"
        } else if beep?["volume_crash"] != nil {
            beepVolumeFieldName = "volume_crash"
        }
        let minimum = ledStatic?.number(["min"]).map(Int.init)
        let maximum = ledStatic?.number(["max"]).map(Int.init)
        let range = minimum.flatMap { minValue in
            maximum.flatMap { maxValue in
                minValue <= maxValue ? minValue...maxValue : nil
            }
        }
        return NasHardwareSettings(
            restartsAfterPowerFailure: power?.boolean(["rc_power_config"]),
            ledBrightness: led?.number(["led_brightness"]).map(Int.init),
            ledBrightnessRange: range,
            fanMode: fan?.string(["dual_fan_speed"]),
            isFanFailureAlertEnabled: beep?.boolean(["fan_fail"]),
            isVolumeFailureAlertEnabled: beep?.boolean([
                "volume_or_cache_crash",
                "volume_crash"
            ]),
            isPowerOnSoundEnabled: beep?.boolean(["poweron_beep"]),
            isPowerOffSoundEnabled: beep?.boolean(["poweroff_beep"]),
            isResetSoundEnabled: beep?.boolean(["reset_beep"]),
            isExternalDriveDeepSleepEnabled: hibernation?.boolean(["eunit_deep_sleep"]),
            isWakeUpLogEnabled: hibernation?.boolean(["enable_log"]),
            isSATASleepEnabled: hibernation?.boolean(["sata_deep_sleep"]),
            ignoresNetworkDiscoveryDuringSleep: hibernation?.boolean([
                "ignore_netbios_broadcast"
            ]),
            isAutomaticPowerOffEnabled: hibernation?.boolean(["auto_poweroff_enable"]),
            ups: Self.upsSettings(from: ups)
        )
    }

    public func loadPowerSchedule() async throws -> NasPowerScheduleSnapshot {
        let value = try await call(
            DsmAPIName.coreHardwarePowerSchedule,
            method: "load",
            version: 1
        )
        let primaryRows = value.objects("schedules")
        let rows = primaryRows.isEmpty ? value.objects("items") : primaryRows
        let maximumEntries = 128
        var seenIDs = Set<String>()
        let entries = rows.prefix(maximumEntries).enumerated().compactMap {
            index, raw -> NasPowerScheduleEntry? in
            let item = DsmDynamicJSON.object(raw)
            guard let hour = item.integer(["hour"]).flatMap({
                $0 >= 0 && $0 <= 23 ? Int($0) : nil
            }),
            let minute = item.integer(["minute"]).flatMap({
                $0 >= 0 && $0 <= 59 ? Int($0) : nil
            }) else {
                return nil
            }
            let serverID = Self.safePowerScheduleIdentifier(
                item.string(["id", "schedule_id"])
            )
            let id = serverID ?? "power-schedule-\(index)"
            guard seenIDs.insert(id).inserted else { return nil }
            return NasPowerScheduleEntry(
                id: id,
                action: Self.powerScheduleAction(
                    item.string(["action", "type", "operation"])
                ),
                isEnabled: item.boolean(["enabled", "is_enabled"]),
                hour: hour,
                minute: minute,
                recurrence: Self.powerScheduleRecurrence(item)
            )
        }
        let reportedTotal = value.integer(["total", "total_count"]).flatMap {
            $0 >= 0 && $0 <= 1_000_000 ? Int($0) : nil
        }
        let total = max(entries.count, reportedTotal ?? rows.count)
        return NasPowerScheduleSnapshot(
            entries: entries,
            timeZoneIdentifier: Self.safePowerScheduleTimeZone(
                value.string(["timezone", "time_zone"])
            ),
            total: total,
            isTruncated: rows.count > maximumEntries
                || (reportedTotal.map { $0 > rows.count } ?? false)
        )
    }

    public func loadExternalStorage() async throws -> NasExternalStorageDirectory {
        let maximumEntriesPerConnection = 64
        let supportedConnections: [(NasExternalStorageConnection, String)] = [
            (.usb, DsmAPIName.coreExternalStorageUSB),
            (.eSATA, DsmAPIName.coreExternalStorageESATA)
        ]
        guard supportedConnections.contains(where: {
            capabilitySupports($0.1, version: 1)
        }) else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("external-storage.unavailable")
            )
        }

        var devices: [NasExternalStorageDevice] = []
        var unavailableConnections: [NasExternalStorageConnection] = []
        var total = 0
        var isTruncated = false

        for (connection, apiName) in supportedConnections {
            guard capabilitySupports(apiName, version: 1) else {
                unavailableConnections.append(connection)
                continue
            }
            do {
                let value = try await call(apiName, method: "list", version: 1)
                let rows = Self.externalStorageRows(from: value, connection: connection)
                let reportedTotal = value.integer(["total", "total_count"]).flatMap {
                    $0 >= 0 && $0 <= 1_000_000 ? Int($0) : nil
                }
                total += max(rows.count, reportedTotal ?? rows.count)
                isTruncated = isTruncated
                    || rows.count > maximumEntriesPerConnection
                    || (reportedTotal.map { $0 > rows.count } ?? false)

                var seenIDs = Set<String>()
                let parsed = rows.prefix(maximumEntriesPerConnection).enumerated().compactMap {
                    index, raw -> NasExternalStorageDevice? in
                    let item = DsmDynamicJSON.object(raw)
                    let rawID = Self.safeExternalStorageIdentifier(
                        item.string(["id", "device_id", "storage_id"])
                    )
                    let localID = rawID ?? "snapshot-\(index)"
                    let id = "\(connection.rawValue):\(localID)"
                    guard seenIDs.insert(id).inserted else { return nil }
                    let capacityBytes = Self.safeExternalStorageByteCount(
                        item.integer(["capacity_bytes", "total_bytes", "size_bytes"])
                    )
                    let usedBytes = Self.safeExternalStorageByteCount(
                        item.integer(["used_bytes", "usage_bytes"])
                    ).flatMap { value in
                        guard let capacityBytes else { return value }
                        return value <= capacityBytes ? value : nil
                    }
                    return NasExternalStorageDevice(
                        id: id,
                        displayName: Self.safeExternalStorageName(
                            item.string(["display_name", "name", "model"])
                        ),
                        connection: connection,
                        status: Self.externalStorageStatus(
                            item.string(["status", "state"])
                        ),
                        capacityBytes: capacityBytes,
                        usedBytes: usedBytes
                    )
                }
                devices.append(contentsOf: parsed)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppError where error.category == .cancelled {
                throw CancellationError()
            } catch {
                // USB 与 eSATA 是独立的只读补充，单项失败不能覆盖另一项结果。
                unavailableConnections.append(connection)
            }
        }

        return NasExternalStorageDirectory(
            devices: devices.sorted {
                if $0.connection != $1.connection {
                    return $0.connection.rawValue < $1.connection.rawValue
                }
                return ($0.displayName ?? $0.id).localizedStandardCompare(
                    $1.displayName ?? $1.id
                ) == .orderedAscending
            },
            total: max(total, devices.count),
            isTruncated: isTruncated,
            unavailableConnections: unavailableConnections
        )
    }

    public func loadZRAM() async throws -> NasZRAMSnapshot {
        let value = try await call(
            DsmAPIName.coreHardwareZRAM,
            method: "get",
            version: 1
        )
        return NasZRAMSnapshot(
            isEnabled: value.boolean(["enable", "enabled", "zram_enable"]),
            configuredBytes: Self.safeExternalStorageByteCount(
                value.integer(["configured_bytes", "capacity_bytes", "size_bytes"])
            ),
            algorithm: Self.zramAlgorithm(
                value.string(["algorithm", "compression_algorithm", "compressor"])
            )
        )
    }

    public func saveHardwareSettings(_ settings: NasHardwareSettings) async throws {
        let result = try await saveHardwareSettingsResult(settings)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw hardwareSettingsError(for: result)
        }
    }

    /// 硬件设置由多个内部接口组成；任一提交失败后都整体回读，禁止自动重放。
    public func saveHardwareSettingsResult(
        _ settings: NasHardwareSettings
    ) async throws -> MutationResult {
        let operation = "hardwareSettingsUpdate"
        let prefix = "hardware.settings"
        if Task.isCancelled {
            return try hardwareMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !isHardwareSettingsUpdateActive else {
            return try hardwareMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isHardwareSettingsUpdateActive = true
        defer { isHardwareSettingsUpdateActive = false }

        let current: NasHardwareSettings
        do {
            current = try await loadHardwareSettings()
        } catch let error as AppError {
            return try hardwarePreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try hardwareMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        do {
            try validateHardwareSettings(settings, current: current)
        } catch {
            return try hardwareMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        let steps = hardwareMutationSteps(from: current, to: settings)
        guard !steps.isEmpty else {
            return try hardwareMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        guard hardwareCapabilitiesSupport(steps) else {
            return try hardwareMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: steps.count,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        if Task.isCancelled {
            return try hardwareMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var acceptedCount = 0
        for step in steps {
            if Task.isCancelled {
                if acceptedCount == 0 {
                    return try hardwareMutationResult(
                        status: .cancelledBeforeSubmission,
                        operation: operation,
                        submitted: false,
                        requiresRefresh: false,
                        succeeded: 0,
                        failed: 0,
                        unknown: 0,
                        diagnosticTag: "\(prefix).cancelled-before-first-submission"
                    )
                }
                return try hardwareMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - acceptedCount,
                    unknown: acceptedCount,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).cancelled-after-submission"
                )
            }
            do {
                try await submitHardwareMutationStep(
                    step,
                    settings: settings,
                    current: current
                )
                acceptedCount += 1
            } catch let error as AppError {
                return try await hardwareSubmissionFailureResult(
                    error,
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            } catch {
                return try await hardwareUnknownSubmissionResult(
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            }
        }

        if Task.isCancelled {
            return try hardwareMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }
        do {
            let verified = try await loadHardwareSettings()
            return try hardwareVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch let error as AppError {
            return try hardwareMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try hardwareMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private func validateHardwareSettings(
        _ settings: NasHardwareSettings,
        current: NasHardwareSettings
    ) throws {
        if let brightness = settings.ledBrightness,
           brightness != current.ledBrightness {
            guard let range = current.ledBrightnessRange, range.contains(brightness) else {
                throw verificationError(L10n.string("shared.e7bc95903e2c1a21"))
            }
        }
        if let fanMode = settings.fanMode,
           fanMode != current.fanMode {
            let supportedModes = Set([
                "highfan",
                "lowfan",
                "fullfan",
                "coolfan",
                "quietfan",
                "quietstopfan"
            ])
            guard supportedModes.contains(fanMode) else {
                throw verificationError(L10n.string("shared.f57a2aff1b6f5542"))
            }
        }
        guard (settings.ups == nil) == (current.ups == nil) else {
            throw verificationError(L10n.string("shared.4b3caf9ebe49fe9e"))
        }
        guard let expectedUPS = settings.ups, settings.ups != current.ups else { return }
        guard ["USB", "SNMP", "SLAVE"].contains(expectedUPS.mode) else {
            throw verificationError(L10n.string("shared.6c49d4a3c0dca3eb"))
        }
        if let delay = expectedUPS.safeModeDelaySeconds,
           !(0...604_800).contains(delay) {
            throw verificationError(L10n.string("shared.6fc94869ad264ba7"))
        }
        if expectedUPS.mode == "SLAVE",
           expectedUPS.isEnabled,
           (expectedUPS.networkServerAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw verificationError(L10n.string("shared.47b0ea4e9e53c8c1"))
        }
        if expectedUPS.mode == "SNMP",
           expectedUPS.isEnabled,
           (expectedUPS.snmpServerAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw verificationError(L10n.string("shared.0ac712a773c6795f"))
        }
    }

    private func hardwareMutationSteps(
        from current: NasHardwareSettings,
        to expected: NasHardwareSettings
    ) -> [HardwareSettingsMutationStep] {
        var steps: [HardwareSettingsMutationStep] = []
        if expected.restartsAfterPowerFailure != nil,
           expected.restartsAfterPowerFailure != current.restartsAfterPowerFailure {
            steps.append(.powerRecovery)
        }
        if expected.ledBrightness != nil,
           expected.ledBrightness != current.ledBrightness {
            steps.append(.ledBrightness)
        }
        if expected.fanMode != nil, expected.fanMode != current.fanMode {
            steps.append(.fanMode)
        }
        if !hardwareBeepParameters(expected, current: current).isEmpty {
            steps.append(.beep)
        }
        if !hardwareHibernationParameters(expected, current: current).isEmpty {
            steps.append(.hibernation)
        }
        if expected.ups != nil, expected.ups != current.ups {
            steps.append(.ups)
        }
        return steps
    }

    private func hardwareCapabilitiesSupport(
        _ steps: [HardwareSettingsMutationStep]
    ) -> Bool {
        steps.allSatisfy { step in
            switch step {
            case .powerRecovery:
                capabilitySupports(DsmAPIName.coreHardwarePowerRecovery)
            case .ledBrightness:
                capabilitySupports(DsmAPIName.coreHardwareLEDBrightness)
            case .fanMode:
                capabilitySupports(DsmAPIName.coreHardwareFanSpeed)
            case .beep:
                capabilitySupports(DsmAPIName.coreHardwareBeepControl)
            case .hibernation:
                capabilitySupports(DsmAPIName.coreHardwareHibernation)
            case .ups:
                capabilitySupports(DsmAPIName.coreExternalDeviceUPS)
            }
        }
    }

    private func submitHardwareMutationStep(
        _ step: HardwareSettingsMutationStep,
        settings: NasHardwareSettings,
        current: NasHardwareSettings
    ) async throws {
        switch step {
        case .powerRecovery:
            guard let value = settings.restartsAfterPowerFailure else {
                throw verificationError(L10n.string("shared.9e2bef35ff2e4491"))
            }
            try await callVoid(
                DsmAPIName.coreHardwarePowerRecovery,
                method: "set",
                parameters: ["rc_power_config": .boolean(value)]
            )
        case .ledBrightness:
            guard let brightness = settings.ledBrightness else {
                throw verificationError(L10n.string("shared.9e2bef35ff2e4491"))
            }
            try await callVoid(
                DsmAPIName.coreHardwareLEDBrightness,
                method: "set_current_brightness",
                parameters: ["led_brightness": .integer(brightness)]
            )
            try await callVoid(
                DsmAPIName.coreHardwareLEDBrightness,
                method: "update"
            )
        case .fanMode:
            guard let fanMode = settings.fanMode else {
                throw verificationError(L10n.string("shared.9e2bef35ff2e4491"))
            }
            try await callVoid(
                DsmAPIName.coreHardwareFanSpeed,
                method: "set",
                parameters: ["dual_fan_speed": .string(fanMode)]
            )
        case .beep:
            try await callVoid(
                DsmAPIName.coreHardwareBeepControl,
                method: "set",
                parameters: hardwareBeepParameters(settings, current: current)
            )
        case .hibernation:
            try await callVoid(
                DsmAPIName.coreHardwareHibernation,
                method: "set",
                parameters: hardwareHibernationParameters(settings, current: current)
            )
        case .ups:
            try await callVoid(
                DsmAPIName.coreExternalDeviceUPS,
                method: "set",
                parameters: try hardwareUPSParameters(settings, current: current)
            )
        }
    }

    private func hardwareBeepParameters(
        _ settings: NasHardwareSettings,
        current: NasHardwareSettings
    ) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [:]
        Self.appendChangedBoolean(
            settings.isFanFailureAlertEnabled,
            current.isFanFailureAlertEnabled,
            key: "fan_fail",
            to: &parameters
        )
        if let volumeField = beepVolumeFieldName {
            Self.appendChangedBoolean(
                settings.isVolumeFailureAlertEnabled,
                current.isVolumeFailureAlertEnabled,
                key: volumeField,
                to: &parameters
            )
        }
        Self.appendChangedBoolean(
            settings.isPowerOnSoundEnabled,
            current.isPowerOnSoundEnabled,
            key: "poweron_beep",
            to: &parameters
        )
        Self.appendChangedBoolean(
            settings.isPowerOffSoundEnabled,
            current.isPowerOffSoundEnabled,
            key: "poweroff_beep",
            to: &parameters
        )
        Self.appendChangedBoolean(
            settings.isResetSoundEnabled,
            current.isResetSoundEnabled,
            key: "reset_beep",
            to: &parameters
        )
        return parameters
    }

    private func hardwareHibernationParameters(
        _ settings: NasHardwareSettings,
        current: NasHardwareSettings
    ) -> [String: DsmParameterValue] {
        var parameters: [String: DsmParameterValue] = [:]
        Self.appendChangedBoolean(
            settings.isExternalDriveDeepSleepEnabled,
            current.isExternalDriveDeepSleepEnabled,
            key: "eunit_deep_sleep",
            to: &parameters
        )
        Self.appendChangedBoolean(
            settings.isWakeUpLogEnabled,
            current.isWakeUpLogEnabled,
            key: "enable_log",
            to: &parameters
        )
        Self.appendChangedBoolean(
            settings.isSATASleepEnabled,
            current.isSATASleepEnabled,
            key: "sata_deep_sleep",
            to: &parameters
        )
        Self.appendChangedBoolean(
            settings.ignoresNetworkDiscoveryDuringSleep,
            current.ignoresNetworkDiscoveryDuringSleep,
            key: "ignore_netbios_broadcast",
            to: &parameters
        )
        Self.appendChangedBoolean(
            settings.isAutomaticPowerOffEnabled,
            current.isAutomaticPowerOffEnabled,
            key: "auto_poweroff_enable",
            to: &parameters
        )
        return parameters
    }

    private func hardwareUPSParameters(
        _ settings: NasHardwareSettings,
        current: NasHardwareSettings
    ) throws -> [String: DsmParameterValue] {
        guard let expected = settings.ups, let currentUPS = current.ups else {
            throw verificationError(L10n.string("shared.4b3caf9ebe49fe9e"))
        }
        var parameters: [String: DsmParameterValue] = [
            "enable": .boolean(expected.isEnabled),
            "mode": .string(expected.mode)
        ]
        if let delay = expected.safeModeDelaySeconds {
            parameters["delay_time"] = .integer(delay)
        }
        Self.appendChangedBoolean(
            expected.waitsUntilLowBattery,
            currentUPS.waitsUntilLowBattery,
            key: "ups_set_safemode_until_lowbatt",
            to: &parameters
        )
        Self.appendChangedBoolean(
            expected.shutsDownUPSAfterSafeMode,
            currentUPS.shutsDownUPSAfterSafeMode,
            key: "shutdown_device",
            to: &parameters
        )
        if let address = expected.networkServerAddress {
            parameters["net_server_ip"] = .string(
                address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        if let address = expected.snmpServerAddress {
            parameters["snmp_server_ip"] = .string(
                address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return parameters
    }

    private func hardwareSubmissionFailureResult(
        _ submissionError: AppError,
        settings: NasHardwareSettings,
        steps: [HardwareSettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        let isAmbiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        if submissionError.category == .cancelled {
            return try hardwareMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: max(0, steps.count - acceptedCount - 1),
                unknown: min(steps.count, acceptedCount + 1),
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        do {
            let verified = try await loadHardwareSettings()
            return try hardwareVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: submissionError.category,
                uncertainCount: isAmbiguous
                    ? min(steps.count, acceptedCount + 1)
                    : acceptedCount
            )
        } catch {
            if acceptedCount > 0 || isAmbiguous {
                let unknown = min(
                    steps.count,
                    acceptedCount + (isAmbiguous ? 1 : 0)
                )
                return try hardwareMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - unknown,
                    unknown: unknown,
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).partial-readback-unverified"
                )
            }
            return try hardwareRejectedResult(
                submissionError,
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
    }

    private func hardwareUnknownSubmissionResult(
        settings: NasHardwareSettings,
        steps: [HardwareSettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadHardwareSettings()
            return try hardwareVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown,
                uncertainCount: min(steps.count, acceptedCount + 1)
            )
        } catch {
            let unknown = min(steps.count, acceptedCount + 1)
            return try hardwareMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: steps.count - unknown,
                unknown: unknown,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func hardwareVerifiedResult(
        _ actual: NasHardwareSettings,
        expected: NasHardwareSettings,
        steps: [HardwareSettingsMutationStep],
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil,
        uncertainCount: Int = 0
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.hardwareMutationStep($0, matches: actual, expected: expected)
        }.count
        let remaining = steps.count - succeeded
        if succeeded == steps.count {
            return try hardwareMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        let unknown = min(remaining, max(0, uncertainCount - succeeded))
        if succeeded > 0 {
            return try hardwareMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if unknown > 0 {
            return try hardwareMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                },
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unchanged"
            )
        }
        if let failureCategory {
            return try hardwareRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string("hardware.settings.failed")
                ),
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
        return try hardwareMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: remaining,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func hardwareRejectedResult(
        _ error: AppError,
        totalCount: Int,
        submitted: Bool,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try hardwareMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func hardwarePreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try hardwareMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        }
        return try hardwareRejectedResult(
            error,
            totalCount: 1,
            submitted: false,
            operation: operation,
            prefix: prefix
        )
    }

    private static func hardwareMutationStep(
        _ step: HardwareSettingsMutationStep,
        matches actual: NasHardwareSettings,
        expected: NasHardwareSettings
    ) -> Bool {
        switch step {
        case .powerRecovery:
            actual.restartsAfterPowerFailure == expected.restartsAfterPowerFailure
        case .ledBrightness:
            actual.ledBrightness == expected.ledBrightness
        case .fanMode:
            actual.fanMode == expected.fanMode
        case .beep:
            optionalHardwareValue(
                actual.isFanFailureAlertEnabled,
                matches: expected.isFanFailureAlertEnabled
            )
                && optionalHardwareValue(
                    actual.isVolumeFailureAlertEnabled,
                    matches: expected.isVolumeFailureAlertEnabled
                )
                && optionalHardwareValue(
                    actual.isPowerOnSoundEnabled,
                    matches: expected.isPowerOnSoundEnabled
                )
                && optionalHardwareValue(
                    actual.isPowerOffSoundEnabled,
                    matches: expected.isPowerOffSoundEnabled
                )
                && optionalHardwareValue(
                    actual.isResetSoundEnabled,
                    matches: expected.isResetSoundEnabled
                )
        case .hibernation:
            optionalHardwareValue(
                actual.isExternalDriveDeepSleepEnabled,
                matches: expected.isExternalDriveDeepSleepEnabled
            )
                && optionalHardwareValue(
                    actual.isWakeUpLogEnabled,
                    matches: expected.isWakeUpLogEnabled
                )
                && optionalHardwareValue(
                    actual.isSATASleepEnabled,
                    matches: expected.isSATASleepEnabled
                )
                && optionalHardwareValue(
                    actual.ignoresNetworkDiscoveryDuringSleep,
                    matches: expected.ignoresNetworkDiscoveryDuringSleep
                )
                && optionalHardwareValue(
                    actual.isAutomaticPowerOffEnabled,
                    matches: expected.isAutomaticPowerOffEnabled
                )
        case .ups:
            upsSettings(actual.ups, match: expected.ups)
        }
    }

    private static func optionalHardwareValue<T: Equatable>(
        _ actual: T?,
        matches expected: T?
    ) -> Bool {
        expected == nil || actual == expected
    }

    private func hardwareMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func hardwareSettingsError(for result: MutationResult) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? "hardware.settings.failed"
            )
        )
    }

    public func loadRemoteAccessSettings() async throws -> NasRemoteAccessSettings {
        let hasQuickConnect = capabilities[DsmAPIName.coreQuickConnect]?.selectedVersion != nil
        let hasUPnP = capabilities[DsmAPIName.coreQuickConnectUPnP]?.selectedVersion != nil
        guard hasQuickConnect || hasUPnP else {
            throw unavailableError()
        }
        let quickConnect = hasQuickConnect
            ? try await call(
                DsmAPIName.coreQuickConnect,
                method: "get_misc_config",
                version: 3
            )
            : nil
        let upnp = hasUPnP
            ? try await call(DsmAPIName.coreQuickConnectUPnP, method: "get")
            : nil
        return NasRemoteAccessSettings(
            isRelayEnabled: quickConnect?.boolean(["relay_enabled"]),
            isRouterConfigurationEnabled: upnp?.boolean(["enabled"]),
            canDisableRelay: !isConnectedThroughQuickConnectRelay
        )
    }

    public func saveRemoteAccessSettings(_ settings: NasRemoteAccessSettings) async throws {
        let result = try await saveRemoteAccessSettingsResult(settings)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw remoteAccessSettingsError(for: result)
        }
    }

    /// 远程访问设置可能改变连接路径；提交开始后必须先回读，禁止自动重放。
    public func saveRemoteAccessSettingsResult(
        _ settings: NasRemoteAccessSettings
    ) async throws -> MutationResult {
        let operation = "remoteAccessSettingsUpdate"
        let prefix = "remote-access.settings"
        if Task.isCancelled {
            return try remoteAccessMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !isRemoteAccessSettingsUpdateActive else {
            return try remoteAccessMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isRemoteAccessSettingsUpdateActive = true
        defer { isRemoteAccessSettingsUpdateActive = false }

        let current: NasRemoteAccessSettings
        do {
            current = try await loadRemoteAccessSettings()
        } catch let error as AppError {
            return try remoteAccessPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try remoteAccessMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        if settings.isRelayEnabled == false,
           current.isRelayEnabled == true,
           !current.canDisableRelay {
            return try remoteAccessMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).active-relay-connection"
            )
        }
        let steps = remoteAccessMutationSteps(from: current, to: settings)
        guard !steps.isEmpty else {
            return try remoteAccessMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        guard remoteAccessCapabilitiesSupport(steps) else {
            return try remoteAccessMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: steps.count,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        if Task.isCancelled {
            return try remoteAccessMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var acceptedCount = 0
        for step in steps {
            if Task.isCancelled {
                if acceptedCount == 0 {
                    return try remoteAccessMutationResult(
                        status: .cancelledBeforeSubmission,
                        operation: operation,
                        submitted: false,
                        requiresRefresh: false,
                        succeeded: 0,
                        failed: 0,
                        unknown: 0,
                        diagnosticTag: "\(prefix).cancelled-before-first-submission"
                    )
                }
                return try remoteAccessMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - acceptedCount,
                    unknown: acceptedCount,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).cancelled-after-submission"
                )
            }
            do {
                try await submitRemoteAccessMutationStep(step, settings: settings)
                acceptedCount += 1
            } catch let error as AppError {
                return try await remoteAccessSubmissionFailureResult(
                    error,
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            } catch {
                return try await remoteAccessUnknownSubmissionResult(
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            }
        }

        if Task.isCancelled {
            return try remoteAccessMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }
        do {
            let verified = try await loadRemoteAccessSettings()
            return try remoteAccessVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch let error as AppError {
            return try remoteAccessMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try remoteAccessMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private func remoteAccessMutationSteps(
        from current: NasRemoteAccessSettings,
        to expected: NasRemoteAccessSettings
    ) -> [RemoteAccessSettingsMutationStep] {
        var steps: [RemoteAccessSettingsMutationStep] = []
        if expected.isRelayEnabled != nil,
           expected.isRelayEnabled != current.isRelayEnabled {
            steps.append(.relay)
        }
        if expected.isRouterConfigurationEnabled != nil,
           expected.isRouterConfigurationEnabled
                != current.isRouterConfigurationEnabled {
            steps.append(.routerConfiguration)
        }
        return steps
    }

    private func remoteAccessCapabilitiesSupport(
        _ steps: [RemoteAccessSettingsMutationStep]
    ) -> Bool {
        steps.allSatisfy { step in
            switch step {
            case .relay:
                capabilitySupports(DsmAPIName.coreQuickConnect, version: 3)
            case .routerConfiguration:
                capabilitySupports(DsmAPIName.coreQuickConnectUPnP)
            }
        }
    }

    private func submitRemoteAccessMutationStep(
        _ step: RemoteAccessSettingsMutationStep,
        settings: NasRemoteAccessSettings
    ) async throws {
        switch step {
        case .relay:
            guard let enabled = settings.isRelayEnabled else {
                throw verificationError(L10n.string("shared.259c1e687815c0a7"))
            }
            try await callVoid(
                DsmAPIName.coreQuickConnect,
                method: "set_misc_config",
                version: 3,
                parameters: ["relay_enabled": .boolean(enabled)]
            )
        case .routerConfiguration:
            guard let enabled = settings.isRouterConfigurationEnabled else {
                throw verificationError(L10n.string("shared.259c1e687815c0a7"))
            }
            try await callVoid(
                DsmAPIName.coreQuickConnectUPnP,
                method: "set",
                parameters: ["enabled": .boolean(enabled)]
            )
        }
    }

    private func remoteAccessSubmissionFailureResult(
        _ submissionError: AppError,
        settings: NasRemoteAccessSettings,
        steps: [RemoteAccessSettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        let isAmbiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        if submissionError.category == .cancelled {
            return try remoteAccessMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: max(0, steps.count - acceptedCount - 1),
                unknown: min(steps.count, acceptedCount + 1),
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        do {
            let verified = try await loadRemoteAccessSettings()
            return try remoteAccessVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: submissionError.category,
                uncertainCount: isAmbiguous
                    ? min(steps.count, acceptedCount + 1)
                    : acceptedCount
            )
        } catch {
            if acceptedCount > 0 || isAmbiguous {
                let unknown = min(
                    steps.count,
                    acceptedCount + (isAmbiguous ? 1 : 0)
                )
                return try remoteAccessMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - unknown,
                    unknown: unknown,
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).partial-readback-unverified"
                )
            }
            return try remoteAccessRejectedResult(
                submissionError,
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
    }

    private func remoteAccessUnknownSubmissionResult(
        settings: NasRemoteAccessSettings,
        steps: [RemoteAccessSettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadRemoteAccessSettings()
            return try remoteAccessVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown,
                uncertainCount: min(steps.count, acceptedCount + 1)
            )
        } catch {
            let unknown = min(steps.count, acceptedCount + 1)
            return try remoteAccessMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: steps.count - unknown,
                unknown: unknown,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func remoteAccessVerifiedResult(
        _ actual: NasRemoteAccessSettings,
        expected: NasRemoteAccessSettings,
        steps: [RemoteAccessSettingsMutationStep],
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil,
        uncertainCount: Int = 0
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.remoteAccessMutationStep($0, matches: actual, expected: expected)
        }.count
        let remaining = steps.count - succeeded
        if succeeded == steps.count {
            return try remoteAccessMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        let unknown = min(remaining, max(0, uncertainCount - succeeded))
        if succeeded > 0 {
            return try remoteAccessMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if unknown > 0 {
            return try remoteAccessMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: remaining - unknown,
                unknown: unknown,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                },
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unchanged"
            )
        }
        if let failureCategory {
            return try remoteAccessRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string("remote-access.settings.failed")
                ),
                totalCount: steps.count,
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
        return try remoteAccessMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: remaining,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func remoteAccessRejectedResult(
        _ error: AppError,
        totalCount: Int,
        submitted: Bool,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try remoteAccessMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func remoteAccessPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try remoteAccessMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        }
        return try remoteAccessRejectedResult(
            error,
            totalCount: 1,
            submitted: false,
            operation: operation,
            prefix: prefix
        )
    }

    private static func remoteAccessMutationStep(
        _ step: RemoteAccessSettingsMutationStep,
        matches actual: NasRemoteAccessSettings,
        expected: NasRemoteAccessSettings
    ) -> Bool {
        switch step {
        case .relay:
            actual.isRelayEnabled == expected.isRelayEnabled
        case .routerConfiguration:
            actual.isRouterConfigurationEnabled
                == expected.isRouterConfigurationEnabled
        }
    }

    private func remoteAccessMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func remoteAccessSettingsError(for result: MutationResult) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? "remote-access.settings.failed"
            )
        )
    }

    public func saveSecuritySettings(_ settings: NasSecuritySettings) async throws {
        guard settings.failedAttempts > 0, settings.failedAttempts <= 9_999 else {
            throw verificationError(L10n.string("shared.7172e0328c485e2d"))
        }
        guard settings.withinMinutes > 0, settings.withinMinutes <= 9_999_999 else {
            throw verificationError(L10n.string("shared.6b3faa04b8983fea"))
        }
        if let days = settings.expirationDays, !(1...999).contains(days) {
            throw verificationError(L10n.string("shared.eb7055df43bef6c1"))
        }
        let current = try await loadSecuritySettings()
        guard current != settings else { return }
        if settings.isAutoBlockEnabled != current.isAutoBlockEnabled
            || settings.failedAttempts != current.failedAttempts
            || settings.withinMinutes != current.withinMinutes
            || settings.expirationDays != current.expirationDays {
            try await callVoid(
                DsmAPIName.coreSecurityAutoBlock,
                method: "set",
                parameters: [
                    "enable": .boolean(settings.isAutoBlockEnabled),
                    "attempts": .integer(settings.failedAttempts),
                    "within_mins": .integer(settings.withinMinutes),
                    "expire_day": .integer(settings.expirationDays ?? 0)
                ]
            )
        }
        if settings.dosProtection != current.dosProtection {
            let currentIDs = Set(current.dosProtection.map(\.id))
            guard Set(settings.dosProtection.map(\.id)) == currentIDs else {
                throw verificationError(L10n.string("shared.106655f64c87e191"))
            }
            let configs: [[String: DsmJSONValue]] = settings.dosProtection.map {
                [
                    "adapter": .string($0.id),
                    "dos_protect_enable": .boolean($0.isEnabled)
                ]
            }
            try await callVoid(
                DsmAPIName.coreSecurityDoS,
                method: "set",
                version: 2,
                parameters: ["configs": .objectArray(configs)]
            )
        }
        if let expected = settings.isPortScanProtectionEnabled,
           expected != current.isPortScanProtectionEnabled {
            try await callVoid(
                DsmAPIName.coreSecurityFirewallConf,
                method: "set",
                parameters: ["enable_port_check": .boolean(expected)]
            )
        }
        if let expected = settings.isFirewallEnabled,
           expected != current.isFirewallEnabled {
            if expected {
                guard let profile = current.firewallProfileName, !profile.isEmpty else {
                    throw verificationError(L10n.string("shared.816830de0895450c"))
                }
                try await applyFirewallProfile(profile)
            } else {
                try await callVoid(
                    DsmAPIName.coreSecurityFirewall,
                    method: "set",
                    parameters: ["set_type": .string("disable")]
                )
            }
        }
        let verified = try await loadSecuritySettings()
        guard verified.isAutoBlockEnabled == settings.isAutoBlockEnabled,
              verified.failedAttempts == settings.failedAttempts,
              verified.withinMinutes == settings.withinMinutes,
              verified.expirationDays == settings.expirationDays,
              verified.dosProtection == settings.dosProtection,
              (settings.isFirewallEnabled == nil
                || verified.isFirewallEnabled == settings.isFirewallEnabled),
              (settings.isPortScanProtectionEnabled == nil
                || verified.isPortScanProtectionEnabled
                    == settings.isPortScanProtectionEnabled) else {
            throw verificationError(L10n.string("shared.879eb126a08e1b1c"))
        }
    }

    /// 安全设置由多个内部接口组成；每个子操作都必须单独记录并在结束后整体回读。
    public func saveSecuritySettingsResult(
        _ settings: NasSecuritySettings
    ) async throws -> MutationResult {
        let operation = "securitySettingsUpdate"
        let prefix = "security.settings"
        if Task.isCancelled {
            return try securityMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        do {
            try validateSecuritySettings(settings)
        } catch {
            return try securityMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        guard !isSecuritySettingsUpdateActive else {
            return try securityMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isSecuritySettingsUpdateActive = true
        defer { isSecuritySettingsUpdateActive = false }

        let current: NasSecuritySettings
        let steps: [SecuritySettingsMutationStep]
        do {
            current = try await loadSecuritySettings()
            steps = try securityMutationSteps(from: current, to: settings)
        } catch let error as AppError {
            return try securityPreflightResult(error, operation: operation, prefix: prefix)
        } catch {
            return try securityMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        guard !steps.isEmpty else {
            return try securityMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        guard securityCapabilitiesSupport(steps, settings: settings) else {
            return try securityMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: steps.count,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        if Task.isCancelled {
            return try securityMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var acceptedCount = 0
        for step in steps {
            if Task.isCancelled {
                return try securityMutationResult(
                    status: .cancellationRequestedAfterSubmission,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - acceptedCount,
                    unknown: acceptedCount,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).cancelled-after-submission"
                )
            }
            do {
                try await submitSecurityMutationStep(
                    step,
                    settings: settings,
                    current: current
                )
                acceptedCount += 1
            } catch let error as AppError {
                return try await securitySubmissionFailureResult(
                    error,
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            } catch {
                return try await securityUnknownSubmissionResult(
                    settings: settings,
                    steps: steps,
                    acceptedCount: acceptedCount,
                    operation: operation,
                    prefix: prefix
                )
            }
        }

        if Task.isCancelled {
            return try securityMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }
        do {
            let verified = try await loadSecuritySettings()
            return try securityVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix
            )
        } catch let error as AppError {
            return try securityMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try securityMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: steps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private func validateSecuritySettings(
        _ settings: NasSecuritySettings
    ) throws {
        guard (1...9_999).contains(settings.failedAttempts) else {
            throw verificationError(L10n.string("shared.7172e0328c485e2d"))
        }
        guard (1...9_999_999).contains(settings.withinMinutes) else {
            throw verificationError(L10n.string("shared.6b3faa04b8983fea"))
        }
        if let days = settings.expirationDays, !(1...999).contains(days) {
            throw verificationError(L10n.string("shared.eb7055df43bef6c1"))
        }
        let ids = settings.dosProtection.map(\.id)
        guard Set(ids).count == ids.count,
              ids.allSatisfy({
                  !$0.isEmpty
                      && $0.unicodeScalars.allSatisfy {
                          CharacterSet(
                              charactersIn:
                                  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
                          ).contains($0)
                      }
              }) else {
            throw verificationError(L10n.string("shared.106655f64c87e191"))
        }
    }

    private func securityMutationSteps(
        from current: NasSecuritySettings,
        to expected: NasSecuritySettings
    ) throws -> [SecuritySettingsMutationStep] {
        var steps: [SecuritySettingsMutationStep] = []
        if current.isAutoBlockEnabled != expected.isAutoBlockEnabled
            || current.failedAttempts != expected.failedAttempts
            || current.withinMinutes != expected.withinMinutes
            || current.expirationDays != expected.expirationDays {
            steps.append(.autoBlock)
        }
        if Self.dosValues(current.dosProtection) != Self.dosValues(expected.dosProtection) {
            guard Set(current.dosProtection.map(\.id))
                    == Set(expected.dosProtection.map(\.id)) else {
                throw verificationError(L10n.string("shared.106655f64c87e191"))
            }
            steps.append(.denialOfService)
        }
        if let expectedPortScan = expected.isPortScanProtectionEnabled,
           expectedPortScan != current.isPortScanProtectionEnabled {
            steps.append(.portScanProtection)
        }
        if let expectedFirewall = expected.isFirewallEnabled,
           expectedFirewall != current.isFirewallEnabled {
            if expectedFirewall {
                guard let profile = current.firewallProfileName, !profile.isEmpty else {
                    throw verificationError(L10n.string("shared.816830de0895450c"))
                }
            }
            steps.append(.firewall)
        }
        return steps
    }

    private func securityCapabilitiesSupport(
        _ steps: [SecuritySettingsMutationStep],
        settings: NasSecuritySettings
    ) -> Bool {
        steps.allSatisfy { step in
            switch step {
            case .autoBlock:
                capabilitySupports(DsmAPIName.coreSecurityAutoBlock)
            case .denialOfService:
                capabilitySupports(DsmAPIName.coreNetworkEthernet)
                    && capabilitySupports(DsmAPIName.coreSecurityDoS, version: 2)
            case .portScanProtection:
                capabilitySupports(DsmAPIName.coreSecurityFirewallConf)
            case .firewall:
                capabilitySupports(DsmAPIName.coreSecurityFirewall)
                    && (settings.isFirewallEnabled != true
                        || capabilitySupports(DsmAPIName.coreSecurityFirewallProfileApply))
            }
        }
    }

    func capabilitySupports(_ name: String, version: Int? = nil) -> Bool {
        guard let capability = capabilities[name],
              let selectedVersion = capability.selectedVersion else {
            return false
        }
        let requiredVersion = version ?? selectedVersion
        return capability.minVersion...capability.maxVersion ~= requiredVersion
    }

    private func submitSecurityMutationStep(
        _ step: SecuritySettingsMutationStep,
        settings: NasSecuritySettings,
        current: NasSecuritySettings
    ) async throws {
        switch step {
        case .autoBlock:
            try await callVoid(
                DsmAPIName.coreSecurityAutoBlock,
                method: "set",
                parameters: [
                    "enable": .boolean(settings.isAutoBlockEnabled),
                    "attempts": .integer(settings.failedAttempts),
                    "within_mins": .integer(settings.withinMinutes),
                    "expire_day": .integer(settings.expirationDays ?? 0)
                ]
            )
        case .denialOfService:
            let configs: [[String: DsmJSONValue]] = settings.dosProtection.map {
                [
                    "adapter": .string($0.id),
                    "dos_protect_enable": .boolean($0.isEnabled)
                ]
            }
            try await callVoid(
                DsmAPIName.coreSecurityDoS,
                method: "set",
                version: 2,
                parameters: ["configs": .objectArray(configs)]
            )
        case .portScanProtection:
            guard let expected = settings.isPortScanProtectionEnabled else {
                throw verificationError(L10n.string("shared.879eb126a08e1b1c"))
            }
            try await callVoid(
                DsmAPIName.coreSecurityFirewallConf,
                method: "set",
                parameters: ["enable_port_check": .boolean(expected)]
            )
        case .firewall:
            guard let expected = settings.isFirewallEnabled else {
                throw verificationError(L10n.string("shared.879eb126a08e1b1c"))
            }
            if expected {
                guard let profile = current.firewallProfileName, !profile.isEmpty else {
                    throw verificationError(L10n.string("shared.816830de0895450c"))
                }
                try await applyFirewallProfile(profile)
            } else {
                try await callVoid(
                    DsmAPIName.coreSecurityFirewall,
                    method: "set",
                    parameters: ["set_type": .string("disable")]
                )
            }
        }
    }

    private func securitySubmissionFailureResult(
        _ submissionError: AppError,
        settings: NasSecuritySettings,
        steps: [SecuritySettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled {
            return try securityMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: max(0, steps.count - acceptedCount - 1),
                unknown: min(steps.count, acceptedCount + 1),
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        let isAmbiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        if acceptedCount > 0 || isAmbiguous {
            do {
                let verified = try await loadSecuritySettings()
                return try securityVerifiedResult(
                    verified,
                    expected: settings,
                    steps: steps,
                    operation: operation,
                    prefix: prefix,
                    failureCategory: submissionError.category
                )
            } catch {
                let unknown = min(steps.count, acceptedCount + (isAmbiguous ? 1 : 0))
                return try securityMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: steps.count - unknown,
                    unknown: unknown,
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).partial-readback-unverified"
                )
            }
        }
        return try securityRejectedResult(
            submissionError,
            totalCount: steps.count,
            operation: operation,
            prefix: prefix
        )
    }

    private func securityUnknownSubmissionResult(
        settings: NasSecuritySettings,
        steps: [SecuritySettingsMutationStep],
        acceptedCount: Int,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadSecuritySettings()
            return try securityVerifiedResult(
                verified,
                expected: settings,
                steps: steps,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown
            )
        } catch {
            let unknown = min(steps.count, acceptedCount + 1)
            return try securityMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: steps.count - unknown,
                unknown: unknown,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func securityVerifiedResult(
        _ actual: NasSecuritySettings,
        expected: NasSecuritySettings,
        steps: [SecuritySettingsMutationStep],
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.securityMutationStep($0, matches: actual, expected: expected)
        }.count
        let failed = steps.count - succeeded
        if succeeded == steps.count {
            return try securityMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        if succeeded > 0 {
            return try securityMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: failed,
                unknown: 0,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                } ?? .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if let failureCategory {
            return try securityRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string("security.settings.failed")
                ),
                totalCount: steps.count,
                operation: operation,
                prefix: prefix
            )
        }
        return try securityMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: failed,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func securityRejectedResult(
        _ error: AppError,
        totalCount: Int,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try securityMutationResult(
            status: status,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func securityPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let category: MutationErrorCategory?
        let localizationKey: String?
        switch error.category {
        case .cancelled:
            return try securityMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            category = .permission
            localizationKey = "\(prefix).permission-denied"
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            category = .unsupported
            localizationKey = "\(prefix).unsupported"
        default:
            status = .confirmedFailure
            category = packageMutationErrorCategory(for: error.category)
            localizationKey = "\(prefix).failed"
        }
        return try securityMutationResult(
            status: status,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).preflight-failed"
        )
    }

    private static func securityMutationStep(
        _ step: SecuritySettingsMutationStep,
        matches actual: NasSecuritySettings,
        expected: NasSecuritySettings
    ) -> Bool {
        switch step {
        case .autoBlock:
            actual.isAutoBlockEnabled == expected.isAutoBlockEnabled
                && actual.failedAttempts == expected.failedAttempts
                && actual.withinMinutes == expected.withinMinutes
                && actual.expirationDays == expected.expirationDays
        case .denialOfService:
            dosValues(actual.dosProtection) == dosValues(expected.dosProtection)
        case .portScanProtection:
            actual.isPortScanProtectionEnabled == expected.isPortScanProtectionEnabled
        case .firewall:
            actual.isFirewallEnabled == expected.isFirewallEnabled
        }
    }

    private static func dosValues(
        _ settings: [NasDoSProtectionSetting]
    ) -> [String: Bool] {
        Dictionary(settings.map { ($0.id, $0.isEnabled) }, uniquingKeysWith: { _, latest in latest })
    }

    private func securityMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func applyFirewallProfile(_ profile: String) async throws {
        let started = try await call(
            DsmAPIName.coreSecurityFirewallProfileApply,
            method: "start",
            parameters: [
                "name": .string(profile),
                "profile_applying": .boolean(false)
            ]
        )
        guard let taskID = started.string(["task_id"]), !taskID.isEmpty else {
            throw verificationError(L10n.string("shared.40d8f50f944fb5b6"))
        }
        var completed = false
        for attempt in 0..<30 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1))
            }
            let status = try await call(
                DsmAPIName.coreSecurityFirewallProfileApply,
                method: "status",
                parameters: ["task_id": .string(taskID)]
            )
            if let success = status.boolean(["success"]) {
                guard success else {
                    try? await callVoid(
                        DsmAPIName.coreSecurityFirewallProfileApply,
                        method: "stop"
                    )
                    throw verificationError(L10n.string("shared.672df0d0489dd59a"))
                }
                completed = true
                break
            }
        }
        try? await callVoid(DsmAPIName.coreSecurityFirewallProfileApply, method: "stop")
        guard completed else {
            throw AppError(
                category: .serverBusy,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.41454065abd301f9")
            )
        }
    }

    public func loadRegionSettings() async throws -> NasRegionSettings {
        let value = try await call(
            DsmAPIName.coreRegionNTP,
            method: "get",
            version: 3
        )
        let zonesValue = try await call(
            DsmAPIName.coreRegionNTP,
            method: "listzone",
            version: 1
        )
        guard let dateFormat = value.string(["date_format"]),
              let timeFormat = value.string(["time_format"]),
              let timeZone = value.string(["timezone"]),
              let rawMode = value.string(["enable_ntp"]) else {
            throw verificationError(L10n.string("shared.db6b9590023d51f5"))
        }
        let isNetworkTimeEnabled =
            ["ntp", "true", "yes", "1", "enabled"].contains(rawMode.lowercased())
        let serverText = value.string(["server"]) ?? ""
        let servers = serverText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let zones = zonesValue.objects("zonedata").compactMap { zone -> NasTimeZoneOption? in
            guard let id = zone["value"]?.scalarString, !id.isEmpty else { return nil }
            return NasTimeZoneOption(
                id: id,
                displayName: zone["display"]?.scalarString ?? id
            )
        }
        let manualDate = Self.regionDate(
            date: value.string(["date"]),
            hour: value.number(["hour"]).map(Int.init),
            minute: value.number(["minute"]).map(Int.init),
            second: value.number(["second"]).map(Int.init)
        )
        return NasRegionSettings(
            dateFormat: dateFormat,
            timeFormat: timeFormat,
            timeZone: timeZone,
            isNetworkTimeEnabled: isNetworkTimeEnabled,
            timeServers: servers,
            manualDate: manualDate,
            timeZones: zones
        )
    }

    public func saveRegionSettings(_ settings: NasRegionSettings) async throws {
        let result = try await saveRegionSettingsResult(settings)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw regionSettingsError(for: result)
        }
    }

    /// 先保存并回读区域配置，再执行必要的网络校时；提交后的未知结果不得自动重放。
    public func saveRegionSettingsResult(
        _ settings: NasRegionSettings
    ) async throws -> MutationResult {
        let operation = "regionSettingsUpdate"
        let prefix = "region.settings"
        if Task.isCancelled {
            return try regionMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !isRegionSettingsUpdateActive else {
            return try regionMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        isRegionSettingsUpdateActive = true
        defer { isRegionSettingsUpdateActive = false }

        guard !settings.normalizedDateFormat.isEmpty,
              !settings.normalizedTimeFormat.isEmpty,
              settings.timeZones.contains(where: { $0.id == settings.timeZone }),
              settings.normalizedTimeServers.count <= 3,
              !settings.isNetworkTimeEnabled
                || (!settings.normalizedTimeServers.isEmpty
                    && settings.normalizedTimeServers.allSatisfy(
                        NasRegionSettings.isValidTimeServer
                    )) else {
            return try regionMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).invalid",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        guard capabilitySupports(DsmAPIName.coreRegionNTP, version: 3) else {
            return try regionMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }

        let current: NasRegionSettings
        do {
            current = try await loadRegionSettings()
        } catch let error as AppError {
            return try regionPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try regionMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }
        let manualDate = settings.isNetworkTimeEnabled
            ? settings.manualDate
            : (settings.manualDate ?? current.manualDate)
        let normalized = NasRegionSettings(
            dateFormat: settings.normalizedDateFormat,
            timeFormat: settings.normalizedTimeFormat,
            timeZone: settings.timeZone,
            isNetworkTimeEnabled: settings.isNetworkTimeEnabled,
            timeServers: settings.normalizedTimeServers,
            manualDate: manualDate,
            timeZones: current.timeZones
        )
        guard normalized.isNetworkTimeEnabled || normalized.manualDate != nil else {
            return try regionMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).invalid",
                diagnosticTag: "\(prefix).missing-manual-date"
            )
        }
        let configurationSteps = Self.regionMutationSteps(
            from: current,
            to: normalized,
            updatesManualDate: settings.manualDate != nil
        )
        let needsSynchronization = normalized.isNetworkTimeEnabled
            && (!current.isNetworkTimeEnabled
                || current.timeServers != normalized.timeServers)
        var allSteps = configurationSteps
        if needsSynchronization {
            allSteps.append(.synchronize)
        }
        guard !allSteps.isEmpty else {
            return try regionMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).no-changes"
            )
        }
        if Task.isCancelled {
            return try regionMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var parameters: [String: DsmParameterValue] = [
            "date_format": .string(normalized.dateFormat),
            "time_format": .string(normalized.timeFormat),
            "timezone": .string(normalized.timeZone),
            "enable_ntp": .string(normalized.isNetworkTimeEnabled ? "ntp" : "manual"),
            "server": .string(normalized.timeServers.joined(separator: ","))
        ]
        if !normalized.isNetworkTimeEnabled {
            guard let manualDate = normalized.manualDate else {
                return try regionMutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .validation,
                    localizationKey: "\(prefix).invalid",
                    diagnosticTag: "\(prefix).missing-manual-date"
                )
            }
            let calendar = Calendar(identifier: .gregorian)
            let parts = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: manualDate
            )
            guard let year = parts.year, let month = parts.month, let day = parts.day,
                  let hour = parts.hour, let minute = parts.minute, let second = parts.second else {
                return try regionMutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .validation,
                    localizationKey: "\(prefix).invalid",
                    diagnosticTag: "\(prefix).invalid-manual-date"
                )
            }
            parameters["date"] = .string("\(year)/\(month)/\(day)")
            parameters["hour"] = .integer(hour)
            parameters["minute"] = .integer(minute)
            parameters["second"] = .integer(second)
        }

        do {
            try await callVoid(
                DsmAPIName.coreRegionNTP,
                method: "set",
                version: 3,
                parameters: parameters
            )
        } catch let error as AppError {
            return try await regionSubmissionFailureResult(
                error,
                expected: normalized,
                configurationSteps: configurationSteps,
                includesPendingSynchronization: needsSynchronization,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try await regionUnknownSubmissionResult(
                expected: normalized,
                configurationSteps: configurationSteps,
                includesPendingSynchronization: needsSynchronization,
                operation: operation,
                prefix: prefix
            )
        }
        if Task.isCancelled {
            return try regionMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: allSteps.count,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-before-readback"
            )
        }

        let verifiedConfiguration: NasRegionSettings
        do {
            verifiedConfiguration = try await loadRegionSettings()
        } catch let error as AppError {
            return try regionMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: allSteps.count,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try regionMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: allSteps.count,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
        let configurationResult = try regionVerifiedResult(
            verifiedConfiguration,
            expected: normalized,
            steps: configurationSteps,
            operation: operation,
            prefix: prefix
        )
        guard configurationResult.status == .confirmedSuccess else {
            return configurationResult
        }
        guard needsSynchronization else {
            return configurationResult
        }

        do {
            try await callVoid(
                DsmAPIName.coreRegionNTP,
                method: "sync",
                version: 2,
                parameters: [
                    "servers": .stringArray(normalized.timeServers)
                ]
            )
        } catch let error as AppError {
            return try regionSynchronizationFailureResult(
                error,
                succeeded: configurationSteps.count,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try regionMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: configurationSteps.count,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).sync-unknown"
            )
        }
        if Task.isCancelled {
            return try regionMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: configurationSteps.count,
                failed: 0,
                unknown: 1,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-after-sync"
            )
        }
        do {
            let verified = try await loadRegionSettings()
            return try regionVerifiedResult(
                verified,
                expected: normalized,
                steps: allSteps,
                synchronizationAccepted: true,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try regionMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: configurationSteps.count,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).sync-readback-unverified"
            )
        }
    }

    private static func regionMutationSteps(
        from current: NasRegionSettings,
        to expected: NasRegionSettings,
        updatesManualDate: Bool
    ) -> [RegionSettingsMutationStep] {
        var steps: [RegionSettingsMutationStep] = []
        if current.dateFormat != expected.dateFormat {
            steps.append(.dateFormat)
        }
        if current.timeFormat != expected.timeFormat {
            steps.append(.timeFormat)
        }
        if current.timeZone != expected.timeZone {
            steps.append(.timeZone)
        }
        if current.isNetworkTimeEnabled != expected.isNetworkTimeEnabled {
            steps.append(.mode)
        }
        if expected.isNetworkTimeEnabled,
           current.timeServers != expected.timeServers {
            steps.append(.servers)
        }
        if !expected.isNetworkTimeEnabled, updatesManualDate,
           !regionDatesMatch(current.manualDate, expected.manualDate) {
            steps.append(.manualDate)
        }
        return steps
    }

    private static func regionDatesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince(rhs)) <= 120
    }

    private static func regionMutationStep(
        _ step: RegionSettingsMutationStep,
        matches actual: NasRegionSettings,
        expected: NasRegionSettings,
        synchronizationAccepted: Bool
    ) -> Bool {
        switch step {
        case .dateFormat:
            actual.dateFormat == expected.dateFormat
        case .timeFormat:
            actual.timeFormat == expected.timeFormat
        case .timeZone:
            actual.timeZone == expected.timeZone
        case .mode:
            actual.isNetworkTimeEnabled == expected.isNetworkTimeEnabled
        case .servers:
            actual.timeServers == expected.timeServers
        case .manualDate:
            regionDatesMatch(actual.manualDate, expected.manualDate)
        case .synchronize:
            synchronizationAccepted
        }
    }

    private func regionVerifiedResult(
        _ actual: NasRegionSettings,
        expected: NasRegionSettings,
        steps: [RegionSettingsMutationStep],
        synchronizationAccepted: Bool = false,
        includesPendingSynchronization: Bool = false,
        operation: String,
        prefix: String,
        failureCategory: AppErrorCategory? = nil,
        treatsMismatchAsUnknown: Bool = false
    ) throws -> MutationResult {
        let succeeded = steps.filter {
            Self.regionMutationStep(
                $0,
                matches: actual,
                expected: expected,
                synchronizationAccepted: synchronizationAccepted
            )
        }.count
        let pendingSynchronization = includesPendingSynchronization ? 1 : 0
        let unmatched = steps.count - succeeded
        let unknown = treatsMismatchAsUnknown ? unmatched : 0
        let totalUnknown = unknown + pendingSynchronization
        let failed = unmatched - unknown
        if succeeded == steps.count, pendingSynchronization == 0 {
            return try regionMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        }
        if succeeded > 0 {
            return try regionMutationResult(
                status: .partialSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: failed,
                unknown: totalUnknown,
                errorCategory: .conflict,
                localizationKey: "\(prefix).partial",
                diagnosticTag: "\(prefix).partial"
            )
        }
        if totalUnknown > 0 {
            return try regionMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: failed,
                unknown: totalUnknown,
                errorCategory: failureCategory.map {
                    packageMutationErrorCategory(for: $0)
                },
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
        if let failureCategory {
            return try regionRejectedResult(
                AppError(
                    category: failureCategory,
                    isRetryable: false,
                    safeUserMessage: L10n.string("region.settings.failed")
                ),
                totalCount: max(1, steps.count),
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
        return try regionMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: max(1, failed),
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func regionSubmissionFailureResult(
        _ submissionError: AppError,
        expected: NasRegionSettings,
        configurationSteps: [RegionSettingsMutationStep],
        includesPendingSynchronization: Bool,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled {
            return try regionMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: configurationSteps.count
                    + (includesPendingSynchronization ? 1 : 0),
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        }
        let ambiguous = switch submissionError.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        do {
            let verified = try await loadRegionSettings()
            return try regionVerifiedResult(
                verified,
                expected: expected,
                steps: configurationSteps,
                includesPendingSynchronization: ambiguous
                    && includesPendingSynchronization,
                operation: operation,
                prefix: prefix,
                failureCategory: submissionError.category,
                treatsMismatchAsUnknown: ambiguous
            )
        } catch {
            if ambiguous {
                return try regionMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: configurationSteps.count
                        + (includesPendingSynchronization ? 1 : 0),
                    errorCategory: packageMutationErrorCategory(
                        for: submissionError.category
                    ),
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).readback-unverified"
                )
            }
            return try regionRejectedResult(
                submissionError,
                totalCount: max(1, configurationSteps.count),
                submitted: true,
                operation: operation,
                prefix: prefix
            )
        }
    }

    private func regionUnknownSubmissionResult(
        expected: NasRegionSettings,
        configurationSteps: [RegionSettingsMutationStep],
        includesPendingSynchronization: Bool,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadRegionSettings()
            return try regionVerifiedResult(
                verified,
                expected: expected,
                steps: configurationSteps,
                includesPendingSynchronization: includesPendingSynchronization,
                operation: operation,
                prefix: prefix,
                failureCategory: .unknown,
                treatsMismatchAsUnknown: true
            )
        } catch {
            return try regionMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: configurationSteps.count
                    + (includesPendingSynchronization ? 1 : 0),
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }
    }

    private func regionSynchronizationFailureResult(
        _ error: AppError,
        succeeded: Int,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try regionMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-sync"
            )
        }
        let ambiguous = switch error.category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
        return try regionMutationResult(
            status: .partialSuccess,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: succeeded,
            failed: ambiguous ? 0 : 1,
            unknown: ambiguous ? 1 : 0,
            errorCategory: packageMutationErrorCategory(for: error.category),
            localizationKey: "\(prefix).partial",
            diagnosticTag: "\(prefix).sync-failed"
        )
    }

    private func regionRejectedResult(
        _ error: AppError,
        totalCount: Int,
        submitted: Bool,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try regionMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: totalCount,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func regionPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try regionMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        }
        return try regionRejectedResult(
            error,
            totalCount: 1,
            submitted: false,
            operation: operation,
            prefix: prefix
        )
    }

    private func regionMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func regionSettingsError(for result: MutationResult) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? "region.settings.failed"
            )
        )
    }

    public func loadDDNS() async throws -> NasDDNSDirectory {
        let providerValue = try await call(DsmAPIName.coreDDNSProvider, method: "list")
        let recordValue = try await call(DsmAPIName.coreDDNSRecord, method: "list")
        let providerObjects = providerValue.objects("providers")
        var providerOrder: [String] = []
        var providerByID: [String: NasDDNSProvider] = [:]
        for item in providerObjects {
            guard let id = item["id"]?.scalarString
                    ?? item["provider"]?.scalarString,
                  !id.isEmpty else {
                continue
            }
            let provider = NasDDNSProvider(
                id: id,
                displayName: item["display"]?.scalarString
                    ?? item["name"]?.scalarString
                    ?? id
            )
            if let existing = providerByID[id] {
                // DSM 可能按协议类型重复列出同一服务商；保留更友好的显示名称。
                if existing.displayName == id, provider.displayName != id {
                    providerByID[id] = provider
                }
            } else {
                providerOrder.append(id)
                providerByID[id] = provider
            }
        }
        let providers = providerOrder.compactMap { providerByID[$0] }
        let names = providers.reduce(into: [String: String]()) {
            $0[$1.id] = $1.displayName
        }
        let records = recordValue.objects("records").compactMap { item -> NasDDNSRecord? in
            guard let provider = item["provider"]?.scalarString,
                  let hostname = item["hostname"]?.scalarString,
                  !provider.isEmpty, !hostname.isEmpty else {
                return nil
            }
            let ipv4 = item["ip"]?.scalarString
            let ipv6 = item["ipv6"]?.scalarString
            let addresses = [ipv4, ipv6].compactMap { address -> String? in
                guard let address,
                      !["", "0.0.0.0", "0:0:0:0:0:0:0:0"].contains(address) else {
                    return nil
                }
                return address
            }
            return NasDDNSRecord(
                id: provider,
                providerID: provider,
                providerName: names[provider] ?? provider,
                hostname: hostname,
                address: addresses.isEmpty ? nil : addresses.joined(separator: " / "),
                status: item["status"]?.scalarString,
                lastUpdated: item["lastupdated"]?.scalarString,
                isEnabled: item["enable"]?.scalarBoolean ?? false,
                username: item["username"]?.scalarString,
                networkType: item["net"]?.scalarString,
                ipv4: ipv4,
                ipv6: ipv6,
                interfaceV4: item["interface_v4"]?.scalarString,
                interfaceV6: item["interface_v6"]?.scalarString,
                heartbeat: item["heartbeat"]?.scalarBoolean ?? false
            )
        }
        return NasDDNSDirectory(providers: providers, records: records)
    }

    public func testDDNSResult(
        _ draft: NasDDNSDraft
    ) async throws -> MutationResult {
        let operation = "ddnsProviderTest"
        let prefix = "ddns.test"
        if Task.isCancelled {
            return try ddnsMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                localizationKey: "\(prefix).cancelled",
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard draft.isValidForSubmission else {
            return try ddnsInvalidResult(operation: operation, prefix: prefix)
        }
        guard ddnsCapabilitiesAreAvailable else {
            return try ddnsUnsupportedResult(operation: operation, prefix: prefix)
        }
        let providerID = draft.normalizedProviderID
        guard !isDDNSRefreshActive,
              activeDDNSProviderIDs.insert(providerID).inserted else {
            return try ddnsBusyResult(operation: operation, prefix: prefix)
        }
        defer { activeDDNSProviderIDs.remove(providerID) }

        let directory: NasDDNSDirectory
        do {
            directory = try await loadDDNS()
        } catch let error as AppError {
            return try ddnsRejectedResult(
                error,
                operation: operation,
                prefix: prefix,
                submitted: false
            )
        } catch {
            return try ddnsUnknownPreflightResult(
                operation: operation,
                prefix: prefix
            )
        }
        guard directory.providers.contains(where: { $0.id == providerID }),
              draft.originalProviderID == nil
                || draft.originalProviderID == providerID else {
            return try ddnsInvalidResult(operation: operation, prefix: prefix)
        }
        if Task.isCancelled {
            return try ddnsMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                localizationKey: "\(prefix).cancelled",
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }
        let parameters = Self.ddnsParameters(
            draft,
            hostname: draft.normalizedHostname,
            username: draft.normalizedUsername
        )
        do {
            try await callVoid(
                DsmAPIName.coreDDNSRecord,
                method: "test",
                parameters: parameters
            )
            if Task.isCancelled {
                return try ddnsCancellationAfterSubmissionResult(
                    operation: operation,
                    prefix: prefix
                )
            }
            return try ddnsMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                localizationKey: "\(prefix).completed",
                diagnosticTag: "\(prefix).accepted"
            )
        } catch let error as AppError {
            if error.category == .cancelled {
                return try ddnsCancellationAfterSubmissionResult(
                    operation: operation,
                    prefix: prefix
                )
            }
            if ddnsSubmissionIsAmbiguous(error.category) {
                return try ddnsUnverifiedResult(
                    operation: operation,
                    prefix: prefix,
                    category: error.category,
                    diagnosticTag: "\(prefix).submission-unverified"
                )
            }
            return try ddnsRejectedResult(
                error,
                operation: operation,
                prefix: prefix,
                submitted: true
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).submission-unknown"
            )
        }
    }

    public func saveDDNS(_ draft: NasDDNSDraft) async throws {
        let result = try await saveDDNSResult(draft)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw ddnsOperationError(for: result, fallbackKey: "ddns.save.failed")
        }
    }

    public func saveDDNSResult(
        _ draft: NasDDNSDraft
    ) async throws -> MutationResult {
        let operation = "ddnsRecordSave"
        let prefix = "ddns.save"
        if Task.isCancelled {
            return try ddnsCancelledBeforeSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        guard draft.isValidForSubmission else {
            return try ddnsInvalidResult(operation: operation, prefix: prefix)
        }
        guard ddnsCapabilitiesAreAvailable else {
            return try ddnsUnsupportedResult(operation: operation, prefix: prefix)
        }
        let providerID = draft.normalizedProviderID
        guard !isDDNSRefreshActive,
              activeDDNSProviderIDs.insert(providerID).inserted else {
            return try ddnsBusyResult(operation: operation, prefix: prefix)
        }
        defer { activeDDNSProviderIDs.remove(providerID) }

        let directory: NasDDNSDirectory
        do {
            directory = try await loadDDNS()
        } catch let error as AppError {
            return try ddnsRejectedResult(
                error,
                operation: operation,
                prefix: prefix,
                submitted: false
            )
        } catch {
            return try ddnsUnknownPreflightResult(
                operation: operation,
                prefix: prefix
            )
        }
        guard directory.providers.contains(where: { $0.id == providerID }) else {
            return try ddnsInvalidResult(operation: operation, prefix: prefix)
        }
        if let original = draft.originalProviderID {
            guard original == providerID,
                  directory.records.contains(where: { $0.providerID == original }) else {
                return try ddnsConflictResult(
                    operation: operation,
                    prefix: prefix,
                    diagnosticTag: "\(prefix).missing-original"
                )
            }
        } else if directory.records.contains(where: { $0.providerID == providerID }) {
            return try ddnsConflictResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).duplicate-provider"
            )
        }
        if Task.isCancelled {
            return try ddnsCancelledBeforeSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        var parameters = Self.ddnsParameters(
            draft,
            hostname: draft.normalizedHostname,
            username: draft.normalizedUsername
        )
        if draft.password.isEmpty, providerID != "Synology" {
            parameters.removeValue(forKey: "passwd")
        }
        do {
            try await callVoid(
                DsmAPIName.coreDDNSRecord,
                method: draft.originalProviderID == nil ? "create" : "set",
                parameters: parameters
            )
        } catch let error as AppError {
            return try await ddnsSaveSubmissionFailureResult(
                error,
                draft: draft,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try await ddnsSaveUnknownSubmissionResult(
                draft: draft,
                operation: operation,
                prefix: prefix
            )
        }
        if Task.isCancelled {
            return try ddnsCancellationAfterSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        do {
            let verified = try await loadDDNS()
            return try ddnsSavedRecordResult(
                directory: verified,
                draft: draft,
                operation: operation,
                prefix: prefix,
                treatsMismatchAsUnknown: false
            )
        } catch let error as AppError {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                category: error.category,
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    public func deleteDDNS(providerID: String) async throws {
        let result = try await deleteDDNSResult(providerID: providerID)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw ddnsOperationError(
                for: result,
                fallbackKey: "ddns.delete.failed"
            )
        }
    }

    public func deleteDDNSResult(
        providerID: String
    ) async throws -> MutationResult {
        let operation = "ddnsRecordDelete"
        let prefix = "ddns.delete"
        let normalizedID = providerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if Task.isCancelled {
            return try ddnsCancelledBeforeSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        guard !normalizedID.isEmpty else {
            return try ddnsInvalidResult(operation: operation, prefix: prefix)
        }
        guard ddnsCapabilitiesAreAvailable else {
            return try ddnsUnsupportedResult(operation: operation, prefix: prefix)
        }
        guard !isDDNSRefreshActive,
              activeDDNSProviderIDs.insert(normalizedID).inserted else {
            return try ddnsBusyResult(operation: operation, prefix: prefix)
        }
        defer { activeDDNSProviderIDs.remove(normalizedID) }

        do {
            let current = try await loadDDNS()
            guard current.records.contains(where: {
                $0.providerID == normalizedID
            }) else {
                return try ddnsConflictResult(
                    operation: operation,
                    prefix: prefix,
                    diagnosticTag: "\(prefix).missing-record"
                )
            }
        } catch let error as AppError {
            return try ddnsRejectedResult(
                error,
                operation: operation,
                prefix: prefix,
                submitted: false
            )
        } catch {
            return try ddnsUnknownPreflightResult(
                operation: operation,
                prefix: prefix
            )
        }
        if Task.isCancelled {
            return try ddnsCancelledBeforeSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        do {
            try await callVoid(
                DsmAPIName.coreDDNSRecord,
                method: "delete",
                parameters: ["id": .stringArray([normalizedID])]
            )
        } catch let error as AppError {
            return try await ddnsDeleteSubmissionFailureResult(
                error,
                providerID: normalizedID,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try await ddnsDeleteUnknownSubmissionResult(
                providerID: normalizedID,
                operation: operation,
                prefix: prefix
            )
        }
        if Task.isCancelled {
            return try ddnsCancellationAfterSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        do {
            let verified = try await loadDDNS()
            return try ddnsDeletedRecordResult(
                directory: verified,
                providerID: normalizedID,
                operation: operation,
                prefix: prefix,
                treatsPresenceAsUnknown: false
            )
        } catch let error as AppError {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                category: error.category,
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    public func refreshDDNS() async throws {
        let result = try await refreshDDNSResult()
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw ddnsOperationError(
                for: result,
                fallbackKey: "ddns.refresh.failed"
            )
        }
    }

    public func refreshDDNSResult() async throws -> MutationResult {
        let operation = "ddnsAddressRefresh"
        let prefix = "ddns.refresh"
        if Task.isCancelled {
            return try ddnsCancelledBeforeSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        guard ddnsCapabilitiesAreAvailable else {
            return try ddnsUnsupportedResult(operation: operation, prefix: prefix)
        }
        guard !isDDNSRefreshActive, activeDDNSProviderIDs.isEmpty else {
            return try ddnsBusyResult(operation: operation, prefix: prefix)
        }
        isDDNSRefreshActive = true
        defer { isDDNSRefreshActive = false }

        do {
            let current = try await loadDDNS()
            guard !current.records.isEmpty else {
                return try ddnsConflictResult(
                    operation: operation,
                    prefix: prefix,
                    diagnosticTag: "\(prefix).no-records"
                )
            }
        } catch let error as AppError {
            return try ddnsRejectedResult(
                error,
                operation: operation,
                prefix: prefix,
                submitted: false
            )
        } catch {
            return try ddnsUnknownPreflightResult(
                operation: operation,
                prefix: prefix
            )
        }
        if Task.isCancelled {
            return try ddnsCancelledBeforeSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        do {
            try await callVoid(
                DsmAPIName.coreDDNSRecord,
                method: "update_ip_address"
            )
        } catch let error as AppError {
            if error.category == .cancelled {
                return try ddnsCancellationAfterSubmissionResult(
                    operation: operation,
                    prefix: prefix
                )
            }
            if ddnsSubmissionIsAmbiguous(error.category) {
                return try ddnsUnverifiedResult(
                    operation: operation,
                    prefix: prefix,
                    category: error.category,
                    diagnosticTag: "\(prefix).submission-unverified"
                )
            }
            return try ddnsRejectedResult(
                error,
                operation: operation,
                prefix: prefix,
                submitted: true
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).submission-unknown"
            )
        }
        if Task.isCancelled {
            return try ddnsCancellationAfterSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        do {
            _ = try await loadDDNS()
            return try ddnsMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                localizationKey: "\(prefix).completed",
                diagnosticTag: "\(prefix).accepted-and-reloaded"
            )
        } catch let error as AppError {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                category: error.category,
                diagnosticTag: "\(prefix).readback-unverified"
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private var ddnsCapabilitiesAreAvailable: Bool {
        capabilitySupports(DsmAPIName.coreDDNSProvider, version: 1)
            && capabilitySupports(DsmAPIName.coreDDNSRecord, version: 1)
    }

    private func ddnsSaveSubmissionFailureResult(
        _ submissionError: AppError,
        draft: NasDDNSDraft,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled {
            return try ddnsCancellationAfterSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        let ambiguous = ddnsSubmissionIsAmbiguous(submissionError.category)
        do {
            let verified = try await loadDDNS()
            let result = try ddnsSavedRecordResult(
                directory: verified,
                draft: draft,
                operation: operation,
                prefix: prefix,
                treatsMismatchAsUnknown: ambiguous
            )
            if result.status == .confirmedSuccess || ambiguous {
                return result
            }
        } catch {
            if ambiguous {
                return try ddnsUnverifiedResult(
                    operation: operation,
                    prefix: prefix,
                    category: submissionError.category,
                    diagnosticTag: "\(prefix).readback-unverified"
                )
            }
        }
        return try ddnsRejectedResult(
            submissionError,
            operation: operation,
            prefix: prefix,
            submitted: true
        )
    }

    private func ddnsSaveUnknownSubmissionResult(
        draft: NasDDNSDraft,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadDDNS()
            return try ddnsSavedRecordResult(
                directory: verified,
                draft: draft,
                operation: operation,
                prefix: prefix,
                treatsMismatchAsUnknown: true
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).submission-unknown"
            )
        }
    }

    private func ddnsDeleteSubmissionFailureResult(
        _ submissionError: AppError,
        providerID: String,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled {
            return try ddnsCancellationAfterSubmissionResult(
                operation: operation,
                prefix: prefix
            )
        }
        let ambiguous = ddnsSubmissionIsAmbiguous(submissionError.category)
        do {
            let verified = try await loadDDNS()
            let result = try ddnsDeletedRecordResult(
                directory: verified,
                providerID: providerID,
                operation: operation,
                prefix: prefix,
                treatsPresenceAsUnknown: ambiguous
            )
            if result.status == .confirmedSuccess || ambiguous {
                return result
            }
        } catch {
            if ambiguous {
                return try ddnsUnverifiedResult(
                    operation: operation,
                    prefix: prefix,
                    category: submissionError.category,
                    diagnosticTag: "\(prefix).readback-unverified"
                )
            }
        }
        return try ddnsRejectedResult(
            submissionError,
            operation: operation,
            prefix: prefix,
            submitted: true
        )
    }

    private func ddnsDeleteUnknownSubmissionResult(
        providerID: String,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadDDNS()
            return try ddnsDeletedRecordResult(
                directory: verified,
                providerID: providerID,
                operation: operation,
                prefix: prefix,
                treatsPresenceAsUnknown: true
            )
        } catch {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).submission-unknown"
            )
        }
    }

    private func ddnsSavedRecordResult(
        directory: NasDDNSDirectory,
        draft: NasDDNSDraft,
        operation: String,
        prefix: String,
        treatsMismatchAsUnknown: Bool
    ) throws -> MutationResult {
        if let record = directory.records.first(where: {
            $0.providerID == draft.normalizedProviderID
        }), Self.ddnsRecord(record, matches: draft) {
            return try ddnsMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                localizationKey: "\(prefix).completed",
                diagnosticTag: "\(prefix).readback-confirmed"
            )
        }
        if treatsMismatchAsUnknown {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).readback-mismatch"
            )
        }
        return try ddnsMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-mismatch"
        )
    }

    private func ddnsDeletedRecordResult(
        directory: NasDDNSDirectory,
        providerID: String,
        operation: String,
        prefix: String,
        treatsPresenceAsUnknown: Bool
    ) throws -> MutationResult {
        if !directory.records.contains(where: { $0.providerID == providerID }) {
            return try ddnsMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                localizationKey: "\(prefix).completed",
                diagnosticTag: "\(prefix).readback-confirmed"
            )
        }
        if treatsPresenceAsUnknown {
            return try ddnsUnverifiedResult(
                operation: operation,
                prefix: prefix,
                diagnosticTag: "\(prefix).readback-still-present"
            )
        }
        return try ddnsMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: true,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).readback-still-present"
        )
    }

    private static func ddnsRecord(
        _ actual: NasDDNSRecord,
        matches expected: NasDDNSDraft
    ) -> Bool {
        actual.providerID == expected.normalizedProviderID
            && actual.hostname.lowercased() == expected.normalizedHostname
            && actual.username == expected.normalizedUsername
            && actual.isEnabled == expected.isEnabled
            && actual.heartbeat == expected.heartbeat
    }

    private func ddnsSubmissionIsAmbiguous(
        _ category: AppErrorCategory
    ) -> Bool {
        switch category {
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            true
        default:
            false
        }
    }

    private func ddnsCancelledBeforeSubmissionResult(
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .cancelledBeforeSubmission,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 0,
            unknown: 0,
            localizationKey: "\(prefix).cancelled",
            diagnosticTag: "\(prefix).cancelled-before-submission"
        )
    }

    private func ddnsCancellationAfterSubmissionResult(
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .cancellationRequestedAfterSubmission,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: .unknown,
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).cancelled-after-submission"
        )
    }

    private func ddnsInvalidResult(
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .validation,
            localizationKey: "\(prefix).invalid",
            diagnosticTag: "\(prefix).invalid-input"
        )
    }

    private func ddnsConflictResult(
        operation: String,
        prefix: String,
        diagnosticTag: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "\(prefix).failed",
            diagnosticTag: diagnosticTag
        )
    }

    private func ddnsBusyResult(
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .conflict,
            localizationKey: "ddns.operation.busy",
            diagnosticTag: "\(prefix).duplicate-submission"
        )
    }

    private func ddnsUnsupportedResult(
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .unsupported,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .unsupported,
            localizationKey: "ddns.operation.unsupported",
            diagnosticTag: "\(prefix).unsupported"
        )
    }

    private func ddnsUnknownPreflightResult(
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .confirmedFailure,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: .unknown,
            localizationKey: "\(prefix).failed",
            diagnosticTag: "\(prefix).preflight-unknown"
        )
    }

    private func ddnsUnverifiedResult(
        operation: String,
        prefix: String,
        category: AppErrorCategory? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try ddnsMutationResult(
            status: .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: category.map {
                packageMutationErrorCategory(for: $0)
            },
            localizationKey: "\(prefix).unverified",
            diagnosticTag: diagnosticTag
        )
    }

    private func ddnsRejectedResult(
        _ error: AppError,
        operation: String,
        prefix: String,
        submitted: Bool
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        let category: MutationErrorCategory
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "ddns.operation.permission-denied"
            category = .permission
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "ddns.operation.unsupported"
            category = .unsupported
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
            category = packageMutationErrorCategory(for: error.category)
        }
        return try ddnsMutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: category,
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).rejected"
        )
    }

    private func ddnsMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func ddnsOperationError(
        for result: MutationResult,
        fallbackKey: String
    ) -> AppError {
        let category: AppErrorCategory = switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
        return AppError(
            category: category,
            isRetryable: false,
            safeUserMessage: L10n.string(
                result.localizationKey ?? fallbackKey
            )
        )
    }

    public func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot {
        let value = try await call(
            DsmAPIName.coreSystemUtilization,
            method: "get",
            parameters: [
                "resource": .string("all"),
                "type": .string("current")
            ]
        )
        let cpu = value["cpu"] ?? .object([:])
        let memory = value["memory"] ?? .object([:])
        let networkRows = value.objects("network")
        let totalNetwork = networkRows.first {
            DsmDynamicJSON.object($0).string(["device"])?.lowercased() == "total"
        }.map(DsmDynamicJSON.object) ?? .object([:])
        let diskTotal = value["disk"]?["total"] ?? .object([:])
        let volumeTotal = value["space"]?["total"] ?? .object([:])
        let nfsRows = value.objects("nfs").map(DsmDynamicJSON.object)
        let userCPU = cpu.number(["user_load"]) ?? 0
        let systemCPU = cpu.number(["system_load"]) ?? 0
        let otherCPU = cpu.number(["other_load"]) ?? 0
        let timestamp = value.number(["time"]).map(Date.init(timeIntervalSince1970:)) ?? Date()

        return NasPerformanceSnapshot(
            recordedAt: timestamp,
            cpuUsage: Self.percent(userCPU + systemCPU + otherCPU),
            cpuUserUsage: Self.percent(userCPU),
            cpuSystemUsage: Self.percent(systemCPU),
            cpuOtherUsage: Self.percent(otherCPU),
            memoryUsage: Self.percent(memory.number(["real_usage"]) ?? 0),
            swapUsage: Self.percent(memory.number(["swap_usage"]) ?? 0),
            networkReceivedBytesPerSecond: totalNetwork.integer(["rx"]) ?? 0,
            networkSentBytesPerSecond: totalNetwork.integer(["tx"]) ?? 0,
            diskReadBytesPerSecond: diskTotal.integer(["read_byte"]) ?? 0,
            diskWriteBytesPerSecond: diskTotal.integer(["write_byte"]) ?? 0,
            volumeReadBytesPerSecond: volumeTotal.integer(["read_byte"]) ?? 0,
            volumeWriteBytesPerSecond: volumeTotal.integer(["write_byte"]) ?? 0,
            diskUtilization: Self.percent(diskTotal.number(["utilization"]) ?? 0),
            nfsReadOperationsPerSecond: nfsRows.reduce(0) { $0 + ($1.integer(["read_OPS"]) ?? 0) },
            nfsWriteOperationsPerSecond: nfsRows.reduce(0) { $0 + ($1.integer(["write_OPS"]) ?? 0) }
        )
    }

    public func loadSystemProcesses(
        start: Int,
        limit: Int
    ) async throws -> NasProcessDirectory {
        let safeStart = max(0, start)
        let safeLimit = min(500, max(1, limit))
        let processValue = try await call(
            DsmAPIName.coreSystemProcess,
            method: "list",
            parameters: [
                "start": .integer(safeStart),
                "limit": .integer(safeLimit)
            ]
        )
        let primaryProcessRows = processValue.objects("processes")
        let processRows = primaryProcessRows.isEmpty
            ? processValue.objects("items")
            : primaryProcessRows
        var seenProcessIDs = Set<String>()
        let processes = processRows.compactMap { raw -> NasSystemProcess? in
            let item = DsmDynamicJSON.object(raw)
            guard let processID = Self.safeProcessID(
                item.string(["pid", "process_id"])
            ),
            let name = Self.safeProcessDisplayName(
                item.string(["name", "process_name"])
            ) else {
                return nil
            }
            let id = "process:\(processID)"
            guard seenProcessIDs.insert(id).inserted else { return nil }
            return NasSystemProcess(
                id: id,
                processID: processID,
                name: name,
                status: Self.safeProcessText(item.string(["status"]), maximumLength: 80),
                groupID: Self.safeProcessGroupIdentifier(
                    item.string(["group_id", "group", "service"])
                )
            )
        }
        .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame
                ? $0.processID.localizedStandardCompare($1.processID) == .orderedAscending
                : order == .orderedAscending
        }

        var groups: [NasProcessGroup] = []
        var groupsAreUnavailable = !capabilitySupports(
            DsmAPIName.coreSystemProcessGroup,
            version: 1
        )
        if !groupsAreUnavailable {
            do {
                let groupValue = try await call(
                    DsmAPIName.coreSystemProcessGroup,
                    method: "list",
                    version: 1,
                    parameters: [
                        "start": .integer(0),
                        "limit": .integer(safeLimit)
                    ]
                )
                let primaryGroupRows = groupValue.objects("groups")
                let groupRows = primaryGroupRows.isEmpty
                    ? groupValue.objects("items")
                    : primaryGroupRows
                var seenGroupIDs = Set<String>()
                groups = groupRows.compactMap { raw -> NasProcessGroup? in
                    let item = DsmDynamicJSON.object(raw)
                    guard let id = Self.safeProcessGroupIdentifier(
                        item.string(["id", "group_id", "service"])
                    ),
                    seenGroupIDs.insert(id).inserted,
                    let name = Self.safeProcessDisplayName(
                        item.string(["display_name", "name", "service"])
                    ) else {
                        return nil
                    }
                    let count = item.integer(["process_count", "count"]).flatMap {
                        $0 >= 0 && $0 <= 1_000_000 ? Int($0) : nil
                    }
                    return NasProcessGroup(
                        id: id,
                        name: name,
                        status: Self.safeProcessText(
                            item.string(["status"]),
                            maximumLength: 80
                        ),
                        processCount: count
                    )
                }
                .sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppError where error.category == .cancelled {
                throw CancellationError()
            } catch {
                // 服务进程组是可选只读补充，失败不得阻断进程列表。
                groupsAreUnavailable = true
            }
        }

        let reportedTotal = processValue.integer(["total", "total_count"]).flatMap {
            $0 >= 0 && $0 <= 1_000_000 ? Int($0) : nil
        }
        let total = max(processes.count, reportedTotal ?? processes.count)
        return NasProcessDirectory(
            processes: processes,
            groups: groups,
            total: total,
            isTruncated: safeStart + processes.count < total
                || (processes.count == safeLimit && total == processes.count),
            groupsAreUnavailable: groupsAreUnavailable
        )
    }

    public func loadDiskTestStatus(diskID: String) async throws -> NasDiskTestStatus {
        let disk = try await validatedStorageDisk(id: diskID)
        guard disk.supportsSmartTest else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.edb18b7e9cd3b114")
            )
        }
        return try await loadDiskTestStatus(for: disk, includesHistory: true)
    }

    private func loadDiskTestStatus(
        for disk: NasDisk,
        includesHistory: Bool
    ) async throws -> NasDiskTestStatus {
        let value = try await call(
            DsmAPIName.coreStorageDisk,
            method: "get_smart_test_log",
            parameters: ["device": .string(disk.deviceID)]
        )
        let latest = value.objects("testInfo").first.map(DsmDynamicJSON.object)
        let isRunning = latest?.boolean(["testing", "is_testing"]) ?? false
        let isBusyWithOtherTest = !isRunning && (
            latest?.boolean(["ihm_testing"]) == true
                || latest?.boolean(["perf_testing"]) == true
        )
        let rawType = latest?.string(["test_type", "testType", "type"])?.lowercased()
        let runningType: NasDiskTestType?
        if rawType == "quick" {
            runningType = .quick
        } else if rawType == "extend" || rawType == "extended" {
            runningType = .extended
        } else {
            runningType = nil
        }
        let history: DiskTestHistorySnapshot
        if includesHistory {
            history = try await loadDiskTestHistory(for: disk)
            diskTestHistories[disk.id] = history
        } else {
            history = diskTestHistories[disk.id] ?? .unavailable
        }
        return NasDiskTestStatus(
            diskID: disk.id,
            isRunning: isRunning,
            isBusyWithOtherTest: isBusyWithOtherTest,
            runningType: isRunning ? runningType : nil,
            progressDescription: latest?.string(["remain", "progress"]),
            lastQuickTest: history.lastQuickTest,
            lastExtendedTest: history.lastExtendedTest,
            lastResult: latest?.string(["latest_test_result", "result"])
                ?? history.latestResult,
            isHistoryAvailable: history.isAvailable
        )
    }

    private func loadDiskTestHistory(for disk: NasDisk) async throws -> DiskTestHistorySnapshot {
        let value: DsmDynamicJSON
        do {
            value = try await call(
                DsmAPIName.coreStorageDisk,
                method: "disk_test_log_get",
                parameters: [
                    "device": .string(disk.deviceID),
                    "offset": .integer(0),
                    "limit": .integer(100),
                    "sort_by": .string("time"),
                    "sort_direction": .string("DESC"),
                    "type": .string("smart")
                ]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable
        }

        let logs = value.objects("testLog").map(DsmDynamicJSON.object)
        let smartLogs = logs.filter {
            $0.string(["type"])?.lowercased() == "smart"
                || $0.string(["test_type"]) != nil
        }
        let quick = smartLogs.first { $0.string(["test_type"])?.lowercased() == "quick" }
        let extended = smartLogs.first {
            let type = $0.string(["test_type"])?.lowercased()
            return type == "extend" || type == "extended"
        }
        return DiskTestHistorySnapshot(
            lastQuickTest: quick?.string(["time"]),
            lastExtendedTest: extended?.string(["time"]),
            latestResult: smartLogs.first?.string(["result"]),
            isAvailable: true
        )
    }

    public func startDiskTest(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> NasDiskTestStatus {
        let disk = try await validatedStorageDisk(id: diskID)
        guard disk.supportsSmartTest else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.edb18b7e9cd3b114")
            )
        }
        let current = try await loadDiskTestStatus(for: disk, includesHistory: false)
        guard !current.isRunning else {
            throw AppError(
                category: .conflict,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.0eb619b75fdbcff5")
            )
        }
        guard !current.isBusyWithOtherTest else {
            throw AppError(
                category: .conflict,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.b8c5b11d9fc2c1f5")
            )
        }

        try await callVoid(
            DsmAPIName.coreStorageDisk,
            method: "do_smart_test",
            parameters: [
                "device": .string(disk.deviceID),
                "type": .string(type == .quick ? "quick" : "extend")
            ]
        )

        for attempt in 0..<6 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1))
            }
            let verified = try await loadDiskTestStatus(for: disk, includesHistory: false)
            if verified.isRunning {
                return verified
            }
        }
        throw AppError(
            category: .conflict,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.ddef2b60c5d885df")
        )
    }

    public func stopDiskTest(diskID: String) async throws -> NasDiskTestStatus {
        let disk = try await validatedStorageDisk(id: diskID)
        guard disk.supportsSmartTest else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.edb18b7e9cd3b114")
            )
        }
        let current = try await loadDiskTestStatus(for: disk, includesHistory: false)
        guard current.isRunning else {
            return current
        }

        try await callVoid(
            DsmAPIName.coreStorageDisk,
            method: "do_smart_test",
            parameters: [
                "device": .string(disk.deviceID),
                "type": .string("stop")
            ]
        )

        for attempt in 0..<6 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1))
            }
            let verified = try await loadDiskTestStatus(for: disk, includesHistory: false)
            if !verified.isRunning {
                return verified
            }
        }
        throw AppError(
            category: .conflict,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.9681fb468adf10c2")
        )
    }

    public func startDiskTestResult(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> MutationResult {
        try await changeDiskTestResult(
            diskID: diskID,
            type: type,
            shouldBeRunning: true
        )
    }

    public func stopDiskTestResult(diskID: String) async throws -> MutationResult {
        try await changeDiskTestResult(
            diskID: diskID,
            type: nil,
            shouldBeRunning: false
        )
    }

    /// 检测启停在提交或轮询失败时可能已经生效；未知结果必须先回读，不得自动重放。
    private func changeDiskTestResult(
        diskID: String,
        type: NasDiskTestType?,
        shouldBeRunning: Bool
    ) async throws -> MutationResult {
        let operation = shouldBeRunning ? "diskTestStart" : "diskTestStop"
        let prefix = shouldBeRunning
            ? "storage.disk-test.start"
            : "storage.disk-test.stop"
        if Task.isCancelled {
            return try diskTestMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard !diskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try diskTestMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).invalid-disk"
            )
        }
        guard capabilitySupports(DsmAPIName.coreStorageDisk) else {
            return try diskTestMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        guard activeDiskTestIDs.insert(diskID).inserted else {
            return try diskTestMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        defer { activeDiskTestIDs.remove(diskID) }

        let disk: NasDisk
        do {
            disk = try await validatedStorageDisk(id: diskID)
            guard disk.supportsSmartTest else {
                return try diskTestMutationResult(
                    status: .unsupported,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .unsupported,
                    localizationKey: "\(prefix).unsupported",
                    diagnosticTag: "\(prefix).disk-unsupported"
                )
            }
            let current = try await loadDiskTestStatus(
                for: disk,
                includesHistory: false
            )
            if shouldBeRunning {
                guard !current.isRunning, !current.isBusyWithOtherTest else {
                    return try diskTestMutationResult(
                        status: .confirmedFailure,
                        operation: operation,
                        submitted: false,
                        requiresRefresh: false,
                        succeeded: 0,
                        failed: 1,
                        unknown: 0,
                        errorCategory: .conflict,
                        localizationKey: "\(prefix).failed",
                        diagnosticTag: current.isRunning
                            ? "\(prefix).already-running"
                            : "\(prefix).other-test-running"
                    )
                }
            } else {
                guard current.isRunning else {
                    return try diskTestMutationResult(
                        status: .confirmedFailure,
                        operation: operation,
                        submitted: false,
                        requiresRefresh: false,
                        succeeded: 0,
                        failed: 1,
                        unknown: 0,
                        errorCategory: .conflict,
                        localizationKey: "\(prefix).failed",
                        diagnosticTag: "\(prefix).already-stopped"
                    )
                }
            }
        } catch let error as AppError {
            return try diskTestPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try diskTestMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }

        if Task.isCancelled {
            return try diskTestMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        do {
            try await callVoid(
                DsmAPIName.coreStorageDisk,
                method: "do_smart_test",
                parameters: [
                    "device": .string(disk.deviceID),
                    "type": .string(
                        shouldBeRunning
                            ? (type == .quick ? "quick" : "extend")
                            : "stop"
                    )
                ]
            )
        } catch let error as AppError {
            return try await diskTestSubmissionResult(
                error,
                disk: disk,
                shouldBeRunning: shouldBeRunning,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try await diskTestUnknownSubmissionResult(
                disk: disk,
                shouldBeRunning: shouldBeRunning,
                operation: operation,
                prefix: prefix
            )
        }

        if Task.isCancelled {
            return try diskTestMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-after-submission"
            )
        }

        for attempt in 0..<6 {
            do {
                if attempt > 0 {
                    try await Task.sleep(for: .seconds(1))
                }
                let verified = try await loadDiskTestStatus(
                    for: disk,
                    includesHistory: false
                )
                if verified.isRunning == shouldBeRunning {
                    return try diskTestMutationResult(
                        status: .confirmedSuccess,
                        operation: operation,
                        submitted: true,
                        requiresRefresh: false,
                        succeeded: 1,
                        failed: 0,
                        unknown: 0,
                        diagnosticTag: "\(prefix).confirmed"
                    )
                }
            } catch let error as AppError {
                return try diskTestReadbackResult(
                    error,
                    operation: operation,
                    prefix: prefix
                )
            } catch {
                return try diskTestMutationResult(
                    status: Task.isCancelled
                        ? .cancellationRequestedAfterSubmission
                        : .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    errorCategory: .unknown,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).readback-unknown"
                )
            }
        }
        return try diskTestMutationResult(
            status: .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: .conflict,
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).poll-timeout"
        )
    }

    public func controlPackage(id: String, action: NasPackageAction) async throws {
        let result = try await controlPackageResult(id: id, action: action)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw AppError(
                category: packageControlAppErrorCategory(for: result),
                isRetryable: false,
                safeUserMessage: L10n.string(
                    result.localizationKey ?? "package.control.failed"
                )
            )
        }
    }

    /// 套件启动与停止按稳定套件 ID 去重；写请求不自动重放，只通过列表状态确认结果。
    public func controlPackageResult(
        id: String,
        action: NasPackageAction
    ) async throws -> MutationResult {
        if action == .uninstall {
            return try await uninstallPackageResult(id: id)
        }

        let operation: String
        let prefix: String
        let checkType: String
        let method: String
        switch action {
        case .start:
            operation = "packageStart"
            prefix = "package.start"
            checkType = "start_check"
            method = "start"
        case .stop:
            operation = "packageStop"
            prefix = "package.stop"
            checkType = "stop_check"
            method = "stop"
        case .uninstall:
            operation = "packageUninstall"
            prefix = "package.uninstall"
            checkType = "uninstall_check"
            method = "uninstall"
        case .upgrade:
            return try packageMutationResult(
                status: .unsupported,
                operation: "packageUpgrade",
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "package.upgrade.unsupported",
                diagnosticTag: "package.upgrade.unsupported"
            )
        }

        if Task.isCancelled {
            return try packageMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                localizationKey: "package.control.cancelled",
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }

        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "package.control.not-found",
                diagnosticTag: "\(prefix).invalid-id"
            )
        }
        guard capabilities[DsmAPIName.corePackage]?.selectedVersion != nil,
              capabilities[DsmAPIName.corePackageControl]?.selectedVersion != nil else {
            return try packageMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "package.control.unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        guard activePackageMutationIDs.insert(normalizedID).inserted else {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "package.control.busy",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        defer { activePackageMutationIDs.remove(normalizedID) }

        let packages: [NasPackage]
        do {
            packages = try await loadPackages(includingIcons: false)
        } catch let error as AppError {
            return try packageControlPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "package.control.failed",
                diagnosticTag: "\(prefix).list-preflight-unknown"
            )
        }
        guard let package = packages.first(where: { $0.id == normalizedID }) else {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "package.control.not-found",
                diagnosticTag: "\(prefix).not-found"
            )
        }
        let isAvailable = action == .start ? package.canStart : package.canStop
        guard isAvailable else {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).unavailable",
                diagnosticTag: "\(prefix).state-rejected"
            )
        }

        do {
            try await callVoid(
                DsmAPIName.corePackage,
                method: "feasibility_check",
                parameters: [
                    "type": .string(checkType),
                    "packages": .stringArray([normalizedID])
                ]
            )
        } catch let error as AppError {
            return try packageControlPreflightResult(
                error,
                operation: operation,
                prefix: prefix
            )
        }

        if Task.isCancelled {
            return try packageMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                localizationKey: "package.control.cancelled",
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        var parameters: [String: DsmParameterValue] = [
            "id": .string(normalizedID)
        ]
        if action == .start {
            parameters["dsm_apps"] = .stringArray(
                packageControlMetadata[normalizedID]?.dsmApps ?? []
            )
        }
        do {
            try await callVoid(
                DsmAPIName.corePackageControl,
                method: method,
                parameters: parameters
            )
        } catch let error as AppError {
            if packageControlSubmissionMayBeAmbiguous(error.category) {
                return try await reconcilePackageControlAfterAmbiguousSubmission(
                    id: normalizedID,
                    action: action,
                    operation: operation,
                    prefix: prefix,
                    submissionError: error
                )
            }
            return try packageControlSubmissionResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try packageMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submission-unknown"
            )
        }

        return try await pollPackageControlState(
            id: normalizedID,
            action: action,
            operation: operation,
            prefix: prefix,
            maximumAttempts: 10
        )
    }

    /// 套件卸载属于破坏性操作；请求提交后必须通过套件列表回读确认，未知结果不得自动重放。
    public func uninstallPackageResult(id: String) async throws -> MutationResult {
        let operation = "packageUninstall"
        if Task.isCancelled {
            return try packageMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "package.uninstall.cancelled-before-submission"
            )
        }

        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "package.uninstall.failed",
                diagnosticTag: "package.uninstall.invalid-input"
            )
        }
        guard capabilities[DsmAPIName.corePackage]?.selectedVersion != nil,
              capabilities[DsmAPIName.corePackageUninstallation]?.selectedVersion != nil else {
            return try packageMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "package.uninstall.unsupported",
                diagnosticTag: "package.uninstall.unsupported"
            )
        }
        guard activePackageMutationIDs.insert(normalizedID).inserted else {
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "package.uninstall.failed",
                diagnosticTag: "package.uninstall.duplicate-submission"
            )
        }
        defer { activePackageMutationIDs.remove(normalizedID) }

        do {
            try await callVoid(
                DsmAPIName.corePackage,
                method: "feasibility_check",
                parameters: [
                    "type": .string("uninstall_check"),
                    "packages": .stringArray([normalizedID]),
                ]
            )
        } catch let error as AppError {
            return try packagePreflightResult(
                error,
                operation: operation,
                prefix: "package.uninstall"
            )
        }

        if Task.isCancelled {
            return try packageMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "package.uninstall.cancelled-after-preflight"
            )
        }

        do {
            try await callVoid(
                DsmAPIName.corePackageUninstallation,
                method: "uninstall",
                parameters: [
                    "id": .string(normalizedID),
                    "dsm_apps": .stringArray(
                        packageControlMetadata[normalizedID]?.dsmApps ?? []
                    ),
                ]
            )
        } catch let error as AppError {
            return try packageSubmissionResult(
                error,
                operation: operation,
                prefix: "package.uninstall"
            )
        }

        if Task.isCancelled {
            return try packageMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                localizationKey: "package.uninstall.unverified",
                diagnosticTag: "package.uninstall.cancelled-after-submission"
            )
        }

        do {
            let packages = try await loadPackages(includingIcons: false)
            if packages.contains(where: { $0.id == normalizedID }) {
                return try packageMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    localizationKey: "package.uninstall.unverified",
                    diagnosticTag: "package.uninstall.still-listed"
                )
            }
            return try packageMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                diagnosticTag: "package.uninstall.confirmed"
            )
        } catch let error as AppError {
            let status: MutationResultStatus = error.category == .cancelled
                ? .cancellationRequestedAfterSubmission
                : .submittedButUnverified
            return try packageMutationResult(
                status: status,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "package.uninstall.unverified",
                diagnosticTag: "package.uninstall.readback-unverified"
            )
        } catch {
            return try packageMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "package.uninstall.unverified",
                diagnosticTag: "package.uninstall.readback-unknown"
            )
        }
    }

    func powerPreflightFailureResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try powerMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                errorCategory: nil,
                localizationKey: "power.action.cancelled",
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied:
            return try powerMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                errorCategory: .permission,
                localizationKey: "power.action.permission-denied",
                diagnosticTag: "\(prefix).preflight-permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try powerMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                errorCategory: .unsupported,
                localizationKey: "power.action.unsupported",
                diagnosticTag: "\(prefix).preflight-unsupported"
            )
        case .authenticationRequired, .otpRequired:
            return try powerMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                errorCategory: .authentication,
                localizationKey: "power.action.session-expired",
                diagnosticTag: "\(prefix).preflight-authentication"
            )
        default:
            return try powerMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "power.action.preflight-failed",
                diagnosticTag: "\(prefix).preflight-failed"
            )
        }
    }

    func powerSubmissionFailureResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try powerMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                errorCategory: .unknown,
                localizationKey: "power.action.unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            return try powerMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "power.action.unverified",
                diagnosticTag: "\(prefix).submitted-unverified"
            )
        case .permissionDenied:
            return try powerMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: true,
                errorCategory: .permission,
                localizationKey: "power.action.permission-denied",
                diagnosticTag: "\(prefix).permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try powerMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: true,
                errorCategory: .unsupported,
                localizationKey: "power.action.unsupported",
                diagnosticTag: "\(prefix).unsupported-response"
            )
        case .authenticationRequired, .otpRequired:
            return try powerMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                errorCategory: .authentication,
                localizationKey: "power.action.session-expired",
                diagnosticTag: "\(prefix).authentication-rejected"
            )
        default:
            return try powerMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "power.action.rejected",
                diagnosticTag: "\(prefix).rejected"
            )
        }
    }

    func powerMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        errorCategory: MutationErrorCategory?,
        localizationKey: String,
        diagnosticTag: String
    ) throws -> MutationResult {
        let isUnknown = status == .submittedButUnverified
            || status == .cancellationRequestedAfterSubmission
        return try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: isUnknown,
            counts: MutationResultCounts(
                succeeded: status == .confirmedSuccess ? 1 : 0,
                failed: [
                    .confirmedFailure,
                    .permissionDenied,
                    .unsupported
                ].contains(status) ? 1 : 0,
                unknown: isUnknown ? 1 : 0
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    func powerAppErrorCategory(
        for result: MutationResult
    ) -> AppErrorCategory {
        switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .partialSuccess:
            .partialFailure
        case .confirmedSuccess, .confirmedFailure, .submittedButUnverified:
            .unknown
        }
    }

    public func checkSystemUpdate() async throws -> NasSystemUpdateInfo {
        func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let system = try await call(
            DsmAPIName.coreSystem,
            method: "info",
            parameters: [:]
        )
        let updateResponse = try await call(
            DsmAPIName.coreUpgradeServer,
            method: "check",
            version: 3,
            parameters: [
                "user_reading": .boolean(true),
                "need_auto_smallupdate": .boolean(true),
                "need_promotion": .boolean(false)
            ]
        )
        let update = updateResponse["update"] ?? .null
        let currentVersion = normalized(system.string(["firmware_ver", "version"]))
        let latestVersion = normalized(update.string(["version"]))
        let releaseNotes = normalized(update.string([
            "release_note",
            "release_notes",
            "whats_new",
            "description"
        ]))
        return NasSystemUpdateInfo(
            isUpdateAvailable: latestVersion != nil && latestVersion != currentVersion,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes
        )
    }

    public func loadScheduledTasks() async throws -> [NasScheduledTask] {
        let value = try await call(
            DsmAPIName.coreTaskScheduler,
            method: "list",
            version: 3,
            parameters: [
                "start": .integer(0),
                "limit": .integer(1_000)
            ]
        )
        return value.objects("tasks").enumerated().compactMap { index, raw in
            let item = DsmDynamicJSON.object(raw)
            guard let name = item.string(["name"]) else { return nil }
            return NasScheduledTask(
                id: item.string(["id"]) ?? "task-\(index)-\(name)",
                name: name,
                owner: item.string(["real_owner", "owner"]),
                realOwner: item.string(["real_owner"]),
                type: item.string(["type"]),
                action: item.string(["action"]),
                isEnabled: item.boolean(["enable"]) ?? false,
                nextTriggerDescription: item.string(["next_trigger_time"]),
                canRun: item.boolean(["can_run"]) ?? false,
                canEdit: item.boolean(["can_edit"]) ?? false
            )
        }
    }

    public func loadScheduledTaskDraft(
        id: Int?,
        realOwner: String?
    ) async throws -> NasScheduledTaskDraft {
        var parameters: [String: DsmParameterValue] = [
            "id": .integer(id ?? -1)
        ]
        if let realOwner, !realOwner.isEmpty {
            parameters["real_owner"] = .string(realOwner)
        }
        if id == nil {
            parameters["type"] = .string("script")
        }
        let value = try await call(
            DsmAPIName.coreTaskScheduler,
            method: "get",
            version: 4,
            parameters: parameters
        )
        let schedule = value["schedule"] ?? .object([:])
        let extra = value["extra"] ?? .object([:])
        return NasScheduledTaskDraft(
            id: id,
            name: value.string(["name"]) ?? "",
            owner: value.string(["owner", "real_owner"]) ?? realOwner ?? "",
            realOwner: value.string(["real_owner"]) ?? realOwner,
            isEnabled: value.boolean(["enable"]) ?? true,
            script: extra.string(["script"]) ?? "",
            notifyOnError: extra.boolean(["notify_if_error"]) ?? false,
            notificationEmails: extra.string(["notify_mail"]) ?? "",
            schedule: NasTaskSchedule(
                dateType: Int(schedule.number(["date_type"]) ?? 0),
                weekDays: schedule.string(["week_day"]) ?? "0,1,2,3,4,5,6",
                date: schedule.string(["date"]),
                repeatDate: Int(schedule.number(["repeat_date"]) ?? 1001),
                monthlyWeek: schedule["monthly_week"]?.array?.compactMap {
                    $0.scalarNumber.map(Int.init)
                } ?? [],
                hour: Int(schedule.number(["hour"]) ?? 0),
                minute: Int(schedule.number(["minute"]) ?? 0),
                repeatHour: Int(schedule.number(["repeat_hour"]) ?? 0),
                repeatMinute: Int(schedule.number(["repeat_min"]) ?? 0),
                lastWorkHour: Int(schedule.number(["last_work_hour"]) ?? 0)
            )
        )
    }

    public func loadScheduledTaskResults(
        taskName: String
    ) async throws -> [NasScheduledTaskResult] {
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.06669846e8a043c1")
            )
        }
        let value = try await call(
            DsmAPIName.coreEventScheduler,
            method: "result_list",
            parameters: ["task_name": .string(name)]
        )
        let rows = value.array ?? value["results"]?.array ?? []
        return Array(rows.compactMap { raw -> NasScheduledTaskResult? in
            guard let resultID = raw.string(["result_id", "id"]) else { return nil }
            let exitInfo = raw["exit_info"] ?? .object([:])
            return NasScheduledTaskResult(
                id: resultID,
                taskName: raw.string(["task_name"]) ?? name,
                startedAt: Self.date(from: raw.string(["start_time"])),
                stoppedAt: Self.date(from: raw.string(["stop_time"])),
                exitType: exitInfo.string(["exit_type"]) ?? raw.string(["exit_type"]),
                exitCode: (
                    exitInfo.integer(["exit_code"])
                        ?? raw.integer(["exit_code"])
                ).map(Int.init),
                triggerEvent: raw.string(["trigger_event"])
            )
        }.reversed())
    }

    public func loadScheduledTaskResultOutput(
        taskName: String,
        resultID: String
    ) async throws -> NasScheduledTaskResultOutput {
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = resultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !identifier.isEmpty else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.e72bfeedb9c72727")
            )
        }
        let value = try await call(
            DsmAPIName.coreEventScheduler,
            method: "result_get_file",
            parameters: [
                "task_name": .string(name),
                "result_id": .string(identifier)
            ]
        )
        return NasScheduledTaskResultOutput(
            command: value.string(["script_in"]),
            output: value.string(["script_out"])
        )
    }

    public func saveScheduledTask(_ draft: NasScheduledTaskDraft) async throws {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOwner = draft.owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedOwner.isEmpty, !draft.script.isEmpty else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.56b9ed2bd4038953")
            )
        }

        var parameters: [String: DsmParameterValue] = [
            "name": .string(trimmedName),
            "owner": .string(trimmedOwner),
            "enable": .boolean(draft.isEnabled),
            "type": .string("script"),
            "schedule": .object(Self.taskScheduleParameters(draft.schedule)),
            "extra": .object([
                "script": .string(draft.script),
                "notify_enable": .boolean(
                    draft.notifyOnError || !draft.notificationEmails.isEmpty
                ),
                "notify_if_error": .boolean(draft.notifyOnError),
                "notify_mail": .string(draft.notificationEmails)
            ])
        ]
        if let id = draft.id {
            parameters["id"] = .integer(id)
        }
        if let realOwner = draft.realOwner, !realOwner.isEmpty {
            parameters["real_owner"] = .string(realOwner)
        }
        try await callVoid(
            DsmAPIName.coreTaskScheduler,
            method: draft.id == nil ? "create" : "set",
            version: 4,
            parameters: parameters
        )
    }

    public func setScheduledTaskEnabled(
        id: Int,
        realOwner: String?,
        enabled: Bool
    ) async throws {
        try await taskCommand(
            method: "set_enable",
            id: id,
            realOwner: realOwner,
            additional: ["enable": .boolean(enabled)]
        )
    }

    public func runScheduledTask(id: Int, realOwner: String?) async throws {
        try await taskCommand(method: "run", id: id, realOwner: realOwner)
    }

    public func deleteScheduledTask(id: Int, realOwner: String?) async throws {
        try await taskCommand(method: "delete", id: id, realOwner: realOwner)
    }

    private func validatedStorageDisk(id: String) async throws -> NasDisk {
        if let disk = storageDisks[id] {
            return disk
        }
        _ = try await loadStorage()
        guard let disk = storageDisks[id] else {
            throw AppError(
                category: .conflict,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.e8513b25080428db")
            )
        }
        return disk
    }

    func call(
        _ name: String,
        method: String,
        version requestedVersion: Int? = nil,
        parameters: [String: DsmParameterValue] = [:]
    ) async throws -> DsmDynamicJSON {
        guard let capability = capabilities[name],
              let selectedVersion = capability.selectedVersion else {
            throw unavailableError()
        }
        let version = requestedVersion ?? selectedVersion
        guard capability.minVersion...capability.maxVersion ~= version else {
            throw unavailableError()
        }
        do {
            return try await client.call(
                path: capability.path,
                api: capability.name,
                version: version,
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: DsmDynamicJSON.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func taskCommand(
        method: String,
        id: Int,
        realOwner: String?,
        additional: [String: DsmParameterValue] = [:]
    ) async throws {
        var parameters = additional
        parameters["id"] = .integer(id)
        if let realOwner, !realOwner.isEmpty {
            parameters["real_owner"] = .string(realOwner)
        }
        try await callVoid(
            DsmAPIName.coreTaskScheduler,
            method: method,
            version: 3,
            parameters: parameters
        )
    }

    private static func taskScheduleParameters(
        _ schedule: NasTaskSchedule
    ) -> [String: DsmJSONValue] {
        var result: [String: DsmJSONValue] = [
            "date_type": .integer(schedule.dateType),
            "week_day": .string(schedule.weekDays),
            "repeat_date": .integer(schedule.repeatDate),
            "monthly_week": .array(schedule.monthlyWeek.map(DsmJSONValue.integer)),
            "hour": .integer(schedule.hour),
            "minute": .integer(schedule.minute),
            "repeat_hour": .integer(schedule.repeatHour),
            "repeat_min": .integer(schedule.repeatMinute),
            "last_work_hour": .integer(schedule.lastWorkHour),
            "repeat_min_store_config": .array([1, 5, 10, 15, 20, 30].map(DsmJSONValue.integer)),
            "repeat_hour_store_config": .array(
                Array(1...23).map(DsmJSONValue.integer)
            )
        ]
        if let date = schedule.date, !date.isEmpty {
            result["date"] = .string(date)
        }
        return result
    }

    func callVoid(
        _ name: String,
        method: String,
        version requestedVersion: Int? = nil,
        parameters: [String: DsmParameterValue] = [:]
    ) async throws {
        guard let capability = capabilities[name],
              let selectedVersion = capability.selectedVersion else {
            throw unavailableError()
        }
        let version = requestedVersion ?? selectedVersion
        guard capability.minVersion...capability.maxVersion ~= version else {
            throw unavailableError()
        }
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: version,
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private static func validateEthernetInterface(
        _ interface: NasEthernetInterface
    ) throws {
        guard interface.id.hasPrefix("eth"),
              interface.id.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
                  ).contains($0)
              }) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.e08a7f16a91c9932")
            )
        }
        guard (576...9_000).contains(interface.mtu) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.bd04fc72d0e308c0")
            )
        }
        if interface.isVLANEnabled {
            guard let vlanID = interface.vlanID, (1...4_094).contains(vlanID) else {
                throw AppError(
                    category: .invalidResponse,
                    isRetryable: true,
                    safeUserMessage: L10n.string("shared.e5be64194f7d7959")
                )
            }
        }
        if !interface.usesDHCP {
            guard Self.isValidIPv4(interface.address),
                  Self.isValidIPv4(interface.subnetMask),
                  interface.gateway.isEmpty || Self.isValidIPv4(interface.gateway) else {
                throw AppError(
                    category: .invalidResponse,
                    isRetryable: true,
                    safeUserMessage: L10n.string("shared.e4338b64530bcbcc")
                )
            }
        }
    }

    private static func ethernetConfiguration(
        _ interface: NasEthernetInterface
    ) -> [String: DsmJSONValue] {
        var config: [String: DsmJSONValue] = [
            "ifname": .string(interface.id),
            "use_dhcp": .boolean(interface.usesDHCP),
            "is_default_gateway": .boolean(interface.isDefaultGateway),
            "mtu": .integer(interface.mtu),
            "enable_vlan": .boolean(interface.isVLANEnabled)
        ]
        if !interface.usesDHCP {
            config["ip"] = .string(interface.address)
            config["mask"] = .string(interface.subnetMask)
            config["gateway"] = .string(interface.gateway)
            config["dns"] = .string(interface.dnsServers)
        }
        if interface.isVLANEnabled, let vlanID = interface.vlanID {
            config["vlan_id"] = .integer(vlanID)
        }
        return config
    }

    private func diskTestPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try diskTestMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied, .authenticationRequired:
            return try diskTestMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).preflight-permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try diskTestMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).preflight-unsupported"
            )
        default:
            return try diskTestMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-failed"
            )
        }
    }

    private func diskTestSubmissionResult(
        _ error: AppError,
        disk: NasDisk,
        shouldBeRunning: Bool,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try diskTestMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-during-submission"
            )
        case .permissionDenied, .authenticationRequired:
            return try diskTestMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try diskTestMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported-response"
            )
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            do {
                let verified = try await loadDiskTestStatus(
                    for: disk,
                    includesHistory: false
                )
                if verified.isRunning == shouldBeRunning {
                    return try diskTestMutationResult(
                        status: .confirmedSuccess,
                        operation: operation,
                        submitted: true,
                        requiresRefresh: false,
                        succeeded: 1,
                        failed: 0,
                        unknown: 0,
                        diagnosticTag: "\(prefix).confirmed-after-submit-error"
                    )
                }
            } catch {
                // 回读失败仍保持未知，不使用原请求自动重放。
            }
            return try diskTestMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unverified"
            )
        default:
            return try diskTestMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).rejected"
            )
        }
    }

    private func diskTestUnknownSubmissionResult(
        disk: NasDisk,
        shouldBeRunning: Bool,
        operation: String,
        prefix: String
    ) async throws -> MutationResult {
        do {
            let verified = try await loadDiskTestStatus(
                for: disk,
                includesHistory: false
            )
            if verified.isRunning == shouldBeRunning {
                return try diskTestMutationResult(
                    status: .confirmedSuccess,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: false,
                    succeeded: 1,
                    failed: 0,
                    unknown: 0,
                    diagnosticTag: "\(prefix).confirmed-after-unknown-response"
                )
            }
        } catch {
            // 回读失败仍保持未知，不使用原请求自动重放。
        }
        return try diskTestMutationResult(
            status: .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: .unknown,
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).submitted-unknown"
        )
    }

    private func diskTestReadbackResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try diskTestMutationResult(
            status: error.category == .cancelled
                ? .cancellationRequestedAfterSubmission
                : .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: packageMutationErrorCategory(for: error.category),
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).readback-unverified"
        )
    }

    private func diskTestMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func ethernetPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try ethernetMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied, .authenticationRequired:
            return try ethernetMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).preflight-permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try ethernetMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).preflight-unsupported"
            )
        default:
            return try ethernetMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-failed"
            )
        }
    }

    private func ethernetSubmissionResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            return try ethernetMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try ethernetMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported-response"
            )
        case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            return try ethernetMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unverified"
            )
        default:
            return try ethernetMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).rejected"
            )
        }
    }

    private func ethernetReadbackResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try ethernetMutationResult(
            status: error.category == .cancelled
                ? .cancellationRequestedAfterSubmission
                : .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: packageMutationErrorCategory(for: error.category),
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).readback-unverified"
        )
    }

    private func ethernetMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    func deleteDirectoryEntryResult(
        name: String,
        kind: NasAccount.Kind,
        protectedNames: Set<String>
    ) async throws -> MutationResult {
        let isGroup = kind == .group
        let operation = isGroup ? "groupDelete" : "accountDelete"
        let prefix = isGroup ? "group.delete" : "account.delete"
        let apiName = isGroup ? DsmAPIName.coreGroup : DsmAPIName.coreUser

        if Task.isCancelled {
            return try directoryMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard !trimmed.isEmpty else {
            return try directoryMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .validation,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).invalid-input"
            )
        }
        guard !protectedNames.contains(normalized) else {
            return try directoryMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).protected-entry"
            )
        }
        guard capabilities[apiName]?.selectedVersion != nil,
              capabilities[DsmAPIName.coreUser]?.selectedVersion != nil,
              capabilities[DsmAPIName.coreGroup]?.selectedVersion != nil else {
            return try directoryMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }

        let inserted: Bool
        if isGroup {
            inserted = activeGroupDeletionNames.insert(normalized).inserted
        } else {
            inserted = activeAccountDeletionNames.insert(normalized).inserted
        }
        guard inserted else {
            return try directoryMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .conflict,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).duplicate-submission"
            )
        }
        defer {
            if isGroup {
                activeGroupDeletionNames.remove(normalized)
            } else {
                activeAccountDeletionNames.remove(normalized)
            }
        }

        do {
            let directory = try await loadAccountsAndGroups()
            let entries = isGroup ? directory.groups : directory.users
            guard entries.contains(where: {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else {
                return try directoryMutationResult(
                    status: .confirmedFailure,
                    operation: operation,
                    submitted: false,
                    requiresRefresh: false,
                    succeeded: 0,
                    failed: 1,
                    unknown: 0,
                    errorCategory: .conflict,
                    localizationKey: "\(prefix).failed",
                    diagnosticTag: "\(prefix).target-not-found"
                )
            }
        } catch let error as AppError {
            return try directoryPreflightResult(error, operation: operation, prefix: prefix)
        } catch {
            return try directoryMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unknown,
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }

        if Task.isCancelled {
            return try directoryMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        do {
            try await callVoid(
                apiName,
                method: "delete",
                parameters: ["name": .stringArray([trimmed])]
            )
        } catch let error as AppError {
            return try directorySubmissionResult(error, operation: operation, prefix: prefix)
        } catch {
            return try directoryMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unknown"
            )
        }

        if Task.isCancelled {
            return try directoryMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).cancelled-after-submission"
            )
        }

        do {
            let directory = try await loadAccountsAndGroups()
            let entries = isGroup ? directory.groups : directory.users
            if entries.contains(where: {
                $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return try directoryMutationResult(
                    status: .submittedButUnverified,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: true,
                    succeeded: 0,
                    failed: 0,
                    unknown: 1,
                    localizationKey: "\(prefix).unverified",
                    diagnosticTag: "\(prefix).still-listed"
                )
            }
            return try directoryMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 1,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).confirmed"
            )
        } catch let error as AppError {
            return try directoryReadbackResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try directoryMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: .unknown,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).readback-unknown"
            )
        }
    }

    private func directoryPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try directoryMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied, .authenticationRequired:
            return try directoryMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).preflight-permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try directoryMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).preflight-unsupported"
            )
        default:
            return try directoryMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).preflight-failed"
            )
        }
    }

    private func directorySubmissionResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .permissionDenied, .authenticationRequired:
            return try directoryMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try directoryMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported-response"
            )
        case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            return try directoryMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unverified"
            )
        default:
            return try directoryMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).rejected"
            )
        }
    }

    private func directoryReadbackResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        try directoryMutationResult(
            status: error.category == .cancelled
                ? .cancellationRequestedAfterSubmission
                : .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: packageMutationErrorCategory(for: error.category),
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).readback-unverified"
        )
    }

    private func directoryMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    private func packagePreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        let status: MutationResultStatus
        let localizationKey: String
        switch error.category {
        case .cancelled:
            return try packageMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied, .authenticationRequired:
            status = .permissionDenied
            localizationKey = "\(prefix).permission-denied"
        case .apiUnavailable, .versionUnsupported:
            status = .unsupported
            localizationKey = "\(prefix).unsupported"
        default:
            status = .confirmedFailure
            localizationKey = "\(prefix).failed"
        }
        return try packageMutationResult(
            status: status,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 1,
            unknown: 0,
            errorCategory: packageMutationErrorCategory(for: error.category),
            localizationKey: localizationKey,
            diagnosticTag: "\(prefix).preflight-rejected"
        )
    }

    private func packageSubmissionResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try packageMutationResult(
                status: .cancellationRequestedAfterSubmission,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submission-cancelled"
            )
        case .permissionDenied, .authenticationRequired:
            return try packageMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "\(prefix).permission-denied",
                diagnosticTag: "\(prefix).permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try packageMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "\(prefix).unsupported",
                diagnosticTag: "\(prefix).unsupported-response"
            )
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            return try packageMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unverified"
            )
        default:
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).failed",
                diagnosticTag: "\(prefix).rejected"
            )
        }
    }

    private func packageControlPreflightResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try packageMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 0,
                unknown: 0,
                localizationKey: "package.control.cancelled",
                diagnosticTag: "\(prefix).preflight-cancelled"
            )
        case .permissionDenied:
            return try packageMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "package.control.permission-denied",
                diagnosticTag: "\(prefix).preflight-permission-denied"
            )
        case .authenticationRequired, .otpRequired:
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .authentication,
                localizationKey: "package.control.session-expired",
                diagnosticTag: "\(prefix).preflight-authentication"
            )
        case .apiUnavailable, .versionUnsupported:
            return try packageMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "package.control.unsupported",
                diagnosticTag: "\(prefix).preflight-unsupported"
            )
        default:
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "package.control.failed",
                diagnosticTag: "\(prefix).preflight-failed"
            )
        }
    }

    private func packageControlSubmissionResult(
        _ error: AppError,
        operation: String,
        prefix: String
    ) throws -> MutationResult {
        switch error.category {
        case .permissionDenied:
            return try packageMutationResult(
                status: .permissionDenied,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .permission,
                localizationKey: "package.control.permission-denied",
                diagnosticTag: "\(prefix).permission-denied"
            )
        case .authenticationRequired, .otpRequired:
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .authentication,
                localizationKey: "package.control.session-expired",
                diagnosticTag: "\(prefix).authentication-rejected"
            )
        case .apiUnavailable, .versionUnsupported:
            return try packageMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: .unsupported,
                localizationKey: "package.control.unsupported",
                diagnosticTag: "\(prefix).unsupported-response"
            )
        case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            return try packageMutationResult(
                status: error.category == .cancelled
                    ? .cancellationRequestedAfterSubmission
                    : .submittedButUnverified,
                operation: operation,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: 1,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "\(prefix).unverified",
                diagnosticTag: "\(prefix).submitted-unverified"
            )
        default:
            return try packageMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: 1,
                unknown: 0,
                errorCategory: packageMutationErrorCategory(for: error.category),
                localizationKey: "package.control.failed",
                diagnosticTag: "\(prefix).rejected"
            )
        }
    }

    private func packageControlSubmissionMayBeAmbiguous(
        _ category: AppErrorCategory
    ) -> Bool {
        switch category {
        case .cancelled, .networkUnavailable, .timeout, .serverBusy,
             .invalidResponse, .unknown:
            true
        default:
            false
        }
    }

    private func reconcilePackageControlAfterAmbiguousSubmission(
        id: String,
        action: NasPackageAction,
        operation: String,
        prefix: String,
        submissionError: AppError
    ) async throws -> MutationResult {
        if submissionError.category == .cancelled || Task.isCancelled {
            let readback = await Task.detached {
                try await self.loadPackages(includingIcons: false)
            }.result
            if case let .success(packages) = readback,
               packageControlStateMatches(
                   packages: packages,
                   id: id,
                   action: action
               ) {
                return try packageMutationResult(
                    status: .confirmedSuccess,
                    operation: operation,
                    submitted: true,
                    requiresRefresh: false,
                    succeeded: 1,
                    failed: 0,
                    unknown: 0,
                    localizationKey: "\(prefix).completed",
                    diagnosticTag: "\(prefix).confirmed-after-cancellation"
                )
            }
            return try packageControlSubmissionResult(
                submissionError,
                operation: operation,
                prefix: prefix
            )
        }

        return try await pollPackageControlState(
            id: id,
            action: action,
            operation: operation,
            prefix: prefix,
            maximumAttempts: 3,
            fallbackErrorCategory: packageMutationErrorCategory(
                for: submissionError.category
            )
        )
    }

    private func pollPackageControlState(
        id: String,
        action: NasPackageAction,
        operation: String,
        prefix: String,
        maximumAttempts: Int,
        fallbackErrorCategory: MutationErrorCategory? = nil
    ) async throws -> MutationResult {
        var lastErrorCategory = fallbackErrorCategory
        for attempt in 0..<maximumAttempts {
            do {
                let packages = try await loadPackages(includingIcons: false)
                if packageControlStateMatches(
                    packages: packages,
                    id: id,
                    action: action
                ) {
                    return try packageMutationResult(
                        status: .confirmedSuccess,
                        operation: operation,
                        submitted: true,
                        requiresRefresh: false,
                        succeeded: 1,
                        failed: 0,
                        unknown: 0,
                        localizationKey: "\(prefix).completed",
                        diagnosticTag: "\(prefix).confirmed"
                    )
                }
            } catch let error as AppError {
                if error.category == .cancelled {
                    return try packageMutationResult(
                        status: .cancellationRequestedAfterSubmission,
                        operation: operation,
                        submitted: true,
                        requiresRefresh: true,
                        succeeded: 0,
                        failed: 0,
                        unknown: 1,
                        errorCategory: .unknown,
                        localizationKey: "\(prefix).unverified",
                        diagnosticTag: "\(prefix).readback-cancelled"
                    )
                }
                lastErrorCategory = packageMutationErrorCategory(
                    for: error.category
                )
            } catch {
                lastErrorCategory = .unknown
            }

            if attempt < maximumAttempts - 1 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return try packageMutationResult(
                        status: .cancellationRequestedAfterSubmission,
                        operation: operation,
                        submitted: true,
                        requiresRefresh: true,
                        succeeded: 0,
                        failed: 0,
                        unknown: 1,
                        errorCategory: .unknown,
                        localizationKey: "\(prefix).unverified",
                        diagnosticTag: "\(prefix).poll-cancelled"
                    )
                }
            }
        }

        return try packageMutationResult(
            status: .submittedButUnverified,
            operation: operation,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            errorCategory: lastErrorCategory ?? .conflict,
            localizationKey: "\(prefix).unverified",
            diagnosticTag: "\(prefix).poll-timeout"
        )
    }

    private func packageControlStateMatches(
        packages: [NasPackage],
        id: String,
        action: NasPackageAction
    ) -> Bool {
        guard let package = packages.first(where: { $0.id == id }) else {
            return false
        }
        let status = package.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch action {
        case .start:
            return package.canStop
                || status == "running"
                || status == "active"
        case .stop:
            return package.canStart
                || status == "stopped"
                || status == "inactive"
                || status == "disabled"
        case .uninstall, .upgrade:
            return false
        }
    }

    private func packageControlAppErrorCategory(
        for result: MutationResult
    ) -> AppErrorCategory {
        switch result.status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .cancelledBeforeSubmission, .cancellationRequestedAfterSubmission:
            .cancelled
        case .partialSuccess:
            .partialFailure
        case .confirmedSuccess:
            .unknown
        case .confirmedFailure:
            result.errorCategory == .conflict ? .conflict : .unknown
        case .submittedButUnverified:
            .unknown
        }
    }

    private func packageMutationResult(
        status: MutationResultStatus,
        operation: String,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationKey: String? = nil,
        diagnosticTag: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: localizationKey,
            diagnosticTag: diagnosticTag
        )
    }

    func packageMutationErrorCategory(
        for category: AppErrorCategory
    ) -> MutationErrorCategory {
        switch category {
        case .networkUnavailable, .timeout:
            .network
        case .authenticationRequired, .otpRequired:
            .authentication
        case .permissionDenied:
            .permission
        case .conflict, .notFound, .serverBusy:
            .conflict
        case .apiUnavailable, .versionUnsupported:
            .unsupported
        case .invalidResponse:
            .server
        default:
            .unknown
        }
    }

    func unavailableError() -> AppError {
        AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.45f2d65c5f20a7b9")
        )
    }

    func verificationError(_ message: String) -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: message
        )
    }

    private static func validatePort(_ port: Int) throws {
        guard 1...65_535 ~= port else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.8a6549bde9979b57")
            )
        }
    }

    private static func appendChangedBoolean(
        _ expected: Bool?,
        _ current: Bool?,
        key: String,
        to parameters: inout [String: DsmParameterValue]
    ) {
        if let expected, expected != current {
            parameters[key] = .boolean(expected)
        }
    }

    private static func regionDate(
        date: String?,
        hour: Int?,
        minute: Int?,
        second: Int?
    ) -> Date? {
        guard let date else { return nil }
        let parts = date.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = hour ?? 0
        components.minute = minute ?? 0
        components.second = second ?? 0
        return components.date
    }

    private static func ddnsParameters(
        _ draft: NasDDNSDraft,
        hostname: String,
        username: String
    ) -> [String: DsmParameterValue] {
        var result: [String: DsmParameterValue] = [
            "enable": .boolean(draft.isEnabled),
            "provider": .string(draft.providerID),
            "hostname": .string(hostname),
            "username": .string(username),
            "net": .string(draft.networkType),
            "ip": .string(draft.ipv4),
            "ipv6": .string(draft.ipv6),
            "interface_v4": .string(draft.interfaceV4),
            "interface_v6": .string(draft.interfaceV6),
            "heartbeat": .boolean(draft.heartbeat)
        ]
        if let original = draft.originalProviderID {
            result["id"] = .string(original)
        }
        if draft.providerID == "Synology" {
            result["passwd"] = .string("Synology")
        } else if !draft.password.isEmpty {
            result["passwd"] = .string(draft.password)
        }
        return result
    }

    private static func upsSettings(from value: DsmDynamicJSON?) -> NasUPSSettings? {
        guard let value,
              let enabled = value.boolean(["enable"]),
              let mode = value.string(["mode"]),
              ["USB", "SNMP", "SLAVE"].contains(mode) else {
            return nil
        }
        return NasUPSSettings(
            isEnabled: enabled,
            mode: mode,
            safeModeDelaySeconds: value.number(["delay_time"]).map(Int.init),
            waitsUntilLowBattery: value.boolean(["ups_set_safemode_until_lowbatt"]),
            shutsDownUPSAfterSafeMode: value.boolean(["shutdown_device"]),
            networkServerAddress: value.string(["net_server_ip"]),
            snmpServerAddress: value.string(["snmp_server_ip"])
        )
    }

    private static func upsSettings(
        _ actual: NasUPSSettings?,
        match expected: NasUPSSettings?
    ) -> Bool {
        guard let expected else { return true }
        guard let actual else { return false }
        return actual.isEnabled == expected.isEnabled
            && actual.mode == expected.mode
            && actual.safeModeDelaySeconds == expected.safeModeDelaySeconds
            && actual.waitsUntilLowBattery == expected.waitsUntilLowBattery
            && actual.shutsDownUPSAfterSafeMode == expected.shutsDownUPSAfterSafeMode
            && normalizedOptionalText(actual.networkServerAddress)
                == normalizedOptionalText(expected.networkServerAddress)
            && normalizedOptionalText(actual.snmpServerAddress)
                == normalizedOptionalText(expected.snmpServerAddress)
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func ethernetInterface(
        from value: DsmDynamicJSON,
        fallback: [String: DsmDynamicJSON],
        id: String
    ) -> NasEthernetInterface? {
        let prefix = "ethernet_"
        func field(_ name: String) -> DsmDynamicJSON? {
            value[name] ?? value[prefix + name] ?? fallback[name] ?? fallback[prefix + name]
        }
        guard let usesDHCP = field("use_dhcp")?.scalarBoolean else { return nil }
        let displayName = field("title")?.scalarString
            ?? field("display")?.scalarString
            ?? id
        return NasEthernetInterface(
            id: id,
            displayName: displayName,
            status: field("status")?.scalarString,
            usesDHCP: usesDHCP,
            address: field("ip")?.scalarString ?? "",
            subnetMask: field("mask")?.scalarString ?? "",
            gateway: field("gateway")?.scalarString ?? "",
            dnsServers: field("dns")?.scalarString ?? "",
            isDefaultGateway: field("is_default_gateway")?.scalarBoolean ?? false,
            mtu: Int(field("mtu")?.scalarNumber
                ?? field("mtu_config")?.scalarNumber
                ?? 1_500),
            isVLANEnabled: field("enable_vlan")?.scalarBoolean ?? false,
            vlanID: field("vlan_id")?.scalarNumber.map(Int.init)
        )
    }

    private static func ethernetInterface(
        _ actual: NasEthernetInterface,
        matches expected: NasEthernetInterface
    ) -> Bool {
        actual.id == expected.id
            && actual.usesDHCP == expected.usesDHCP
            && (expected.usesDHCP || actual.address == expected.address)
            && (expected.usesDHCP || actual.subnetMask == expected.subnetMask)
            && (expected.usesDHCP || actual.gateway == expected.gateway)
            && (expected.usesDHCP || actual.dnsServers == expected.dnsServers)
            && actual.isDefaultGateway == expected.isDefaultGateway
            && actual.mtu == expected.mtu
            && actual.isVLANEnabled == expected.isVLANEnabled
            && (!expected.isVLANEnabled || actual.vlanID == expected.vlanID)
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let number = Int(part), (0...255).contains(number) else {
                return false
            }
            return String(number) == part || part == "0"
        }
    }

    static func package(_ package: NasPackage, iconData: Data?) -> NasPackage {
        NasPackage(
            id: package.id,
            name: package.name,
            version: package.version,
            status: package.status,
            statusDescription: package.statusDescription,
            packageDescription: package.packageDescription,
            installType: package.installType,
            installedAt: package.installedAt,
            iconData: iconData,
            canStart: package.canStart,
            canStop: package.canStop,
            canUninstall: package.canUninstall,
            isUpgradeAvailable: package.isUpgradeAvailable,
            canUpgrade: package.canUpgrade
        )
    }

    static func packageIconCacheKey(_ package: NasPackage) -> String {
        "\(package.id)|\(package.version ?? "")"
    }

    static func loadPackageIcon(
        package: NasPackage,
        capability: ApiCapability,
        version: Int,
        baseURL: URL,
        credential: DsmSessionCredential,
        transport: any DsmHTTPTransport
    ) async -> Data? {
        guard let request = try? DsmRequestBuilder.build(
            baseURL: baseURL,
            path: capability.path,
            api: capability.name,
            version: version,
            method: "get",
            requestFormat: capability.requestFormat,
            parameters: [
                "name": .string(package.id),
                "ver": .string(package.version ?? ""),
                "size": .integer(128)
            ],
            credential: nil,
            httpMethod: "GET"
        ) else { return nil }
        var imageRequest = request
        imageRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        if let cookie = credential.cookieHeaderValue {
            imageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            imageRequest.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        guard let response = try? await transport.send(imageRequest),
              (200..<300).contains(response.statusCode),
              !response.data.isEmpty,
              response.data.count <= 2 * 1_024 * 1_024 else { return nil }
        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value.lowercased()
        guard contentType?.hasPrefix("image/") == true
                || hasKnownImageSignature(response.data) else {
            return nil
        }
        return response.data
    }

    static func hasKnownImageSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return true
        }
        return false
    }

    private static func percent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func memoryBytes(_ value: Int64) -> Int64 {
        // DSM `ram_size` 当前返回 MiB；保留对未来直接返回字节的兼容。
        value < 1_000_000 ? value * 1_024 * 1_024 : value
    }

    private static func uptimeSeconds(from value: String?) -> Int64? {
        guard let value else { return nil }
        if let seconds = Int64(value) {
            return seconds
        }
        let parts = value.split(separator: ":").compactMap { Int64($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }

    private static func safeProcessID(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 32),
              value.allSatisfy(\.isNumber) else {
            return nil
        }
        return value
    }

    private static func safeProcessGroupIdentifier(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 128),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "._-:")
                  ).contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func safeProcessDisplayName(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 512) else {
            return nil
        }
        let components = value.split { $0 == "/" || $0 == "\\" }
        return safeProcessText(
            components.last.map(String.init) ?? value,
            maximumLength: 160
        )
    }

    private static func safeProcessText(
        _ raw: String?,
        maximumLength: Int
    ) -> String? {
        guard let raw else { return nil }
        let normalized = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumLength))
    }

    private static func safePowerScheduleIdentifier(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 128),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "._-:")
                  ).contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func externalStorageRows(
        from value: DsmDynamicJSON,
        connection: NasExternalStorageConnection
    ) -> [[String: DsmDynamicJSON]] {
        let keys: [String]
        switch connection {
        case .usb:
            keys = ["devices", "items", "storages", "usb_devices"]
        case .eSATA:
            keys = ["devices", "items", "storages", "esata_devices"]
        }
        for key in keys {
            let rows = value.objects(key)
            if !rows.isEmpty { return rows }
        }
        return []
    }

    private static func safeExternalStorageIdentifier(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 128),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "._-:")
                  ).contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func safeExternalStorageName(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 160),
              !value.contains("/"),
              !value.contains("\\") else {
            return nil
        }
        return value
    }

    private static func safeExternalStorageByteCount(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func externalStorageStatus(_ raw: String?) -> NasExternalStorageStatus {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ready", "normal", "healthy", "connected", "mounted", "active":
            return .ready
        case "busy", "in_use", "in-use", "syncing", "checking":
            return .busy
        case "unavailable", "offline", "disconnected", "error", "failed":
            return .unavailable
        default:
            return .unknown
        }
    }

    private static func zramAlgorithm(_ raw: String?) -> NasZRAMAlgorithm {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "lz4", "lz4hc": .lz4
        case "lzo", "lzo-rle", "lzorle": .lzo
        case "zstd": .zstd
        default: .unknown
        }
    }

    private static func safePowerScheduleTimeZone(_ raw: String?) -> String? {
        guard let value = safeProcessText(raw, maximumLength: 128),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "_/+-")
                  ).contains($0)
              }) else {
            return nil
        }
        return value
    }

    private static func powerScheduleAction(_ raw: String?) -> NasPowerScheduleAction {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "startup", "start", "poweron", "power_on", "boot":
            return .startup
        case "shutdown", "stop", "poweroff", "power_off":
            return .shutdown
        case "restart", "reboot":
            return .restart
        default:
            return .unknown
        }
    }

    private static func powerScheduleRecurrence(
        _ item: DsmDynamicJSON
    ) -> NasPowerScheduleRecurrence {
        if let date = powerScheduleDate(item.string(["date", "run_date"])) {
            return .once(date)
        }

        let rawWeekdays = item.strings(["weekdays", "days"])
        let tokens: [String]
        if rawWeekdays.isEmpty {
            tokens = item.string(["weekdays", "days", "repeat"])
                .map {
                    $0.split { character in
                        character == "," || character == " " || character == ";"
                    }.map(String.init)
                } ?? []
        } else {
            tokens = rawWeekdays
        }
        let weekdays = Set(tokens.compactMap(powerScheduleWeekday))
        guard weekdays.count == tokens.count, !weekdays.isEmpty else {
            return .unknown
        }
        if weekdays.count == NasWeekday.allCases.count {
            return .daily
        }
        return .weekly(weekdays.sorted { $0.rawValue < $1.rawValue })
    }

    private static func powerScheduleWeekday(_ raw: String) -> NasWeekday? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mon", "monday": .monday
        case "tue", "tues", "tuesday": .tuesday
        case "wed", "wednesday": .wednesday
        case "thu", "thur", "thurs", "thursday": .thursday
        case "fri", "friday": .friday
        case "sat", "saturday": .saturday
        case "sun", "sunday": .sunday
        default: nil
        }
    }

    private static func powerScheduleDate(_ raw: String?) -> NasPowerScheduleDate? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              (1970...9999).contains(parts[0]),
              (1...12).contains(parts[1]),
              (1...31).contains(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let resolvedDate = components.date else { return nil }
        let resolved = components.calendar?.dateComponents(
            [.year, .month, .day],
            from: resolvedDate
        )
        guard resolved?.year == parts[0],
              resolved?.month == parts[1],
              resolved?.day == parts[2] else {
            return nil
        }
        return NasPowerScheduleDate(year: parts[0], month: parts[1], day: parts[2])
    }

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty, value != "--" else { return nil }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    func cleanPackageStatusDescription(status: String?, rawOrigin: String?, rawDesc: String?) -> String {
        let raw = [rawOrigin, rawDesc].compactMap { $0 }.joined(separator: " ").lowercased()
        if raw.contains("script status is not 0 but the unit is active") {
            return L10n.string("shared.0c1dfe694215dfd3")
        }
        if raw.contains("retrieve from status script") {
            return L10n.string("shared.bef163e84a4d4676")
        }
        if let status = status?.lowercased() {
            if status == "running" || status == "active" { return L10n.string("shared.1f0eb99b7ed094be") }
            if status == "stop" || status == "stopped" { return L10n.string("shared.a8c3698b5b8c485d") }
            if status == "error" || status == "failed" { return L10n.string("shared.65350ffbd5f562ce") }
        }
        if let rawDesc = rawDesc, !rawDesc.isEmpty, !rawDesc.contains("retrieve from status script") {
            return rawDesc
        }
        return L10n.string("shared.1f0eb99b7ed094be")
    }
}
