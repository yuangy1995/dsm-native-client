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

/** 人物详情实际选择入口、人脸传输与加密恢复；全部人物、人脸和原件均为合成数据。 */
class SynologyPhotosPersonFacesUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("faces-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
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
    private val writes get() = calls.filter { it.method in setOf("delete_face", "separate", "set_cover") }
    private val mediaCalls = CopyOnWriteArrayList<Request>()
    private val people = ConcurrentHashMap<Long, JsonObject>().apply {
        put(1, person(1, "Synthetic A", 2)); put(2, person(2, "Synthetic B", 1)); put(3, person(3, "Synthetic hidden", 1, false))
    }
    private val members = ConcurrentHashMap<Long, List<Long>>().apply { put(1, listOf(51, 52)); put(2, listOf(53)); put(3, listOf(54)) }
    private val faces = ConcurrentHashMap<Long, Pair<Long, Long>>().apply { put(101, 1L to 51L); put(102, 1L to 51L); put(103, 1L to 52L) }
    private var readGate: CompletableDeferred<Unit>? = null
    @Volatile private var failRead = false
    @Volatile private var unknown = false
    @Volatile private var applyWrites = true
    @Volatile private var manage = true
    private var sharedOnly = false

    @After fun cleanup() {
        readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }
    @Test fun 移出人脸从实际选择菜单取消零写确认只移走没有剩余人脸的照片() {
        show(); detail(); val before = model.state.value
        action(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES); form(); capture("remove-ready")
        compose.waitUntil(5_000) { mediaCalls.any { it.url.queryParameter("type") == "\"face\"" } }
        val image = mediaCalls.first { it.url.queryParameter("type") == "\"face\"" }; assertEquals("GET", image.method); assertNull(image.url.queryParameter("size"))
        scroll("photos_face_102").performClick(); save(); confirmation(); capture("remove-risk"); cancel(); assertTrue(writes.isEmpty())
        save(); confirmation(); confirm(); finished(); capture("remove-saved")
        assertEquals(mapOf("person_id" to "1", "face_id" to "[101,103]"), writes.single().fields)
        assertEquals(setOf(52L), editor.state.value.records.single().checkpoint.people!!.faces!!.removedPhotoIds)
        close(); capture("remove-detail")
        assertEquals(listOf(51L), model.state.value.items.map { it.id.itemId }); assertEquals(listOf(51L), model.edits!!.state.value.selected.map { it.id.itemId })
        assertEquals(before.months, model.state.value.months); assertEquals(before.selectedMonth, model.state.value.selectedMonth)
        assertTrue(calls.filter { it.api.endsWith("Browse.Item") && it.method == "get" }.any { 52L in it.ids("id") })
    }
    @Test fun 归入已有目标可搜索且保留其他人脸和原照片() {
        show(); detail(listOf(51)); action(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES); form()
        scroll("photos_face_102").performClick(); scroll("photos_faces_search").performTextReplacement("Synthetic B")
        scroll("photos_faces_target_2").performClick(); capture("existing-target"); save(); confirmation(); capture("existing-risk"); confirm(); finished(); capture("existing-saved")
        assertEquals(mapOf("name" to "\"Synthetic B\"", "target_id" to "2", "face_id" to "[101]"), writes.single().fields)
        assertEquals(2L to 51L, faces.getValue(101)); assertEquals(1L to 51L, faces.getValue(102))
        close(); assertEquals(listOf(51L, 52L), model.state.value.items.map { it.id.itemId }); assertEquals(listOf(51L), model.edits!!.state.value.selected.map { it.id.itemId })
    }
    @Test fun 新人物实际回执成为目标并只更新已离开来源的照片() {
        show(); detail(listOf(51)); action(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES); form()
        scroll("photos_faces_name").performTextReplacement("Synthetic new"); capture("new-name"); save(); confirmation(); capture("new-risk"); confirm(); finished(); capture("new-saved")
        assertEquals(90L, editor.state.value.records.single().checkpoint.people!!.faces!!.targetReceipt)
        assertEquals(mapOf("name" to "\"Synthetic new\"", "target_id" to "0", "face_id" to "[101,102]"), writes.single().fields)
        assertEquals("Synthetic new", people.getValue(90).getValue("name").jsonPrimitive.content)
        close(); assertEquals(listOf(52L), model.state.value.items.map { it.id.itemId }); assertTrue(model.edits!!.state.value.selected.isEmpty())
    }
    @Test fun 单张设为封面直接保存不透明回执且原图和选择不变() {
        show(); detail(listOf(51)); val before = model.state.value
        action(SynologyPhotoAlbumAction.COVER_PERSON); form(); capture("cover-ready"); save(); finished(); assertNull(editor.state.value.confirmation); capture("cover-saved")
        assertEquals(mapOf("id" to "1", "photo_id" to "51"), writes.single().fields)
        assertEquals(701L, editor.state.value.records.single().checkpoint.people!!.faces!!.coverReceipt)
        close(); assertEquals(before.items, model.state.value.items); assertEquals(listOf(51L), model.edits!!.state.value.selected.map { it.id.itemId })
        assertEquals("cover-701", model.state.value.navigation.categoryItem!!.personCover!!.revision)
    }
    @Test fun 人脸加载错误恢复空状态搜索空且输入与选择跨刷新保留() {
        show(); detail(listOf(51)); readGate = CompletableDeferred(); action(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES)
        compose.waitUntil(5_000) { editor.state.value.loading }; capture("faces-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }; capture("faces-error")
        failRead = false; scroll("photos_faces_refresh").performClick(); form(); capture("faces-normal")
        scroll("photos_faces_name").performTextReplacement("Unsaved"); scroll("photos_face_102").performClick()
        failRead = true; scroll("photos_faces_refresh").performClick(); compose.waitUntil(5_000) { !editor.state.value.loading && editor.state.value.error != null }
        failRead = false; scroll("photos_faces_refresh").performClick(); form(); assertEquals("Unsaved", editor.state.value.name); assertEquals(setOf(101L), editor.state.value.selectedFaces)
        scroll("photos_faces_search").performTextReplacement("missing")
        compose.onNodeWithTag("photos_faces_list").performScrollToNode(hasText(text(R.string.sp_people_search_empty))); capture("faces-search-empty")
        faces.clear(); scroll("photos_faces_refresh").performClick(); form()
        compose.onNodeWithTag("photos_faces_list").performScrollToNode(hasText(text(R.string.sp_person_faces_empty))); capture("faces-empty")
        scroll("photos_faces_save").assertIsNotEnabled(); assertTrue(writes.isEmpty())
    }
    @Test fun 断线归入已有目标模型重建后仅回读且不重复发送() {
        show(); detail(listOf(51)); action(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES); form(); scroll("photos_faces_target_2").performClick()
        unknown = true; applyWrites = false; save(); confirmation(); confirm(); pending(); capture("existing-pending")
        assertEquals(1, writes.size); cold(); detail(listOf(51)); action(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES); form(); capture("existing-restored")
        scroll("photos_faces_save").assertIsNotEnabled(); review(); pending(); assertEquals(1, writes.size)
        apply(writes.single()); review(); finished(); capture("existing-recovered"); assertEquals(1, writes.size)
    }
    @Test fun 新人物丢回执不按同名认领重建后仍保留恢复记录() {
        show(); detail(listOf(51)); action(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES); form(); scroll("photos_faces_name").performTextReplacement("Synthetic unknown")
        unknown = true; save(); confirmation(); confirm(); pending(); capture("new-pending")
        assertTrue(people.containsKey(90)); assertNull(editor.state.value.records.single().checkpoint.people!!.faces!!.targetReceipt)
        cold(); detail(listOf(52)); action(SynologyPhotoAlbumAction.REMOVE_PERSON_FACES); form(); review(); pending(); capture("new-restored")
        assertEquals(1, writes.size); assertTrue(editor.state.value.records.single().checkpoint.people!!.completedIds.isEmpty())
    }
    @Test fun 共享确认前权限撤销零写恢复后路由正确且保留草稿() {
        sharedOnly = true; show(); detail(listOf(51)); action(SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES); form()
        scroll("photos_faces_name").performTextReplacement("Synthetic shared")
        androidx.test.espresso.Espresso.closeSoftKeyboard()
        save(); confirmation(); manage = false; confirm()
        compose.waitUntil(5_000) { !editor.state.value.working && editor.state.value.error != null }; capture("shared-permission")
        assertTrue(writes.isEmpty()); assertEquals("Synthetic shared", editor.state.value.name); assertEquals(setOf(101L, 102L), editor.state.value.selectedFaces)
        manage = true; save(); confirmation(); confirm(); finished(); capture("shared-saved")
        assertEquals("SYNO.FotoTeam.Browse.Person", writes.single().api); assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
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
        c.api.endsWith("Browse.Person") && c.method == "list_face" -> list(faces.filter { it.value.first == c.id("person_id") && it.value.second in c.ids("item_id") }
            .keys.sorted().map { obj("""{"id":$it,"additional":{"thumbnail":{"cache_key":"synthetic-face-$it"}}}""") })
        c.api.endsWith("Browse.Item") && c.method == "get" -> list(c.ids("id").map(::photo))
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2026,"month":10,"day":1,"item_count":1}]}]}""")
        c.api.endsWith("Browse.Item") -> list(((c.fields["person_id"]?.toLong() ?: c.fields["person"]?.let { c.ids("person").single() })?.let { members[it].orEmpty() } ?: members.values.flatten())
            .drop(c.fields["offset"]?.toInt() ?: 0).take(c.fields["limit"]?.toInt() ?: 500).map(::photo))
        c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"name":"/Synthetic","parent":8,"additional":{"access_permission":{"view":true,"manage":$manage}}}}""")
        c.method in setOf("delete_face", "separate", "set_cover") -> {
            assertTrue(store.records(owner, 41).last { it.checkpoint.people != null }.checkpoint.people!!.attempted)
            if (applyWrites) apply(c)
            if (unknown) throw IOException("Synthetic interrupted response")
            when (c.method) {
                "separate" -> obj("""{"id":${c.id("target_id").takeIf { it > 0 } ?: 90},"name":${c.fields.getValue("name")}}""")
                "set_cover" -> obj("""{"id":${c.id("id")},"name":"Synthetic A","cover":701}""")
                else -> obj("{}")
            }
        }
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun apply(c: Call) {
        when (c.method) {
            "delete_face" -> c.ids("face_id").forEach { faces.remove(it) }
            "separate" -> {
                val target = c.id("target_id").takeIf { it > 0 } ?: 90L
                c.ids("face_id").forEach { id -> faces[id] = target to faces.getValue(id).second }
                val photos = faces.values.filter { it.first == target }.map { it.second }.distinct()
                members[target] = (members[target].orEmpty() + photos).distinct(); people[target] = person(target, c.text("name"), members.getValue(target).size)
            }
            "set_cover" -> { val id = c.id("id"); val old = people.getValue(id)
                people[id] = JsonObject(old + ("cover" to JsonPrimitive(701)) + ("additional" to obj("""{"thumbnail":{"cache_key":"cover-701"}}"""))) }
        }
        if (c.method != "set_cover") {
            val remaining = faces.values.filter { it.first == 1L }.map { it.second }.distinct().sorted()
            members[1] = remaining; people[1] = person(1, "Synthetic A", remaining.size)
        }
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun library() {
        ready(); compose.runOnIdle { model.selectSection(SynologyPhotosSection.ALBUMS) }; ready()
        compose.runOnIdle { model.openCategory(SynologyPhotoCategory.PEOPLE) }; ready()
        assertEquals(SynologyPhotoCategory.PEOPLE, model.state.value.navigation.category)
    }
    private fun detail(ids: List<Long> = listOf(51, 52)) {
        library(); compose.onNodeWithText("Synthetic A").performClick(); ready()
        compose.runOnIdle { model.edits!!.selectMode(true); ids.forEach { id -> model.edits!!.toggle(model.state.value.items.single { it.id.itemId == id }) } }
    }
    private fun action(action: SynologyPhotoAlbumAction) {
        compose.onNodeWithTag("photos_person_selection_actions").performClick()
        compose.onNodeWithTag("photos_person_selection_${action.name}").performScrollTo().performClick()
    }
    private fun form() { compose.waitUntil(10_000) { !editor.state.value.loading && editor.state.value.loaded }; assertNull(editor.state.value.error) }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_faces_list").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun save() { scroll("photos_faces_save").performClick() }
    private fun confirmation() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.confirmation != null } }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_faces_confirm").performClick() }
    private fun finished() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.records.isNotEmpty() && editor.state.value.records.all { it.checkpoint.finished } }; assertNull(editor.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !editor.state.value.working && editor.state.value.pending } }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun review() {
        val count = calls.count { it.method == "list_face" }
        scroll("photos_people_review").performClick()
        compose.waitUntil(10_000) { calls.count { it.method == "list_face" } > count && !editor.state.value.working }
    }
    private fun text(id: Int) = context.getString(id)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-faces-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        private fun person(id: Long, name: String, count: Int, shown: Boolean = true) = obj("""{"id":$id,"name":${JsonPrimitive(name)},"item_count":$count,"show":$shown,"additional":{"thumbnail":{"cache_key":"synthetic-$id"}}}""")
        private fun photo(id: Long) = obj("""{"id":$id,"filename":"Synthetic-$id.jpg","filesize":4,"time":1790812800,"indexed_time":1790812800,"folder_id":9,"type":"photo"}""")
    }
}
