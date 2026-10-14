package io.github.qwertyuiop1995.dsmnativeclient.network

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure

/** 按通用契约区分会话、授权与能力错误；登录专有错误不套用到文件/套件请求。 */
internal fun dsmApiFailure(code: Int?, authenticationRequest: Boolean = false): DsmFailure {
    if (authenticationRequest) when (code) {
        400, 401, 402, 404 -> return DsmFailure(code, "Sign-in information is incorrect", "Check the account, password, and verification code.", true, DsmErrorKind.AUTHENTICATION_FAILED)
        403, 406 -> return DsmFailure(code, "Two-factor code required", "Enter the current code from your authenticator.", true, DsmErrorKind.OTP_REQUIRED)
        407 -> return DsmFailure(code, "Two-factor code is incorrect", "Use the latest code and try again.", true, DsmErrorKind.OTP_INVALID)
        408, 409 -> return DsmFailure(code, "Device confirmation required", "Confirm the device in DSM and try again.", true, DsmErrorKind.DEVICE_CONFIRMATION_REQUIRED)
    }
    return when (code) {
        102, 104 -> DsmFailure(code, "Feature unsupported", "Update DSM or the related package.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        103 -> DsmFailure(code, "Package version unsupported", "Update the package and try again.", kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED)
        105 -> DsmFailure(code, "Permission denied", "Use an account with the required permission.", kind = DsmErrorKind.PERMISSION_DENIED)
        106, 107, 119 -> DsmFailure(code, "Session expired", "Sign in again.", true, DsmErrorKind.SESSION_EXPIRED)
        108 -> DsmFailure(code, "The upload was not completed", "Choose the file again and retry.", kind = DsmErrorKind.UPLOAD_FAILED)
        115 -> DsmFailure(code, "The NAS did not allow this upload", "Check folder permissions and available space.", kind = DsmErrorKind.UPLOAD_NOT_ALLOWED)
        1800 -> DsmFailure(code, "The upload size could not be verified", "Choose the file again and retry.", kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH)
        1801, 1802, 1803, 1804, 1805 -> DsmFailure(code, "The NAS could not accept this file", "Check the file name, folder permissions, and available space.", kind = DsmErrorKind.UPLOAD_FAILED)
        else -> DsmFailure(code, "NAS operation failed", "Refresh and try again.", kind = DsmErrorKind.REQUEST_FAILED)
    }.copy(isExplicitApiRejection = code != null)
}

internal fun httpFailure(code: Int): DsmFailure = when (code) {
    401 -> DsmFailure(code, "Session expired", "Sign in again.", true, DsmErrorKind.SESSION_EXPIRED)
    403 -> DsmFailure(code, "Permission denied", "Use an account with the required permission.", kind = DsmErrorKind.PERMISSION_DENIED)
    else -> DsmFailure(code, "Could not connect to the NAS", "Check the network, address, and certificate.", kind = DsmErrorKind.CONNECTION_FAILED)
}
