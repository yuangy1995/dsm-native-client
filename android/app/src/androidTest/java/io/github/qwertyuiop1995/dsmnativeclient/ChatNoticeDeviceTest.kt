package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.app.NotificationManager
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*
import java.util.UUID

/** 使用真实系统通知中心；合成账号和加密索引独立清理，不发送任何 NAS 请求。 */
class ChatNoticeDeviceTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val store = ChatNoticeStore(app)
    private val driver = ChatNoticeDriver(app, store, profiles)
    private val manager get() = app.getSystemService(NotificationManager::class.java)
    private val profile = NasProfile(UUID.randomUUID().toString(), "Synthetic notices", "https://synthetic.invalid", "test")
    private val previousProfile = profiles.lastProfileId()
    private val previousEnabled = store.enabled()
    private lateinit var owner: WorkspaceOwner
    private lateinit var noticeScope: ChatNoticeScope
    @Before fun prepare() {
        // Android 撤销权限会终止测试进程；由专用设备套件在结束后统一回收。
        shell("pm grant ${app.packageName} $POST_NOTIFICATIONS_PERMISSION")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session"), null, false, persistSession = true)
        store.setEnabled(true); noticeScope = store.scope(owner); assertTrue(driver.allowed())
    }
    @After fun cleanup() {
        if (::noticeScope.isInitialized) { driver.remove(noticeScope); store.remove(noticeScope) }
        store.setEnabled(previousEnabled); profiles.removeProfile(profile.id); profiles.setLastProfileId(previousProfile)
    }
    private fun shell(value: String) { InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(value).use { descriptor ->
        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).readBytes()
    } }
    private fun awaitNotice() {
        val until = android.os.SystemClock.elapsedRealtime() + 5_000
        while (notices().isEmpty() && android.os.SystemClock.elapsedRealtime() < until) Thread.sleep(10)
        assertEquals(1, notices().size)
    }
    private fun notices() = manager.activeNotifications.filter { it.tag?.startsWith(ChatNoticeDriver.tag(noticeScope)) == true }
    @Test fun notificationContainsOnlyGenericTextAndOpaqueOriginalConversationRoute() {
        val route = driver.route(noticeScope, "synthetic-channel")!!; driver.incoming(noticeScope, route)
        awaitNotice(); val notice = notices().single(); assertFalse(notice.tag.contains("synthetic"))
        assertEquals(app.getString(R.string.chat_notice_message_title), notice.notification.extras.getCharSequence("android.title").toString())
        assertEquals(app.getString(R.string.chat_notice_open), notice.notification.extras.getCharSequence("android.text").toString())
        assertEquals(profile.id, profiles.opaqueWorkspaceRoute(route)!!.profileId)
        assertEquals(OpaqueWorkspaceTarget.ChatConversation("synthetic-channel"), profiles.opaqueWorkspaceRoute(route)!!.target)
        assertNotNull(notice.notification.contentIntent)
        driver.incoming(noticeScope, route); assertEquals(1, notices().size)
    }
    @Test fun reminderDeliversOnceAndCanceledOrChangedRecordCannotFire() {
        val route = driver.route(noticeScope, "synthetic-channel")!!
        val now = System.currentTimeMillis()
        store.sync(noticeScope, "synthetic-channel", listOf(ChatReminder("r", "m", now + 100)), route, now)
        val row = store.reminders(noticeScope.id).single()
        assertFalse(driver.deliver(row, now)); assertTrue(driver.deliver(row, now + 100)); assertFalse(driver.deliver(row, now + 100))
        awaitNotice()
        store.sync(noticeScope, "synthetic-channel", listOf(row.reminder.copy(remindAtEpochMillis = now + 1_000)), route, now)
        assertFalse(driver.deliver(row, now + 2_000))
        store.sync(noticeScope, "synthetic-channel", emptyList(), route, now)
        assertFalse(driver.deliver(row, now + 3_000))
    }
    @Test fun signedOutAndDisabledConnectionsCannotShowNotifications() {
        val route = driver.route(noticeScope, "synthetic-channel")!!
        store.setEnabled(false); driver.incoming(noticeScope, route); assertTrue(notices().isEmpty())
        store.setEnabled(true); profiles.signOut(owner); driver.incoming(noticeScope, route); assertTrue(notices().isEmpty())
    }
}
