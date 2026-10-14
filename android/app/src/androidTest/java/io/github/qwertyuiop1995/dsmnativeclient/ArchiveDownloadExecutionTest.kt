package io.github.qwertyuiop1995.dsmnativeclient

import android.content.*
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
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
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/** 真实系统文件描述符与加密清单；仅网络响应及内容提供器入口使用合成夹具。 */
class ArchiveDownloadExecutionTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val profiles = SecureProfileStore(context)
    private val transfers = TransferStore(context)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("archive-execution-" + UUID.randomUUID(), "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
    private val target = File(context.cacheDir, "archive-execution-" + UUID.randomUUID())
    private val destination = Uri.parse("content://synthetic.archive.provider/target")
    private val requests = mutableListOf<Request>()
    private var openCount = 0
    private lateinit var ioContext: Context
    private lateinit var repo: DsmRepository
    private lateinit var owner: WorkspaceOwner
    private lateinit var record: PersistedDownload
    private val bytes = java.io.ByteArrayOutputStream().also { buffer ->
        java.util.zip.ZipOutputStream(buffer).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry("a.txt ")); zip.write("content".toByteArray()); zip.closeEntry()
            zip.putNextEntry(java.util.zip.ZipEntry("Empty/")); zip.closeEntry()
        }
    }.toByteArray()

    @Before fun prepare() {
        target.writeText("old-partial-output-longer-than-a-header")
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = "application/zip"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor? = null
            override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
                openCount++; assertEquals("rw", mode)
                return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_WRITE)
            }
            override fun insert(uri: Uri, values: ContentValues?): Uri? = error("No inserts")
            override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = error("No deletion")
            override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = error("No updates")
        }
        provider.attachInfo(context, ProviderInfo().apply { authority = "synthetic.archive.provider" })
        val resolver = ContentResolver.wrap(provider)
        ioContext = object : ContextWrapper(context) { override fun getContentResolver() = resolver }
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false)
        record = PersistedDownload(newArchiveDownloadId(), profile.id, "/synthetic/a.txt ", "Archive.zip",
            destination.toString(), true, state = TransferState.RUNNING, completedBytes = 20)
        profiles.bindRecord(WorkspaceRecordKind.DOWNLOAD, record.id, owner)
        val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); requests += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(bytes.toResponseBody("application/zip".toMediaType())).build()
        }.build())
        repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
            mapOf("SYNO.FileStation.Download" to ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2)))
        repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
    }

    @After fun clean() {
        transfers.remove(record.id); profiles.removeProfile(profile.id); profiles.setLastProfileId(previous); target.delete()
    }

    @Test fun restartedArchiveTruncatesPartialAndWritesExactZipFromOriginalSources() = runBlocking {
        savePlan()
        var reset = false
        val progress = mutableListOf<Long>()
        val written = executeFileDownload(ioContext, repo, record, transfers, true, {}, { reset = true }) { value, _ -> progress += value }
        assertTrue(reset); assertEquals(bytes.size.toLong(), written); assertArrayEquals(bytes, target.readBytes())
        assertEquals(bytes.size.toLong(), progress.last())
        assertNull(requests.single().header("Range"))
        assertEquals("""["/synthetic/a.txt ","/synthetic/Empty"]""", requests.single().url.queryParameter("path"))
        assertEquals(1, openCount)
    }

    @Test fun missingPlanDoesNotOpenOrTruncateExistingDestination() = runBlocking {
        transfers.upsert(record)
        val old = target.readBytes()
        assertTrue(runCatching { execute() }.exceptionOrNull() is java.io.IOException)
        assertEquals(0, openCount); assertTrue(requests.isEmpty()); assertArrayEquals(old, target.readBytes())
    }

    @Test fun accountChangeAndObsoleteExecutionRejectBeforeOpeningDestination() = runBlocking {
        savePlan()
        val old = target.readBytes()
        assertTrue(runCatching { executeFileDownload(ioContext, repo, record, transfers, false,
            { throw kotlinx.coroutines.CancellationException("Old execution") }, {}) { _, _ -> } }.isFailure)
        profiles.signOut(owner)
        val failure = runCatching { execute() }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, failure.kind)
        assertEquals(0, openCount); assertTrue(requests.isEmpty()); assertArrayEquals(old, target.readBytes())
    }

    private fun savePlan() = assertTrue(transfers.createArchiveDownloadDurably(record, ArchiveDownloadPlan(
        taskId = record.id, profileId = profile.id, destinationUri = destination.toString(),
        sources = listOf(ArchiveDownloadSource(record.sourcePath, "a.txt ", false), ArchiveDownloadSource("/synthetic/Empty", "Empty", true)))))
    private suspend fun execute() = executeFileDownload(ioContext, repo, record, transfers, false, {}, {}) { _, _ -> }
}
