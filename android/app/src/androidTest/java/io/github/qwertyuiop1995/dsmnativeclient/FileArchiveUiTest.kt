package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 正式文件页、归档面板与任务中心；仅网络内容和文件资料使用合成夹具。 */
class FileArchiveUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val transfers = TransferStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("archive-edit-ui-" + UUID.randomUUID(), "Archive NAS", "https://synthetic.example.invalid", "synthetic")
    private val root = FileItem("/synthetic", "Synthetic", true, canRead = true, canWrite = true)
    private val archive = FileItem("/synthetic/Documents.zip", "Documents.zip", false, size = 100, canRead = true)
    private val notes = FileItem("/synthetic/notes.txt", "notes.txt", false, size = 20, canRead = true)
    private val target = FileItem("/synthetic/Target", "Target", true, canRead = true, canWrite = true)
    private val readOnly = FileItem("/synthetic/ReadOnly", "ReadOnly", true, canRead = true, canWrite = false)
    private val folder = ArchiveItem(7, "Folder", "Folder", true)
    private val child = ArchiveItem(3, "a.txt", "Folder/a.txt", false, 12)
    private val zero = ArchiveItem(8, "zero.txt", "zero.txt", false, 0)
    private val files = ConcurrentHashMap<String, FileItem>()
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    private lateinit var model: AppViewModel
    @Volatile private var listGate: CountDownLatch? = null
    @Volatile private var emptyArchive = false
    @Volatile private var childFailure = false
    @Volatile private var passwordRequired = false
    @Volatile private var statusFailure = false
    @Volatile private var directoryFailure = false

    @Before fun prepare() {
        listOf(root, archive, notes, target, readOnly).forEach { files[it.path] = it }
        val session = DsmSession(profile.id, "synthetic-session", "synthetic-token")
        val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }; calls += fields
                val body = if (fields["api"] == "SYNO.FileStation.Extract" && fields["method"] == "list" && passwordRequired && fields["password"] != "synthetic-password")
                    """{"success":false,"error":{"code":1403}}"""
                else buildJsonObject { put("success", true); put("data", response(fields)) }.toString()
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body.toResponseBody("application/json".toMediaType())).build()
            }.build())
            val repo = authorizedRepository(profile, session, api, listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
                ApiCapability("SYNO.FileStation.Extract", "entry.cgi", 2, 2), ApiCapability("SYNO.FileStation.Compress", "entry.cgi", 3, 3)).associateBy(ApiCapability::name))
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                supportsCompression = true, supportsExtraction = true, fileBrowser = FileBrowserState(path = root.path), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        awaitText(archive.name)
    }

    @After fun clean() {
        listGate?.countDown()
        compose.waitUntil(10_000) { transfers.servers(profile.id).none { it.state == TransferState.RUNNING } }
        compose.runOnIdle {
            model.fileArchive.invalidate()
            transfers.servers(profile.id).forEach { record ->
                transfers.updateServer(record.id) { it.copy(state = TransferState.CANCELLED, submissionPhase = PersistedServerSubmissionPhase.TERMINAL,
                    requiresRefresh = false, mutationResult = null, refreshCompleted = true) }
                transfers.removeServer(record.id)
            }
            profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
        }
    }

    @Test fun selectedNestedFileKeepsDraftThroughRotationAndUsesChosenDestination() {
        openExtract()
        compose.onNodeWithTag("archive_password").performScrollTo().performTextInput("synthetic-password")
        compose.onNodeWithTag("archive_password").performImeAction()
        compose.onNodeWithText(text(R.string.archive_encoding_enu)).performScrollTo().performClick()
        compose.onNodeWithTag("archive_read").performScrollTo().performClick(); awaitLoaded()
        compose.onNodeWithText(text(R.string.archive_extract_selected)).performScrollTo().performClick()
        compose.onNodeWithContentDescription(app.getString(R.string.archive_open_folder, folder.name)).performClick()
        awaitText(child.name)
        compose.onNodeWithTag("archive_entry_3").performClick()
        capture("archive-selected")
        compose.onNodeWithTag("archive_use_selection").performClick()
        compose.onNodeWithText(text(R.string.archive_destination)).performScrollTo().performClick()
        chooseFolder(root.name)
        chooseFolder(target.name)
        compose.waitUntil(10_000) { model.fileArchive.state.value.location?.path == target.path }
        compose.onNodeWithTag("archive_choose_location").performClick()
        compose.onNodeWithTag("archive_create_subfolder").performScrollTo().performClick()
        compose.onNodeWithTag("archive_keep_directories").performScrollTo().performClick()
        compose.activityRule.scenario.recreate()
        assertEquals(setOf(3), model.fileArchive.state.value.selected.keys)
        assertEquals("synthetic-password", model.fileArchive.state.value.options.password)
        capture("archive-options")
        compose.onNodeWithTag("archive_submit").performScrollTo().performClick()
        val record = awaitTerminal()
        assertEquals(TransferState.SUCCEEDED, record.state)
        assertEquals(listOf("${target.path}/a.txt"), transfers.extractionOutputs(record).map { it.path })
        assertEquals(12L, TransferStore(app).extractionOutputs(record).single().expectedBytes)
        val write = writes().single()
        assertEquals("3", write["item_id"]); assertEquals(target.path, write["dest_folder_path"])
        assertEquals("false", write["keep_dir"]); assertEquals("false", write["create_subfolder"])
        assertEquals("enu", write["codepage"]); assertEquals("synthetic-password", write["password"])
        compose.runOnIdle { model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.onNodeWithText(text(R.string.client_finished_tasks)).performClick()
        awaitText(record.title); capture("archive-completed")
    }

    @Test fun overwriteHasConcreteConfirmationAndVerifiesAllOutputs() {
        openExtract()
        compose.onNodeWithTag("archive_overwrite").performScrollTo().performClick()
        compose.onNodeWithTag("archive_submit").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.archive_replace_warning)).assertIsDisplayed()
        assertTrue(writes().isEmpty()); capture("archive-overwrite-confirmation")
        compose.onNodeWithTag("archive_confirm_overwrite").performClick()
        val record = awaitTerminal()
        assertEquals(TransferState.SUCCEEDED, record.state)
        assertEquals("true", writes().single()["overwrite"])
        assertTrue(transfers.extractionOutputs(record).all { it.requiresTaskCompletion })
        assertEquals(3, transfers.extractionOutputs(record).size)
    }

    @Test fun unknownOverwriteSurvivesRecreationBlocksRepeatAndRefreshesOriginalTaskOnly() {
        statusFailure = true
        openExtract(); compose.onNodeWithTag("archive_overwrite").performScrollTo().performClick()
        compose.onNodeWithTag("archive_submit").performScrollTo().performClick(); compose.onNodeWithTag("archive_confirm_overwrite").performClick()
        val record = awaitTerminal(); assertTrue(record.requiresRefresh)
        compose.activityRule.scenario.recreate()
        assertTrue(TransferStore(app).extractionOutputs(record).all { it.requiresTaskCompletion })
        openExtract(); compose.onNodeWithTag("archive_submit").performScrollTo().performClick()
        compose.onNodeWithTag("file_archive_editor").assertIsDisplayed()
        assertEquals(DsmErrorKind.WORKSPACE_BUSY, model.fileArchive.state.value.failure?.kind)
        assertEquals(1, writes().size)
        compose.onNodeWithContentDescription(text(R.string.close)).performClick()
        statusFailure = false
        compose.runOnIdle { model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.onNodeWithText(text(R.string.client_active_tasks)).performClick()
        awaitText(text(R.string.open_and_refresh_affected_folder))
        capture("archive-recovery")
        compose.onNodeWithText(text(R.string.open_and_refresh_affected_folder)).performScrollTo().performClick()
        compose.waitUntil(10_000) { transfers.server(record.id)?.refreshCompleted == true }
        assertEquals(FileServerMutationVerification.MATCHES.name, transfers.server(record.id)?.verification)
        assertEquals(1, writes().size)
        assertTrue(calls.filter { it["method"] == "status" }.all { it["taskid"] == "synthetic-extract-task" })
    }

    @Test fun archiveBrowserCoversLoadingEmptyFilterPagingAndFailureRetry() {
        val gate = CountDownLatch(1); listGate = gate; emptyArchive = true
        openExtract(wait = false)
        compose.waitUntil(10_000) { model.fileArchive.state.value.page is Loadable.Loading }
        compose.onNodeWithTag("archive_submit").assertIsNotEnabled()
        listGate = null; gate.countDown(); awaitLoaded()
        compose.onNodeWithTag("archive_browse").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.archive_contents_empty)).assertIsDisplayed()
        capture("archive-empty")
        compose.onNodeWithTag("archive_use_selection").performClick()
        emptyArchive = false; compose.onNodeWithTag("archive_read").performScrollTo().performClick(); awaitLoaded()
        compose.onNodeWithTag("archive_browse").performScrollTo().performClick()
        compose.onNodeWithTag("archive_filter").performTextInput("missing")
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed()
        compose.onNodeWithTag("archive_filter").performTextClearance()
        compose.onNodeWithTag("archive_filter").performImeAction()
        compose.onNodeWithTag("archive_more").performClick(); awaitText(zero.name)
        childFailure = true
        compose.onNodeWithContentDescription(app.getString(R.string.archive_open_folder, folder.name)).performClick()
        compose.waitUntil(10_000) { model.fileArchive.state.value.page is Loadable.Failed }
        compose.onNodeWithText(text(R.string.retry)).assertIsDisplayed()
        capture("archive-load-failure")
        childFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); awaitText(child.name)
        capture("archive-browser")
    }

    @Test fun passwordFailureCanBeCorrectedBeforeStartingExtraction() {
        passwordRequired = true
        openExtract(wait = false)
        compose.waitUntil(10_000) { model.fileArchive.state.value.page is Loadable.Failed }
        compose.onNodeWithText(text(R.string.archive_password_incorrect), substring = true).performScrollTo().assertIsDisplayed()
        assertTrue(writes().isEmpty())
        compose.onNodeWithTag("archive_password").performScrollTo().performTextInput("synthetic-password")
        compose.onNodeWithTag("archive_read").performScrollTo().performClick(); awaitLoaded()
        compose.onNodeWithTag("archive_submit").performScrollTo().performClick()
        assertEquals(TransferState.SUCCEEDED, awaitTerminal().state)
        assertEquals("synthetic-password", writes().single()["password"])
    }

    @Test fun compressionUsesChosenLevelFormatAndDottedName() {
        compose.onNodeWithText(notes.name).performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.create_archive)).performScrollTo().performClick()
        compose.onNodeWithTag("archive_name").performScrollTo().performTextReplacement("report.v1")
        compose.onNodeWithText(text(R.string.archive_format_7z)).performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.archive_level_best)).performScrollTo().performClick()
        compose.onNodeWithTag("archive_password").performScrollTo().performTextInput("synthetic-password")
        capture("archive-compression")
        compose.onNodeWithTag("archive_submit").performScrollTo().performClick()
        assertEquals(TransferState.SUCCEEDED, awaitTerminal().state)
        val write = writes().single()
        assertEquals("best", write["level"]); assertEquals("7z", write["format"])
        assertEquals("/synthetic/report.v1.7z", write["dest_file_path"])
        assertEquals("synthetic-password", write["password"])
    }

    @Test fun readOnlyDestinationCanBeBrowsedButCannotBeSelected() {
        openExtract()
        compose.onNodeWithText(text(R.string.archive_destination)).performScrollTo().performClick()
        val search = compose.onNode(hasSetTextAction() and hasAnyAncestor(hasTestTag("archive_locations")))
        search.performTextInput("missing")
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed()
        search.performTextClearance(); search.performImeAction()
        chooseFolder(root.name)
        directoryFailure = true
        chooseFolder(readOnly.name)
        compose.waitUntil(10_000) { model.fileArchive.state.value.locations is Loadable.Failed }
        directoryFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick()
        compose.waitUntil(10_000) { model.fileArchive.state.value.location?.path == readOnly.path }
        compose.onNodeWithTag("archive_choose_location").assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.archive_choose_writable_destination)).assertIsDisplayed()
        assertTrue(writes().isEmpty())
    }

    private fun openExtract(wait: Boolean = true) {
        compose.onNodeWithText(archive.name).performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.extract_archive)).performScrollTo().performClick()
        if (wait) awaitLoaded()
    }
    private fun chooseFolder(name: String) {
        val match = hasText(name) and hasAnyAncestor(hasTestTag("archive_locations"))
        compose.waitUntil(10_000) { compose.onAllNodes(match).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(match).performClick()
    }
    private fun awaitLoaded() {
        try { compose.waitUntil(10_000) { model.fileArchive.state.value.page is Loadable.Ready } }
        catch (error: Throwable) {
            capture("archive-read-failure")
            val current = model.fileArchive.state.value
            val readCount = calls.count { it["api"] == "SYNO.FileStation.Extract" && it["method"] == "list" }
            throw AssertionError("Archive state=${current.page::class.simpleName}, error=${(current.page as? Loadable.Failed)?.error?.kind}, encoding=${current.options.codepage}, reads=$readCount", error)
        }
    }
    private fun awaitText(value: String) {
        try { compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() } }
        catch (error: Throwable) {
            capture("archive-text-failure")
            val current = model.fileArchive.state.value
            val reads = calls.filter { it["api"] == "SYNO.FileStation.Extract" && it["method"] == "list" }.takeLast(6).map { it["item_id"] to it["offset"] }
            throw AssertionError("Archive state=${current.page::class.simpleName}, error=${(current.page as? Loadable.Failed)?.error?.kind}, filterEmpty=${current.filter.isEmpty()}, reads=$reads", error)
        }
    }
    private fun awaitTerminal(): PersistedServerTransfer {
        compose.waitUntil(15_000) { transfers.servers(profile.id).singleOrNull()?.state in setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED) }
        return transfers.servers(profile.id).single()
    }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] == "start" }.toList() }
    private fun response(fields: Map<String, String>): JsonObject = when (fields["api"]) {
        "SYNO.FileStation.List" -> when (fields["method"]) {
            "getinfo" -> buildJsonObject { putJsonArray("files") { Json.parseToJsonElement(fields.getValue("path")).jsonArray.forEach { value -> files[value.jsonPrimitive.content]?.let { add(file(it)) } } } }
            "list_share" -> buildJsonObject { put("total", 1); put("offset", 0); putJsonArray("shares") { add(file(root)) } }
            "list" -> {
                val path = fields["folder_path"] ?: root.path
                if (directoryFailure && path == readOnly.path) throw IOException("synthetic folder read failure")
                val values = files.values.filter { it.path.substringBeforeLast('/') == path && (fields["filetype"] != "dir" || it.isDirectory) }.sortedBy { it.name }
                buildJsonObject { put("total", values.size); put("offset", 0); put("files", JsonArray(values.map(::file))) }
            }
            else -> error("Unexpected synthetic file method")
        }
        "SYNO.FileStation.Extract" -> when (fields["method"]) {
            "list" -> {
                listGate?.await(10, TimeUnit.SECONDS)
                if (childFailure && fields["item_id"] == "7") throw IOException("synthetic archive read failure")
                val all = if (emptyArchive) emptyList() else if (fields["item_id"] == "-1") listOf(folder, zero) else listOf(child)
                val offset = fields.getValue("offset").toInt()
                buildJsonObject { put("total", all.size); put("items", JsonArray(all.drop(offset).take(1).map(::entry))) }
            }
            "start" -> {
                val selected = fields["item_id"]?.split(',')?.map(String::toInt)
                val all = listOf(folder, zero, child).filter { selected == null || it.id in selected || folder.id in selected && it.path.startsWith("Folder/") }
                val destination = fields.getValue("dest_folder_path") + if (fields["create_subfolder"] == "true") "/Documents" else ""
                all.filter { fields["keep_dir"] != "false" || !it.isDirectory }.forEach { item ->
                    val path = destination + "/" + if (fields["keep_dir"] == "false") item.name else item.path
                    files[path] = FileItem(path, item.name, item.isDirectory, size = item.size ?: 0, canRead = true, canWrite = true)
                }
                buildJsonObject { put("taskid", "synthetic-extract-task") }
            }
            "status" -> { if (statusFailure) throw IOException("synthetic archive status failure"); buildJsonObject { put("finished", true) } }
            "stop" -> buildJsonObject {}
            else -> error("Unexpected synthetic archive method")
        }
        "SYNO.FileStation.Compress" -> when (fields["method"]) {
            "start" -> { val path = fields.getValue("dest_file_path"); files[path] = FileItem(path, path.substringAfterLast('/'), false, size = 100, canRead = true)
                buildJsonObject { put("taskid", "synthetic-compress-task") } }
            "status" -> buildJsonObject { put("finished", true) }
            else -> error("Unexpected synthetic compression method")
        }
        else -> error("Unexpected synthetic API")
    }
    private fun file(value: FileItem) = buildJsonObject {
        put("path", value.path); put("name", value.name); put("isdir", value.isDirectory); put("size", value.size)
        putJsonObject("additional") { putJsonObject("perm") { put("is_acl_mode", false); putJsonObject("acl") { put("read", value.canRead); put("write", value.canWrite); put("del", value.canDelete) } } }
    }
    private fun entry(value: ArchiveItem) = buildJsonObject { put("item_id", value.id); put("name", value.name); put("path", value.path); put("is_dir", value.isDirectory); value.size?.let { put("size", it) } }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "file-archive-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
