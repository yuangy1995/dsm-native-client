import DsmCore
import Foundation

private actor PackagePreferenceSubmission {
    private(set) var submitted = false
    private(set) var accepted = false
    func record(_ step: NasPackagePreferenceCheckpoint) {
        if step == .willSubmit { submitted = true } else { accepted = true }
    }
}

extension DsmNasAdministrationRepository {
    public func changePackagePreferencesResult(_ change: NasPackagePreferenceChange,
        checkpoint: @escaping @Sendable (NasPackagePreferenceCheckpoint) async throws -> Void) async throws -> MutationResult {
        let operation = switch change.kind { case .settings: "packageSettingsSave"; case .saveSource: "packageSourceSave"; case .removeSource: "packageSourceRemove" }
        func result(_ status: MutationResultStatus, submitted: Bool, category: MutationErrorCategory? = nil) throws -> MutationResult {
            let unknown = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
            return try .init(status: status, operation: operation, submitted: submitted, requiresRefresh: unknown,
                counts: .init(succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: [.confirmedFailure, .permissionDenied, .unsupported].contains(status) ? 1 : 0, unknown: unknown ? 1 : 0),
                errorCategory: category, diagnosticTag: "package-preference.\(status.rawValue.lowercased())")
        }
        guard change.isValid else { return try result(.confirmedFailure, submitted: false, category: .validation) }
        let state = PackagePreferenceSubmission()
        let record: @Sendable (NasPackagePreferenceCheckpoint) async throws -> Void = { stage in
            if stage == .accepted { await state.record(stage) }
            try await checkpoint(stage)
            if stage == .willSubmit {
                try Task.checkCancellation()
                await state.record(stage)
            }
        }
        do {
            switch change {
            case .settings(let original, let desired):
                _ = try await savePackageCenterSettings(desired, replacing: original.settings,
                    expectedUnknownIDs: original.unknownUpdateIDs, checkpoint: record)
            case .saveSource(let source, let old): _ = try await savePackageSource(source, replacing: old, checkpoint: record)
            case .removeSource(let source): _ = try await deletePackageSource(source, checkpoint: record)
            }
            return try result(.confirmedSuccess, submitted: await state.submitted)
        } catch {
            if Self.packagePreferenceTrustFailure(error) { throw error }
            let submitted = await state.submitted, category = (error as? AppError)?.category
            if error is CancellationError || category == .cancelled {
                return try result(submitted ? .cancellationRequestedAfterSubmission : .cancelledBeforeSubmission, submitted: submitted)
            }
            // 明确接受之后的权限/读取失败属于回读失败，不能把已接受的写请求改成被拒绝。
            if await state.accepted { return try result(.submittedButUnverified, submitted: true) }
            switch category {
            case .permissionDenied, .authenticationRequired: return try result(.permissionDenied, submitted: submitted, category: .permission)
            case .apiUnavailable, .versionUnsupported: return try result(.unsupported, submitted: submitted, category: .unsupported)
            case .conflict, .notFound: return try result(.confirmedFailure, submitted: submitted, category: .conflict)
            case .invalidResponse where !submitted || (error as? AppError)?.dsmCode != nil:
                return try result(.confirmedFailure, submitted: submitted, category: .validation)
            default: return try result(submitted ? .submittedButUnverified : .confirmedFailure, submitted: submitted, category: .unknown)
            }
        }
    }
}
