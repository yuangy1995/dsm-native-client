import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadFileServiceSettings() async throws -> NasFileServiceSettings { try await loadFileServiceSettings(managed: false) }
    public func loadTerminalSettings() async throws -> NasTerminalSettings { try await loadTerminalSettings(managed: false) }
    public func loadProxySettings() async throws -> NasProxySettings { try await loadProxySettings(managed: false) }

    public func loadServiceForManagement(_ kind: NasServiceKind) async throws -> NasServiceSettings {
        switch kind {
        case .fileServices: return .fileServices(try await loadFileServiceSettings(managed: true))
        case .terminal: return .terminal(try await loadTerminalSettings(managed: true))
        case .proxy: return .proxy(try await loadProxySettings(managed: true))
        case .remoteAccess: return .remoteAccess(try await loadRemoteAccessForManagement())
        case .ethernet: return .ethernet(try await loadEthernetForManagement())
        case .security: return .security(try await loadSecuritySettings(managed: true))
        case .hardware: return .hardware(try await loadHardwareSettings(managed: true))
        case .powerSchedule:
            guard serviceVersion(.powerSchedule) != nil else { throw unavailableError() }
            return .powerSchedule(try await loadPowerSchedule())
        case .zram:
            guard serviceVersion(.zram) != nil else { throw unavailableError() }
            let value = try await loadZRAM()
            guard serviceVersion(.rebootRequired) != nil else { return .zram(value, needsReboot: nil) }
            let reboot: Bool?
            do {
                let result = try await call(DsmAPIName.coreHardwareNeedReboot, method: "get", version: 1)
                if case .boolean(let enabled) = result["need_reboot"] { reboot = enabled } else { reboot = nil }
            } catch {
                if error is CancellationError || error is DsmCertificateTrustError { throw error }
                if let value = error as? AppError, [.authenticationRequired, .permissionDenied, .tlsUntrusted, .tlsCertificateChanged, .cancelled].contains(value.category) { throw error }
                // 重启要求读取失败仍显示压缩状态，但不可据此保存。
                reboot = nil
            }
            return .zram(value, needsReboot: reboot)
        }
    }

    private func loadFileServiceSettings(managed: Bool) async throws -> NasFileServiceSettings {
        let smb = try await readServiceStep(.smb, managed: managed)
        let nfs = try await readServiceStep(.nfs, managed: managed)
        let ftp = try await readServiceStep(.ftp, managed: managed)
        let sftp = try await readServiceStep(.sftp, managed: managed)
        let web = try await readServiceStep(.webDiscovery, managed: managed)
        let discovery = try await readServiceStep(.fileDiscovery, managed: managed)
        guard [smb, nfs, ftp, sftp, web, discovery].contains(where: { $0 != nil }) else { throw unavailableError() }
        return try NasFileServiceSettings(
            isSMBEnabled: serviceBoolean(smb, "enable_samba", managed: managed),
            isNFSEnabled: serviceBoolean(nfs, "enable_nfs", managed: managed),
            isFTPEnabled: serviceBoolean(ftp, "enable_ftp", managed: managed),
            isFTPSEnabled: serviceBoolean(ftp, "enable_ftps", managed: managed),
            ftpPort: servicePort(ftp, ["portnum"], managed: managed),
            isSFTPEnabled: serviceBoolean(sftp, "enable", managed: managed),
            sftpPort: servicePort(sftp, ["portnum", "sftp_portnum"], managed: managed),
            isSSDPEnabled: serviceBoolean(web, "enable_ssdp", managed: managed),
            isBonjourEnabled: serviceBoolean(web, "enable_avahi", managed: managed),
            isSMBTimeMachineEnabled: serviceBoolean(discovery, "enable_smb_time_machine", managed: managed))
    }

    private func loadTerminalSettings(managed: Bool) async throws -> NasTerminalSettings {
        guard let value = try await readServiceStep(.terminal, managed: managed) else { throw unavailableError() }
        guard let ssh = try serviceBoolean(value, "enable_ssh", managed: managed),
              let telnet = try serviceBoolean(value, "enable_telnet", managed: managed) else {
            throw verificationError(L10n.string("shared.e53ee9190654879c"))
        }
        return try .init(isSSHEnabled: ssh, isTelnetEnabled: telnet, sshPort: servicePort(value, ["ssh_port"], managed: managed))
    }

    private func loadProxySettings(managed: Bool) async throws -> NasProxySettings {
        guard let value = try await readServiceStep(.proxy, managed: managed) else { throw unavailableError() }
        guard let enabled = try serviceBoolean(value, "enable", managed: managed) else {
            throw verificationError(L10n.string("shared.21598082fdbb7d65"))
        }
        if managed, let host = value["http_host"], host != .null, case .string = host {} else if managed, value["http_host"] != nil, value["http_host"] != .null {
            throw verificationError(L10n.string("shared.21598082fdbb7d65"))
        }
        let result = try NasProxySettings(isEnabled: enabled, host: value.string(["http_host"]) ?? "", port: servicePort(value, ["http_port"], managed: managed))
        guard !managed || result.isValidForSaving else { throw verificationError(L10n.string("shared.21598082fdbb7d65")) }
        return result
    }

    private func readServiceStep(_ step: NasServiceStep, managed: Bool) async throws -> DsmDynamicJSON? {
        let api = serviceAPI(step)
        guard capabilities[api]?.selectedVersion != nil else { return nil }
        let version: Int?
        if managed {
            guard let supported = serviceVersion(step) else { return nil }
            version = supported
        } else { version = step == .webDiscovery ? 2 : nil }
        let value = try await call(api, method: step == .relay ? "get_misc_config" : "get", version: version)
        if managed && value.object == nil { throw verificationError(L10n.string("file-services.settings.failed")) }
        return value
    }

    func serviceBoolean(_ payload: DsmDynamicJSON?, _ key: String, managed: Bool) throws -> Bool? {
        guard managed else { return payload?.boolean([key]) }
        guard let value = payload?[key], value != .null else { return nil }
        switch value {
        case .boolean(let value): return value
        case .number(let value) where value == 0 || value == 1: return value == 1
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "1", "enabled": return true
            case "false", "no", "0", "disabled": return false
            default: break
            }
        default: break
        }
        throw verificationError(L10n.string("file-services.settings.failed"))
    }
    private func servicePort(_ payload: DsmDynamicJSON?, _ keys: [String], managed: Bool) throws -> Int? {
        guard managed else { return payload?.number(keys).map(Int.init) }
        for key in keys {
            guard let value = payload?[key], value != .null else { continue }
            let number: Double?
            switch value { case .number(let value): number = value; case .string(let value): number = Double(value); default: number = nil }
            guard let number, number.isFinite, number.rounded() == number, (1...65_535).contains(number) else {
                throw verificationError(L10n.string("file-services.settings.invalid"))
            }
            return Int(number)
        }
        return nil
    }

    func serviceAPI(_ step: NasServiceStep) -> String {
        switch step {
        case .smb: DsmAPIName.coreFileServiceSMB
        case .nfs: DsmAPIName.coreFileServiceNFS
        case .ftp: DsmAPIName.coreFileServiceFTP
        case .sftp: DsmAPIName.coreFileServiceSFTP
        case .webDiscovery: DsmAPIName.coreWebDSM
        case .fileDiscovery: DsmAPIName.coreFileServiceDiscovery
        case .terminal: DsmAPIName.coreTerminal
        case .proxy: DsmAPIName.coreNetworkProxy
        case .relay: DsmAPIName.coreQuickConnect
        case .routerConfiguration: DsmAPIName.coreQuickConnectUPnP
        case .zram: DsmAPIName.coreHardwareZRAM
        case .rebootRequired: DsmAPIName.coreHardwareNeedReboot
        case .powerSchedule: DsmAPIName.coreHardwarePowerSchedule
        case .ethernet: DsmAPIName.coreNetworkEthernet
        case .autoBlock: DsmAPIName.coreSecurityAutoBlock
        case .denialOfService: DsmAPIName.coreSecurityDoS
        case .firewallNotifications: DsmAPIName.coreSecurityFirewallConf
        case .firewall: DsmAPIName.coreSecurityFirewall
        case .powerRecovery: DsmAPIName.coreHardwarePowerRecovery
        case .ledBrightness, .ledUpdate: DsmAPIName.coreHardwareLEDBrightness
        case .fanMode: DsmAPIName.coreHardwareFanSpeed
        case .beep: DsmAPIName.coreHardwareBeepControl
        case .hibernation: DsmAPIName.coreHardwareHibernation
        case .ups: DsmAPIName.coreExternalDeviceUPS
        }
    }
    func serviceVersion(_ step: NasServiceStep) -> Int? {
        guard let capability = capabilities[serviceAPI(step)], capability.selectedVersion != nil else { return nil }
        if step == .ethernet { return capability.minVersion <= 1 && capability.maxVersion >= 2 ? 1 : nil }
        let version: Int
        switch step { case .smb, .nfs, .terminal: version = min(3, capability.maxVersion); case .webDiscovery, .denialOfService: version = 2; case .relay: version = 3; default: version = 1 }
        return version >= 1 && capability.minVersion <= version && version <= capability.maxVersion ? version : nil
    }

    /// 管理入口绑定原配置；实际写请求与旧入口共用，额外检查点只负责权限与恢复记录。
    public func changeServiceResult(_ change: NasServiceChange,
        checkpoint: @escaping @Sendable (NasServiceCheckpoint) async throws -> Void) async throws -> MutationResult {
        let steps = change.orderedSteps ?? [], total = max(1, steps.count)
        var completed = 0, submitted = false
        func result(_ status: MutationResultStatus, unknown: Int = 0, category: MutationErrorCategory? = nil) throws -> MutationResult {
            try MutationResult(status: status, operation: "serviceSettingsUpdate", submitted: submitted,
                requiresRefresh: unknown > 0 || status == .partialSuccess,
                counts: .init(succeeded: completed, failed: status == .cancelledBeforeSubmission ? 0 : total - completed - unknown, unknown: unknown),
                errorCategory: category, diagnosticTag: "service.change.\(status.rawValue.lowercased())")
        }
        func failure(_ error: Error) throws -> MutationResult {
            if error is DsmCertificateTrustError { throw error }
            if let error = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(error.category) { throw error }
            let category = (error as? AppError)?.category
            let status: MutationResultStatus
            switch category {
            case .permissionDenied, .authenticationRequired: status = .permissionDenied
            case .apiUnavailable, .versionUnsupported: status = .unsupported
            case .cancelled: status = submitted ? .partialSuccess : .cancelledBeforeSubmission
            default: status = error is CancellationError && !submitted ? .cancelledBeforeSubmission : .confirmedFailure
            }
            return try result(completed > 0 ? .partialSuccess : status,
                category: category.map { packageMutationErrorCategory(for: $0) })
        }
        if Task.isCancelled { return try result(.cancelledBeforeSubmission) }
        guard !steps.isEmpty else { return try result(.confirmedFailure, category: .validation) }
        let active: Bool
        switch change.kind { case .fileServices: active = isFileServiceSettingsUpdateActive; case .terminal: active = isTerminalSettingsUpdateActive; case .proxy: active = isProxySettingsUpdateActive; case .remoteAccess: active = isRemoteAccessSettingsUpdateActive
        case .zram: active = isZRAMUpdateActive; case .powerSchedule: active = isPowerScheduleUpdateActive
        case .ethernet: active = isManagedEthernetUpdateActive || !activeEthernetUpdateIDs.isEmpty
        case .security: active = isSecuritySettingsUpdateActive
        case .hardware: active = isHardwareSettingsUpdateActive }
        guard !active else { return try result(.confirmedFailure, category: .conflict) }
        setServiceActive(change.kind, true)
        defer { setServiceActive(change.kind, false) }
        guard steps.allSatisfy({ serviceVersion($0) != nil }) else { return try result(.unsupported, category: .unsupported) }
        let appliesFirewall: Bool
        if case .security(let settings) = change.desired { appliesFirewall = steps.contains(.firewall) && settings.isFirewallEnabled == true } else { appliesFirewall = false }
        if appliesFirewall && !capabilitySupports(DsmAPIName.coreSecurityFirewallProfileApply, version: 1) { return try result(.unsupported, category: .unsupported) }
        var expected = change.original
        for step in steps {
            if Task.isCancelled { return try result(submitted ? .partialSuccess : .cancelledBeforeSubmission) }
            do {
                let current = try await loadServiceForManagement(change.kind)
                guard expected.hasSameConfiguration(as: current) else { return try result(completed > 0 ? .partialSuccess : .confirmedFailure, category: .conflict) }
            } catch { return try failure(error) }
            // 写前/接受回执/回读检查点错误均直接传回，不能把记录失败当作服务端拒绝。
            try await checkpoint(.willSubmit(step))
            submitted = true
            var accepted = false, rejection: Error?, firewallTask: String?
            do {
                let submittedSettings = change.ethernetTarget.map { NasServiceSettings.ethernet([$0]) } ?? change.desired
                if step == .firewall && appliesFirewall, case .security(let value) = submittedSettings, let profile = value.firewallProfileName {
                    firewallTask = try await startManagedFirewallProfile(profile)
                } else {
                    try await submitManagedServiceStep(step, settings: submittedSettings, current: expected, version: serviceVersion(step)!)
                }
                accepted = true
            } catch {
                if error is DsmCertificateTrustError { throw error }
                if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
                switch (error as? AppError)?.category {
                case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, nil: break
                default: rejection = error
                }
            }
            if let rejection {
                try await checkpoint(.rejected(step))
                return try failure(rejection)
            }
            if let firewallTask { try await checkpoint(.firewallTaskStarted(firewallTask)) }
            if accepted { try await checkpoint(.accepted(step)) }
            if Task.isCancelled { return try result(.cancellationRequestedAfterSubmission, unknown: 1) }
            // LED 读取可能只反映暂存亮度。两个写边界各自缺回执时均保留未知，不继续应用。
            if (step == .ledBrightness || step == .ledUpdate) && !accepted {
                return try result(completed > 0 ? .partialSuccess : .submittedButUnverified, unknown: 1)
            }
            if step == .firewall && appliesFirewall {
                // 未拿到回执不能仅凭开关变化认领任务；回执写盘错误也不能被当作网络错误吞掉。
                guard let firewallTask else { return try result(completed > 0 ? .partialSuccess : .submittedButUnverified, unknown: 1) }
                var outcome: Bool?
                do {
                    for attempt in 0..<30 {
                        if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
                        outcome = try await readFirewallApplication(firewallTask)
                        if outcome != nil { break }
                    }
                } catch {
                    if error is DsmCertificateTrustError { throw error }
                    if let value = error as? AppError, [.authenticationRequired, .permissionDenied, .tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
                    return try result(completed > 0 ? .partialSuccess : .submittedButUnverified, unknown: 1)
                }
                guard let outcome else { return try result(completed > 0 ? .partialSuccess : .submittedButUnverified, unknown: 1) }
                try await checkpoint(.firewallTaskFinished(outcome))
                if Task.isCancelled { return try result(.cancellationRequestedAfterSubmission, unknown: 1) }
                try await checkpoint(.willCleanFirewallTask)
                // stop 没有目标参数，仅本次持续执行且已结束的任务可以清理；重启恢复不调用它。
                try await cleanCompletedFirewallTask()
                if !outcome {
                    try await checkpoint(.rejected(step))
                    return try result(completed > 0 ? .partialSuccess : .confirmedFailure, category: .unknown)
                }
            }
            let current: NasServiceSettings
            do { current = try await loadServiceForManagement(change.kind) }
            catch {
                if error is DsmCertificateTrustError { throw error }
                if let value = error as? AppError,
                   [.authenticationRequired, .permissionDenied, .tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
                return try result(completed > 0 ? .partialSuccess : .submittedButUnverified, unknown: 1)
            }
            if change.savedFieldsMatch(current, step: step) {
                try await checkpoint(.verified(step)); completed += 1
                expected = expected.replacing(step, with: change.desired)
                // 其他组被外部修改时，下一组停止；最后一次读取也必须包含全部已写组。
                if completed == steps.count {
                    let matching = steps.filter { change.savedFieldsMatch(current, step: $0) }.count
                    if matching != steps.count {
                        completed = matching
                        return try result(matching > 0 ? .partialSuccess : .confirmedFailure, category: .conflict)
                    }
                }
            } else {
                let partial = change.hasPartialResult(current, step: step)
                if partial { try await checkpoint(.partial(step)) }
                return try result(completed > 0 ? .partialSuccess : .submittedButUnverified, unknown: 1)
            }
        }
        return try result(.confirmedSuccess)
    }

    private func setServiceActive(_ kind: NasServiceKind, _ active: Bool) {
        switch kind { case .fileServices: isFileServiceSettingsUpdateActive = active; case .terminal: isTerminalSettingsUpdateActive = active; case .proxy: isProxySettingsUpdateActive = active; case .remoteAccess: isRemoteAccessSettingsUpdateActive = active
        case .zram: isZRAMUpdateActive = active; case .powerSchedule: isPowerScheduleUpdateActive = active
        case .ethernet: isManagedEthernetUpdateActive = active
        case .security: isSecuritySettingsUpdateActive = active
        case .hardware: isHardwareSettingsUpdateActive = active }
    }
}
