package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import java.util.Collections
import java.util.UUID

/** 只替代远端 HTTP，系统入口仍使用正式权限、解码、存储和上传任务。 */
internal class SystemFileFixture {
    val profile = NasProfile(UUID.randomUUID().toString(), "Synthetic files", "https://synthetic.example.invalid", "synthetic")
    val session = DsmSession(profile.id, "synthetic-session")
    var allowed = true
    var before: (Map<String, String>) -> Unit = {}
    var incomplete = false
    var downloadBytes = "abc".toByteArray()
    val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    val entries = linkedMapOf("/share" to folder("/share"), "/share/folder" to folder("/share/folder"))
    fun repository(owner: WorkspaceOwner, validate: () -> Unit): DsmRepository {
        val caps = listOf("SYNO.FileStation.List", "SYNO.FileStation.Download", "SYNO.FileStation.MD5").associateWith { ApiCapability(it, "entry.cgi", 1, 2) }
        val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), false) },
            { error("Unexpected fallback") }, {})
        val client = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); val form = request.body as? FormBody
            val fields = if (form != null) (0 until form.size).associate { form.name(it) to form.value(it) }
                else request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
            calls += fields; before(fields)
            if (fields["api"] == "SYNO.FileStation.Download") return@addInterceptor Response.Builder().request(request)
                .protocol(Protocol.HTTP_1_1).code(200).message("synthetic").header("Content-Type", "application/octet-stream")
                .body(downloadBytes.toResponseBody("application/octet-stream".toMediaType())).build()
            if (fields["api"] == "SYNO.FileStation.MD5") return@addInterceptor Response.Builder().request(request)
                .protocol(Protocol.HTTP_1_1).code(200).message("synthetic").body(buildJsonObject {
                    put("success", true); putJsonObject("data") { when (fields["method"]) {
                        "start" -> put("taskid", "synthetic-digest")
                        "status" -> { put("finished", true); put("md5", java.security.MessageDigest.getInstance("MD5").digest(downloadBytes).joinToString("") { "%02x".format(it) }) }
                        else -> error("Unexpected digest request")
                    } }
                }.toString().toResponseBody("application/json".toMediaType())).build()
            check(fields["api"] == "SYNO.FileStation.List")
            val method = fields.getValue("method")
            val items = when (method) {
                "getinfo" -> Json.parseToJsonElement(fields.getValue("path")).jsonArray.mapNotNull { entries[it.jsonPrimitive.content] }
                "list_share" -> entries.filterKeys { it.count { ch -> ch == '/' } == 1 }.values.toList()
                "list" -> entries.filter { (path, item) -> path.substringBeforeLast('/') == fields["folder_path"] &&
                    (fields["filetype"] != "dir" || item.getValue("isdir").jsonPrimitive.boolean) }.values.toList()
                else -> error("Unexpected request")
            }
            val offset = fields["offset"]?.toInt() ?: 0
            val data = buildJsonObject {
                put("offset", offset); put("total", items.size + if (incomplete) 1 else 0)
                put(if (method == "list_share") "shares" else "files", JsonArray(if (incomplete) emptyList() else items.drop(offset).take(fields["limit"]?.toInt() ?: items.size)))
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        return DsmRepository(profile, session, DsmApiClient(client), caps, access).also {
            it.bindOwner(owner, validate); runBlocking { it.refreshAccess() }
        }
    }
    companion object {
        fun folder(path: String, writable: Boolean = true) = item(path, true, writable)
        fun item(path: String, directory: Boolean = false, writable: Boolean = true) = buildJsonObject {
            put("path", path); put("name", path.substringAfterLast('/')); put("isdir", directory)
            putJsonObject("additional") {
                put("size", 3); put("mount_point_type", "normal"); putJsonObject("time") { put("mtime", 100) }
                putJsonObject("perm") { put("read", true); put("write", writable); put("delete", false) }
            }
        }
    }
}
