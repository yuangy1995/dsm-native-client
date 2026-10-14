package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.FileShareRecoveryStore
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 实际 Android 宿主与分享页面；所有文件、成员和网络结果均为明确的合成夹具。 */
class FileSharingUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val recovery = FileShareRecoveryStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("share-ui-" + UUID.randomUUID(), "Sharing NAS", "https://synthetic.example.invalid", "synthetic")
    private lateinit var model: AppViewModel
    private lateinit var repo: DsmRepository
    private val requests = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    private val links = Collections.synchronizedList(mutableListOf<JsonObject>())
    @Volatile private var listFailure = false
    @Volatile private var failAfterCreate = false
    @Volatile private var listGate: CountDownLatch? = null
    @Volatile private var writeGate: CountDownLatch? = null
    @Volatile private var membersFail = false
    private val folder = FileItem("/synthetic/Inbox", "Inbox", true, canRead = true, canWrite = true)
    private val file = FileItem("/synthetic/Report.txt", "Report.txt", false, size = 10, canRead = true)

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
                requests += fields
                val data = response(fields)
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body("{\"success\":true,\"data\":$data}".toResponseBody("application/json".toMediaType())).build()
            }.build())
            repo = authorizedRepository(profile, session, api, mapOf(
                "SYNO.FileStation.List" to ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
                "SYNO.FileStation.Sharing" to ApiCapability("SYNO.FileStation.Sharing", "entry.cgi", 1, 3),
                "SYNO.FileStation.UserGrp" to ApiCapability("SYNO.FileStation.UserGrp", "entry.cgi", 1, 1)))
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }; repo.bindShareRecovery(recovery)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                supportsSharing = true, fileBrowser = FileBrowserState(path = "/synthetic"), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        awaitText(file.name)
    }

    @After fun clean() {
        listGate?.countDown()
        writeGate?.countDown()
        if (::model.isInitialized) compose.waitUntil(10_000) { !model.fileSharing.state.value.busy }
        compose.runOnIdle { model.fileSharing.invalidate(); recovery.removeProfile(profile.id); profiles.removeProfile(profile.id); profiles.setLastProfileId(previous) }
    }

    @Test fun batchCreationKeepsPasswordAndDatesThroughRotationThenClearsDraft() {
        compose.onNodeWithText(file.name).performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.select_item)).performScrollTo().performClick()
        compose.onNodeWithText(folder.name).performClick()
        compose.onNodeWithText(text(R.string.file_share_create)).performScrollTo().performClick()
        compose.onNodeWithTag("file_share_password").performTextInput("synthetic-pass")
        compose.onNodeWithText(app.getString(R.string.file_share_days, 7)).performScrollTo().performClick()
        compose.activityRule.scenario.recreate()
        assertEquals("synthetic-pass", model.fileSharing.state.value.draft.password)
        capture("sharing-create")
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        awaitResults(2)
        assertTrue(model.fileSharing.state.value.results.all { it.outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS })
        assertEquals("", model.fileSharing.state.value.draft.password)
        val writes = writeCalls("create")
        assertEquals(2, writes.size)
        assertTrue(writes.all { it["password"] == "synthetic-pass" && it["date_expired"] != null && it["version"] == "3" })
        compose.onAllNodesWithText(text(R.string.copy_share_link)).onLast().performScrollTo().performClick()
        val clipboard = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        assertEquals(links.joinToString("\n") { it["url"]!!.jsonPrimitive.content }, clipboard.primaryClip?.getItemAt(0)?.text.toString())
        capture("sharing-created")
    }

    @Test fun collectionRequiresConcreteConfirmationAndSavesNameMessage() {
        openCreate(folder.name)
        compose.onNodeWithText(text(R.string.file_share_collection)).performScrollTo().performClick()
        compose.onNodeWithTag("file_share_request_name").performScrollTo().performTextInput("Project inbox")
        compose.onNodeWithTag("file_share_request_message").performScrollTo().performTextInput("Upload synthetic documents")
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_share_confirm_title)).assertIsDisplayed()
        assertTrue(writeCalls("create").isEmpty())
        capture("sharing-collection-confirmation")
        compose.onNodeWithTag("file_share_confirm").performClick()
        awaitResults(1)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.fileSharing.state.value.results.single().outcome.result.status)
        assertEquals("true", writeCalls("create").single()["file_request"])
        assertEquals("Project inbox", writeCalls("create").single()["request_name"])
        assertEquals("Upload synthetic documents", writeCalls("create").single()["request_info"])
    }

    @Test fun namedMembersComeFromPagedListAndSaveWithoutChangingDates() {
        links += share("existing", file.path, file.name, available = "2026-10-11 14:25:36")
        openManager()
        compose.onNodeWithContentDescription(text(R.string.file_share_access)).performClick()
        compose.onNodeWithText(text(R.string.file_share_named_members)).performScrollTo().performClick()
        awaitText("member-a")
        compose.onNodeWithText("member-a").performClick()
        compose.onNodeWithText(text(R.string.file_share_more_members)).performScrollTo().performClick()
        awaitText("group-b")
        compose.onNodeWithText("group-b").performClick()
        capture("sharing-members")
        compose.onNodeWithText(app.getString(R.string.file_share_use_members, 2)).performClick()
        compose.onNodeWithTag("file_share_access_count").performScrollTo().performTextReplacement("12")
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        compose.onNodeWithTag("file_share_confirm").performClick()
        awaitResults(1)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.fileSharing.state.value.results.single().outcome.result.status)
        val write = writeCalls("edit").single()
        assertEquals("[\"member-a\"]", write["protect_users"])
        assertEquals("[\"group-b\"]", write["protect_groups"])
        assertEquals("12", write["expire_times"])
        assertFalse(write.containsKey("password")); assertFalse(write.containsKey("date_available")); assertFalse(write.containsKey("date_expired"))
    }

    @Test fun passwordRemovalAndExpiryEditKeepOriginalAvailabilityTime() {
        links += share("protected", file.path, file.name, password = true, available = "2026-10-11 14:25:36", expires = "2026-12-31")
        openManager()
        compose.onNodeWithContentDescription(text(R.string.file_share_edit)).performClick()
        compose.onNodeWithText(text(R.string.file_share_password_remove)).performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_share_no_expiry)).performScrollTo().performClick()
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        assertTrue(writeCalls("edit").isEmpty())
        compose.onNodeWithTag("file_share_confirm").performClick()
        awaitResults(1)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.fileSharing.state.value.results.single().outcome.result.status)
        assertEquals("", writeCalls("edit").single()["password"])
        assertEquals("0", writeCalls("edit").single()["date_expired"])
        assertFalse(writeCalls("edit").single().containsKey("date_available"))
    }

    @Test fun managerHandlesEmptyFilteredFailureAndRetry() {
        listGate = CountDownLatch(1)
        openManager(waitForResult = false)
        compose.onNode(hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate)).assertIsDisplayed()
        listGate?.countDown(); listGate = null
        compose.waitUntil(10_000) { model.workspace.value?.fileShareLinks is Loadable.Ready }
        compose.onNodeWithText(text(R.string.manage_share_links_empty)).assertIsDisplayed()
        links += share("one", file.path, file.name)
        compose.onNodeWithContentDescription(text(R.string.refresh)).performClick()
        awaitText(file.name)
        compose.onNodeWithText(text(R.string.file_share_filter)).performTextInput("absent")
        compose.onNodeWithText(text(R.string.file_share_filter_empty)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.file_share_clear_filter)).performClick()
        listFailure = true
        compose.onNodeWithContentDescription(text(R.string.refresh)).performClick()
        awaitText(text(R.string.manage_share_links_load_failed))
        capture("sharing-load-failure")
        listFailure = false
        compose.onNodeWithText(text(R.string.retry)).performClick()
        compose.waitUntil(10_000) { model.workspace.value?.fileShareLinks is Loadable.Ready }
        compose.waitUntil(10_000) {
            compose.onNode(hasText(file.name) and hasAnyAncestor(hasTestTag("file_share_manager"))).isDisplayed()
        }
        compose.onNode(hasText(file.name) and hasAnyAncestor(hasTestTag("file_share_manager"))).assertIsDisplayed()
        capture("sharing-manager")
    }

    @Test fun memberPickerShowsEmptyAndFailureThenRecovers() {
        links += share("members", file.path, file.name)
        openManager()
        compose.onNodeWithContentDescription(text(R.string.file_share_access)).performClick()
        compose.onNodeWithText(text(R.string.file_share_named_members)).performScrollTo().performClick()
        awaitText("member-a")
        compose.onNodeWithText(text(R.string.file_share_member_search)).performTextInput("absent")
        compose.onNodeWithText("absent").performImeAction()
        awaitText(text(R.string.file_share_member_empty))
        compose.onNodeWithText(text(R.string.file_share_clear_filter)).performClick()
        awaitText("member-a")
        membersFail = true
        compose.onAllNodesWithContentDescription(text(R.string.file_share_member_search)).onLast().performClick()
        awaitText(text(R.string.file_share_member_failed))
        membersFail = false
        compose.onNodeWithText(text(R.string.retry)).performClick()
        awaitText("member-a")
        assertTrue(writeCalls("edit").isEmpty())
    }

    @Test fun invalidPasswordCanBeCorrectedBeforeAnyRequest() {
        openCreate(file.name)
        compose.onNodeWithTag("file_share_password").performTextInput("synthetic-too-long-password")
        compose.onNodeWithTag("file_share_submit").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.file_share_check_fields)).performScrollTo().assertIsDisplayed()
        assertTrue(writeCalls("create").isEmpty())
        compose.onNodeWithTag("file_share_password").performScrollTo().performTextReplacement("synthetic-pass")
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        awaitResults(1)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, model.fileSharing.state.value.results.single().outcome.result.status)
    }

    @Test fun savingCannotBeHiddenByCloseOrSystemBack() {
        writeGate = CountDownLatch(1)
        openCreate(file.name)
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        compose.waitUntil(10_000) { writeCalls("create").size == 1 }
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        capture("sharing-save-dismiss")
        compose.onNodeWithTag("file_share_editor").assertIsDisplayed()
        compose.onNodeWithContentDescription(text(R.string.close)).assertIsNotEnabled()
        assertTrue(model.fileSharing.state.value.busy)
        writeGate?.countDown(); writeGate = null
        awaitResults(1)
        compose.onNodeWithContentDescription(text(R.string.close)).assertIsEnabled().performClick()
        compose.onNodeWithTag("file_share_editor").assertDoesNotExist()
        assertEquals(1, writeCalls("create").size)
    }

    @Test fun interruptedCreationOnlyRefreshesSavedIdentityAndCannotRepeat() {
        failAfterCreate = true
        openCreate(file.name)
        compose.onNodeWithTag("file_share_submit").performScrollTo().performClick()
        awaitResults(1)
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, model.fileSharing.state.value.results.single().outcome.result.status)
        compose.onNodeWithText(text(R.string.file_share_unknown)).performScrollTo().assertIsDisplayed()
        compose.activityRule.scenario.recreate()
        assertEquals(1, writeCalls("create").size)
        compose.runOnIdle { model.fileSharing.close() }
        listFailure = false; failAfterCreate = false
        openManager()
        awaitText(file.name)
        compose.waitUntil(10_000) { model.fileSharing.state.value.pending.isEmpty() }
        assertEquals(1, writeCalls("create").size)
    }

    @Test fun qrCodeDecodesToSelectedLinkAndSystemSharingUsesNativeChooser() {
        links += share("qr-link", file.path, file.name)
        openManager()
        compose.onNodeWithContentDescription(text(R.string.file_share_qr)).performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("file_share_qr_image").fetchSemanticsNodes().isNotEmpty() }
        val bitmap = compose.onNodeWithTag("file_share_qr_image").captureToImage().asAndroidBitmap()
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val decoded = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(bitmap.width, bitmap.height, pixels))))
        assertEquals("https://share.example.invalid/qr-link", decoded.text)
        capture("sharing-qr")
        compose.onNodeWithContentDescription(text(R.string.close)).performClick()
        compose.onNodeWithContentDescription(text(R.string.file_share_system)).performClick()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        compose.waitUntil(10_000) { automation.rootInActiveWindow?.packageName?.toString() in setOf("android", "com.android.intentresolver") }
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.onNodeWithTag("file_share_manager").assertExists()
        assertTrue(writeCalls("create").isEmpty())
    }

    @Test fun deletingLinkRequiresConfirmationAndLeavesOtherLinks() {
        links += share("delete-one", file.path, file.name)
        links += share("keep-two", folder.path, folder.name)
        openManager()
        compose.onAllNodesWithContentDescription(text(R.string.delete_share_link)).onFirst().performClick()
        compose.onNodeWithText(app.getString(R.string.delete_share_link_confirmation, file.name)).assertIsDisplayed()
        assertTrue(writeCalls("delete").isEmpty())
        compose.onAllNodesWithText(text(R.string.delete_share_link)).onLast().performClick()
        compose.waitUntil(10_000) { writeCalls("delete").size == 1 && links.size == 1 }
        assertEquals("keep-two", links.single()["id"]!!.jsonPrimitive.content)
        assertEquals("[\"delete-one\"]", writeCalls("delete").single()["id"])
    }

    private fun openCreate(name: String) {
        compose.onNodeWithText(name).performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.create_share_link)).performClick()
        compose.onNodeWithTag("file_share_editor").assertExists()
    }
    private fun openManager(waitForResult: Boolean = true) {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.manage_share_links)).performScrollTo().performClick()
        if (waitForResult) compose.waitUntil(10_000) { model.workspace.value?.fileShareLinks is Loadable.Ready || model.workspace.value?.fileShareLinks is Loadable.Failed }
    }
    private fun awaitResults(count: Int) = compose.waitUntil(10_000) { !model.fileSharing.state.value.busy && model.fileSharing.state.value.results.size == count }
    private fun awaitText(value: String) = compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() }
    private fun text(id: Int) = app.getString(id)
    private fun writeCalls(method: String) = synchronized(requests) { requests.filter { it["api"] == "SYNO.FileStation.Sharing" && it["method"] == method } }

    private fun response(fields: Map<String, String>): JsonObject = when (fields["api"]) {
        "SYNO.FileStation.List" -> {
            val items = if (fields["method"] == "getinfo") {
                val paths = Json.parseToJsonElement(fields.getValue("path")).jsonArray.map { it.jsonPrimitive.content }
                listOf(folder, file).filter { it.path in paths }
            } else listOf(folder, file)
            buildJsonObject { put("total", items.size); put("offset", 0); put("files", JsonArray(items.map { item -> buildJsonObject {
                put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
                putJsonObject("additional") { putJsonObject("perm") {
                    put("is_acl_mode", false)
                    putJsonObject("acl") { put("read", item.canRead); put("write", item.canWrite); put("del", item.canDelete) }
                } }
            } })) }
        }
        "SYNO.FileStation.Sharing" -> synchronized(links) { when (fields["method"]) {
            "list" -> { listGate?.await(10, TimeUnit.SECONDS); if (listFailure) throw IOException("synthetic sharing read failure")
                buildJsonObject { put("total", links.size); put("offset", 0); put("links", JsonArray(links.toList())) } }
            "create" -> {
                writeGate?.await(10, TimeUnit.SECONDS)
                val path = Json.parseToJsonElement(fields.getValue("path")).jsonArray.single().jsonPrimitive.content
                val id = "link-${links.size + 1}"
                links += share(id, path, path.substringAfterLast('/'), password = fields["password"]?.isNotEmpty() == true,
                    available = fields["date_available"] ?: "0", expires = fields["date_expired"] ?: "0", collection = fields["file_request"] == "true",
                    requestName = fields["request_name"].orEmpty(), message = fields["request_info"].orEmpty())
                if (failAfterCreate) listFailure = true
                buildJsonObject { putJsonArray("links") { add(buildJsonObject { put("id", id); put("path", path); put("error", 0) }) } }
            }
            "edit" -> {
                val id = Json.parseToJsonElement(fields.getValue("id")).jsonArray.single().jsonPrimitive.content
                val index = links.indexOfFirst { it["id"]!!.jsonPrimitive.content == id }
                val values = links[index].toMutableMap()
                fields["password"]?.let { values["has_password"] = JsonPrimitive(it.isNotEmpty()); values["protect_type"] = JsonPrimitive(if (it.isEmpty()) "none" else "password") }
                listOf("date_available", "date_expired", "protect_type", "request_name", "request_info").forEach { key -> fields[key]?.let { values[key] = JsonPrimitive(it) } }
                listOf("protect_users", "protect_groups").forEach { key -> fields[key]?.let { values[key] = Json.parseToJsonElement(it) } }
                if (fields["protect_type"] != null) values["has_password"] = JsonPrimitive(false)
                fields["expire_times"]?.let { values["expire_times"] = JsonPrimitive(it.toInt()) }
                links[index] = JsonObject(values); buildJsonObject {} }
            "delete" -> {
                val ids = Json.parseToJsonElement(fields.getValue("id")).jsonArray.map { it.jsonPrimitive.content }
                links.removeAll { it["id"]!!.jsonPrimitive.content in ids }; buildJsonObject {} }
            else -> error("Unexpected synthetic sharing method")
        } }
        "SYNO.FileStation.UserGrp" -> {
            if (membersFail) throw IOException("synthetic member read failure")
            val all = listOf("member-a" to "user", "group-b" to "group").filter { it.first.startsWith(fields["prefix"].orEmpty()) }
            val offset = fields.getValue("offset").toInt()
            buildJsonObject { put("total", all.size); put("owners", JsonArray(all.drop(offset).take(1).map { (name, kind) -> buildJsonObject { put("name", name); put("type", kind) } })) }
        }
        else -> error("Unexpected synthetic API")
    }
    private fun share(id: String, path: String, name: String, password: Boolean = false, available: String = "0", expires: String = "0",
                      collection: Boolean = false, requestName: String = "", message: String = "") = buildJsonObject {
        put("id", id); put("path", path); put("name", name); put("url", "https://share.example.invalid/$id")
        put("has_password", password); put("date_available", available); put("date_expired", expires); put("status", "valid")
        put("protect_type", if (password) "password" else "none"); put("protect_users", JsonArray(emptyList())); put("protect_groups", JsonArray(emptyList()))
        put("expire_times", 0); put("enable_upload", collection); put("project_name", if (collection) "SYNO.SDS.App.SharingUpload.Application" else "SYNO.SDS.App.FileStation3.Instance")
        put("request_name", requestName); put("request_info", message)
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val output = File(app.getExternalFilesDir(null), "file-sharing-review/$name.png")
        output.parentFile?.mkdirs(); output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
