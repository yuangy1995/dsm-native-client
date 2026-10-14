package io.github.qwertyuiop1995.dsmnativeclient

import android.content.*
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.util.UUID

/** 真实文件描述符、加密来源和共用前台/Worker 执行器；只有网络数据为合成。 */
class FileVFSDownloadExecutionTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val profiles = SecureProfileStore(context)
    private val transfers = TransferStore(context)
    private val previous = profiles.lastProfileId()
    private val nas = NasProfile("vfs-download-" + UUID.randomUUID(), "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
    private val target = File(context.cacheDir, "vfs-download-output-" + UUID.randomUUID())
    private val destination = Uri.parse("content://synthetic.vfs.provider/target")
    private val downloads = mutableListOf<Request>()
    private lateinit var owner: WorkspaceOwner
    private lateinit var original: FileVFSProfile
    private lateinit var source: FileVFSDownloadSource
    private lateinit var record: PersistedDownload
    private lateinit var repo: DsmRepository
    private lateinit var ioContext: Context
    private var changedConnection = false
    private var changedFile = false
    private var denied = false
    private var opens = 0
    private val content = "original".toByteArray()
    @Before fun prepare() {
        target.writeText("old-partial-output-that-must-be-preserved-on-failure")
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = "application/octet-stream"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor? = null
            override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor { opens++; assertEquals("rw", mode); return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_WRITE) }
            override fun insert(uri: Uri, values: ContentValues?): Uri? = error("No inserts")
            override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = error("No deletion")
            override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = error("No updates")
        }
        provider.attachInfo(context, ProviderInfo().apply { authority = "synthetic.vfs.provider" })
        val resolver = ContentResolver.wrap(provider); ioContext = object : ContextWrapper(context) { override fun getContentResolver() = resolver }
        val session = DsmSession(nas.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(nas.id), nas, session, null, false)
        original = FileVFSProfile(owner, "opaque", "davs", "WebDAV", "davs://opaque-root/Shared Files", "server.invalid", 443,
            "Synthetic", "synthetic-account", "UTF-8", FileVFSConnectionState.CONNECTED)
        source = FileVFSDownloadSource(original, original.uri, original.uri + "/report.txt ", "report.txt ", 8, 10)
        record = PersistedDownload(newVFSDownloadId(), nas.id, source.path, source.name, destination.toString(), false, state = TransferState.RUNNING, expectedBytes = 8)
        profiles.bindRecord(WorkspaceRecordKind.DOWNLOAD, record.id, owner)
        val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request()
            val form = request.body as? FormBody
            val fields = if (form != null) (0 until form.size).associate { form.name(it) to form.value(it) } else request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
            val builder = Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("OK")
            if (fields["api"] == "SYNO.FileStation.Download") {
                downloads += request
                val range = request.header("Range")
                if (range != null) { assertEquals("bytes=4-7", range); builder.code(206).header("Content-Range", "bytes 4-7/8").body(content.copyOfRange(4, 8).toResponseBody("application/octet-stream".toMediaType())) }
                else builder.code(200).body(content.toResponseBody("application/octet-stream".toMediaType()))
            } else {
                val data = when (fields["api"]) {
                    VFS_PROFILE_API -> buildJsonObject { put("total", 1); putJsonArray("profiles") { add(buildJsonObject {
                        put("id", original.id); put("protocol", original.protocolId); put("protocol_name", original.protocolName); put("uri", original.uri)
                        put("hostname", original.hostname); put("port", original.port); put("alias", original.alias)
                        put("account", if (changedConnection) "another-account" else original.account); put("codepage", original.codepage); put("connect_status", 1)
                    }) } }
                    "SYNO.FileStation.List" -> buildJsonObject { put("offset", 0); put("total", 1); putJsonArray("files") { add(buildJsonObject {
                        put("name", source.name); put("path", source.path); put("isdir", false); put("size", if (changedFile) 9 else 8)
                        putJsonObject("additional") { putJsonObject("time") { put("mtime", 10) }; putJsonObject("perm") { putJsonObject("acl") { put("read", !denied) } } }
                    }) } }
                    else -> error("Unexpected synthetic request")
                }
                builder.code(200).body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType()))
            }
            builder.build()
        }.build())
        val caps = listOf(VFS_PROFILE_API, "SYNO.FileStation.List", "SYNO.FileStation.Download")
            .associateWith { ApiCapability(it, "entry.cgi", 1, if (it == VFS_PROFILE_API) 1 else 2) }
        repo = authorizedRepository(nas, session, api, caps); repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
    }
    @After fun clean() { transfers.remove(record.id); profiles.removeProfile(nas.id); profiles.setLastProfileId(previous); target.delete() }
    private fun save() = assertTrue(transfers.createVFSDownloadDurably(record, FileVFSDownloadPlan(taskId = record.id, destinationUri = record.destinationUri, source = source)))
    private suspend fun execute(exact: Boolean = false, reset: () -> Unit = {}) = executeFileDownload(ioContext, repo, record, transfers, exact, {}, reset) { _, _ -> }
    @Test fun currentOriginalConnectionDownloadsExactBytesUsingUntouchedRemoteUri() = runBlocking {
        save(); assertEquals(8L, execute()); assertArrayEquals(content, target.readBytes()); assertEquals(1, opens)
        assertEquals(JsonArray(listOf(JsonPrimitive(source.path))).toString(), downloads.single().url.queryParameter("path"))
        assertNull(downloads.single().url.queryParameter("_sid")); assertNull(downloads.single().url.queryParameter("SynoToken"))
    }
    @Test fun resumeRechecksConnectionAndMetadataThenAppendsMatchingByteRange() = runBlocking {
        target.writeBytes(content.copyOfRange(0, 4)); record = record.copy(completedBytes = 4); save()
        var reset = false
        assertEquals(8L, execute(true) { reset = true }); assertFalse(reset); assertArrayEquals(content, target.readBytes())
        assertEquals("bytes=4-7", downloads.single().header("Range"))
    }
    @Test fun changedConnectionOrFileOrPermissionCannotOpenExistingOutput() = runBlocking {
        save(); val previous = target.readBytes()
        for (variant in 0..2) {
            changedConnection = variant == 0; changedFile = variant == 1; denied = variant == 2
            assertTrue(runCatching { execute() }.isFailure); assertEquals(0, opens); assertTrue(downloads.isEmpty()); assertArrayEquals(previous, target.readBytes())
        }
    }
    @Test fun missingPlanAndSignedOutAccountPreserveOutputWithoutDownload() = runBlocking {
        val previous = target.readBytes()
        assertTrue(runCatching { execute() }.exceptionOrNull() is FileVFSDownloadPlanUnavailable)
        save(); profiles.signOut(owner); assertTrue(runCatching { execute() }.exceptionOrNull() is DsmFailure)
        assertEquals(0, opens); assertTrue(downloads.isEmpty()); assertArrayEquals(previous, target.readBytes())
    }
}
