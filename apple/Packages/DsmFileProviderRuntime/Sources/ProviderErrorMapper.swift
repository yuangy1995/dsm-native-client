import DsmCore
import FileProvider
import Foundation
import DsmLocalization

enum ProviderErrorMapper {
    static func mapDeletion(_ error: Error, itemIdentifier: NSFileProviderItemIdentifier) -> Error {
        guard let writeback = error as? DesktopDriveWritebackError else {
            return map(error, itemIdentifier: itemIdentifier)
        }
        let key: String
        switch writeback {
        case .disabled: key = "desktopDrive.delete.disabled"
        case .invalidItem: key = "desktopDrive.delete.invalid"
        case .conflict: key = "desktopDrive.delete.conflict"
        case .outcomeUnknown: key = "desktopDrive.delete.unknown"
        default: return map(error, itemIdentifier: itemIdentifier)
        }
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.cannotSynchronize.rawValue,
                       userInfo: [NSLocalizedDescriptionKey: message(key)])
    }

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
                           userInfo: [NSLocalizedDescriptionKey: message(key)])
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
    private static func message(_ key: String) -> String {
        #if os(iOS)
        switch key {
        case "desktopDrive.writeback.conflict": return L10n.string("mobile.files-location.conflict-error")
        case "desktopDrive.writeback.unknown": return L10n.string("mobile.files-location.unknown-error")
        case "desktopDrive.writeback.pending": return L10n.string("mobile.files-location.pending-error")
        case "desktopDrive.delete.disabled": return L10n.string("mobile.files-location.delete-disabled-error")
        case "desktopDrive.delete.invalid": return L10n.string("mobile.files-location.delete-invalid-error")
        case "desktopDrive.delete.conflict": return L10n.string("mobile.files-location.delete-conflict-error")
        case "desktopDrive.delete.unknown": return L10n.string("mobile.files-location.delete-unknown-error")
        default: break
        }
        #endif
        return L10n.string(key)
    }

}
