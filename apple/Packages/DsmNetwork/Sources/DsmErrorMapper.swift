import DsmCore
import Foundation
import DsmLocalization

enum DsmErrorContext {
    case general
    case fileStation
    case authentication(otpWasSubmitted: Bool)
}

enum DsmErrorMapper {
    static func map(_ error: DsmNetworkError, context: DsmErrorContext = .general) -> AppError {
        switch error {
        case .invalidRequest(let requestID):
            return AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.ceafc4ba41052cd3"),
                requestID: requestID
            )
        case .httpStatus(let code, let requestID):
            return mapHTTPStatus(code, requestID: requestID, context: context)
        case .responseTooLarge(let requestID), .invalidResponse(let requestID):
            return AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.f98d542d79142efa"),
                requestID: requestID
            )
        case .api(let code, let requestID):
            return mapDSMCode(code, requestID: requestID, context: context)
        case .transport(let code, let requestID):
            return mapTransportCode(code, requestID: requestID)
        case .cancelled(let requestID):
            return AppError(
                category: .cancelled,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.83f4727f2b4672a6"),
                requestID: requestID
            )
        }
    }

    private static func mapHTTPStatus(
        _ code: Int,
        requestID: UUID,
        context: DsmErrorContext
    ) -> AppError {
        if code == 401 {
            return AppError(
                category: .authenticationRequired,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.f19745ebfe7e7094"),
                httpStatus: code,
                requestID: requestID
            )
        }

        if code == 403 {
            if case .authentication = context {
                return AppError(
                    category: .authenticationRequired,
                    isRetryable: false,
                    safeUserMessage: L10n.string("shared.f19745ebfe7e7094"),
                    httpStatus: code,
                    requestID: requestID
                )
            }
            return AppError(
                category: .permissionDenied,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.f0daa43c26f5dc7c"),
                httpStatus: code,
                requestID: requestID
            )
        }

        return AppError(
            category: code >= 500 ? .serverBusy : .invalidResponse,
            isRetryable: code >= 500,
            safeUserMessage: code >= 500 ? L10n.string("shared.3a10274bc9cbc505") : L10n.string("shared.266b4cf4f0a2c3ea"),
            httpStatus: code,
            requestID: requestID
        )
    }

    private static func mapDSMCode(
        _ code: Int,
        requestID: UUID,
        context: DsmErrorContext
    ) -> AppError {
        if case .authentication(let otpWasSubmitted) = context {
            switch code {
            case 400:
                return apiError(.authenticationRequired, false, L10n.string("shared.971c1182f4bc8d69"), code, requestID)
            case 401:
                return apiError(.authenticationRequired, false, L10n.string("shared.3c5f4468deb3648e"), code, requestID)
            case 402:
                return apiError(.permissionDenied, false, L10n.string("shared.993d62ddf6d3073c"), code, requestID)
            case 403, 406:
                return apiError(.otpRequired, false, L10n.string("shared.cc1dfd45497926ba"), code, requestID)
            case 404 where otpWasSubmitted:
                return apiError(.otpRequired, false, L10n.string("shared.999c5ca11380400b"), code, requestID)
            case 407:
                return apiError(.permissionDenied, false, L10n.string("shared.7fe7b412406eb8b2"), code, requestID)
            case 408:
                return apiError(.authenticationRequired, false, L10n.string("shared.a444c2afe457be21"), code, requestID)
            case 409, 410:
                return apiError(.authenticationRequired, false, L10n.string("shared.417ad1f7a8d06f80"), code, requestID)
            default:
                break
            }
        }

        if case .fileStation = context, code == 407 || code == 411 {
            return apiError(.permissionDenied, false, L10n.string("shared.b99b8ea54fa7ef76"), code, requestID)
        }

        switch code {
        case 102, 103:
            return apiError(.apiUnavailable, false, L10n.string("shared.119cf0fb55dbb178"), code, requestID)
        case 104:
            return apiError(.versionUnsupported, false, L10n.string("shared.95cbdf7aaaa0f83b"), code, requestID)
        case 105:
            return apiError(.permissionDenied, false, L10n.string("shared.b99b8ea54fa7ef76"), code, requestID)
        case 106, 107, 119:
            return apiError(.authenticationRequired, false, L10n.string("shared.18b4f39557c377e4"), code, requestID)
        case 109, 110, 111, 117, 118:
            return apiError(.serverBusy, true, L10n.string("shared.fb3e57ef440d7c78"), code, requestID)
        case 150:
            return apiError(.networkUnavailable, false, L10n.string("shared.e19b0bb20792fd73"), code, requestID)
        case 404, 408, 900:
            return apiError(.notFound, false, L10n.string("shared.5f35ed652b825e19"), code, requestID)
        case 1300:
            return apiError(.unknown, true, L10n.string("shared.913dbcbb37d0b503"), code, requestID)
        case 1301:
            return apiError(.invalidResponse, false, L10n.string("shared.539873656a8d3b33"), code, requestID)
        case 1400:
            return apiError(.unknown, true, L10n.string("shared.9c25538cfcc5cf55"), code, requestID)
        case 1401, 1402:
            return apiError(.invalidResponse, false, L10n.string("shared.4c29707adc9687ba"), code, requestID)
        case 1403:
            return apiError(.invalidResponse, false, L10n.string("shared.c9e14d75e9b9fa8c"), code, requestID)
        case 1404, 1405:
            return apiError(.invalidResponse, false, L10n.string("shared.55106e700c58cc74"), code, requestID)
        default:
            return apiError(.unknown, false, L10n.string("shared.98ba28a8694df5f0"), code, requestID)
        }
    }

    private static func mapTransportCode(_ code: Int, requestID: UUID) -> AppError {
        let urlErrorCode = URLError.Code(rawValue: code)
        switch urlErrorCode {
        case .timedOut:
            return AppError(
                category: .timeout,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.c78d50442236c602"),
                requestID: requestID
            )
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
            return AppError(
                category: .networkUnavailable,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.3891ecb7c07e3057"),
                requestID: requestID
            )
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .secureConnectionFailed:
            return AppError(
                category: .tlsUntrusted,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.e34c1fb14f39863b"),
                requestID: requestID
            )
        case .cancelled:
            return AppError(
                category: .cancelled,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.83f4727f2b4672a6"),
                requestID: requestID
            )
        default:
            return AppError(
                category: .networkUnavailable,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.0a8292dd1d9b62a1"),
                requestID: requestID
            )
        }
    }

    private static func apiError(
        _ category: AppErrorCategory,
        _ isRetryable: Bool,
        _ message: String,
        _ code: Int,
        _ requestID: UUID
    ) -> AppError {
        AppError(
            category: category,
            isRetryable: isRetryable,
            safeUserMessage: message,
            dsmCode: code,
            requestID: requestID
        )
    }
}
