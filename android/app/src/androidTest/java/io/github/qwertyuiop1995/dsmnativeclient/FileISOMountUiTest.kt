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

/** 真实 MainActivity/菜单/目录选择与 Repository；仅账号及网络使用合成测试资料。 */
class FileISOMountUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val recovery = FileISOMountRecoveryStore(app)
    private val remoteRecovery = FileRemoteMountRecoveryStore(app)
    private val permissions = FilePermissionRecoveryStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("iso-ui-" + UUID.randomUUID(), "ISO NAS", "https://synthetic.example.invalid", "synthetic")
    private val root = FileItem("/synthetic", "Synthetic", true, canRead = true, canWrite = true, mountPointType = "shared_folder")
    private val source = FileItem("/synthetic/disc.iso", "disc.iso", false, 24, 10, canRead = true, canWrite = true, mountPointType = "normal")
    private val empty = FileItem("/synthetic/Empty", "Empty", true, modifiedAtEpochSeconds = 10, canRead = true, canWrite = true, mountPointType = "normal")
    private val readOnly = empty.copy(path = "/synthetic/ReadOnly", name = "ReadOnly", canWrite = false)
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    @Volatile private var mounted = false
    @Volatile private var automatic = false
    @Volatile private var administrator = true
    @Volatile private var inventoryFailure = false
    @Volatile private var directoryFailure = false
    @Volatile private var nonempty = false
    @Volatile private var unknownMount = false
    @Volatile private var ordinaryMountType = "normal"
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
            val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true,
                DesktopApplication.NAS_SETTINGS to false), administrator) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(profile, session, api, caps, access); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            repo.fileMounts.bindRecovery(recovery); repo.fileMounts.remote.bindRecovery(remoteRecovery); repo.filePermissions.bindRecovery(permissions)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = root.path), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        awaitText(source.name)
    }
    @After fun clean() {
        inventoryGate?.countDown(); directoryGate?.countDown()
        compose.waitUntil(10_000) { !model.fileISOMounts.state.value.busy }
        compose.runOnIdle {
            model.fileISOMounts.invalidate(); recovery.removeProfile(profile.id); permissions.removeProfile(profile.id)
            remoteRecovery.removeProfile(profile.id)
            profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
        }
    }

    @Test fun mountingFromFileMenuPreservesSelectionAndConfirmsAutomaticConnection() {
        openSource(); chooseEmpty(); capture("iso-editor")
        compose.onNodeWithTag("iso_automatic").performScrollTo().performClick()
        compose.activityRule.scenario.recreate()
        assertEquals(empty.path, model.fileISOMounts.state.value.destination?.path); assertTrue(model.fileISOMounts.state.value.automatic)
        compose.onNodeWithTag("iso_submit").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.iso_automatic_impact)).assertIsDisplayed(); capture("iso-confirmation")
        assertTrue(writes().isEmpty()); compose.onNodeWithTag("iso_confirm_automatic").performClick()
        awaitResult(MutationResultStatus.CONFIRMED_SUCCESS); capture("iso-completed")
        assertEquals(1, writes().size); val sent = writes().single()
        assertEquals("mount_iso", sent["method"]); assertEquals(source.path, sent["source"])
        assertEquals(empty.path, sent["mount_point"]); assertEquals("true", sent["auto_mount"]); assertEquals("true", sent["user_set"])
        compose.onNodeWithTag("iso_show_mounts").performScrollTo().performClick(); awaitReady()
        compose.onNodeWithTag("iso_browse").performClick()
        compose.waitUntil(10_000) { model.workspace.value?.fileBrowser?.path == empty.path }
        assertEquals(1, writes().size)
    }
    @Test fun ordinaryMountUsesActionButtonAndDisconnectLeavesIsoAndFolder() {
        ordinaryMountType = ""
        openSource(); chooseEmpty(); compose.onNodeWithTag("iso_submit").performScrollTo().performClick()
        awaitResult(MutationResultStatus.CONFIRMED_SUCCESS); assertEquals("false", writes().single()["auto_mount"])
        compose.onNodeWithTag("iso_show_mounts").performScrollTo().performClick(); awaitReady(); capture("iso-list")
        compose.onNodeWithTag("iso_unmount").performClick()
        compose.onNodeWithText(text(R.string.iso_unmount_impact)).assertExists(); capture("iso-disconnect")
        compose.onNodeWithTag("iso_submit").performScrollTo().performClick(); awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        assertEquals(2, writes().size); assertEquals("[\"${empty.path}\"]", writes().last()["mount_point"])
        assertFalse(calls.any { it["api"]?.contains("Delete") == true }); assertFalse(mounted)
    }
    @Test fun nonEmptyFolderKeepsErrorAndSendsNoMount() {
        openSource(); chooseEmpty(); nonempty = true
        compose.onNodeWithTag("iso_submit").performScrollTo().performClick()
        compose.waitUntil(10_000) { !model.fileISOMounts.state.value.busy && model.fileISOMounts.state.value.failure != null }
        compose.onNodeWithText(text(R.string.file_mount_empty_required) + " " + text(R.string.file_mount_empty_required_hint)).assertExists()
        capture("iso-nonempty"); assertTrue(writes().isEmpty())
    }
    @Test fun unknownMountSurvivesCloseAndRecreationAndRefreshDoesNotReplay() {
        unknownMount = true; openSource(); chooseEmpty(); compose.onNodeWithTag("iso_submit").performScrollTo().performClick()
        awaitResult(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED); capture("iso-pending-editor")
        compose.onNodeWithContentDescription(text(R.string.close)).performClick(); compose.activityRule.scenario.recreate()
        openManager(); assertEquals(1, model.fileISOMounts.state.value.pending.size); capture("iso-pending-manager")
        compose.onNodeWithTag("iso_pending_refresh").performClick(); awaitResult(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED)
        assertEquals(1, writes().size)
        mounted = true
        compose.onNodeWithTag("iso_pending_refresh").performClick(); awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        assertEquals(1, writes().size); assertTrue(model.fileISOMounts.state.value.pending.isEmpty())
    }
    @Test fun managerLoadingErrorRetryEmptyAndFilterStatesRemainUsable() {
        inventoryGate = CountDownLatch(1); openManager(wait = false)
        compose.waitUntil(10_000) { model.fileISOMounts.state.value.inventory is Loadable.Loading }; capture("iso-loading")
        inventoryFailure = true; inventoryGate?.countDown(); inventoryGate = null
        compose.waitUntil(10_000) { model.fileISOMounts.state.value.inventory is Loadable.Failed }
        compose.onNodeWithText(text(R.string.retry)).assertIsDisplayed(); capture("iso-error")
        inventoryFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); awaitReady()
        compose.onNodeWithText(text(R.string.iso_mounts_empty)).assertIsDisplayed(); capture("iso-empty")
        mounted = true; compose.onNodeWithTag("iso_refresh").performClick(); awaitReady()
        compose.onNodeWithTag("iso_filter").performTextInput("no-match"); compose.onNodeWithTag("iso_filter").performImeAction()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("iso-filter-empty")
        compose.onNodeWithTag("iso_filter").performTextClearance(); compose.onNodeWithTag("iso_filter").performImeAction()
        compose.onNodeWithTag("iso_browse").assertIsDisplayed(); assertTrue(writes().isEmpty())
    }
    @Test fun folderPickerLoadingErrorFilterEmptyAndReadOnlyDoNotChangeSelection() {
        openSource(); directoryGate = CountDownLatch(1)
        compose.onNodeWithText(text(R.string.iso_destination)).performClick()
        compose.waitUntil(10_000) { model.fileISOMounts.state.value.locations is Loadable.Loading }; capture("iso-folders-loading")
        directoryFailure = true; directoryGate?.countDown(); directoryGate = null
        compose.waitUntil(10_000) { model.fileISOMounts.state.value.locations is Loadable.Failed }; capture("iso-folders-error")
        directoryFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); awaitLocation("")
        compose.onNodeWithTag("iso_location_Synthetic").performClick(); awaitLocation(root.path)
        compose.onNodeWithTag("iso_location_filter").performTextInput("no-match"); compose.onNodeWithTag("iso_location_filter").performImeAction()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("iso-folders-filter-empty")
        compose.onNodeWithTag("iso_location_filter").performTextClearance(); compose.onNodeWithTag("iso_location_filter").performImeAction()
        compose.onNodeWithTag("iso_location_ReadOnly").performClick(); awaitLocation(readOnly.path)
        awaitText(text(R.string.archive_choose_writable_destination))
        compose.onNodeWithText(text(R.string.file_search_no_folders)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.archive_choose_writable_destination)).assertIsDisplayed()
        compose.onNodeWithTag("iso_choose_location").assertIsNotEnabled(); capture("iso-folder-readonly")
        assertNull(model.fileISOMounts.state.value.destination); assertTrue(writes().isEmpty())
    }
    @Test fun administratorRevocationClosesAutomaticConfirmationWithoutWriting() {
        openSource(); chooseEmpty(); compose.onNodeWithTag("iso_automatic").performScrollTo().performClick()
        compose.onNodeWithTag("iso_submit").performScrollTo().performClick(); administrator = false
        compose.runOnIdle { model.refreshWorkspaceAccess() }
        compose.waitUntil(10_000) { model.fileISOMounts.state.value.screen == null }
        compose.onNodeWithTag("iso_confirm_automatic").assertDoesNotExist(); assertTrue(writes().isEmpty())
        openSource(); chooseEmpty(); compose.onNodeWithTag("iso_submit").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.iso_management_unavailable)).assertExists(); capture("iso-readonly-account")
    }

    private fun openSource() {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(source.name).fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText(source.name).assertIsDisplayed().performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.iso_mount_action)).performScrollTo().performClick(); awaitReady()
    }
    private fun openManager(wait: Boolean = true) {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.iso_mounts_title)).performScrollTo().performClick()
        if (wait) awaitReady()
    }
    private fun chooseEmpty() {
        compose.onNodeWithText(text(R.string.iso_destination)).performScrollTo().performClick(); awaitLocation("")
        compose.onNodeWithTag("iso_location_Synthetic").performClick(); awaitLocation(root.path)
        compose.onNodeWithTag("iso_location_Empty").performClick(); awaitLocation(empty.path)
        compose.onNodeWithTag("iso_choose_location").assertIsEnabled().performClick()
        compose.waitUntil(10_000) { !model.fileISOMounts.state.value.locationsVisible }
    }
    private fun awaitReady() = compose.waitUntil(10_000) { model.fileISOMounts.state.value.inventory is Loadable.Ready && model.fileISOMounts.state.value.recoveryReadable }
    private fun awaitLocation(path: String) = compose.waitUntil(10_000) { model.fileISOMounts.state.value.locationPath == path && model.fileISOMounts.state.value.locations is Loadable.Ready }
    private fun awaitResult(status: MutationResultStatus) = compose.waitUntil(10_000) { !model.fileISOMounts.state.value.busy && model.fileISOMounts.state.value.result?.status == status }
    private fun awaitText(value: String) = compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] in setOf("mount_iso", "unmount") }.toList() }

    private fun response(fields: Map<String, String>): JsonObject = when (fields["api"]) {
        MOUNT_LIST_API -> if (fields["method"] == "get") {
            inventoryGate?.await(10, TimeUnit.SECONDS)
            if (inventoryFailure) throw IOException("synthetic inventory failure")
            buildJsonObject { putJsonObject("mountConfig") { put("enable_iso_mount", true); put("enable_remote_mount", true) }
                putJsonArray("remoteList") {}; putJsonArray("isoList") { if (mounted) add(buildJsonObject {
                    put("type", "iso"); put("source", source.path); put("mount_point", empty.path); put("auto_mount", automatic)
                }) } }
        } else { check(fields["method"] == "unmount"); mounted = false; buildJsonObject {} }
        MOUNT_API -> {
            check(fields["method"] == "mount_iso"); if (unknownMount) throw IOException("synthetic lost connection")
            mounted = true; automatic = fields["auto_mount"] == "true"; buildJsonObject {}
        }
        "SYNO.FileStation.List" -> when (fields["method"]) {
            "getinfo" -> buildJsonObject { putJsonArray("files") { Json.parseToJsonElement(fields.getValue("path")).jsonArray.forEach { value ->
                add(file(listOf(root, source, empty, readOnly).single { it.path == value.jsonPrimitive.content }))
            } } }
            "list_share", "list" -> {
                if (fields["method"] == "list_share" || fields["filetype"] == "dir") {
                    directoryGate?.await(10, TimeUnit.SECONDS); if (directoryFailure) throw IOException("synthetic folder failure")
                }
                val rows = when {
                    fields["method"] == "list_share" -> listOf(root)
                    fields["folder_path"] == root.path -> if (fields["filetype"] == "dir") listOf(empty, readOnly) else listOf(source, empty, readOnly)
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
            put("mount_point_type", if (mounted && item.path == empty.path) "iso" else if (item.mountPointType == "normal") ordinaryMountType else item.mountPointType)
            putJsonObject("time") { put("mtime", item.modifiedAtEpochSeconds ?: 10) }
            putJsonObject("perm") { putJsonObject("acl") { put("read", item.canRead); put("write", item.canWrite); put("del", false) } }
        }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.waitForIdle(150, 5_000)
        val bitmap = automation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "file-iso-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
