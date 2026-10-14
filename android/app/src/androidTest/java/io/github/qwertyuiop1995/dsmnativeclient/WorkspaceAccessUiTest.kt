package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.ui.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.ClientDeviceScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.PinnedModules
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.*
import java.io.File
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Before
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** 只使用合成账号；拒绝所有真实网络，覆盖实际刷新入口与撤销时的 Compose 页面。 */
class WorkspaceAccessUiTest {
    @get:Rule val rule = createComposeRule()
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val preferences = context.getSharedPreferences("lanstash_interface", Context.MODE_PRIVATE)
    private val models = ViewModelStore()
    private var previousPinned: String? = null
    private fun text(id: Int) = context.getString(id)
    private fun model(state: WorkspaceState = ApprovedUiFixture.state()) = ApprovedUiFixture.model(state).also { models.put("model", it) }

    @Before fun preserve() {
        previousPinned = preferences.getString("pinned_modules_v1", null)
        preferences.edit().putString("pinned_modules_v1", PinnedModules().encode()).commit()
    }
    @After fun restore() {
        models.clear()
        preferences.edit().apply {
            if (previousPinned == null) remove("pinned_modules_v1") else putString("pinned_modules_v1", previousPinned)
        }.commit()
    }

    @Test fun 当前文件权限撤销立即隐藏列表且恢复导航不改偏好() {
        val model = model()
        val preference = preferences.getString("pinned_modules_v1", null)
        rule.setContent { LanStashTheme { val state by model.workspace.collectAsState(); ClientWorkspace(state!!, model) } }
        rule.onNodeWithContentDescription(text(R.string.client_files)).performClick()
        rule.runOnIdle {
            val state = model.workspace.value!!
            ApprovedUiFixture.setState(model, state.copy(availability = state.availability.map {
                if (it.module == Module.FILES) denied(it.module) else it
            }))
        }
        rule.onNodeWithText(text(R.string.module_access_denied)).assertIsDisplayed()
        rule.onNodeWithContentDescription(text(R.string.client_files)).assertDoesNotExist()
        ApprovedUiFixture.state().files.let { it as Loadable.Ready }.value.items.forEach {
            rule.onNodeWithText(it.name).assertDoesNotExist()
        }
        capture("files-access-revoked")
        rule.runOnIdle {
            assertEquals(preference, preferences.getString("pinned_modules_v1", null))
            ApprovedUiFixture.setState(model, model.workspace.value!!.copy(availability = ApprovedUiFixture.state().availability))
        }
        rule.onNodeWithContentDescription(text(R.string.client_files)).assertIsDisplayed()
        rule.runOnIdle { assertEquals(Loadable.Idle, model.workspace.value!!.files) }
    }

    @Test fun 全部功能里的刷新实际读取账号授权() {
        var allowed = true
        var reads = 0
        val state = ApprovedUiFixture.state()
        val capabilities = mapOf("SYNO.FileStation.List" to ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2))
        val reader = WorkspaceAccessReader(capabilities, readPrivileges = {
            reads++; DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), false)
        }, readFileSession = { error("明确摘要不应探测文件") }, readPhotoAccess = { error("没有照片能力") })
        val api = DsmApiClient(OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { error("合成 UI 不应请求网络") }.build())
        val repo = DsmRepository(state.profile, DsmSession(state.profile.id, "synthetic"), api, capabilities, reader)
        runBlocking { repo.refreshAccess() }
        val model = model(state)
        AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
        ApprovedUiFixture.setState(model, state)
        rule.setContent { LanStashTheme { val current by model.workspace.collectAsState(); ClientWorkspace(current!!, model) } }
        rule.onNodeWithContentDescription(text(R.string.client_all_features)).performClick()
        rule.runOnIdle { allowed = false }
        rule.onNodeWithText(text(R.string.refresh)).performScrollTo().performClick()
        rule.waitUntil { !model.workspace.value!!.access.refreshing && reads == 2 }
        rule.runOnIdle {
            assertFalse(model.workspace.value!!.availability.allows(Module.FILES))
            assertEquals(Loadable.Idle, model.workspace.value!!.files)
        }
    }

    @Test fun NAS任务权限撤销不隐藏手机传输记录() {
        val state = ApprovedUiFixture.state().copy(availability = Module.entries.map(::denied))
        val model = model(state)
        var source by mutableStateOf(ClientTaskSource.PHONE)
        rule.setContent { LanStashTheme { ClientTaskCenterScreen(state, model, source) { source = it } } }
        rule.onNodeWithText(state.transfers.single().title).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_nas_file_tasks)).performClick()
        rule.onNodeWithText(text(R.string.module_access_denied)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.client_phone_transfers)).performClick()
        rule.onNodeWithText(state.transfers.single().title).assertIsDisplayed()
    }

    @Test fun 设备权限撤销不显示旧设备信息且设置仍可达() {
        val state = ApprovedUiFixture.state().copy(availability = Module.entries.map(::denied))
        rule.setContent { LanStashTheme { ClientDeviceScreen(state, null, {}, {}, {}, {}) } }
        rule.onNodeWithText("Demo device").assertDoesNotExist()
        rule.onNodeWithText(text(R.string.client_storage_category)).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.module_access_denied)).assertIsDisplayed()
        rule.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(text(R.string.client_app_settings)))
        rule.onNodeWithText(text(R.string.client_app_settings)).assertIsDisplayed()
        capture("device-access-revoked")
    }

    @Test fun 会话过期提供重新登录并在深色界面保持可读() {
        var signIns = 0
        val state = ApprovedUiFixture.state().copy(availability = listOf(ModuleAvailability(Module.FILES, false,
            ModuleUnavailableReason.AUTHENTICATION_REQUIRED, ModuleAccessState.AUTHENTICATION_REQUIRED)))
        rule.setContent { LanStashTheme(darkTheme = true) {
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                WorkspaceAccessNotice(state, Module.FILES, {}, { signIns++ }, Modifier.fillMaxSize())
            }
        } }
        rule.onNodeWithText(text(R.string.workspace_sign_in_again)).performClick()
        rule.runOnIdle { assertEquals(1, signIns) }
        capture("expired-access-dark")
    }

    private fun denied(module: Module) = ModuleAvailability(module, false, ModuleUnavailableReason.ACCESS_DENIED, ModuleAccessState.DENIED)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureAccessUi") != "true") return
        rule.waitForIdle()
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        val directory = File(context.getExternalFilesDir(null), "workspace-access-review").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
