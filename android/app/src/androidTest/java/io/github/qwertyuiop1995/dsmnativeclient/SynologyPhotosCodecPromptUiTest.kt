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

/** 正式两阶段仓储、根图库与加密恢复；合成数据覆盖多次保存及冷恢复。 */
class SynologyPhotosCodecPromptUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("codec-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private val codec get() = model.codecPrompt!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("reindex", "reindex_all_user", "set") }
    private var administrator = true; private var currentUserId = 41L
    private var personalEnabled = true; private var sharedEnabled = true
    private var promptShow = true; private var failRead = false; private var unknown = false; private var denied = false
    private var promptDenied = false; private var promptUnknown = false
    private var gate: CompletableDeferred<Unit>? = null; private var writeGate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit); writeGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }
    @Test fun 加载无提示与取消均零写普通账号无个人来源只能稍后() {
        show(); ready(); gate = CompletableDeferred(); menu(); compose.waitUntil(5_000) { codec.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); scroll("photos_codec_generate").performClick()
        compose.onNodeWithText(text(R.string.sp_codec_all_users_risk)).assertIsDisplayed(); capture("all-users-confirmation"); cancel(); assertTrue(writes.isEmpty())
        promptShow = false; refresh(); form(); compose.onNodeWithText(text(R.string.sp_codec_empty)).assertIsDisplayed(); capture("empty")
        promptShow = true; administrator = false; personalEnabled = false; refresh(); form()
        scroll("photos_codec_generate").assertIsNotEnabled(); scroll("photos_codec_later").assertIsEnabled(); capture("personal-unavailable")
        assertTrue(writes.isEmpty())
    }
    @Test fun 普通账号生成保留历史月份和原件选择且不刷新图库() {
        administrator = false; show(); ready(); compose.runOnIdle { model.jumpToMonth(YearMonth.of(2020, 3)) }; ready()
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.first()) }
        val old = model.state.value; val selected = model.edits!!.state.value.selected; val reads = photoReads()
        menu(); form(); scroll("photos_codec_generate").performClick()
        compose.onNodeWithText(text(R.string.sp_codec_personal_risk)).assertIsDisplayed(); capture("personal-confirmation"); confirm(); settled(); capture("generation-received")
        assertEquals(listOf("reindex", "set"), writes.map { it.method }); assertEquals("SYNO.Foto.Index", writes.first().api)
        assertEquals(mapOf("type" to "\"thumbnail\""), writes.first().fields)
        assertEquals(old.items, model.state.value.items); assertEquals(old.selectedMonth, model.state.value.selectedMonth)
        assertEquals(selected, model.edits!!.state.value.selected); assertEquals(reads, photoReads()); close(); capture("selection-preserved")
    }
    @Test fun 管理员两图库关闭仍能从相册进入全用户生成() {
        personalEnabled = false; sharedEnabled = false; show(); ready(); assertTrue(model.state.value.access!!.spaces.isEmpty())
        assertEquals(SynologyPhotosSection.ALBUMS, model.state.value.navigation.section); menu(); form()
        scroll("photos_codec_generate").assertIsEnabled().performClick(); compose.onNodeWithText(text(R.string.sp_codec_all_users_risk)).assertIsDisplayed()
        confirm(); settled(); capture("no-library-admin-received"); assertEquals(listOf("reindex_all_user", "set"), writes.map { it.method })
    }
    @Test fun 稍后直接保存固定提示且不生成预览() {
        show(); ready(); menu(); form(); scroll("photos_codec_later").performClick(); settled(); capture("later-saved")
        assertEquals(listOf("set"), writes.map { it.method }); assertEquals("SYNO.Foto.Setting.Wizard", writes.single().api)
        assertEquals(mapOf("prompt" to """[{"name":"new_codec_installed","show":false}]"""), writes.single().fields)
        assertFalse(codec.state.value.prompt!!.shouldShow)
    }
    @Test fun 生成明确拒绝保留提示且可以清除失败记录后重新操作() {
        denied = true; show(); ready(); menu(); form(); scroll("photos_codec_generate").performClick(); confirm(); settled()
        compose.onNodeWithText(text(R.string.sp_codec_rejected)).performScrollTo().assertIsDisplayed(); capture("generation-rejected")
        assertTrue(codec.state.value.prompt!!.shouldShow); assertEquals(listOf("reindex_all_user"), writes.map { it.method })
        scroll("photos_codec_clear").performClick(); compose.waitUntil(5_000) { codec.state.value.records.isEmpty() }
        denied = false; scroll("photos_codec_later").performClick(); settled(); assertEquals(listOf("reindex_all_user", "set"), writes.map { it.method })
    }
    @Test fun 丢失生成回执冷恢复只读即使提示关闭也不追认() {
        unknown = true; show(); ready(); menu(); form(); scroll("photos_codec_generate").performClick(); confirm(); pending(); capture("generation-unknown")
        cold(); menu(); form(); scroll("photos_codec_generate").assertIsNotEnabled(); scroll("photos_codec_later").assertIsNotEnabled()
        compose.onNodeWithTag("photos_codec_clear").assertDoesNotExist(); compose.onNodeWithTag("photos_codec_continue").assertDoesNotExist()
        promptShow = false; scroll("photos_codec_review").performClick(); pending(); capture("unknown-cold-closed-prompt")
        assertEquals(1, writes.size); assertFalse(codec.state.value.records.single().checkpoint.finished)
    }
    @Test fun 生成接收提示拒绝冷恢复只保存提示完成后新提示可再处理() {
        promptDenied = true; show(); ready(); menu(); form(); scroll("photos_codec_generate").performClick(); confirm(); pending()
        scroll("photos_codec_continue").assertIsEnabled(); capture("partial"); assertEquals(2, writes.size)
        cold(); menu(); form(); compose.onNodeWithTag("photos_codec_clear").assertDoesNotExist(); scroll("photos_codec_generate").assertIsNotEnabled()
        scroll("photos_codec_review").performClick(); pending(); assertEquals(2, writes.size); capture("partial-cold")
        promptDenied = false; scroll("photos_codec_continue").performClick(); settled(); capture("continued-save-complete")
        assertEquals(listOf("reindex_all_user", "set", "set"), writes.map { it.method })
        promptShow = true; refresh(); form(); scroll("photos_codec_generate").assertIsEnabled().performClick(); cancel(); assertEquals(3, writes.size)
    }
    @Test fun 提示回执未知只读恢复不能重复保存提示() {
        promptUnknown = true; show(); ready(); menu(); form(); scroll("photos_codec_generate").performClick(); confirm(); pending(); capture("save-unknown")
        cold(); menu(); form(); compose.onNodeWithTag("photos_codec_continue").assertDoesNotExist(); assertEquals(2, writes.size)
        promptShow = false; scroll("photos_codec_review").performClick(); settled(); capture("save-observed-closed")
        assertEquals(2, writes.size)
    }
    @Test fun 读取失败可恢复确认后范围变化零写发送后关闭页面保留结果() {
        show(); ready(); failRead = true; menu(); error(); capture("read-error"); assertTrue(writes.isEmpty())
        failRead = false; refresh(); form(); scroll("photos_codec_generate").performClick(); administrator = false; confirm(); error(); capture("scope-changed")
        assertTrue(writes.isEmpty()); refresh(); form(); writeGate = CompletableDeferred(); scroll("photos_codec_generate").performClick(); confirm()
        compose.waitUntil(5_000) { writes.isNotEmpty() && codec.state.value.working }; capture("submitting")
        compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick()
        compose.runOnIdle { writeGate!!.complete(Unit); writeGate = null }; compose.waitUntil(5_000) { !codec.state.value.working }
        assertFalse(codec.state.value.visible); assertEquals(listOf("reindex", "set"), writes.map { it.method })
        menu(); form()
        val saved = codec.state.value.records.single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, saved.phase); assertTrue(saved.codecPrompt!!.generationAcknowledged); assertTrue(saved.codecPrompt!!.promptClosed)
        compose.onNodeWithText(text(R.string.sp_codec_received)).performScrollTo().assertIsDisplayed(); capture("closed-during-save-result")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album", "Index", "Setting.Wizard")
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
            if (call.api.endsWith("Setting.Wizard") && method == "get") { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            if (method in setOf("reindex", "reindex_all_user")) writeGate?.await()
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$currentUserId,"is_admin":$administrator}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$personalEnabled,"team_space_permission":"management","timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"album_list_sort_by":"create_time","album_list_sort_direction":"desc","album_display_type":"all_album"}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedEnabled}""")
        c.api.endsWith("Setting.Wizard") && c.method == "get" -> obj("""{"prompt":[{"name":"other","show":true},{"name":"new_codec_installed","show":$promptShow}]}""")
        c.api.endsWith("Setting.Wizard") && c.method == "set" -> {
            if (promptDenied) throw DsmFailure(100, "Synthetic rejected", "Synthetic recovery")
            if (promptUnknown) throw IOException("Synthetic missing receipt")
            promptShow = false; obj("{}")
        }
        c.method in setOf("reindex", "reindex_all_user") -> {
            if (denied) throw DsmFailure(100, "Synthetic rejected", "Synthetic recovery")
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
    private fun form() { compose.waitUntil(10_000) { !codec.state.value.loading && codec.state.value.prompt != null }; assertNull(codec.state.value.error) }
    private fun menu() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithTag("photos_codec_menu").performScrollTo().performClick() }
    private fun scroll(tag: String) = compose.onNodeWithTag(tag).performScrollTo()
    private fun refresh() { scroll("photos_codec_refresh").performClick() }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_codec_confirm").performClick() }
    private fun settled() { compose.waitUntil(10_000) { !codec.state.value.working && !codec.state.value.loading && codec.state.value.records.any { it.id == codec.state.value.activeId && it.checkpoint.finished } }; assertNull(codec.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !codec.state.value.working && !codec.state.value.loading && codec.state.value.records.any { !it.checkpoint.finished } }; assertNull(codec.state.value.error) }
    private fun error() { compose.waitUntil(10_000) { !codec.state.value.loading && !codec.state.value.working && codec.state.value.error != null } }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun photoReads() = calls.count { it.api.endsWith("Browse.Item") && it.method == "list" }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-codec-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
