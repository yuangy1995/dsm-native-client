package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
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
import okio.Buffer
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 原生文件入口和实际仓储；系统选择结果、文档提供器和 NAS 内容均为明确合成夹具。 */
class OfficeDocumentUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app); private val recovery = FileRecoveryStores(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("office-ui-${UUID.randomUUID()}", "Office NAS", "https://synthetic.example.invalid", "synthetic")
    private val original = "synthetic-original-document".encodeToByteArray()
    private val edited = "synthetic-edited-document".encodeToByteArray()
    @Volatile private var remote = original
    @Volatile private var allowed = true
    @Volatile private var corruptUpload = false
    @Volatile private var failInfo = false
    @Volatile private var gate: CountDownLatch? = null
    private var uploads = 0; private var providerReads = 0; private var pickerName = "edited.docx"
    private val intents = CopyOnWriteArrayList<Intent>()
    private lateinit var model: AppViewModel; private lateinit var repository: DsmRepository
    private val feature get() = model.officeDocuments
    private val input by lazy { File(app.cacheDir, "${profile.id}-input") }
    private val output by lazy { File(app.cacheDir, "${profile.id}-output") }
    private val importUri = Uri.parse("content://synthetic.office.provider/import")
    private val exportUri = Uri.parse("content://synthetic.office.provider/export")
    private val monitor = object : Instrumentation.ActivityMonitor() {
        override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? {
            if (intent.action !in setOf(Intent.ACTION_OPEN_DOCUMENT, Intent.ACTION_CREATE_DOCUMENT, Intent.ACTION_CHOOSER)) return null
            intents += Intent(intent)
            return if (intent.action == Intent.ACTION_CHOOSER) Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null)
            else Instrumentation.ActivityResult(Activity.RESULT_OK, Intent().setData(if (intent.action == Intent.ACTION_OPEN_DOCUMENT) importUri else exportUri))
        }
    }
    @Before fun prepare() {
        input.writeBytes(edited)
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = OfficeDocumentPolicy.mime(pickerName)
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor =
                MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf(pickerName)) }
            override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor = when (uri) {
                importUri -> { assertEquals("r", mode); providerReads++; ParcelFileDescriptor.open(input, ParcelFileDescriptor.MODE_READ_ONLY) }
                exportUri -> { assertEquals("wt", mode); ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_WRITE_ONLY) }
                else -> error("Unexpected synthetic URI")
            }
            override fun insert(uri: Uri, values: ContentValues?): Uri? = error("No insert")
            override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = error("No deletion")
            override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = error("No update")
        }
        provider.attachInfo(app, ProviderInfo().apply { authority = "synthetic.office.provider" })
        val resolver = ContentResolver.wrap(provider)
        InstrumentationRegistry.getInstrumentation().addMonitor(monitor)
        val session = DsmSession(profile.id, "synthetic-session")
        val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false, persistSession = true)
        val caps = mapOf("List" to 2, "MD5" to 1, "Download" to 2, "Upload" to 2, "CheckPermission" to 3)
            .mapKeys { "SYNO.FileStation.${it.key}" }.mapValues { (key, version) -> ApiCapability(key, "entry.cgi", 1, version) }
        val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), false) }, { error("Unexpected fallback") }, {})
        repository = DsmRepository(profile, session, DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(::respond).build()), caps, access)
        runBlocking { repository.refreshAccess() }; repository.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repository)
            OfficeDocumentFeatureModel::class.java.getDeclaredField("resolver").apply { isAccessible = true }.set(feature, { resolver })
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repository.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = "/synthetic")))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        compose.waitUntil(10_000) { model.workspace.value?.files is Loadable.Ready }
    }
    @After fun cleanup() {
        gate?.countDown(); gate = null
        compose.runOnIdle { feature.cancel() }
        compose.waitUntil(10_000) { !feature.state.value.busy }
        compose.runOnIdle { feature.invalidate(); model.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS)); recovery.removeProfile(profile.id); profiles.removeProfile(profile.id); profiles.setLastProfileId(previous) }
        InstrumentationRegistry.getInstrumentation().removeMonitor(monitor); input.delete(); output.delete()
    }
    @Test fun externalEditorInterruptionRequiresReceivingLocalChangesBeforeExplicitNasSave() {
        open()
        val row = feature.state.value.selected!!
        val transfer = OfficeDocumentTransfer(recovery.office)
        val editing = runBlocking { transfer.beginExternal(row.id, row.owner) }
        try {
            recovery.office.artifact(editing.id, editing.externalId!!).writeBytes(edited)
            compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.selected?.externalId != null }
            compose.onNodeWithTag("office_save").assertDoesNotExist()
            click("office_receive_external")
            assertEquals(0, uploads); assertNotNull(feature.state.value.selected?.externalId)
            runBlocking { transfer.closeExternal(editing, successful = false) }
            capture("office-external-interrupted")
            compose.activityRule.scenario.recreate()
            click("office_receive_external"); ready(OfficeDocumentPhase.CHANGED)
            assertNull(feature.state.value.selected?.externalId); assertNull(feature.state.value.notice); assertEquals(0, uploads)
            assertArrayEquals(original, recovery.office.artifact(row.id, row.originalId).readBytes())
            capture("office-external-received")
            click("office_save"); compose.onNodeWithTag("office_confirm_save").performClick(); ready(OfficeDocumentPhase.SAVED)
            assertEquals(1, uploads); assertArrayEquals(edited, remote)
        } finally {
            runBlocking { runCatching { transfer.closeExternal(editing, successful = false) } }
            recovery.office.get(row.id).takeIf { it.externalId != null }?.let { recovery.office.discard(it, discardExternal = true) }
        }
    }
    @Test fun editsSystemCopyThenConfirmsAndSavesOnlyOriginalTarget() {
        open(); capture("office-ready"); click("office_edit")
        compose.waitUntil(10_000) { intents.any { it.action == Intent.ACTION_CHOOSER } && !feature.state.value.busy }
        assertArrayEquals(original, output.readBytes()); assertEquals(0, uploads)
        val picker = intents.first { it.action == Intent.ACTION_CREATE_DOCUMENT }
        assertEquals("document.docx", picker.getStringExtra(Intent.EXTRA_TITLE)); assertEquals(OfficeDocumentPolicy.mime("document.docx"), picker.type)
        val edit = intents.last { it.action == Intent.ACTION_CHOOSER }.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
        assertEquals(Intent.ACTION_EDIT, edit.action); assertEquals(exportUri, edit.data)
        assertTrue(edit.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0)
        importEdited(); ready(OfficeDocumentPhase.CHANGED); capture("office-changed")
        click("office_save"); compose.onNodeWithText(text(R.string.office_save_confirm, "document.docx", "Office NAS")).assertExists(); capture("office-confirm")
        compose.onNodeWithText(text(R.string.cancel)).performClick(); assertEquals(0, uploads)
        click("office_save"); compose.onNodeWithTag("office_confirm_save").performClick(); ready(OfficeDocumentPhase.SAVED)
        assertEquals(1, uploads); assertArrayEquals(edited, remote); capture("office-saved")
        click("office_finish"); compose.onNodeWithTag("office_confirm_finish").performClick()
        compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.selectedId == null }
        assertTrue(recovery.office.records(repository.owner!!).isEmpty()); assertArrayEquals(edited, remote)
    }
    @Test fun unchangedCopyAndReadOnlyOpenDoNotUpload() {
        input.writeBytes(original); open(); importEdited(); ready(OfficeDocumentPhase.UNCHANGED)
        compose.onNodeWithTag("office_save").assertDoesNotExist(); capture("office-unchanged")
        click("office_open"); compose.waitUntil(10_000) { intents.any { it.action == Intent.ACTION_CHOOSER } }
        val view = intents.last().getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
        assertEquals(Intent.ACTION_VIEW, view.action); assertTrue(view.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertEquals(0, view.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION); assertEquals(0, uploads)
    }
    @Test fun changedOriginalStopsSaveAndEditedCopyCanStillBeExported() {
        open(); importEdited(); ready(OfficeDocumentPhase.CHANGED); remote = ByteArray(original.size) { 33 }
        click("office_save"); compose.onNodeWithTag("office_confirm_save").performClick(); ready(OfficeDocumentPhase.CONFLICT)
        assertEquals(0, uploads); compose.onNodeWithTag("office_save").assertDoesNotExist(); capture("office-conflict")
        compose.onAllNodesWithText(text(R.string.office_changed_hint), substring = true).assertCountEquals(1)
        click("office_export"); compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.notice != null }
        assertArrayEquals(edited, output.readBytes()); assertEquals(0, uploads)
    }
    @Test fun unknownSaveReopensAfterRecreationAndRefreshNeverUploadsAgain() {
        open(); importEdited(); ready(OfficeDocumentPhase.CHANGED); corruptUpload = true
        click("office_save"); compose.onNodeWithTag("office_confirm_save").performClick(); ready(OfficeDocumentPhase.UNKNOWN)
        val id = feature.state.value.selectedId!!; capture("office-unknown")
        compose.activityRule.scenario.recreate()
        compose.runOnIdle { feature.dismiss(); feature.show() }
        compose.waitUntil(10_000) { !feature.state.value.busy }
        compose.onNode(hasText("document.docx") and hasAnyAncestor(hasTestTag("office_dialog"))).performClick()
        assertEquals(id, feature.state.value.selectedId); compose.onNodeWithTag("office_save").assertDoesNotExist()
        compose.onNodeWithTag("office_import").assertDoesNotExist(); compose.onNodeWithTag("office_finish").assertDoesNotExist()
        remote = edited; click("office_refresh"); ready(OfficeDocumentPhase.SAVED); assertEquals(1, uploads); capture("office-restored")
    }
    @Test fun revokedPermissionRejectsVisibleConfirmationAndLatePicker() {
        open(); importEdited(); ready(OfficeDocumentPhase.CHANGED); click("office_save")
        allowed = false; runBlocking { repository.refreshAccess() }
        compose.runOnIdle {
            ApprovedUiFixture.setState(model, model.workspace.value!!.copy(availability = repository.availability()))
            feature.authorizationChanged(); feature.save()
        }
        compose.onNodeWithTag("office_dialog").assertDoesNotExist(); assertEquals(0, uploads)
        allowed = true; runBlocking { repository.refreshAccess() }
        val reads = providerReads
        compose.runOnIdle { ApprovedUiFixture.setState(model, model.workspace.value!!.copy(availability = repository.availability())); feature.show() }
        compose.waitUntil(10_000) { !feature.state.value.busy }
        compose.runOnIdle {
            feature.select(recovery.office.records(repository.owner!!).single().id); feature.requestPicker(OfficePickerKind.IMPORT)
            val ticket = feature.state.value.picker!!.token
            feature.invalidate(); feature.pickerResult(ticket, importUri)
        }
        assertEquals(reads, providerReads); assertEquals(0, uploads)
    }
    @Test fun loadingFailureRetryEmptyAndWrongFormatUseNativeStates() {
        compose.runOnIdle { feature.show() }; compose.waitUntil(10_000) { !feature.state.value.busy }
        compose.onNodeWithText(text(R.string.office_empty)).assertIsDisplayed(); capture("office-empty")
        compose.runOnIdle { feature.dismiss() }; gate = CountDownLatch(1); failInfo = true
        compose.onNodeWithText("document.docx").performClick()
        compose.waitUntil(10_000) { feature.state.value.records is Loadable.Loading }; capture("office-loading")
        gate?.countDown(); gate = null; compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.failure != null }
        compose.onNodeWithTag("office_retry").assertExists(); capture("office-error")
        failInfo = false; click("office_retry"); ready(OfficeDocumentPhase.READY)
        pickerName = "wrong.xlsx"; importEdited(); compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.failure != null }
        assertEquals(DsmErrorKind.OFFICE_FORMAT, feature.state.value.failure?.kind); assertEquals(0, providerReads); assertEquals(0, uploads)
        capture("office-format-error")
    }
    private fun open() { compose.onNodeWithText("document.docx").performClick(); ready(OfficeDocumentPhase.READY) }
    private fun importEdited() { click("office_import") }
    private fun click(tag: String) { compose.onNodeWithTag(tag).performScrollTo().performClick() }
    private fun ready(phase: OfficeDocumentPhase) { compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.selected?.phase == phase } }
    private fun text(id: Int, vararg values: Any) = compose.activity.getString(id, *values)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val rendered = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { compose.activity.window.decorView.postOnAnimation {
            compose.activity.window.decorView.postOnAnimation { rendered.countDown() }
        } }
        check(rendered.await(2, TimeUnit.SECONDS))
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "workspace-office-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    private fun item() = FileItem("/synthetic/document.docx", "document.docx", false, remote.size.toLong(), 100,
        canRead = true, canWrite = true, canDelete = true, mountPointType = "normal")
    private fun respond(chain: Interceptor.Chain): Response {
        val request = chain.request(); val fields = request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }.toMutableMap()
        when (val body = request.body) {
            is FormBody -> (0 until body.size).forEach { fields[body.name(it)] = body.value(it) }
            is MultipartBody -> {
                var uploaded: ByteArray? = null; var filename: String? = null
                body.parts.forEach { part ->
                    val header = part.headers?.get("Content-Disposition").orEmpty()
                    val key = Regex("name=\"([^\"]+)\"").find(header)?.groupValues?.get(1).orEmpty()
                    val name = Regex("filename=\"([^\"]+)\"").find(header)?.groupValues?.get(1)
                    val buffer = Buffer(); part.body.writeTo(buffer)
                    if (name != null) { filename = name; uploaded = buffer.readByteArray() } else fields[key] = buffer.readUtf8()
                }
                assertNull(request.url.queryParameter("_sid")); assertNull(request.url.queryParameter("SynoToken"))
                assertEquals("/synthetic", fields["path"]); assertEquals("true", fields["overwrite"]); assertEquals("document.docx", filename)
                assertEquals(OfficeDocumentPhase.SAVING, recovery.office.records(repository.owner!!).single().phase)
                uploads++; remote = if (corruptUpload) byteArrayOf(3, 2, 1) else checkNotNull(uploaded)
            }
        }
        val data = when (fields.getValue("api")) {
            "SYNO.FileStation.List" -> when (fields["method"]) {
                "getinfo" -> {
                    gate?.await(10, TimeUnit.SECONDS)
                    if (failInfo) throw IOException("Synthetic file read failed")
                    buildJsonObject { putJsonArray("files") { add(fileJson()) } }
                }
                "list" -> buildJsonObject { put("offset", 0); put("total", 1); putJsonArray("files") { add(fileJson()) } }
                "list_share" -> buildJsonObject { put("offset", 0); put("total", 0); putJsonArray("shares") {} }
                else -> error("Unexpected synthetic list")
            }
            "SYNO.FileStation.MD5" -> if (fields["method"] == "start") buildJsonObject { put("taskid", "synthetic-md5") }
                else buildJsonObject { put("finished", true); put("md5", MessageDigest.getInstance("MD5").digest(remote).joinToString("") { "%02x".format(it) }) }
            "SYNO.FileStation.CheckPermission", "SYNO.FileStation.Upload", "SYNO.FileStation.Download" -> buildJsonObject {}
            else -> error("Unexpected synthetic API")
        }
        val body = if (fields["api"] == "SYNO.FileStation.Download") remote.toResponseBody("application/octet-stream".toMediaType())
            else buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body).build()
    }
    private fun fileJson() = buildJsonObject {
        val item = item(); put("path", item.path); put("name", item.name); put("isdir", false); put("size", item.size)
        putJsonObject("additional") { put("size", item.size); put("mount_point_type", "normal"); putJsonObject("time") { put("mtime", 100) }
            putJsonObject("perm") { put("read", true); put("write", true); put("delete", true) } }
    }
}
