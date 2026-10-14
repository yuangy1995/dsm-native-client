package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
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
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** 真实任务页的恢复按钮与目录导航；只使用明确合成的只读响应。 */
class UploadRecoveryUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val application = ApplicationProvider.getApplicationContext<Application>()
    private val store = SecureProfileStore(application)
    private val transfers = TransferStore(application)
    private val previous = store.lastProfileId()
    private val suffix = UUID.randomUUID().toString()
    private val profile = NasProfile("upload-ui-$suffix", "Upload NAS", "https://synthetic.example.invalid", "synthetic")
    private val bytes = "original-content".encodeToByteArray()
    private val task = PersistedUpload("upload-ui-task-$suffix", profile.id, "content://synthetic/item", "Recovered.bin",
        expectedBytes = bytes.size.toLong(), destinationPath = "/synthetic/target", state = TransferState.FAILED,
        workId = "execution-$suffix", backupMode = false, overwrite = true, requiresRefresh = true)
    private var remote = bytes
    private val methods = Collections.synchronizedList(mutableListOf<String>())
    private lateinit var host: WorkspaceHostModel
    private lateinit var model: AppViewModel

    @Before fun prepare() {
        val owner = store.commitConnection(store.connectionAttempt(profile.id), profile,
            DsmSession(profile.id, "synthetic-session"), null, false)
        store.bindRecord(WorkspaceRecordKind.UPLOAD, task.id, owner)
        transfers.upsert(task)
        transfers.saveUploadContent(task, requireNotNull(task.workId), UploadContentDigest(bytes.size.toLong()).also { it.write(bytes) }.finish())
        compose.runOnIdle {
            host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false))
            model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request()
                val form = request.body as? FormBody
                val parameters = form?.let { (0 until it.size).associate { i -> form.name(i) to form.value(i) } }.orEmpty()
                val method = request.url.queryParameter("method") ?: parameters["method"] ?: error("Missing method")
                methods += method
                val body = if (method == "download") remote.toResponseBody("application/octet-stream".toMediaType()) else {
                    val data = when (method) {
                        "list_share" -> """{"shares":[],"total":0}"""
                        "getinfo" -> if (parameters["path"] == "[\"${task.destinationPath}\"]") {
                            """{"files":[{"path":"${task.destinationPath}","name":"target","isdir":true,"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}]}"""
                        } else fileData()
                        "list" -> fileData()
                        else -> error("恢复界面不得写入：$method")
                    }
                    """{"success":true,"data":$data}""".toResponseBody("application/json".toMediaType())
                }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
            }.build())
            val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
                listOf("SYNO.FileStation.List", "SYNO.FileStation.Download").associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
            repo.bindOwner(owner) { store.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.FILES,
                files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS))
        }
        awaitTask()
    }

    @After fun clean() {
        compose.runOnIdle {
            transfers.upsert(task.copy(state = TransferState.SUCCEEDED, requiresRefresh = false))
            transfers.removeTerminal(profile.id)
            store.removeProfile(profile.id); store.setLastProfileId(previous)
        }
    }

    @Test fun `实际重试按钮只读比较原内容并将任务移至已结束`() {
        capture("upload-recovery-before")
        action(R.string.retry).performClick()
        compose.waitUntil(10_000) { transfers.upload(task.id)?.state == TransferState.SUCCEEDED }
        assertFalse(requireNotNull(transfers.upload(task.id)).requiresRefresh)
        compose.waitUntil(10_000) { model.workspace.value?.message == application.getString(R.string.upload_retry_already_complete) }
        assertEquals(application.getString(R.string.upload_retry_already_complete), model.workspace.value?.message)
        compose.onNodeWithText(application.getString(R.string.client_finished_tasks)).performClick()
        awaitTask()
        action(R.string.retry).assertDoesNotExist()
        action(R.string.upload_open_target_folder).assertIsDisplayed()
        assertEquals(1, methods.count { it == "download" })
        assertFalse(methods.contains("upload"))
        capture("upload-recovery-complete")
    }

    @Test fun `同大小冲突保留原任务且可从卡片打开原目录`() {
        remote = "different-values".encodeToByteArray()
        action(R.string.retry).performClick()
        compose.waitUntil(10_000) { model.workspace.value?.message == application.getString(R.string.upload_retry_conflict) }
        assertEquals(task, transfers.upload(task.id))
        awaitTask(); capture("upload-recovery-conflict")
        action(R.string.upload_open_target_folder).performClick()
        compose.waitUntil(10_000) { model.workspace.value?.selectedModule == Module.FILES && model.workspace.value?.fileBrowser?.path == task.destinationPath }
        assertEquals(profile.id, host.active.value.model.workspace.value?.profile?.id)
        assertFalse(methods.contains("upload"))
        compose.onNodeWithText(task.title).assertExists()
    }

    private fun fileData() = """{"files":[{"path":"${task.destinationPath}/${task.title}","name":"${task.title}","isdir":false,"size":${remote.size},"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"total":1}"""
    private val rowTag get() = "global_task_${profile.id}:UPLOAD:${task.id}"
    private fun awaitTask() {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(task.title).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("global_task_list").performScrollToNode(hasText(task.title))
    }
    private fun action(resource: Int) = compose.onNode(hasText(application.getString(resource)) and hasAnyAncestor(hasTestTag(rowTag)), useUnmergedTree = true)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val output = File(application.getExternalFilesDir(null), "upload-recovery-review/$name.png")
        output.parentFile?.mkdirs(); output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
