package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

/** 实际 MainActivity 与宿主切换，只有合成响应；任何未列出的请求立即失败。 */
class WorkspaceHostUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val application = ApplicationProvider.getApplicationContext<Application>()
    private val store = SecureProfileStore(application)
    private val previousSelection = store.lastProfileId()
    private val suffix = UUID.randomUUID().toString()
    private val first = NasProfile("host-a-$suffix", "Shared NAS", "https://nas.example.invalid", "account-a")
    private val second = first.copy(id = "host-b-$suffix", username = "account-b")
    private lateinit var host: WorkspaceHostModel
    private lateinit var firstModel: AppViewModel
    private lateinit var secondModel: AppViewModel

    @Before fun connectSyntheticWorkspaces() {
        compose.runOnIdle {
            for (profile in listOf(first, second)) store.commitConnection(store.connectionAttempt(profile.id), profile,
                DsmSession(profile.id, "synthetic-session"), null, false)
            host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            firstModel = install(first)
            secondModel = install(second)
            assertTrue(host.select(first.id))
        }
        compose.waitForIdle()
    }

    @After fun cleanSyntheticConnections() {
        compose.runOnIdle {
            store.removeProfile(first.id); store.removeProfile(second.id)
            store.setLastProfileId(previousSelection)
        }
    }

    @Test fun `选择器区分同NAS双账号且切换后顶部归属明确`() {
        compose.onNodeWithText("Shared NAS").performClick()
        compose.onAllNodesWithText("account-a", useUnmergedTree = true).onFirst().assertExists()
        compose.onAllNodesWithText("account-b").onFirst().assertIsDisplayed()
        capture("account-picker")
        compose.onAllNodesWithText("account-b").onFirst().performClick()
        compose.waitForIdle()
        compose.runOnIdle {
            assertSame(secondModel, host.active.value.model)
            assertEquals(second.id, host.active.value.model.workspace.value?.profile?.id)
            assertNotNull(firstModel.workspace.value)
        }
        compose.onNodeWithText("account-b").assertIsDisplayed()
        capture("account-b-home")
    }

    @Test fun `切换保留原目录页面与原Repository归属`() {
        compose.onNodeWithContentDescription(compose.activity.getString(R.string.client_files)).performClick()
        compose.runOnIdle {
            val current = requireNotNull(firstModel.workspace.value)
            ApprovedUiFixture.setState(firstModel, current.copy(fileBrowser = current.fileBrowser.copy(path = "/synthetic/first")))
            assertTrue(host.select(second.id))
            assertTrue(host.select(first.id))
            assertSame(firstModel, host.active.value.model)
            assertEquals("/synthetic/first", firstModel.workspace.value?.fileBrowser?.path)
            assertEquals(first.id, firstModel.workspaceOwner?.profileId)
            assertEquals(second.id, secondModel.workspaceOwner?.profileId)
        }
        compose.waitForIdle()
        compose.onNodeWithContentDescription(compose.activity.getString(R.string.client_files)).assertIsSelected()
        compose.onNodeWithText("account-a", substring = true).assertIsDisplayed()
    }

    @Test fun `退出当前连接不会清除另一个连接的会话或页面`() {
        compose.runOnIdle {
            val otherState = secondModel.workspace.value
            val otherOwner = secondModel.workspaceOwner
            host.signOut(first.id)
            assertNull(firstModel.workspace.value)
            assertNull(store.currentOwner(first.id))
            assertEquals(otherState, secondModel.workspace.value)
            assertEquals(otherOwner, secondModel.workspaceOwner)
            store.requireCurrentOwner(requireNotNull(otherOwner))
            assertTrue(host.select(second.id))
        }
        compose.waitForIdle()
        compose.onNodeWithText("account-b").assertIsDisplayed()
    }

    @Test fun `新增连接不恢复上次账号并可返回原工作区`() {
        compose.runOnIdle {
            assertTrue(host.newConnection())
            val draft = host.active.value.model
            assertNull(draft.workspace.value)
            assertNull(draft.login.value.selectedProfileId)
            assertEquals("", draft.login.value.savedPassword)
            assertFalse(draft.login.value.isConnecting)
        }
        compose.onNodeWithTag("login_address").assertIsDisplayed()
        compose.onNodeWithContentDescription(compose.activity.getString(R.string.go_up)).performClick()
        compose.runOnIdle { assertSame(firstModel, host.active.value.model); assertNotNull(firstModel.workspace.value) }
    }

    @Test fun `未结束的旧写流程继续保留切换保护`() {
        compose.runOnIdle {
            ApprovedUiFixture.setState(firstModel, requireNotNull(firstModel.workspace.value).copy(isPerformingAction = true))
            assertFalse(host.select(second.id))
            assertFalse(host.showPicker())
            assertSame(firstModel, host.active.value.model)
            assertTrue(firstModel.workspace.value?.message?.isNotBlank() == true)
        }
    }

    @Test fun `连接选择器支持键盘确认`() {
        compose.onNodeWithText("Shared NAS").performClick()
        val target = compose.onAllNodesWithText("account-b").onFirst()
        // 模拟器没有硬件键盘；切换系统输入模式后才测试原生键盘焦点。
        InstrumentationRegistry.getInstrumentation().setInTouchMode(false)
        try {
            compose.waitForIdle()
            target.performSemanticsAction(SemanticsActions.RequestFocus) { assertTrue(it()) }
            target.assertIsFocused()
            target.performKeyInput { pressKey(Key.Enter) }
            compose.waitUntil { host.active.value.model === secondModel }
        } finally {
            InstrumentationRegistry.getInstrumentation().setInTouchMode(true)
        }
    }

    @Test fun `空连接选择器提供添加入口`() {
        compose.runOnIdle {
            host.removeConnection(first)
            host.removeConnection(second)
            assertTrue(host.connections.value.isEmpty())
            assertTrue(host.showPicker())
        }
        compose.onNodeWithText(compose.activity.getString(R.string.client_add_nas)).assertIsDisplayed().performClick()
        compose.onNodeWithTag("login_address").assertIsDisplayed()
    }

    @Test fun `连接失败仍保留对应账号入口和退出菜单`() {
        compose.runOnIdle {
            ApprovedUiFixture.setState(secondModel, requireNotNull(secondModel.workspace.value).copy(
                access = WorkspaceAccessUiState(failure = DsmFailure(null, "Synthetic offline", "Synthetic retry",
                    kind = DsmErrorKind.CONNECTION_FAILED))))
            assertTrue(host.showPicker())
        }
        compose.onNodeWithText(compose.activity.getString(R.string.workspace_connection_attention)).assertIsDisplayed()
        compose.onAllNodesWithContentDescription(compose.activity.getString(R.string.client_device_actions)).onLast().performClick()
        compose.onNodeWithText(compose.activity.getString(R.string.sign_out_description)).assertIsDisplayed().performClick()
        val accountName = compose.activity.getString(R.string.workspace_account_page, second.name, second.username)
        compose.onNodeWithText(compose.activity.getString(R.string.workspace_sign_out_title, accountName)).assertIsDisplayed()
        compose.onNodeWithText(compose.activity.getString(R.string.cancel)).performClick()
        compose.runOnIdle { assertNotNull(firstModel.workspace.value); assertNotNull(secondModel.workspace.value) }
    }

    @Test fun `同名设备与同名账号仍通过地址区分`() {
        val other = second.copy(username = first.username, address = "https://other.example.invalid")
        compose.runOnIdle {
            store.commitConnection(store.connectionAttempt(other.id), other, DsmSession(other.id, "synthetic-session"), null, false)
            install(other)
            assertTrue(host.select(first.id))
            assertTrue(host.showPicker())
        }
        compose.onAllNodesWithText(first.address).onFirst().assertIsDisplayed()
        compose.onNodeWithText(other.address).assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(other.id, host.active.value.model.workspace.value?.profile?.id) }
        compose.onNodeWithText(other.address).assertIsDisplayed()
    }

    @Test fun `重命名只更新文字并保留原会话和目录`() {
        val owner = firstModel.workspaceOwner
        compose.runOnIdle {
            val state = requireNotNull(firstModel.workspace.value)
            ApprovedUiFixture.setState(firstModel, state.copy(fileBrowser = state.fileBrowser.copy(path = "/synthetic/kept")))
            assertTrue(host.showPicker())
        }
        compose.onAllNodesWithContentDescription(compose.activity.getString(R.string.client_device_actions)).onFirst().performClick()
        compose.onNodeWithText(compose.activity.getString(R.string.rename)).performClick()
        compose.onNodeWithTag("connection_display_name").performTextReplacement("Renamed NAS")
        val revision = io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceIdentityChanges.value
        compose.onNodeWithText(compose.activity.getString(R.string.save)).performSemanticsAction(SemanticsActions.OnClick) { it(); it() }
        compose.waitUntil(10_000) { firstModel.workspace.value?.profile?.name == "Renamed NAS" }
        compose.runOnIdle {
            assertEquals(owner, firstModel.workspaceOwner)
            assertEquals("/synthetic/kept", firstModel.workspace.value?.fileBrowser?.path)
            assertSame(firstModel, host.active.value.model)
            assertEquals(revision + 1, io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceIdentityChanges.value)
        }
    }

    @Test fun `重命名保存失败保留输入和原身份重试才更新名称`() {
        val hostStore = WorkspaceHostModel::class.java.getDeclaredField("store").apply { isAccessible = true }.get(host)
        val owner = firstModel.workspaceOwner
        PreferenceFailureFixture(requireNotNull(hostStore)).use { failure ->
            compose.runOnIdle { assertTrue(host.showPicker()) }
            compose.onAllNodesWithContentDescription(compose.activity.getString(R.string.client_device_actions)).onFirst().performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.rename)).performClick()
            compose.onNodeWithTag("connection_display_name").performTextReplacement("Recovered NAS")
            failure.failCommits = true
            compose.onNodeWithText(compose.activity.getString(R.string.save)).performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText(compose.activity.getString(R.string.error_connection_name_save)).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText(compose.activity.getString(R.string.error_connection_name_save)).assertIsDisplayed()
            compose.onNodeWithTag("connection_display_name").assertTextContains("Recovered NAS")
            compose.runOnIdle { assertEquals(first.name, firstModel.workspace.value?.profile?.name); assertEquals(owner, firstModel.workspaceOwner) }
            capture("connection-name-storage-error")
            failure.failCommits = false
            compose.onNodeWithText(compose.activity.getString(R.string.save)).performClick()
            compose.waitUntil(10_000) { firstModel.workspace.value?.profile?.name == "Recovered NAS" }
            compose.onNodeWithText(compose.activity.getString(R.string.error_connection_name_save)).assertDoesNotExist()
            assertEquals(owner, firstModel.workspaceOwner)
        }
    }

    @Test fun `任务中心按全部设备或当前账号筛选且固定页链接回到原账号`() {
        compose.runOnIdle {
            ApprovedUiFixture.setState(firstModel, requireNotNull(firstModel.workspace.value).copy(transfers = listOf(
                TransferTask("foreground-a", "Account A task", "", TransferDirection.UPLOAD, TransferState.RUNNING))))
            ApprovedUiFixture.setState(secondModel, requireNotNull(secondModel.workspace.value).copy(transfers = listOf(
                TransferTask("foreground-b", "Account B task", "", TransferDirection.UPLOAD, TransferState.RUNNING))))
            firstModel.requestClientModule(Module.TRANSFERS)
        }
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.size == 2 }
        compose.onNodeWithText("Account A task").assertIsDisplayed()
        compose.onNodeWithText("Account B task").assertIsDisplayed()
        compose.onNodeWithText(application.getString(R.string.workspace_account_page, first.name, first.username)).performClick()
        compose.onNodeWithText("Account A task").assertIsDisplayed()
        compose.onNodeWithText("Account B task").assertDoesNotExist()
        compose.onNodeWithText(application.getString(R.string.task_all_devices)).performClick()
        compose.onNodeWithText("Account B task").assertIsDisplayed()
        capture("tasks-account-filter")
        lateinit var token: String
        compose.runOnIdle {
            ApprovedUiFixture.setState(firstModel, requireNotNull(firstModel.workspace.value).copy(transfers = emptyList()))
            ApprovedUiFixture.setState(secondModel, requireNotNull(secondModel.workspace.value).copy(transfers = emptyList()))
            firstModel.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS))
            firstModel.copyCurrentPageLink()
            val clipboard = application.getSystemService(android.content.ClipboardManager::class.java)
            val uri = clipboard.primaryClip!!.getItemAt(0).text.toString()
            token = (uri.externalWorkspaceRoute() as ExternalWorkspaceRoute.OpaqueObject).token
            val route = requireNotNull(store.opaqueWorkspaceRoute(token))
            assertEquals(first.id, route.profileId)
            assertEquals(OpaqueWorkspaceTarget.Page(WorkspacePage.SETTINGS), route.target)
            assertTrue(host.select(second.id))
            assertTrue(host.selectForOpaqueTarget(token))
            assertSame(firstModel, host.active.value.model)
            firstModel.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS))
            firstModel.navigateToOpaqueExternalRoute(token)
        }
        compose.waitUntil { firstModel.workspace.value?.selectedModule == Module.SETTINGS }
        assertEquals(second.id, secondModel.workspace.value?.profile?.id)
    }

    @Test fun `跨账号继续任务先回原任务页且过时操作不重放已完成任务`() {
        val transfers = io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore(application)
        val id = "finished-$suffix"
        val owner = requireNotNull(secondModel.workspaceOwner)
        try {
            store.bindRecord(io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.DOWNLOAD, id, owner)
            transfers.upsert(io.github.qwertyuiop1995.dsmnativeclient.data.PersistedDownload(id, second.id,
                "/synthetic/finished.txt", "Finished.txt", "content://synthetic.invalid/finished", false,
                state = TransferState.SUCCEEDED))
            val previous = GlobalTransferItem(second.id,
                io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind.DOWNLOAD, owner, second,
                TransferTask(id, "Finished.txt", "", TransferDirection.DOWNLOAD, TransferState.PAUSED), canResume = true)
            compose.runOnIdle {
                host.actOnTask(previous, GlobalTransferAction.RESUME)
                assertSame(secondModel, host.active.value.model)
                assertEquals(Module.TRANSFERS, secondModel.workspace.value?.selectedModule)
                host.actOnTask(previous, GlobalTransferAction.RESUME)
                assertEquals(TransferState.SUCCEEDED, transfers.download(id)?.state)
                assertNull(transfers.download(id)?.workId)
            }
        } finally { transfers.remove(id) }
    }

    private fun install(profile: NasProfile): AppViewModel {
        assertTrue(host.select(profile.id, attemptRestore = false))
        val model = host.active.value.model
        val api = DsmApiClient(OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { chain ->
                val request = chain.request()
                val body = request.body as? FormBody ?: error("Unexpected non-form synthetic request")
                val method = (0 until body.size).firstOrNull { body.name(it) == "method" }?.let(body::value)
                val data = when (method) {
                    "list_share" -> """{"shares":[],"offset":0,"total":0}"""
                    "getinfo" -> """{"files":[]}"""
                    "list" -> """{"files":[],"offset":0,"total":0}"""
                    else -> error("Unexpected synthetic request")
                }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body("""{"success":true,"data":$data}""".toResponseBody("application/json".toMediaType())).build()
            }.build())
        val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), api,
            listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2)).associateBy { it.name })
        val owner = requireNotNull(store.currentOwner(profile.id))
        repo.bindOwner(owner) { store.requireCurrentOwner(owner) }
        AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
        ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.FILES,
            files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
        return model
    }

    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val output = File(application.getExternalFilesDir(null), "workspace-identity-review/$name.png")
        output.parentFile?.mkdirs()
        output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
