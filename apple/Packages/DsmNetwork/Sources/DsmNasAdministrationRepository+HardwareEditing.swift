import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func savePowerScheduleResult(
        _ entries: [NasPowerScheduleEntry], replacing baseline: NasPowerScheduleSnapshot
    ) async throws -> MutationResult {
        guard !isPowerScheduleUpdateActive else { throw hardwareEditingError("nas.edit.busy") }
        guard baseline.canEdit, NasPowerScheduleSnapshot.replacementIsValid(entries) else {
            throw hardwareEditingError("power-schedule.edit.invalid")
        }
        isPowerScheduleUpdateActive = true
        defer { isPowerScheduleUpdateActive = false }
        let current = try await loadPowerSchedule()
        guard current.hasSameSchedule(as: baseline.entries) else {
            throw hardwareEditingError("nas.edit.changed")
        }
        let operation = "powerScheduleSave"
        if current.hasSameSchedule(as: entries) {
            return try hardwareEditingResult(operation, status: .cancelledBeforeSubmission, submitted: false)
        }
        try Task.checkCancellation()
        do {
            try await submitPowerSchedule(entries)
        } catch {
            return try hardwareEditingWriteFailure(operation, error: error)
        }
        // 无论保存响应如何，只有重新读取完整清单才能确认生效。
        guard let actual = try? await loadPowerSchedule(), actual.hasSameSchedule(as: entries) else {
            return try hardwareEditingResult(operation, status: .submittedButUnverified, submitted: true)
        }
        return try hardwareEditingResult(operation, status: .confirmedSuccess, submitted: true)
    }

    public func saveZRAMResult(enabled: Bool, replacing baseline: NasZRAMSnapshot) async throws -> MutationResult {
        guard !isZRAMUpdateActive else { throw hardwareEditingError("nas.edit.busy") }
        guard baseline.isEnabled != nil,
              capabilities[DsmAPIName.coreHardwareNeedReboot]?.selectedVersion == 1 else {
            throw AppError(category: .apiUnavailable, isRetryable: false,
                           safeUserMessage: L10n.string("zram.edit.unavailable"))
        }
        isZRAMUpdateActive = true
        defer { isZRAMUpdateActive = false }
        let current = try await loadZRAM()
        guard current.isEnabled == baseline.isEnabled else { throw hardwareEditingError("nas.edit.changed") }
        let operation = "zramSave"
        if current.isEnabled == enabled {
            return try hardwareEditingResult(operation, status: .cancelledBeforeSubmission, submitted: false)
        }
        let rebootBeforeSave = try await call(DsmAPIName.coreHardwareNeedReboot, method: "get", version: 1)
        guard case .boolean = rebootBeforeSave["need_reboot"] else {
            throw AppError(category: .invalidResponse, isRetryable: true,
                           safeUserMessage: L10n.string("zram.edit.unavailable"))
        }
        try Task.checkCancellation()
        do {
            try await submitZRAM(enabled: enabled)
        } catch {
            return try hardwareEditingWriteFailure(operation, error: error)
        }
        do {
            // 与官方页面一致标记需重启，但绝不附带关机或重启请求。
            try await submitRebootRequired()
            let actual = try await loadZRAM()
            let reboot = try await call(DsmAPIName.coreHardwareNeedReboot, method: "get", version: 1)
            guard actual.isEnabled == enabled, reboot["need_reboot"] == .boolean(true) else {
                return try hardwareEditingResult(operation, status: .submittedButUnverified, submitted: true)
            }
        } catch {
            return try hardwareEditingResult(operation, status: .submittedButUnverified, submitted: true)
        }
        return try hardwareEditingResult(operation, status: .confirmedSuccess, submitted: true)
    }

    func submitPowerSchedule(_ entries: [NasPowerScheduleEntry]) async throws {
        func tasks(_ action: NasPowerScheduleAction) -> DsmParameterValue {
            .objectArray(entries.filter { $0.action == action }.map { entry in
                ["enabled": .boolean(entry.isEnabled == true),
                 "weekdays": .string((entry.scheduledWeekdays ?? []).map(String.init).joined(separator: ",")),
                 "hour": .integer(entry.hour), "min": .integer(entry.minute)]
            })
        }
        try await callVoid(DsmAPIName.coreHardwarePowerSchedule, method: "save", version: 1,
                           parameters: ["poweron_tasks": tasks(.startup), "poweroff_tasks": tasks(.shutdown)])
    }

    func submitZRAM(enabled: Bool) async throws {
        try await callVoid(DsmAPIName.coreHardwareZRAM, method: "set", version: 1, parameters: ["enable_zram": .boolean(enabled)])
    }

    func submitRebootRequired() async throws {
        try await callVoid(DsmAPIName.coreHardwareNeedReboot, method: "set", version: 1)
    }

    private func hardwareEditingError(_ key: String) -> AppError {
        AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string(key))
    }

    private func hardwareEditingWriteFailure(_ operation: String, error: Error) throws -> MutationResult {
        let category = (error as? AppError)?.category
        if category == .permissionDenied || category == .apiUnavailable || category == .authenticationRequired {
            return try hardwareEditingResult(operation,
                status: category == .permissionDenied ? .permissionDenied : .confirmedFailure, submitted: true)
        }
        return try hardwareEditingResult(operation, status: .submittedButUnverified, submitted: true)
    }

    private func hardwareEditingResult(
        _ operation: String, status: MutationResultStatus, submitted: Bool
    ) throws -> MutationResult {
        let key: String
        let category: MutationErrorCategory?
        switch status {
        case .confirmedSuccess, .cancelledBeforeSubmission: key = "nas.edit.saved"; category = nil
        case .permissionDenied: key = "nas.edit.permission-denied"; category = .permission
        case .confirmedFailure: key = "nas.edit.failed"; category = .conflict
        default: key = "nas.edit.unconfirmed"; category = .unknown
        }
        return try powerMutationResult(status: status, operation: operation, submitted: submitted,
                                       errorCategory: category, localizationKey: key, diagnosticTag: "\(operation.lowercased()).\(key)")
    }
}
