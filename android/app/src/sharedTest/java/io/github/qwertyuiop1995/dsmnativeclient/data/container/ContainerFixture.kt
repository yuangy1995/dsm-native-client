package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.net.URLDecoder
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

/** 合成后端只拦截真实工作区传输，不替换 Repository、权限或持久阶段。 */
internal class ContainerFixture : Interceptor {
    data class Call(val api: String, val method: String, val version: Int, val fields: Map<String, JsonElement>, val oneShot: Boolean)
    val calls = java.util.concurrent.CopyOnWriteArrayList<Call>()
    val writes get() = calls.filter { it.method in setOf("start", "stop", "restart", "delete", "create", "remove", "pull_start") }
    var admin = true; var allowed = true; var ownerValid = true; var known = true; var packageVersion = "24.0.2-1535"; var format = "JSON"
    var minVersion = 1; var rejection: Int? = null; var applyWrite = true
    var versions = emptyMap<String, IntRange>()
    var before: (Call) -> Unit = {}; var after: (Call) -> Unit = {}
    var controls = listOf(control()); var projects = obj("{}"); var total: Int? = null
    var logs = emptyList<JsonObject>()
    var images = listOf(image()); var imageTotal: Int? = null
    var registryTags: JsonElement = JsonArray(listOf(JsonPrimitive("stable"), JsonPrimitive("latest")))
    var taskId: JsonElement? = JsonPrimitive("synthetic-task"); var pullFinished: JsonElement = JsonPrimitive(true)
    var pullRepository = "synthetic/image"; var pullTag = "stable"; var applyPullResult = true
    var errors = emptyMap<Pair<String, String>, Int>()
    var networks = listOf(network()); var networkTotal: Int? = null; var failedNetworks: JsonElement = JsonArray(emptyList())
    val profile = NasProfile("synthetic-container-${UUID.randomUUID()}", "Synthetic", "https://synthetic.invalid", "Synthetic user")
    fun capabilities() = listOf("SYNO.Docker.Container", "SYNO.Docker.Project", "SYNO.Docker.Image", "SYNO.Docker.Network", "SYNO.Docker.Registry", "SYNO.Docker.Log")
        .associateWith { ApiCapability(it, "entry.cgi", versions[it]?.first ?: minVersion, versions[it]?.last ?: 2, format) } + mapOf(
            "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 3, format),
            "SYNO.Core.Package" to ApiCapability("SYNO.Core.Package", "entry.cgi", 1, 3, format))
    fun reader(caps: Map<String, ApiCapability>) = WorkspaceAccessReader(caps, readPrivileges = {
        DesktopAppPrivileges(DesktopApplication.entries.associateWith { allowed }, admin)
    }, readFileSession = { error("Unexpected file session") }, readPhotoAccess = {})
    fun repository(generation: String = "generation", identity: String = "identity"): DsmRepository {
        val caps = capabilities()
        return DsmRepository(profile, DsmSession(profile.id, "synthetic-sid", "synthetic-token"),
            DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(this).build()), caps, reader(caps)).also {
            it.bindOwner(WorkspaceOwner(profile.id, identity, generation)) {
                if (!ownerValid) throw DsmFailure(null, "Synthetic stale owner", "", kind = DsmErrorKind.WORKSPACE_CHANGED)
            }
            runBlocking { it.refreshAccess() }
        }
    }
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request(); val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val raw = body.split('&').associate { field -> val parts = field.split('=', limit = 2)
            URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts.getOrElse(1) { "" }, "UTF-8") }
        val call = Call(raw.getValue("api"), raw.getValue("method"), raw.getValue("version").toInt(),
            raw.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }.mapValues { (key, value) ->
                if (format == "JSON" || key in setOf("offset", "limit", "page_size", "force", "preserve_profile", "show_dsm", "images", "networks", "enable_ipv6", "disable_masquerade") ||
                    key == "task_id" && (taskId as? JsonPrimitive)?.isString == false) Json.parseToJsonElement(value) else JsonPrimitive(value)
            }, request.body?.isOneShot() == true)
        calls += call; before(call)
        val data = response(call)
        after(call)
        val denied = errors[call.api to call.method] ?: if (call in writes) rejection else null
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic").body(
            buildJsonObject {
                if (denied != null) { put("success", false); put("error", buildJsonObject { put("code", denied) }) }
                else { put("success", true); put("data", data) }
            }.toString().toResponseBody("application/json".toMediaType())).build()
    }
    fun response(call: Call): JsonObject = when (call.api to call.method) {
        "SYNO.Core.System" to "info" -> if (known) obj("""{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}""")
            else obj("""{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""")
        "SYNO.Core.Package" to "list" -> buildJsonObject {
            put("total", 1); put("packages", buildJsonArray { add(buildJsonObject {
                put("id", "ContainerManager"); put("name", "Container Manager"); put("version", packageVersion)
                put("additional", obj("""{"status":"running","startable":true,"install_type":"volume","ctl_uninstall":true,"dsm_apps":[],"available_operation":{}}"""))
            }) })
        }
        "SYNO.Docker.Container" to "list" -> buildJsonObject { put("containers", JsonArray(controls)); put("offset", 0); put("total", total ?: controls.size) }
        "SYNO.Docker.Project" to "list" -> projects
        "SYNO.Docker.Container" to "start", "SYNO.Docker.Container" to "stop", "SYNO.Docker.Container" to "restart", "SYNO.Docker.Container" to "delete" -> {
            if (applyWrite && rejection == null) {
                val name = call.fields.getValue("name").jsonPrimitive.content
                controls = if (call.method == "delete") controls.filter { it["name"] != JsonPrimitive(name) }
                    else controls.map { row -> if (row["name"] == JsonPrimitive(name)) JsonObject(row + ("State" to buildJsonObject {
                        put("Running", call.method != "stop"); put("Paused", false); put("Restarting", false)
                        put("StartedAt", if (call.method == "restart") "2026-10-13T02:00:00Z" else "2026-10-13T01:00:00Z")
                    })) else row }
            }
            obj("{}")
        }
        "SYNO.Docker.Image" to "list" -> buildJsonObject { put("images", JsonArray(images)); put("offset", 0); put("total", imageTotal ?: images.size) }
        "SYNO.Docker.Registry" to "search" -> obj("""{"data":[{"name":"synthetic/image","registry":"docker.io","is_official":true}]}""")
        "SYNO.Docker.Registry" to "tags" -> buildJsonObject { put("tags", registryTags) }
        "SYNO.Docker.Image" to "pull_start" -> buildJsonObject { taskId?.let { put("task_id", it) } }
        "SYNO.Docker.Image" to "pull_status" -> {
            if (applyPullResult && pullFinished == JsonPrimitive(true)) images = listOf(image(repository = pullRepository, tags = listOf(pullTag)))
            buildJsonObject { put("repository", pullRepository); put("tag", pullTag); put("finished", pullFinished); put("current", 1); put("total", 2) }
        }
        "SYNO.Docker.Image" to "delete" -> {
            if (applyWrite && rejection == null) for (target in call.fields.getValue("images").jsonArray.map { it.jsonObject }) {
                if (target["identity"] != null) images = images.filter { it["id"] != target["identity"] }
                else images = images.mapNotNull { row ->
                    if (row["repository"] != target["repository"]) row else {
                        val remaining = row.getValue("tags").jsonArray.filter { it !in target.getValue("tags").jsonArray }
                        if (remaining.isEmpty()) null else JsonObject(row + ("tags" to JsonArray(remaining)))
                    }
                }
            }
            obj("{}")
        }
        "SYNO.Docker.Network" to "list" -> buildJsonObject { put("network", JsonArray(networks)); put("offset", 0); put("total", networkTotal ?: networks.size) }
        "SYNO.Docker.Network" to "create" -> {
            if (applyWrite && rejection == null) networks = networks + JsonObject(network("created-id", call.fields.getValue("name").jsonPrimitive.content) + call.fields)
            obj("{}")
        }
        "SYNO.Docker.Network" to "remove" -> {
            if (applyWrite && rejection == null && failedNetworks == JsonArray(emptyList())) {
                val ids = call.fields.getValue("networks").jsonArray.map { it.jsonObject["id"] }
                networks = networks.filter { it["id"] !in ids }
            }
            buildJsonObject { put("failed", failedNetworks) }
        }
        "SYNO.Docker.Log" to "list" -> buildJsonObject { put("logs", JsonArray(logs)); put("offset", 0); put("total", logs.size) }
        else -> error("Unexpected synthetic container request: ${call.api}/${call.method}")
    }
    companion object {
        fun obj(value: String) = Json.parseToJsonElement(value) as JsonObject
        fun control(id: String = "synthetic-id", name: String = "Synthetic container", running: Boolean = false, managed: Boolean = false) = buildJsonObject {
            put("id", id); put("name", name); put("is_package", managed)
            put("image", "synthetic/other:stable")
            put("State", buildJsonObject { put("Running", running); put("Paused", false); put("Restarting", false); put("StartedAt", "2026-10-13T01:00:00Z") })
        }
        fun image(id: String = "synthetic-image", repository: String = "synthetic/image", tags: List<String> = listOf("stable")) = buildJsonObject {
            put("id", id); put("repository", repository); put("tags", JsonArray(tags.map(::JsonPrimitive))); put("size", 1024)
        }
        fun network(id: String = "synthetic-network", name: String = "Synthetic-network", containers: List<String> = emptyList()) = buildJsonObject {
            put("id", id); put("name", name); put("driver", "bridge"); put("containers", JsonArray(containers.map(::JsonPrimitive))); put("enable_ipv6", false)
            put("subnet", "192.0.2.0/24"); put("gateway", "192.0.2.1"); put("iprange", "")
        }
    }
}
