package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.core.app.ActivityOptionsCompat
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*

/** 正式仓储/媒体解码/系统文档API；选择器结果来自合成Registry，文件写入测试APK提供器。 */
class SynologyPhotosExportUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver get() = context.contentResolver
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var owner = WorkspaceOwner("export-${UUID.randomUUID()}", "synthetic", UUID.randomUUID().toString())
    private val profiles by lazy { io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore(context) }
    private var previousProfile: String? = null
    private val editStore by lazy { SynologyPhotoEditStore(context) }
    private val albumStore by lazy { SynologyPhotoAlbumStore(context) }
    private lateinit var model: SynologyPhotosModel
    private var filename = "Synthetic.png"
    private var home = true; private var team = true; private var download = true; private var converted = true
    private var albumOwner = 41L; private var albumDownload = true; private var corrupt = false
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val media = CopyOnWriteArrayList<Request>()
    private val png by lazy { image(Bitmap.CompressFormat.PNG) }
    private val jpeg by lazy { image(Bitmap.CompressFormat.JPEG) }
    private val zip by lazy { ByteArrayOutputStream().also { out -> java.util.zip.ZipOutputStream(out).use { it.putNextEntry(java.util.zip.ZipEntry("Synthetic.png")); it.write(png); it.closeEntry() } }.toByteArray() }
    private var pending: Pair<Int, Intent>? = null
    private val registry = object : ActivityResultRegistry() {
        override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
            check(pending == null)
            pending = requestCode to contract.createIntent(context, input)
        }
    }
    private val registryOwner = object : ActivityResultRegistryOwner { override val activityResultRegistry = registry }
    private val tree get() = DocumentsContract.buildTreeDocumentUri(SynologyPhotoExportTestProvider.AUTHORITY, "root")
    private val parent get() = DocumentsContract.buildDocumentUriUsingTree(tree, "root")

    @Before fun reset() {
        resolver.call(SynologyPhotoExportTestProvider.AUTHORITY, "reset", null, null)
        previousProfile = profiles.lastProfileId()
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "synthetic")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic"), null, false, persistSession = true)
    }
    @After fun cleanup() {
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        editStore.removeProfile(owner.profileId); albumStore.removeProfile(owner.profileId)
        profiles.removeProfile(owner.profileId); profiles.setLastProfileId(previousProfile)
        resolver.call(SynologyPhotoExportTestProvider.AUTHORITY, "reset", null, null)
    }

    @Test fun 单张原件经过文件选择器再保存且保持图库月份与选择() {
        show(); ready(); compose.runOnIdle { model.edits!!.toggle(model.state.value.items.first()) }
        val before = model.state.value; val selected = model.edits!!.state.value.selected
        openPreview(); savePreview(); capture("single-formats"); choose(SynologyPhotoDownloadFormat.ORIGINAL)
        picker(); assertEquals(Intent.ACTION_CREATE_DOCUMENT, pending!!.second.action)
        assertEquals("Synthetic.png", pending!!.second.getStringExtra(Intent.EXTRA_TITLE))
        assertEquals(0, model.exports.state.value.saved)
        compose.runOnIdle { model.deactivate(preservePreparedExport = true); model.activate() }
        assertEquals(before.paginationKey, model.state.value.paginationKey); assertEquals(before.selectedMonth, model.state.value.selectedMonth)
        finishPicker(); completed(1); capture("single-saved")
        assertArrayEquals(png, bytes(documents().getValue("Synthetic.png")))
        assertEquals(selected, model.edits!!.state.value.selected); assertEquals(before.navigation, model.state.value.navigation)
        assertEquals(1, media.count { fields(it)["method"] == "download" })
    }

    @Test fun 多选逐张保存同名另存真实格式与原格式保留计数() {
        show(); ready()
        val existing = create("Synthetic.png"); resolver.openOutputStream(existing)!!.use { it.write("keep".toByteArray()) }
        compose.runOnIdle { model.edits!!.selectLoaded(model.state.value.items) }
        val before = model.state.value; val selected = model.edits!!.state.value.selected
        compose.onNodeWithTag("photos_export_selected").assertIsDisplayed().performClick(); capture("batch-formats")
        compose.onNodeWithTag("photos_export_ORIGINAL_SIZE_JPEG").assertDoesNotExist()
        choose(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG); picker()
        assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, pending!!.second.action); assertEquals(0, media.count { fields(it)["method"] == "download" })
        finishPicker(); completed(3); capture("batch-saved")
        val saved = documents()
        assertEquals(setOf("Synthetic.png", "Synthetic (1).png", "Other.jpg", "Synthetic (2).png"), saved.keys)
        assertEquals("keep", bytes(existing).decodeToString()); assertArrayEquals(png, bytes(saved.getValue("Synthetic (1).png")))
        assertArrayEquals(jpeg, bytes(saved.getValue("Other.jpg"))); assertEquals(2, model.exports.state.value.retainedOriginals)
        assertEquals(before.paginationKey, model.state.value.paginationKey); assertEquals(selected, model.edits!!.state.value.selected)
    }

    @Test fun 原尺寸能力与完整JPEG真实解码拒绝截断内容且转换不重发() {
        filename = "Conversion.heic"; show(); ready(); openPreview(); savePreview(); capture("original-jpeg-format")
        choose(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG); picker(); finishPicker(); completed(1)
        val file = documents().getValue("Conversion.jpg"); assertArrayEquals(jpeg, bytes(file)); assertEquals(1, calls.count { it.method == "convert" }); capture("original-jpeg-saved")
        closeResult(); compose.runOnIdle { model.preview.closePreview(); corrupt = true }; openPreview(); savePreview(); choose(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG)
        failed(); capture("truncated-jpeg"); assertNull(pending); assertEquals(1, documents().size); assertEquals(2, calls.count { it.method == "convert" })
        closeResult(); compose.runOnIdle { model.preview.closePreview(); converted = false; model.refresh() }; ready(); openPreview(); savePreview()
        compose.onNodeWithTag("photos_export_ORIGINAL_SIZE_JPEG").assertDoesNotExist(); capture("format-unavailable")
    }

    @Test fun 协作整相册在原空间关闭时保存完整ZIP且不借贡献权绕过下载限制() {
        home = false; team = false; albumOwner = 99; show(); ready(); openAlbum()
        menu(R.string.sp_export_album); capture("album-formats"); choose(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG)
        picker(); finishPicker(); completed(1); capture("album-zip-saved")
        val request = media.single { fields(it)["method"] == "download" }
        assertEquals("POST", request.method); assertNull(request.url.query)
        assertEquals("SYNO.Foto.Browse.Album", fields(request)["api"]); assertEquals("\"synthetic-passphrase\"", fields(request)["passphrase"])
        assertNull(fields(request)["item_id"]); assertArrayEquals(zip, bytes(documents().getValue("Synthetic album.zip")))
        closeResult(); albumDownload = false; menu(R.string.sp_export_album); choose(SynologyPhotoDownloadFormat.ORIGINAL)
        failed(); capture("album-download-denied"); assertNull(pending); assertEquals(1, documents().size)
    }

    @Test fun 整目录与同级混选使用目录编号不会替换成当前页面照片() {
        show(); ready(); compose.onNode(hasText(text(R.string.sp_library_folders)) and hasClickAction()).performClick(); ready()
        menu(R.string.sp_export_folder); choose(SynologyPhotoDownloadFormat.ORIGINAL); picker(); finishPicker(); completed(1); capture("folder-zip-saved")
        assertEquals("[9]", fields(media.last { fields(it)["method"] == "download" })["folder_id"])
        assertNull(fields(media.last { fields(it)["method"] == "download" })["item_id"])
        closeResult(); compose.runOnIdle { model.edits!!.selectMode(true) }
        compose.onNodeWithTag("photos_collection_10").performClick()
        compose.runOnIdle { model.edits!!.toggle(model.state.value.items.first()) }
        compose.onNodeWithTag("photos_export_selected").assertIsDisplayed().performClick(); choose(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG)
        picker(); finishPicker(); completed(1); capture("mixed-zip-saved")
        val mixed = fields(media.last { fields(it)["method"] == "download" })
        assertEquals("[10]", mixed["folder_id"]); assertEquals("[1]", mixed["item_id"])
        assertEquals(1, model.edits!!.state.value.selectedFolders.size); assertEquals(1, model.edits!!.state.value.selected.size)
    }

    @Test fun 批量目标创建失败保留已完成文件并准确显示部分完成() {
        show(); ready(); compose.runOnIdle { model.edits!!.selectLoaded(model.state.value.items) }
        compose.onNodeWithTag("photos_export_selected").assertIsDisplayed().performClick(); choose(SynologyPhotoDownloadFormat.ORIGINAL); picker()
        resolver.call(SynologyPhotoExportTestProvider.AUTHORITY, "failAfter", "1", null)
        finishPicker(); failed(); capture("partial-save")
        compose.onNodeWithText(text(R.string.sp_export_retry)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.sp_media_failed)).assertDoesNotExist()
        assertEquals(1, model.exports.state.value.saved); assertEquals(3, model.exports.state.value.total)
        assertEquals(setOf("Synthetic.png"), documents().keys); assertArrayEquals(png, bytes(documents().getValue("Synthetic.png")))
        assertEquals(2, media.count { fields(it)["method"] == "download" })
    }

    @Test fun 取消选择器和撤权后迟到结果清理新空文档且不报告保存成功() {
        show(); ready(); openPreview(); savePreview(); choose(SynologyPhotoDownloadFormat.ORIGINAL); picker()
        finishPicker(cancel = true); compose.waitUntil(5_000) { model.exports.state.value.cancelled }; capture("picker-cancelled")
        assertEquals(0, model.exports.state.value.saved); assertTrue(documents().isEmpty()); closeResult()
        openPreview(); savePreview(); choose(SynologyPhotoDownloadFormat.ORIGINAL); picker()
        compose.runOnIdle { model.revokeAccess() }
        finishPicker(); compose.waitUntil(5_000) { documents().isEmpty() }
        assertEquals(SynologyPhotoExportPhase.IDLE, model.exports.state.value.phase); assertEquals(0, model.exports.state.value.saved); capture("revoked-picker")
    }

    @Test fun 文档复制中途取消仅删除本次不完整文件既有文件保持原样() {
        val existing = create("Existing.txt"); resolver.openOutputStream(existing)!!.use { it.write("keep".toByteArray()) }
        val file = File(context.cacheDir, "synthetic-copy-${UUID.randomUUID()}").apply { writeBytes(ByteArray(200_000) { 1 }) }
        try {
            runBlocking {
                val destination = SynologyPhotoDocumentDestination(resolver, tree, true)
                var checks = 0
                try { destination.save(file, "Cancelled.dat", "application/octet-stream") { if (++checks == 7) throw CancellationException() }; fail() }
                catch (_: CancellationException) { }
                assertEquals(setOf("Existing.txt"), documents().keys); assertEquals("keep", bytes(existing).decodeToString())
                try { SynologyPhotoDocumentDestination(resolver, existing, false).save(file, "Existing.txt", "text/plain") {}; fail() }
                catch (_: java.io.IOException) { }
                assertEquals("keep", bytes(existing).decodeToString())
            }
        } finally { file.delete() }
    }

    private fun show() {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Sharing.Passphrase", "Download", "BackgroundTask.File", "BackgroundTask.Info").map {
            ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON")
        } }.associateBy { it.name }
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "synthetic")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); media += request; val fields = fields(request)
            val archive = fields["api"] == "SYNO.Foto.Browse.Album" || fields["folder_id"] != null
            val convertedImage = fields["download_type"] == "\"original_size_jpeg\"" || fields["download_type"] == "\"optimized_jpeg\"" && fields["item_id"] == "[2]"
            val data = when { archive -> zip; convertedImage -> if (corrupt) jpeg.copyOf(jpeg.size / 2) else jpeg; fields["download_type"] == "\"source\"" && fields["item_id"] == "[2]" -> jpeg; else -> png }
            val type = if (archive) "application/zip" else if (convertedImage || data === jpeg) "image/jpeg" else "image/png"
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic").header("Content-Type", type).body(data.toResponseBody(type.toMediaType())).build()
        }.build()
        val transport = SynologyPhotosMediaTransport(profile, DsmSession(owner.profileId, "synthetic"), profile.address, http)
        val repository = SynologyPhotosRepository(owner.profileId, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call; response(call)
        }, transport)
        model = SynologyPhotosModel(repository, scope, pageSize = 3, uploadOwner = owner, editStore = editStore, albumStore = albumStore, requireUploadOwner = { profiles.requireCurrentOwner(owner) }, execution = io.github.qwertyuiop1995.dsmnativeclient.background.AndroidWorkspaceExecution(context))
        compose.setContent { CompositionLocalProvider(LocalActivityResultRegistryOwner provides registryOwner) {
            LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
            } }
        } }
    }
    private fun response(call: Call): JsonObject = when {
        call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"entry","ame_status":{"has_hevc":true}}""")
        call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_converted_original_jpeg":$converted}""")
        call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$team}""")
        call.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2020,"month":3,"day":1,"item_count":3}]}]}""")
        call.api.endsWith("Browse.Category") -> list(emptyList())
        call.method == "get_album_list_order" -> obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc"}""")
        call.method == "get_album_list_display" -> obj("""{"album_display_type":"all_album"}""")
        call.api.endsWith("Browse.Album") -> list(listOf(obj("""{"id":7,"name":"Synthetic album","type":"condition","owner_user_id":$albumOwner,"sort_by":"takentime","sort_direction":"asc","passphrase":"synthetic-passphrase"}""")))
        call.api.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"download":$albumDownload,"upload":true}}""")
        call.api.endsWith("Browse.Folder") -> if (call.method == "list") list(if (call.fields["id"] == "9" && call.fields["offset"] == "0") listOf(folder(10)) else emptyList())
            else JsonObject(mapOf("folder" to folder(call.fields["id"]?.toLong() ?: 9)))
        call.api.endsWith("Browse.Item") -> if (call.method == "get") list(Json.parseToJsonElement(call.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long) })
            else list((1L..3).drop(call.fields.getValue("offset").toInt()).take(call.fields.getValue("limit").toInt()).map(::photo))
        call.api.endsWith("Download") && call.method == "convert" -> obj("{}")
        else -> error("Unexpected synthetic API")
    }
    private fun folder(id: Long) = obj("""{"id":$id,"name":"${if (id == 10L) "/child" else "/"}","parent":${if (id == 10L) 9 else 0},"additional":{"access_permission":{"view":true,"download":$download,"manage":true},"thumbnail":[]}}""")
    private fun photo(id: Long) = obj("""{"id":$id,"filename":"${if (id == 2L) "Other.jpg" else filename}","filesize":${if (id == 2L) jpeg.size else png.size},"time":1583064000,"indexed_time":1583064000,"folder_id":9,"type":"photo","owner_user_id":41,"additional":{"provider_user_id":41,"thumbnail":{"unit_id":$id,"cache_key":"synthetic"},"orientation":1,"resolution":{"width":160,"height":120}}}""")
    private fun image(format: Bitmap.CompressFormat): ByteArray {
        val bitmap = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(44, 128, 170))
        return ByteArrayOutputStream().use { out -> bitmap.compress(format, 95, out); bitmap.recycle(); out.toByteArray() }
    }
    private fun fields(request: Request): Map<String, String> = (request.body as? FormBody)?.let { form -> (0 until form.size).associate { form.name(it) to form.value(it) } }
        ?: request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading && !model.state.value.loadingMore }; assertNull(model.state.value.error); compose.waitForIdle() }
    private fun openPreview() { compose.runOnIdle { model.preview.open(model.state.value.items.first()) }; compose.waitUntil(5_000) { model.preview.state.value.imageReady } }
    private fun savePreview() {
        compose.onNodeWithTag("photos_preview_actions").performScrollToNode(hasContentDescription(text(R.string.sp_media_save)))
        compose.onNodeWithContentDescription(text(R.string.sp_media_save)).assertIsDisplayed().performClick()
    }
    private fun menu(label: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithText(text(label)).performScrollTo().performClick() }
    private fun choose(format: SynologyPhotoDownloadFormat) { compose.onNodeWithTag("photos_export_${format.name}").performClick() }
    private fun picker() { compose.waitUntil(5_000) { pending != null } }
    private fun finishPicker(cancel: Boolean = false) {
        val result = pending!!; pending = null
        val uri = if (cancel) null else if (result.second.action == Intent.ACTION_OPEN_DOCUMENT_TREE) tree else create(result.second.getStringExtra(Intent.EXTRA_TITLE)!!)
        compose.runOnIdle { registry.dispatchResult(result.first, if (cancel) Activity.RESULT_CANCELED else Activity.RESULT_OK, Intent().setData(uri)) }
    }
    private fun completed(count: Int) { compose.waitUntil(8_000) { model.exports.state.value.phase == SynologyPhotoExportPhase.FINISHED }; assertNull(model.exports.state.value.error); assertEquals(count, model.exports.state.value.saved); assertFalse(model.exports.state.value.cancelled) }
    private fun failed() { compose.waitUntil(8_000) { model.exports.state.value.phase == SynologyPhotoExportPhase.FINISHED }; assertNotNull(model.exports.state.value.error) }
    private fun closeResult() { compose.onNodeWithText(text(R.string.sp_media_close)).performClick(); compose.waitUntil(5_000) { model.exports.state.value.phase == SynologyPhotoExportPhase.IDLE } }
    private fun openAlbum() { compose.onNodeWithText("Synthetic album").performClick(); ready() }
    private fun create(name: String) = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", name)!!
    private fun bytes(uri: Uri) = resolver.openInputStream(uri)!!.use { it.readBytes() }
    private fun documents(): Map<String, Uri> {
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        return resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, "root"), columns, null, null, null)!!.use { cursor ->
            buildMap { while (cursor.moveToNext()) put(cursor.getString(0), DocumentsContract.buildDocumentUri(SynologyPhotoExportTestProvider.AUTHORITY, cursor.getString(1))) }
        }
    }
    private fun text(id: Int) = context.getString(id)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val target = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val image = target.captureToImage().asAndroidBitmap()
        File(context.getExternalFilesDir(null), "workspace-photos-export-review/$name.png").apply { parentFile!!.mkdirs() }.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }; image.recycle()
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    }
}
