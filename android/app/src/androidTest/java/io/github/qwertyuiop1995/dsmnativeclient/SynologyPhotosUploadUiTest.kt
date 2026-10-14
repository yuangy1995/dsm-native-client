package io.github.qwertyuiop1995.dsmnativeclient

import android.content.ContentValues
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.*
import org.junit.Assert.*

/** 生产图库、上传仓储、加密恢复和系统选择器；HTTP/照片均为合成资料，无真实 NAS 请求。 */
class SynologyPhotosUploadUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profile = NasProfile("photos-upload-test-${UUID.randomUUID()}", "Synthetic Photos", "https://photos.example.invalid", "synthetic")
    private val profiles by lazy { io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore(context) }
    private var previousProfile: String? = null
    private lateinit var owner: WorkspaceOwner
    @Before fun bindExecutionOwner() {
        previousProfile = profiles.lastProfileId()
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-session", "synthetic-token"), null, false, persistSession = true)
    }
    private lateinit var store: SynologyPhotoUploadStore
    private lateinit var repository: SynologyPhotosRepository
    private lateinit var repositoryFactory: () -> SynologyPhotosRepository
    private lateinit var model: SynologyPhotosModel
    private var modelEpoch by mutableIntStateOf(0)
    private val uploads get() = model.uploads!!
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val sent = CopyOnWriteArrayList<Call>()
    private val httpRequests = CopyOnWriteArrayList<Request>()
    private val originals = CopyOnWriteArrayList<Uri>()
    private val remoteItems = ConcurrentHashMap<Long, JsonObject>()
    private val remoteFolders = ConcurrentHashMap<Long, Pair<Long, String>>()
    private var home = true
    private var shared = "management"
    private var uploadAllowed = true
    private var omitReceipt = false
    private var failRead = false
    private var gate: CompletableDeferred<Unit>? = null
    private val imageBytes by lazy {
        val bitmap = Bitmap.createBitmap(20, 16, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.rgb(70, 120, 190)) }
        ByteArrayOutputStream().use { output -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray() }
    }

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        originals.forEach { context.contentResolver.delete(it, null, null) }
        if (::store.isInitialized) store.removeProfile(profile.id)
        profiles.removeProfile(profile.id); profiles.setLastProfileId(previousProfile)
    }

    @Test fun 系统选择照片后先显示固定批次再上传并保留原件() {
        show(); openUpload(); capture("form")
        val name = "LanStash-Synthetic-${UUID.randomUUID().toString().take(8)}.png"
        val uri = createMedia(name)
        compose.onNodeWithTag("photos_upload_select_files").performScrollTo().assertIsEnabled().performClick()
        val node = awaitDocument(name)
        var click: AccessibilityNodeInfo? = node
        while (click != null && !click.isClickable) click = click.parent
        assertTrue("系统选择器应能选择刚创建的合成图片", click?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true)
        awaitPrepared()
        val row = uploads.state.value.selected!!
        assertEquals(SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.PERSONAL), row.target)
        assertEquals(name, row.entries.single().filename)
        assertArrayEquals(imageBytes, store.artifact(row.id, row.entries.single().id).readBytes())
        assertEquals(0, android.system.Os.stat(store.artifact(row.id, row.entries.single().id).path).st_mode and 0b111111)
        assertTrue(sent.isEmpty()); capture("prepared")
        compose.onNodeWithTag("photos_upload_start").assertIsDisplayed().performClick(); awaitFinished()
        assertEquals(1, sent.size); assertEquals(1, httpRequests.size)
        assertTrue(httpRequests.single().body!!.isOneShot()); assertNull(httpRequests.single().url.query)
        assertEquals("\"timeline\"", sent.single().fields["uploadDestination"])
        assertFalse(store.artifact(row.id, row.entries.single().id).exists())
        context.contentResolver.openInputStream(uri)!!.use { assertArrayEquals(imageBytes, it.readBytes()) }
        capture("completed")
    }

    @Test fun 无原照片库权限的相册贡献者也可上传且不重复加入() {
        home = false; shared = "none"
        show()
        compose.onNodeWithText("Synthetic album").performClick(); ready(); openUpload()
        assertEquals(SynologyPhotoUploadTarget.Album(71), uploads.state.value.draft?.target)
        stage(listOf(source()))
        compose.onNodeWithTag("photos_upload_start").performClick(); awaitFinished()
        assertEquals("\"synthetic-share\"", sent.single().fields["passphrase"])
        assertFalse(sent.single().fields.containsKey("album_id")); assertFalse(sent.single().fields.containsKey("uploadDestination"))
        assertTrue(calls.none { it.method == "add_item" })
        capture("contributor-album")
    }

    @Test fun 保留目录结构使用确认后的父编号并展示全部项目() {
        show(); openUpload()
        compose.runOnIdle { uploads.selectTarget(SynologyPhotoUploadTarget.Folder(SynologyPhotoSpace.SHARED, 9), "Synthetic folder") }
        stage(listOf(source("Trip/Sub", "first.png"), source("Trip", "second.png")))
        capture("folder-ready")
        compose.onNodeWithTag("photos_upload_start").performClick(); awaitFinished()
        val created = calls.filter { it.method == "create" }
        assertEquals(2, created.size); assertTrue(created.all { it.api == "SYNO.FotoTeam.Browse.Folder" })
        assertEquals("9", created[0].fields["target_id"])
        assertEquals("301", created[1].fields["target_id"])
        assertEquals(listOf("302", "301"), sent.map { it.fields["target_folder_id"] })
        assertTrue(sent.all { it.api == "SYNO.FotoTeam.Upload.Item" })
        assertEquals(2, uploads.state.value.selected?.completedCount)
        capture("folder-completed")
    }

    @Test fun 丢失回执保留记录重新打开后只读恢复且不重传() {
        omitReceipt = true
        show(); openUpload(); stage(listOf(source()))
        compose.onNodeWithTag("photos_upload_start").performClick()
        compose.waitUntil(10_000) { !uploads.state.value.working && uploads.state.value.selected?.requiresReview == true }
        assertEquals(1, sent.size)
        compose.onNodeWithText(text(R.string.sp_upload_pending)).assertIsDisplayed(); capture("pending")
        val batch = uploads.state.value.selected!!
        compose.runOnIdle {
            model.close()
            repository = repositoryFactory()
            model = createModel()
            modelEpoch++
        }
        // 同一内容窗口改用重新构建的生产上传模型，恢复时没有自动写请求。
        compose.runOnIdle { model.activate() }
        ready()
        val restored = model.uploads!!
        compose.runOnIdle { restored.showQueue() }
        compose.waitUntil(10_000) { restored.state.value.records.any { it.id == batch.id } }
        compose.runOnIdle { restored.selectBatch(batch.id); restored.start(batch.id, reviewOnly = true) }
        compose.waitUntil(10_000) { !restored.state.value.working }
        assertEquals(1, sent.size)
        assertTrue(restored.state.value.selected!!.requiresReview)
        assertTrue(calls.none { it.api.endsWith("Browse.Item") && it.method == "get" })
    }

    @Test fun 读取失败和空任务有恢复操作且被拒绝目标不会提交() {
        show(); openUpload()
        gate = CompletableDeferred()
        compose.runOnIdle { uploads.stage(uploads.state.value.draft!!) { gate!!.await(); listOf(source()) } }
        compose.onNodeWithText(text(R.string.sp_upload_inspecting)).assertIsDisplayed(); capture("import-loading")
        compose.onNodeWithText(text(R.string.cancel)).performClick()
        compose.waitUntil(10_000) { !uploads.state.value.working }
        assertTrue(uploads.state.value.records.isEmpty()); assertTrue(sent.isEmpty())
        gate?.complete(Unit); gate = null
        failRead = true
        compose.onNodeWithText(text(R.string.sp_upload_choose_album)).performScrollTo().performClick()
        compose.waitUntil(10_000) { uploads.state.value.error != null && !uploads.state.value.albumsLoading }
        capture("read-error")
        failRead = false
        compose.onNodeWithText(text(R.string.sp_retry)).performScrollTo().performClick()
        compose.waitUntil(10_000) { uploads.state.value.albums.isNotEmpty() }
        compose.onNodeWithText("Synthetic album").performScrollTo().performClick()
        uploadAllowed = false
        stage(listOf(source()), expectPrepared = false)
        compose.waitUntil(10_000) { !uploads.state.value.working && uploads.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_upload_permission_error)).assertIsDisplayed()
        assertTrue(sent.isEmpty()); assertTrue(uploads.state.value.records.isEmpty()); capture("permission-error")
        compose.runOnIdle { uploads.showQueue() }
        compose.onNodeWithText(text(R.string.sp_upload_queue_empty)).assertIsDisplayed(); capture("empty-queue")
    }

    @Test fun 上传中暂停保留不明项目且重新打开入口不会改目标() {
        show(); openUpload()
        compose.runOnIdle { uploads.selectTarget(SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.SHARED)) }
        stage(listOf(source()))
        gate = CompletableDeferred()
        compose.onNodeWithTag("photos_upload_start").performClick()
        compose.waitUntil(10_000) { uploads.state.value.working && sent.size == 1 }
        assertTrue(io.github.qwertyuiop1995.dsmnativeclient.background.WorkspaceExecutionRegistry.shared.entries.value.any { it.activity == io.github.qwertyuiop1995.dsmnativeclient.background.WorkspaceExecutionActivity.PHOTO_UPLOAD })
        capture("uploading")
        compose.onNodeWithText(text(R.string.sp_upload_pause)).performClick()
        compose.waitUntil(10_000) { !uploads.state.value.working && uploads.state.value.selected?.requiresReview == true }
        capture("paused")
        compose.runOnIdle { uploads.dismiss(); uploads.open(SynologyPhotoNavigation(), model.state.value.access) }
        compose.waitUntil(10_000) { !uploads.state.value.loading }
        compose.onNodeWithText(context.getString(R.string.sp_upload_queue_count, 1)).performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.sp_source_shared)).performClick()
        compose.onNodeWithText(text(R.string.sp_upload_refresh)).performClick()
        compose.waitUntil(10_000) { !uploads.state.value.working }
        assertEquals(SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.SHARED), uploads.state.value.selected!!.target)
        assertEquals(1, sent.size)
        capture("paused-restored")
    }

    private fun show() {
        store = SynologyPhotoUploadStore(context)
        val session = DsmSession(profile.id, "synthetic-session", "synthetic-token")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); httpRequests += request
            request.body!!.writeTo(Buffer())
            val payload = if (omitReceipt) "{}" else "{\"id\":${100 + sent.size},\"action\":\"add\"}"
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .body("{\"success\":true,\"data\":$payload}".toResponseBody("application/json".toMediaType())).build()
        }.build()
        val api = DsmApiClient(http)
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder",
            "Browse.Album", "Browse.NormalAlbum", "Browse.Category", "Sharing.Passphrase", "Upload.Item")
        val capabilities = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> suffixes.map { "$prefix.$it" } }
            .associateWith { ApiCapability(it, "entry.cgi", 1, 5, "JSON") }
        repositoryFactory = { SynologyPhotosRepository(profile.id, capabilities, { capability, method, fields ->
            val call = Call(capability.name, method, fields); calls += call; reply(call)
        }, uploadTransport = { capability, method, fields, source, progress ->
            sent += Call(capability.name, method, fields)
            gate?.await()
            val id = 100L + sent.size
            val folder = fields["target_folder_id"]?.toLong() ?: 9
            val name = Json.parseToJsonElement(fields.getValue("name")).jsonPrimitive.content
            remoteItems[id] = obj("""{"id":$id,"filename":${JsonPrimitive(name)},"filesize":${source.contentLength},"time":1735689600,"indexed_time":1735689600,"folder_id":$folder,"owner_user_id":41,"type":"photo","additional":{"provider_user_id":41}}""")
            api.uploadPhoto(profile, session, capability, method, fields, source, progress)
        }) }
        repository = repositoryFactory()
        model = createModel()
        compose.setContent { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { key(modelEpoch) { SynologyPhotosLibrary(model, canBackup = true, onBackup = {}) } }
        } } }
        ready()
    }

    private fun createModel() = SynologyPhotosModel(repository, scope, uploadStore = SynologyPhotoUploadStore(context), uploadOwner = owner, requireUploadOwner = { profiles.requireCurrentOwner(owner) }, execution = io.github.qwertyuiop1995.dsmnativeclient.background.AndroidWorkspaceExecution(context))

    private fun reply(call: Call): JsonObject = when {
        call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$shared","upload_default_action":"rename"}""")
        call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
        failRead -> throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
        call.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
        call.api.endsWith("Browse.Item") && call.method == "get" -> JsonObject(mapOf("list" to JsonArray(listOfNotNull(remoteItems[Json.parseToJsonElement(call.fields.getValue("id")).jsonArray[0].jsonPrimitive.long]))))
        call.api.endsWith("Browse.Item") -> obj("""{"list":[]}""")
        call.api.endsWith("Browse.Category") -> obj("""{"list":[]}""")
        call.api.endsWith("Browse.Album") || call.api.endsWith("Browse.NormalAlbum") -> obj("""{"list":[{"id":71,"name":"Synthetic album","type":"normal","owner_user_id":42,"additional":{"sharing_info":{"passphrase":"synthetic-share"}}}]}""")
        call.api.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":$uploadAllowed,"download":false}}""")
        call.api.endsWith("Browse.Folder") && call.method == "create" -> {
            val id = 301L + remoteFolders.size
            remoteFolders[id] = call.fields.getValue("target_id").toLong() to Json.parseToJsonElement(call.fields.getValue("name")).jsonPrimitive.content
            obj("""{"folder":{"id":$id}}""")
        }
        call.api.endsWith("Browse.Folder") && call.method == "get" -> {
            val id = call.fields["id"]?.toLong() ?: 9
            val pair = remoteFolders[id] ?: (0L to "/")
            obj("""{"folder":{"id":$id,"parent":${pair.first},"name":${JsonPrimitive(pair.second)},"additional":{"access_permission":{"view":true,"manage":$uploadAllowed,"upload":$uploadAllowed}}}}""")
        }
        call.api.endsWith("Browse.Folder") -> obj("""{"list":[]}""")
        else -> error("Unexpected synthetic Photos request")
    }

    private fun openUpload() {
        compose.onNodeWithContentDescription(text(R.string.sp_upload_title)).performClick()
        compose.waitUntil(10_000) { uploads.state.value.draft?.duplicate != null && !uploads.state.value.loading }
    }
    private fun stage(sources: List<SynologyPhotoLocalSource>, expectPrepared: Boolean = true) {
        compose.runOnIdle { uploads.stage(uploads.state.value.draft!!) { sources } }
        if (expectPrepared) awaitPrepared()
    }
    private fun source(folder: String = "", name: String = "synthetic.png") = SynologyPhotoLocalSource(name, imageBytes.size.toLong(), 1000, folder) { ByteArrayInputStream(imageBytes) }
    private fun awaitPrepared() { compose.waitUntil(15_000) { !uploads.state.value.working && uploads.state.value.selected != null }; assertNull(uploads.state.value.error) }
    private fun awaitFinished() { compose.waitUntil(15_000) { !uploads.state.value.working && uploads.state.value.selected?.finished == true }; assertNull(uploads.state.value.error) }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun text(id: Int) = context.getString(id)
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun createMedia(name: String): Uri {
        val values = ContentValues().apply { put(MediaStore.Images.Media.DISPLAY_NAME, name); put(MediaStore.Images.Media.MIME_TYPE, "image/png") }
        val uri = context.contentResolver.insert(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)!!
        originals += uri
        context.contentResolver.openOutputStream(uri)!!.use { it.write(imageBytes) }
        return uri
    }
    private fun awaitDocument(name: String): AccessibilityNodeInfo {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val deadline = SystemClock.uptimeMillis() + 15_000
        while (SystemClock.uptimeMillis() < deadline) {
            automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(name)?.firstOrNull { it.text?.toString() == name }?.let { return it }
            SystemClock.sleep(100)
        }
        throw AssertionError("系统文件选择器未显示合成图片")
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-upload-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
