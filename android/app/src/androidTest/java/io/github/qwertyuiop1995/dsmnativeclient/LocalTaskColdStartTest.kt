package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.Intent
import android.net.Uri
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalTaskColdStartTest {
    @Test fun `冷启动任务通知不触发已保存的自动登录`() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        val store = SecureProfileStore(app)
        // 只清理本测试上次在启动阶段中断后留下的合成资料，不触及其他连接。
        store.profiles().filter { it.id.startsWith("task-cold-") && it.address == "https://synthetic.invalid" && it.username == "synthetic" }
            .forEach { store.removeProfile(it.id) }
        val previous = store.lastProfileId()
        val profile = NasProfile("task-cold-${UUID.randomUUID()}", "Synthetic NAS", "https://synthetic.invalid", "synthetic")
        val taskId = "cold-task-${UUID.randomUUID()}"
        val owner = store.commitConnection(store.connectionAttempt(profile.id), profile,
            DsmSession(profile.id, "synthetic-session"), "synthetic-password", true)
        store.setLastProfileId(profile.id)
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, taskId, owner)
        val token = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, taskId))
        try {
            val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            val activity = instrumentation.startActivitySync(Intent(app, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                action = Intent.ACTION_VIEW
                data = Uri.parse(opaqueObjectExternalWorkspaceUri(token))
            }) as MainActivity
            instrumentation.runOnMainSync {
                val host = ViewModelProvider(activity)[WorkspaceHostModel::class.java]
                assertTrue(host.taskHistoryVisible.value)
                assertEquals("${profile.id}:DOWNLOAD:$taskId", host.focusedTaskKey.value)
                assertNull(host.active.value.model.workspace.value)
                assertFalse(host.active.value.model.login.value.isConnecting)
                assertTrue(store.isAutoLoginEnabled(profile.id))
                assertNotNull(store.session(profile.id))
                host.restoreInitialConnection()
                assertFalse(host.active.value.model.login.value.isConnecting)
                activity.recreate()
            }
            instrumentation.waitForIdleSync()
            var recreated: MainActivity? = null
            val deadline = android.os.SystemClock.uptimeMillis() + 10_000
            while (recreated == null && android.os.SystemClock.uptimeMillis() < deadline) {
                instrumentation.runOnMainSync {
                    recreated = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).filterIsInstance<MainActivity>()
                        .firstOrNull { it !== activity }
                }
                if (recreated == null) Thread.sleep(50)
            }
            instrumentation.runOnMainSync {
                val current = requireNotNull(recreated)
                val host = ViewModelProvider(current)[WorkspaceHostModel::class.java]
                assertTrue(host.taskHistoryVisible.value)
                assertFalse(host.active.value.model.login.value.isConnecting)
                assertNull(host.active.value.model.workspace.value)
                assertEquals("${profile.id}:DOWNLOAD:$taskId", host.focusedTaskKey.value)
                current.finish()
            }
        } finally {
            store.removeProfile(profile.id)
            store.setLastProfileId(previous)
        }
    }
}
