package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
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

/** 正式维护仓储、根图库、加密恢复和媒体加载；仅使用合成内容。 */
class SynologyPhotosMaintenanceUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("maintenance-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private val maintenance get() = model.maintenance!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method == "reindex" }
    private var administrator = true; private var currentUserId = 41L; private var h264 = true
    private var personalEnabled = true; private var sharedEnabled = true
    private var indexing = 0L; private var previews = 0L; private var afterCount = 0L
    private var failRead = false; private var unknown = false; private var denied = false
    private var gate: CompletableDeferred<Unit>? = null; private var writeGate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit); writeGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }
    @Test fun 两个图库均关闭时仍可浏览相册且不显示维护入口() {
        personalEnabled = false; sharedEnabled = false; show(); ready()
        assertTrue(model.state.value.access!!.spaces.isEmpty()); assertEquals(SynologyPhotosSection.ALBUMS, model.state.value.navigation.section)
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithTag("photos_maintenance_menu").assertDoesNotExist(); capture("no-library-menu")
        assertTrue(writes.isEmpty())
    }
    @Test fun 加载空闲忙碌与预览能力独立且取消零写入() {
        h264 = false; previews = 3; show(); ready(); gate = CompletableDeferred()
        menu(); compose.waitUntil(5_000) { maintenance.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("busy-preview")
        scroll("photos_maintenance_PREVIEWS").assertIsNotEnabled(); scroll("photos_maintenance_INDEX").assertIsEnabled().performClick()
        compose.onNodeWithText(context.getString(R.string.sp_maintenance_index_risk, text(R.string.sp_source_personal))).assertIsDisplayed(); capture("index-confirmation")
        cancel(); assertTrue(writes.isEmpty()); previews = 0; refresh(); form()
        compose.onNodeWithText(text(R.string.sp_maintenance_previews_unavailable)).performScrollTo().assertIsDisplayed(); capture("unsupported-preview")
        scroll("photos_maintenance_INDEX").assertIsEnabled(); indexing = 2; refresh(); form(); scroll("photos_maintenance_INDEX").assertIsNotEnabled(); capture("busy-index")
    }
    @Test fun 个人重建保持历史月份多选且未刷新图库() {
        show(); ready(); compose.runOnIdle { model.jumpToMonth(YearMonth.of(2020, 3)) }; ready()
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.first()) }
        val old = model.state.value; val selected = model.edits!!.state.value.selected; val reads = photoReads()
        menu(); form(); scroll("photos_maintenance_INDEX").performClick(); confirm(); settled(); capture("personal-request-received")
        assertEquals("SYNO.Foto.Index", writes.single().api); assertEquals(mapOf("type" to "\"basic\""), writes.single().fields)
        assertEquals(old.items, model.state.value.items); assertEquals(old.selectedMonth, model.state.value.selectedMonth)
        assertEquals(selected, model.edits!!.state.value.selected); assertEquals(reads, photoReads()); close(); capture("personal-selection-preserved")
    }
    @Test fun 共享预览确认固定目标收到回执后归零结束读取() {
        afterCount = 4; show(); ready(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        menu(); form(); scroll("photos_maintenance_PREVIEWS").performClick()
        compose.onNodeWithText(context.getString(R.string.sp_maintenance_previews_risk, text(R.string.sp_source_shared))).assertIsDisplayed(); capture("shared-previews-confirmation")
        confirm(); pending(); scroll("photos_maintenance_review").assertIsEnabled(); capture("shared-previews-processing")
        assertEquals("SYNO.FotoTeam.Index", writes.single().api); assertEquals(mapOf("type" to "\"thumbnail\""), writes.single().fields)
        previews = 0; scroll("photos_maintenance_review").performClick(); settled()
        compose.onNodeWithText(text(R.string.sp_maintenance_idle_after_request)).performScrollTo().assertIsDisplayed(); capture("shared-previews-idle")
        assertEquals(1, writes.size); scroll("photos_maintenance_clear").performClick(); compose.waitUntil(5_000) { maintenance.state.value.records.isEmpty() }
    }
    @Test fun 丢回执冷恢复即使归零也不追认不重发或清除() {
        unknown = true; afterCount = 2; show(); ready(); menu(); form(); scroll("photos_maintenance_INDEX").performClick(); confirm(); pending()
        compose.onNodeWithText(text(R.string.sp_maintenance_unknown)).performScrollTo().assertIsDisplayed(); capture("lost-receipt")
        close(); indexing = 0; cold(); menu(); form(); scroll("photos_maintenance_review").performClick(); pending()
        scroll("photos_maintenance_INDEX").assertIsNotEnabled(); compose.onNodeWithTag("photos_maintenance_clear").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_maintenance_unknown)).performScrollTo().assertIsDisplayed(); capture("cold-lost-receipt")
        assertEquals(1, writes.size); assertFalse(maintenance.state.value.records.single().checkpoint.finished)
    }
    @Test fun 读取错误重试状态变化零写与明确拒绝保留事实() {
        show(); ready(); failRead = true; menu(); error(); capture("read-failed")
        compose.onNodeWithText(text(R.string.sp_maintenance_failed)).performScrollTo().assertIsDisplayed(); failRead = false; refresh(); form()
        scroll("photos_maintenance_INDEX").performClick(); indexing = 1; confirm(); error()
        compose.onNodeWithText(text(R.string.sp_maintenance_changed)).performScrollTo().assertIsDisplayed(); capture("status-changed"); assertTrue(writes.isEmpty())
        indexing = 0; refresh(); form(); denied = true; scroll("photos_maintenance_INDEX").performClick(); confirm(); settled()
        compose.onNodeWithText(text(R.string.sp_maintenance_rejected)).performScrollTo().assertIsDisplayed(); capture("request-rejected"); assertEquals(1, writes.size)
    }
    @Test fun 共享入口需要管理员且确认前撤权或换用户都零写() {
        administrator = false; show(); ready(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithTag("photos_maintenance_menu").assertDoesNotExist(); capture("nonadministrator-menu")
        compose.onNode(hasText(text(R.string.sp_settings_display)) and hasAnyAncestor(isPopup())).performScrollTo().performClick()
        compose.waitUntil(5_000) { !model.settings!!.state.value.loading }; close()
        administrator = true; cold(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready(); menu(); form()
        scroll("photos_maintenance_INDEX").performClick(); administrator = false; confirm(); error()
        compose.onNodeWithText(text(R.string.sp_maintenance_permission)).performScrollTo().assertIsDisplayed(); capture("administrator-revoked"); assertTrue(writes.isEmpty())
        administrator = true; close(); menu(); form(); scroll("photos_maintenance_INDEX").performClick(); currentUserId = 42; confirm(); error()
        compose.onNodeWithText(text(R.string.sp_maintenance_permission)).performScrollTo().assertIsDisplayed(); capture("identity-changed"); assertTrue(writes.isEmpty())
    }
    @Test fun 提交处理中返回不重发完成记录保留() {
        show(); ready(); menu(); form(); writeGate = CompletableDeferred()
        scroll("photos_maintenance_INDEX").performClick(); confirm(); compose.waitUntil(5_000) { writes.size == 1 && maintenance.state.value.working }; capture("sending")
        close(); assertFalse(maintenance.state.value.visible); compose.runOnIdle { writeGate!!.complete(Unit); writeGate = null }
        compose.waitUntil(5_000) { !maintenance.state.value.working }; assertEquals(1, writes.size)
        menu(); form(); compose.onNodeWithText(text(R.string.sp_maintenance_idle_after_request)).performScrollTo().assertIsDisplayed(); capture("closed-while-sending")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album", "Index")
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
            if (call.api.endsWith("Index") && method == "get") { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            if (method == "reindex") writeGate?.await()
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$currentUserId,"is_admin":$administrator}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$personalEnabled,"team_space_permission":"management","ame_status":{"has_h264":$h264},"timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedEnabled}""")
        c.api.endsWith("Index") && c.method == "get" -> obj("""{"basic":$indexing,"thumbnail":$previews}""")
        c.method == "reindex" -> {
            if (denied) throw DsmFailure(100, "Synthetic rejected", "Synthetic recovery")
            if (c.fields["type"] == "\"basic\"") indexing = afterCount else previews = afterCount
            if (unknown) throw IOException("Synthetic missing receipt")
            obj("{}")
        }
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2020,"month":3,"day":2,"item_count":1},{"year":2020,"month":3,"day":1,"item_count":1}]}]}""")
        c.api.endsWith("Browse.Item") && c.method == "list" -> list(if (c.fields["offset"] == "0") listOf(photo(2), photo(1)) else emptyList())
        c.api.endsWith("Browse.Item") && c.method == "get" -> list(Json.parseToJsonElement(c.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long) })
        c.api.endsWith("Browse.Category") || c.api.endsWith("Browse.Album") -> list(emptyList())
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun photo(id: Long) = buildJsonObject {
        val time = Instant.parse(if (id == 2L) "2020-03-02T23:07:00Z" else "2020-03-01T12:00:00Z").epochSecond
        put("id", id); put("filename", "Synthetic$id.jpg"); put("filesize", 4); put("time", time); put("indexed_time", time); put("folder_id", 9); put("type", "photo")
        put("additional", obj("""{"thumbnail":{"unit_id":$id,"cache_key":"synthetic"},"description":"Synthetic description","address":{"country":"Synthetic country","state":"Synthetic state","county":"Synthetic county","city":"Synthetic city"}}"""))
    }
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun form() { compose.waitUntil(10_000) { !maintenance.state.value.loading && maintenance.state.value.status != null }; assertNull(maintenance.state.value.error) }
    private fun menu() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithTag("photos_maintenance_menu").performScrollTo().performClick() }
    private fun scroll(tag: String) = compose.onNodeWithTag(tag).performScrollTo()
    private fun refresh() { scroll("photos_maintenance_refresh").performClick() }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_maintenance_confirm").performClick() }
    private fun settled() { compose.waitUntil(10_000) { !maintenance.state.value.working && !maintenance.state.value.loading && maintenance.state.value.records.any { it.id == maintenance.state.value.activeId && it.checkpoint.finished } }; assertNull(maintenance.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !maintenance.state.value.working && !maintenance.state.value.loading && maintenance.state.value.records.any { !it.checkpoint.finished } }; assertNull(maintenance.state.value.error) }
    private fun error() { compose.waitUntil(10_000) { !maintenance.state.value.loading && !maintenance.state.value.working && maintenance.state.value.error != null } }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun photoReads() = calls.count { it.api.endsWith("Browse.Item") && it.method == "list" }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-maintenance-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
