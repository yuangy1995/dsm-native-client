import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func performPowerAction(_ action: NasPowerAction) async throws {
        let result = try await performPowerActionResult(action)
        guard result.status == .confirmedSuccess
                || result.status == .cancelledBeforeSubmission else {
            throw AppError(
                category: powerAppErrorCategory(for: result),
                isRetryable: false,
                safeUserMessage: L10n.string(
                    result.localizationKey ?? "power.action.rejected"
                )
            )
        }
    }

    /// 电源请求无法安全回读；明确响应只表示 DSM 已接受，提交阶段断线不得自动重放。
    public func performPowerActionResult(
        _ action: NasPowerAction
    ) async throws -> MutationResult {
        let operation = action == .shutdown ? "nasShutdown" : "nasReboot"
        let prefix = action == .shutdown ? "power.shutdown" : "power.reboot"
        if Task.isCancelled {
            return try powerMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                errorCategory: nil,
                localizationKey: "power.action.cancelled",
                diagnosticTag: "\(prefix).cancelled-before-submission"
            )
        }
        guard capabilities[DsmAPIName.coreSystem]?.selectedVersion != nil else {
            return try powerMutationResult(
                status: .unsupported,
                operation: operation,
                submitted: false,
                errorCategory: .unsupported,
                localizationKey: "power.action.unsupported",
                diagnosticTag: "\(prefix).unsupported"
            )
        }
        guard !isPowerActionActive else {
            return try powerMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                errorCategory: .conflict,
                localizationKey: "power.action.busy",
                diagnosticTag: "\(prefix).duplicate"
            )
        }
        isPowerActionActive = true
        defer { isPowerActionActive = false }

        do {
            _ = try await call(DsmAPIName.coreSystem, method: "info")
        } catch let error as AppError {
            return try powerPreflightFailureResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try powerMutationResult(
                status: .confirmedFailure,
                operation: operation,
                submitted: false,
                errorCategory: .unknown,
                localizationKey: "power.action.preflight-failed",
                diagnosticTag: "\(prefix).preflight-unknown"
            )
        }

        if Task.isCancelled {
            return try powerMutationResult(
                status: .cancelledBeforeSubmission,
                operation: operation,
                submitted: false,
                errorCategory: nil,
                localizationKey: "power.action.cancelled",
                diagnosticTag: "\(prefix).cancelled-after-preflight"
            )
        }

        let method: String
        switch action {
        case .shutdown: method = "shutdown"
        case .reboot: method = "reboot"
        }
        do {
            try await callVoid(
                DsmAPIName.coreSystem,
                method: method,
                parameters: [:]
            )
            return try powerMutationResult(
                status: .confirmedSuccess,
                operation: operation,
                submitted: true,
                errorCategory: nil,
                localizationKey: "\(prefix).accepted",
                diagnosticTag: "\(prefix).accepted"
            )
        } catch let error as AppError {
            return try powerSubmissionFailureResult(
                error,
                operation: operation,
                prefix: prefix
            )
        } catch {
            return try powerMutationResult(
                status: .submittedButUnverified,
                operation: operation,
                submitted: true,
                errorCategory: .unknown,
                localizationKey: "power.action.unverified",
                diagnosticTag: "\(prefix).submission-unknown"
            )
        }
    }
}
