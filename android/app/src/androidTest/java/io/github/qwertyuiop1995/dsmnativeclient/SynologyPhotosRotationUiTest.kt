package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
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

/** 正式仓储、加密恢复和真实 PNG 解码；所有请求仅连接进程内合成响应。 */
class SynologyPhotosRotationUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("rotation-${UUID.randomUUID()}", "synthetic", UUID.randomUUID().toString())
    private val store by lazy { SynologyPhotoEditStore(context) }
    private var root by mutableStateOf<SynologyPhotosModel?>(null)
    private val model get() = root!!
    @Volatile private var orientation = 1
    @Volatile private var width = 160
    @Volatile private var height = 120
    private var originalOrientation: Int? = null
    private var home = true; private var manage = true; private var manager = true
    private var albumOwner = 99L; private var provider = 41L
    private var mediaType = "photo"; private var filename = "Synthetic1.jpg"
    private var apply = true; private var swap = true; private var lost = false; private var reject = false
    private var gate: CompletableDeferred<Unit>? = null
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val mediaCalls = CopyOnWriteArrayList<Request>()
    private val writes get() = calls.filter { it.method == "set" }

    @After fun cleanup() {
        gate?.complete(Unit); root?.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        store.removeProfile(owner.profileId)
    }
    @Test fun 保存中即时转向只写一次完成后保留选择并可连续旋转() {
        show(); ready(); open(); capture("before")
        compose.runOnIdle { model.edits!!.toggle(model.preview.state.value.photo!!) }
        val before = model.state.value; val readsBefore = calls.count { it.api.endsWith("Browse.Item") && it.method == "list" }; gate = CompletableDeferred()
        rotate(); compose.waitUntil(5_000) { writes.size == 1 }
        compose.onNodeWithContentDescription(text(R.string.sp_rotate_action)).assertIsNotEnabled()
        compose.onNodeWithContentDescription(text(R.string.sp_media_save)).performScrollTo().assertIsNotEnabled()
        assertEquals(-90f, model.preview.state.value.rotationDegrees)
        compose.onNodeWithText(text(R.string.sp_rotate_saving)).assertIsDisplayed(); capture("saving")
        gate!!.complete(Unit); gate = null; saved(8); capture("saved")
        assertEquals(before.navigation, model.state.value.navigation); assertEquals(before.paginationKey, model.state.value.paginationKey)
        assertEquals(before.selectedMonth, model.state.value.selectedMonth)
        assertEquals(8, model.edits!!.state.value.selected.single().orientation)
        assertEquals(readsBefore, calls.count { it.api.endsWith("Browse.Item") && it.method == "list" })
        assertEquals(setOf("id", "rotate_action"), writes.single().fields.keys)
        assertTrue(mediaCalls.filter { it.url.encodedPath.endsWith("Thumbnail/get") }.all { it.header("Cache-Control") == "no-cache" })
        for (next in listOf(3, 6, 1)) { rotate(); saved(next) }
        assertEquals(4, writes.size); capture("four-turns")
        compose.runOnIdle { model.preview.closePreview() }; capture("gallery-preserved")
    }
    @Test fun 丢回执冷恢复只读取结果不再旋转() {
        swap = false; lost = true; show(); ready(); open(); rotate()
        compose.waitUntil(5_000) { !model.edits!!.state.value.working && model.edits!!.state.value.records.any { it.checkpoint.phase == SynologyPhotoEditPhase.PENDING } }
        assertEquals(0f, model.preview.state.value.rotationDegrees)
        compose.onNodeWithText(text(R.string.sp_rotate_interrupted)).assertIsDisplayed()
        compose.onNodeWithContentDescription(text(R.string.sp_slideshow_start)).performScrollTo().assertIsNotEnabled(); capture("interrupted")
        compose.runOnIdle { model.close(); root = buildModel() }; ready(); open()
        compose.onNodeWithContentDescription(text(R.string.sp_rotate_action)).assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.sp_edit_refresh)).performClick()
        compose.waitUntil(5_000) { !model.edits!!.state.value.working }; assertEquals(1, writes.size)
        width = 120; height = 160
        compose.onNodeWithText(text(R.string.sp_edit_refresh)).performClick(); saved(8)
        assertEquals(1, writes.size); capture("restored")
    }
    @Test fun 明确拒绝与写前权限拒绝恢复原图且不会跳转图库() {
        reject = true; apply = false; show(); ready(); open(); rotate()
        compose.waitUntil(5_000) { model.edits!!.state.value.records.any { it.checkpoint.phase == SynologyPhotoEditPhase.PARTIAL } && !model.edits!!.state.value.working }
        compose.onNodeWithText(text(R.string.sp_rotate_failed)).assertIsDisplayed(); capture("rejected")
        assertEquals(1, orientation); assertEquals(0f, model.preview.state.value.rotationDegrees)
        assertEquals(1L, model.preview.state.value.photo?.id?.itemId)
        reject = false; manage = false
        compose.runOnIdle { model.preview.closePreview() }; open(); rotate()
        compose.waitUntil(5_000) { model.edits!!.state.value.error != null && !model.edits!!.state.value.working }
        assertEquals(1, writes.size); compose.onNodeWithText(text(R.string.sp_rotate_failed)).assertIsDisplayed(); capture("permission-denied")
    }
    @Test fun 媒体限制和实况方向使用真实详情决定入口() {
        show(); ready()
        for ((name, type) in listOf("Synthetic1.GIF" to "photo", "Synthetic1.WEBP" to "photo", "Synthetic1.jpg" to "photo360")) {
            filename = name; mediaType = type; compose.runOnIdle { model.refresh() }; ready(); open()
            compose.onNodeWithContentDescription(text(R.string.sp_rotate_action)).assertDoesNotExist()
            capture("unsupported-${type}-${name.substringAfterLast('.')}"); compose.runOnIdle { model.preview.closePreview() }
        }
        filename = "Synthetic1.jpg"; mediaType = "live"; originalOrientation = 1
        compose.runOnIdle { model.refresh() }; ready(); open(); compose.onNodeWithContentDescription(text(R.string.sp_media_play_motion)).assertExists()
        rotate(); saved(8)
        compose.onNodeWithContentDescription(text(R.string.sp_media_play_motion)).assertDoesNotExist(); capture("live-rotated")
    }
    @Test fun 本人相册贡献与共享管理按原来源保存关闭原来源保持只读() {
        show(); ready(); album(); open(); rotate(); saved(8); capture("contributed-album")
        assertEquals("SYNO.Foto.Browse.Item", writes.single().api); assertNull(writes.single().fields["album_id"])
        assertTrue(calls.any { it.method == "get" && it.api.endsWith("Browse.Item") && it.fields["album_id"] == "7" })
        compose.runOnIdle { model.preview.closePreview() }; albumOwner = 0; orientation = 1; width = 160; height = 120
        compose.runOnIdle { model.refresh() }; ready(); open(); rotate(); saved(8); capture("shared-album")
        assertEquals("SYNO.FotoTeam.Browse.Item", writes.last().api); assertNull(writes.last().fields["album_id"])
        compose.runOnIdle { model.preview.closePreview() }; home = false; albumOwner = 99
        compose.runOnIdle { model.refresh() }; ready()
        compose.onNodeWithText("Synthetic album").performClick(); ready(); open()
        compose.onNodeWithContentDescription(text(R.string.sp_rotate_action)).performScrollTo().assertIsNotEnabled()
        assertEquals(2, writes.size); capture("source-disabled")
    }
    @Test fun 保存期间换图与退出不会被完成回调覆盖撤权保留恢复记录() {
        show(); ready(); open(); gate = CompletableDeferred(); rotate()
        compose.waitUntil(5_000) { writes.size == 1 }
        compose.onNodeWithContentDescription(text(R.string.sp_media_next)).performScrollTo().performClick()
        compose.waitUntil(5_000) { model.preview.state.value.photo?.id?.itemId == 2L && !model.preview.state.value.loading }
        gate!!.complete(Unit); gate = null
        compose.waitUntil(5_000) { !model.edits!!.state.value.working }
        assertEquals(2L, model.preview.state.value.photo!!.id.itemId); capture("next-photo")
        compose.runOnIdle { model.preview.closePreview() }; open(); gate = CompletableDeferred(); rotate()
        compose.waitUntil(5_000) { writes.size == 2 }
        compose.runOnIdle { model.revokeAccess() }; gate!!.complete(Unit); gate = null
        compose.waitUntil(5_000) { !SynologyPhotoEditStore.isProfileBusy(owner.profileId) }
        assertNull(model.preview.state.value.photo)
        assertTrue(store.records(owner, 41).any { it.checkpoint.submitted && !it.checkpoint.finished }); capture("revoked")
    }

    private fun show() {
        root = buildModel()
        compose.setContent { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { root?.let { SynologyPhotosLibrary(it, false, {}) } }
        } } }
    }
    private fun buildModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Sharing.Passphrase")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "synthetic")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); mediaCalls += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).message("synthetic").code(200)
                .header("Content-Type", "image/png").body(png().toResponseBody("image/png".toMediaType())).build()
        }.build()
        val transport = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (method == "set") {
                gate?.await()
                if (apply) {
                    orientation = listOf(8, 5, 6, 7, 4, 1, 2, 3)[orientation - 1]
                    if (swap) { val old = width; width = height; height = old }
                }
                if (lost) throw IOException("Synthetic lost response")
                obj(if (reject) """{"error_list":[{"id":1,"error":105}]}""" else "{}")
            } else response(call)
        }, transport)
        return SynologyPhotosModel(repo, scope, pageSize = 2, uploadOwner = owner, editStore = store)
    }
    private fun response(call: Call): JsonObject = when {
        call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"${if (manager) "management" else "entry"}"}""")
        call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
        call.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2020,"month":3,"day":1,"item_count":3}]}]}""")
        call.api.endsWith("Browse.Category") -> list(emptyList())
        call.method == "get_album_list_order" -> obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc"}""")
        call.method == "get_album_list_display" -> obj("""{"album_display_type":"all_album"}""")
        call.api.endsWith("Browse.Album") -> list(listOf(obj("""{"id":7,"name":"Synthetic album","type":"normal","owner_user_id":$albumOwner,"sort_by":"takentime","sort_direction":"asc","passphrase":"synthetic"}""")))
        call.api.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":false,"download":false}}""")
        call.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"manage":$manage}}}}""")
        call.api.endsWith("Browse.Item") -> if (call.method == "get") list(Json.parseToJsonElement(call.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long) })
            else list((1L..3).drop(call.fields.getValue("offset").toInt()).take(call.fields.getValue("limit").toInt()).map(::photo))
        else -> error("Unexpected synthetic call")
    }
    private fun photo(id: Long): JsonObject = obj("""{"id":$id,"filename":"${if (id == 1L) filename else "Synthetic$id.jpg"}","filesize":500,"time":1583064000,"indexed_time":1583064000,"folder_id":9,"type":"${if (id == 1L) mediaType else "photo"}","owner_user_id":$albumOwner,"additional":{"provider_user_id":$provider,"thumbnail":{"unit_id":$id,"cache_key":"synthetic"},"orientation":${if (id == 1L) orientation else 1},"orientation_original":${originalOrientation ?: "null"},"resolution":{"width":$width,"height":$height}}}""")
    private fun png(): ByteArray {
        val bitmap = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888)
        for (y in 0 until 120) for (x in 0 until 160) bitmap.setPixel(x, y, if (x < 80) Color.rgb(50, 110, 190) else Color.rgb(235, 155, 45))
        val degrees = when (orientation) { 8 -> -90f; 3 -> -180f; 6 -> -270f; else -> 0f }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, 160, 120, Matrix().apply { postRotate(degrees) }, false)
        return ByteArrayOutputStream().use { out -> rotated.compress(Bitmap.CompressFormat.PNG, 100, out); if (rotated !== bitmap) rotated.recycle(); bitmap.recycle(); out.toByteArray() }
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading && !model.state.value.loadingMore }; assertNull(model.state.value.error); compose.waitForIdle() }
    private fun open() {
        compose.runOnIdle { model.preview.open(model.state.value.items.first()) }
        compose.waitUntil(5_000) { !model.preview.state.value.loading && model.preview.state.value.imageReady }
    }
    private fun rotate() {
        assertTrue("Expected ready preview rotation", model.canRotatePreview)
        compose.onNodeWithContentDescription(text(R.string.sp_rotate_action)).performScrollTo().assertIsEnabled().performClick()
    }
    private fun saved(expected: Int) {
        compose.waitUntil(8_000) { !model.edits!!.state.value.working && !model.preview.state.value.loading && model.preview.state.value.imageReady &&
            model.preview.state.value.photo?.orientation == expected && model.preview.state.value.rotationDegrees == 0f }
        compose.onNodeWithText(text(R.string.sp_rotate_saved)).assertIsDisplayed()
        assertEquals(expected, model.state.value.items.first().orientation)
    }
    private fun album() {
        compose.onNode(hasText(text(R.string.sp_library_albums)) and hasClickAction()).performClick(); ready()
        compose.onNodeWithText("Synthetic album").performClick(); ready()
    }
    private fun text(id: Int) = context.getString(id)
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val target = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val image = target.captureToImage().asAndroidBitmap()
        File(context.getExternalFilesDir(null), "workspace-photos-rotation-review/$name.png").apply { parentFile!!.mkdirs() }.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
