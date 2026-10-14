package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
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

/** 实际全局任务卡片打开目录详情，无保存会话时通过当前连接只读恢复。 */
class FolderUploadRecoveryUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val context = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(context)
    private val transfers = TransferStore(context)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("folder-recovery-${UUID.randomUUID()}", "Folder NAS", "https://synthetic.example.invalid", "synthetic")
    private val bytes = "synthetic-content".toByteArray()
    private val task = PersistedUpload("folder-recovery-${UUID.randomUUID()}", profile.id, "content://synthetic/tree", "Recovered folder",
        expectedBytes = bytes.size.toLong(), destinationPath = "/synthetic", sourceTreeUri = "content://synthetic/tree",
        backupMode = false, mirrorDirectories = true, state = TransferState.PAUSED, workId = "prior-execution", requiresRefresh = true)
    private val requests = Collections.synchronizedList(mutableListOf<String>())
    private lateinit var model: AppViewModel

    @Before fun prepare() {
        val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false)
        profiles.bindRecord(WorkspaceRecordKind.UPLOAD, task.id, owner)
        val proof = UploadContentDigest(bytes.size.toLong()).also { it.write(bytes) }.finish()
        val plan = FolderUploadPlan(taskId = task.id, profileId = profile.id, treeUri = task.sourceUri, destinationPath = task.destinationPath,
            entries = listOf(FolderUploadEntry(FolderUploadSource("root", task.sourceUri, task.title, true), FolderUploadEntryState.SUCCEEDED),
                FolderUploadEntry(FolderUploadSource("file", "content://synthetic/file", "${task.title}/a.txt", false, bytes = bytes.size.toLong()),
                    FolderUploadEntryState.UNRESOLVED, fingerprint = proof)))
        assertTrue(transfers.createFolderUploadDurably(task, plan))
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val body = request.body as? FormBody
                val fields = body?.let { (0 until it.size).associate { index -> it.name(index) to it.value(index) } }.orEmpty()
                val method = fields["method"] ?: request.url.queryParameter("method") ?: error("Missing method")
                requests += method
                val payload = when (method) {
                    "download" -> bytes.toResponseBody("application/octet-stream".toMediaType())
                    "getinfo", "list" -> """{"success":true,"data":{"files":[{"path":"/synthetic/${task.title}/a.txt","name":"a.txt","isdir":false,"size":${bytes.size},"additional":{"perm":{"is_acl_mode":false,"acl":{"read":true,"write":false,"del":false}}}}],"total":1}}""".toResponseBody("application/json".toMediaType())
                    "list_share" -> """{"success":true,"data":{"shares":[],"total":0}}""".toResponseBody("application/json".toMediaType())
                    else -> error("恢复目录任务不得写入：$method")
                }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(payload).build()
            }.build())
            val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
                listOf("SYNO.FileStation.List", "SYNO.FileStation.Download").associateWith { ApiCapability(it, "entry.cgi", 1, 2) })
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.FILES,
                files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS))
        }
    }

    @After fun clean() {
        compose.runOnIdle { model.folderUploads.close(); transfers.updateUpload(task.id) { it.copy(state = TransferState.SUCCEEDED, requiresRefresh = false) }
            transfers.removeTerminal(profile.id); profiles.removeProfile(profile.id); profiles.setLastProfileId(previous) }
    }

    @Test fun `暂停目录从实际卡片打开详情并只读完成旧上传`() {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(task.title).fetchSemanticsNodes().isNotEmpty() }
        val row = "global_task_${profile.id}:UPLOAD:${task.id}"
        compose.onNodeWithTag("global_task_list").performScrollToNode(hasText(task.title))
        compose.onNode(hasText(context.getString(R.string.folder_upload_details)) and hasAnyAncestor(hasTestTag(row)), useUnmergedTree = true).performClick()
        compose.onNodeWithTag("folder_upload_dialog").assertIsDisplayed()
        compose.onNodeWithText(context.getString(R.string.folder_upload_continue)).performClick()
        compose.waitUntil(10_000) { transfers.upload(task.id)?.state == TransferState.SUCCEEDED }
        compose.waitUntil(10_000) { model.folderUploads.ui.value.taskState == TransferState.SUCCEEDED }
        assertFalse(checkNotNull(transfers.upload(task.id)).requiresRefresh)
        assertEquals(1, requests.count { it == "download" })
        assertTrue(requests.all { it in setOf("list", "getinfo", "download", "list_share") })
        compose.onNodeWithText(context.getString(R.string.folder_upload_continue)).assertDoesNotExist()
    }
}
