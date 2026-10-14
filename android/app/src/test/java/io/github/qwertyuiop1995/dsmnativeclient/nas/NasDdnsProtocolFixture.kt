package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.net.URLDecoder
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

internal class NasDdnsProtocolFixture : Interceptor {
    data class Call(val api: String, val method: String, val version: Int, val fields: JsonObject, val oneShot: Boolean)
    val calls = mutableListOf<Call>(); val writes get() = calls.filter { it.oneShot }
    var format = "JSON"; var knownEnvironment = true; var ownerValid = true; var reject: Int? = null
    var versions = mapOf(DDNS_PROVIDER to 1, DDNS_RECORD to 1)
    var providers = JsonArray(listOf(row("""{"id":"Example","display":"Synthetic provider"}""")))
    var rows = JsonArray(emptyList()); var before: (Call) -> Unit = {}; var afterWrite: (Call) -> Unit = {}
    fun saved() { rows = JsonArray(listOf(row("""{"provider":"Example","hostname":"saved.example.invalid","username":"synthetic-user","enable":true,"heartbeat":false}"""))) }
    fun fields(vararg values: Pair<String, JsonElement>) { rows = JsonArray(listOf(JsonObject(rows.single().jsonObject + values))) }
    fun draft() = NasDdnsDraft(providerId = "Example", hostname = "created.example.invalid", username = "synthetic-user", password = "synthetic-only-secret")
    fun repository(session: String = "session", identity: String = "identity"): DsmRepository {
        val profile = NasProfile("synthetic-ddns", "Synthetic", "https://synthetic.invalid", "Current")
        val caps = versions.mapValues { (api, version) -> ApiCapability(api, "entry.cgi", version, version, format) } +
            ("SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1, format))
        return authorizedRepository(profile, DsmSession("synthetic-sid", "synthetic-token"), DsmApiClient(OkHttpClient.Builder().addInterceptor(this).build()), caps).also {
            it.bindOwner(WorkspaceOwner(profile.id, identity, session)) { if (!ownerValid) throw DsmFailure(null, "Synthetic stale owner", "", kind = DsmErrorKind.WORKSPACE_CHANGED) }
        }
    }
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request(); val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val raw = body.split('&').associate { field -> val pair = field.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8") }
        val call = Call(raw.getValue("api"), raw.getValue("method"), raw.getValue("version").toInt(), JsonObject(raw.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }
            .mapValues { (key, value) -> if (format == "JSON" || key in setOf("id", "enable", "heartbeat")) Json.parseToJsonElement(value) else JsonPrimitive(value) }), request.body?.isOneShot() == true)
        synchronized(calls) { calls += call }; before(call)
        val data = when {
            call.api == "SYNO.Core.System" -> if (knownEnvironment) row("""{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}""")
                else row("""{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""")
            call.api == DDNS_PROVIDER -> buildJsonObject { put("providers", providers) }
            call.method == "list" -> buildJsonObject { put("records", rows) }
            else -> {
                when (call.method) {
                    "create", "set" -> rows = JsonArray(listOf(JsonObject((rows.firstOrNull()?.jsonObject.orEmpty() + call.fields).filterKeys { it != "passwd" })))
                    "delete" -> rows = JsonArray(emptyList())
                    "test", "update_ip_address" -> Unit
                    else -> error("Unexpected synthetic method")
                }; afterWrite(call); JsonObject(emptyMap())
            }
        }
        val envelope = if (call.oneShot && reject != null) buildJsonObject { put("success", false); put("error", buildJsonObject { put("code", requireNotNull(reject)) }) }
            else buildJsonObject { put("success", true); put("data", data) }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
            .body(envelope.toString().toResponseBody("application/json".toMediaType())).build()
    }
    companion object { fun row(value: String) = Json.parseToJsonElement(value).jsonObject }
}
