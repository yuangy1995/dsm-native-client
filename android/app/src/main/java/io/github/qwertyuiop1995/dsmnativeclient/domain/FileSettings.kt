package io.github.qwertyuiop1995.dsmnativeclient.domain

import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner

internal enum class FileSettingsScope(val value: String) { ADMINISTRATORS("admin"), EVERYONE("everyone"), SELECTED("per_user") }
internal enum class FileMountScope(val value: String) { ADMINISTRATORS("admin"), EVERYONE("all"), SELECTED("custom") }
internal enum class FileBandwidthPolicy(val value: String) { DISABLED("disabled"), ENABLED("enabled"), SCHEDULED("scheduled"), UNCONFIGURED("notexist") }
internal data class FileSettingsAccountId(val kind: FileSharePrincipalKind, val value: Long) {
    val field get() = if (kind == FileSharePrincipalKind.USER) "uid" else "gid"
}
internal data class FileSettingsAccount(val id: FileSettingsAccountId, val name: String, val administrator: Boolean)
internal data class FileSettingsPage<T>(val items: List<T>, val total: Int, val nextOffset: Int)

internal data class FileStationSettings(
    val owner: WorkspaceOwner, val recordsTransfers: Boolean, val usesDefaultPermissions: Boolean, val showsAccounts: Boolean,
    val sharing: FileSettingsScope, val fileRequests: FileSettingsScope, val remoteMounts: FileSettingsScope, val isoMounts: FileSettingsScope,
    val sharingAccounts: Set<FileSettingsAccountId>, val requestAccounts: Set<FileSettingsAccountId>,
    val defaultLinkLimit: Int, val bandwidth: FileBandwidthPolicy, val schedule: String, val customSharingPage: Boolean?,
) { override fun toString() = "FileStationSettings" }

internal enum class FileMountSourceKind(val value: String) { LOCAL("local"), LDAP("ldap"), DOMAIN("domain") }
/** 域名称保留请求值，与界面显示名分开。 */
internal data class FileMountAccountSource(val kind: FileMountSourceKind, val domain: String = "") {
    val valid get() = if (kind == FileMountSourceKind.DOMAIN) domain.isNotEmpty() else domain.isEmpty()
    override fun toString() = "FileMountAccountSource($kind)"
}
internal data class FileMountDirectory(val source: FileMountAccountSource, val name: String)
internal data class FileMountDirectories(val items: List<FileMountDirectory>, val hasUnavailableSources: Boolean)
internal data class FileMountAccount(
    val owner: WorkspaceOwner, val source: FileMountAccountSource, val id: FileSettingsAccountId,
    val name: String, val enabled: Boolean, val canModify: Boolean,
) { override fun toString() = "FileMountAccount" }

internal enum class FileBandwidthOwner(val value: String, val isGroup: Boolean) {
    LOCAL_USER("local_user", false), LOCAL_GROUP("local_group", true), LDAP_USER("ldap_user", false), LDAP_GROUP("ldap_group", true),
    DOMAIN_USER("domain_user", false), DOMAIN_GROUP("domain_group", true),
}
internal data class FileBandwidthEntry(
    val owner: WorkspaceOwner, val name: String, val ownerType: FileBandwidthOwner, val policy: FileBandwidthPolicy,
    val schedule: String, val uploadLimit: Int, val downloadLimit: Int, val alternateUploadLimit: Int, val alternateDownloadLimit: Int,
) { override fun toString() = "FileBandwidthEntry($ownerType, $policy)" }

internal object FileWeeklySchedule {
    /** 官方时间表按星期日至星期六、每天 0…23 时排列；服务级 0/1，账号级 0/1/2。 */
    fun valid(value: String, perAccount: Boolean) = value.length == 168 && value.all { it in '0'..if (perAccount) '2' else '1' }
    fun index(day: Int, hour: Int): Int { require(day in 0..6 && hour in 0..23); return day * 24 + hour }
}

internal sealed interface FileSettingsChange {
    data class General(val baseline: FileStationSettings, val updated: FileStationSettings) : FileSettingsChange
    data class MountScope(val owner: WorkspaceOwner, val baseline: FileMountScope, val updated: FileMountScope) : FileSettingsChange
    data class MountAccount(val baseline: FileMountAccount, val enabled: Boolean) : FileSettingsChange
    data class Bandwidth(val baseline: FileBandwidthEntry, val updated: FileBandwidthEntry) : FileSettingsChange
    data class Theme(val baseline: FileSharingTheme, val updated: FileSharingTheme) : FileSettingsChange
}

internal enum class FileSettingsRisk { SHARING, FILE_REQUESTS, REMOTE_MOUNTS, ISO_MOUNTS, ACCOUNT_NAMES }
internal fun FileSettingsChange.risks(): Set<FileSettingsRisk> = buildSet {
    fun widens(old: FileSettingsScope, new: FileSettingsScope) = old != new && (new == FileSettingsScope.EVERYONE || old == FileSettingsScope.ADMINISTRATORS)
    when (val change = this@risks) {
        is FileSettingsChange.General -> {
            val old = change.baseline; val new = change.updated
            if (widens(old.sharing, new.sharing) || new.sharing == FileSettingsScope.SELECTED && !old.sharingAccounts.containsAll(new.sharingAccounts)) add(FileSettingsRisk.SHARING)
            if (widens(old.fileRequests, new.fileRequests) || new.fileRequests == FileSettingsScope.SELECTED && !old.requestAccounts.containsAll(new.requestAccounts)) add(FileSettingsRisk.FILE_REQUESTS)
            if (widens(old.remoteMounts, new.remoteMounts)) add(FileSettingsRisk.REMOTE_MOUNTS)
            if (widens(old.isoMounts, new.isoMounts)) add(FileSettingsRisk.ISO_MOUNTS)
            if (!old.showsAccounts && new.showsAccounts) add(FileSettingsRisk.ACCOUNT_NAMES)
        }
        is FileSettingsChange.MountScope -> if (change.baseline != change.updated &&
            (change.updated == FileMountScope.EVERYONE || change.baseline == FileMountScope.ADMINISTRATORS)) add(FileSettingsRisk.REMOTE_MOUNTS)
        is FileSettingsChange.MountAccount -> if (!change.baseline.enabled && change.enabled) add(FileSettingsRisk.REMOTE_MOUNTS)
        is FileSettingsChange.Bandwidth, is FileSettingsChange.Theme -> Unit
    }
}
