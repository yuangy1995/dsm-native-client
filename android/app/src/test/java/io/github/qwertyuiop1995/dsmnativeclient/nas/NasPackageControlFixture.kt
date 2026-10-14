package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.net.URLDecoder
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

/** 真实请求编码与授权边界，响应全部为合成数据，不连接 NAS。 */
internal class NasPackageControlFixture : Interceptor {
    data class Call(val api: String, val method: String, val version: Int, val fields: Map<String, String>, val oneShot: Boolean)
    val calls = java.util.concurrent.CopyOnWriteArrayList<Call>()
    val writes get() = calls.filter { it.method in setOf("start", "stop", "uninstall") }
    var admin = true; var ownerValid = true; var known = true; var format = "FORM"
    var versions: Map<String, IntRange> = emptyMap()
    var rejection: Int? = null; var rejectMethod = "start"; var before: (Call) -> Unit = {}
    var directory = directory(row()); var afterWrite: JsonObject? = null
    fun repository(generation: String = "generation", identity: String = "identity"): DsmRepository {
        val profile = NasProfile("synthetic-control", "Synthetic", "https://synthetic.invalid", "Synthetic user")
        val caps = listOf("SYNO.Core.System", "SYNO.Core.Package", "SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation").associateWith {
            val range = versions[it] ?: 1..3
            ApiCapability(it, "entry.cgi", range.first, range.last, format)
        }
        val reader = WorkspaceAccessReader(caps, readPrivileges = { DesktopAppPrivileges(DesktopApplication.entries.associateWith { true }, admin) },
            readFileSession = { error("No file session") }, readPhotoAccess = {})
        return DsmRepository(profile, DsmSession(profile.id, "synthetic-sid", "synthetic-token"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(this).build()), caps, reader).also {
            it.bindOwner(WorkspaceOwner(profile.id, identity, generation)) {
                if (!ownerValid) throw DsmFailure(null, "Synthetic stale owner", "", kind = DsmErrorKind.WORKSPACE_CHANGED)
            }
            runBlocking { it.refreshAccess() }
        }
    }
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request(); val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val fields = body.split('&').associate { field -> val pair = field.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8") }
        val call = Call(fields.getValue("api"), fields.getValue("method"), fields.getValue("version").toInt(),
            fields.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }, request.body?.isOneShot() == true)
        calls += call; before(call)
        val rejected = call.method == rejectMethod && rejection != null
        val data = when (call.method) {
            "info" -> Json.parseToJsonElement(if (known) """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}"""
                else """{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""")
            "list" -> directory
            "feasibility_check" -> JsonObject(emptyMap())
            "start", "stop", "uninstall" -> { if (!rejected) afterWrite?.let { directory = it }; JsonObject(emptyMap()) }
            else -> error("Unexpected synthetic request")
        }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic").body(
            buildJsonObject {
                if (rejected) { put("success", false); put("error", buildJsonObject { put("code", requireNotNull(rejection)) }) }
                else { put("success", true); put("data", data) }
            }.toString().toResponseBody("application/json".toMediaType())).build()
    }
    companion object {
        fun row(status: String = "stopped", timestamp: Long = 1_700_000_000): JsonObject = buildJsonObject {
            put("id", "synthetic-package"); put("name", "Synthetic private display"); put("version", "1.0"); put("timestamp", timestamp)
            put("additional", buildJsonObject {
                put("status", status); put("startable", true); put("install_type", "volume"); put("ctl_uninstall", true)
                put("description", "Synthetic private description"); put("dsm_apps", JsonArray(listOf(JsonPrimitive("synthetic-app"))))
                put("available_operation", JsonObject(emptyMap()))
            })
        }
        fun directory(vararg rows: JsonObject): JsonObject = buildJsonObject { put("packages", JsonArray(rows.toList())); put("total", rows.size) }
        fun changed(row: JsonObject = row(), key: String, value: JsonElement?, additional: Boolean = true): JsonObject {
            val base = if (additional) row.getValue("additional").jsonObject else row
            val next = JsonObject(base.toMutableMap().also { if (value == null) it.remove(key) else it[key] = value })
            return if (additional) JsonObject(row + ("additional" to next)) else next
        }
    }
}
