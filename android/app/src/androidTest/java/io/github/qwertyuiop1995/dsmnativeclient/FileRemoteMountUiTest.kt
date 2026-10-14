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

/** 真正的文件菜单、表单、恢复页面及网络仓储；仅网络与资料使用合成夹具。 */
class FileRemoteMountUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val remoteRecovery = FileRemoteMountRecoveryStore(app)
    private val isoRecovery = FileISOMountRecoveryStore(app)
    private val permissions = FilePermissionRecoveryStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("remote-ui-" + UUID.randomUUID(), "Remote NAS", "https://synthetic.example.invalid", "synthetic")
    private val root = FileItem("/synthetic", "Synthetic", true, canRead = true, canWrite = true, mountPointType = "shared_folder")
    private val empty = FileItem("/synthetic/Empty", "Empty", true, modifiedAtEpochSeconds = 10, canRead = true, canWrite = true, mountPointType = "")
    private val oldFolder = empty.copy(path = "/synthetic/Previous", name = "Previous")
    private val readOnly = empty.copy(path = "/synthetic/ReadOnly", name = "ReadOnly", canWrite = false)
    private val old = FileMountConnection(FileMountKind.CIFS, "//previous.invalid/share", oldFolder.path, false)
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    @Volatile private var connections = emptyList<FileMountConnection>()
    @Volatile private var administrator = true
    @Volatile private var allowed = true
    @Volatile private var inventoryFailure = false
    @Volatile private var directoryFailure = false
    @Volatile private var nonempty = false
    @Volatile private var unknownMount = false
    @Volatile private var inventoryGate: CountDownLatch? = null
    @Volatile private var directoryGate: CountDownLatch? = null
    private lateinit var model: AppViewModel
    private lateinit var repo: DsmRepository
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }; calls += fields
                val data = response(fields)
                assertNull(request.url.query)
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
            }.build())
            val caps = listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
                ApiCapability(MOUNT_API, "entry.cgi", 1, 1), ApiCapability(MOUNT_LIST_API, "entry.cgi", 1, 1)).associateBy(ApiCapability::name)
            val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed,
                DesktopApplication.NAS_SETTINGS to false), administrator) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(profile, session, api, caps, access); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            repo.fileMounts.bindRecovery(isoRecovery); repo.fileMounts.remote.bindRecovery(remoteRecovery); repo.filePermissions.bindRecovery(permissions)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = root.path), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        awaitText(empty.name)
    }
    @After fun clean() {
        inventoryGate?.countDown(); directoryGate?.countDown()
        compose.waitUntil(10_000) { !model.fileRemoteMounts.state.value.busy }
        compose.runOnIdle {
            model.fileRemoteMounts.invalidate(); remoteRecovery.removeProfile(profile.id)
            isoRecovery.removeProfile(profile.id); permissions.removeProfile(profile.id)
            profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
        }
    }

    @Test fun cifsFormRecreationClearsPasswordAndAutomaticConnectionRequiresConfirmation() {
        openManager(); compose.onNodeWithTag("remote_add").performClick()
        fill("remote_server", "server.invalid"); fill("remote_shared_folder", "share/folder")
        fill("remote_username", "synthetic-user"); fill("remote_password", "synthetic-secret"); fill("remote_domain", "synthetic-domain")
        chooseEmpty(); capture("remote-cifs-editor")
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("remote_password").performScrollTo().assertTextEquals(text(R.string.password), "")
        assertEquals(empty.path, model.fileRemoteMounts.state.value.setup.mountPoint)
        fill("remote_password", "synthetic-secret")
        compose.onNodeWithTag("remote_automatic").performScrollTo().performClick()
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.remote_mount_automatic_impact)).assertIsDisplayed(); capture("remote-automatic-confirm")
        assertTrue(writes().isEmpty()); compose.onNodeWithTag("remote_confirm").performClick()
        awaitOutcome(RemoteMountOutcomeStatus.COMPLETED)
        assertEquals(1, writes().size); val sent = writes().single()
        assertEquals("CIFS", sent["mount_type"]); assertEquals("//server.invalid/share/folder", sent["server_ip"])
        assertEquals("synthetic-domain\\synthetic-user", sent["account"]); assertEquals("synthetic-secret", sent["passwd"])
        assertEquals("true", sent["auto_mount"])
        compose.onNodeWithTag("remote_back_to_list").performScrollTo().performClick(); awaitReady(); capture("remote-list")
        compose.onNodeWithTag("remote_browse").performClick()
        compose.waitUntil(10_000) { model.workspace.value?.fileBrowser?.path == empty.path }
        assertEquals(1, writes().size)
    }
    @Test fun nfsProtocolClearsCredentialsAndVersionFourDisablesUdp() {
        openManager(); compose.onNodeWithTag("remote_add").performClick()
        fill("remote_server", "server.invalid"); fill("remote_shared_folder", "share/folder")
        fill("remote_username", "synthetic-user"); fill("remote_password", "synthetic-secret")
        compose.onNodeWithTag("remote_protocol_NFS").performScrollTo().performClick()
        compose.onNodeWithTag("remote_password").assertDoesNotExist()
        compose.onNodeWithTag("remote_transport_udp").performScrollTo().performClick()
        compose.onNodeWithTag("remote_nfs_4").performScrollTo().performClick()
        compose.onNodeWithTag("remote_transport_udp").assertIsNotEnabled()
        assertEquals("tcp", model.fileRemoteMounts.state.value.setup.nfsTransport)
        chooseEmpty(); capture("remote-nfs-editor")
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.COMPLETED)
        val sent = writes().single(); assertEquals("NFS", sent["mount_type"]); assertEquals("4", sent["nfs_version"])
        assertFalse("passwd" in sent); assertFalse("account" in sent)
        compose.onNodeWithTag("remote_back_to_list").performScrollTo().performClick(); awaitReady()
        compose.onNodeWithTag("remote_disconnect").performClick(); capture("remote-disconnect")
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.COMPLETED)
        assertEquals("unmount", writes().last()["method"]); assertTrue(connections.isEmpty())
        assertFalse(calls.any { it["api"]?.contains("Delete") == true })
    }
    @Test fun movingConnectionRequiresSecondActionBeforeDisconnectingOriginal() {
        connections = listOf(old); openManager(); compose.onNodeWithTag("remote_edit").performClick()
        fill("remote_server", "server.invalid"); chooseEmpty()
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.remote_mount_change_move_impact)).assertExists(); capture("remote-move-confirm")
        compose.onNodeWithTag("remote_confirm").performClick(); awaitOutcome(RemoteMountOutcomeStatus.READY)
        assertEquals(1, writes().size); assertEquals(2, connections.size)
        compose.onNodeWithText(text(R.string.remote_mount_ready_disconnect)).assertExists(); capture("remote-ready-disconnect")
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("remote_continue").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.COMPLETED)
        assertEquals(2, writes().size); assertEquals(empty.path, connections.single().mountPoint)
        assertEquals(JsonArray(listOf(JsonPrimitive(oldFolder.path))).toString(), writes().last()["mount_point"])
    }
    @Test fun sameLocationChangeDisconnectsThenAsksForPasswordAgain() {
        connections = listOf(old); openManager(); compose.onNodeWithTag("remote_edit").performClick()
        fill("remote_server", "server.invalid"); fill("remote_password", "first-synthetic-secret")
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.remote_mount_change_same_impact)).assertExists()
        compose.onNodeWithTag("remote_confirm").performClick(); awaitOutcome(RemoteMountOutcomeStatus.READY)
        assertEquals("unmount", writes().single()["method"]); assertTrue(connections.isEmpty())
        compose.onNodeWithTag("remote_password").performScrollTo().assertTextEquals(text(R.string.password), "")
        capture("remote-ready-connect"); fill("remote_password", "second-synthetic-secret")
        compose.onNodeWithTag("remote_continue").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.COMPLETED)
        assertEquals("second-synthetic-secret", writes().last()["passwd"]); assertEquals(oldFolder.path, connections.single().mountPoint)
    }
    @Test fun unknownConnectionSurvivesCloseAndRefreshOnlyReads() {
        unknownMount = true; openManager(); compose.onNodeWithTag("remote_add").performClick()
        fill("remote_server", "server.invalid"); fill("remote_shared_folder", "share"); chooseEmpty()
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.UNKNOWN)
        capture("remote-pending-editor")
        compose.onNodeWithContentDescription(text(R.string.close)).performClick(); compose.activityRule.scenario.recreate()
        openManager(); assertEquals(1, model.fileRemoteMounts.state.value.pending.size); capture("remote-pending-list")
        compose.onNodeWithTag("remote_open_recovery").performClick()
        compose.onNodeWithTag("remote_review").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.UNKNOWN)
        assertEquals(1, writes().size)
        connections = listOf(FileMountConnection(FileMountKind.CIFS, "//server.invalid/share", empty.path, false))
        compose.onNodeWithTag("remote_review").performScrollTo().performClick(); awaitOutcome(RemoteMountOutcomeStatus.COMPLETED)
        assertEquals(1, writes().size); assertTrue(model.fileRemoteMounts.state.value.pending.isEmpty())
    }
    @Test fun endingRemainingMoveKeepsBothConnectionsAfterExplicitConfirmation() {
        connections = listOf(old); openManager(); compose.onNodeWithTag("remote_edit").performClick(); chooseEmpty()
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick(); compose.onNodeWithTag("remote_confirm").performClick()
        awaitOutcome(RemoteMountOutcomeStatus.READY)
        compose.onNodeWithTag("remote_end_remaining").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.remote_mount_end_both_impact)).assertExists(); capture("remote-end-confirm")
        compose.onNodeWithTag("remote_confirm").performClick(); awaitOutcome(RemoteMountOutcomeStatus.ENDED)
        assertEquals(2, connections.size); assertEquals(1, writes().size); assertTrue(model.fileRemoteMounts.state.value.pending.isEmpty())
    }
    @Test fun managerLoadingErrorEmptyAndFilteredStatesRemainUsable() {
        inventoryGate = CountDownLatch(1); openManager(wait = false)
        compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.inventory is Loadable.Loading }; capture("remote-loading")
        inventoryFailure = true; inventoryGate?.countDown(); inventoryGate = null
        compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.inventory is Loadable.Failed }; capture("remote-error")
        inventoryFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); awaitReady()
        compose.onNodeWithText(text(R.string.remote_mount_empty)).assertIsDisplayed(); capture("remote-empty")
        connections = listOf(old); compose.onNodeWithTag("remote_refresh").performClick(); awaitReady()
        compose.onNodeWithTag("remote_filter").performTextInput("no-match"); compose.onNodeWithTag("remote_filter").performImeAction()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("remote-filter-empty")
        compose.onNodeWithTag("remote_filter").performTextClearance(); compose.onNodeWithTag("remote_filter").performImeAction()
        compose.onNodeWithTag("remote_browse").assertIsDisplayed(); assertTrue(writes().isEmpty())
    }
    @Test fun folderPickerLoadingErrorFilterAndReadOnlyNeverChooseUnavailableFolder() {
        openManager(); compose.onNodeWithTag("remote_add").performClick(); directoryGate = CountDownLatch(1)
        compose.onNodeWithText(text(R.string.remote_mount_destination)).performScrollTo().performClick()
        compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.locations.items is Loadable.Loading }; capture("remote-folders-loading")
        directoryFailure = true; directoryGate?.countDown(); directoryGate = null
        compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.locations.items is Loadable.Failed }; capture("remote-folders-error")
        directoryFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); awaitLocation("")
        compose.onNodeWithTag("remote_location_Synthetic").performClick(); awaitLocation(root.path)
        compose.onNodeWithTag("remote_location_filter").performTextInput("no-match"); compose.onNodeWithTag("remote_location_filter").performImeAction()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("remote-folders-filter-empty")
        compose.onNodeWithTag("remote_location_filter").performTextClearance(); compose.onNodeWithTag("remote_location_filter").performImeAction()
        compose.onNodeWithTag("remote_location_ReadOnly").performClick(); awaitLocation(readOnly.path)
        awaitText(text(R.string.archive_choose_writable_destination))
        compose.onNodeWithText(text(R.string.file_search_no_folders)).assertIsDisplayed()
        compose.onNodeWithTag("remote_choose_location").assertIsNotEnabled(); capture("remote-folder-readonly")
        assertNull(model.fileRemoteMounts.state.value.destination); assertTrue(writes().isEmpty())
    }
    @Test fun nonemptyFolderReportsRecoveryAndNeverConnects() {
        openManager(); compose.onNodeWithTag("remote_add").performClick()
        fill("remote_server", "server.invalid"); fill("remote_shared_folder", "share"); chooseEmpty(); nonempty = true
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick()
        compose.waitUntil(10_000) { !model.fileRemoteMounts.state.value.busy && model.fileRemoteMounts.state.value.failure != null }
        assertEquals(DsmErrorKind.FILE_MOUNT_EMPTY_REQUIRED, model.fileRemoteMounts.state.value.failure?.kind)
        capture("remote-nonempty"); assertTrue(writes().isEmpty())
    }
    @Test fun revokedGrantClosesConfirmationAndCannotSubmitStaleCredentials() {
        openManager(); compose.onNodeWithTag("remote_add").performClick()
        fill("remote_server", "server.invalid"); fill("remote_shared_folder", "share"); fill("remote_password", "synthetic-secret"); chooseEmpty()
        compose.onNodeWithTag("remote_automatic").performScrollTo().performClick()
        compose.onNodeWithTag("remote_submit").performScrollTo().performClick(); allowed = false
        compose.runOnIdle { model.refreshWorkspaceAccess() }
        compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.screen == null }
        compose.onNodeWithTag("remote_confirm").assertDoesNotExist(); assertTrue(writes().isEmpty())
    }

    private fun openManager(wait: Boolean = true) {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.remote_mount_title)).performScrollTo().performClick()
        if (wait) awaitReady()
    }
    private fun chooseEmpty() {
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(150, 5_000)
        compose.onNodeWithText(text(R.string.remote_mount_destination)).performScrollTo().assertIsDisplayed().performClick()
        try { awaitLocation("") } catch (error: Throwable) { runCatching { capture("remote-folder-open-failure") }; throw error }
        compose.onNodeWithTag("remote_location_Synthetic").performClick(); awaitLocation(root.path)
        compose.onNodeWithTag("remote_location_Empty").performClick(); awaitLocation(empty.path)
        compose.onNodeWithTag("remote_choose_location").assertIsEnabled().performClick()
        compose.waitUntil(10_000) { !model.fileRemoteMounts.state.value.locationsVisible }
    }
    private fun fill(tag: String, value: String) {
        compose.onNodeWithTag(tag).performScrollTo().performTextReplacement(value)
        compose.onNodeWithTag(tag).performImeAction()
    }
    private fun awaitReady() = compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.inventory is Loadable.Ready && model.fileRemoteMounts.state.value.recoveryReadable }
    private fun awaitLocation(path: String) = compose.waitUntil(10_000) { model.fileRemoteMounts.state.value.locations.path == path && model.fileRemoteMounts.state.value.locations.items is Loadable.Ready }
    private fun awaitOutcome(status: RemoteMountOutcomeStatus) = compose.waitUntil(10_000) { !model.fileRemoteMounts.state.value.busy && model.fileRemoteMounts.state.value.outcome?.status == status }
    private fun awaitText(value: String) = compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] in setOf("mount_remote", "unmount") }.toList() }
    private fun response(fields: Map<String, String>): JsonObject = when (fields["api"]) {
        MOUNT_LIST_API -> if (fields["method"] == "get") {
            inventoryGate?.await(10, TimeUnit.SECONDS)
            if (inventoryFailure) throw IOException("synthetic inventory failure")
            buildJsonObject { putJsonObject("mountConfig") { put("enable_iso_mount", true); put("enable_remote_mount", true) }
                putJsonArray("isoList") {}; putJsonArray("remoteList") { connections.forEach { connection -> add(buildJsonObject {
                    put("type", connection.kind.name); put("source", connection.source); put("mount_point", connection.mountPoint); put("auto_mount", connection.automatic)
                }) } } }
        } else {
            check(fields["method"] == "unmount")
            val point = Json.parseToJsonElement(fields.getValue("mount_point")).jsonArray.single().jsonPrimitive.content
            connections = connections.filterNot { it.mountPoint == point }; buildJsonObject {}
        }
        MOUNT_API -> {
            check(fields["method"] == "mount_remote"); if (unknownMount) throw IOException("synthetic lost connection")
            connections += FileMountConnection(FileMountKind.valueOf(fields.getValue("mount_type")), fields.getValue("server_ip"), fields.getValue("mount_point"), fields["auto_mount"] == "true")
            buildJsonObject {}
        }
        "SYNO.FileStation.List" -> when (fields["method"]) {
            "getinfo" -> buildJsonObject { putJsonArray("files") { Json.parseToJsonElement(fields.getValue("path")).jsonArray.forEach { value ->
                add(file(listOf(root, empty, oldFolder, readOnly).single { it.path == value.jsonPrimitive.content }))
            } } }
            "list_share", "list" -> {
                if (fields["method"] == "list_share" || fields["filetype"] == "dir") {
                    directoryGate?.await(10, TimeUnit.SECONDS); if (directoryFailure) throw IOException("synthetic folder failure")
                }
                val rows = when {
                    fields["method"] == "list_share" -> listOf(root)
                    fields["folder_path"] == root.path -> listOf(empty, oldFolder, readOnly)
                    else -> emptyList()
                }
                buildJsonObject { put("offset", 0); put("total", if (fields["limit"] == "1" && nonempty) 1 else rows.size)
                    putJsonArray(if (fields["method"] == "list_share") "shares" else "files") { rows.forEach { add(file(it)) } } }
            }
            else -> error("Unexpected synthetic file method")
        }
        else -> error("Unexpected synthetic API")
    }
    private fun file(item: FileItem) = buildJsonObject {
        put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
        putJsonObject("additional") {
            put("mount_point_type", if (connections.any { it.mountPoint == item.path }) "remote" else item.mountPointType)
            putJsonObject("time") { put("mtime", item.modifiedAtEpochSeconds ?: 10) }
            putJsonObject("perm") { putJsonObject("acl") { put("read", item.canRead); put("write", item.canWrite); put("del", false) } }
        }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.waitForIdle(150, 5_000)
        // Compose 状态空闲后仍需等待窗口实际绘制，避免截到前一个表单。
        val drawn = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val frames = android.view.Choreographer.getInstance()
            frames.postFrameCallback { frames.postFrameCallback { drawn.countDown() } }
        }
        assertTrue("Window did not draw before screenshot", drawn.await(5, TimeUnit.SECONDS))
        val bitmap = automation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "file-remote-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
