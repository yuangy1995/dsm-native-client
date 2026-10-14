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
        ModuleUnavailableReason.ACCESS_DENIED -> R.string.module_access_denied
        ModuleUnavailableReason.ACCESS_UNREAD -> R.string.module_access_unread
        ModuleUnavailableReason.ACCESS_FAILED -> R.string.module_access_failed
        ModuleUnavailableReason.AUTHENTICATION_REQUIRED -> R.string.module_access_sign_in
        ModuleUnavailableReason.FEATURE_UNSUPPORTED -> R.string.module_unavailable_generic
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
    DsmErrorKind.WORKSPACE_CHANGED ->
        R.string.error_workspace_changed to R.string.error_workspace_changed_recovery
    DsmErrorKind.WORKSPACE_BUSY ->
        R.string.error_workspace_busy to R.string.error_workspace_busy_recovery
    DsmErrorKind.BACKGROUND_EXECUTION_UNAVAILABLE ->
        R.string.execution_unavailable to R.string.execution_unavailable_recovery
    DsmErrorKind.LOCAL_STORAGE_FAILED ->
        R.string.error_connection_not_saved to R.string.error_connection_not_saved_recovery
    DsmErrorKind.INVALID_ADDRESS ->
        R.string.error_invalid_address to R.string.error_invalid_address_recovery
    DsmErrorKind.INSECURE_ADDRESS ->
        R.string.error_insecure_address to R.string.error_insecure_address_recovery
    DsmErrorKind.TLS_UNTRUSTED ->
        R.string.error_certificate_untrusted to R.string.error_certificate_untrusted_recovery
    DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED ->
        R.string.error_local_network_permission to R.string.error_local_network_permission_recovery
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
    DsmErrorKind.FILE_SEARCH_INVALID_CONDITIONS -> R.string.file_search_invalid to R.string.file_search_invalid_recovery
    DsmErrorKind.FILE_SEARCH_INVALID_REGEX -> R.string.file_search_invalid_regex to R.string.file_search_invalid_regex_recovery
    DsmErrorKind.FILE_CONTENT_SEARCH_REGEX -> R.string.file_search_content_regex to R.string.file_search_content_regex_recovery
    DsmErrorKind.FILE_SEARCH_INCOMPLETE -> R.string.file_search_incomplete to R.string.file_search_incomplete_recovery
    DsmErrorKind.FILE_SEARCH_TIMED_OUT -> R.string.file_search_timeout to R.string.file_search_timeout_recovery
    DsmErrorKind.FILE_CONTENT_SEARCH_UNAVAILABLE -> R.string.file_search_content_unavailable to R.string.file_search_content_unavailable_recovery
    DsmErrorKind.ARCHIVE_PASSWORD_REQUIRED -> R.string.archive_password_incorrect to R.string.archive_password_recovery
    DsmErrorKind.ARCHIVE_CONTENT_UNAVAILABLE -> R.string.archive_contents_failed to R.string.archive_contents_recovery
    DsmErrorKind.ARCHIVE_INVALID_SELECTION -> R.string.archive_selection_changed to R.string.archive_selection_recovery
    DsmErrorKind.ARCHIVE_RECOVERY_UNAVAILABLE -> R.string.archive_recovery_unavailable to R.string.archive_recovery_unavailable_hint
    DsmErrorKind.CHAT_ITEM_CHANGED -> R.string.chat_item_changed to R.string.chat_item_changed_hint
    DsmErrorKind.FILE_PERMISSIONS_CHANGED -> R.string.file_permissions_changed to R.string.file_permissions_changed_hint
    DsmErrorKind.FILE_PERMISSIONS_SELF_DENIED -> R.string.file_permissions_self_denied to R.string.file_permissions_self_denied_hint
    DsmErrorKind.FILE_PERMISSIONS_PENDING -> R.string.file_permissions_related_busy to R.string.file_permissions_related_busy_hint
    DsmErrorKind.FILE_MOUNT_CHANGED -> R.string.file_mount_changed to R.string.file_mount_changed_hint
    DsmErrorKind.FILE_MOUNT_EMPTY_REQUIRED -> R.string.file_mount_empty_required to R.string.file_mount_empty_required_hint
    DsmErrorKind.FILE_MOUNT_PENDING -> R.string.file_mount_pending to R.string.file_mount_pending_hint
    DsmErrorKind.FILE_REMOTE_MOUNT_OPTIONS -> R.string.file_remote_mount_options_invalid to R.string.file_remote_mount_options_invalid_hint
    DsmErrorKind.FILE_VFS_CHANGED -> R.string.file_vfs_changed to R.string.file_vfs_changed_hint
    DsmErrorKind.FILE_VFS_OPTIONS -> R.string.file_vfs_invalid to R.string.file_vfs_invalid_hint
    DsmErrorKind.FILE_VFS_PENDING -> R.string.file_vfs_pending to R.string.file_vfs_pending_hint
    DsmErrorKind.FILE_VFS_IDENTITY_WARNING -> R.string.file_vfs_identity_warning to R.string.file_vfs_identity_warning_hint
    DsmErrorKind.FILE_VFS_AUTHORIZATION_FAILED -> R.string.file_vfs_authorization_failed to R.string.file_vfs_authorization_failed_hint
    DsmErrorKind.FILE_VFS_AUTHORIZATION_EXPIRED -> R.string.file_vfs_authorization_expired to R.string.file_vfs_authorization_expired_hint
    DsmErrorKind.FILE_SETTINGS_CHANGED -> R.string.file_settings_changed to R.string.file_settings_changed_hint
    DsmErrorKind.FILE_SETTINGS_PENDING -> R.string.file_settings_pending to R.string.file_settings_pending_hint
    DsmErrorKind.FILE_SETTINGS_INVALID -> R.string.file_settings_invalid to R.string.file_settings_invalid_hint
    DsmErrorKind.FILE_BACKGROUND_TASK_CHANGED -> R.string.file_background_task_changed to R.string.file_background_task_changed_hint
    DsmErrorKind.FILE_BACKGROUND_TASK_PENDING -> R.string.file_background_task_pending to R.string.file_background_task_pending_hint
    DsmErrorKind.CROSS_NAS_CHANGED -> R.string.cross_nas_changed to R.string.cross_nas_changed_hint
    DsmErrorKind.CROSS_NAS_PENDING -> R.string.cross_nas_pending to R.string.cross_nas_pending_hint
    DsmErrorKind.CROSS_NAS_CONFLICT -> R.string.cross_nas_conflict to R.string.cross_nas_conflict_hint
    DsmErrorKind.CROSS_NAS_INCOMPLETE -> R.string.cross_nas_incomplete to R.string.cross_nas_incomplete_hint
    DsmErrorKind.OFFICE_CHANGED -> R.string.office_changed to R.string.office_changed_hint
    DsmErrorKind.OFFICE_LOCAL -> R.string.office_local_error to R.string.office_local_error_hint
    DsmErrorKind.OFFICE_FORMAT -> R.string.office_format_error to R.string.office_format_error_hint
    DsmErrorKind.OFFICE_PENDING -> R.string.office_pending to R.string.office_pending_hint
    DsmErrorKind.FILE_THEME_IMAGE_INVALID -> R.string.file_theme_image_invalid to R.string.file_theme_image_invalid_hint
    DsmErrorKind.EMPTY_FILE_UNSUPPORTED ->
        R.string.error_empty_file_unsupported to R.string.error_empty_file_unsupported_recovery
    DsmErrorKind.NAS_RELAY_PROTECTED -> R.string.remote_access_trusted_relay_title to R.string.remote_access_trusted_relay_message
    DsmErrorKind.NAS_SMART_CHANGED -> R.string.smart_changed_title to R.string.smart_changed_message
    DsmErrorKind.NAS_CONNECTION_CHANGED -> R.string.connection_feedback_conflict_title to R.string.connection_feedback_conflict_message
    DsmErrorKind.NAS_SERVICE_CHANGED -> R.string.nas_service_changed to R.string.nas_service_changed_hint
    DsmErrorKind.NAS_SERVICE_INVALID -> R.string.nas_service_invalid to R.string.nas_service_invalid_hint
    DsmErrorKind.NAS_REGION_CHANGED -> R.string.nas_region_changed to R.string.region_feedback_conflict_message
    DsmErrorKind.NAS_DDNS_INVALID -> R.string.ddns_invalid_title to R.string.ddns_invalid_hint
    DsmErrorKind.NAS_REGION_INVALID -> R.string.nas_region_invalid to R.string.nas_region_invalid_hint
    DsmErrorKind.CHANGE_NOT_CONFIRMED ->
        R.string.error_change_not_confirmed to R.string.error_change_not_confirmed_recovery
    DsmErrorKind.UPLOAD_FAILED ->
        R.string.error_upload_failed to R.string.error_upload_failed_recovery
    DsmErrorKind.UPLOAD_NOT_ALLOWED ->
        R.string.error_upload_not_allowed to R.string.error_upload_not_allowed_recovery
    DsmErrorKind.UPLOAD_LENGTH_MISMATCH ->
        R.string.error_upload_length_mismatch to R.string.error_upload_length_mismatch_recovery
    DsmErrorKind.DOWNLOAD_SOURCE_UNAVAILABLE ->
        R.string.error_download_source_unavailable to R.string.error_download_source_unavailable_recovery
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
