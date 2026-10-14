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
import java.time.YearMonth
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

/** 正式人物页面、仓储和加密恢复；所有人物、图片与网络响应均为合成测试数据。 */
class SynologyPhotosPeopleUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("people-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private val editor get() = model.people!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
        fun id(key: String) = fields.getValue(key).toLong()
        fun text(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonPrimitive.content
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set", "merge", "show") }
    private val mediaCalls = CopyOnWriteArrayList<Request>()
    private val people = ConcurrentHashMap<Long, JsonObject>().apply {
        put(1, person(1, "Synthetic A", 1)); put(2, person(2, "Synthetic B", 1)); put(3, person(3, "Synthetic hidden", 1, false))
    }
    private val members = ConcurrentHashMap<Long, List<Long>>().apply { put(1, listOf(51)); put(2, listOf(52)); put(3, listOf(53)) }
    private var readGate: CompletableDeferred<Unit>? = null
    @Volatile private var failRead = false
    @Volatile private var unknown = false
    @Volatile private var applyWrites = true
    @Volatile private var partialShow = false
    @Volatile private var manage = true
    private var sharedOnly = false

    @After fun cleanup() {
        readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }
    @Test fun 人物封面与普通命名从卡片菜单直接保存并局部更新() {
        show(); library(); capture("person-grid")
        compose.waitUntil(5_000) { mediaCalls.any { it.url.queryParameter("type") == "\"person\"" } }
        val request = mediaCalls.first { it.url.queryParameter("type") == "\"person\"" }
        assertEquals("GET", request.method); assertNull(request.url.queryParameter("size")); assertNull(request.url.queryParameter("id_album"))
        action(SynologyPhotoAlbumAction.RENAME_PERSON); form(); name("Synthetic renamed"); capture("rename-ready")
        failRead = true; scroll("photos_people_refresh").performClick()
        compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }; capture("rename-refresh-error")
        failRead = false; scroll("photos_people_refresh").performClick(); form()
        scroll("photos_person_name").assertTextContains("Synthetic renamed"); assertTrue(writes.isEmpty()); capture("rename-refreshed")
        save(); finished(); assertNull(editor.state.value.confirmation); capture("rename-saved")
        assertEquals(mapOf("id" to "1", "name" to "\"Synthetic renamed\""), writes.single().fields)
        close(); compose.onNodeWithText("Synthetic renamed").assertExists()
        assertEquals(SynologyPhotoCategory.PEOPLE, model.state.value.navigation.category)
        assertEquals("Synthetic B", model.state.value.collections.single { it.id == 2L }.name)
    }
    @Test fun 少量照片清空名称说明隐去后果取消不写确认后保留原件() {
        show(); library(); action(SynologyPhotoAlbumAction.RENAME_PERSON); form(); name(""); save(); confirmation(); capture("clear-risk")
        assertTrue(writes.isEmpty()); cancel(); assertTrue(writes.isEmpty())
        save(); confirmation(); confirm(); finished(); capture("clear-saved")
        assertEquals(listOf(51L), members[1]); assertFalse(people.getValue(1).getValue("show").jsonPrimitive.boolean)
        assertEquals(setOf(1L), editor.state.value.records.single().checkpoint.people!!.removedIds)
        close(); assertEquals(listOf(2L), model.state.value.collections.map { it.id })
    }
    @Test fun 合并固定目标且确认前不写完成后成员完整并更新卡片() {
        show(); library(); action(SynologyPhotoAlbumAction.MERGE_PEOPLE); form(); capture("merge-ready")
        compose.onNodeWithTag("photos_people_select_1").assertDoesNotExist()
        choose(2); name("Synthetic merged"); save(); confirmation(); capture("merge-risk"); cancel()
        assertTrue(writes.isEmpty()); assertEquals(1L, editor.state.value.target!!.id)
        save(); confirmation(); confirm(); finished(); capture("merge-saved")
        assertEquals(mapOf("target_id" to "1", "merged_id" to "[2]", "name" to "\"Synthetic merged\""), writes.single().fields)
        assertEquals(setOf(51L, 52L), members.getValue(1).toSet()); assertFalse(people.containsKey(2))
        close(); assertEquals(1, model.state.value.collections.size); assertEquals(2, model.state.value.collections.single().count)
    }
    @Test fun 隐藏人物五态搜索及显示保存后更新网格() {
        show(); library(); readGate = CompletableDeferred(); visibilityMenu()
        compose.waitUntil(5_000) { editor.state.value.loading }; capture("people-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }; capture("people-error")
        failRead = false; compose.onNodeWithTag("photos_people_refresh").performClick(); form(); capture("people-normal")
        scroll("photos_people_visibility_true").performClick()
        search("missing"); compose.onNodeWithText(text(R.string.sp_people_search_empty)).assertExists(); capture("people-search-empty")
        search("hidden"); choose(3); capture("people-show-selected"); save(); finished(); capture("people-show-saved")
        assertEquals(mapOf("id" to "[3]", "show" to "true"), writes.single().fields)
        close(); assertEquals(setOf(1L, 2L, 3L), model.state.value.collections.map { it.id }.toSet())
        people.clear(); visibilityMenu(); form(); compose.onNodeWithText(text(R.string.sp_people_empty)).assertExists(); capture("people-empty")
        compose.onNodeWithTag("photos_people_save").assertIsNotEnabled()
    }
    @Test fun 批量隐藏明确回执但仅部分匹配时显示部分结果() {
        partialShow = true; show(); library(); visibilityMenu(); form(); choose(1); choose(2); save()
        compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.records.singleOrNull()?.checkpoint?.phase == SynologyPhotoAlbumPhase.PARTIAL }
        assertEquals(setOf(1L), editor.state.value.records.single().checkpoint.people!!.completedIds)
        compose.onNodeWithTag("photos_people_list").performScrollToNode(hasText(text(R.string.sp_people_partial))); compose.onNodeWithText(text(R.string.sp_people_partial)).assertIsDisplayed(); capture("people-partial")
        close(); assertEquals(listOf(2L), model.state.value.collections.map { it.id }); assertEquals(1, writes.size)
    }
    @Test fun 合并断线后加密冷恢复只读直到完整成员一致且不重发() {
        unknown = true; applyWrites = false; show(); library(); action(SynologyPhotoAlbumAction.MERGE_PEOPLE); form(); choose(2)
        save(); confirmation(); confirm(); pending(); capture("merge-unknown"); assertEquals(1, writes.size)
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; library(); visibilityMenu(); form()
        assertTrue(editor.state.value.pending); capture("merge-cold")
        val before = reads(); scroll("photos_people_review").performClick()
        compose.waitUntil(10_000) { reads() > before && !editor.state.value.working && editor.state.value.pending }
        assertEquals(1, writes.size)
        apply(writes.single()); scroll("photos_people_review").performClick(); finished(); capture("merge-recovered")
        assertEquals(1, writes.size); assertEquals(setOf(51L, 52L), members.getValue(1).toSet())
    }
    @Test fun 共享人物使用正确来源权限撤回后保存失败且不写() {
        sharedOnly = true; show(); library(); action(SynologyPhotoAlbumAction.RENAME_PERSON); form(); name("Synthetic shared")
        save(); finished(); capture("shared-saved"); assertEquals("SYNO.FotoTeam.Browse.Person", writes.single().api)
        assertTrue(mediaCalls.any { it.url.encodedPath.contains("/t/") && it.url.queryParameter("type") == "\"person\"" })
        close(); action(SynologyPhotoAlbumAction.RENAME_PERSON); form(); name("Synthetic denied"); manage = false; save()
        compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.error != null }; capture("shared-permission")
        assertEquals(1, writes.size); assertEquals("Synthetic denied", editor.state.value.name)
    }
    @Test fun 人物详情改名保留月份照片选择和导航() {
        show(); library(); compose.onNodeWithText("Synthetic A").performClick(); ready()
        compose.runOnIdle { model.jumpToMonth(YearMonth.of(2026, 10)) }; ready()
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.single()) }
        val before = model.state.value
        compose.runOnIdle { editor.open(SynologyPhotoAlbumAction.RENAME_PERSON, before.navigation.space, before.navigation.categoryItem) }
        form(); name("Synthetic detail"); save(); finished(); close(); capture("detail-renamed")
        assertEquals(before.items, model.state.value.items); assertEquals(before.months, model.state.value.months)
        assertEquals(before.selectedMonth, model.state.value.selectedMonth); assertEquals(before.navigation.copy(categoryItem = before.navigation.categoryItem!!.copy(name = "Synthetic detail")), model.state.value.navigation)
        assertEquals(before.items.single().id, model.edits!!.state.value.selected.single().id)
    }

    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Album", "Browse.NormalAlbum", "Browse.Folder")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); mediaCalls += request
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic", "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (cap.name.endsWith("Browse.Person") && method == "list") { readGate?.await(); if (failRead) throw IOException("Synthetic unavailable") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":${!sharedOnly},"team_space_permission":"${if (manage) "management" else "entry"}","enable_person":true}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_person":true}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$sharedOnly,"enable_person":true}""")
        c.api.endsWith("Browse.Category") -> obj("""{"list":[{"id":"person"}]}""")
        c.api.endsWith("Browse.Album") -> list(emptyList())
        c.api.endsWith("Browse.Person") && c.method == "list" -> list(people.values.sortedBy { it.getValue("id").jsonPrimitive.long }
            .filter { c.fields["show_hidden"] == "true" || it.getValue("show").jsonPrimitive.boolean }.drop(c.id("offset").toInt()).take(c.id("limit").toInt()))
        c.api.endsWith("Browse.Person") && c.method == "get" -> list(c.ids("id").mapNotNull(people::get))
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":1}]}]}""")
        c.api.endsWith("Browse.Item") -> list(((c.fields["person_id"]?.toLong() ?: c.fields["person"]?.let { c.ids("person").single() })?.let { members[it].orEmpty() } ?: members.values.flatten())
            .drop(c.fields["offset"]?.toInt() ?: 0).take(c.fields["limit"]?.toInt() ?: 500).map(::photo))
        c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$manage}}}}""")
        c.method in setOf("set", "merge", "show") -> {
            assertTrue(store.records(owner, 41).last { it.checkpoint.people != null }.checkpoint.people!!.attempted)
            if (applyWrites) apply(c)
            if (unknown) throw IOException("Synthetic interrupted response")
            if (c.method == "set") obj("""{"id":${c.id("id")},"name":${c.fields.getValue("name")}}""") else obj("{}")
        }
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun apply(c: Call) {
        when (c.method) {
            "set" -> {
                val id = c.id("id"); val old = people.getValue(id); val name = c.text("name")
                people[id] = JsonObject(old + ("name" to JsonPrimitive(name)) +
                    if (name.isEmpty() && old.getValue("item_count").jsonPrimitive.int < 2) mapOf("show" to JsonPrimitive(false)) else emptyMap())
            }
            "show" -> c.ids("id").let { if (partialShow) it.take(1) else it }.forEach { id ->
                people[id] = JsonObject(people.getValue(id) + ("show" to JsonPrimitive(c.fields.getValue("show").toBooleanStrict())))
            }
            "merge" -> {
                val target = c.id("target_id"); val sources = c.ids("merged_id")
                members[target] = (listOf(target) + sources).flatMap { members.getValue(it) }.distinct()
                people[target] = person(target, c.text("name"), members.getValue(target).size)
                sources.forEach { people.remove(it); members.remove(it) }
            }
        }
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun library() {
        ready(); compose.runOnIdle { model.selectSection(SynologyPhotosSection.ALBUMS) }; ready()
        compose.runOnIdle { model.openCategory(SynologyPhotoCategory.PEOPLE) }; ready()
        assertEquals(SynologyPhotoCategory.PEOPLE, model.state.value.navigation.category)
    }
    private fun action(action: SynologyPhotoAlbumAction) {
        compose.onNodeWithTag("photos_person_actions_1").performClick()
        compose.onNodeWithTag("photos_person_menu_${action.name}").performScrollTo().performClick()
    }
    private fun visibilityMenu() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithTag("photos_people_menu").performScrollTo().performClick() }
    private fun form() { compose.waitUntil(10_000) { !editor.state.value.loading && editor.state.value.loaded }; assertNull(editor.state.value.error) }
    private fun name(value: String) { scroll("photos_person_name").performTextReplacement(value) }
    private fun search(value: String) { scroll("photos_people_search").performTextReplacement(value) }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_people_list").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun choose(id: Long) { compose.onNodeWithTag("photos_people_list").performScrollToNode(hasTestTag("photos_people_select_$id")); compose.onNodeWithTag("photos_people_select_$id").performClick() }
    private fun save() { scroll("photos_people_save").performClick() }
    private fun confirmation() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.confirmation != null } }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_people_confirm").performClick() }
    private fun finished() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.records.isNotEmpty() && editor.state.value.records.all { it.checkpoint.finished } }; assertNull(editor.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.pending } }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick() }
    private fun reads() = calls.count { it.api.endsWith("Browse.Person") && it.method == "list" }
    private fun text(id: Int) = context.getString(id)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-people-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        private fun person(id: Long, name: String, count: Int, shown: Boolean = true) = obj("""{"id":$id,"name":${JsonPrimitive(name)},"item_count":$count,"show":$shown,"additional":{"thumbnail":{"cache_key":"synthetic-$id"}}}""")
        private fun photo(id: Long) = obj("""{"id":$id,"filename":"Synthetic-$id.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo"}""")
    }
}
