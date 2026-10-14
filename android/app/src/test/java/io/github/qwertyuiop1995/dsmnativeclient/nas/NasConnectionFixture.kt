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

internal class NasConnectionFixture : Interceptor {
    data class Call(val api: String, val method: String, val version: Int, val fields: Map<String, String>, val oneShot: Boolean)
    val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.method == "kick_connection" }
    var admin = true; var ownerValid = true; var known = true; var minVersion = 1; var format = "FORM"
    var rejection: Int? = null; var before: (Call) -> Unit = {}; var row = row(); var directory = directory(row)
    var afterWrite: JsonObject? = null
    fun repository(generation: String = "generation", identity: String = "identity"): DsmRepository {
        val profile = NasProfile("synthetic-connections", "Synthetic", "https://synthetic.invalid", "Synthetic user")
        val caps = mapOf("SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 3, format),
            "SYNO.Core.CurrentConnection" to ApiCapability("SYNO.Core.CurrentConnection", "entry.cgi", minVersion, 2, format))
        val reader = WorkspaceAccessReader(caps, readPrivileges = {
            DesktopAppPrivileges(DesktopApplication.entries.associateWith { true }, admin)
        }, readFileSession = { error("No file session") }, readPhotoAccess = {})
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
        synchronized(calls) { calls += call }; before(call)
        val data = when (call.method) {
            "info" -> Json.parseToJsonElement(if (known) """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}"""
                else """{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""")
            "list" -> directory
            "kick_connection" -> { afterWrite?.let { directory = it }; JsonObject(emptyMap()) }
            else -> error("Unexpected synthetic request")
        }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic").body(
            buildJsonObject {
                if (call.oneShot && rejection != null) { put("success", false); put("error", buildJsonObject { put("code", requireNotNull(rejection)) }) }
                else { put("success", true); put("data", data) }
            }.toString().toResponseBody("application/json".toMediaType())).build()
    }
    companion object {
        fun row(web: Boolean = true): JsonObject = buildJsonObject {
            if (web) put("did", "synthetic-device") else put("pid", 123)
            put("who", "synthetic-account"); put("from", "synthetic-source"); put("type", if (web) "HTTP/HTTPS" else "SMB")
            put("protocol", if (web) "HTTPS" else "SMB"); put("descr", "synthetic-client")
            put("time", 123456); put("is_current_connected", false); put("can_be_kicked", true)
        }
        fun directory(vararg rows: JsonObject): JsonObject = buildJsonObject { put("items", JsonArray(rows.toList())); put("total", rows.size) }
    }
}
