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

/** 正式文件入口及连接页面；只有 NAS 网络和资料使用合成夹具。 */
class FileVFSUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val recovery = FileVFSRecoveryStore(app)
    private val previous = profiles.lastProfileId()?.takeUnless { it.startsWith("vfs-ui-") }
    private val nas = NasProfile("vfs-ui-" + UUID.randomUUID(), "VFS NAS", "https://synthetic.example.invalid", "synthetic")
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    private lateinit var owner: WorkspaceOwner
    private lateinit var model: AppViewModel
    private lateinit var repo: DsmRepository
    private lateinit var original: FileVFSProfile
    @Volatile private var connections = emptyList<FileVFSProfile>()
    @Volatile private var allowed = true
    @Volatile private var inventoryFailure = false
    @Volatile private var folderFailure = false
    @Volatile private var loseSecondResponse = false
    @Volatile private var inventoryGate: CountDownLatch? = null
    @Volatile private var folderGate: CountDownLatch? = null
    @Volatile private var emptyFolder = false
    private var setup = FileVFSConfiguration("davs", "server.invalid", 443, "Saved server", "synthetic-account", folder = "Shared Files")

    @Before fun prepare() {
        // 清理本组先前被中止后留下的合成资料，不读取或输出其他账号。
        profiles.profiles().filter { it.id.startsWith("vfs-ui-") }.forEach { recovery.removeProfile(it.id); profiles.removeProfile(it.id) }
        val session = DsmSession(nas.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(nas.id), nas, session, null, false)
        original = FileVFSProfile(owner, "opaque-id", "davs", "WebDAV", "davs://opaque-root/Shared Files", setup.hostname, setup.port,
            setup.alias, setup.account, setup.codepage, FileVFSConnectionState.CONNECTED)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(nas.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as? FormBody
                val fields = if (form != null) (0 until form.size).associate { form.name(it) to form.value(it) }
                    else request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
                calls += fields
                val body = if (fields["method"] == "download") "original".toByteArray().toResponseBody("application/octet-stream".toMediaType())
                    else { val data = response(fields); assertNull(request.url.query)
                        buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType()) }
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
            }.build())
            val caps = listOf(VFS_PROFILE_API, VFS_PROTOCOL_API, VFS_CONNECTION_API, "SYNO.FileStation.List", "SYNO.FileStation.Download", "SYNO.Core.System")
                .associateWith { ApiCapability(it, "entry.cgi", 1, if (it in setOf("SYNO.FileStation.List", "SYNO.FileStation.Download")) 2 else 1) }
            val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), true) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(nas, session, api, caps, access); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            repo.fileMounts.vfs.bindRecovery(recovery)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(nas, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = "/synthetic"), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        compose.waitUntil(10_000) { model.workspace.value?.files is Loadable.Ready }
    }
    @After fun clean() {
        inventoryGate?.countDown(); folderGate?.countDown()
        compose.waitUntil(10_000) { !model.fileVFS.state.value.busy }
        compose.runOnIdle {
            model.fileVFS.invalidate(); recovery.removeProfile(nas.id)
            val transfers = TransferStore(app)
            transfers.downloads(nas.id).forEach { record ->
                model.cancelTransfer(record.id)
                runCatching { app.contentResolver.delete(android.net.Uri.parse(record.destinationUri), null, null) }
                transfers.remove(record.id)
            }
            profiles.removeProfile(nas.id); profiles.setLastProfileId(previous)
        }
    }

    @Test fun ftpCreateRequiresCleartextConsentAndRecreationClearsPassword() {
        openManager(); compose.onNodeWithTag("vfs_add_server").performClick()
        fill("vfs_alias", "Synthetic FTP"); fill("vfs_server", "new.invalid"); fill("vfs_account", "synthetic")
        fill("vfs_password", "synthetic-secret"); capture("vfs-ftp-form")
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("vfs_password").performScrollTo().assertTextEquals(text(R.string.password), "")
        fill("vfs_password", "synthetic-secret")
        compose.onNodeWithTag("vfs_advanced").performScrollTo().performClick()
        compose.onNodeWithTag("vfs_one_connection").performScrollTo().performClick()
        compose.onNodeWithTag("vfs_save").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.vfs_cleartext_impact)).assertExists(); capture("vfs-cleartext-confirm")
        assertTrue(writes().isEmpty()); compose.onNodeWithTag("vfs_accept_cleartext").performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        assertEquals(2, writes().size); assertEquals("1", writes().first()["max_connection"])
        assertEquals("false", writes().first()["force"]); assertEquals("synthetic-secret", writes().first()["password"])
        assertFalse(writes().last().containsKey("force")); capture("vfs-created")
    }
    @Test fun webdavEditPreservesPasswordUnlessExplicitlyReplaced() {
        connections = listOf(original); openManager(); compose.onNodeWithTag("vfs_edit").performClick(); detailReady()
        compose.onNodeWithTag("vfs_password").assertDoesNotExist()
        compose.onNodeWithTag("vfs_folder").performScrollTo().assertTextEquals(text(R.string.vfs_folder), "Shared Files")
        fill("vfs_alias", "Renamed server"); fill("vfs_folder", "New folder"); capture("vfs-webdav-edit")
        compose.onNodeWithTag("vfs_save").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        assertTrue(writes().all { "password" !in it }); assertEquals("New folder", writes().last()["uri_path"])
        compose.onNodeWithTag("vfs_back").performScrollTo().performClick(); ready(); compose.onNodeWithTag("vfs_edit").performClick(); detailReady()
        compose.onNodeWithTag("vfs_replace_password").performScrollTo().performClick()
        compose.onNodeWithTag("vfs_password").performScrollTo().assertTextEquals(text(R.string.password), "")
        compose.onNodeWithTag("vfs_save").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        assertEquals("", writes().last()["password"]); assertEquals(4, writes().size)
    }
    @Test fun disconnectReconnectAndRemoveSavedRequireDistinctConfirmation() {
        connections = listOf(original); openManager(); capture("vfs-connections")
        compose.onNodeWithTag("vfs_disconnect").performClick()
        compose.onNodeWithText(text(R.string.vfs_disconnect_impact)).assertExists(); capture("vfs-disconnect")
        assertTrue(writes().isEmpty()); compose.onNodeWithTag("vfs_confirm_action").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        compose.onNodeWithTag("vfs_back").performScrollTo().performClick(); ready(); compose.onNodeWithTag("vfs_connect").performClick()
        compose.onNodeWithTag("vfs_confirm_action").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        assertEquals(original.id, writes().last()["profile_id"])
        compose.onNodeWithTag("vfs_back").performScrollTo().performClick(); ready(); compose.onNodeWithTag("vfs_disconnect").performClick()
        compose.onNodeWithTag("vfs_confirm_action").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        compose.onNodeWithTag("vfs_back").performScrollTo().performClick(); ready(); compose.onNodeWithTag("vfs_remove").performClick()
        compose.onNodeWithText(text(R.string.vfs_remove_impact)).assertExists(); capture("vfs-remove")
        compose.onNodeWithTag("vfs_confirm_action").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.COMPLETED)
        assertEquals(4, writes().size); assertEquals(VFS_PROFILE_API, writes().last()["api"]); assertTrue(connections.isEmpty())
        assertTrue(calls.none { it["api"] == "SYNO.FileStation.Delete" })
    }
    @Test fun unknownSavedStepSurvivesReopenAndOnlyRefreshesStatus() {
        loseSecondResponse = true; openManager(); compose.onNodeWithTag("vfs_add_server").performClick()
        compose.onNodeWithTag("vfs_protocol_davs").performScrollTo().performClick()
        fill("vfs_alias", "New WebDAV"); fill("vfs_server", "new.invalid")
        compose.onNodeWithTag("vfs_save").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.UNKNOWN)
        capture("vfs-pending-form"); compose.onNodeWithContentDescription(text(R.string.close)).performClick()
        compose.activityRule.scenario.recreate(); openManager(); capture("vfs-pending-list")
        compose.onNodeWithTag("vfs_add_server").assertIsNotEnabled()
        compose.onNodeWithTag("vfs_open_recovery").performClick(); compose.onNodeWithTag("vfs_review").performScrollTo().performClick(); outcome(FileVFSOutcomeStatus.UNKNOWN)
        assertEquals(2, writes().size); assertEquals(1, model.fileVFS.state.value.pending.size)
    }
    @Test fun managerLoadingErrorEmptyAndFilterEmptyHaveRecovery() {
        inventoryGate = CountDownLatch(1); openManager(false)
        compose.waitUntil(10_000) { model.fileVFS.state.value.inventory is Loadable.Loading }; capture("vfs-loading")
        inventoryFailure = true; inventoryGate?.countDown(); inventoryGate = null
        compose.waitUntil(10_000) { model.fileVFS.state.value.inventory is Loadable.Failed }; capture("vfs-error")
        inventoryFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); ready()
        compose.onNodeWithText(text(R.string.vfs_empty)).assertIsDisplayed(); capture("vfs-empty")
        connections = listOf(original); compose.onNodeWithTag("vfs_refresh").performClick(); ready()
        compose.onNodeWithTag("vfs_filter").performTextInput("no-match"); compose.onNodeWithTag("vfs_filter").performImeAction()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("vfs-filter-empty")
        compose.onNodeWithTag("vfs_filter").performTextClearance(); compose.onNodeWithTag("vfs_filter").performImeAction()
        compose.onNodeWithTag("vfs_browse").assertIsDisplayed(); assertTrue(writes().isEmpty())
    }
    @Test fun browserLoadingErrorEmptyPaginationAndFolderNavigationUseOriginalUri() {
        connections = listOf(original); openManager(); folderGate = CountDownLatch(1); compose.onNodeWithTag("vfs_browse").performClick()
        compose.waitUntil(10_000) { model.fileVFS.state.value.files is Loadable.Loading }; capture("vfs-browser-loading")
        folderFailure = true; folderGate?.countDown(); folderGate = null
        compose.waitUntil(10_000) { model.fileVFS.state.value.files is Loadable.Failed }; capture("vfs-browser-error")
        folderFailure = false; emptyFolder = true; compose.onNodeWithText(text(R.string.retry)).performClick(); folderReady()
        compose.onNodeWithText(text(R.string.vfs_files_empty)).assertIsDisplayed(); capture("vfs-browser-empty")
        emptyFolder = false; compose.onNodeWithTag("vfs_folder_refresh").performClick(); folderReady()
        compose.onNodeWithTag("vfs_more").performClick()
        compose.waitUntil(10_000) { !model.fileVFS.state.value.loadingMore && (model.fileVFS.state.value.files as? Loadable.Ready)?.value?.items?.size == 2 }
        capture("vfs-browser-files")
        compose.onNodeWithTag("vfs_files_filter").performTextInput("no-match"); compose.onNodeWithTag("vfs_files_filter").performImeAction()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("vfs-browser-filter-empty")
        compose.onNodeWithTag("vfs_files_filter").performTextClearance(); compose.onNodeWithTag("vfs_files_filter").performImeAction()
        compose.onNodeWithText("A folder").performClick(); folderReady(); capture("vfs-browser-child")
        assertEquals(original.uri + "/A folder", model.fileVFS.state.value.locations.last().path)
        compose.onNodeWithTag("vfs_location_0").performClick(); folderReady(); assertEquals(original.uri, model.fileVFS.state.value.locations.single().path)
        assertTrue(calls.filter { it["api"] == "SYNO.FileStation.List" && it["folder_path"]?.contains("://") == true }.all { it["folder_path"]!!.startsWith(original.uri) })
        assertTrue(writes().isEmpty())
    }
    @Test fun nativeSaveDownloadsOriginalRemoteFileAndShowsCompletedTask() {
        connections = listOf(original); openManager(); compose.onNodeWithTag("vfs_browse").performClick(); folderReady()
        compose.onNodeWithTag("vfs_more").performClick()
        compose.waitUntil(10_000) { !model.fileVFS.state.value.loadingMore && (model.fileVFS.state.value.files as? Loadable.Ready)?.value?.items?.size == 2 }
        compose.onNodeWithTag("vfs_download").performClick()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun saveButton(node: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
            node ?: return null
            if (node.isClickable && node.isEnabled && node.text?.toString() in setOf("Save", "SAVE", "保存")) return node
            for (index in 0 until node.childCount) saveButton(node.getChild(index))?.let { return it }
            return null
        }
        compose.waitUntil(10_000) { saveButton(automation.rootInActiveWindow) != null }
        assertTrue(checkNotNull(saveButton(automation.rootInActiveWindow)).performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
        val transfers = TransferStore(app)
        compose.waitUntil(15_000) { transfers.downloads(nas.id).singleOrNull()?.state == TransferState.SUCCEEDED }
        val record = transfers.downloads(nas.id).single()
        assertTrue(record.isVFSDownload); assertEquals(original, transfers.vfsDownloadPlan(record)?.source?.profile)
        assertEquals(original.uri + "/file.txt ", record.sourcePath); assertEquals(8L, record.completedBytes)
        app.contentResolver.openInputStream(android.net.Uri.parse(record.destinationUri))!!.use { assertArrayEquals("original".toByteArray(), it.readBytes()) }
        assertEquals(JsonArray(listOf(JsonPrimitive(record.sourcePath))).toString(), calls.single { it["method"] == "download" }["path"])
        compose.runOnIdle { model.fileVFS.close(); model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.onNodeWithText(text(R.string.client_finished_tasks)).performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText(record.title).fetchSemanticsNodes().isNotEmpty() }
        capture("vfs-download-completed")
    }
    @Test fun remoteDownloadOpensSystemSavePickerAndCancellationDoesNotCreateTask() {
        connections = listOf(original); openManager(); compose.onNodeWithTag("vfs_browse").performClick(); folderReady()
        compose.onNodeWithTag("vfs_more").performClick()
        compose.waitUntil(10_000) { !model.fileVFS.state.value.loadingMore && (model.fileVFS.state.value.files as? Loadable.Ready)?.value?.items?.size == 2 }
        compose.onNodeWithTag("vfs_download").performClick()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        compose.waitUntil(10_000) { automation.rootInActiveWindow?.packageName?.toString()?.endsWith(".documentsui") == true }
        capture("vfs-system-save-picker")
        repeat(3) {
            if (automation.rootInActiveWindow?.packageName?.toString() != app.packageName) {
                automation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
                automation.waitForIdle(200, 5_000)
            }
        }
        compose.waitUntil(10_000) { automation.rootInActiveWindow?.packageName?.toString() == app.packageName }
        compose.onNodeWithTag("vfs_browser").assertIsDisplayed()
        assertTrue(TransferStore(app).downloads(nas.id).isEmpty()); assertTrue(writes().isEmpty())
    }
    @Test fun cloudChoicesComeFromNasAndSelectingOneDoesNotLaunchOrSave() {
        openManager(); compose.onNodeWithTag("vfs_add_cloud").performClick(); compose.onNodeWithText("Google Drive").performClick()
        compose.onNodeWithTag("vfs_authorize").assertExists(); compose.onNodeWithText(text(R.string.vfs_sign_in_hint)).assertExists(); capture("vfs-cloud-sign-in")
        compose.activityRule.scenario.recreate(); compose.onNodeWithTag("vfs_authorize").assertExists()
        assertTrue(calls.none { it["api"] == "SYNO.Core.System" }); assertTrue(writes().isEmpty())
    }
    @Test fun unavailableBrowserClosesSignInAndShowsRecoveryWithoutOpeningExternalPage() {
        openManager(); compose.onNodeWithTag("vfs_add_cloud").performClick(); compose.onNodeWithText("Google Drive").performClick()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var attempts = 0
        val monitor = object : android.app.Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: android.content.Intent): android.app.Instrumentation.ActivityResult? {
                if (intent.action == android.content.Intent.ACTION_VIEW) {
                    assertEquals("synooauth.synology.com", intent.data?.host); attempts++
                    throw android.content.ActivityNotFoundException("Synthetic unavailable browser")
                }
                return null
            }
        }
        instrumentation.addMonitor(monitor)
        try {
            compose.onNodeWithTag("vfs_authorize").performScrollTo().performClick()
            compose.waitUntil(10_000) { model.fileVFS.state.value.failure?.kind == DsmErrorKind.FILE_VFS_AUTHORIZATION_FAILED }
            assertEquals(1, attempts); assertNull(model.fileVFS.state.value.browserUrl); assertFalse(model.fileVFS.state.value.cloudWaiting)
            compose.onNodeWithText(text(R.string.file_vfs_authorization_failed_hint), substring = true).performScrollTo().assertIsDisplayed()
            capture("vfs-browser-unavailable")
            compose.onNodeWithTag("vfs_authorize").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(10_000) { attempts == 2 && model.fileVFS.state.value.failure?.kind == DsmErrorKind.FILE_VFS_AUTHORIZATION_FAILED }
            assertTrue(writes().isEmpty())
        } finally { instrumentation.removeMonitor(monitor) }
    }
    @Test fun revokedAuthorizationClosesEditorAndCleartextPromptBeforeWrite() {
        openManager(); compose.onNodeWithTag("vfs_add_server").performClick(); fill("vfs_alias", "FTP"); fill("vfs_server", "synthetic.invalid")
        fill("vfs_password", "synthetic-secret"); compose.onNodeWithTag("vfs_save").performScrollTo().performClick()
        compose.onNodeWithTag("vfs_accept_cleartext").assertExists(); allowed = false
        compose.runOnIdle { model.refreshWorkspaceAccess() }
        compose.waitUntil(10_000) { model.fileVFS.state.value.screen == null }
        compose.onNodeWithTag("vfs_accept_cleartext").assertDoesNotExist(); assertTrue(writes().isEmpty())
    }

    private fun openManager(wait: Boolean = true) {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.vfs_title)).performScrollTo().performClick(); if (wait) ready()
    }
    private fun ready() = compose.waitUntil(10_000) { model.fileVFS.state.value.inventory is Loadable.Ready && model.fileVFS.state.value.recoveryReadable }
    private fun detailReady() = compose.waitUntil(10_000) { model.fileVFS.state.value.detail is Loadable.Ready }
    private fun folderReady() = compose.waitUntil(10_000) { model.fileVFS.state.value.files is Loadable.Ready }
    private fun outcome(value: FileVFSOutcomeStatus) = compose.waitUntil(10_000) { !model.fileVFS.state.value.busy && model.fileVFS.state.value.outcome?.status == value }
    private fun fill(tag: String, value: String) { compose.onNodeWithTag(tag).performScrollTo().performTextReplacement(value); compose.onNodeWithTag(tag).performImeAction() }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["api"] in setOf(VFS_PROFILE_API, VFS_CONNECTION_API) && it["method"] in setOf("create", "set", "delete") }.toList() }
    private fun response(fields: Map<String, String>): JsonObject {
        val api = fields.getValue("api"); val method = fields.getValue("method")
        if (api in setOf(VFS_CONNECTION_API, VFS_PROFILE_API) && method in setOf("create", "set", "delete")) {
            if (api == VFS_PROFILE_API && loseSecondResponse) throw IOException("synthetic lost profile response")
            if (method == "delete") connections = if (api == VFS_PROFILE_API) connections.filterNot { it.id == fields["id"] }
                else connections.map { if (it.id == fields["id"]) it.copy(state = FileVFSConnectionState.DISCONNECTED) else it }
            else if ("profile_id" in fields) connections = connections.map { it.copy(state = FileVFSConnectionState.CONNECTED) }
            else {
                setup = setup.copy(protocolId = fields["protocol"] ?: setup.protocolId, hostname = fields["hostname"] ?: setup.hostname,
                    port = fields["port"]?.toInt() ?: setup.port, alias = fields["alias"] ?: setup.alias, account = fields["account"] ?: setup.account,
                    codepage = fields["codepage"] ?: setup.codepage, folder = fields["uri_path"] ?: setup.folder,
                    usesOneConnection = fields["max_connection"]?.let { it == "1" } ?: setup.usesOneConnection)
                val existing = connections.singleOrNull { it.id == fields["id"] }
                connections = listOf((existing ?: original.copy(id = "new-id", uri = setup.protocolId + "://opaque-new/root")).copy(protocolId = setup.protocolId,
                    hostname = setup.hostname, port = setup.port, alias = setup.alias, account = setup.account, codepage = setup.codepage, state = FileVFSConnectionState.CONNECTED))
            }
            return buildJsonObject {}
        }
        return when (api) {
            VFS_PROFILE_API -> if (method == "get") buildJsonObject {
                put("hostname", setup.hostname); put("port", setup.port); put("alias", setup.alias); put("account", setup.account); put("codepage", setup.codepage)
                put("uri_path", setup.folder); put("max_connection", if (setup.usesOneConnection) 1 else 0)
            } else {
                inventoryGate?.await(10, TimeUnit.SECONDS); if (inventoryFailure) throw IOException("synthetic inventory failure")
                buildJsonObject { put("total", connections.size); putJsonArray("profiles") { connections.forEach { row -> add(buildJsonObject {
                    put("id", row.id); put("protocol", row.protocolId); put("protocol_name", row.protocolName); put("uri", row.uri)
                    put("hostname", row.hostname); put("port", row.port); put("alias", row.alias); put("account", row.account); put("codepage", row.codepage)
                    put("connect_status", if (row.state == FileVFSConnectionState.CONNECTED) 1 else 0)
                }) } } }
            }
            VFS_PROTOCOL_API -> buildJsonObject { putJsonArray("protocols") {
                listOf(Triple("ftp", "FTP", 21), Triple("sftp", "SFTP", 22), Triple("dav", "WebDAV (HTTP)", 80), Triple("davs", "WebDAV (HTTPS)", 443), Triple("google", "Google Drive", null)).forEach { (id, name, port) ->
                    add(buildJsonObject { put("protocol", id); put("name", name); port?.let { put("default_port", it) }; put("has_server", false) })
                }
            } }
            "SYNO.Core.System" -> buildJsonObject { put("firmware_ver", "7.2.2") }
            "SYNO.FileStation.List" -> {
                val path = fields["folder_path"].orEmpty(); val offset = fields["offset"]?.toInt() ?: 0
                if (path.contains("://")) { folderGate?.await(10, TimeUnit.SECONDS); if (folderFailure) throw IOException("synthetic folder failure") }
                val rows = if (!path.contains("://") || emptyFolder || path.endsWith("/A folder")) emptyList()
                    else if (offset == 0) listOf(FileItem(path + "/A folder", "A folder", true)) else listOf(FileItem(path + "/file.txt ", "file.txt ", false, 8, 10))
                buildJsonObject { put("offset", offset); put("total", if (rows.isEmpty()) 0 else 2); putJsonArray(if (method == "list_share") "shares" else "files") {
                    rows.forEach { item -> add(buildJsonObject { put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
                        putJsonObject("additional") { putJsonObject("time") { put("mtime", item.modifiedAtEpochSeconds ?: 10) }
                            putJsonObject("perm") { putJsonObject("acl") { put("read", true) } } }
                    }) }
                } }
            }
            else -> error("Unexpected synthetic API")
        }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle(); val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.waitForIdle(150, 5_000)
        val drawn = CountDownLatch(1)
        instrumentation.runOnMainSync { val frames = android.view.Choreographer.getInstance(); frames.postFrameCallback { frames.postFrameCallback { drawn.countDown() } } }
        assertTrue(drawn.await(5, TimeUnit.SECONDS))
        val bitmap = instrumentation.uiAutomation.takeScreenshot(); val file = File(app.getExternalFilesDir(null), "file-vfs-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
