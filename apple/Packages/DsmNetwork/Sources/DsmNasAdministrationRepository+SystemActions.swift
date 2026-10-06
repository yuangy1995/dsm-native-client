import DsmCore
import Foundation

extension DsmNasAdministrationRepository {
    public var supportsSystemPowerActions: Bool {
        guard let value = capabilities[DsmAPIName.coreSystem], value.selectedVersion != nil else { return false }
        return value.minVersion <= 3 && value.maxVersion >= 3
    }
    /// 恢复电源入口只检查新会话可达；不能据此证明上次关机或重启完成。
    public func verifyPowerConnection() async throws {
        _ = try await call(DsmAPIName.coreSystem, method: "info", version: 3)
    }
    public func performSystemActionResult(_ action: NasSystemAction,
        checkpoint: @escaping @Sendable (NasSystemActionCheckpoint) async throws -> Void) async throws -> MutationResult {
        switch action {
        case .power(let value): return try await performPowerActionResult(value, version: 3, checkpoint: checkpoint)
        case .disconnect(let target): return try await disconnectConnectionResult(target, checkpoint: checkpoint)
        }
    }
    private func disconnectConnectionResult(_ target: NasConnection,
        checkpoint: @escaping @Sendable (NasSystemActionCheckpoint) async throws -> Void) async throws -> MutationResult {
        func result(_ status: MutationResultStatus, submitted: Bool, category: MutationErrorCategory? = nil) throws -> MutationResult {
            let unknown = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
            return try .init(status: status, operation: "connectionDisconnect", submitted: submitted, requiresRefresh: unknown,
                counts: .init(succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: [.confirmedFailure, .permissionDenied, .unsupported].contains(status) ? 1 : 0, unknown: unknown ? 1 : 0),
                errorCategory: category, diagnosticTag: "connection.\(status.rawValue.lowercased())")
        }
        func failure(_ error: Error, submitted: Bool) throws -> MutationResult {
            if error is DsmCertificateTrustError { throw error }
            if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
            if error is CancellationError || (error as? AppError)?.category == .cancelled {
                return try result(submitted ? .cancellationRequestedAfterSubmission : .cancelledBeforeSubmission, submitted: submitted)
            }
            switch (error as? AppError)?.category {
            case .permissionDenied, .authenticationRequired: return try result(.permissionDenied, submitted: submitted, category: .permission)
            case .apiUnavailable, .versionUnsupported: return try result(.unsupported, submitted: submitted, category: .unsupported)
            case .conflict, .invalidResponse: return try result(.confirmedFailure, submitted: submitted, category: .conflict)
            default: return try result(.confirmedFailure, submitted: submitted, category: .unknown)
            }
        }
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        let key: String
        do { key = try beginConnectionMutation(target) } catch { return try failure(error, submitted: false) }
        defer { activeConnectionKeys.remove(key) }
        do { try await prepareConnectionDisconnect(target, version: 1) }
        catch { return try failure(error, submitted: false) }
        try await checkpoint(.willSubmit)
        if Task.isCancelled { return try result(.cancelledBeforeSubmission, submitted: false) }
        var accepted = false
        do { try await submitConnectionDisconnect(target, version: 1); accepted = true }
        catch {
            if error is DsmCertificateTrustError { throw error }
            if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
            switch (error as? AppError)?.category {
            case .cancelled, .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown, nil: break
            default: return try failure(error, submitted: true)
            }
        }
        if accepted { try await checkpoint(.accepted) }
        for attempt in 0..<(accepted ? 4 : 1) {
            if Task.isCancelled { return try result(.cancellationRequestedAfterSubmission, submitted: true) }
            do {
                let page = try await loadConnectionsForManagement()
                if page.isCompleteForManagement, !page.connections.contains(where: { target.mayRemain(in: $0) }) {
                    return try result(.confirmedSuccess, submitted: true)
                }
            } catch {
                if error is DsmCertificateTrustError { throw error }
                if let value = error as? AppError, [.tlsUntrusted, .tlsCertificateChanged].contains(value.category) { throw error }
                break
            }
            if accepted && attempt < 3 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        return try result(Task.isCancelled ? .cancellationRequestedAfterSubmission : .submittedButUnverified, submitted: true)
    }
}
