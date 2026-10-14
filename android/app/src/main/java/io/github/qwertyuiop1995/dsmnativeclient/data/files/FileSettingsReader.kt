package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*

/** Settings/VFS.User 的字段类型不同，编号字符串兼容仅限已核对的 VFS.User 名单。 */
internal class FileSettingsReader(
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val owner: () -> WorkspaceOwner?, private val requireOwner: () -> Unit,
) {
    suspend fun theme(): FileSharingTheme {
        val identity = identity()
        val data = call(FILE_SHARING_THEME_API, "get", emptyMap(), 1)
        fun sequence(key: String): String? {
            val raw = data[key]; if (raw == null || raw is JsonNull) return null
            val value = raw as? JsonPrimitive ?: throw settingsReadFailure()
            return if (value.isString) value.content else value.longOrNull?.toString() ?: throw settingsReadFailure()
        }
        val result = FileSharingTheme(identity, data.settingsBool("enable_logo_customize"), data.settingsBool("enable_background_customize"),
            FileThemeLogoPosition.entries.singleOrNull { it.value == data.settingsText("logo_position") } ?: throw settingsReadFailure(),
            FileThemeBackgroundPosition.entries.singleOrNull { it.value == data.settingsText("background_position") } ?: throw settingsReadFailure(),
            data.settingsText("background_color"), data.settingsText("footer_msg"), data.settingsBool("enable_footer_html"),
            sequence("logo_seq"), sequence("background_seq"))
        requireOwner(); return result
    }
    suspend fun general(): FileStationSettings {
        val identity = identity()
        val data = call(FILE_SETTINGS_API, "get", emptyMap(), 1)
        val limit = data.settingsText("sharing_default_limit").takeIf { it.isNotEmpty() && it.all(Char::isDigit) }
            ?.toIntOrNull()?.takeIf { it in 0..999_999_999 } ?: throw settingsReadFailure()
        val schedule = data.settingsText("schedule_plan")
        val remote = scope(data.settingsText("rf_allow")); val iso = scope(data.settingsText("vd_allow"))
        if (remote == FileSettingsScope.SELECTED || iso == FileSettingsScope.SELECTED ||
            schedule.isNotEmpty() && !FileWeeklySchedule.valid(schedule, false)) throw settingsReadFailure()
        val result = FileStationSettings(identity, data.settingsBool("transfer_log_enable"), data.settingsBool("use_unix_default_perm"),
            data.settingsBool("enable_list_usergrp"), scope(data.settingsText("sharing_allow")), scope(data.settingsText("file_request_allow")), remote, iso,
            members(data, "sharing"), members(data, "file_request"), limit, when (data.settingsText("bandwidth_enable")) {
                "bandwidth_disable" -> FileBandwidthPolicy.DISABLED; "bandwidth_enable" -> FileBandwidthPolicy.ENABLED
                "bandwidth_schedule" -> FileBandwidthPolicy.SCHEDULED; else -> throw settingsReadFailure()
            }, schedule, when ((data["enable_sharing_custom_setting"] as? JsonPrimitive)?.takeIf { it.isString }?.content) {
                "true" -> true; "false" -> false; else -> null
            })
        requireOwner(); return result
    }
    suspend fun mountScope(): FileMountScope {
        requireOwner()
        val data = call(FILE_MOUNT_USER_API, "get", mapOf("content" to "user_enabled_type"), 1)
        val result = FileMountScope.entries.singleOrNull { it.value == data.settingsText("user_enabled_type") } ?: throw settingsReadFailure()
        requireOwner(); return result
    }
    suspend fun directories(): FileMountDirectories {
        requireOwner(); val items = mutableListOf(FileMountDirectory(FileMountAccountSource(FileMountSourceKind.LOCAL), ""))
        var unavailable = false
        try {
            if (call(FILE_DIRECTORY_LDAP_API, "get", emptyMap(), 1).settingsBool("enable_client"))
                items += FileMountDirectory(FileMountAccountSource(FileMountSourceKind.LDAP), "")
        } catch (error: Exception) { rethrowCritical(error); unavailable = true }
        try {
            if (call(FILE_DIRECTORY_DOMAIN_API, "get", emptyMap(), 1).settingsBool("enable_domain")) {
                if (!call(FILE_DIRECTORY_DOMAIN_API, "test_dc", emptyMap(), 1).settingsBool("test_join_success")) unavailable = true
                else {
                    val rows = call(FILE_DIRECTORY_DOMAIN_API, "get_domain_list", emptyMap(), 2)["domain_list"] as? JsonArray ?: throw settingsReadFailure()
                    val domains = rows.map { row ->
                        val name: String; val value: String
                        when (row) {
                            is JsonPrimitive -> { name = row.takeIf { it.isString }?.content ?: throw settingsReadFailure(); value = name }
                            is JsonArray -> {
                                if (row.size < 2 || row.any { it !is JsonPrimitive || !it.isString }) throw settingsReadFailure()
                                name = row[0].jsonPrimitive.content; value = row[1].jsonPrimitive.content
                            }
                            else -> throw settingsReadFailure()
                        }
                        if (name.isEmpty() || value.isEmpty()) throw settingsReadFailure()
                        FileMountDirectory(FileMountAccountSource(FileMountSourceKind.DOMAIN, value), name)
                    }
                    if (domains.isEmpty() || domains.map { it.source }.distinct().size != domains.size) throw settingsReadFailure()
                    items += domains
                }
            }
        } catch (error: Exception) { rethrowCritical(error); unavailable = true }
        requireOwner(); return FileMountDirectories(items, unavailable)
    }
    suspend fun policyAccounts(kind: FileSharePrincipalKind, query: String, offset: Int, limit: Int = 200): FileSettingsPage<FileSettingsAccount> {
        validatePage(offset, limit); requireOwner()
        val user = kind == FileSharePrincipalKind.USER
        val data = call(FILE_SETTINGS_PRINCIPAL_API, if (user) "list_user" else "list_group",
            mapOf("type" to "all", "query" to query, "offset" to offset.toString(), "limit" to limit.toString()), 1)
        val rows = data.settingsRows(if (user) "users" else "groups").map { row ->
            val value = row.settingsLong(if (user) "uid" else "gid")
            val name = row.settingsText("name")
            if (value < 0 || name.isEmpty()) throw settingsReadFailure()
            FileSettingsAccount(FileSettingsAccountId(kind, value), name,
                if (user || "is_admin" in row) row.settingsBool("is_admin") else false)
        }
        requireOwner(); return page(data, rows, offset, limit) { it.id }
    }
    suspend fun mountAccounts(source: FileMountAccountSource, kind: FileSharePrincipalKind, query: String,
                              offset: Int, limit: Int = 200): FileSettingsPage<FileMountAccount> {
        validatePage(offset, limit); if (!source.valid) throw settingsChanged()
        val identity = identity(); val user = kind == FileSharePrincipalKind.USER
        val fields = mapOf("content" to if (user) "user_settings" else "group_settings", "usergroup" to if (user) "user" else "group",
            "type" to source.kind.value, "substr" to query, "offset" to offset.toString(), "limit" to limit.toString()) +
            if (source.kind == FileMountSourceKind.DOMAIN) mapOf("domain" to source.domain) else emptyMap()
        val data = call(FILE_MOUNT_USER_API, "get", fields, 1)
        val rows = data.settingsRows("usergrp_settings").map { row ->
            val primitive = row[if (user) "uid" else "gid"] as? JsonPrimitive ?: throw settingsReadFailure()
            val value = if (primitive.isString) primitive.content.takeIf { it.isNotEmpty() && it.all { c -> c in '0'..'9' } }?.toLongOrNull()
                else primitive.longOrNull
            val name = row.settingsText("name")
            if (value == null || value < 0 || name.isEmpty()) throw settingsReadFailure()
            FileMountAccount(identity, source, FileSettingsAccountId(kind, value), name, row.settingsBool("enabled"), row.settingsBool("is_modifiable"))
        }
        requireOwner(); return page(data, rows, offset, limit) { it.id }
    }
    suspend fun bandwidth(type: FileBandwidthOwner, offset: Int, limit: Int = 200): FileSettingsPage<FileBandwidthEntry> {
        validatePage(offset, limit); val identity = identity()
        val data = call(FILE_BANDWIDTH_API, "list", mapOf("protocol" to "FileStation", "owner_type" to type.value,
            "offset" to offset.toString(), "limit" to limit.toString()), 1)
        val rows = data.settingsRows("bandwidths").map { row ->
            val name = row.settingsText("name"); val schedule = row.settingsText("schedule_plan")
            if (name.isEmpty() || row.settingsText("protocol") != "FileStation" || row.settingsText("owner_type") != type.value ||
                schedule.isNotEmpty() && !FileWeeklySchedule.valid(schedule, true)) throw settingsReadFailure()
            val policy = FileBandwidthPolicy.entries.singleOrNull { it.value == row.settingsText("policy") } ?: throw settingsReadFailure()
            FileBandwidthEntry(identity, name, type, policy, schedule, row.settingsInt("upload_limit_1"), row.settingsInt("download_limit_1"),
                row.settingsInt("upload_limit_2"), row.settingsInt("download_limit_2")).also {
                if (listOf(it.uploadLimit, it.downloadLimit, it.alternateUploadLimit, it.alternateDownloadLimit).any { n -> n < 0 }) throw settingsReadFailure()
            }
        }
        requireOwner(); return page(data, rows, offset, limit) { it.name }
    }
    private fun identity(): WorkspaceOwner { requireOwner(); return owner() ?: throw workspaceStorageFailure() }
    private fun rethrowCritical(error: Exception) {
        if (error is CancellationException || error is DsmFailure && (error.isAuthenticationFailure || error.kind in setOf(
                DsmErrorKind.WORKSPACE_CHANGED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED,
                DsmErrorKind.TLS_UNTRUSTED))) throw error
        requireOwner()
    }
    private fun scope(value: String) = FileSettingsScope.entries.singleOrNull { it.value == value } ?: throw settingsReadFailure()
    private fun members(data: JsonObject, prefix: String): Set<FileSettingsAccountId> = buildSet {
        for (kind in FileSharePrincipalKind.entries) {
            val seen = mutableSetOf<Long>(); val user = kind == FileSharePrincipalKind.USER
            val field = prefix + if (user) "_privilege" else "_group_privilege"
            val values = (data[field] as? JsonObject)?.settingsRows("items") ?: throw settingsReadFailure()
            for (row in values) {
                val value = row.settingsLong(if (user) "uid" else "gid")
                if (value < 0 || !seen.add(value)) throw settingsReadFailure()
                if (row.settingsBool("enabled")) add(FileSettingsAccountId(kind, value))
            }
        }
    }
    private fun validatePage(offset: Int, limit: Int) { if (offset < 0 || limit !in 1..200) throw settingsChanged() }
    private fun <T, K> page(data: JsonObject, rows: List<T>, offset: Int, limit: Int, key: (T) -> K): FileSettingsPage<T> {
        val total = data.settingsInt("total")
        if (total < offset || rows.size > limit || rows.size > total - offset || rows.isEmpty() && total > offset ||
            rows.map(key).distinct().size != rows.size || "offset" in data && data.settingsInt("offset") != offset) throw settingsReadFailure()
        return FileSettingsPage(rows, total, offset + rows.size)
    }
}

internal const val FILE_SETTINGS_API = "SYNO.FileStation.Settings"
internal const val FILE_SHARING_THEME_API = "SYNO.Core.Theme.FileSharingLogin"
internal const val FILE_THEME_IMAGE_API = "SYNO.Core.Theme.Image"
internal const val FILE_SETTINGS_PRINCIPAL_API = "SYNO.FileStation.UserGrp"
internal const val FILE_MOUNT_USER_API = "SYNO.FileStation.VFS.User"
internal const val FILE_BANDWIDTH_API = "SYNO.Core.BandwidthControl"
internal const val FILE_DIRECTORY_LDAP_API = "SYNO.Core.Directory.LDAP"
internal const val FILE_DIRECTORY_DOMAIN_API = "SYNO.Core.Directory.Domain"
internal fun settingsReadFailure() = DsmFailure(null, "Settings could not be read", "Refresh and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun settingsChanged() = DsmFailure(null, "The settings have changed", "Refresh and make your changes again.", kind = DsmErrorKind.FILE_SETTINGS_CHANGED)
internal fun JsonObject.settingsRows(key: String) = (this[key] as? JsonArray)?.map { it as? JsonObject ?: throw settingsReadFailure() } ?: throw settingsReadFailure()
internal fun JsonObject.settingsText(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw settingsReadFailure()
internal fun JsonObject.settingsBool(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw settingsReadFailure()
internal fun JsonObject.settingsLong(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: throw settingsReadFailure()
internal fun JsonObject.settingsInt(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: throw settingsReadFailure()
