package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

/** 真实宿主、持久任务和 PendingIntent；不恢复任何 NAS，也不产生网络请求。 */
class GlobalTaskCenterUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val application = ApplicationProvider.getApplicationContext<Application>()
    private val store = SecureProfileStore(application)
    private val transfers = TransferStore(application)
    private val previous = store.lastProfileId()
    private val suffix = UUID.randomUUID().toString()
    private val first = NasProfile("tasks-a-$suffix", "Home NAS", "https://first.example.invalid", "synthetic-a")
    private val second = NasProfile("tasks-b-$suffix", "Studio NAS", "https://second.example.invalid", "synthetic-b")
    private val a = "download-a-$suffix"
    private val b = "download-b-$suffix"
    private lateinit var host: WorkspaceHostModel
    private lateinit var launchIntent: Intent
    private lateinit var trackedActivity: MainActivity

    @Before fun seedLocalHistory() {
        compose.runOnIdle {
            trackedActivity = compose.activity
            launchIntent = Intent(trackedActivity.intent)
            host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            listOf(first to a, second to b).forEach { (profile, id) ->
                val owner = store.commitConnection(store.connectionAttempt(profile.id), profile,
                    DsmSession(profile.id, "synthetic-session"), null, false)
                store.bindRecord(WorkspaceRecordKind.DOWNLOAD, id, owner)
                transfers.upsert(PersistedDownload(id, profile.id, "/synthetic/$id", if (id == a) "First.txt" else "Second.txt",
                    "content://synthetic.invalid/$id", false, 4096, TransferState.RUNNING, 1024))
            }
            assertTrue(host.select(first.id, attemptRestore = false))
            assertNull(host.active.value.model.workspace.value)
        }
    }

    @After fun cleanOnlySyntheticHistory() {
        // ActivityScenario 以启动 Intent 识别生命周期；已消费的通知事件不能成为测试宿主标识。
        InstrumentationRegistry.getInstrumentation().runOnMainSync { trackedActivity.intent = launchIntent }
        compose.runOnIdle {
            host.closeTaskHistory()
            transfers.remove(a); transfers.remove(b)
            store.removeProfile(first.id); store.removeProfile(second.id)
            store.setLastProfileId(previous)
        }
    }

    @Test fun `未连接时能查看双NAS任务且暂停只修改原任务`() {
        compose.runOnIdle { assertTrue(host.showTaskHistory()) }
        awaitRows(2)
        showTask("First.txt")
        showTask("Second.txt")
        compose.onNodeWithText(application.getString(R.string.task_nas_to_phone, second.name)).assertIsDisplayed()
        capture("tasks-all-offline")
        compose.onNode(hasText(application.getString(R.string.pause_download)) and hasAnyAncestor(hasTestTag("global_task_${key(second, b)}")), useUnmergedTree = true).performClick()
        compose.waitUntil(10_000) { transfers.download(b)?.state == TransferState.PAUSED }
        assertEquals(TransferState.RUNNING, transfers.download(a)?.state)
        assertNull(host.active.value.model.workspace.value)
        assertFalse(host.active.value.model.login.value.isConnecting)
    }

    @Test fun `不同通知保留各自目标并且重建不重连`() {
        val firstIntent = TransferNotifications.openAppIntent(application, a, WorkspaceRecordKind.DOWNLOAD)
        val secondIntent = TransferNotifications.openAppIntent(application, b, WorkspaceRecordKind.DOWNLOAD)
        assertNotEquals(firstIntent, secondIntent)
        secondIntent.send()
        compose.waitUntil(10_000) { host.focusedTaskKey.value == key(second, b) }
        awaitRows(2)
        showTask("Second.txt")
        InstrumentationRegistry.getInstrumentation().runOnMainSync { trackedActivity.intent = launchIntent; trackedActivity.recreate() }
        compose.waitUntil(10_000) {
            var recreated: MainActivity? = null
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                recreated = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull()
            }
            recreated?.takeIf { it !== trackedActivity }?.also { trackedActivity = it } != null
        }
        compose.runOnIdle { assertSame(host, ViewModelProvider(trackedActivity)[WorkspaceHostModel::class.java]) }
        compose.waitUntil(10_000) { host.taskHistoryVisible.value }
        assertEquals(key(second, b), host.focusedTaskKey.value)
        firstIntent.send()
        compose.waitUntil(10_000) { host.focusedTaskKey.value == key(first, a) }
        assertNull(host.active.value.model.workspace.value)
        assertFalse(host.active.value.model.login.value.isConnecting)
        assertEquals(first.id, host.active.value.model.login.value.selectedProfileId)
    }

    @Test fun `账号更改后隐藏旧标题并禁止旧按钮与旧通知`() {
        compose.runOnIdle { host.showTaskHistory() }
        awaitRows(2)
        val oldItem = (host.taskCenter.state.value as Loadable.Ready).value.first { it.task.id == a }
        val oldToken = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, a))
        compose.runOnIdle {
            val replacement = first.copy(username = "new-synthetic-account")
            store.commitConnection(store.connectionAttempt(first.id), replacement,
                DsmSession(first.id, "replacement-session"), null, false)
        }
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.firstOrNull { it.task.id == a }?.profile == null }
        compose.onNodeWithText("First.txt").assertDoesNotExist()
        compose.onNodeWithText(application.getString(R.string.task_original_connection_unavailable)).assertIsDisplayed()
        compose.runOnIdle {
            host.actOnTask(oldItem, GlobalTransferAction.PAUSE)
            assertEquals(TransferState.RUNNING, transfers.download(a)?.state)
            assertNull(store.opaqueWorkspaceRoute(oldToken))
        }
    }

    @Test fun `通知打开已结束任务并在记录移除后说明原因`() {
        transfers.update(b) { it.copy(state = TransferState.SUCCEEDED, completedBytes = 4096) }
        val token = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, b))
        compose.activity.startActivity(Intent(application, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW; data = Uri.parse(opaqueObjectExternalWorkspaceUri(token))
        })
        compose.waitUntil(10_000) { host.focusedTaskKey.value == key(second, b) }
        awaitRows(2)
        showTask("Second.txt")
        compose.onNodeWithText(application.getString(R.string.client_finished_tasks)).assertIsSelected()
        transfers.remove(b)
        awaitRows(1)
        compose.onNodeWithText(application.getString(R.string.task_record_missing)).assertIsDisplayed()
    }

    @Test fun `空历史和筛选为空分别提供可理解的状态`() {
        compose.runOnIdle { host.showTaskHistory() }
        awaitRows(2)
        compose.onNodeWithText(application.getString(R.string.client_finished_tasks)).performClick()
        compose.onNodeWithText(application.getString(R.string.no_filtered_transfer_tasks)).assertIsDisplayed()
        transfers.remove(a); transfers.remove(b)
        awaitRows(0)
        compose.onNodeWithText(application.getString(R.string.no_transfer_tasks)).assertIsDisplayed()
    }

    @Test fun `本机记录读取失败不冒充空列表且重试恢复原任务`() {
        val currentStore = GlobalTaskCenterModel::class.java.getDeclaredField("transfers").apply { isAccessible = true }.get(host.taskCenter)
        PreferenceFailureFixture(requireNotNull(currentStore)).use { failure ->
            failure.failReads = true
            compose.runOnIdle { host.showTaskHistory(); host.taskCenter.retry() }
            compose.waitUntil(10_000) { host.taskCenter.state.value is Loadable.Failed }
            compose.onNodeWithText(application.getString(R.string.task_history_read_failed)).assertIsDisplayed()
            compose.onNodeWithText(application.getString(R.string.no_transfer_tasks)).assertDoesNotExist()
            compose.onNodeWithText(application.getString(R.string.retry)).assertIsEnabled(); capture("task-history-storage-error")
            failure.failReads = false
            compose.onNodeWithText(application.getString(R.string.retry)).performClick(); awaitRows(2)
            showTask("First.txt"); showTask("Second.txt")
            assertNull(host.active.value.model.workspace.value); assertFalse(host.active.value.model.login.value.isConnecting)
        }
    }

    private fun showTask(title: String) {
        compose.onNodeWithTag("global_task_list").performScrollToNode(hasText(title))
        compose.onNodeWithText(title).assertIsDisplayed()
    }
    private fun key(profile: NasProfile, id: String) = "${profile.id}:DOWNLOAD:$id"
    private fun row(profile: NasProfile, id: String) = compose.onNodeWithTag("global_task_${key(profile, id)}", useUnmergedTree = true)
    private fun awaitRows(size: Int) {
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.count { it.profileId in setOf(first.id, second.id) } == size }
        compose.waitForIdle()
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(application.getExternalFilesDir(null), "workspace-task-review/$name.png")
        file.parentFile?.mkdirs()
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
