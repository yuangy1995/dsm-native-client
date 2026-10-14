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
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*

/** 相似分组经正式入口、仓储、媒体和加密记录运行；全部响应和照片为合成数据。 */
class SynologyPhotosSimilarUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("similar-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private lateinit var deletionStore: SynologyPhotoDeletionStore
    private val editor get() = model.similar!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>) {
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
        fun id(key: String) = fields.getValue(key).toLong()
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set_top_pick", "remove_item", "ungroup", "add_item") }
    private val mediaCalls = CopyOnWriteArrayList<Request>()
    private val groups = ConcurrentHashMap<Long, Pair<List<Long>, Long>>().apply { put(1, listOf(51L, 52L, 53L) to 51L); put(2, listOf(61L, 62L) to 61L) }
    private var readGate: CompletableDeferred<Unit>? = null
    @Volatile private var failRead = false
    @Volatile private var unknown = false
    @Volatile private var applyWrites = true
    @Volatile private var manage = true
    private var sharedOnly = false
    private val sourceImage by lazy {
        ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
    }
    @After fun cleanup() {
        readGate?.complete(Unit); if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
        if (::deletionStore.isInitialized) deletionStore.removeProfile(owner.profileId)
    }
    @Test fun 打开完整组三张独立选择预览和推荐原位更新() {
        show(); library(); capture("similar-gallery"); openGroup(); capture("similar-group")
        assertEquals(listOf(51L, 52L, 53L), editor.state.value.detail!!.photos.map { it.id.itemId })
        scroll("photos_similar_member_52").onChildAt(0).performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo?.id?.itemId == 52L && !model.preview.state.value.loading }
        capture("similar-preview")
        val pages = calls.count { it.method == "list_similar" }
        compose.onNodeWithTag("photos_preview_actions").performScrollToNode(hasContentDescription(text(R.string.sp_slideshow_start)))
        compose.onNodeWithContentDescription(text(R.string.sp_slideshow_start)).performClick()
        compose.waitUntil(10_000) { model.slideshow.state.value.active && !model.slideshow.state.value.loading }
        compose.runOnIdle { model.slideshow.pause() }
        compose.onNodeWithContentDescription(text(R.string.sp_media_next)).performClick()
        compose.waitUntil(10_000) { !model.slideshow.state.value.loading && model.slideshow.preview.state.value.photo?.id?.itemId == 53L }
        assertEquals(pages, calls.count { it.method == "list_similar" }); assertNull(model.slideshow.state.value.error)
        assertEquals(listOf(51L, 52L, 53L), model.slideshow.previewItems.map { it.id.itemId }); capture("group-slideshow")
        compose.onNodeWithContentDescription(text(R.string.sp_slideshow_stop)).performClick(); choose(52); scroll("photos_similar_top_pick").performClick(); finished()
        assertTrue(editor.state.value.confirmation.isEmpty()); assertEquals(mapOf("id" to "1", "item_id" to "52"), writes.single().fields)
        assertEquals(52L, model.state.value.items.first().id.itemId); capture("similar-recommended")
    }
    @Test fun 移出确认取消零写实际完成后撤销恢复完整组() {
        show(); library(); openGroup(); choose(53); scroll("photos_similar_remove").performClick(); confirmation(); capture("remove-confirm")
        compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick(); assertTrue(writes.isEmpty())
        scroll("photos_similar_remove").performClick(); confirmation(); confirm(); finished()
        assertEquals(mapOf("id" to "1", "item_id" to "[53]"), writes.single().fields); assertEquals(listOf(51L, 52L), editor.state.value.detail!!.group.photoIds)
        scroll("photos_similar_undo").performClick(); finished(); capture("remove-undone")
        assertEquals("add_item", writes.last().method); assertEquals("[51,52,53]", writes.last().fields["item_id"])
        assertEquals(3, editor.state.value.detail!!.photos.size); compose.onAllNodesWithTag("photos_similar_undo").assertCountEquals(0)
    }
    @Test fun 批量拆组未知暂停冷启动只读恢复再继续并逆序撤销() {
        show(); library(); compose.runOnIdle { model.edits!!.selectMode(true); model.state.value.items.forEach(model.edits!!::toggle) }
        compose.onNodeWithTag("photos_similar_ungroup_selected").performClick(); confirmation(); unknown = true; applyWrites = false; confirm(); pending()
        assertEquals(1, writes.size); assertEquals(2, store.records(owner, 41).size)
        scroll("photos_similar_continue").assertIsNotEnabled(); capture("batch-pending")
        compose.runOnIdle { model.close(); store = SynologyPhotoAlbumStore(context); model = makeModel(); epoch++ }; ready()
        compose.runOnIdle { editor.showRecords(SynologyPhotoSpace.PERSONAL) }; form(); pending(); assertEquals(1, writes.size)
        apply(writes.single()); unknown = false; applyWrites = true; scroll("photos_similar_review").performClick()
        compose.waitUntil(10_000) { !editor.state.value.working && !editor.state.value.pending }
        scroll("photos_similar_continue").performClick(); confirmation(); confirm(); finished(); assertEquals(2, writes.size)
        compose.onNodeWithTag("photos_similar_group").performScrollToNode(hasTestTag("photos_similar_undo"))
        compose.onAllNodesWithTag("photos_similar_undo").onFirst().performClick(); finished(); capture("batch-undone")
        assertEquals(listOf("2", "1"), writes.takeLast(2).map { it.fields["id"] }); assertEquals(2, groups.size)
    }
    @Test fun 整组导出读取所有成员且清理只进入既有原件删除确认() {
        show(); library(); openGroup(); choose(52); scroll("photos_similar_export").performClick()
        compose.waitUntil(10_000) { model.exports.state.value.phase == SynologyPhotoExportPhase.FORMAT }
        assertEquals(listOf(51L, 52L, 53L), (model.exports.state.value.request as SynologyPhotoExportRequest.Items).photos.map { it.id.itemId })
        capture("group-export"); compose.onNodeWithContentDescription(text(R.string.close)).performClick(); scroll("photos_similar_clean_up").performClick()
        compose.waitUntil(10_000) { !model.deletion.state.value.checking && (model.deletion.state.value.candidate != null || model.deletion.state.value.error != null) }
        assertNull(model.deletion.state.value.error)
        assertEquals(listOf(51L, 53L), model.deletion.state.value.candidate!!.map { it.id.itemId }); capture("keep-selected-delete-confirm")
        closeDialog(); assertTrue(writes.isEmpty()); assertTrue(calls.none { it.method == "delete" })
    }
    @Test fun 共享分组权限撤回不写且读取失败刷新恢复解散和记录空态() {
        sharedOnly = true; show(); library(); readGate = CompletableDeferred(); openGroup(wait = false)
        compose.waitUntil(10_000) { editor.state.value.loading }; capture("similar-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(10_000) { !editor.state.value.loading && editor.state.value.error != null }; capture("similar-error")
        failRead = false; scroll("photos_similar_refresh").performClick(); form(); choose(52); scroll("photos_similar_top_pick").performClick(); finished()
        assertEquals("SYNO.FotoTeam.Browse.Similar", writes.single().api); assertTrue(mediaCalls.any { it.url.encodedPath.contains("/t/") })
        choose(51); manage = false; scroll("photos_similar_top_pick").performClick()
        compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.error != null }; capture("similar-permission"); assertEquals(1, writes.size)
        manage = true; groups.remove(1); scroll("photos_similar_refresh").performClick(); form(); assertTrue(editor.state.value.dissolved); capture("similar-dissolved")
        closeDialog(); compose.runOnIdle { editor.showRecords(SynologyPhotoSpace.PERSONAL) }; form(); capture("similar-records-empty")
        compose.onNodeWithText(text(R.string.sp_similar_records_empty)).assertExists()
    }
    private fun show() {
        deletionStore = SynologyPhotoDeletionStore(context); store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline", "Browse.Album", "Browse.NormalAlbum", "Browse.Folder", "BackgroundTask.File")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); mediaCalls += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                .header("Content-Type", "image/png").body(sourceImage.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic", "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, cap.maxVersion, method, fields); calls += call
            if (cap.name.endsWith("Browse.Similar") && method in setOf("list", "get")) { readGate?.await(); if (failRead) throw IOException("Synthetic unavailable") }
            response(call)
        }, media, canDeleteOriginals = true)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore, deletionStore = deletionStore)
    }

    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":${!sharedOnly},"team_space_permission":"${if (manage) "management" else "entry"}","enable_similar":true}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_similar":true}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedOnly,"enable_similar":true}""")
        c.api.endsWith("Browse.Category") -> obj("""{"list":[{"id":"similar"}]}""")
        c.api.endsWith("Browse.Album") -> list(emptyList())
        c.api.endsWith("Browse.Similar") && c.method == "get_status" -> obj("""{"waiting_count":3,"similar_clustering_stage":"running","is_similar_hash_migration_done":true}""")
        c.api.endsWith("Browse.Similar") && c.method == "get" -> list(c.ids("id").mapNotNull { group(it) })
        c.api.endsWith("Browse.SimilarTimeline") || c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":2}]}]}""")
        c.api.endsWith("Browse.SimilarItem") && c.method == "list_similar" -> list(groups.toSortedMap().values.map { photo(it.second, true) }
            .drop(c.id("offset").toInt()).take(c.id("limit").toInt()))
        c.api.endsWith("Browse.SimilarItem") -> list(c.ids("id").map { photo(it, true) })
        c.api.endsWith("Browse.Item") && c.method == "get" -> list(c.ids("id").map { photo(it) })
        c.api.endsWith("Browse.Item") -> list(listOf(51L, 52L, 53L, 61L, 62L).map { photo(it) })
        c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$manage}}}}""")
        c.method in setOf("set_top_pick", "remove_item", "ungroup", "add_item") -> {
            val pending = store.records(owner, 41).filter { it.checkpoint.similar?.attempted == true }
            assertTrue(pending.isNotEmpty())
            if (applyWrites) apply(c)
            if (unknown) throw IOException("Synthetic interrupted response")
            obj("{}")
        }
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun apply(c: Call) {
        if (c.method == "ungroup") { c.ids("id").forEach(groups::remove); return }
        val id = c.id("id")
        when (c.method) {
            "set_top_pick" -> groups[id] = groups.getValue(id).first to c.id("item_id")
            "remove_item" -> {
                val old = groups.getValue(id); val remaining = old.first - c.ids("item_id").toSet()
                if (remaining.size < 2) groups.remove(id) else groups[id] = remaining to (old.second.takeIf(remaining::contains) ?: remaining.first())
            }
            "add_item" -> groups[id] = c.ids("item_id") to c.id("top_pick")
        }
    }
    private fun group(id: Long): JsonObject? = groups[id]?.let { obj("""{"id":$id,"count":${it.first.size},"top_pick":${it.second},"item_id":${JsonArray(it.first.map(::JsonPrimitive))}}""") }
    private fun photo(id: Long, similar: Boolean = false): JsonObject {
        val base = obj("""{"id":$id,"filename":"Synthetic-$id.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo","additional":{"thumbnail":{"unit_id":$id,"cache_key":"photo-$id"},"resolution":{"width":96,"height":96},"orientation":1}}""")
        return if (!similar) base else JsonObject(base + ("similar" to (groups.entries.singleOrNull { id in it.value.first }?.key?.let(::group) ?: JsonNull)))
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun library() {
        ready(); compose.runOnIdle { model.selectSection(SynologyPhotosSection.ALBUMS) }; ready()
        compose.onNodeWithText(text(R.string.sp_category_similar)).performClick(); ready()
    }
    private fun openGroup(wait: Boolean = true) {
        compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Synthetic-51.jpg")).performClick()
        if (wait) form()
    }
    private fun form() { compose.waitUntil(10_000) { !editor.state.value.loading && editor.state.value.loaded }; assertNull(editor.state.value.error) }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_similar_group").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun choose(id: Long) { scroll("photos_similar_select_$id").performClick() }
    private fun confirmation() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.confirmation.isNotEmpty() }; assertNull(editor.state.value.error) }
    private fun confirm() { compose.onNodeWithTag("photos_similar_confirm").performClick() }
    private fun finished() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.records.isNotEmpty() && editor.state.value.records.all { it.checkpoint.finished } }; assertNull(editor.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.pending } }
    private fun closeDialog() { compose.onAllNodes(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).onLast().performClick() }
    private fun text(id: Int) = context.getString(id)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-similar-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    }
}
