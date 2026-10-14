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

/** 生产图库、目录操作仓储、加密记录与实际图片解码；所有接口与图片均为合成测试数据。 */
class SynologyPhotosFolderUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profileId = "folder-ui-${UUID.randomUUID()}"
    private val owner = WorkspaceOwner(profileId, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val folders get() = model.folders!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields.getValue(key).let(Json::parseToJsonElement)
        fun id(key: String) = value(key).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
    }
    private val paths = ConcurrentHashMap<Long, String>().apply { put(1, "/"); put(9, "/Synthetic folder"); put(10, "/Synthetic folder/Child"); put(12, "/Synthetic folder/Empty") }
    private val parents = ConcurrentHashMap<Long, Long>().apply { put(1, 0); put(9, 1); put(10, 9); put(12, 9) }
    private val sorts = ConcurrentHashMap<Long, Pair<String, String>>()
    private val covers = ConcurrentHashMap<Long, Boolean>()
    private val writes = CopyOnWriteArrayList<Call>()
    private val mediaCalls = CopyOnWriteArrayList<Request>()
    private var readGate: CompletableDeferred<Unit>? = null
    private var failRead = false; private var loseCreate = false; private var validImage = true
    private var manageTarget = true; private var failPreflight = false; private var teamPermission = "entry"
    @After fun cleanup() {
        readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profileId)
    }
    @Test fun 新建和重命名使用实际目录菜单保持路径与原件() {
        show(); ready(); rootFolders(); capture("folder-root")
        menu(R.string.sp_folder_create); formReady(); capture("create-empty")
        compose.onNodeWithTag("photos_folder_save").assertIsNotEnabled()
        name("bad/name"); compose.onNodeWithTag("photos_folder_save").assertIsNotEnabled(); capture("invalid-name")
        name("Synthetic new folder"); save(); finished(); capture("created")
        assertEquals("create", writes.single().method); assertEquals("1", writes.single().fields["target_id"])
        close(); compose.onNodeWithText("Synthetic new folder").assertExists()
        compose.onNodeWithContentDescription(context.getString(R.string.sp_folder_actions, "Synthetic new folder")).performClick()
        choose(R.string.sp_folder_rename); formReady(); name("Synthetic renamed folder"); capture("rename-form")
        save(); finished(); close(); capture("renamed")
        compose.onNodeWithText("Synthetic renamed folder").assertExists()
        assertEquals(listOf("create", "rename"), writes.map { it.method }); assertEquals("11", writes.last().fields["id"])
        assertEquals(1L, model.state.value.navigation.folders.last().id)
    }
    @Test fun 只读目录可保存排序重新进入仍保留顺序且网格不按日期重排() {
        manageTarget = false; show(); ready(); targetFolder(); capture("sort-before")
        menu(R.string.sp_folder_sort); formReady()
        compose.onNodeWithTag("photos_folder_sort_field").performClick(); choose(R.string.sp_folder_sort_name)
        compose.onNodeWithTag("photos_folder_sort_direction").performClick(); choose(R.string.sp_folder_sort_descending)
        capture("sort-form"); save(); finished(); close(); capture("sort-after")
        assertEquals(listOf(21L, 22L), model.state.value.items.map { it.id.itemId })
        val first = compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Zebra.jpg")).fetchSemanticsNode().boundsInRoot
        val second = compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Apple.jpg")).fetchSemanticsNode().boundsInRoot
        assertTrue(first.top < second.top || first.top == second.top && first.left < second.left)
        compose.onNodeWithTag("photos_folder_path").performClick(); choose(R.string.sp_folder_root); ready()
        compose.onNodeWithText("Synthetic folder").performClick(); ready(); menu(R.string.sp_folder_sort); formReady()
        assertEquals(SynologyPhotoSort(SynologyPhotoSort.Field.FILENAME, SynologyPhotoSort.Direction.DESCENDING), folders.state.value.draft!!.sort)
        compose.onNodeWithTag("photos_folder_save").assertIsNotEnabled(); capture("sort-reopened")
        assertEquals(1, writes.size); assertEquals("\"desc\"", writes.single().fields["sort_direction"])
    }
    @Test fun 封面可选只读子目录照片目标保持不变并实际解码图片() {
        show(); ready(); targetFolder(); menu(R.string.sp_folder_cover); formReady(); browseReady(); capture("cover-browser")
        compose.onNodeWithTag("photos_folder_child_10").performScrollTo().performClick(); browseReady(); capture("cover-child")
        cover(23); save(); finished(); capture("cover-saved")
        assertEquals("9", writes.single().fields["id"]); assertEquals("[23]", writes.single().fields["id_item"])
        assertEquals("set_cover", writes.single().method)
        val request = mediaCalls.last { it.url.queryParameter("folder_cover_seq") == "0" }
        assertEquals("9", request.url.queryParameter("id")); assertEquals("\"folder\"", request.url.queryParameter("type")); assertNull(request.url.queryParameter("size"))
        assertTrue(store.records(owner, 41).single().checkpoint.folder!!.coverAcknowledged)
        close(); assertEquals(9L, model.state.value.navigation.folders.last().id)
    }
    @Test fun 封面回执后图片不可解码时不报完成恢复仅重读() {
        show(); ready(); targetFolder(); menu(R.string.sp_folder_cover); formReady(); browseReady(); cover(21)
        validImage = false; save(); pending(); capture("cover-undecodable")
        assertTrue(folders.state.value.records.single().checkpoint.folder!!.coverAcknowledged); assertEquals(1, writes.size)
        validImage = true; compose.onNodeWithTag("photos_folder_resume").performClick(); finished(); capture("cover-recovered")
        assertEquals(1, writes.size); assertTrue(mediaCalls.count { it.url.queryParameter("folder_cover_seq") == "0" } >= 2)
    }
    @Test fun 创建回执丢失后冷恢复保留真实新目录但不认领同名或重复创建() {
        loseCreate = true; show(); ready(); targetFolder(); menu(R.string.sp_folder_create); formReady(); name("Synthetic uncertain")
        save(); pending(); capture("create-pending"); assertNull(folders.state.value.records.single().checkpoint.folder!!.createdFolderId)
        close(); compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        menu(R.string.sp_folder_records); compose.waitUntil(10_000) { folders.state.value.records.isNotEmpty() }
        compose.onNodeWithTag("photos_folder_resume").performClick(); pending(); capture("cold-read-only")
        assertEquals(1, writes.size); assertTrue(paths.containsKey(11)); compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
    }
    @Test fun 读取加载失败和空子目录有恢复入口保存前失败保留输入() {
        show(); ready(); targetFolder(); readGate = CompletableDeferred(); menu(R.string.sp_folder_rename)
        compose.waitUntil(10_000) { folders.state.value.loading }; capture("folder-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(10_000) { !folders.state.value.loading }; capture("folder-read-error")
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); formReady()
        name("Synthetic retry"); failPreflight = true; save()
        compose.waitUntil(10_000) { !folders.state.value.working && folders.state.value.error != null }; capture("folder-save-error")
        assertTrue(writes.isEmpty()); compose.onNodeWithTag("photos_folder_save").assertIsEnabled()
        failPreflight = false; save(); finished(); close()
        menu(R.string.sp_folder_cover); formReady(); browseReady(); compose.onNodeWithTag("photos_folder_child_12").performScrollTo().performClick(); browseReady(); capture("cover-empty")
        compose.onNodeWithText(text(R.string.sp_folder_cover_empty)).assertExists(); compose.onNodeWithTag("photos_folder_save").assertIsNotEnabled()
    }
    @Test fun 共享entry可上传目录能创建但不展示改名封面入口() {
        show(); ready(); compose.onNodeWithTag("photos_source").performClick(); choose(R.string.sp_source_shared); ready(); targetFolder()
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithText(text(R.string.sp_folder_rename)).assertDoesNotExist(); compose.onNodeWithText(text(R.string.sp_folder_cover)).assertDoesNotExist()
        choose(R.string.sp_folder_create); formReady(); name("Synthetic shared child"); capture("shared-create"); save(); finished(); capture("shared-created")
        assertEquals("SYNO.FotoTeam.Browse.Folder", writes.single().api); assertEquals("9", writes.single().fields["target_id"])
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { SynologyPhotosLibrary(model, false, {}) } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        val profile = NasProfile(profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request(); mediaCalls += request
            val bytes = if (request.url.queryParameter("folder_cover_seq") != null && !validImage) byteArrayOf(1, 2, 3) else image
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(bytes.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profileId, "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profileId, caps, { capability, method, fields ->
            val call = Call(capability.name, method, fields)
            if (call.api.endsWith("Browse.Folder") && method == "get") {
                readGate?.await(); if (failRead || failPreflight) throw IOException("Synthetic folder read")
            }
            if (method in setOf("create", "rename", "set_order", "set_cover")) writes += call
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"$teamPermission"}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
        c.api.endsWith("Browse.Folder") && c.method == "get" -> JsonObject(mapOf("folder" to folder(c.fields["id"]?.toLong() ?: 1, c.api.contains("FotoTeam"))))
        c.api.endsWith("Browse.Folder") && c.method == "list" -> {
            val values = paths.keys.filter { parents[it] == c.id("id") }.sortedBy { paths[it] }.let { if (c.value("sort_direction").jsonPrimitive.content == "desc") it.reversed() else it }
            JsonObject(mapOf("list" to JsonArray(values.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()).map { folder(it, c.api.contains("FotoTeam")) })))
        }
        c.api.endsWith("Browse.Folder") && c.method == "create" -> {
            val parent = c.id("target_id"); paths[11] = paths.getValue(parent).trimEnd('/') + "/" + c.value("name").jsonPrimitive.content; parents[11] = parent
            if (loseCreate) throw IOException("Synthetic lost receipt")
            obj("""{"folder":{"id":11}}""")
        }
        c.api.endsWith("Browse.Folder") && c.method == "rename" -> {
            val id = c.id("id"); val old = paths.getValue(id); val next = old.substringBeforeLast('/') + "/" + c.value("name").jsonPrimitive.content
            paths.keys.forEach { key -> val path = paths.getValue(key); if (path == old || path.startsWith("$old/")) paths[key] = next + path.removePrefix(old) }; obj("{}")
        }
        c.api.endsWith("Browse.Folder") && c.method == "set_order" -> { sorts[c.id("id")] = c.value("sort_by").jsonPrimitive.content to c.value("sort_direction").jsonPrimitive.content; obj("{}") }
        c.api.endsWith("Browse.Folder") && c.method == "set_cover" -> { covers[c.id("id")] = true; obj("{}") }
        c.api.endsWith("Browse.Item") && c.method == "get" -> JsonObject(mapOf("list" to JsonArray(listOf(photo(c.id("id"))))))
        c.api.endsWith("Browse.Item") && c.method == "list" -> {
            val ids = when (c.id("folder_id")) { 9L -> listOf(21L, 22L); 10L -> listOf(23L); else -> emptyList() }
            val field = c.value("sort_by").jsonPrimitive.content
            val sorted = ids.sortedWith { a, b ->
                val key = when (field) { "filename" -> "filename"; "filesize" -> "filesize"; "item_type" -> "type"; else -> "time" }
                if (key in setOf("filename", "type")) photo(a).getValue(key).jsonPrimitive.content.compareTo(photo(b).getValue(key).jsonPrimitive.content)
                else photo(a).getValue(key).jsonPrimitive.long.compareTo(photo(b).getValue(key).jsonPrimitive.long)
            }.let { if (c.value("sort_direction").jsonPrimitive.content == "desc") it.reversed() else it }
            JsonObject(mapOf("list" to JsonArray(sorted.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()).map(::photo))))
        }
        else -> error("Unexpected synthetic operation")
    }
    private fun folder(id: Long, shared: Boolean) = buildJsonObject {
        put("id", id); put("name", paths.getValue(id)); put("parent", parents.getValue(id))
        sorts[id]?.let { put("sort_by", it.first); put("sort_direction", it.second) }
        put("additional", buildJsonObject {
            put("access_permission", obj("""{"view":true,"manage":${!shared && manageTarget && id != 10L},"upload":true,"download":false}"""))
            if (covers[id] == true) put("thumbnail", Json.parseToJsonElement("""[{"folder_cover_seq":0,"cache_key":"synthetic-cover"}]"""))
        })
    }
    private fun photo(id: Long) = obj("""{"id":$id,"filename":"${if (id == 21L) "Zebra.jpg" else if (id == 22L) "Apple.jpg" else "Child.jpg"}","filesize":4,"time":${if (id == 21L) 100 else 200},"indexed_time":300,"folder_id":${if (id == 23L) 10 else 9},"type":"photo","additional":{"thumbnail":{"unit_id":$id,"cache_key":"synthetic"}}}""")
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun formReady() { compose.waitUntil(10_000) { !folders.state.value.loading && folders.state.value.draft != null }; assertNull(folders.state.value.error) }
    private fun browseReady() { compose.waitUntil(10_000) { !folders.state.value.browsing && folders.state.value.path.isNotEmpty() }; assertNull(folders.state.value.browseError) }
    private fun rootFolders() { compose.onNodeWithText(text(R.string.sp_library_folders)).performClick(); ready() }
    private fun targetFolder() { rootFolders(); compose.onNodeWithText("Synthetic folder").performClick(); ready() }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); choose(id) }
    private fun choose(id: Int) { compose.onNode(hasText(text(id)) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun name(value: String) { compose.onNodeWithTag("photos_folder_name").performTextReplacement(value); compose.onNodeWithTag("photos_folder_name").performImeAction() }
    private fun cover(id: Long) {
        compose.onNodeWithTag("photos_folder_form").performScrollToNode(hasTestTag("photos_folder_cover_$id"))
        compose.onNode(hasClickAction() and hasAnyAncestor(hasTestTag("photos_folder_cover_$id"))).performClick().assertIsSelected()
    }
    private fun save() { compose.onNodeWithTag("photos_folder_save").assertIsEnabled().performClick() }
    private fun finished() { compose.waitUntil(10_000) { !folders.state.value.working && folders.state.value.records.any { it.id == folders.state.value.activeId && it.checkpoint.finished } }; assertNull(folders.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !folders.state.value.working && folders.state.value.records.isNotEmpty() }; assertNull(folders.state.value.error); assertFalse(folders.state.value.records.single().checkpoint.finished); ready() }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-folder-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
