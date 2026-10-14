package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.*
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
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

/** 原生表单、图片解码及真实仓储；合成网络和只读文件提供器不接触用户图片或 NAS。 */
class FileThemeUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app); private val recovery = FileRecoveryStores(app)
    private val previous = profiles.lastProfileId()?.takeUnless { it.startsWith("theme-ui-") }
    private val nas = NasProfile("theme-ui-${UUID.randomUUID()}", "Theme NAS", "https://synthetic.example.invalid", "synthetic")
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    private lateinit var model: AppViewModel; private lateinit var repo: DsmRepository
    private val theme get() = model.fileSettings
    private val picker get() = theme.themePicker
    @Volatile private var readFailure = false
    @Volatile private var invalidImage = false
    @Volatile private var loseReply = false
    @Volatile private var advanceSequence = true
    @Volatile private var nasAllowed = true
    @Volatile private var gate: CountDownLatch? = null
    private var images = listOf("/history/synthetic-logo.png")
    private var imageIndex = 0
    private var settings = buildJsonObject {
        put("enable_logo_customize", false); put("enable_background_customize", false); put("enable_footer_html", false)
        put("logo_position", "rightup"); put("background_position", "fill"); put("background_color", "#FFFFFF"); put("footer_msg", "")
        put("logo_seq", "1"); put("background_seq", "2")
    }
    private val imageFile by lazy { File(app.cacheDir, "theme-ui-${nas.id}.png") }
    private lateinit var ioContext: Context
    private lateinit var png: ByteArray
    @Before fun prepare() {
        profiles.profiles().filter { it.id.startsWith("theme-ui-") }.forEach { recovery.removeProfile(it.id); profiles.removeProfile(it.id) }
        val bitmap = Bitmap.createBitmap(120, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.rgb(36, 85, 237)) }
        png = java.io.ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() }; bitmap.recycle(); imageFile.writeBytes(png)
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = "image/png"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor =
                MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf("synthetic-local.png")) }
            override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor { assertEquals("r", mode); return ParcelFileDescriptor.open(imageFile, ParcelFileDescriptor.MODE_READ_ONLY) }
            override fun insert(uri: Uri, values: ContentValues?): Uri? = error("No insert")
            override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = error("No deletion")
            override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = error("No update")
        }
        provider.attachInfo(app, ProviderInfo().apply { authority = "synthetic.theme.provider" })
        ioContext = object : ContextWrapper(app) { override fun getContentResolver() = ContentResolver.wrap(provider) }
        val session = DsmSession(nas.id, "synthetic-session")
        val owner = profiles.commitConnection(profiles.connectionAttempt(nas.id), nas, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(nas.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request()
                val fields = when (val body = request.body) {
                    is FormBody -> (0 until body.size).associate { body.name(it) to body.value(it) }
                    is MultipartBody -> {
                        val raw = okio.Buffer().also(body::writeTo).readUtf8(); assertTrue(raw.contains("name=\"upload_image\"; filename=\"synthetic-local.png\""))
                        body.parts.mapNotNull { part ->
                            val disposition = part.headers?.get("Content-Disposition").orEmpty()
                            if ("filename=" in disposition) null else Regex("name=\"([^\"]+)\"").find(disposition)?.groupValues?.get(1)?.let { it to okio.Buffer().also(part.body::writeTo).readUtf8() }
                        }.toMap()
                    }
                    else -> request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
                }
                calls += fields
                assertNull(request.url.queryParameter("_sid")); assertNull(request.url.queryParameter("SynoToken"))
                val body = if (request.method == "GET") {
                    if (request.url.encodedPath.contains("/default_login_background/")) assertNull(request.header("Cookie")) else assertNotNull(request.header("Cookie"))
                    (if (invalidImage) byteArrayOf(1, 2, 3) else png).toResponseBody("image/png".toMediaType())
                } else buildJsonObject { put("success", true); put("data", response(fields)) }.toString().toResponseBody("application/json".toMediaType())
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
            }.build())
            val caps = listOf(FILE_SHARING_THEME_API, FILE_THEME_IMAGE_API, "SYNO.FileStation.List", "SYNO.FileStation.Thumb", "SYNO.Core.System").associateWith {
                ApiCapability(it, "entry.cgi", 1, if (it.startsWith("SYNO.FileStation.")) 2 else 1)
            }
            val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true, DesktopApplication.NAS_SETTINGS to nasAllowed), true) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(nas, session, api, caps, access); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }; recovery.bind(repo)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(nas, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = "/synthetic"), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        compose.waitUntil(10_000) { model.workspace.value?.files is Loadable.Ready }
    }
    @After fun cleanup() {
        gate?.countDown(); gate = null
        compose.waitUntil(10_000) { !theme.state.value.busy }
        compose.runOnIdle { theme.invalidate(); recovery.removeProfile(nas.id); profiles.removeProfile(nas.id); profiles.setLastProfileId(previous) }
        imageFile.delete()
    }
    @Test fun layoutLoadsRetriesAndSavesNativeFieldsWithDraftRecreation() {
        openRoot(); readFailure = true; gate = CountDownLatch(1)
        compose.onNodeWithText(text(R.string.file_theme_title)).performClick()
        compose.waitUntil(10_000) { theme.state.value.theme is Loadable.Loading }; capture("theme-loading")
        gate?.countDown(); gate = null; compose.waitUntil(10_000) { theme.state.value.theme is Loadable.Failed }; capture("theme-error")
        compose.onNodeWithTag("settings_save").assertDoesNotExist(); readFailure = false
        compose.onNodeWithTag("settings_retry").performClick(); ready(); capture("theme-layout")
        fill("theme_color", "bad"); compose.onNodeWithTag("settings_save").performScrollTo().assertIsNotEnabled()
        fill("theme_color", "#2455ED"); fill("theme_footer", "Synthetic footer")
        compose.activityRule.scenario.recreate(); compose.onNodeWithTag("theme_footer").performScrollTo()
            .assertTextEquals(text(R.string.file_theme_footer), text(R.string.file_theme_footer_hint), "Synthetic footer")
        compose.onNodeWithTag("theme_footer_html").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("Synthetic footer", writes().single()["footer_msg"]); assertEquals("true", writes().single()["enable_footer_html"]); capture("theme-saved")
    }
    @Test fun historyPreviewSelectsStableImageAndSavesOnlyAfterReturningToForm() {
        openTheme(); chooseLogo(); imageIndex = 7
        compose.onNodeWithText("synthetic-logo.png").performClick(); previewReady(); capture("theme-history-preview")
        assertEquals("7", calls.last { it["method"] == "get" && it["api"] == FILE_THEME_IMAGE_API }["index"])
        assertTrue(writes().isEmpty()); compose.onNodeWithTag("theme_use_image").performScrollTo().performClick()
        compose.onNodeWithTag("theme_logo_position").performScrollTo().performClick(); compose.onNodeWithText(text(R.string.file_theme_bottom_left)).performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("history", writes().single()["logo_type"]); assertEquals("synthetic-logo.png", writes().single()["logo_path"])
        assertEquals("leftbottom", writes().single()["logo_position"])
    }
    @Test fun defaultBackgroundHasLocalizedFilterAndNativePreview() {
        openTheme(); compose.onNodeWithTag("theme_background_enabled").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("theme_choose_background").performScrollTo().performClick(); source(R.string.file_theme_defaults); rowsReady()
        val name = app.getString(R.string.file_theme_default_name, 10)
        compose.onNodeWithTag("theme_image_filter").performTextInput(name)
        compose.onNode(hasText(name) and hasAnyAncestor(hasTestTag("theme_image_list"))).performScrollTo().performClick(); previewReady(); capture("theme-default-preview")
        compose.onNodeWithTag("theme_use_image").performScrollTo().performClick()
        compose.onNodeWithTag("theme_background_position").performScrollTo().performClick(); compose.onNodeWithText(text(R.string.file_theme_fit)).performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("default", writes().single()["background_type"]); assertEquals("dsm7_010.jpg", writes().single()["background_path"])
        assertEquals("fit", writes().single()["background_position"])
    }
    @Test fun emptyFilteredAndInvalidPreviewStatesHaveRecoverableActions() {
        images = emptyList(); openTheme(); chooseLogo(); compose.onNodeWithText(text(R.string.file_theme_empty)).assertExists(); capture("theme-empty")
        images = listOf("/history/synthetic-logo.png"); compose.onNodeWithText(text(R.string.refresh)).performClick(); rowsReady()
        compose.onNodeWithTag("theme_image_filter").performTextInput("absent")
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertExists(); capture("theme-filter-empty")
        compose.onNodeWithTag("theme_image_filter").performTextClearance(); invalidImage = true
        compose.onNodeWithText("synthetic-logo.png").performClick(); compose.waitUntil(10_000) { picker.state.value.preview is Loadable.Failed }
        compose.onNodeWithText(text(R.string.file_theme_image_invalid) + " " + text(R.string.file_theme_image_invalid_hint)).assertExists()
        compose.onNodeWithTag("theme_use_image").performScrollTo().assertIsNotEnabled(); capture("theme-preview-error")
        invalidImage = false; compose.onNodeWithText(text(R.string.retry)).performScrollTo().performClick(); previewReady()
    }
    @Test fun nasImagesUseReadableFilesAndKeepFullPath() {
        openTheme(); chooseLogo(); source(R.string.file_theme_nas); rowsReady()
        compose.onNodeWithText("Synthetic pictures").performClick(); rowsReady(); capture("theme-nas-list")
        compose.onNodeWithText("synthetic-nas.png").performClick(); previewReady()
        compose.onNodeWithTag("theme_use_image").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("fromDS", writes().single()["logo_type"]); assertEquals("/pictures/synthetic-nas.png", writes().single()["logo_path"])
    }
    @Test fun localImageDecodesUploadsThenNeedsIndependentPageSave() {
        openTheme(); chooseLogo(); source(R.string.file_theme_local); importLocal(); previewReady(); capture("theme-local-preview")
        assertTrue(writes().isEmpty()); assertEquals(0, uploads())
        compose.onNodeWithTag("theme_upload").performScrollTo().performClick()
        compose.waitUntil(10_000) { picker.state.value.kind == null && theme.state.value.themeDraft?.logoImage != null }
        assertEquals(1, uploads()); assertTrue(writes().isEmpty()); assertEquals("/history/synthetic-local.png", theme.state.value.themeDraft?.logoImage?.path)
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals(1, writes().size)
    }
    @Test fun uploadReplyLossDoesNotReplaySameBytesAndHistoryCanRecoverSelection() {
        openTheme(); chooseLogo(); source(R.string.file_theme_local); importLocal(); previewReady(); loseReply = true
        compose.onNodeWithTag("theme_upload").performScrollTo().performClick()
        compose.waitUntil(10_000) { !picker.state.value.busy && picker.state.value.unknownUpload }; capture("theme-upload-unknown")
        compose.onNodeWithTag("theme_upload").performScrollTo().assertIsNotEnabled(); assertEquals(1, uploads())
        source(R.string.file_theme_history); rowsReady(); compose.onNodeWithText("synthetic-local.png").performClick(); previewReady()
        compose.onNodeWithTag("theme_use_image").performScrollTo().performClick(); loseReply = false
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals(1, uploads()); assertEquals(1, writes().size)
    }
    @Test fun imageSaveWithoutSequenceChangeStaysReadonlyAcrossRecreationAndRefresh() {
        openTheme(); chooseLogo(); compose.onNodeWithText("synthetic-logo.png").performClick(); previewReady()
        compose.onNodeWithTag("theme_use_image").performScrollTo().performClick(); advanceSequence = false
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.UNKNOWN)
        compose.activityRule.scenario.recreate(); compose.onNodeWithTag("settings_review").performScrollTo().assertExists(); capture("theme-save-unknown")
        settings = JsonObject(settings + ("logo_seq" to JsonPrimitive("3")))
        compose.onNodeWithTag("settings_review").performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals(1, writes().size)
    }
    @Test fun revokedCoreAccessClosesThemeAndLateSystemSelectionCannotImport() {
        openTheme(); chooseLogo(); source(R.string.file_theme_local)
        val ticket = picker.selectionTicket()!!
        nasAllowed = false; runBlocking { repo.refreshAccess() }
        compose.runOnIdle {
            ApprovedUiFixture.setState(model, model.workspace.value!!.copy(availability = repo.availability()))
            theme.authorizationChanged(); picker.importLocal(ioContext, Uri.parse("content://synthetic.theme.provider/image"), ticket)
        }
        compose.onNodeWithTag("theme_image_picker").assertDoesNotExist(); assertNull(picker.state.value.local); assertEquals(0, uploads()); assertTrue(writes().isEmpty())
    }
    private fun importLocal() = compose.runOnIdle {
        picker.importLocal(ioContext, Uri.parse("content://synthetic.theme.provider/image"), picker.selectionTicket()!!)
    }
    private fun openRoot() {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.file_settings_title)).performScrollTo().performClick()
        compose.waitUntil(10_000) { theme.state.value.recoveryReadable }
    }
    private fun openTheme() { openRoot(); compose.onNodeWithText(text(R.string.file_theme_title)).performClick(); ready() }
    private fun ready() = compose.waitUntil(10_000) { theme.state.value.theme is Loadable.Ready && theme.state.value.recoveryReadable }
    private fun chooseLogo() {
        compose.onNodeWithTag("theme_logo_enabled").performScrollTo().performClick()
        compose.onNodeWithTag("theme_choose_logo").performScrollTo().performClick(); rowsReady()
    }
    private fun source(label: Int) {
        compose.onNodeWithTag("theme_image_source").performClick()
        compose.onNode(hasText(text(label)) and hasAnyAncestor(isPopup())).performClick(); rowsReady()
    }
    private fun rowsReady() = compose.waitUntil(10_000) { picker.state.value.rows is Loadable.Ready }
    private fun previewReady() = compose.waitUntil(10_000) { picker.state.value.preview is Loadable.Ready }
    private fun fill(tag: String, value: String) { compose.onNodeWithTag(tag).performScrollTo().performTextReplacement(value); compose.onNodeWithTag(tag).performImeAction() }
    private fun outcome(status: FileSettingsOutcomeStatus) = compose.waitUntil(10_000) { !theme.state.value.busy && theme.state.value.outcome?.status == status }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] == "set" }.toList() }
    private fun uploads() = synchronized(calls) { calls.count { it["method"] == "upload" } }
    private fun response(fields: Map<String, String>): JsonObject {
        when (fields["api"]) {
            FILE_SHARING_THEME_API -> {
                if (fields["method"] == "get") { gate?.await(10, TimeUnit.SECONDS); if (readFailure) throw IOException("synthetic theme failure"); return settings }
                val values = settings.toMutableMap()
                fields.filterKeys { it in settings && !it.endsWith("_seq") }.forEach { (key, value) -> values[key] = if (key.startsWith("enable_")) JsonPrimitive(value.toBooleanStrict()) else JsonPrimitive(value) }
                if (advanceSequence) for (kind in FileThemeImageKind.entries) if ("${kind.value}_path" in fields)
                    values["${kind.value}_seq"] = JsonPrimitive((values.getValue("${kind.value}_seq").jsonPrimitive.content.toInt() + 1).toString())
                settings = JsonObject(values); return buildJsonObject {}
            }
            FILE_THEME_IMAGE_API -> if (fields["method"] == "list") return buildJsonObject { putJsonArray("list") {
                images.forEachIndexed { index, path -> add(buildJsonObject { put("index", index + imageIndex); put("path", path); put("filename", path.substringAfterLast('/')) }) }
            } } else {
                images = images + "/history/synthetic-local.png"
                if (loseReply) throw IOException("synthetic lost upload reply")
                return buildJsonObject { put("path", "/history/synthetic-local.png") }
            }
            "SYNO.FileStation.List" -> {
                val shares = fields["method"] == "list_share"
                val empty = fields["folder_path"] == "/synthetic"
                return buildJsonObject { put("offset", 0); put("total", if (empty) 0 else 1); putJsonArray(if (shares) "shares" else "files") {
                    if (!empty) add(buildJsonObject {
                        put("path", if (shares) "/pictures" else "/pictures/synthetic-nas.png"); put("name", if (shares) "Synthetic pictures" else "synthetic-nas.png"); put("isdir", shares)
                        putJsonObject("additional") { putJsonObject("perm") { put("read", true) } }
                    })
                } }
            }
        }
        error("Unexpected synthetic request")
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle(); val instrumentation = InstrumentationRegistry.getInstrumentation(); instrumentation.uiAutomation.waitForIdle(150, 5_000)
        val drawn = CountDownLatch(1)
        instrumentation.runOnMainSync { val frames = android.view.Choreographer.getInstance(); frames.postFrameCallback { frames.postFrameCallback { drawn.countDown() } } }
        assertTrue(drawn.await(5, TimeUnit.SECONDS))
        val bitmap = instrumentation.uiAutomation.takeScreenshot(); val file = File(app.getExternalFilesDir(null), "file-theme-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
