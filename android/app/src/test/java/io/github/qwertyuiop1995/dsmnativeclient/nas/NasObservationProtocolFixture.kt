package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.io.IOException
import java.net.URLDecoder
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

internal class NasObservationProtocolFixture : Interceptor {
    data class Request(val api: String, val method: String, val version: Int, val fields: Map<String, String>, val write: Boolean)
    val requests = mutableListOf<Request>()
    var logs: (Int, Int) -> JsonObject = { offset, _ -> logPage(offset) }
    var processes = Json.parseToJsonElement("""{"process":[{"pid":10,"command":"/synthetic/bin/worker --token=synthetic-secret","status":"sleeping","account":"synthetic-account","environment":{"secret":"synthetic-secret"},"group_id":"synthetic.service"}],"total":1}""").jsonObject
    var groups = Json.parseToJsonElement("""{"slices":[{"unit_name":"synthetic.service","name":"/synthetic/services/worker","process":[{}]}]}""").jsonObject
    var failingApi: String? = null; var beforeRead: ((Request) -> Unit)? = null
    var groupsSupported = true; var minimumVersion = 1; var requestFormat = "JSON"; var ownerValid = true
    fun repository(session: String = "session"): DsmRepository {
        val profile = NasProfile("synthetic-observation", "Synthetic", "https://synthetic.invalid", "Current")
        val capabilities = listOfNotNull(SYSTEM_LOG, SYSTEM_PROCESS, SYSTEM_PROCESS_GROUP.takeIf { groupsSupported })
            .associateWith { ApiCapability(it, "entry.cgi", minimumVersion, 2, requestFormat) }
        return authorizedRepository(profile, DsmSession("synthetic-sid", "synthetic-token"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(this).build()), capabilities).also {
            it.bindOwner(WorkspaceOwner(profile.id, "identity", session)) { if (!ownerValid) throw DsmFailure(null, "Synthetic stale owner", "", kind = DsmErrorKind.WORKSPACE_CHANGED) }
        }
    }
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request(); val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val fields = body.split('&').associate { field -> val parts = field.split('=', limit = 2)
            URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8") }
        val record = Request(fields.getValue("api"), fields.getValue("method"), fields.getValue("version").toInt(), fields, request.body?.isOneShot() == true)
        synchronized(requests) { requests += record }; beforeRead?.invoke(record)
        if (record.api == failingApi) throw IOException("Synthetic read failure")
        val data = when (record.api) {
            SYSTEM_LOG -> logs(fields.getValue("offset").toInt(), fields.getValue("limit").toInt())
            SYSTEM_PROCESS -> processes; SYSTEM_PROCESS_GROUP -> groups; else -> error("Unexpected synthetic request")
        }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
            .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
    }
    companion object {
        fun logPage(offset: Int = 0, count: Int = 1, total: Int? = 250) = buildJsonObject {
            put("items", JsonArray((offset until offset + count).map { index -> buildJsonObject {
                put("descr", "Synthetic entry $index"); put("time", "2026-10-13 12:00:00"); put("level", "info"); put("who", "Synthetic account"); put("logtype", "system")
            } })); total?.let { put("total", it) }
        }
    }
}
