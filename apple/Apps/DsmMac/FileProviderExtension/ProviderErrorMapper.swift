import DsmCore
import FileProvider
import Foundation
import DsmLocalization

enum ProviderErrorMapper {
    static func map(
        _ error: Error,
        itemIdentifier: NSFileProviderItemIdentifier
    ) -> Error {
        if let writeback = error as? DesktopDriveWritebackError {
            let key: String
            switch writeback {
            case .conflict: key = "desktopDrive.writeback.conflict"
            case .outcomeUnknown: key = "desktopDrive.writeback.unknown"
            case .pendingChanges: key = "desktopDrive.writeback.pending"
            case .busy: return NSFileProviderError(.serverUnreachable)
            case .disabled: key = "desktopDrive.writeback.readOnly"
            case .invalidItem: key = "desktopDrive.writeback.invalid"
            case .keptLocally: key = "desktopDrive.writeback.stopped"
            }
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                           userInfo: [NSLocalizedDescriptionKey: L10n.string(key)])
        }
        if error is CancellationError {
            return CocoaError(.userCancelled)
        }
        if let appError = error as? AppError {
            switch appError.category {
            case .cancelled:
                return CocoaError(.userCancelled)
            case .authenticationRequired, .otpRequired:
                return NSFileProviderError(.notAuthenticated)
            case .permissionDenied:
                return CocoaError(.fileReadNoPermission)
            case .notFound:
                return NSError.fileProviderErrorForNonExistentItem(
                    withIdentifier: itemIdentifier
                )
            case .localStorageFull:
                return CocoaError(.fileWriteOutOfSpace)
            case .networkUnavailable, .timeout, .tlsUntrusted,
                 .tlsCertificateChanged, .serverBusy:
                return NSFileProviderError(.serverUnreachable)
            case .apiUnavailable, .versionUnsupported, .invalidResponse,
                 .partialFailure, .conflict, .remoteStorageFull, .unknown:
                return NSFileProviderError(.cannotSynchronize)
            }
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSFileProviderErrorDomain
            || cocoaError.domain == NSCocoaErrorDomain {
            return error
        }
        return NSFileProviderError(.serverUnreachable)
    }
}
