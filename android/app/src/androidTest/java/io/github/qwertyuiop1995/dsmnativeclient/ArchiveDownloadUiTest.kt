package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import android.net.Uri
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.io.File
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** 实际文件页、系统新建文档和全局任务中心；网络仅返回合成 ZIP。 */
class ArchiveDownloadUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val transfers = TransferStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("archive-ui-" + UUID.randomUUID(), "Archive NAS", "https://synthetic.example.invalid", "synthetic")
    private lateinit var model: AppViewModel
    private val requests = Collections.synchronizedList(mutableListOf<Request>())
    @Volatile private var gate: CountDownLatch? = null
    private val plainBytes = ByteArray(20) { (65 + it).toByte() }
    private val folderBytes = java.io.ByteArrayOutputStream().also { buffer ->
        java.util.zip.ZipOutputStream(buffer).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry("Empty/")); zip.closeEntry()
        }
    }.toByteArray()
    private val bytes = java.io.ByteArrayOutputStream().also { buffer ->
        java.util.zip.ZipOutputStream(buffer).use { zip ->
            zip.putNextEntry(java.util.zip.ZipEntry("a.txt")); zip.write("synthetic-archive-content".toByteArray()); zip.closeEntry()
            zip.putNextEntry(java.util.zip.ZipEntry("Empty/")); zip.closeEntry()
        }
    }.toByteArray()

    @Before fun prepare() {
        val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request()
                val form = request.body as? FormBody
                val fields = form?.let { (0 until it.size).associate { index -> it.name(index) to it.value(index) } }.orEmpty()
                val method = fields["method"] ?: request.url.queryParameter("method")
                val body = if (method == "download") {
                    requests += request
                    gate?.await(10, TimeUnit.SECONDS)
                    val content = when (request.url.queryParameter("path")) {
                        """["/synthetic/a.txt"]""" -> plainBytes
                        """["/synthetic/Empty"]""" -> folderBytes
                        else -> bytes
                    }
                    content.toResponseBody("application/octet-stream".toMediaType())
                } else {
                    check(method in setOf("list", "getinfo", "list_share")) { "Unexpected method: " + method }
                    """{"success":true,"data":{"files":[{"path":"/synthetic/a.txt","name":"a.txt","isdir":false,"size":20,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}},{"path":"/synthetic/Empty","name":"Empty","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"total":2}}"""
                        .toResponseBody("application/json".toMediaType())
                }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
            }.build())
            val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
                listOf("SYNO.FileStation.List", "SYNO.FileStation.Download").associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = "/synthetic"), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithText("a.txt").fetchSemanticsNodes().isNotEmpty() }
    }

    @After fun clean() {
        gate?.countDown()
        compose.runOnIdle {
            transfers.downloads(profile.id).forEach {
                model.cancelTransfer(it.id)
                runCatching { app.contentResolver.delete(Uri.parse(it.destinationUri), null, null) }
                transfers.remove(it.id)
            }
            profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
        }
    }

    @Test fun nativeSaveCreatesOneZipFromSelectedFileAndDirectory() {
        chooseTwo()
        capture("archive-selection")
        saveNativeDocument()
        val record = awaitComplete()
        assertTrue(record.isArchiveDownload); assertEquals(2, transfers.archiveDownloadPlan(record)?.sources?.size)
        assertEquals(record.completedBytes, record.totalBytes)
        assertEquals(bytes.size.toLong(), record.completedBytes)
        assertNull(requests.single().header("Range"))
        assertEquals("""["/synthetic/a.txt","/synthetic/Empty"]""", requests.single().url.queryParameter("path"))
        app.contentResolver.openInputStream(Uri.parse(record.destinationUri))!!.use { assertArrayEquals(bytes, it.readBytes()) }
        compose.runOnIdle { model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.onNodeWithText(text(R.string.client_finished_tasks)).performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText(record.title).fetchSemanticsNodes().isNotEmpty() }
        capture("archive-completed")
    }

    @Test fun pausedArchiveRestartsFromOriginalSelectionThroughTaskCard() {
        val blocked = CountDownLatch(1); gate = blocked
        chooseTwo(); saveNativeDocument()
        compose.waitUntil(10_000) { requests.size == 1 }
        val record = transfers.downloads(profile.id).single()
        compose.runOnIdle { model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text(R.string.pause_download)).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(text(R.string.pause_download)).performClick()
        compose.waitUntil(10_000) { transfers.download(record.id)?.state == TransferState.PAUSED }
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text(R.string.resume_download)).fetchSemanticsNodes().isNotEmpty() }
        capture("archive-paused")
        gate = null
        compose.onNodeWithText(text(R.string.resume_download)).performClick()
        blocked.countDown()
        val completed = awaitComplete()
        assertEquals(record.id, completed.id); assertEquals(2, requests.size)
        assertTrue(requests.all { it.header("Range") == null })
        assertEquals(requests.first().url.queryParameter("path"), requests.last().url.queryParameter("path"))
        app.contentResolver.openInputStream(Uri.parse(record.destinationUri))!!.use { assertArrayEquals(bytes, it.readBytes()) }
        capture("archive-resumed")
    }

    @Test fun singleDirectoryUsesSameZipTaskAndKeepsItsName() {
        compose.onNodeWithText("Empty").performTouchInput { longClick() }
        saveNativeDocument(R.string.download_folder_as_zip)
        val completed = awaitComplete()
        assertEquals("Empty.zip", completed.title)
        assertTrue(completed.isArchiveDownload)
        assertEquals("/synthetic/Empty", transfers.archiveDownloadPlan(completed)?.sources?.single()?.path)
        app.contentResolver.openInputStream(Uri.parse(completed.destinationUri))!!.use { assertArrayEquals(folderBytes, it.readBytes()) }
    }

    @Test fun singleFileRetainsOriginalFormatAndKnownLength() {
        compose.onNodeWithText("a.txt").performTouchInput { longClick() }
        saveNativeDocument(R.string.download_item)
        val completed = awaitComplete()
        assertEquals("a.txt", completed.title)
        assertFalse(completed.isArchiveDownload)
        assertEquals(plainBytes.size.toLong(), completed.expectedBytes)
        app.contentResolver.openInputStream(Uri.parse(completed.destinationUri))!!.use { assertArrayEquals(plainBytes, it.readBytes()) }
    }

    private fun chooseTwo() {
        compose.onNodeWithText("a.txt").performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.select_item)).performScrollTo().performClick()
        compose.onNodeWithText("Empty").performClick()
        compose.onNodeWithText(text(R.string.download_selected_as_zip)).assertIsEnabled()
    }

    private fun saveNativeDocument(action: Int = R.string.download_selected_as_zip) {
        compose.onNodeWithText(text(action)).performClick()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun saveButton(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
            node ?: return null
            if (node.isClickable && node.isEnabled && node.text?.toString() in setOf("Save", "SAVE", "保存")) return node
            for (index in 0 until node.childCount) saveButton(node.getChild(index))?.let { return it }
            return null
        }
        compose.waitUntil(10_000) { saveButton(automation.rootInActiveWindow) != null }
        val button = checkNotNull(saveButton(automation.rootInActiveWindow))
        assertTrue(button.performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }

    private fun awaitComplete(): PersistedDownload {
        try {
            compose.waitUntil(15_000) { transfers.downloads(profile.id).singleOrNull()?.state == TransferState.SUCCEEDED }
        } catch (failure: Throwable) {
            capture("archive-failed")
            throw AssertionError("states=" + transfers.downloads(profile.id).map { it.state to it.errorKind } +
                " requests=" + requests.size + " message=" + model.workspace.value?.message, failure)
        }
        return transfers.downloads(profile.id).single()
    }
    private fun text(id: Int) = app.getString(id)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val output = File(app.getExternalFilesDir(null), "archive-download-review/" + name + ".png")
        output.parentFile?.mkdirs(); output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
