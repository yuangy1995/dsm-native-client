package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeStore
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.SystemFileFixture
import org.junit.*
import org.junit.Assert.*

class ChatNoticeUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val store = ChatNoticeStore(app)
    private val fixture = SystemFileFixture()
    private val previous = profiles.lastProfileId()
    private val enabled = store.enabled()
    private lateinit var model: AppViewModel
    @Before fun prepare() {
        // Android 撤销权限会终止测试进程；由专用设备套件在结束后统一回收。
        shell("pm grant ${app.packageName} $POST_NOTIFICATIONS_PERMISSION")
        store.setEnabled(false)
        val owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        val repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(fixture.profile.id, attemptRestore = false)); model = host.active.value.model
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(fixture.profile, availability = repo.availability(), selectedModule = Module.SETTINGS))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS))
        }
    }
    @After fun cleanup() {
        if (::model.isInitialized) compose.runOnIdle { model.chatNotices.clear() }
        store.setEnabled(enabled); profiles.removeProfile(fixture.profile.id); profiles.setLastProfileId(previous)
    }
    private fun shell(value: String) { InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(value).use {
        android.os.ParcelFileDescriptor.AutoCloseInputStream(it).readBytes()
    } }
    @Test fun settingsTogglePersistsAndStatesTheActualForegroundAndScheduledReminderLimits() {
        val toggle = compose.onNodeWithContentDescription(compose.activity.getString(R.string.chat_notices_title))
        toggle.performScrollTo().assertIsOff().assertHeightIsAtLeast(48.dp).performClick()
        compose.waitUntil(8_000) { !model.chatNotices.state.value.changing && store.enabled() }
        toggle.assertIsOn()
        captureSystemIntegration(compose.activity, "chat-notifications")
        compose.onNodeWithText(compose.activity.getString(R.string.chat_notices_limitations)).assertExists()
        toggle.performClick(); compose.waitUntil(8_000) { !model.chatNotices.state.value.changing && !store.enabled() }; toggle.assertIsOff()
    }
    @Test fun deniedAndSyncFailureRemainVisibleWithTheCorrectRecoveryAction() {
        @Suppress("UNCHECKED_CAST")
        val state = model.chatNotices.javaClass.getDeclaredField("mutable").apply { isAccessible = true }.get(model.chatNotices)
            as kotlinx.coroutines.flow.MutableStateFlow<io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeState>
        compose.runOnIdle { state.value = state.value.copy(enabled = true, allowed = false, error = null) }
        compose.onNodeWithText(compose.activity.getString(R.string.chat_notices_denied)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(compose.activity.getString(R.string.chat_notices_settings)).performScrollTo().assertIsEnabled()
        captureSystemIntegration(compose.activity, "chat-notifications-denied")
        compose.runOnIdle { state.value = state.value.copy(allowed = true, error = R.string.chat_notices_sync_failed) }
        compose.onNodeWithText(compose.activity.getString(R.string.chat_notices_sync_failed)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(compose.activity.getString(R.string.retry)).performScrollTo().assertIsEnabled()
        compose.onNodeWithText(compose.activity.getString(R.string.chat_notices_settings)).assertDoesNotExist()
        captureSystemIntegration(compose.activity, "chat-notifications-sync-error")
        compose.runOnIdle { state.value = state.value.copy(error = null) }
        compose.onNodeWithText(compose.activity.getString(R.string.chat_notices_sync_failed)).assertDoesNotExist()
        compose.onNodeWithContentDescription(compose.activity.getString(R.string.chat_notices_title)).performScrollTo().assertIsOn()
    }
}
