package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
data class NasProfile(
    val id: String,
    val name: String,
    val address: String,
    val username: String,
    val port: Int? = null,
    val rememberSession: Boolean = true,
)

@Serializable
data class DsmSession(
    val profileId: String,
    val sid: String,
    val synoToken: String? = null,
    val deviceId: String? = null,
)

@Serializable
data class ApiCapability(
    val name: String,
    val path: String,
    val minVersion: Int,
    val maxVersion: Int,
    // 能力发现的原始请求格式；未提供时不得猜测为 Photos 所需的 JSON。
    val requestFormat: String = "",
) {
    fun version(preferred: Int = maxVersion): Int = preferred.coerceIn(minVersion, maxVersion)
}

enum class DsmErrorKind {
    UNKNOWN,
    INVALID_ADDRESS,
    INSECURE_ADDRESS,
    TLS_UNTRUSTED,
    LOCAL_NETWORK_PERMISSION_REQUIRED,
    INVALID_QUICK_CONNECT_ID,
    QUICK_CONNECT_NOT_FOUND,
    QUICK_CONNECT_OFFLINE,
    QUICK_CONNECT_DIRECT_UNAVAILABLE,
    QUICK_CONNECT_SERVICE_UNAVAILABLE,
    QUICK_CONNECT_INVALID_RESPONSE,
    QUICK_CONNECT_RELAY_DISABLED,
    QUICK_CONNECT_RELAY_UNAVAILABLE,
    QUICK_CONNECT_IDENTITY_MISMATCH,
    MISSING_LOGIN_FIELDS,
    NO_SAVED_SESSION,
    SAVED_SESSION_EXPIRED,
    WORKSPACE_CHANGED,
    WORKSPACE_BUSY,
    LOCAL_STORAGE_FAILED,
    BACKGROUND_EXECUTION_UNAVAILABLE,
    REQUEST_FAILED,
    FEATURE_UNSUPPORTED,
    PACKAGE_VERSION_UNSUPPORTED,
    SESSION_EXPIRED,
    PERMISSION_DENIED,
    RATE_LIMITED,
    AUTHENTICATION_FAILED,
    OTP_REQUIRED,
    OTP_INVALID,
    DEVICE_CONFIRMATION_REQUIRED,
    CONNECTION_FAILED,
    INVALID_RESPONSE,
    SEARCH_NOT_STARTED,
    FILE_SEARCH_INVALID_CONDITIONS,
    FILE_SEARCH_INVALID_REGEX,
    FILE_CONTENT_SEARCH_REGEX,
    FILE_SEARCH_INCOMPLETE,
    FILE_SEARCH_TIMED_OUT,
    FILE_CONTENT_SEARCH_UNAVAILABLE,
    ARCHIVE_PASSWORD_REQUIRED,
    ARCHIVE_CONTENT_UNAVAILABLE,
    ARCHIVE_INVALID_SELECTION,
    ARCHIVE_RECOVERY_UNAVAILABLE,
    FILE_PERMISSIONS_CHANGED,
    FILE_PERMISSIONS_SELF_DENIED,
    FILE_PERMISSIONS_PENDING,
    FILE_MOUNT_CHANGED,
    FILE_MOUNT_EMPTY_REQUIRED,
    FILE_MOUNT_PENDING,
    FILE_REMOTE_MOUNT_OPTIONS,
    FILE_VFS_CHANGED,
    FILE_VFS_OPTIONS,
    FILE_VFS_PENDING,
    FILE_VFS_IDENTITY_WARNING,
    FILE_VFS_AUTHORIZATION_EXPIRED,
    FILE_VFS_AUTHORIZATION_FAILED,
    FILE_SETTINGS_CHANGED,
    FILE_SETTINGS_PENDING,
    FILE_SETTINGS_INVALID,
    FILE_BACKGROUND_TASK_CHANGED,
    FILE_BACKGROUND_TASK_PENDING,
    CROSS_NAS_CHANGED,
    CROSS_NAS_PENDING,
    CROSS_NAS_CONFLICT,
    CROSS_NAS_INCOMPLETE,
    OFFICE_CHANGED,
    OFFICE_LOCAL,
    OFFICE_FORMAT,
    OFFICE_PENDING,
    FILE_THEME_IMAGE_INVALID,
    EMPTY_FILE_UNSUPPORTED,
    CHAT_ITEM_CHANGED,
    CHANGE_NOT_CONFIRMED,
    NAS_SERVICE_CHANGED,
    NAS_CONNECTION_CHANGED,
    NAS_SMART_CHANGED,
    NAS_SERVICE_INVALID,
    NAS_REGION_CHANGED,
    NAS_REGION_INVALID,
    NAS_DDNS_INVALID,
    NAS_RELAY_PROTECTED,
    UPLOAD_FAILED,
    UPLOAD_NOT_ALLOWED,
    UPLOAD_LENGTH_MISMATCH,
    DOWNLOAD_FAILED,
    DOWNLOAD_SOURCE_UNAVAILABLE,
    DOWNLOAD_LENGTH_MISMATCH,
    PREVIEW_TOO_LARGE,
}

data class DsmFailure(
    val code: Int?,
    override val message: String,
    val recovery: String,
    val isAuthenticationFailure: Boolean = false,
    val kind: DsmErrorKind = DsmErrorKind.UNKNOWN,
    val isExplicitApiRejection: Boolean = false,
) : RuntimeException(message)

enum class Module {
    FILES,
    PHOTOS,
    CHAT,
    DOWNLOADS,
    CONTAINERS,
    VIRTUAL_MACHINES,
    NAS_SETTINGS,
    TRANSFERS,
    SETTINGS,
}

enum class ModuleUnavailableReason {
    ACCESS_DENIED,
    ACCESS_UNREAD,
    ACCESS_FAILED,
    AUTHENTICATION_REQUIRED,
    FEATURE_UNSUPPORTED,
    SYNOLOGY_PHOTOS,
    CHAT_SERVICE,
    DOWNLOAD_STATION,
    CONTAINER_MANAGER,
    VIRTUAL_MACHINE_MANAGER,
}

enum class NasPowerAction { SHUTDOWN, REBOOT }

data class ModuleAvailability(
    val module: Module,
    val isAvailable: Boolean,
    val reason: ModuleUnavailableReason? = null,
    val access: ModuleAccessState = if (isAvailable) ModuleAccessState.ALLOWED else ModuleAccessState.UNSUPPORTED,
)

/** 账号授权与接口能力分别读取；未读取不能当作允许。 */
enum class ModuleAccessState { ALLOWED, DENIED, UNSUPPORTED, UNREAD, FAILED, AUTHENTICATION_REQUIRED }
