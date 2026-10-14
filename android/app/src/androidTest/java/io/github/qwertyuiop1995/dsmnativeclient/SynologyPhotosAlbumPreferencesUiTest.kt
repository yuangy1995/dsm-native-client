package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
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
import java.time.*
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*

/** 相册浏览偏好的正式图库、仓储、加密恢复与原生控件；仅使用合成 NAS 响应。 */
class SynologyPhotosAlbumPreferencesUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("settings-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val settings get() = model.settings!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method.startsWith("set_") }
    private var album = obj("""{"id":7,"name":"Synthetic album 7","owner_user_id":41,"type":"normal","sort_by":"takentime","sort_direction":"asc","passphrase":"synthetic"}""")
    private var order = obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc","shared_with_me_sort_by":"start_time","shared_with_me_sort_direction":"desc","shared_with_others_sort_by":"share_modify_time","shared_with_others_sort_direction":"asc"}""")
    private var display = obj("""{"album_display_type":"all_album"}""")
    private var home = true; private var empty = false; private var failRead = false
    private var apply = true; private var unknown = false; private var denied = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 相册照片排序直接保存后保留相册选择和顺序重开可见() {
        show(); ready(); albums(); openAlbum(); capture("album-original")
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.first()) }
        val selected = model.edits!!.state.value.selected
        menu(R.string.sp_album_photo_sort); form(); capture("album-sort-original")
        select("photos_album_sort_field", R.string.sp_folder_sort_name); select("photos_album_sort_direction", R.string.sp_folder_sort_descending)
        capture("album-sort-changed"); save(); settled(); assertNull(settings.state.value.confirmation); close(); ready()
        assertEquals(7L, model.state.value.navigation.album!!.id); assertEquals(selected, model.edits!!.state.value.selected)
        assertEquals(3L, model.state.value.items.first().id.itemId)
        compose.waitUntil(5_000) { model.state.value.items.size == 3 }
        val positions = listOf(3L, 2L, 1L).map { id -> compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Synthetic$id.jpg")).fetchSemanticsNode().boundsInRoot }
        positions.zipWithNext().forEach { (before, after) -> assertTrue("Displayed order must follow album sort across photo dates", before.top < after.top || before.top == after.top && before.left < after.left) }
        capture("album-sorted")
        menu(R.string.sp_album_photo_sort); form(); compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled()
        assertEquals(SynologyPhotoSort.Field.FILENAME, (settings.state.value.desired as SynologyPhotoAlbumSortSettings).sort.field)
        assertEquals(mapOf("id" to "7", "sort_by" to "\"filename\"", "sort_direction" to "\"desc\""), writes.single().fields)
    }
    @Test fun 全部我的相册独立保存且排序列表五字段可选() {
        show(); ready(); albums(); menu(R.string.sp_album_list_display); form(); capture("display-all")
        select("photos_album_list_display", R.string.sp_album_display_mine); save(); settled(); capture("display-saved"); close()
        compose.waitUntil(5_000) { !model.state.value.hasMoreCollections }; assertEquals(listOf(7L, 9L), model.state.value.collections.map { it.id })
        capture("albums-mine"); menu(R.string.sp_album_list_sort); form(); scrollTag("photos_album_list_sort_field").performClick()
        for (id in listOf(R.string.sp_album_sort_name, R.string.sp_album_sort_type, R.string.sp_album_sort_start, R.string.sp_album_sort_created, R.string.sp_album_sort_sharing))
            compose.onNode(hasText(text(id)) and hasAnyAncestor(isPopup())).performScrollTo().assertIsDisplayed()
        chooseText(text(R.string.sp_album_sort_created)); select("photos_album_sort_direction", R.string.sp_folder_sort_descending); save(); settled(); close()
        assertEquals(SynologyPhotoAlbumDisplay.MINE, model.state.value.albumDisplay); capture("albums-sorted-mine")
        assertEquals(setOf("album_list_sort_by", "album_list_sort_direction"), writes.last().fields.keys); assertEquals(2, writes.size)
    }
    @Test fun 两个分享列表保存互不影响收集菜单不出现相册偏好() {
        show(); ready(); sharing(SynologyPhotoShareScope.WITH_ME); menu(R.string.sp_album_sort_with_me); form(); capture("shared-with-me-original")
        select("photos_album_list_sort_field", R.string.sp_album_sort_type); select("photos_album_sort_direction", R.string.sp_folder_sort_ascending); save(); settled(); close(); capture("shared-with-me-sorted")
        sharing(SynologyPhotoShareScope.WITH_OTHERS); menu(R.string.sp_album_sort_with_others); form(); capture("shared-with-others-original")
        assertEquals(SynologyPhotoAlbumListSort.Field.SHARED_TIME, (settings.state.value.desired as SynologyPhotoAlbumListSortSettings).sort.field)
        select("photos_album_list_sort_field", R.string.sp_album_sort_name); save(); settled(); close()
        assertEquals(setOf("shared_with_others_sort_by", "shared_with_others_sort_direction"), writes.last().fields.keys)
        assertEquals("album_type", order.getValue("shared_with_me_sort_by").jsonPrimitive.content)
        sharing(SynologyPhotoShareScope.REQUESTS); capture("requests-without-preferences")
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithTag("photos_settings_menu_LIST_SORT").assertDoesNotExist(); compose.onNodeWithTag("photos_settings_menu_LIST_DISPLAY").assertDoesNotExist()
        assertEquals(2, writes.size)
    }
    @Test fun 个人来源关闭仍可给可查看相册排序不要求管理原件() {
        home = false; album = JsonObject(album + ("owner_user_id" to JsonPrimitive(42))); show(); ready(); albums(); capture("home-disabled-albums"); openAlbum()
        menu(R.string.sp_album_photo_sort); form(); capture("view-only-album-sort")
        select("photos_album_sort_field", R.string.sp_folder_sort_size); save(); settled(); capture("view-only-sort-saved"); close(); capture("view-only-album")
        assertEquals(1, writes.size); assertTrue(calls.any { it.method == "get_permission" }); assertEquals(7L, model.state.value.navigation.album!!.id)
    }
    @Test fun 未知保存重启后只读恢复相同范围不重复发送() {
        apply = false; unknown = true; show(); ready(); albums(); menu(R.string.sp_album_list_display); form()
        select("photos_album_list_display", R.string.sp_album_display_mine); save(); pending(); capture("unknown-save"); close(); cold()
        menu(R.string.sp_settings_records); records(); capture("cold-records")
        compose.onNodeWithTag("photos_settings_resume").performClick(); pending(); assertEquals(1, writes.size)
        display = obj("""{"album_display_type":"my_album"}"""); compose.onNodeWithTag("photos_settings_resume").performClick(); settled(); capture("cold-completed")
        assertEquals(1, writes.size); close(); albums(); compose.waitUntil(5_000) { !model.state.value.hasMoreCollections }; capture("cold-mine")
        assertEquals(listOf(7L, 9L), model.state.value.collections.map { it.id })
    }
    @Test fun 读取失败可继续浏览重试恢复并发修改及权限拒绝不误报成功() {
        failRead = true; show(); ready(); albums(); capture("preferences-read-error")
        compose.onNodeWithText(text(R.string.sp_album_preferences_failed)).assertIsDisplayed(); assertTrue(model.state.value.collections.isNotEmpty())
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); ready(); assertTrue(model.state.value.preferenceErrors.isEmpty())
        menu(R.string.sp_album_list_sort); form(); select("photos_album_list_sort_field", R.string.sp_album_sort_type)
        order = JsonObject(order + ("album_list_sort_by" to JsonPrimitive("create_time"))); save()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }; compose.onNodeWithText(text(R.string.sp_settings_changed)).assertIsDisplayed(); capture("concurrent-change")
        assertTrue(writes.isEmpty()); close(); menu(R.string.sp_album_list_sort); form(); select("photos_album_list_sort_field", R.string.sp_album_sort_type)
        denied = true; save(); settled(); compose.onNodeWithText(text(R.string.sp_settings_rejected)).assertIsDisplayed(); capture("permission-rejected"); close()
        capture("albums-after-rejection"); assertEquals(1, writes.size)
    }
    @Test fun 空相册和加载状态仍能设置显示范围取消不产生写入() {
        empty = true; show(); ready(); albums(); capture("albums-empty")
        gate = CompletableDeferred(); menu(R.string.sp_album_list_display); compose.waitUntil(5_000) { settings.state.value.loading }; capture("preference-loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("empty-display-form")
        select("photos_album_list_display", R.string.sp_album_display_mine); close(); assertTrue(writes.isEmpty()); capture("cancel-empty-display")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album", "Browse.NormalAlbum", "Sharing.Passphrase", "Sharing.Misc", "PhotoRequest")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (method.startsWith("get_album_list")) { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, pageSize = 2, uploadOwner = owner, albumStore = store, editStore = SynologyPhotoEditStore(context))
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"none"}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":false}""")
        c.method == "get_album_list_order" -> order
        c.method == "get_album_list_display" -> display
        c.api.endsWith("Browse.Album") && c.method == "get" -> list(listOf(album))
        c.api.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":false,"download":false}}""")
        c.method.startsWith("set_") -> {
            if (denied) throw DsmFailure(105, "Synthetic denied", "Synthetic recovery")
            val values = c.fields.mapValues { Json.parseToJsonElement(it.value) }
            if (apply) when (c.method) {
                "set_order" -> album = JsonObject(album + values.filterKeys { it != "id" })
                "set_album_list_order" -> order = JsonObject(order + values)
                "set_album_list_display" -> display = JsonObject(display + values)
                else -> error("Unexpected synthetic write")
            }
            if (unknown) throw IOException("Synthetic missing receipt")
            obj("{}")
        }
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
        c.api.endsWith("Browse.Category") || c.api.endsWith("PhotoRequest") -> list(emptyList())
        c.api.endsWith("Browse.Item") -> {
            val ids = if (c.fields["sort_direction"] == "\"asc\"") listOf(1L, 2L, 3L) else listOf(3L, 2L, 1L)
            list(ids.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()).map(::photo))
        }
        c.method == "list" || c.method == "list_shared_with_me_album" -> {
            val ids = if (empty) emptyList() else if (c.fields["category"] == "\"normal\"") listOf(7L, 9L) else listOf(7L, 8L, 9L)
            list(ids.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()).map { obj("""{"id":$it,"name":"Synthetic album $it","type":"normal"}""") })
        }
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun photo(id: Long): JsonObject {
        // 日期顺序与名称顺序不同，必须用实际网格位置发现错误的日期重排。
        val time = Instant.parse(when (id) { 1L -> "2020-03-01T12:00:00Z"; 2L -> "2020-03-03T12:00:00Z"; else -> "2020-03-02T12:00:00Z" }).epochSecond
        return obj("""{"id":$id,"filename":"Synthetic$id.jpg","filesize":4,"time":$time,"indexed_time":$time,"folder_id":9,"type":"photo","owner_user_id":41,"additional":{"provider_user_id":41,"thumbnail":{"unit_id":$id,"cache_key":"synthetic"}}}""")
    }
    private fun albums() { compose.onNode(hasText(text(R.string.sp_library_albums)) and hasClickAction()).performClick(); ready() }
    private fun openAlbum() { compose.onNodeWithText("Synthetic album 7").performClick(); ready() }
    private fun sharing(value: SynologyPhotoShareScope) { compose.runOnIdle { model.selectSection(SynologyPhotosSection.SHARING) }; ready(); compose.runOnIdle { model.selectShareScope(value) }; ready() }
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun form() { compose.waitUntil(10_000) { !settings.state.value.loading && settings.state.value.desired != null }; assertNull(settings.state.value.error) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); chooseText(text(id)) }
    private fun chooseText(value: String) { compose.onNode(hasText(value) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun scrollTag(tag: String): SemanticsNodeInteraction = compose.onNodeWithTag(tag).performScrollTo()
    private fun select(tag: String, id: Int) { scrollTag(tag).performClick(); chooseText(text(id)) }
    private fun save() { compose.onNodeWithTag("photos_settings_save").assertIsEnabled().performClick() }
    private fun records() { compose.waitUntil(10_000) { settings.state.value.records.isNotEmpty() } }
    private fun settled() { compose.waitUntil(10_000) { !settings.state.value.working && settings.state.value.records.any { it.id == settings.state.value.activeId && it.checkpoint.finished } }; assertNull(settings.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !settings.state.value.working && settings.state.value.records.any { !it.checkpoint.finished } }; assertNull(settings.state.value.error) }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-preferences-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
