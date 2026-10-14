package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList

/** 真实客户端的隔离协议端；所有请求止于拦截器，不访问任何 NAS。 */
internal class NasWorkspaceFixture {
    val services = NasServiceSettingsFixture()
    val region = NasRegionFixture()
    val directory = NasDirectoryFixture()
    val tasks = NasScheduledTaskFixture()
    val packages = NasPackageFixture()
    data class Call(val api: String, val method: String, val parameters: Map<String, JsonElement>, val oneShot: Boolean)
    val calls = CopyOnWriteArrayList<Call>()
    val writes get() = calls.filter { it.oneShot }
    @Volatile var loseTerminalReceipt = false
    @Volatile var packageRunning = true
    @Volatile var admin = true
    val capabilities = (NasServiceStep.entries.map { it.api } + listOf("SYNO.Core.System", REGION_SETTINGS_API,
        "SYNO.Core.User", "SYNO.Core.Group", "SYNO.Core.TaskScheduler", "SYNO.Core.EventScheduler", PACKAGE_API, PACKAGE_INSTALL,
        "SYNO.Core.Package.Server", PACKAGE_SETTINGS, PACKAGE_FEED, "SYNO.Core.Package.Info",
        "SYNO.Core.Package.Setting.Volume", "SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation",
        "SYNO.Core.Package.Installation.Download", firewallApplyApi)).associateWith { ApiCapability(it, "entry.cgi", 1, if (it == "SYNO.Core.TaskScheduler") 4 else 3, "JSON") }
    val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
        val request = chain.request()
        val encoded = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val fields = encoded.split('&').associate { value -> val pair = value.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8") }
        val call = Call(fields.getValue("api"), fields.getValue("method"), fields.filterKeys {
            it !in setOf("api", "method", "version", "_sid", "SynoToken") }.mapValues { Json.parseToJsonElement(it.value) }, request.body?.isOneShot() == true)
        calls += call
        if (call.oneShot && call.api == NasServiceStep.TERMINAL.api && loseTerminalReceipt) throw IOException("Synthetic lost receipt")
        val result = runBlocking { respond(call, fields.getValue("version").toInt()) }
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
            .body(buildJsonObject { put("success", true); put("data", result) }.toString().toResponseBody("application/json".toMediaType())).build()
    }.build())

    private suspend fun respond(c: Call, version: Int): JsonObject = when {
        c.api == "SYNO.Core.System" -> NasRegionFixture.row("""{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12,"hostname":"Synthetic NAS"}""")
        c.api == REGION_SETTINGS_API -> region.call(c.api, c.method, version, c.parameters, c.oneShot)
        c.api in setOf("SYNO.Core.User", "SYNO.Core.Group") -> directory.call(c.api, c.method, version, c.parameters, c.oneShot)
        c.api in setOf("SYNO.Core.TaskScheduler", "SYNO.Core.EventScheduler") -> tasks.call(c.api, c.method, version, c.parameters, c.oneShot)
        c.api in setOf("SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation") -> {
            when (c.method) { "start" -> packageRunning = true; "stop" -> packageRunning = false; "uninstall" -> packages.installed.remove(c.parameters.getValue("id").jsonPrimitive.content) }
            JsonObject(emptyMap())
        }
        c.api.startsWith("SYNO.Core.Package") -> {
            val result = packages.call(c.api, c.method, version, c.parameters, c.oneShot)
            if (c.api == PACKAGE_API && c.method == "list" && c.parameters["additional"].toString().contains("status")) JsonObject(result +
                ("packages" to JsonArray(result.getValue("packages").jsonArray.map { element -> val row = element.jsonObject
                    JsonObject(row + ("additional" to JsonObject(row.getValue("additional").jsonObject + ("status" to JsonPrimitive(if (packageRunning) "running" else "stopped")))) ) }))) else result
        }
        c.api in NasServiceStep.entries.map { it.api } || c.api == firewallApplyApi -> services.call(c.api, c.method, version, c.parameters, c.oneShot)
        else -> error("Unexpected synthetic NAS request: ${c.api}/${c.method}")
    }
}
