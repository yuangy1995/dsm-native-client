package io.github.qwertyuiop1995.dsmnativeclient.testing

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import java.util.Collections

/** 正式仓储/授权/请求通路，NAS 响应全部为合成任务，不使用真实文件。 */
internal class FileBackgroundTaskFixture(val preferences: MemoryPreferences = MemoryPreferences(),
    profileId: String = "background-synthetic", session: String = "session", val stopVersions: Map<FileBackgroundTaskKind, Int> = emptyMap()) {
    val profile = NasProfile(profileId, "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
    val owner = WorkspaceOwner(profile.id, "identity", session)
    var allowed = true; var validOwner = true; var applyWrites = true
    var rows = listOf(row())
    var before: (Map<String, String>) -> Unit = {}
    var afterWrite: (Map<String, String>) -> Unit = {}
    var overrideRead: ((Map<String, String>) -> JsonObject?) = { null }
    var responseError: (Map<String, String>) -> Int? = { null }
    val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    val requests = Collections.synchronizedList(mutableListOf<Request>())
    private val capabilities = (FileBackgroundTaskKind.entries.map { it.taskAPI.first to (stopVersions[it] ?: it.taskAPI.second) } +
        (FILE_BACKGROUND_API to 3) + ("SYNO.FileStation.List" to 2)).associate { (api, version) -> api to ApiCapability(api, "entry.cgi", 1, version) }
    private val access = WorkspaceAccessReader(capabilities,
        { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), false) }, { error("No implicit fallback") }, {})
    val repository = DsmRepository(profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), DsmApiClient(
        OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); val body = request.body as FormBody
            val fields = (0 until body.size).associate { body.name(it) to body.value(it) }
            calls += fields; requests += request; before(fields)
            val error = responseError(fields)
            val data = if (error != null) null else if (fields["method"] == "list") overrideRead(fields) ?: page(fields) else {
                val id = fields.getValue("taskid").let { if (fields["method"] == "clear_finished") Json.parseToJsonElement(it).jsonArray.single().jsonPrimitive.content else it }
                if (applyWrites) rows = if (fields["method"] == "clear_finished") rows.filterNot { it["taskid"]?.jsonPrimitive?.content == id }
                    else rows.map { if (it["taskid"]?.jsonPrimitive?.content == id) JsonObject(it + ("finished" to JsonPrimitive(true))) else it }
                afterWrite(fields); buildJsonObject { }
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(buildJsonObject {
                put("success", error == null)
                if (error == null) put("data", data!!) else putJsonObject("error") { put("code", error) }
            }.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()), capabilities, access).also { repo ->
        runBlocking { repo.refreshAccess() }
        repo.bindOwner(owner) { if (!validOwner) throw DsmFailure(null, "Changed", "Reconnect", kind = DsmErrorKind.WORKSPACE_CHANGED) }
        repo.fileBackgroundTasks.bindRecovery(FileBackgroundTaskRecoveryStore(preferences))
    }
    val tasks get() = repository.fileBackgroundTasks
    fun writes() = synchronized(calls) { calls.filter { it["method"] != "list" }.toList() }
    private fun page(fields: Map<String, String>) = buildJsonObject {
        val offset = fields.getValue("offset").toInt(); val limit = fields.getValue("limit").toInt()
        put("offset", offset); put("total", rows.size); put("tasks", JsonArray(rows.drop(offset).take(limit)))
    }
    companion object {
        fun row(id: String = "synthetic-task", kind: FileBackgroundTaskKind = FileBackgroundTaskKind.COPY_OR_MOVE,
            finished: Boolean = false, time: Double = 1700000000.125) = buildJsonObject {
            put("taskid", id); put("api", kind.taskAPI.first); put("version", kind.taskAPI.second); put("method", "start")
            put("crtime", time); put("finished", finished); put("progress", 0.25); put("processed_num", 2)
            put("processed_size", 1024); put("total", 4096)
        }
    }
}
