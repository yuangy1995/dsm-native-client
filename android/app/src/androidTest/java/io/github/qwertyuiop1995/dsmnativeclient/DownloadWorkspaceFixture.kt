package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.OneShotRequestBody
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 正式客户端与模型使用合成响应；任何请求均止于本机拦截器。 */
internal class DownloadWorkspaceFixture {
    val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    val capabilities = listOf("Task" to 3, "Info" to 2, "Schedule" to 1, "RSS.Site" to 1,
        "RSS.Feed" to 1, "BTSearch" to 1).map { (name, version) ->
        ApiCapability("SYNO.DownloadStation.$name", "entry.cgi", 1, version)
    }.plus(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2)).associateBy { it.name }
    @Volatile var loseCreationReceipt = false
    @Volatile var ignorePause = false
    @Volatile var failDetails = false
    @Volatile var failList = false
    @Volatile var manager = true
    @Volatile var detailsGate: CountDownLatch? = null
    private val tasks = linkedMapOf("a" to task("a", "Synthetic alpha"), "b" to task("b", "Synthetic beta"))
    private var rssTime = 1700000000L
    private val config = mutableMapOf("default_destination" to JsonPrimitive("downloads"),
        "unzip_service_enabled" to JsonPrimitive(false), "bt_max_download" to JsonPrimitive(0),
        "http_max_download" to JsonPrimitive(0), "ftp_max_download" to JsonPrimitive(0))
    private val schedule = mutableMapOf("enabled" to JsonPrimitive(false))
    val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
        val request = chain.request()
        val body = (request.body as? OneShotRequestBody)?.delegate ?: request.body
        val fields = when (body) {
            is FormBody -> (0 until body.size).associate { body.name(it) to body.value(it) }
            is MultipartBody -> request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() } +
                body.parts.associate { part ->
                    val disposition = checkNotNull(part.headers?.get("Content-Disposition"))
                    val name = Regex("name=\"([^\"]+)\"").find(disposition)!!.groupValues[1]
                    name to if (name == "file") "<synthetic-file>" else Buffer().use { buffer -> part.body.writeTo(buffer); buffer.readUtf8() }
                }
            else -> error("Unexpected synthetic download transport")
        }
        calls += fields
        val taskApi = fields["api"] == "SYNO.DownloadStation.Task"
        if (taskApi && fields["method"] == "getinfo") detailsGate?.await(10, TimeUnit.SECONDS)
        if (taskApi && fields["method"] == "create" && loseCreationReceipt) throw IOException("Synthetic creation receipt lost")
        val failed = taskApi && (fields["method"] == "getinfo" && failDetails || fields["method"] == "list" && failList)
        val result = if (failed) buildJsonObject { put("success", false); putJsonObject("error") { put("code", 105) } }
            else buildJsonObject { put("success", true); put("data", respond(fields)) }
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(result.toString().toResponseBody("application/json".toMediaType())).build()
    }.build())
    fun writes(method: String) = synchronized(calls) { calls.filter { it["method"] == method } }
    @Synchronized fun pauseFirst() { tasks["a"] = JsonObject(tasks.getValue("a") + ("status" to JsonPrimitive("paused"))) }
    @Synchronized fun empty() { tasks.clear() }
    private fun task(id: String, title: String) = buildJsonObject {
        put("id", id); put("title", title); put("type", "bt"); put("status", "downloading"); put("size", 4096)
        putJsonObject("additional") {
            putJsonObject("detail") { put("destination", "downloads"); put("create_time", 1700000000) }
            putJsonObject("transfer") { put("size_downloaded", 1024) }
            putJsonArray("file") { add(buildJsonObject { put("filename", "synthetic.bin"); put("size", 4096) }) }
            putJsonArray("tracker") { add(buildJsonObject { put("url", "https://user:secret@tracker.example.invalid/announce?token=private"); put("status", "working") }) }
        }
    }
    private fun rows(name: String, values: List<JsonElement>) = buildJsonObject { put(name, JsonArray(values)) }
    private fun page(name: String, values: List<JsonElement>) = buildJsonObject {
        put("offset", 0); put("total", values.size); put(name, JsonArray(values))
    }
    @Synchronized private fun respond(f: Map<String, String>): JsonObject {
        val method = f.getValue("method")
        return when (f["api"]) {
            "SYNO.DownloadStation.Task" -> when (method) {
                "list" -> page("tasks", tasks.values.toList())
                "getinfo" -> rows("tasks", listOfNotNull(tasks[f["id"]]))
                "create" -> JsonObject(emptyMap())
                "pause", "resume", "delete", "edit" -> {
                    val ids = f.getValue("id").split(',')
                    for (id in ids) {
                        if (method == "delete") tasks.remove(id)
                        else if (method == "edit") {
                            val old = tasks.getValue(id); val additional = old.getValue("additional").jsonObject
                            tasks[id] = JsonObject(old + ("additional" to JsonObject(additional + ("detail" to
                                JsonObject(additional.getValue("detail").jsonObject + ("destination" to JsonPrimitive(f.getValue("destination"))))))))
                        } else if (method != "pause" || !ignorePause) tasks[id] = JsonObject(tasks.getValue(id) +
                            ("status" to JsonPrimitive(if (method == "pause") "paused" else "downloading")))
                    }
                    rows("_array", ids.map { buildJsonObject { put("id", it); put("error", 0) } })
                }
                else -> error("Unexpected synthetic task method")
            }
            "SYNO.DownloadStation.Info" -> when (method) {
                "getinfo" -> buildJsonObject { put("is_manager", manager) }
                "setserverconfig" -> { update(config, f); JsonObject(emptyMap()) }
                else -> JsonObject(config.toMap())
            }
            "SYNO.DownloadStation.Schedule" -> if (method == "setconfig") {
                update(schedule, f); JsonObject(emptyMap())
            } else JsonObject(schedule.toMap())
            "SYNO.DownloadStation.RSS.Site" -> if (method == "refresh") { rssTime++; JsonObject(emptyMap()) }
                else page("site", listOf(buildJsonObject {
                    put("id", 6); put("title", "Synthetic subscription"); put("url", "https://feed.example.invalid/rss")
                    put("username", ""); put("is_updating", false); put("last_update", rssTime)
                }))
            "SYNO.DownloadStation.RSS.Feed" -> page("feeds", listOf(buildJsonObject {
                put("title", "Synthetic RSS item"); put("size", "4096"); put("time", 1700000000)
                put("download_uri", "https://download.example.invalid/rss.torrent"); put("external_link", "")
            }))
            "SYNO.DownloadStation.BTSearch" -> when (method) {
                "getModule" -> rows("modules", listOf(buildJsonObject { put("id", "synthetic"); put("title", "Synthetic provider"); put("enabled", true) }))
                "getCategory" -> rows("categories", emptyList())
                "start" -> buildJsonObject { put("taskid", "synthetic-search") }
                "list" -> buildJsonObject { put("finished", true); putJsonArray("items") { add(buildJsonObject {
                    put("title", "Synthetic BT item"); put("size", 4096); put("seeds", 2); put("download_uri", "magnet:?xt=urn:btih:synthetic")
                }) } }
                "clean" -> JsonObject(emptyMap())
                else -> error("Unexpected synthetic search method")
            }
            "SYNO.FileStation.List" -> {
                val path = if (method == "getinfo") Json.parseToJsonElement(f.getValue("path")).jsonArray.single().jsonPrimitive.content else "/incoming"
                val folder = buildJsonObject { put("name", "incoming"); put("path", path); put("isdir", true)
                    putJsonObject("additional") { putJsonObject("perm") { put("read", true); put("write", true); put("delete", false) } } }
                if (method == "getinfo") rows("files", listOf(folder)) else page(if (method == "list_share") "shares" else "files", if (method == "list_share") listOf(folder) else emptyList())
            }
            else -> error("Unexpected synthetic download API")
        }
    }
    private fun update(values: MutableMap<String, JsonPrimitive>, fields: Map<String, String>) {
        fields.filterKeys { it in values }.forEach { (key, value) -> values[key] = when {
            key == "default_destination" -> JsonPrimitive(value)
            value in setOf("true", "false") -> JsonPrimitive(value.toBooleanStrict())
            else -> JsonPrimitive(value.toInt())
        } }
    }
}
