package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.time.LocalDate
import kotlinx.serialization.Serializable

@Serializable
enum class FileShareStatus { VALID, INVALID, INACTIVE, EXPIRED, BROKEN, UNKNOWN }
@Serializable
enum class FileShareProtection { NONE, PASSWORD, USERS }
enum class FileSharePrincipalKind { USER, GROUP }

data class FileSharePrincipal(val name: String, val kind: FileSharePrincipalKind)
data class FileSharePrincipalPage(val items: List<FileSharePrincipal>, val total: Int, val nextOffset: Int)

@Serializable
data class FileShareAdvancedDetails(
    val protection: FileShareProtection,
    val users: Set<String>,
    val groups: Set<String>,
    val maximumAccesses: Int,
    val isFileRequest: Boolean,
    val allowsUpload: Boolean,
    val requestName: String,
    val requestMessage: String,
)

@Serializable
data class FileRequestConfiguration(val name: String, val message: String)

/** 密码不提供数据类的自动字符串表示，且不参与任何持久化。 */
sealed interface FileSharePasswordChange {
    data object Keep : FileSharePasswordChange
    data object Remove : FileSharePasswordChange
    class Set(val value: String) : FileSharePasswordChange
}

sealed interface FileShareDateChange {
    data object Keep : FileShareDateChange
    data object Clear : FileShareDateChange
    data class Set(val date: LocalDate) : FileShareDateChange
}

sealed interface FileShareAudienceChange {
    data object Keep : FileShareAudienceChange
    data object Anyone : FileShareAudienceChange
    data class Principals(val members: Set<FileSharePrincipal>) : FileShareAudienceChange
}

data class FileShareAdvancedChange(
    val audience: FileShareAudienceChange = FileShareAudienceChange.Keep,
    val maximumAccesses: Int? = null,
    val requestName: String? = null,
    val requestMessage: String? = null,
)

class FileShareCreateRequest(
    val target: FileItem,
    val password: String? = null,
    val availableOn: LocalDate? = null,
    val expiresOn: LocalDate? = null,
    val fileRequest: FileRequestConfiguration? = null,
) {
    val isValid: Boolean get() = (password == null || password.isNotEmpty() && password.codePointCount(0, password.length) <= 16) &&
        (availableOn == null || expiresOn == null || availableOn <= expiresOn) &&
        (fileRequest == null || target.isDirectory)
}

class FileShareEditRequest(
    val baseline: FileShareLink,
    val password: FileSharePasswordChange = FileSharePasswordChange.Keep,
    val availableOn: FileShareDateChange = FileShareDateChange.Keep,
    val expiresOn: FileShareDateChange = FileShareDateChange.Keep,
    val advanced: FileShareAdvancedChange? = null,
) {
    val isValid: Boolean get() {
        if (!baseline.passwordKnown || !baseline.availabilityKnown || !baseline.expirationKnown) return false
        if (password is FileSharePasswordChange.Set && (password.value.isEmpty() || password.value.codePointCount(0, password.value.length) > 16)) return false
        val start = availableOn.resolve(baseline.availableAt)
        val end = expiresOn.resolve(baseline.expiresAt)
        if (start != null && end != null && start > end) return false
        if (advanced != null) {
            val original = baseline.advanced ?: return false
            if (advanced.maximumAccesses?.let { it !in 0..9999 } == true) return false
            if (advanced.audience != FileShareAudienceChange.Keep && (password != FileSharePasswordChange.Keep || original.isFileRequest)) return false
            if (advanced.audience is FileShareAudienceChange.Principals &&
                (advanced.audience.members.isEmpty() || advanced.audience.members.any { it.name.isBlank() })) return false
            if (!original.isFileRequest && (advanced.requestName != null || advanced.requestMessage != null)) return false
        }
        return password != FileSharePasswordChange.Keep || availableOn != FileShareDateChange.Keep ||
            expiresOn != FileShareDateChange.Keep || advanced != null
    }
}

internal fun FileShareDateChange.resolve(original: String?): LocalDate? = when (this) {
    FileShareDateChange.Keep -> original?.let { LocalDate.parse(it.take(10)) }
    FileShareDateChange.Clear -> null
    is FileShareDateChange.Set -> date
}
