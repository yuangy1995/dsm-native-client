package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
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
import java.io.IOException
import java.time.Instant
import java.time.YearMonth
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.*
import org.junit.Assert.*

/** 正式前台队列、系统解码、三档上传和加密恢复；仅网络与设备能力报告使用合成夹具。 */
class SynologyPhotosAutomaticPreviewUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("automatic-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private lateinit var cache: File
    private val automatic get() = model.automaticPreviews!!
    private val settings get() = model.settings!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val uploads get() = calls.filter { it.method == "upload" }
    private val uploaded = ConcurrentHashMap<String, ByteArray>()
    private val thumbnailReads = AtomicInteger()
    @Volatile private var enabled = true
    @Volatile private var published = false
    @Volatile private var unknown = false
    @Volatile private var rejected = false
    @Volatile private var conversions = 0
    private var home = true; private var shared = false; private var manage = true; private var populated = true
    private var failSettings = false
    private var conversionGate: CompletableDeferred<Unit>? = null
    private var settingsGate: CompletableDeferred<Unit>? = null
    private lateinit var original: ByteArray

    @After fun cleanup() {
        conversionGate?.complete(Unit); settingsGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
        if (::cache.isInitialized) { assertTrue(cache.list()!!.isEmpty()); assertTrue(cache.delete()) }
    }

    @Test fun 空库不常驻状态设置加载失败重试直接保存且仅修改自动开关() {
        enabled = false; populated = false; show(); ready(); process()
        compose.onNodeWithTag("photos_automatic_status").assertDoesNotExist(); capture("empty-idle")
        settingsGate = CompletableDeferred(); menu(); compose.waitUntil(5_000) { settings.state.value.loading }; capture("settings-loading")
        failSettings = true; compose.runOnIdle { settingsGate!!.complete(Unit); settingsGate = null }
        compose.waitUntil(5_000) { !settings.state.value.loading && settings.state.value.error != null }; capture("settings-error")
        failSettings = false; compose.onNode(hasText(text(R.string.sp_retry)) and hasAnyAncestor(isDialog())).performClick(); form()
        compose.onNodeWithTag("photos_settings_automatic_preview").assertIsOff().performClick(); capture("settings-enabled")
        compose.onNodeWithTag("photos_settings_save").performClick()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.records.any { it.checkpoint.finished } }
        assertNull(settings.state.value.error); assertNull(settings.state.value.confirmation)
        assertEquals(mapOf("auto_generate_thumbnail" to "true"), calls.single { it.method == "set" }.fields)
        assertTrue(uploads.isEmpty()); closeSettings(); menu(); form()
        compose.onNodeWithTag("photos_settings_automatic_preview").assertIsOn(); compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled(); capture("settings-saved")
    }

    @Test fun 真实生成可暂停继续完成后三档图片更新且月份选择分页不变() {
        enabled = false; show(); ready(); compose.runOnIdle { model.jumpToMonth(YearMonth.of(2020, 3)) }; ready()
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.single()) }
        val before = model.state.value; val reads = photoReads()
        conversionGate = CompletableDeferred(); enabled = true; process(); working(); capture("working")
        compose.onNodeWithTag("photos_automatic_toggle").performClick()
        compose.waitUntil(5_000) { automatic.state.value.paused && !automatic.state.value.working }
        assertTrue(cache.list()!!.isEmpty()); assertTrue(uploads.isEmpty()); capture("paused")
        compose.runOnIdle { conversionGate!!.complete(Unit); conversionGate = null }
        compose.onNodeWithTag("photos_automatic_toggle").performClick(); completed(); capture("completed")
        assertEquals(2, conversions); assertEquals(1, uploads.size); assertEquals("151", uploads.single().fields.getValue("unit_id"))
        assertEquals(before.copy(items = model.state.value.items, groups = model.state.value.groups), model.state.value)
        assertEquals(before.items.single().id, model.edits!!.state.value.selected.single().id)
        assertEquals("new", model.edits!!.state.value.selected.single().thumbnail!!.revision); assertEquals(reads, photoReads())
        assertEquals(setOf("xl", "sm", "m"), uploaded.keys); uploaded.values.forEach { bytes ->
            assertEquals(0xff, bytes[0].toInt() and 255); assertEquals(0xd8, bytes[1].toInt() and 255)
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size); assertNotNull(bitmap)
            assertEquals(160, bitmap.width); assertEquals(120, bitmap.height); bitmap.recycle()
        }
        compose.onNodeWithTag("photos_automatic_status").assertDoesNotExist()
    }

    @Test fun 未知上传冷恢复只读刷新内容匹配后结束且不重复上传() {
        unknown = true; show(); ready(); process(); pending(); capture("upload-unknown")
        assertEquals(1, uploads.size); assertEquals(1, conversions); cold(); process(); pending(); capture("cold-pending")
        val reads = thumbnailReads.get(); compose.onNodeWithTag("photos_automatic_refresh").performClick()
        compose.waitUntil(5_000) { thumbnailReads.get() > reads && !automatic.state.value.working && automatic.state.value.pending }
        assertEquals(1, uploads.size)
        published = true; compose.onNodeWithTag("photos_automatic_refresh").performClick(); completed(); capture("recovered")
        assertEquals(1, uploads.size); assertEquals(1, conversions); assertTrue(cache.list()!!.isEmpty())
        assertEquals("new", model.state.value.items.single().thumbnail!!.revision)
    }

    @Test fun 明确拒绝显示恢复按钮重新开始才再次生成() {
        rejected = true; show(); ready(); process()
        compose.waitUntil(10_000) { !automatic.state.value.working && automatic.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_automatic_preview_failed)).assertIsDisplayed(); capture("rejected")
        process(); assertEquals(1, uploads.size); assertFalse(automatic.state.value.pending)
        rejected = false; compose.onNodeWithTag("photos_automatic_toggle").performClick(); completed(); capture("retry-completed")
        assertEquals(2, uploads.size); assertEquals(2, conversions)
    }

    @Test fun 共享仅浏览权限处理实际可见原件不会扫描全库() {
        home = false; shared = true; manage = false; show(); ready()
        completed(); capture("shared-visible")
        assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
        assertEquals("SYNO.FotoTeam.Upload.ConvertedFile", uploads.single().api)
        assertTrue(calls.any { it.api == "SYNO.FotoTeam.Browse.Folder" && it.method == "get" })
        assertFalse(calls.any { it.method == "list_convert_needed" })
    }

    @Test fun 离开前台取消尚未上传任务重返后可完成且只上传一次() {
        conversionGate = CompletableDeferred(); show(); ready(); process(); working()
        compose.runOnIdle { model.deactivate() }
        compose.waitUntil(5_000) { cache.list()!!.isEmpty() }
        assertTrue(uploads.isEmpty()); assertFalse(automatic.state.value.working)
        compose.runOnIdle { conversionGate!!.complete(Unit); conversionGate = null; model.activate() }
        ready(); process(); completed(); capture("foreground-resumed"); assertEquals(1, uploads.size)
    }

    private fun show() {
        original = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190)); bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle(); output.toByteArray()
        }
        cache = File(context.cacheDir, owner.profileId).apply { assertTrue(mkdir()) }
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album", "Browse.NormalAlbum", "Browse.Folder", "Browse.Unit", "Download", "Upload.ConvertedFile")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); val content: ByteArray; val mime: String
            if (request.method == "POST") {
                val bytes = Buffer(); request.body!!.writeTo(bytes)
                val body = bytes.readByteArray().toString(Charsets.ISO_8859_1)
                fun part(name: String): String = Regex("name=\"$name\"[^\\r]*\\r\\n(?:[^\\r]+\\r\\n)*\\r\\n(.*?)\\r\\n--", RegexOption.DOT_MATCHES_ALL).find(body)!!.groupValues[1]
                val unit = part("unit_id"); assertEquals("151", unit)
                listOf("xl", "sm", "m").forEach { uploaded[it] = part("thumb_$it").toByteArray(Charsets.ISO_8859_1) }
                assertFalse(body.contains("name=\"video\""))
                assertTrue(store.records(owner, 41).single { it.checkpoint.automaticPreview != null }.checkpoint.automaticPreview!!.uploadAttempted)
                calls += Call(if (body.contains("SYNO.FotoTeam.Upload.ConvertedFile")) "SYNO.FotoTeam.Upload.ConvertedFile" else "SYNO.Foto.Upload.ConvertedFile", "upload", mapOf("unit_id" to unit))
                if (unknown) throw IOException("Synthetic interrupted response")
                if (!rejected) published = true
                content = (if (rejected) "{\"success\":false,\"error\":{\"code\":100}}" else "{\"success\":true}").toByteArray(); mime = "application/json"
            } else {
                val size = request.url.queryParameter("size")?.let { Json.parseToJsonElement(it).jsonPrimitive.content }
                if (request.url.encodedPath.endsWith("Thumbnail/get")) thumbnailReads.incrementAndGet()
                content = if (published && request.url.encodedPath.endsWith("Thumbnail/get") && size != null) uploaded.getValue(size) else original
                mime = if (content === original) "image/png" else "image/jpeg"
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                .header("Content-Type", mime).body(content.toResponseBody(mime.toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic", "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (cap.name.endsWith("Setting.User") && method == "get") { settingsGate?.await(); if (failSettings) throw IOException("Synthetic settings unavailable") }
            response(call)
        }, media, automaticConverter = { source, task, output ->
            conversions++; conversionGate?.await(); SynologyPhotosAutomaticPreviewConverter.convert(source, task, output)
        })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore,
            automaticPreviewCache = cache, automaticPreviewSupport = { SynologyPhotoPreviewConversionSupport(true, true, true) })
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") && c.method == "set" -> {
            assertEquals(setOf("auto_generate_thumbnail"), c.fields.keys)
            assertTrue(store.records(owner, 41).single { it.checkpoint.settings != null }.checkpoint.settings!!.attempted)
            enabled = c.fields.getValue("auto_generate_thumbnail").toBooleanStrict(); obj("{}")
        }
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"${if (manage) "management" else "entry"}","auto_generate_thumbnail":$enabled,"timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"album_list_sort_by":"create_time","album_list_sort_direction":"desc","album_display_type":"all_album"}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$shared}""")
        c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"manage":$manage,"download":true}}}}""")
        c.api.endsWith("Browse.Timeline") -> if (populated) obj("""{"section":[{"list":[{"year":2020,"month":3,"day":2,"item_count":1}]}]}""") else obj("""{"section":[]}""")
        c.api.endsWith("Browse.Item") -> list(if (populated && (c.method == "get" || c.fields["offset"] == "0")) listOf(photo(c.api.startsWith("SYNO.FotoTeam"))) else emptyList())
        c.api.endsWith("Browse.Category") || c.api.endsWith("Browse.Album") -> list(emptyList())
        c.method == "list_convert_needed" -> if (populated && !published) obj("""{"list":[{"unit_id":151,"filename":"Synthetic.heic","type":0,"need_thumbnail":true,"need_video":false}]}""") else list(emptyList())
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun photo(team: Boolean) = buildJsonObject {
        val time = Instant.parse("2020-03-02T12:00:00Z").epochSecond
        put("id", 51); put("filename", "Synthetic.heic"); put("filesize", original.size); put("time", time); put("indexed_time", time)
        put("folder_id", 9); put("type", "photo"); put("owner_user_id", if (team) 0 else 41)
        put("additional", obj("""{"thumbnail":{"unit_id":151,"cache_key":"${if (published) "new" else "old"}","xl":"${if (published) "ready" else "ame_defect"}","sm":"${if (published) "ready" else "ame_defect"}"},"description":"Synthetic description"}"""))
    }
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun process() { var job: Job? = null; compose.runOnIdle { job = automatic.process() }; if (conversionGate == null) runBlocking { job?.join() } }
    private fun working() { compose.waitUntil(10_000) { automatic.state.value.working && conversions > 0 }; assertNull(automatic.state.value.error) }
    private fun completed() { compose.waitUntil(15_000) { published && !automatic.state.value.working && automatic.state.value.records.isEmpty() && model.state.value.items.singleOrNull()?.thumbnail?.revision == "new" }; assertNull(automatic.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !automatic.state.value.working && automatic.state.value.pending }; assertEquals(1, uploads.size) }
    private fun form() { compose.waitUntil(5_000) { !settings.state.value.loading && settings.state.value.desired != null }; assertNull(settings.state.value.error) }
    private fun menu() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNode(hasText(text(R.string.sp_automatic_preview_title)) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun closeSettings() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun photoReads() = calls.count { it.api.endsWith("Browse.Item") && it.method == "list" }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-automatic-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
