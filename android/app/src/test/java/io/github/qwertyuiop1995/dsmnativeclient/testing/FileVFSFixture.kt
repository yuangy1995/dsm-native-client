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

/** 仅替代网络响应；请求仍通过正式授权、版本选择和仓储。 */
internal class FileVFSFixture(profileId: String = "vfs-feature") {
    val nas = NasProfile(profileId, "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
    val owner = WorkspaceOwner(nas.id, "identity", "session")
    val original = FileVFSProfile(owner, "opaque-id", "davs", "WebDAV", "davs://opaque-root/Shared Files", "server.invalid", 443,
        "Saved server", "synthetic-account", "UTF-8", FileVFSConnectionState.CONNECTED)
    var setup = FileVFSConfiguration("davs", "server.invalid", 443, original.alias, original.account!!, folder = "Shared Files")
    @Volatile var profiles = listOf(original)
    @Volatile var allowed = true
    @Volatile var administrator = true
    @Volatile var profileFailure = false
    @Volatile var folderFailure = false
    @Volatile var applyWrites = true
    var firmware = "DSM 7.2.1-69057 Update 12"
    var packageVersion = "1.4.1-1559"
    var before: (Map<String, String>) -> Unit = {}
    val preferences = MemoryPreferences()
    val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    var children: (String, Int) -> FilePage = { path, offset -> FilePage(listOf(FileItem(path + "/report.txt", "report.txt", false, 8, 10)), 1, offset) }
    private val capabilities = listOf(VFS_PROFILE_API, VFS_CONNECTION_API, VFS_PROTOCOL_API, "SYNO.Core.System", "SYNO.Core.Package", "SYNO.FileStation.List", "SYNO.FileStation.Download")
        .associateWith { ApiCapability(it, "entry.cgi", 1, if (it in setOf("SYNO.Core.Package", "SYNO.FileStation.List", "SYNO.FileStation.Download")) 2 else 1) }
    private val access = WorkspaceAccessReader(capabilities,
        { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), administrator) }, { error("Unexpected fallback") }, {})
    val repository = DsmRepository(nas, DsmSession(nas.id, "synthetic"), DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
        val request = chain.request(); val form = request.body as FormBody
        val fields = (0 until form.size).associate { form.name(it) to form.value(it) }; calls += fields; before(fields)
        val data = response(fields)
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
            .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
    }.build()), capabilities, access).also { repo ->
        runBlocking { repo.refreshAccess() }; repo.bindOwner(owner) {}
        repo.fileMounts.vfs.bindRecovery(FileVFSRecoveryStore(preferences))
    }
    fun writes() = synchronized(calls) { calls.filter { it["api"] in setOf(VFS_CONNECTION_API, VFS_PROFILE_API) && it["method"] in setOf("create", "set", "delete") }.toList() }
    private fun response(fields: Map<String, String>): JsonObject {
        val api = fields.getValue("api"); val method = fields.getValue("method")
        if (method in setOf("create", "set", "delete") && api in setOf(VFS_PROFILE_API, VFS_CONNECTION_API)) {
            if (applyWrites) {
                if (method == "delete") profiles = if (api == VFS_PROFILE_API) profiles.filterNot { it.id == fields["id"] }
                    else profiles.map { if (it.id == fields["id"]) it.copy(state = FileVFSConnectionState.DISCONNECTED) else it }
                else if ("profile_id" in fields) profiles = profiles.map { if (it.id == fields["profile_id"]) it.copy(state = FileVFSConnectionState.CONNECTED) else it }
                else {
                    setup = setup.copy(protocolId = fields["protocol"] ?: setup.protocolId, hostname = fields["hostname"] ?: setup.hostname,
                        port = fields["port"]?.toInt() ?: setup.port, alias = fields["alias"] ?: setup.alias, account = fields["account"] ?: setup.account,
                        folder = fields["uri_path"] ?: setup.folder, codepage = fields["codepage"] ?: setup.codepage, usesOneConnection = fields["max_connection"]?.let { it == "1" } ?: setup.usesOneConnection)
                    val current = profiles.singleOrNull { it.id == fields["id"] }
                    profiles = listOf((current ?: original.copy(id = "new-id", uri = setup.protocolId + "://opaque-new/root")).copy(
                        protocolId = setup.protocolId, hostname = setup.hostname, port = setup.port, alias = setup.alias, account = setup.account,
                        codepage = setup.codepage, state = FileVFSConnectionState.CONNECTED))
                }
            }
            return buildJsonObject {}
        }
        return when (api) {
            "SYNO.Core.System" -> buildJsonObject { put("firmware_ver", firmware); put("buildnumber", 69057); put("smallfixnumber", 12) }
            "SYNO.Core.Package" -> Json.parseToJsonElement("""{"total":1,"packages":[{"id":"FileStation","name":"File Station","version":"$packageVersion","status":"running","startable":true,"available_operation":[],"dsm_apps":[]}]}""").jsonObject
            VFS_PROFILE_API -> if (method == "get") buildJsonObject {
                put("hostname", setup.hostname); put("port", setup.port); put("alias", setup.alias); put("account", setup.account)
                put("codepage", setup.codepage); put("uri_path", setup.folder); put("max_connection", if (setup.usesOneConnection) 1 else 0)
            } else {
                if (profileFailure) throw java.io.IOException("synthetic profile failure")
                buildJsonObject { put("total", profiles.size); put("profiles", JsonArray(profiles.map(::profileRow))) }
            }
            VFS_PROTOCOL_API -> buildJsonObject { putJsonArray("protocols") {
                for ((id, port) in listOf("ftp" to 21, "sftp" to 22, "dav" to 80, "davs" to 443, "google" to null)) add(buildJsonObject {
                    put("protocol", id); put("name", id); port?.let { put("default_port", it) }; put("has_server", false)
                })
            } }
            "SYNO.FileStation.List" -> {
                if (folderFailure) throw java.io.IOException("synthetic folder failure")
                val page = children(fields.getValue("folder_path"), fields.getValue("offset").toInt())
                buildJsonObject { put("offset", page.offset); put("total", page.total); put("files", JsonArray(page.items.map(::fileRow))) }
            }
            else -> error("Unexpected synthetic request")
        }
    }
    fun profileRow(value: FileVFSProfile) = buildJsonObject {
        put("id", value.id); put("protocol", value.protocolId); put("protocol_name", value.protocolName); put("uri", value.uri)
        put("hostname", value.hostname); put("port", value.port); put("alias", value.alias); put("account", value.account); put("codepage", value.codepage)
        put("connect_status", when (value.state) { FileVFSConnectionState.CONNECTED -> 1; FileVFSConnectionState.DISCONNECTED -> 0; else -> 7 })
    }
    private fun fileRow(item: FileItem) = buildJsonObject {
        put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
        putJsonObject("additional") { putJsonObject("time") { put("mtime", item.modifiedAtEpochSeconds) }
            putJsonObject("perm") { putJsonObject("acl") { put("read", item.canRead) } } }
    }
}
