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

/** 正式主题入口、仓储和加密恢复贯通；全部照片、主题及响应为合成夹具。 */
class SynologyPhotosConceptUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("concept-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private val editor get() = model.concepts!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>) {
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
        fun id(key: String) = fields.getValue(key).toLong()
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set_visibility", "set_cover", "hide_item") }
    private val mediaCalls = CopyOnWriteArrayList<Request>()
    private val concepts = ConcurrentHashMap<Long, JsonObject>().apply {
        put(1, concept(1, "Synthetic Nature", 3)); put(2, concept(2, "Synthetic Travel", 2)); put(3, concept(3, "Synthetic hidden", 2, false))
    }
    private val members = ConcurrentHashMap<Long, List<Long>>().apply { put(1, listOf(51, 52, 53)); put(2, listOf(54, 55)); put(3, listOf(56, 57)) }
    private var readGate: CompletableDeferred<Unit>? = null
    @Volatile private var failRead = false
    @Volatile private var unknown = false
    @Volatile private var applyWrites = true
    @Volatile private var partial = false
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
    }
    @Test fun 主题实际封面卡片隐藏直接保存且其他主题保留() {
        show(); library(); capture("concept-grid")
        compose.waitUntil(5_000) { mediaCalls.any { it.url.queryParameter("id") == "88" } }
        val request = mediaCalls.first { it.url.queryParameter("id") == "88" }
        assertEquals("GET", request.method); assertEquals("\"unit\"", request.url.queryParameter("type")); assertNull(request.url.queryParameter("album_id"))
        compose.onNodeWithTag("photos_concept_actions_1").performClick(); compose.onNodeWithTag("photos_concept_visibility").performClick(); form()
        assertEquals(setOf(1L), editor.state.value.selected); capture("hide-ready"); save(); finished(); capture("hide-saved")
        assertNull(editor.state.value.confirmation); assertEquals(mapOf("id" to "[1]", "visibility" to "false"), writes.single().fields)
        assertEquals(2, writes.single().version); close(); assertEquals(listOf(2L), model.state.value.collections.map { it.id })
        assertEquals(listOf(51L, 52L, 53L), members[1])
    }
    @Test fun 显示管理五态搜索隐藏主题并恢复显示() {
        show(); library(); readGate = CompletableDeferred(); visibilityMenu()
        compose.waitUntil(5_000) { editor.state.value.loading }; capture("concepts-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }; capture("concepts-error")
        failRead = false; scroll("photos_concepts_refresh").performClick(); form(); capture("concepts-normal")
        scroll("photos_concepts_visibility_true").performClick(); search("missing")
        compose.onNodeWithText(text(R.string.sp_concepts_search_empty)).assertExists(); capture("concepts-search-empty")
        search("hidden"); choose(3); capture("show-selected"); save(); finished(); capture("show-saved")
        assertEquals(mapOf("id" to "[3]", "visibility" to "true"), writes.single().fields)
        close(); assertEquals(setOf(1L, 2L, 3L), model.state.value.collections.map { it.id }.toSet())
        concepts.clear(); visibilityMenu(); form(); compose.onNodeWithText(text(R.string.sp_concepts_empty)).assertExists(); capture("concepts-empty")
        scroll("photos_concepts_save").assertIsNotEnabled()
    }
    @Test fun 主题预览菜单设封面直接保存精确照片编号() {
        show(); detail(); val before = model.state.value
        compose.runOnIdle { model.preview.open(model.state.value.items.first()) }
        compose.waitUntil(10_000) { !model.preview.state.value.loading && model.preview.state.value.image != null }
        compose.onNodeWithTag("photos_preview_actions").performScrollToNode(hasTestTag("photos_concept_selection_actions"))
        compose.onNodeWithTag("photos_concept_selection_actions").performClick()
        compose.onNodeWithTag("photos_concept_selection_COVER_CONCEPT").performClick(); form(); capture("cover-ready")
        save(); finished(); capture("cover-saved")
        assertEquals(mapOf("id" to "1", "photo_id" to "51"), writes.single().fields); assertEquals(1, writes.single().version)
        assertNull(editor.state.value.confirmation); scroll("photos_concepts_save").assertIsNotEnabled()
        assertEquals(before.selectedMonth, model.state.value.selectedMonth); assertEquals(before.items, model.state.value.items)
        assertEquals(51L, model.state.value.navigation.categoryItem!!.thumbnail!!.unitId)
    }
    @Test fun 多图移出实际阈值确认取消零写完成保留月份和原件() {
        show(); detail(); val before = model.state.value; val image = sourceImage.copyOf()
        select(listOf(51, 52)); selection(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS); form(); capture("remove-ready")
        save(); confirmation(); compose.onNodeWithText(text(R.string.sp_concept_threshold_risk)).assertExists(); capture("remove-threshold-risk")
        assertTrue(writes.isEmpty()); cancel(); assertTrue(writes.isEmpty()); save(); confirmation(); confirm(); finished(); capture("remove-saved")
        assertEquals(mapOf("id" to "1", "item_id" to "[51,52]"), writes.single().fields)
        assertEquals(listOf(53L), model.state.value.items.map { it.id.itemId }); assertEquals(before.selectedMonth, model.state.value.selectedMonth)
        assertEquals(before.months, model.state.value.months); assertEquals(1, model.state.value.navigation.categoryItem!!.count)
        assertTrue(model.edits!!.state.value.selected.isEmpty()); assertArrayEquals(image, sourceImage)
        assertTrue(calls.filter { it.api.endsWith("Browse.Item") && it.method == "get" }.flatMap { it.ids("id") }.containsAll(listOf(51L, 52L)))
        assertFalse(calls.any { it.method == "delete" || it.method == "delete_item" })
    }
    @Test fun 数量仍足够不显示隐藏风险且多选不能设封面() {
        show(); detail(); select(listOf(51, 52))
        compose.onNodeWithTag("photos_concept_selection_actions").performClick()
        compose.onNodeWithTag("photos_concept_selection_COVER_CONCEPT").assertIsNotEnabled()
        compose.onNodeWithTag("photos_concept_selection_REMOVE_CONCEPT_ITEMS").performClick(); form(); close()
        compose.runOnIdle { model.edits!!.selectMode(false) }; select(listOf(51)); selection(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS); form(); save(); confirmation()
        compose.onNodeWithText(text(R.string.sp_concept_threshold_risk)).assertDoesNotExist(); capture("remove-no-threshold-risk")
        confirm(); finished(); assertEquals(2, model.state.value.navigation.categoryItem!!.count)
    }
    @Test fun 部分移出只更新已确认照片其余保持选择() {
        partial = true; show(); detail(); select(listOf(51, 52)); selection(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS); form()
        save(); confirmation(); confirm(); compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.records.singleOrNull()?.checkpoint?.phase == SynologyPhotoAlbumPhase.PARTIAL }
        compose.onNodeWithTag("photos_concepts_list").performScrollToNode(hasText(text(R.string.sp_concepts_partial)))
        compose.onNodeWithText(text(R.string.sp_concepts_partial)).assertIsDisplayed(); capture("remove-partial")
        assertEquals(listOf(52L, 53L), model.state.value.items.map { it.id.itemId }); assertEquals(listOf(52L), model.edits!!.state.value.selected.map { it.id.itemId })
        assertEquals(listOf(52L), editor.state.value.photos.map { it.id.itemId }); assertEquals(1, writes.size)
    }
    @Test fun 断线加密冷恢复仅回读原操作不重发移出() {
        unknown = true; applyWrites = false; show(); detail(); select(listOf(51, 52)); selection(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS); form()
        save(); confirmation(); confirm(); pending(); capture("remove-unknown"); assertEquals(1, writes.size)
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; library(); visibilityMenu(); form()
        assertTrue(editor.state.value.pending); capture("remove-cold")
        val before = reads(); scroll("photos_concepts_review").performClick()
        compose.waitUntil(10_000) { reads() > before && !editor.state.value.working && editor.state.value.pending }; assertEquals(1, writes.size)
        apply(writes.single()); scroll("photos_concepts_review").performClick(); finished(); capture("remove-recovered")
        assertEquals(1, writes.size); assertEquals(listOf(53L), members.getValue(1))
    }
    @Test fun 共享主题正确路由且权限撤回后零新增写入() {
        sharedOnly = true; show(); detail(); select(listOf(51)); selection(SynologyPhotoAlbumAction.COVER_CONCEPT); form(); save(); finished(); capture("shared-cover-saved")
        assertEquals("SYNO.FotoTeam.Browse.Concept", writes.single().api)
        assertTrue(mediaCalls.any { it.url.encodedPath.contains("/t/") })
        close(); compose.runOnIdle { model.edits!!.selectMode(false) }; select(listOf(52)); selection(SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS); form(); manage = false; save()
        compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.error != null }; capture("shared-permission")
        assertEquals(1, writes.size); assertNull(editor.state.value.confirmation)
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Concept", "Browse.Album", "Browse.NormalAlbum", "Browse.Folder")
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
            if (cap.name.endsWith("Browse.Concept") && method in setOf("list", "get")) { readGate?.await(); if (failRead) throw IOException("Synthetic unavailable") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":${!sharedOnly},"team_space_permission":"${if (manage) "management" else "entry"}","enable_concept":true}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_concept":true}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedOnly,"enable_concept":true}""")
        c.api.endsWith("Browse.Category") -> obj("""{"list":[{"id":"concept"}]}""")
        c.api.endsWith("Browse.Album") -> list(emptyList())
        c.api.endsWith("Browse.Concept") && c.method == "list" -> list(concepts.values.sortedBy { it.getValue("id").jsonPrimitive.long }
            .filter { c.fields["show_hidden"] == "true" || it.getValue("visibility").jsonPrimitive.boolean && it.getValue("item_count").jsonPrimitive.int >= it.getValue("display_threshold").jsonPrimitive.int }
            .drop(c.id("offset").toInt()).take(c.id("limit").toInt()))
        c.api.endsWith("Browse.Concept") && c.method == "get" -> list(c.ids("id").mapNotNull(concepts::get))
        c.api.endsWith("Browse.Timeline") -> if (c.fields["concept_id"]?.toLong()?.let { members.getValue(it).isEmpty() } == true) obj("""{"section":[]}""")
            else obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":3}]}]}""")
        c.api.endsWith("Browse.Item") && c.method == "get" -> list(c.ids("id").map(::photo))
        c.api.endsWith("Browse.Item") -> list((c.fields["concept_id"]?.toLong()?.let { members[it].orEmpty() } ?: (51L..57L).toList())
            .drop(c.fields["offset"]?.toInt() ?: 0).take(c.fields["limit"]?.toInt() ?: 500).map(::photo))
        c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$manage}}}}""")
        c.method in setOf("set_visibility", "set_cover", "hide_item") -> {
            assertTrue(store.records(owner, 41).last { it.checkpoint.concept != null }.checkpoint.concept!!.attempted)
            if (applyWrites) apply(c)
            if (unknown) throw IOException("Synthetic interrupted response")
            obj("{}")
        }
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun apply(c: Call) {
        when (c.method) {
            "set_visibility" -> c.ids("id").let { if (partial) it.take(1) else it }.forEach { id ->
                concepts[id] = JsonObject(concepts.getValue(id) + ("visibility" to JsonPrimitive(c.fields.getValue("visibility").toBooleanStrict()))) }
            "set_cover" -> { val id = c.id("id"); concepts[id] = JsonObject(concepts.getValue(id) +
                ("additional" to obj("""{"thumbnail":{"unit_id":${c.id("photo_id")},"cache_key":"cover-new"}}"""))) }
            "hide_item" -> { val id = c.id("id"); val remove = c.ids("item_id").let { if (partial) it.take(1) else it }
                members[id] = members.getValue(id) - remove.toSet()
                concepts[id] = JsonObject(concepts.getValue(id) + ("item_count" to JsonPrimitive(members.getValue(id).size))) }
        }
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun library() {
        ready(); compose.runOnIdle { model.selectSection(SynologyPhotosSection.ALBUMS) }; ready()
        compose.runOnIdle { model.openCategory(SynologyPhotoCategory.SUBJECTS) }; ready()
        assertEquals(SynologyPhotoCategory.SUBJECTS, model.state.value.navigation.category)
    }
    private fun detail() { library(); compose.onNodeWithTag("photos_collection_1").performClick(); ready() }
    private fun select(ids: List<Long>) { compose.runOnIdle {
        model.edits!!.selectMode(true); ids.forEach { id -> model.edits!!.toggle(model.state.value.items.single { it.id.itemId == id }) }
    } }
    private fun selection(action: SynologyPhotoAlbumAction) {
        compose.onNodeWithTag("photos_concept_selection_actions").performClick()
        compose.onNodeWithTag("photos_concept_selection_${action.name}").performScrollTo().performClick()
    }
    private fun visibilityMenu() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithTag("photos_concepts_menu").performScrollTo().performClick() }
    private fun form() { compose.waitUntil(10_000) { !editor.state.value.loading && editor.state.value.loaded }; assertNull(editor.state.value.error) }
    private fun search(value: String) { scroll("photos_concepts_search").performTextReplacement(value); keyboard() }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_concepts_list").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun choose(id: Long) { scroll("photos_concepts_select_$id").performClick() }
    private fun save() { scroll("photos_concepts_save").performClick() }
    private fun confirmation() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.confirmation != null } }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_concepts_confirm").performClick() }
    private fun finished() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.records.isNotEmpty() && editor.state.value.records.all { it.checkpoint.finished } }; assertNull(editor.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.pending } }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick() }
    private fun reads() = calls.count { it.api.endsWith("Browse.Concept") && it.method == "get" }
    private fun text(id: Int) = context.getString(id)
    private fun keyboard() { androidx.test.espresso.Espresso.closeSoftKeyboard(); compose.waitForIdle() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-concepts-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        private fun concept(id: Long, name: String, count: Int, visible: Boolean = true) = obj("""{"id":$id,"name":${JsonPrimitive(name)},"item_count":$count,"visibility":$visible,"display_threshold":2,"additional":{"thumbnail":{"unit_id":88,"cache_key":"synthetic-$id"}}}""")
        private fun photo(id: Long) = obj("""{"id":$id,"filename":"Synthetic-$id.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo","additional":{"thumbnail":{"unit_id":$id,"cache_key":"photo-$id"},"resolution":{"width":96,"height":96},"orientation":1}}""")
    }
}
