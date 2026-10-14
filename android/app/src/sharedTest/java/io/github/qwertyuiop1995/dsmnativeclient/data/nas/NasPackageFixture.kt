package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal data class PackageRequest(val api: String, val method: String, val version: Int, val parameters: Map<String, JsonElement>, val write: Boolean)
/** 纯合成传输，端点行为由测试控制；不连接 NAS。 */
internal class NasPackageFixture : NasPackageGateway {
    val requests = mutableListOf<PackageRequest>()
    val writes get() = requests.filter { it.write }
    val installed = mutableMapOf<String, String>()
    var quick = true
    var queue = listOf("Synthetic")
    var candidateVersion = "2.0"
    var includeUpgrade = true
    var finished = true
    var currentId = "Synthetic"
    var currentQuick = true
    var accessFailure: Exception? = null
    var intercept: (suspend (PackageRequest) -> JsonObject?)? = null
    var settings = obj("""{"update_channel":false,"enable_email":false,"enable_dsm":true,"enable_autoupdate":false,"autoupdateall":false,"autoupdateimportant":false,"volume_list":[{"mount_point":"/volume1","display":"Volume 1"}]}""")
    var preferenceRows = JsonArray(emptyList())
    var feeds = JsonArray(emptyList())
    var checked = obj("""{"id":"Synthetic","name":"Synthetic package","version":"2.0","filename":"/synthetic/package.spk","type":0,"additional":{"startable":true,"install_type":"volume","install_reboot":false}}""")
    override suspend fun requireWriteAccess() { accessFailure?.let { throw it } }
    override suspend fun upload(source: UploadSource): JsonObject {
        requests += PackageRequest(PACKAGE_INSTALL, "upload", 1, emptyMap(), true)
        return intercept?.invoke(requests.last()) ?: checked
    }
    fun raw(id: String = "Synthetic") = buildJsonObject {
        put("id", id); put("dname", "$id package"); put("version", candidateVersion); put("source", "syno"); put("qinst", quick); put("qupgrade", quick)
        put("beta", false); put("size", 10); put("link", "https://example.invalid/package.spk"); put("md5", "synthetic-checksum"); put("type", 0); put("install_type", "volume")
        put("category", packageStrings(listOf("utility")))
    }
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        val request = PackageRequest(api, method, version, parameters, write); requests += request
        intercept?.invoke(request)?.let { return it }
        return when (api to method) {
            PACKAGE_API to "list" -> if (parameters["additional"].toString().contains("silent_upgrade")) buildJsonObject {
                put("packages", preferenceRows); put("total", preferenceRows.size)
            } else buildJsonObject {
                put("total", installed.size)
                put("packages", JsonArray(installed.map { (id, version) -> buildJsonObject {
                    put("id", id); put("name", "$id package"); put("version", version)
                    put("additional", buildJsonObject { put("status", "running"); put("startable", true); put("install_type", "volume"); put("ctl_uninstall", true)
                        put("dsm_apps", JsonArray(emptyList())); put("available_operation", buildJsonObject { if (includeUpgrade && version != candidateVersion) put("upgrade", raw(id)) }) })
                } }))
            }
            "SYNO.Core.Package.Server" to "list" -> buildJsonObject {
                put("packages", if (parameters["blloadothers"] == JsonPrimitive(true)) JsonArray(emptyList()) else JsonArray(queue.map(::raw)))
                put("beta_packages", JsonArray(emptyList())); put("categories", JsonArray(listOf(obj("""{"id":"utility","dname":"Utilities"}"""))))
            }
            PACKAGE_API to "feasibility_check" -> obj("{}")
            PACKAGE_INSTALL to "get_queue" -> buildJsonObject {
                put("queue", JsonArray(queue.map { buildJsonObject { put("pkg", it); put("beta", false) } }))
                listOf("non_exist_pkgs", "conflicted_pkgs", "broken_pkgs", "replaced_pkgs", "paused_pkgs").forEach { put(it, JsonArray(emptyList())) }
            }
            PACKAGE_INSTALL to "check" -> obj("""{"is_occupied":false,"volume_list":[{"mount_point":"/volume1","display":"Volume 1"}],"volume_path":"/volume1"}""")
            PACKAGE_INSTALL to "install", PACKAGE_INSTALL to "upgrade" -> {
                if (parameters["blqinst"] != null) {
                    currentId = parameters.getValue("name").jsonPrimitive.content; currentQuick = parameters["blqinst"] == JsonPrimitive(true)
                    obj("""{"taskid":"synthetic-task","progress":0.2}""")
                } else { installed[currentId] = candidateVersion; obj("{}") }
            }
            PACKAGE_INSTALL to "status" -> {
                if (finished && currentQuick) installed[currentId] = candidateVersion
                buildJsonObject { put("finished", finished); put("success", true); put("progress", if (finished) 1.0 else 0.4) }
            }
            "SYNO.Core.Package.Installation.Download" to "check" -> checked
            PACKAGE_INSTALL to "cancel", PACKAGE_INSTALL to "clean", PACKAGE_INSTALL to "delete" -> obj("{}")
            PACKAGE_SETTINGS to "get" -> settings
            "SYNO.Core.Package.Setting.Volume" to "get" -> obj("""{"default_vol":"/volume1"}""")
            PACKAGE_SETTINGS to "set" -> {
                settings = JsonObject(settings + parameters.filterKeys { it !in setOf("packages", "packages_important") } +
                    ("update_channel" to JsonPrimitive(parameters["update_channel"] == JsonPrimitive("beta"))))
                obj("{}")
            }
            PACKAGE_FEED to "list" -> buildJsonObject { put("items", feeds); put("total", feeds.size) }
            PACKAGE_FEED to "add", PACKAGE_FEED to "set", PACKAGE_FEED to "delete" -> {
                val list = Json.parseToJsonElement(parameters.getValue("list").jsonPrimitive.content)
                if (method == "delete") feeds = JsonArray(feeds.filter { it.jsonObject["feed"] !in list.jsonArray })
                else {
                    val source = list.jsonObject
                    feeds = JsonArray(feeds.filter { it.jsonObject["feed"] != source["orifeed"] } + JsonObject(source.filterKeys { it != "orifeed" }))
                }
                obj("{}")
            }
            "SYNO.Core.Package.Info" to "get" -> obj("""{"prerelease":{"success":true,"agreed":true}}""")
            else -> error("Unexpected synthetic request $api $method")
        }
    }
    companion object { fun obj(value: String): JsonObject = Json.parseToJsonElement(value).jsonObject }
}
