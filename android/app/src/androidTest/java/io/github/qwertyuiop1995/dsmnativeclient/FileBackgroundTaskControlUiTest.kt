package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 正式工作区、页面与持久恢复；网络只返回合成任务，不操作实际 NAS 文件。 */
class FileBackgroundTaskControlUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app); private val recovery = FileRecoveryStores(app)
    private val transfers = TransferStore(app)
    private val previous = profiles.lastProfileId()?.takeUnless { it.startsWith("background-ui-") }
    private val nas = NasProfile("background-ui-${UUID.randomUUID()}", "Task NAS", "https://synthetic.example.invalid", "synthetic")
    private lateinit var model: AppViewModel; private lateinit var repo: DsmRepository
    private val feature get() = model.fileBackgroundTaskControls
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    @Volatile private var gate: CountDownLatch? = null
    @Volatile private var failRead = false
    @Volatile private var allowed = true
    @Volatile private var applyWrites = true
    private var rows = listOf(row())
    @Before fun prepare() {
        @Suppress("UNCHECKED_CAST")
        val snapshots = TransferStore::class.java.getDeclaredMethod("allFileBackgroundTaskSnapshots").apply { isAccessible = true }
            .invoke(transfers) as List<PersistedFileBackgroundTaskSnapshot>
        snapshots.filter { it.profileId.startsWith("background-ui-") }.forEach { transfers.removeProfile(it.profileId) }
        profiles.profiles().filter { it.id.startsWith("background-ui-") }.forEach { recovery.removeProfile(it.id); profiles.removeProfile(it.id) }
        val session = DsmSession(nas.id, "synthetic-session")
        val owner = profiles.commitConnection(profiles.connectionAttempt(nas.id), nas, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(nas.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }; calls += fields
                assertNull(request.url.queryParameter("_sid")); assertNull(request.url.queryParameter("SynoToken"))
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(buildJsonObject {
                    put("success", true); put("data", response(fields))
                }.toString().toResponseBody("application/json".toMediaType())).build()
            }.build())
            val caps = mapOf(FILE_BACKGROUND_API to 3, "SYNO.FileStation.CopyMove" to 3, "SYNO.FileStation.List" to 2)
                .mapValues { (name, version) -> ApiCapability(name, "entry.cgi", 1, version) }
            val reader = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), false) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(nas, session, api, caps, reader); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }; recovery.bind(repo)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(nas, availability = repo.availability(), selectedModule = Module.SETTINGS))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS))
        }
        compose.onNodeWithContentDescription(text(R.string.transfer_filter_source)).performClick()
        compose.onNodeWithText(text(R.string.client_nas_file_tasks)).performClick(); listReady()
    }
    @After fun cleanup() {
        gate?.countDown(); gate = null
        compose.waitUntil(10_000) { !feature.state.value.busy }
        compose.runOnIdle {
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS)); feature.invalidate()
            transfers.removeProfile(nas.id); recovery.removeProfile(nas.id); profiles.removeProfile(nas.id); profiles.setLastProfileId(previous)
        }
        assertNull(transfers.fileBackgroundTaskSnapshot(nas.id))
    }
    @Test fun detailsLoadRetryReferenceAndRecreationKeepNativePage() {
        rows = listOf(JsonObject(row() + ("processed_num" to JsonPrimitive(1))))
        failRead = true; gate = CountDownLatch(1); details()
        compose.waitUntil(10_000) { feature.state.value.detail is Loadable.Loading }; capture("task-loading")
        gate?.countDown(); gate = null; compose.waitUntil(10_000) { feature.state.value.detail is Loadable.Failed }; capture("task-error")
        compose.onNodeWithTag("background_stop").assertDoesNotExist(); failRead = false
        compose.onNodeWithTag("background_refresh").performScrollTo().performClick(); ready()
        compose.onNodeWithText(app.resources.getQuantityString(R.plurals.file_background_task_items_processed, 1, 1)).assertExists(); capture("task-details")
        compose.onNodeWithText("synthetic-task").assertDoesNotExist()
        compose.onNodeWithTag("background_reference").performScrollTo().performClick(); compose.onNodeWithText("synthetic-task").assertExists()
        compose.activityRule.scenario.recreate(); compose.onNodeWithTag("background_task_page").assertExists()
        compose.onNodeWithTag("background_stop").performScrollTo().assertIsEnabled(); assertTrue(writes().isEmpty())
    }
    @Test fun stopExplainsConsequencesAndOnlyConfirmedActionSubmitsOnce() {
        details(); ready(); compose.onNodeWithTag("background_stop").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_background_task_stop_notice)).assertExists(); capture("task-stop-confirm")
        compose.onNodeWithText(text(R.string.cancel)).performClick(); assertTrue(writes().isEmpty())
        compose.onNodeWithTag("background_stop").performClick(); compose.onNodeWithTag("background_confirm").performClick()
        completed(FileBackgroundTaskAction.STOP); capture("task-ended")
        assertEquals(1, writes().size); assertEquals("synthetic-task", writes().single()["taskid"])
        compose.onNodeWithTag("background_clear").performScrollTo().assertIsEnabled()
        compose.onNodeWithText(text(R.string.file_background_task_ended_scope)).assertExists()
        rows = listOf(JsonObject(row() + ("crtime" to JsonPrimitive(1700000010.0))))
        compose.onNodeWithTag("background_refresh").performScrollTo().performClick(); ready()
        compose.onNodeWithTag("background_action_completed").assertDoesNotExist()
        compose.onNodeWithTag("background_stop").performScrollTo().assertIsEnabled(); assertEquals(1, writes().size)
    }
    @Test fun removeRecordKeepsOtherTasksAndDoesNotDeleteFiles() {
        rows = listOf(row(finished = true), row("other-task")); refreshList()
        compose.onAllNodesWithText(text(R.string.file_background_task_details))[0].performClick(); ready()
        compose.onNodeWithTag("background_clear").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_background_task_clear_notice)).assertExists(); capture("task-clear-confirm")
        compose.onNodeWithTag("background_confirm").performClick(); completed(FileBackgroundTaskAction.CLEAR); capture("task-cleared")
        assertEquals("[\"synthetic-task\"]", writes().single()["taskid"])
        assertEquals(listOf("other-task"), rows.map { it.getValue("taskid").jsonPrimitive.content })
        assertEquals("clear_finished", writes().single()["method"])
    }
    @Test fun unknownStopSurvivesRecreationAndMissingListEntryHasReadonlyRecovery() {
        details(); ready(); applyWrites = false
        compose.onNodeWithTag("background_stop").performScrollTo().performClick(); compose.onNodeWithTag("background_confirm").performClick()
        compose.waitUntil(10_000) { !feature.state.value.busy && feature.pendingCurrent() != null }
        compose.activityRule.scenario.recreate(); compose.onNodeWithTag("background_action_unknown").performScrollTo().assertExists(); capture("task-unknown")
        compose.onNodeWithTag("background_stop").assertDoesNotExist(); compose.onNodeWithTag("background_refresh").performScrollTo().performClick(); ready()
        compose.runOnIdle { feature.back() }; rows = emptyList(); refreshList()
        compose.onNodeWithTag("background_recovery_entry").performClick()
        compose.waitUntil(10_000) { feature.state.value.pending is Loadable.Ready }; capture("task-recovery-list")
        compose.onNode(hasText(text(R.string.file_background_task_kind_copy_move)) and hasAnyAncestor(hasTestTag("background_recovery_list"))).performClick(); ready()
        compose.onNodeWithText(text(R.string.file_background_task_not_listed)).assertExists(); capture("task-recovery-missing")
        assertEquals(1, writes().size); rows = listOf(row(finished = true))
        compose.onNodeWithTag("background_refresh").performScrollTo().performClick(); completed(FileBackgroundTaskAction.STOP)
        assertEquals(1, writes().size)
        compose.runOnIdle { feature.back() }; compose.waitUntil(10_000) { feature.state.value.pending is Loadable.Ready }
        compose.onNodeWithText(text(R.string.file_background_task_recovery_empty)).assertExists(); capture("task-recovery-empty")
    }
    @Test fun disappearingTaskHasHonestEmptyDetailsAndRefreshCanRecover() {
        rows = emptyList(); details(); ready()
        compose.onNodeWithText(text(R.string.file_background_task_not_listed)).assertExists(); capture("task-missing")
        compose.onNodeWithTag("background_stop").assertDoesNotExist(); compose.onNodeWithTag("background_clear").assertDoesNotExist()
        rows = listOf(row()); compose.onNodeWithTag("background_refresh").performScrollTo().performClick(); ready()
        compose.onNodeWithTag("background_stop").performScrollTo().assertIsEnabled(); assertTrue(writes().isEmpty())
    }
    @Test fun revokedFileAccessClosesDetailsAndPreventsConfirmedStop() {
        details(); ready(); compose.onNodeWithTag("background_stop").performScrollTo().performClick()
        allowed = false; runBlocking { repo.refreshAccess() }
        compose.runOnIdle {
            ApprovedUiFixture.setState(model, model.workspace.value!!.copy(availability = repo.availability()))
            feature.authorizationChanged(); feature.confirm()
        }
        compose.onNodeWithTag("background_task_page").assertDoesNotExist(); assertTrue(writes().isEmpty())
    }
    private fun details() = compose.onNodeWithText(text(R.string.file_background_task_details)).performClick()
    private fun ready() = compose.waitUntil(10_000) { feature.state.value.detail is Loadable.Ready && feature.state.value.pending is Loadable.Ready }
    private fun listReady() = compose.waitUntil(10_000) { model.workspace.value?.fileBackgroundTasks is Loadable.Ready && model.workspace.value?.fileBackgroundTaskRefreshInProgress == false }
    private fun refreshList() { compose.runOnIdle { model.refreshFileBackgroundTasks() }; listReady() }
    private fun completed(action: FileBackgroundTaskAction) = compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.completedAction == action }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] in setOf("stop", "clear_finished") }.toList() }
    private fun response(fields: Map<String, String>): JsonObject {
        if (fields["api"] == FILE_BACKGROUND_API && fields["method"] == "list") {
            gate?.await(10, TimeUnit.SECONDS); if (failRead) throw IOException("Synthetic read failure")
            val offset = fields.getValue("offset").toInt(); val limit = fields.getValue("limit").toInt()
            return buildJsonObject { put("offset", offset); put("total", rows.size); put("tasks", JsonArray(rows.drop(offset).take(limit))) }
        }
        if (fields["method"] in setOf("stop", "clear_finished")) {
            val clear = fields["method"] == "clear_finished"
            val id = if (clear) Json.parseToJsonElement(fields.getValue("taskid")).jsonArray.single().jsonPrimitive.content else fields.getValue("taskid")
            if (applyWrites) rows = if (clear) rows.filterNot { it["taskid"]?.jsonPrimitive?.content == id }
                else rows.map { if (it["taskid"]?.jsonPrimitive?.content == id) JsonObject(it + ("finished" to JsonPrimitive(true))) else it }
            return buildJsonObject { }
        }
        error("Unexpected synthetic request")
    }
    private fun row(id: String = "synthetic-task", finished: Boolean = false) = buildJsonObject {
        put("taskid", id); put("api", "SYNO.FileStation.CopyMove"); put("version", 3); put("method", "start")
        put("crtime", 1700000000.125); put("finished", finished); put("progress", 0.25); put("processed_num", 2); put("processed_size", 1024); put("total", 4096)
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle(); val instrumentation = InstrumentationRegistry.getInstrumentation(); instrumentation.uiAutomation.waitForIdle(150, 5_000)
        val drawn = CountDownLatch(1)
        instrumentation.runOnMainSync { val frames = android.view.Choreographer.getInstance(); frames.postFrameCallback { frames.postFrameCallback { drawn.countDown() } } }
        assertTrue(drawn.await(5, TimeUnit.SECONDS)); val bitmap = instrumentation.uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "background-task-review/$name.png"); file.parentFile?.mkdirs()
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
