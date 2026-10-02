import DsmCore
import DsmLocalization
import Foundation

struct FileShareBatchItem: Identifiable, Sendable {
    let target: FileItem
    let status: MutationResultStatus
    let link: FileShareLink?
    var id: FileItem.ID { target.id }

    var message: String {
        switch status {
        case .confirmedSuccess: L10n.string("files.sharing.created")
        case .permissionDenied: L10n.string("files.sharing.denied")
        case .unsupported: L10n.string("files.sharing.unsupported")
        case .cancelledBeforeSubmission: L10n.string("files.sharing.cancelled")
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            L10n.string("files.sharing.unverified")
        case .confirmedFailure: L10n.string("files.sharing.failed")
        }
    }
}

enum FileShareBatch {
    /// 每个目标只提交一次；不因其他目标失败而丢弃已确认链接，也不重放未知结果。
    static func create(
        targets: [FileItem], password: String?,
        availableOn: FileShareLinkCalendarDate?, expiresOn: FileShareLinkCalendarDate?,
        fileRequest: FileRequestConfiguration? = nil,
        operation: @Sendable (FileShareLinkCreateRequest) async throws -> FileShareLinkCreateOutcome
    ) async -> [FileShareBatchItem] {
        var seen = Set<FileItem.ID>()
        var results: [FileShareBatchItem] = []
        for target in targets where seen.insert(target.id).inserted {
            if Task.isCancelled {
                results.append(.init(target: target, status: .cancelledBeforeSubmission, link: nil))
                continue
            }
            do {
                let request = try FileShareLinkCreateRequest(
                    target: target, password: password, availableOn: availableOn, expiresOn: expiresOn, fileRequest: fileRequest
                )
                let outcome = try await operation(request)
                let link = outcome.result.status == .confirmedSuccess ? outcome.confirmedLink : nil
                results.append(.init(target: target,
                    status: outcome.result.status == .confirmedSuccess && link == nil
                        ? .submittedButUnverified : outcome.result.status, link: link))
            } catch is FileShareLinkContractError {
                results.append(.init(target: target, status: .confirmedFailure, link: nil))
            } catch let error as AppError where error.category == .versionUnsupported || error.category == .apiUnavailable || error.category == .permissionDenied {
                results.append(.init(target: target, status: error.category == .permissionDenied ? .permissionDenied : .unsupported, link: nil))
            } catch {
                results.append(.init(target: target, status: .submittedButUnverified, link: nil))
            }
        }
        return results
    }
}
