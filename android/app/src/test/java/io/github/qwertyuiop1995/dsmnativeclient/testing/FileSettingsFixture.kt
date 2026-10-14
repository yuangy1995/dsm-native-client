package io.github.qwertyuiop1995.dsmnativeclient.testing

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import java.util.Collections

/** 合成名单和设置仅用于测试；请求经过正式版本选择、权限门禁及仓储。 */
internal class FileSettingsFixture(profileId: String = "settings-feature", session: String = "session",
                                   val preferences: MemoryPreferences = MemoryPreferences()) {
    val nas = NasProfile(profileId, "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
    val owner = WorkspaceOwner(nas.id, "identity", session)
    @Volatile var allowed = true
    @Volatile var administrator = true
    @Volatile var nasAllowed = true
    @Volatile var ownerValid = true
    @Volatile var applyWrites = true
    var firmware = "DSM 7.2.1-69057 Update 12"
    var packageVersion = "1.4.1-1559"
    var before: (Map<String, String>) -> Unit = {}
    var afterWrite: (Map<String, String>) -> Unit = {}
    var overrideResponse: (Map<String, String>) -> JsonObject? = { null }
    var responseError: (Map<String, String>) -> Int? = { null }
    val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    var general = initialGeneral()
    var theme = initialTheme()
    var advanceThemeSequences = true
    var themeImages = FileThemeImageKind.entries.associateWith { emptyList<JsonObject>() }
    var uploadedPath = "/history/new.png"
    var imageBytes = byteArrayOf(1, 2, 3)
    var lastRequest: Request? = null
    var uploadBody = ""
    var mountScope = "admin"
    var ldapEnabled = true
    var domainEnabled = true
    var domainJoined = true
    var domains = JsonArray(listOf(JsonArray(listOf(JsonPrimitive("Directory display"), JsonPrimitive("DIRECTORY-REQUEST"), JsonPrimitive("Synthetic")))))
    var users = listOf(policyRow(0, "Administrator", true), policyRow(12, "Synthetic user", false))
    var groups = listOf(policyRow(20, "Synthetic group", false, true))
    var accounts: (String, Boolean) -> List<JsonObject> = { _, user -> listOf(mountRow(if (user) 12 else 20, user)) }
    private val mountOverrides = mutableMapOf<Pair<String, Boolean>, Boolean>()
    var bandwidthRows = FileBandwidthOwner.entries.associateWith { listOf(bandwidthRow(it)) }
    private val capabilities = (listOf(FILE_SETTINGS_API, FILE_MOUNT_USER_API, FILE_SETTINGS_PRINCIPAL_API, FILE_BANDWIDTH_API,
        FILE_DIRECTORY_LDAP_API, FILE_DIRECTORY_DOMAIN_API, FILE_SHARING_THEME_API, FILE_THEME_IMAGE_API, "SYNO.FileStation.Thumb", "SYNO.Core.System", "SYNO.Core.Package", "SYNO.FileStation.List")).associateWith {
        ApiCapability(it, "entry.cgi", 1, if (it in setOf("SYNO.Core.Package", FILE_DIRECTORY_DOMAIN_API, "SYNO.FileStation.List", "SYNO.FileStation.Thumb")) 2 else 1)
    }
    private val access = WorkspaceAccessReader(capabilities, {
        DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed, DesktopApplication.NAS_SETTINGS to nasAllowed), administrator)
    }, { error("Unexpected fallback") }, {})
    val repository = DsmRepository(nas, DsmSession(nas.id, "synthetic"), DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
        val request = chain.request(); lastRequest = request
        val fields = when (val body = request.body) {
            is FormBody -> (0 until body.size).associate { body.name(it) to body.value(it) }
            is MultipartBody -> {
                uploadBody = okio.Buffer().also { body.writeTo(it) }.readUtf8()
                body.parts.mapNotNull { part ->
                    val disposition = part.headers?.get("Content-Disposition").orEmpty()
                    if ("filename=" in disposition) null else Regex("name=\"([^\"]+)\"").find(disposition)?.groupValues?.get(1)?.let {
                        it to okio.Buffer().also(part.body::writeTo).readUtf8()
                    }
                }.toMap()
            }
            else -> request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
        }
        calls += fields; before(fields)
        val binary = request.method == "GET"
        val code = responseError(fields)
        val data = if (binary || code != null) null else overrideResponse(fields) ?: response(fields)
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(if (binary) imageBytes.toResponseBody("image/png".toMediaType()) else buildJsonObject {
                put("success", code == null); if (code == null) put("data", data!!) else putJsonObject("error") { put("code", code) }
            }
                .toString().toResponseBody("application/json".toMediaType())).build()
    }.build()), capabilities, access).also { repo ->
        runBlocking { repo.refreshAccess() }
        repo.bindOwner(owner) { if (!ownerValid) throw DsmFailure(null, "Changed", "Reconnect", kind = DsmErrorKind.WORKSPACE_CHANGED) }
        repo.fileSettings.bindRecovery(FileSettingsRecoveryStore(preferences))
    }
    val settings get() = repository.fileSettings
    fun writes() = synchronized(calls) { calls.filter { it["method"] == "set" }.toList() }
    private fun response(fields: Map<String, String>): JsonObject {
        val api = fields.getValue("api"); val method = fields.getValue("method")
        if (method == "set") {
            if (applyWrites) when (api) {
                FILE_SETTINGS_API -> {
                    val data = general.toMutableMap()
                    fields.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }.forEach { (key, value) ->
                        if (key.startsWith("enabled_") || key.startsWith("disabled_")) {
                            val enabled = key.startsWith("enabled_"); val privilege = key.substringAfter('_')
                            val user = !privilege.contains("_group_"); val ids = value.split(',').map(String::toLong).toSet()
                            val old = data.getValue(privilege).jsonObject.getValue("items").jsonArray.map { it.jsonObject }
                            val next = old.filterNot { it.getValue(if (user) "uid" else "gid").jsonPrimitive.long in ids } + ids.map {
                                buildJsonObject { put(if (user) "uid" else "gid", it); put("enabled", enabled) }
                            }
                            data[privilege] = buildJsonObject { put("items", JsonArray(next)) }
                        } else data[key] = if (key in setOf("transfer_log_enable", "use_unix_default_perm", "enable_list_usergrp")) JsonPrimitive(value.toBooleanStrict()) else JsonPrimitive(value)
                    }
                    general = JsonObject(data)
                }
                FILE_MOUNT_USER_API -> {
                    val values = Json.parseToJsonElement(fields.getValue("settings")).jsonObject
                    if ("user_enabled_type" in values) mountScope = values.getValue("user_enabled_type").jsonPrimitive.content
                    else {
                        val user = "user_settings" in values
                        val row = values.getValue(if (user) "user_settings" else "group_settings").jsonArray.single().jsonObject
                        mountOverrides[row.getValue(if (user) "uid" else "gid").jsonPrimitive.content to user] = row.getValue("enabled").jsonPrimitive.boolean
                    }
                }
                FILE_BANDWIDTH_API -> {
                    val row = Json.parseToJsonElement(fields.getValue("bandwidths")).jsonArray.single().jsonObject
                    val type = FileBandwidthOwner.entries.single { it.value == row.getValue("owner_type").jsonPrimitive.content }
                    bandwidthRows = bandwidthRows + (type to bandwidthRows.getValue(type).map { if (it["name"] == row["name"]) row else it })
                }
                FILE_SHARING_THEME_API -> {
                    val values = theme.toMutableMap()
                    fields.filterKeys { it in setOf("enable_logo_customize", "enable_background_customize", "logo_position", "background_position", "background_color", "footer_msg", "enable_footer_html") }
                        .forEach { (key, value) -> values[key] = if (key.startsWith("enable_")) JsonPrimitive(value.toBooleanStrict()) else JsonPrimitive(value) }
                    if (advanceThemeSequences) for (kind in FileThemeImageKind.entries) if ("${kind.value}_path" in fields)
                        values["${kind.value}_seq"] = JsonPrimitive((values["${kind.value}_seq"]!!.jsonPrimitive.content.toInt() + 1).toString())
                    theme = JsonObject(values)
                }
                else -> error("Unexpected synthetic write")
            }
            afterWrite(fields); return buildJsonObject {}
        }
        return when (api) {
            "SYNO.Core.System" -> buildJsonObject { put("firmware_ver", firmware); put("buildnumber", 69057); put("smallfixnumber", 12) }
            "SYNO.Core.Package" -> Json.parseToJsonElement("""{"total":1,"packages":[{"id":"FileStation","name":"File Station","version":"$packageVersion","status":"running","startable":true,"available_operation":[],"dsm_apps":[]}]}""").jsonObject
            FILE_SETTINGS_API -> general
            FILE_SHARING_THEME_API -> theme
            FILE_THEME_IMAGE_API -> {
                val kind = FileThemeImageKind.entries.single { it.requestType == fields["type"] }
                if (method == "list") buildJsonObject { put("list", JsonArray(themeImages.getValue(kind))) }
                else if (method == "upload") {
                    if (applyWrites) themeImages = themeImages + (kind to (themeImages.getValue(kind) + imageRow(uploadedPath, themeImages.getValue(kind).size)))
                    afterWrite(fields); buildJsonObject { put("path", uploadedPath) }
                } else error("Unexpected image request")
            }
            FILE_SETTINGS_PRINCIPAL_API -> paged(fields, if (method == "list_user") "users" else "groups",
                (if (method == "list_user") users else groups).filter { it.getValue("name").jsonPrimitive.content.contains(fields["query"].orEmpty(), true) })
            FILE_MOUNT_USER_API -> if (fields["content"] == "user_enabled_type") buildJsonObject { put("user_enabled_type", mountScope) }
                else {
                    val user = fields["usergroup"] == "user"
                    val rows = accounts(fields["domain"] ?: fields.getValue("type"), user).map { row ->
                        mountOverrides[row.getValue(if (user) "uid" else "gid").jsonPrimitive.content to user]?.let { JsonObject(row + ("enabled" to JsonPrimitive(it))) } ?: row
                    }.filter { it.getValue("name").jsonPrimitive.content.contains(fields["substr"].orEmpty(), true) }
                    paged(fields, "usergrp_settings", rows)
                }
            FILE_BANDWIDTH_API -> paged(fields, "bandwidths", bandwidthRows.getValue(FileBandwidthOwner.entries.single { it.value == fields["owner_type"] }))
            FILE_DIRECTORY_LDAP_API -> buildJsonObject { put("enable_client", ldapEnabled) }
            FILE_DIRECTORY_DOMAIN_API -> when (method) {
                "get" -> buildJsonObject { put("enable_domain", domainEnabled) }
                "test_dc" -> buildJsonObject { put("test_join_success", domainJoined) }
                "get_domain_list" -> buildJsonObject { put("domain_list", domains) }
                else -> error("Unexpected directory request")
            }
            else -> error("Unexpected synthetic read")
        }
    }
    private fun paged(fields: Map<String, String>, key: String, rows: List<JsonObject>): JsonObject {
        val offset = fields.getValue("offset").toInt(); val limit = fields.getValue("limit").toInt()
        return buildJsonObject { put("offset", offset); put("total", rows.size); put(key, JsonArray(rows.drop(offset).take(limit))) }
    }
    companion object {
        fun initialTheme() = buildJsonObject {
            put("enable_logo_customize", false); put("enable_background_customize", false); put("enable_footer_html", false)
            put("logo_position", "rightup"); put("background_position", "fill"); put("background_color", "#FFFFFF"); put("footer_msg", "")
            put("logo_seq", 1); put("background_seq", "2")
        }
        fun imageRow(path: String, index: Int) = buildJsonObject { put("path", path); put("index", index); put("filename", path.substringAfterLast('/')) }
        fun initialGeneral() = buildJsonObject {
            put("transfer_log_enable", false); put("use_unix_default_perm", false); put("enable_list_usergrp", false)
            for (field in listOf("sharing_allow", "file_request_allow", "rf_allow", "vd_allow")) put(field, "admin")
            for (field in listOf("sharing_privilege", "sharing_group_privilege", "file_request_privilege", "file_request_group_privilege"))
                putJsonObject(field) { putJsonArray("items") {} }
            put("sharing_default_limit", "0"); put("bandwidth_enable", "bandwidth_disable"); put("schedule_plan", ""); put("enable_sharing_custom_setting", "false")
        }
        fun policyRow(id: Long, name: String, admin: Boolean, group: Boolean = false) = buildJsonObject {
            put(if (group) "gid" else "uid", id); put("name", name); put("is_admin", admin)
        }
        fun mountRow(id: Long, user: Boolean, enabled: Boolean = false, modifiable: Boolean = true) = buildJsonObject {
            put(if (user) "uid" else "gid", id.toString()); put("name", if (user) "Synthetic user" else "Synthetic group")
            put("enabled", enabled); put("is_modifiable", modifiable)
        }
        fun bandwidthRow(type: FileBandwidthOwner) = buildJsonObject {
            put("name", if (type.isGroup) "Synthetic group" else "Synthetic user"); put("owner_type", type.value); put("protocol", "FileStation")
            put("policy", "notexist"); put("schedule_plan", "")
            for (key in listOf("upload_limit_1", "download_limit_1", "upload_limit_2", "download_limit_2")) put(key, 0)
        }
    }
}
