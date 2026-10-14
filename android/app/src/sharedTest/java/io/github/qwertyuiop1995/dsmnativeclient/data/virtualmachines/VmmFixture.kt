package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

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

/** 只替换 HTTP 后端；权限、请求编码、owner 与操作记录均使用正式实现。 */
internal class VmmFixture : Interceptor {
    data class Call(val api: String, val method: String, val version: Int, val fields: Map<String, JsonElement>, val oneShot: Boolean)
    val calls = java.util.concurrent.CopyOnWriteArrayList<Call>()
    val requests = java.util.concurrent.CopyOnWriteArrayList<Request>()
    val writes get() = calls.filter { it.method in setOf("poweron", "shutdown", "poweroff", "pwr_ctl", "delete", "set", "create", "clear") }
    var admin = true; var allowed = true; var ownerValid = true; var known = true; var packageVersion = "2.6.5-12202"
    var extraCapabilities = emptyList<String>()
    var public = true; var internal = true; var format = "JSON"; var applyWrite = true; var rejection: Int? = null
    var versions = emptyMap<String, IntRange>(); var total: Int? = null
    var before: (Call) -> Unit = {}; var after: (Call) -> Unit = {}
    var responseOverride: (Call) -> JsonObject? = { null }
    var guests = listOf(guest()); var getOverride: JsonObject? = null
    var networks = listOf(network()); var networkGuests = emptyList<JsonObject>(); var networkDetailOverride: JsonObject? = null
    var frozen: JsonElement = JsonPrimitive(false); var networkTotal: Int? = null
    var images = listOf(image()); var imageTotal: Int? = null; var imageFrozen: JsonElement = JsonPrimitive(false)
    var isoImages: JsonElement = JsonArray(listOf(JsonPrimitive("unmounted")))
    var errors = emptyMap<Pair<String, String>, Int>()
    val profile = NasProfile("synthetic-vmm-${UUID.randomUUID()}", "Synthetic", "https://synthetic.invalid", "Synthetic user")
    fun capabilities(): Map<String, ApiCapability> {
        val names = listOf("SYNO.Core.System", "SYNO.Core.Package") + extraCapabilities +
            (if (public) listOf("SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Guest.Action", "SYNO.Virtualization.API.Guest.Image", "SYNO.Virtualization.API.Storage", "SYNO.Virtualization.API.Network", "SYNO.Virtualization.API.Task.Info") else emptyList()) +
            (if (internal) listOf("SYNO.Virtualization.Guest", "SYNO.Virtualization.Guest.Action", "SYNO.Virtualization.Guest.Image", "SYNO.Virtualization.Network", "SYNO.Virtualization.Repo", "SYNO.Virtualization.Cluster", "SYNO.Virtualization.Setting.General") else emptyList())
        return names.associateWith { ApiCapability(it, "entry.cgi", versions[it]?.first ?: 1, versions[it]?.last ?: 3, format) }
    }
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
        val request = chain.request(); requests += request; val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val raw = body.split('&').associate { field -> val pair = field.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8") }
        val call = Call(raw.getValue("api"), raw.getValue("method"), raw.getValue("version").toInt(),
            raw.filterKeys { it !in setOf("api", "method", "version", "_sid", "SynoToken") }.mapValues { (key, value) ->
                if (format == "JSON" || key in setOf("show_dsm", "interfaces_add", "interfaces_remove")) Json.parseToJsonElement(value) else JsonPrimitive(value)
            }, request.body?.isOneShot() == true)
        calls += call; before(call)
        val denied = errors[call.api to call.method] ?: if (call in writes) rejection else null
        val data = if (denied == null) responseOverride(call) ?: response(call) else obj("{}")
        after(call)
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic").body(buildJsonObject {
            if (denied != null) { put("success", false); put("error", buildJsonObject { put("code", denied) }) }
            else { put("success", true); put("data", data) }
        }.toString().toResponseBody("application/json".toMediaType())).build()
    }
    private fun response(call: Call): JsonObject = when {
        call.api == "SYNO.Core.System" && call.method == "info" -> if (known) obj("""{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}""")
            else obj("""{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""")
        call.api == "SYNO.Core.Package" && call.method == "list" -> buildJsonObject {
            put("total", 1); put("packages", buildJsonArray { add(buildJsonObject {
                put("id", "Virtualization"); put("name", "Virtual Machine Manager"); put("version", packageVersion)
                put("additional", obj("""{"status":"running","startable":true,"install_type":"volume","ctl_uninstall":true,"dsm_apps":[],"available_operation":{}}"""))
            }) })
        }
        call.api.endsWith("Guest") && call.method == "list" -> buildJsonObject {
            put("guests", JsonArray(guests.map { source(it, call) })); put("offset", 0); put("total", total ?: guests.size)
        }
        call.api.endsWith("Guest") && call.method == "get" -> getOverride ?: source(guests.single { it["guest_id"] == call.fields["guest_id"] }, call)
        call.api == "SYNO.Virtualization.Network" && call.method == "list" -> buildJsonObject {
            put("is_freeze", frozen); put("networks", JsonArray(networks)); put("offset", 0); put("total", networkTotal ?: networks.size)
        }
        call.api == "SYNO.Virtualization.Network" && call.method == "get" -> networkDetailOverride ?: buildJsonObject {
            put("name", networks.single { it["network_id"] == call.fields["network_id"] }.getValue("name"))
            put("interfaces", JsonArray(emptyList())); put("guests", JsonArray(networkGuests))
        }
        call.api == "SYNO.Virtualization.Network" && call in writes -> {
            if (applyWrite) networks = if (call.method == "delete") networks.filter { it["network_id"] != call.fields["network_id"] }
                else networks.map { row -> if (row["network_id"] == call.fields["network_id"]) JsonObject(row + ("name" to call.fields.getValue("name"))) else row }
            obj("{}")
        }
        call.api.endsWith("Guest.Image") && call.method == "list" -> buildJsonObject {
            put("is_freeze", imageFrozen); put("images", JsonArray(images)); put("offset", 0); put("total", imageTotal ?: images.size)
        }
        call.api.endsWith("Guest.Image") && call.method == "delete" -> {
            val id = call.fields["image_id"] ?: call.fields["id"]
            if (applyWrite) images = images.filter { it["image_id"] != id && it["id"] != id }
            obj("{}")
        }
        call.api == "SYNO.Virtualization.Guest" && call.method == "get_setting" -> buildJsonObject { put("iso_images", isoImages) }
        call.api.endsWith("Guest") && call.method == "set" -> {
            if (applyWrite) guests = guests.map { row ->
                if (row["guest_id"] != call.fields["guest_id"]) row else JsonObject(row.toMutableMap().apply {
                    for ((key, value) in call.fields) when (key) {
                        "new_guest_name", "name" -> { put("guest_name", value); put("name", value) }
                        "description", "desc" -> { put("description", value); put("desc", value) }
                        "vcpu_num", "vram_size", "cpu_weight", "autorun" -> put(key, JsonPrimitive(value.jsonPrimitive.content.toInt()))
                    }
                })
            }
            obj("{}")
        }
        call in writes -> {
            if (applyWrite) {
                val action = (call.fields["action"] as? JsonPrimitive)?.content ?: call.method
                guests = if (action == "delete") guests.filter { it["guest_id"] != call.fields["guest_id"] }
                    else guests.map { row -> if (row["guest_id"] == call.fields["guest_id"]) JsonObject(row +
                        ("status" to JsonPrimitive(if (action in setOf("poweron", "reboot")) "running" else "shutdown"))) else row }
            }
            obj("{}")
        }
        else -> error("Unexpected synthetic VMM request: ${call.api}/${call.method}")
    }
    private fun source(row: JsonObject, call: Call) = if (call.api.contains(".API.")) JsonObject(row - "name" - "desc" - "cpu_weight") else JsonObject((row - "guest_name" - "description").toMutableMap().apply {
        row["vram_size"]?.jsonPrimitive?.intOrNull?.let { put("vram_size", JsonPrimitive(it.toLong() * 1024)) }
    })
    companion object {
        fun obj(value: String) = Json.parseToJsonElement(value) as JsonObject
        fun network(id: String = "network-1", name: String = "Synthetic network", type: String = "external", count: Int = 0) = buildJsonObject {
            put("network_id", id); put("name", name); put("type", type); put("host_id", if (type == "private") "host-1" else ""); put("vlan_id", 0)
            put("interfaces", buildJsonArray { if (type == "external") add(obj("""{"host_id":"host-1","interface_id":"interface-1"}""")) })
            put("num_interfaces", if (type == "external") 1 else 0); put("num_hosts", 1); put("num_vinterfaces", 0); put("num_guests", count)
        }
        fun networkGuest(id: String = "synthetic-guest", running: Boolean = false) = buildJsonObject {
            put("guest_id", id); put("name", "Synthetic guest"); put("running", running); put("prefer_sriov", false); put("use_vf", false)
            put("mac_addr", "00:00:00:00:00:00"); put("vinterface_names", "Synthetic interface")
        }
        fun image(id: String = "image-1", name: String = "Synthetic image", type: String = "disk", storage: String = "storage-1", host: String = "host-1") = buildJsonObject {
            put("id", id); put("image_id", id); put("name", name); put("image_name", name); put("type", type); put("repo_id", storage); put("host_id", host)
            put("status", "online"); put("status_type", "healthy")
        }
        fun guest(id: String = "synthetic-guest", name: String = "Synthetic VM", status: String = "shutdown") = buildJsonObject {
            put("guest_id", id); put("guest_name", name); put("name", name); put("status", status)
            put("description", "Synthetic description"); put("desc", "Synthetic description"); put("vcpu_num", 2); put("vram_size", 1024); put("cpu_weight", 256); put("autorun", 1)
        }
    }
}
