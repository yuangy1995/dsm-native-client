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
    EMPTY_FILE_UNSUPPORTED,
    CHANGE_NOT_CONFIRMED,
    UPLOAD_FAILED,
    UPLOAD_NOT_ALLOWED,
    UPLOAD_LENGTH_MISMATCH,
    DOWNLOAD_FAILED,
    DOWNLOAD_LENGTH_MISMATCH,
    PREVIEW_TOO_LARGE,
}

data class DsmFailure(
    val code: Int?,
    override val message: String,
    val recovery: String,
    val isAuthenticationFailure: Boolean = false,
    val kind: DsmErrorKind = DsmErrorKind.UNKNOWN,
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
)
