package io.github.qwertyuiop1995.dsmnativeclient.localization

import android.content.Context
import androidx.annotation.StringRes
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleUnavailableReason

data class LocalizedFailure(val message: String, val recovery: String) {
    val combined: String get() = "$message $recovery"
}

fun DsmFailure.localize(context: Context): LocalizedFailure {
    val (message, recovery) = resources()
    return LocalizedFailure(
        context.getString(message),
        context.getString(recovery),
    )
}

@StringRes
fun ModuleUnavailableReason.messageResource(): Int = when (this) {
        ModuleUnavailableReason.SYNOLOGY_PHOTOS -> R.string.sp_service_unavailable
        ModuleUnavailableReason.CHAT_SERVICE -> R.string.module_unavailable_chat
        ModuleUnavailableReason.DOWNLOAD_STATION -> R.string.module_unavailable_downloads
        ModuleUnavailableReason.CONTAINER_MANAGER -> R.string.module_unavailable_containers
        ModuleUnavailableReason.VIRTUAL_MACHINE_MANAGER ->
            R.string.module_unavailable_virtual_machines
}

fun ModuleUnavailableReason.localize(context: Context): String =
    context.getString(messageResource())

private fun DsmFailure.resources(): Pair<Int, Int> = when (kind) {
    DsmErrorKind.MISSING_LOGIN_FIELDS ->
        R.string.error_missing_login to R.string.error_missing_login_recovery
    DsmErrorKind.NO_SAVED_SESSION ->
        R.string.error_no_saved_session to R.string.error_no_saved_session_recovery
    DsmErrorKind.SAVED_SESSION_EXPIRED ->
        R.string.error_saved_session_expired to R.string.error_saved_session_expired_recovery
    DsmErrorKind.INVALID_ADDRESS ->
        R.string.error_invalid_address to R.string.error_invalid_address_recovery
    DsmErrorKind.INSECURE_ADDRESS ->
        R.string.error_insecure_address to R.string.error_insecure_address_recovery
    DsmErrorKind.INVALID_QUICK_CONNECT_ID ->
        R.string.error_invalid_quickconnect to R.string.error_invalid_quickconnect_recovery
    DsmErrorKind.QUICK_CONNECT_NOT_FOUND ->
        R.string.error_quickconnect_not_found to R.string.error_quickconnect_not_found_recovery
    DsmErrorKind.QUICK_CONNECT_OFFLINE ->
        R.string.error_quickconnect_offline to R.string.error_quickconnect_offline_recovery
    DsmErrorKind.QUICK_CONNECT_RELAY_DISABLED ->
        R.string.error_quickconnect_relay_disabled to R.string.error_quickconnect_relay_disabled_recovery
    DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH ->
        R.string.error_quickconnect_identity to R.string.error_quickconnect_identity_recovery
    DsmErrorKind.QUICK_CONNECT_DIRECT_UNAVAILABLE,
    DsmErrorKind.QUICK_CONNECT_SERVICE_UNAVAILABLE,
    DsmErrorKind.QUICK_CONNECT_INVALID_RESPONSE,
    DsmErrorKind.QUICK_CONNECT_RELAY_UNAVAILABLE ->
        R.string.error_quickconnect_unavailable to R.string.error_quickconnect_unavailable_recovery
    DsmErrorKind.FEATURE_UNSUPPORTED ->
        R.string.error_feature_unsupported to R.string.error_feature_unsupported_recovery
    DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED ->
        R.string.error_package_unsupported to R.string.error_package_unsupported_recovery
    DsmErrorKind.SESSION_EXPIRED ->
        R.string.error_session_expired to R.string.error_session_expired_recovery
    DsmErrorKind.PERMISSION_DENIED ->
        R.string.error_permission_denied to R.string.error_permission_denied_recovery
    DsmErrorKind.RATE_LIMITED ->
        R.string.error_rate_limited to R.string.error_rate_limited_recovery
    DsmErrorKind.AUTHENTICATION_FAILED ->
        R.string.error_authentication_failed to R.string.error_authentication_failed_recovery
    DsmErrorKind.OTP_REQUIRED ->
        R.string.error_otp_required to R.string.error_otp_required_recovery
    DsmErrorKind.OTP_INVALID ->
        R.string.error_otp_invalid to R.string.error_otp_invalid_recovery
    DsmErrorKind.DEVICE_CONFIRMATION_REQUIRED ->
        R.string.error_device_confirmation to R.string.error_device_confirmation_recovery
    DsmErrorKind.CONNECTION_FAILED ->
        R.string.error_connection_failed to R.string.error_connection_failed_recovery
    DsmErrorKind.INVALID_RESPONSE ->
        R.string.error_invalid_response to R.string.error_invalid_response_recovery
    DsmErrorKind.SEARCH_NOT_STARTED ->
        R.string.error_search_not_started to R.string.error_search_not_started_recovery
    DsmErrorKind.EMPTY_FILE_UNSUPPORTED ->
        R.string.error_empty_file_unsupported to R.string.error_empty_file_unsupported_recovery
    DsmErrorKind.CHANGE_NOT_CONFIRMED ->
        R.string.error_change_not_confirmed to R.string.error_change_not_confirmed_recovery
    DsmErrorKind.UPLOAD_FAILED ->
        R.string.error_upload_failed to R.string.error_upload_failed_recovery
    DsmErrorKind.UPLOAD_NOT_ALLOWED ->
        R.string.error_upload_not_allowed to R.string.error_upload_not_allowed_recovery
    DsmErrorKind.UPLOAD_LENGTH_MISMATCH ->
        R.string.error_upload_length_mismatch to R.string.error_upload_length_mismatch_recovery
    DsmErrorKind.DOWNLOAD_FAILED ->
        R.string.error_download_failed to R.string.error_download_failed_recovery
    DsmErrorKind.DOWNLOAD_LENGTH_MISMATCH ->
        R.string.error_download_length_mismatch to R.string.error_download_length_mismatch_recovery
    DsmErrorKind.PREVIEW_TOO_LARGE ->
        R.string.error_preview_too_large to R.string.error_preview_too_large_recovery
    DsmErrorKind.UNKNOWN,
    DsmErrorKind.REQUEST_FAILED ->
        R.string.operation_not_completed to R.string.try_again_later
}
