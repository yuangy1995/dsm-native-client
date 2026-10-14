package io.github.qwertyuiop1995.dsmnativeclient

import android.content.*
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/** 系统 Cursor/内容流、生产扫描器、加密计划、真实请求编码与结果回读；网络仅接收合成数据。 */
class FolderUploadRepositoryIntegrationTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val profiles = SecureProfileStore(context)
    private val transfers = TransferStore(context)
    private val profile = NasProfile("folder-integration-${UUID.randomUUID()}", "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
    private val previous = profiles.lastProfileId()
    private val source = File(context.cacheDir, "synthetic-folder-${UUID.randomUUID()}.txt")
    private lateinit var resolver: ContentResolver
    private lateinit var scanContext: Context
    private lateinit var repo: DsmRepository
    private lateinit var owner: WorkspaceOwner
    private var metadataChanged = false
    private val tree = DocumentsContract.buildTreeDocumentUri("synthetic.folder.provider", "root")
    private val remote = linkedMapOf("/synthetic" to Remote(directory = true))
    private val writes = mutableListOf<String>()
    private var taskId: String? = null

    @Before fun prepare() {
        source.writeText("abc")
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = "text/plain"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
                val id = DocumentsContract.getDocumentId(uri)
                val ids = if (uri.lastPathSegment == "children") if (id == "root") listOf("empty", "file") else emptyList() else listOf(id)
                return MatrixCursor(checkNotNull(projection)).apply { ids.forEach { value -> addRow(projection.map { column -> when (column) {
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID -> value
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME -> when (value) { "root" -> "Root "; "empty" -> "Empty "; else -> "a.txt " }
                    DocumentsContract.Document.COLUMN_MIME_TYPE -> if (value == "file") "text/plain" else DocumentsContract.Document.MIME_TYPE_DIR
                    DocumentsContract.Document.COLUMN_SIZE -> if (value == "file") 3L else 0L
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED -> if (metadataChanged && value == "file") 2000L else 1000L
                    DocumentsContract.Document.COLUMN_FLAGS -> 0
                    else -> null
                } }.toTypedArray<Any?>()) } }
            }
            override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY)
            override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Read-only fixture")
            override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = error("Read-only fixture")
            override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = error("Read-only fixture")
        }
        provider.attachInfo(context, ProviderInfo().apply { authority = "synthetic.folder.provider" })
        resolver = ContentResolver.wrap(provider)
        scanContext = object : ContextWrapper(context) { override fun getContentResolver() = resolver }
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false)
        val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request()
            val body = request.body
            val fields = if (body is FormBody) (0 until body.size).associate { body.name(it) to body.value(it) } else emptyMap()
            val data = when {
                body is MultipartBody -> {
                    val parts = body.parts.associateBy { it.headers?.get("Content-Disposition")?.substringAfter("name=\"")?.substringBefore('"') }
                    val parent = Buffer().also { checkNotNull(parts["path"]).body.writeTo(it) }.readUtf8()
                    val part = checkNotNull(parts["file"])
                    val filename = part.headers?.get("Content-Disposition")?.substringAfter("filename=\"")?.substringBefore('"') ?: error("Missing name")
                    val bytes = Buffer().also { part.body.writeTo(it) }.readByteArray()
                    remote["$parent/$filename"] = Remote(false, bytes); writes += "upload:$parent/$filename"
                    JSONObject()
                }
                fields["method"] == "create" -> {
                    val path = "${fields["folder_path"]}/${fields["name"]}"
                    remote[path] = Remote(true); writes += "create:$path"; JSONObject()
                }
                fields["method"] == "getinfo" -> {
                    val path = JSONArray(fields.getValue("path")).getString(0)
                    JSONObject().put("files", JSONArray(remote.filterKeys { it == path }.map { fileJson(it.key, it.value) }))
                }
                fields["method"] == "list" -> {
                    val children = remote.filterKeys { it.substringBeforeLast('/') == fields["folder_path"] }
                    JSONObject().put("files", JSONArray(children.map { fileJson(it.key, it.value) })).put("total", children.size).put("offset", 0)
                }
                fields["method"] == "write" -> JSONObject()
                else -> error("Unexpected synthetic request ${fields["method"]}")
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(JSONObject().put("success", true).put("data", data).toString().toResponseBody("application/json".toMediaType())).build()
        }.build())
        repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
            listOf("SYNO.FileStation.List", "SYNO.FileStation.CreateFolder", "SYNO.FileStation.Upload", "SYNO.FileStation.CheckPermission", "SYNO.FileStation.Download")
                .associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
        repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
    }

    @After fun clean() {
        taskId?.let { id -> transfers.updateUpload(id) { it.copy(state = TransferState.SUCCEEDED, requiresRefresh = false) }; transfers.removeTerminal(profile.id) }
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previous); source.delete()
    }

    @Test fun `系统目录扫描到真实请求完成根空目录文件及摘要保存`() = runBlocking {
        val record = createTask()
        val result = execute(record)
        assertEquals(TransferState.SUCCEEDED, result?.state)
        assertEquals(listOf("create:/synthetic/Root ", "create:/synthetic/Root /Empty ", "upload:/synthetic/Root /a.txt "), writes)
        assertArrayEquals("abc".toByteArray(), remote["/synthetic/Root /a.txt "]?.bytes)
        assertEquals(UploadContentDigest(3).also { it.write("abc".toByteArray()) }.finish(), transfers.folderUploadPlan(record.id)?.entries?.last()?.fingerprint)
    }

    @Test fun `扫描后来源时间改变不能上传旧计划中的文件`() = runBlocking {
        val record = createTask(); metadataChanged = true
        assertEquals(TransferState.FAILED, execute(record)?.state)
        assertFalse(writes.any { it.startsWith("upload:") })
        assertEquals(FolderUploadEntryState.FAILED, transfers.folderUploadPlan(record.id)?.entries?.last()?.state)
        assertFalse(checkNotNull(transfers.upload(record.id)).requiresRefresh)
    }

    private suspend fun createTask(): PersistedUpload {
        val scan = scanDocumentTree(scanContext, tree, 100, includeRoot = true) { true }
        val id = UUID.randomUUID().toString(); taskId = id
        val plan = folderUploadPlan(id, profile.id, tree.toString(), "/synthetic", scan)
        val record = PersistedUpload(id, profile.id, tree.toString(), plan.rootName, expectedBytes = plan.totalBytes,
            destinationPath = "/synthetic", sourceTreeUri = tree.toString(), backupMode = false, mirrorDirectories = true, workId = "synthetic-execution")
        profiles.bindRecord(WorkspaceRecordKind.UPLOAD, id, owner)
        assertTrue(transfers.createFolderUploadDurably(record, plan))
        return record
    }
    private suspend fun execute(record: PersistedUpload) = FolderUploadCoordinator(transfers,
        RepositoryFolderUploadEndpoint(repo, resolver, WorkspaceTaskOwnership(profiles), record.id), record.id, checkNotNull(record.workId)).run()
    private fun fileJson(path: String, value: Remote) = JSONObject().put("path", path).put("name", path.substringAfterLast('/'))
        .put("isdir", value.directory).put("size", value.bytes.size).put("additional", JSONObject().put("perm", JSONObject().put("read", true).put("write", true)))
    private data class Remote(val directory: Boolean, val bytes: ByteArray = byteArrayOf())
}
