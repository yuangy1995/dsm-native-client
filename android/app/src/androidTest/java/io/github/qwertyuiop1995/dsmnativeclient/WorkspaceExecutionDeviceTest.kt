package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.app.NotificationManager
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.background.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

/** 正式前台服务与通知取消；任务仅等待，不执行真实网络或用户文件读写。 */
class WorkspaceExecutionDeviceTest {
    @get:Rule val activity = ActivityScenarioRule(MainActivity::class.java)
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val registry = WorkspaceExecutionRegistry.shared
    private val executor = AndroidWorkspaceExecution(app)
    private val profile = NasProfile(UUID.randomUUID().toString(), "Synthetic execution", "https://synthetic.invalid", "test")
    private val previous = profiles.lastProfileId()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var owner: WorkspaceOwner
    @Before fun prepare() {
        // Android 撤销权限会终止测试进程；由专用设备套件在结束后统一回收。
        shell("pm grant ${app.packageName} $POST_NOTIFICATIONS_PERMISSION")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false, persistSession = true)
    }
    @After fun cleanup() = runBlocking {
        scope.cancel(); waitFor { registry.entries.value.isEmpty() }
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
    }
    private fun shell(value: String) { InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(value).use {
        android.os.ParcelFileDescriptor.AutoCloseInputStream(it).readBytes()
    } }
    private suspend fun waitFor(predicate: () -> Boolean) {
        try { withTimeout(10_000) { while (!predicate()) delay(20) } }
        catch (error: TimeoutCancellationException) { throw AssertionError("Execution did not settle: registry=${registry.entries.value.size}, notices=${notices().map { it.id }}", error) }
    }
    private fun notices() = app.getSystemService(NotificationManager::class.java).activeNotifications.filter { it.notification.channelId == WorkspaceExecutionService.CHANNEL }
    @Test fun realForegroundServiceSupportsProgressAndEachNotificationCancelsOnlyItsOriginalOperation() = runBlocking {
        val started = CompletableDeferred<Unit>(); val secondStarted = CompletableDeferred<Unit>()
        val first = scope.launch {
            val lease = executor.begin(owner, WorkspaceExecutionActivity.OFFICE_SAVE)
            try { lease.update(25, 100); started.complete(Unit); awaitCancellation() } finally { lease.finish() }
        }
        started.await()
        val second = scope.launch {
            val lease = executor.begin(owner, WorkspaceExecutionActivity.PHOTO_UPLOAD)
            try { secondStarted.complete(Unit); awaitCancellation() } finally { lease.finish() }
        }
        secondStarted.await(); waitFor { notices().size == 2 }
        val notice = notices().single { it.notification.extras.getCharSequence("android.title") == app.getString(R.string.execution_office_save) }
        assertEquals(250, notice.notification.extras.getInt("android.progress"))
        assertFalse(notice.notification.extras.toString().contains("synthetic.invalid"))
        notice.notification.actions.single().actionIntent.send()
        first.join(); waitFor { registry.entries.value.size == 1 }; assertTrue(second.isActive)
        notice.notification.actions.single().actionIntent.send(); delay(50); assertTrue(second.isActive)
        second.cancelAndJoin(); waitFor { notices().isEmpty() }
    }
    @Test fun anAlreadyStartedOperationStaysOwnedWhileActivityIsInBackground() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val operation = scope.launch {
            val lease = executor.begin(owner, WorkspaceExecutionActivity.CROSS_NAS)
            try { started.complete(Unit); awaitCancellation() } finally { lease.finish() }
        }
        started.await(); shell("input keyevent KEYCODE_HOME")
        delay(250); assertTrue(operation.isActive); assertEquals(1, registry.entries.value.size)
        val row = registry.entries.value.single()
        assertEquals(profile.id, profiles.opaqueWorkspaceRoute(row.route)!!.profileId)
        notices().single().notification.actions.single().actionIntent.send(); operation.join()
        waitFor { registry.entries.value.isEmpty() && notices().isEmpty() }
    }
}
