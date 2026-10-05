import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public var supportsScheduledTaskEditing: Bool { scheduledTaskSupports(version: 3) && scheduledTaskSupports(version: 4) }
    func scheduledTaskSupports(version: Int) -> Bool {
        guard let value = capabilities[DsmAPIName.coreTaskScheduler], value.selectedVersion != nil else { return false }
        return value.minVersion <= version && value.maxVersion >= version
    }
    func beginScheduledTaskMutation(id: Int?) throws -> String {
        let key = id.map(String.init) ?? "new"
        guard activeScheduledTaskKeys.insert(key).inserted else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("task.command.changed"))
        }
        return key
    }
    public func inspectScheduledTask(_ expected: NasScheduledTask) async throws -> NasScheduledTaskDraft? {
        let tasks = try await loadScheduledTasks()
        guard tasks.first(where: { $0.id == expected.id }).map({ expected.hasSameManagementIdentity(as: $0) }) == true else {
            throw scheduledTaskChangedError()
        }
        guard expected.type == "script" else { return nil }
        guard let id = Int(expected.id) else { throw scheduledTaskChangedError() }
        let draft = try await loadScheduledTaskDraft(id: id, realOwner: expected.realOwner)
        guard draft.matches(expected) else { throw scheduledTaskChangedError() }
        return draft
    }
    public func scheduledTaskResults(for expected: NasScheduledTask) async throws -> [NasScheduledTaskResult] {
        try await requireScheduledTaskForResults(expected)
        return try await loadScheduledTaskResults(taskName: expected.name)
    }
    public func scheduledTaskOutput(for expected: NasScheduledTask, resultID: String) async throws -> NasScheduledTaskResultOutput {
        let results = try await scheduledTaskResults(for: expected)
        guard results.contains(where: { $0.id == resultID }) else { throw scheduledTaskChangedError() }
        return try await loadScheduledTaskResultOutput(taskName: expected.name, resultID: resultID)
    }
    private func requireScheduledTaskForResults(_ expected: NasScheduledTask) async throws {
        let tasks = try await loadScheduledTasks()
        guard tasks.filter({ $0.name == expected.name }).count == 1,
              tasks.first(where: { $0.id == expected.id }).map({ expected.hasSameManagementIdentity(as: $0) }) == true else {
            throw scheduledTaskChangedError()
        }
    }
    private func scheduledTaskChangedError() -> AppError {
        .init(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("task.command.changed"))
    }

    public func changeScheduledTaskResult(_ change: NasScheduledTaskChange,
        checkpoint: @escaping @Sendable (NasScheduledTaskCheckpoint) async throws -> Void) async throws -> MutationResult {
        func result(_ status: MutationResultStatus, submitted: Bool, category: MutationErrorCategory? = nil) throws -> MutationResult {
            let unknown = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
            return try .init(status: status, operation: change.action.rawValue, submitted: submitted,
                requiresRefresh: unknown, counts: .init(succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: status == .confirmedSuccess || unknown || status == .cancelledBeforeSubmission ? 0 : 1, unknown: unknown ? 1 : 0),
                errorCategory: category, diagnosticTag: "scheduled-task.\(status.rawValue.lowercased())")
        }
        func failure(_ error: Error, submitted: Bool) throws -> MutationResult {
            if error is DsmCertificateTrustError { throw error }
            if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
            switch (error as? AppError)?.category {
            case .permissionDenied, .authenticationRequired: return try result(.permissionDenied, submitted: submitted, category: .permission)
            case .apiUnavailable, .versionUnsupported: return try result(.unsupported, submitted: submitted, category: .unsupported)
            case .conflict: return try result(.confirmedFailure, submitted: submitted, category: .conflict)
            default:
                if error is CancellationError || (error as? AppError)?.category == .cancelled {
                    return try result(submitted ? .cancellationRequestedAfterSubmission : .cancelledBeforeSubmission, submitted: submitted)
                }
                return try result(.confirmedFailure, submitted: submitted, category: .unknown)
            }
        }
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        guard change.isValid else { return try result(.confirmedFailure, submitted: false, category: .validation) }
        guard scheduledTaskSupports(version: 3), change.originalDraft == nil || scheduledTaskSupports(version: 4) else {
            return try result(.unsupported, submitted: false, category: .unsupported)
        }
        let key: String
        do { key = try beginScheduledTaskMutation(id: change.task.flatMap { Int($0.id) }) }
        catch { return try failure(error, submitted: false) }
        defer { activeScheduledTaskKeys.remove(key) }
        let before: [NasScheduledTask]
        do {
            before = try await loadScheduledTasks()
            guard change.matches(before) else { throw scheduledTaskChangedError() }
            if let original = change.originalDraft {
                let actual = try await loadScheduledTaskDraft(id: original.id, realOwner: original.realOwner)
                guard actual == original else { throw scheduledTaskChangedError() }
            }
        } catch { return try failure(error, submitted: false) }
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        // 用户权限和持久记录由调用方在这里确认，失败不得进入请求。
        try await checkpoint(.willSubmit(existingIDs: change.action == .create ? before.compactMap { Int($0.id) } : []))
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        var accepted = false
        do {
            switch change {
            case .save(_, _, let desired): try await submitScheduledTask(desired)
            case .setEnabled(let task, _, let enabled):
                try await submitScheduledTaskCommand(method: "set_enable", id: Int(task.id)!, realOwner: task.realOwner, additional: ["enable": .boolean(enabled)])
            case .run(let task, _): try await submitScheduledTaskCommand(method: "run", id: Int(task.id)!, realOwner: task.realOwner)
            case .delete(let task): try await submitScheduledTaskCommand(method: "delete", id: Int(task.id)!, realOwner: task.realOwner)
            }
            accepted = true
        } catch {
            if error is DsmCertificateTrustError { throw error }
            if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
            switch (error as? AppError)?.category {
            case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, nil: break
            default: return try failure(error, submitted: true)
            }
        }
        if accepted { try await checkpoint(.accepted) }
        // 运行只能确认请求被接受；旧历史记录不能证明本次脚本已执行。
        if change.action == .run { return try result(accepted ? .confirmedSuccess : .submittedButUnverified, submitted: true) }
        if Task.isCancelled { return try result(.cancellationRequestedAfterSubmission, submitted: true) }
        do {
            let tasks = try await loadScheduledTasks()
            if change.action == .delete, let id = change.task?.id, !tasks.contains(where: { $0.id == id }) {
                return try result(.confirmedSuccess, submitted: true)
            }
            if change.action == .disable, let original = change.task,
               let current = tasks.first(where: { $0.id == original.id }), current.isEnabledKnown, !current.isEnabled,
               original.managementTargetFields == current.managementTargetFields {
                return try result(.confirmedSuccess, submitted: true)
            }
            if let desired = change.desiredDraft {
                let candidates: [NasScheduledTask]
                if let task = change.task { candidates = tasks.filter { $0.id == task.id && $0.realOwner == task.realOwner } }
                else {
                    let oldIDs = Set(before.map(\.id))
                    candidates = accepted ? tasks.filter { !oldIDs.contains($0.id) && $0.name == desired.normalizedName && $0.owner == desired.normalizedOwner } : []
                }
                if candidates.count == 1, let task = candidates.first, task.type == "script", let id = Int(task.id) {
                    let saved = try await loadScheduledTaskDraft(id: id, realOwner: task.realOwner)
                    if saved.matches(task), saved.savedFields == desired.savedFields { return try result(.confirmedSuccess, submitted: true) }
                }
            }
        } catch {
            if error is DsmCertificateTrustError { throw error }
            if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
        }
        return try result(Task.isCancelled ? .cancellationRequestedAfterSubmission : .submittedButUnverified, submitted: true)
    }
}
