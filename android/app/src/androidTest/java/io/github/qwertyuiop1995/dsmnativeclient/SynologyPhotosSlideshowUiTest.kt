package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
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
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*

/** 正式仓储与范围媒体传输接入原生播放器；所有请求由进程内合成数据响应，不连接 NAS。 */
class SynologyPhotosSlideshowUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var model: SynologyPhotosModel
    private val slideshow get() = model.slideshow
    private val owner = WorkspaceOwner("slideshow-${UUID.randomUUID()}", "synthetic", UUID.randomUUID().toString())
    private var home = true; private var empty = false; private var video = false
    @Volatile private var corruptImage = false
    @Volatile private var corruptVideo = false
    private var failPage = false
    private var detailGate: CompletableDeferred<Unit>? = null
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val mediaRequests = CopyOnWriteArrayList<Request>()

    @After fun cleanup() {
        detailGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
    }
    @Test fun 图库入口分页循环触控键盘与停止保留选择和位置() {
        show(); ready()
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.first()) }
        val selected = model.edits!!.state.value.selected; val gallery = model.state.value
        startMenu(); pause(); displayed(); capture("image-paused")
        click(R.string.sp_media_previous); displayed(5); capture("last-photo")
        click(R.string.sp_media_next); displayed(1)
        compose.onNodeWithTag("photos_slideshow").performKeyInput { pressKey(Key.DirectionRight) }; displayed(2)
        compose.onNodeWithTag("photos_slideshow").performKeyInput { pressKey(Key.Spacebar) }
        compose.waitUntil(5_000) { slideshow.state.value.playing }
        compose.onNodeWithTag("photos_slideshow").performKeyInput { pressKey(Key.Spacebar) }
        compose.waitUntil(5_000) { !slideshow.state.value.playing }
        capture("keyboard-paused"); compose.onNodeWithTag("photos_slideshow").performKeyInput { pressKey(Key.Escape) }
        compose.waitUntil(5_000) { !slideshow.state.value.active }
        assertEquals(gallery, model.state.value); assertEquals(selected, model.edits!!.state.value.selected)
        capture("gallery-preserved"); assertReadOnly()
    }
    @Test fun 普通预览从当前照片开始并在显示三秒后切换() {
        show(); ready()
        compose.onNodeWithContentDescription(text(R.string.photo_thumbnail_description, "Synthetic2.jpg")).performClick()
        compose.waitUntil(5_000) { !model.preview.state.value.loading && model.preview.state.value.image != null }
        compose.onNodeWithContentDescription(text(R.string.sp_slideshow_start)).performScrollTo().performClick()
        displayed(2); val start = SystemClock.elapsedRealtime(); capture("preview-start")
        compose.waitUntil(6_000) { currentId() == 3L }
        assertTrue("Photo should remain displayed for three seconds", SystemClock.elapsedRealtime() - start >= 2_700)
        pause(); displayed(3); capture("automatic-next"); click(R.string.sp_slideshow_stop)
        assertNull(model.preview.state.value.photo); assertReadOnly()
    }
    @Test fun 真实视频超过三秒不会跳过暂停继续后播放完才前进() {
        video = true; show(); ready(); startMenu()
        compose.waitUntil(10_000) { slideshow.state.value.ready && slideshow.preview.state.value.source != null }
        val started = SystemClock.elapsedRealtime()
        compose.waitUntil(5_000) { SystemClock.elapsedRealtime() - started >= 3_200 }
        assertEquals(1L, currentId()); pause(); capture("video-paused")
        val paused = SystemClock.elapsedRealtime()
        compose.waitUntil(4_000) { SystemClock.elapsedRealtime() - paused >= 1_200 }
        assertEquals(1L, currentId()); click(R.string.sp_slideshow_resume)
        compose.waitUntil(8_000) { currentId() == 2L }; pause(); displayed(2); capture("video-finished-next")
        assertTrue(mediaRequests.any { it.header("Range") != null }); assertReadOnly()
    }
    @Test fun 图片解码和视频播放失败均暂停重试可恢复() {
        corruptImage = true; show(); ready(); startMenu(); error(); capture("image-error")
        corruptImage = false; compose.onNodeWithText(text(R.string.retry)).performClick(); displayed(1)
        assertFalse(slideshow.state.value.playing); capture("image-retried"); click(R.string.sp_slideshow_stop)
        video = true; corruptVideo = true
        compose.runOnIdle { model.refresh() }; ready(); startMenu(); error(); capture("video-error")
        corruptVideo = false; compose.onNodeWithText(text(R.string.retry)).performClick()
        compose.waitUntil(10_000) { slideshow.state.value.ready && slideshow.preview.state.value.source != null }
        assertNull(slideshow.state.value.error); assertFalse(slideshow.state.value.playing); capture("video-retried")
        click(R.string.sp_slideshow_stop); assertReadOnly()
    }
    @Test fun 补页失败不跳过重试后停在相邻照片() {
        show(); ready(); startMenu(); pause(); displayed(1); failPage = true
        click(R.string.sp_media_next); error(); assertEquals(1L, currentId()); capture("page-error")
        failPage = false; compose.onNodeWithText(text(R.string.retry)).performClick(); displayed(2)
        assertFalse(slideshow.state.value.playing); capture("page-retried"); assertReadOnly()
    }
    @Test fun 加载可暂停返回会终止迟到读取及后续播放() {
        show(); ready(); detailGate = CompletableDeferred(); startMenu()
        compose.waitUntil(5_000) { slideshow.state.value.loading }; capture("loading")
        pause(); compose.runOnIdle { detailGate!!.complete(Unit); detailGate = null }; displayed(1)
        assertFalse(slideshow.state.value.playing); capture("loading-paused")
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.waitUntil(5_000) { !slideshow.state.value.active }; assertNull(slideshow.preview.state.value.photo)
        startMenu(); pause(); displayed(1); compose.runOnIdle { model.revokeAccess() }
        compose.waitUntil(5_000) { !slideshow.state.value.active }; assertNull(slideshow.preview.state.value.photo); assertReadOnly()
    }
    @Test fun 仅可查看相册无需个人目录或下载权限也能播放() {
        home = false; show(); ready()
        compose.onNodeWithText("Synthetic album").performClick(); ready(); startMenu(); pause(); displayed(1)
        capture("view-only-album"); click(R.string.sp_media_next); displayed(2)
        assertEquals(7L, slideshow.preview.state.value.photo!!.albumContext!!.albumId)
        assertTrue(calls.filter { it.api.endsWith("Browse.Item") }.all { it.fields["album_id"] == "7" })
        assertTrue(mediaRequests.all { it.url.queryParameter("album_id") == "7" }); assertReadOnly()
    }
    @Test fun 空图库没有可播放入口共享来源播放沿用共享请求() {
        empty = true; show(); ready(); capture("empty")
        assertFalse(model.canStartSlideshow); assertNull(model.startSlideshow())
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithText(text(R.string.sp_slideshow_start)).assertDoesNotExist()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        empty = false; compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        startMenu(); pause(); displayed(1); capture("shared-source"); click(R.string.sp_media_next); displayed(2)
        assertEquals(SynologyPhotoSpace.SHARED, slideshow.preview.state.value.photo!!.id.space)
        assertTrue(calls.any { it.api == "SYNO.FotoTeam.Browse.Item" && it.method == "get" }); assertReadOnly()
    }
    private fun show() {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Album", "Sharing.Passphrase", "Streaming")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(70, 135, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        val movie = InstrumentationRegistry.getInstrumentation().context.assets.open("synthetic-slideshow.mp4").use { it.readBytes() }
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "synthetic")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); mediaRequests += request
            val builder = Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("synthetic")
            if (request.header("Range") != null) {
                val bytes = if (corruptVideo) ByteArray(500) { 7 } else movie
                val range = request.header("Range")!!.removePrefix("bytes=").split('-')
                val start = range[0].toInt(); val end = minOf(range[1].toInt(), bytes.lastIndex)
                builder.code(206).header("Content-Type", "video/mp4").header("Content-Range", "bytes $start-$end/${bytes.size}")
                    .body(bytes.copyOfRange(start, end + 1).toResponseBody("video/mp4".toMediaType())).build()
            } else {
                val bytes = if (corruptImage && request.url.queryParameter("size") == "\"xl\"") byteArrayOf(1, 2, 3) else image
                builder.code(200).header("Content-Type", "image/png").body(bytes.toResponseBody("image/png".toMediaType())).build()
            }
        }.build()
        val transport = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (cap.name.endsWith("Browse.Item") && method == "get") detailGate?.await()
            response(call)
        }, transport)
        model = SynologyPhotosModel(repo, scope, pageSize = 2, uploadOwner = owner, editStore = SynologyPhotoEditStore(context))
        compose.setContent { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } }
    }
    private fun response(call: Call): JsonObject = when {
        call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"entry"}""")
        call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$home}""")
        call.api.endsWith("Browse.Timeline") -> obj(if (empty) """{"section":[]}""" else """{"section":[{"list":[{"year":2020,"month":3,"day":1,"item_count":5}]}]}""")
        call.api.endsWith("Browse.Category") -> list(emptyList())
        call.method == "get_album_list_order" -> obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc"}""")
        call.method == "get_album_list_display" -> obj("""{"album_display_type":"all_album"}""")
        call.api.endsWith("Browse.Album") -> list(listOf(obj("""{"id":7,"name":"Synthetic album","type":"normal","owner_user_id":99,"sort_by":"takentime","sort_direction":"asc","passphrase":"synthetic"}""")))
        call.api.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":false,"download":false}}""")
        call.api.endsWith("Browse.Item") -> {
            if (call.method == "get") list(Json.parseToJsonElement(call.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long) })
            else {
                if (failPage) throw IOException("Synthetic page failure")
                val offset = call.fields.getValue("offset").toInt(); val limit = call.fields.getValue("limit").toInt()
                list((1L..5).drop(offset).take(limit).map(::photo))
            }
        }
        else -> error("Unexpected synthetic read ${call.api}.${call.method}")
    }
    private fun photo(id: Long): JsonObject = obj("""{"id":$id,"filename":"Synthetic$id.${if (video && id == 1L) "mp4" else "jpg"}","filesize":500,"time":1583064000,"indexed_time":1583064000,"folder_id":9,"type":"${if (video && id == 1L) "video" else "photo"}","owner_user_id":99,"additional":{"provider_user_id":99,"thumbnail":{"unit_id":$id,"cache_key":"synthetic"},"video_convert":[{"quality":"medium"}]}}""")
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading && !model.state.value.loadingMore }; assertNull(model.state.value.error); compose.waitForIdle() }
    private fun startMenu() {
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNode(hasText(text(R.string.sp_slideshow_start)) and hasAnyAncestor(isPopup())).performScrollTo().performClick()
        compose.waitUntil(5_000) { slideshow.state.value.active }
    }
    private fun pause() { if (slideshow.state.value.playing) click(R.string.sp_slideshow_pause); compose.waitUntil(5_000) { !slideshow.state.value.playing } }
    private fun displayed(id: Long = 1) {
        compose.waitUntil(10_000) { !slideshow.state.value.loading && slideshow.state.value.ready && currentId() == id }
        assertNull(slideshow.state.value.error)
    }
    private fun error() { compose.waitUntil(10_000) { slideshow.state.value.error != null && !slideshow.state.value.loading }; assertFalse(slideshow.state.value.playing); compose.onNodeWithText(text(R.string.sp_slideshow_failed)).assertIsDisplayed() }
    private fun click(id: Int) { compose.onNodeWithContentDescription(text(id)).performScrollTo().performClick() }
    private fun currentId() = slideshow.preview.state.value.photo?.id?.itemId
    private fun text(id: Int, vararg args: Any) = context.getString(id, *args)
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun assertReadOnly() {
        assertTrue(calls.none { it.method.startsWith("set") || it.method in setOf("create", "delete", "upload") })
        assertTrue(mediaRequests.none { it.url.queryParameter("force_download") != null })
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-slideshow-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
