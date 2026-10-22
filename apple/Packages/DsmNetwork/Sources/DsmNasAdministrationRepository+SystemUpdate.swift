import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadSystemUpdateStatus() async throws -> NasSystemUpdateStatus {
        let value = try await call(DsmAPIName.coreUpgrade, method: "basic_status", version: 1)
        switch value.string(["status"]) {
        case "none":
            if let plan = systemUpdateSubmittedPlan, let submittedAt = systemUpdateSubmittedAt {
                let system = try await loadSystemOverview()
                if plan.confirmsCompletion(version: system.version, uptimeSeconds: system.uptimeSeconds, submittedAt: submittedAt) {
                    systemUpdateWasSubmitted = false
                    systemUpdateSubmittedPlan = nil
                    systemUpdateSubmittedAt = nil
                    return .init(phase: .completed, installedVersion: system.version)
                }
            }
            return .init(phase: .idle)
        case "downloading":
            guard value.string(["target"]) == "update" else { return .init(phase: .unknown) }
            let progress = try await call(DsmAPIName.coreUpgradeDownload, method: "progress", version: 2,
                                          parameters: ["need_download_target": .boolean(true)])
            return .init(phase: .downloading, percent: updatePercent(progress))
        case "ready_upgrade":
            return .init(phase: .ready, canInstall: supportsSystemUpdateInstallation &&
                         value["allow_upgrade"] == .boolean(true) && isSmallSystemUpdate(value))
        case "upgrading": return try await loadSystemUpdateProgress()
        default: return .init(phase: .unknown)
        }
    }

    public func downloadSystemUpdate(expectedVersion: String) async throws {
        guard !systemUpdateRequestActive, !systemUpdateWasSubmitted, !isPowerActionActive else { throw updateError(.serverBusy, "system-update.busy") }
        systemUpdateRequestActive = true
        defer { systemUpdateRequestActive = false }
        let info = try await checkSystemUpdate()
        guard info.isUpdateAvailable, info.latestVersion == expectedVersion else { throw updateError(.conflict, "system-update.changed") }
        let status = try await call(DsmAPIName.coreUpgrade, method: "basic_status", version: 1)
        guard status.string(["status"]) == "none", status["allow_upgrade"] == .boolean(true) else { throw updateError(.conflict, "system-update.unavailable") }
        try Task.checkCancellation()
        try await callVoid(DsmAPIName.coreUpgradeDownload, method: "start", version: 2,
                           parameters: ["target": .string("update"), "need_auto_smallupdate": .boolean(true)])
    }

    public func prepareSystemUpdate(expectedVersion: String) async throws -> NasSystemUpdatePlan {
        guard !systemUpdateRequestActive, !systemUpdateWasSubmitted, !isPowerActionActive else { throw updateError(.serverBusy, "system-update.busy") }
        systemUpdateRequestActive = true
        defer { systemUpdateRequestActive = false }
        systemUpdatePlan = nil
        let plan = try await checkedSystemUpdatePlan(expectedVersion: expectedVersion)
        systemUpdatePlan = plan
        return plan
    }

    public func installSystemUpdate(plan: NasSystemUpdatePlan) async throws -> NasSystemUpdateSubmission {
        guard !systemUpdateRequestActive, !systemUpdateWasSubmitted, !isPowerActionActive else { throw updateError(.serverBusy, "system-update.busy") }
        guard systemUpdatePlan == plan else { throw updateError(.conflict, "system-update.changed") }
        systemUpdateRequestActive = true
        systemUpdatePlan = nil
        defer { systemUpdateRequestActive = false }
        let current = try await checkedSystemUpdatePlan(expectedVersion: plan.version)
        guard current.build == plan.build, current.update == plan.update,
              current.requiresNASRestart == plan.requiresNASRestart else { throw updateError(.conflict, "system-update.changed") }
        try Task.checkCancellation()
        // 从可能提交起禁止重放，网络错误不能解释为安装失败。
        systemUpdateWasSubmitted = true
        systemUpdateSubmittedPlan = plan
        systemUpdateSubmittedAt = Date()
        do {
            try await callVoid(DsmAPIName.coreUpgrade, method: "start", version: 1,
                               parameters: ["force": .boolean(true), "type": .string("server")])
            return .accepted
        } catch let error as AppError {
            let explicitRejection = error.dsmCode != nil && [.authenticationRequired, .otpRequired, .permissionDenied,
                .apiUnavailable, .versionUnsupported, .conflict, .serverBusy].contains(error.category)
            if explicitRejection || [.tlsUntrusted, .tlsCertificateChanged].contains(error.category) {
                systemUpdateWasSubmitted = false
                systemUpdateSubmittedPlan = nil
                systemUpdateSubmittedAt = nil
                throw error
            }
            return .uncertain
        } catch let error as DsmCertificateTrustError {
            systemUpdateWasSubmitted = false
            systemUpdateSubmittedPlan = nil
            systemUpdateSubmittedAt = nil
            throw error
        } catch {
            return .uncertain
        }
    }

    public func loadSystemUpdateProgress() async throws -> NasSystemUpdateStatus {
        let progress = try await call(DsmAPIName.coreUpgrade, method: "progress", version: 1)
        return .init(phase: .installing, percent: updatePercent(progress))
    }

    private var supportsSystemUpdateInstallation: Bool {
        // 集群另有角色与故障转移预检，不能借普通单机确认绕过。
        capabilities[DsmAPIName.haUpgrade] == nil && capabilities[DsmAPIName.coreUpgrade]?.selectedVersion != nil
    }

    private func isSmallSystemUpdate(_ value: DsmDynamicJSON) -> Bool {
        value["patch_info"]?.string(["upgradetype"]) == "smallupdate" && value.string(["target"]) == "update"
    }

    private func checkedSystemUpdatePlan(expectedVersion: String) async throws -> NasSystemUpdatePlan {
        guard supportsSystemUpdateInstallation else { throw updateError(.apiUnavailable, "system-update.use-dsm") }
        let info = try await checkSystemUpdate()
        guard info.isUpdateAvailable, info.latestVersion == expectedVersion else { throw updateError(.conflict, "system-update.changed") }
        let value = try await call(DsmAPIName.coreUpgrade, method: "basic_status", version: 1)
        guard value["allow_upgrade"] == .boolean(true), isSmallSystemUpdate(value),
              value.string(["status"]) == "ready_upgrade",
              let patch = value["patch_info"], let build = updateInteger(patch["buildnumber"]),
              let update = updateInteger(patch["smallfixnumber"]) else { throw updateError(.conflict, "system-update.use-dsm") }
        let plan = NasSystemUpdatePlan(version: expectedVersion, build: build, update: update)
        guard plan.matchesTargetPatch else { throw updateError(.conflict, "system-update.changed") }
        let feasibility = try await call(DsmAPIName.coreUpgrade, method: "status", version: 1,
                                         parameters: ["feasibility_check": .boolean(true)])
        guard feasibility["allow_upgrade"] == .boolean(true),
              ["", "none"].contains(feasibility.string(["check_type"]) ?? "") else { throw updateError(.conflict, "system-update.use-dsm") }
        // 官方安装前检查；失败必须原样阻止安装，所有安装均明确提示重启与服务中断。
        let drives = try await call(DsmAPIName.coreUpgrade, method: "check_having_upgradeable_drives", version: 1,
                           parameters: ["upgrade_to": .object(["base": .integer(build), "nano": .integer(update)])])
        return .init(id: plan.id, version: expectedVersion, build: build, update: update,
                     requiresNASRestart: patch.string(["reboot"]) == "now" || drives != .boolean(false))
    }

    private func updateInteger(_ value: DsmDynamicJSON?) -> Int? {
        guard case .number(let number) = value, number.isFinite, number >= 0, number <= Double(Int32.max), number.rounded() == number else { return nil }
        return Int(number)
    }

    private func updatePercent(_ value: DsmDynamicJSON) -> Double? {
        guard case .number(let number) = value["percent"], number.isFinite, (0...100).contains(number) else { return nil }
        return number
    }

    private func updateError(_ category: AppErrorCategory, _ key: String) -> AppError {
        .init(category: category, isRetryable: false, safeUserMessage: L10n.string(key))
    }
}
