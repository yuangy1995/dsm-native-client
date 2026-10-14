package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.net.URLDecoder
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

internal class NasServiceProtocolFixture : Interceptor {
    val backend = NasServiceSettingsFixture(); val requests = mutableListOf<Request>()
    var writeRejectionCode: Int? = null
    var knownEnvironment = true; var ownerValid = true; var requestFormat = "JSON"
    fun repository(session: String = "session", identity: String = "identity", username: String = "Current", address: String = "https://synthetic.invalid"): DsmRepository {
        val profile = NasProfile("synthetic-service", "Synthetic", address, username)
        val caps = NasServiceStep.entries.associate { it.api to ApiCapability(it.api, "entry.cgi", backend.versions.getValue(it).first, backend.versions.getValue(it).last, requestFormat) } +
            ("SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 1, requestFormat)) +
            if (backend.applySupported) mapOf(firewallApplyApi to ApiCapability(firewallApplyApi, "entry.cgi", 1, 1, requestFormat)) else emptyMap()
        return authorizedRepository(profile, DsmSession("synthetic-session", "synthetic-sid", "synthetic-token"), DsmApiClient(OkHttpClient.Builder().addInterceptor(this).build()), caps).also {
            it.bindOwner(WorkspaceOwner(profile.id, identity, session)) { if (!ownerValid) throw DsmFailure(null, "Synthetic stale owner", "", kind = DsmErrorKind.WORKSPACE_CHANGED) }
        }
    }
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request(); synchronized(requests) { requests += request }
        val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val fields = body.split('&').associate { field -> val pair = field.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8") }
        val api = fields.getValue("api")
        val data = if (api == "SYNO.Core.System") NasServiceSettingsFixture.row(if (knownEnvironment)
            """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}"""
            else """{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""")
        else runBlocking { backend.call(api, fields.getValue("method"), fields.getValue("version").toInt(), fields.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }
            .mapValues { (key, value) -> if (requestFormat == "JSON" || key !in setOf("http_host", "ifname", "name", "task_id", "set_type", "dual_fan_speed", "mode", "net_server_ip", "snmp_server_ip")) Json.parseToJsonElement(value) else JsonPrimitive(value) }, request.body?.isOneShot() == true) }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
            .body(buildJsonObject { if (request.body?.isOneShot() == true && writeRejectionCode != null) { put("success", false); put("error", buildJsonObject { put("code", requireNotNull(writeRejectionCode)) }) }
                else { put("success", true); put("data", data) } }.toString().toResponseBody("application/json".toMediaType())).build()
    }
}
