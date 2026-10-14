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
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoRequestCodec
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*

/** 生产图库和收集表单通过真实仓储调用合成接口；无真实网络或用户数据。 */
class SynologyPhotosRequestUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profileId = "request-ui-${UUID.randomUUID()}"
    private val owner = WorkspaceOwner(profileId, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val requests get() = model.requests!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields.getValue(key).let(Json::parseToJsonElement)
        fun id(key: String) = value(key).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
    }
    private val entries = ConcurrentHashMap<String, JsonObject>()
    private val createdAlbums = ConcurrentHashMap<Long, String>()
    private val writes = CopyOnWriteArrayList<Call>()
    private var readGate: CompletableDeferred<Unit>? = null
    private var failRead = false; private var loseCreate = false; private var albumPending = false; private var failFolder = false
    @After fun cleanup() {
        readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profileId)
    }
    @Test fun 创建选择共享文件夹贡献相册和限制后复制实际链接() {
        show(); ready(); menu(R.string.sp_request_create); formReady(); capture("create-empty")
        compose.onNodeWithTag("photos_request_save").assertIsNotEnabled()
        subject("Synthetic collection"); scroll("photos_request_source").performClick()
        compose.onNodeWithText(text(R.string.sp_source_shared)).performClick()
        compose.onNodeWithTag("photos_request_default_folder").assertDoesNotExist()
        scroll("photos_request_folders").performClick(); folderReady(); capture("folders")
        compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); formReady()
        assertNull(requests.state.value.draft!!.settings.folderId); assertEquals("Synthetic collection", requests.state.value.draft!!.settings.subject)
        scroll("photos_request_folders").performClick(); folderReady()
        compose.onNodeWithText("Synthetic folder").performClick(); folderReady(); capture("folder-empty")
        compose.onNodeWithTag("photos_request_use_folder").performClick(); formReady()
        scroll("photos_request_albums").performClick(); albumReady(); capture("album-choices")
        compose.onNodeWithText("Synthetic contributed album").performScrollTo().performClick()
        scroll("photos_request_limit_size").assertIsOff().performClick().assertIsOn()
        scroll("photos_request_size").performTextReplacement("25"); compose.onNodeWithTag("photos_request_size").performImeAction()
        scroll("photos_request_expiration").performClick(); compose.onNodeWithText(text(R.string.sp_sharing_choose_date)).performClick()
        onView(withId(android.R.id.button1)).perform(click())
        capture("limits"); save(); finished(); capture("created")
        val call = writes.single(); assertEquals("SYNO.Foto.PhotoRequest", call.api)
        assertEquals("\"shared_space\"", call.fields["library"]); assertEquals("\"/Synthetic folder\"", call.fields["folder_home_path"])
        assertEquals("\"synthetic-contributor\"", call.fields["album_passphrase"]); assertFalse(call.fields.containsKey("album_id"))
        assertEquals("26214400", call.fields["filesize_limit"]); assertTrue(call.fields.getValue("expiration").toLong() > 0)
        compose.onNodeWithTag("photos_request_copy").performScrollTo().assertIsEnabled().performClick()
    }
    @Test fun 编辑保留精确大小仅提交改动并清除目标相册() {
        show(); addExisting(); ready(); sharing(); actions(R.string.sp_request_edit); formReady(); capture("edit-existing")
        compose.onNodeWithTag("photos_request_save").assertIsNotEnabled()
        scroll("photos_request_description").performTextReplacement("Synthetic new description"); compose.onNodeWithTag("photos_request_description").performImeAction()
        scroll("photos_request_albums").performClick(); albumReady()
        compose.onNodeWithText(text(R.string.sp_request_no_album)).performClick(); capture("edit-remove-album")
        save(); finished(); capture("edited")
        assertEquals(mapOf("passphrase" to "\"synthetic-existing\"", "description" to "\"Synthetic new description\"", "album_id" to "-1"), writes.single().fields)
        assertEquals(1_048_577L, entries.getValue("synthetic-existing").getValue("filesize_limit").jsonPrimitive.long)
        compose.onNode(hasText(text(R.string.sp_request_edit)) and hasClickAction()).performScrollTo().performClick(); formReady()
        scroll("photos_request_albums"); compose.onNodeWithText(text(R.string.sp_request_no_album)).assertExists()
        compose.onNodeWithTag("photos_request_save").assertIsNotEnabled(); capture("edit-no-album")
    }
    @Test fun 删除先展示后果返回不写确认仅删除收集链接() {
        show(); addExisting(); ready(); sharing(); actions(R.string.sp_request_delete); formReady(); capture("delete-confirm")
        compose.onNodeWithText(text(R.string.sp_request_delete_note)).assertExists(); assertTrue(writes.isEmpty())
        closeDialog(); actions(R.string.sp_request_delete); formReady(); save(); finished(); capture("deleted")
        assertEquals("SYNO.Foto.PhotoRequest", writes.single().api); assertEquals("delete", writes.single().method)
        assertEquals("[\"synthetic-existing\"]", writes.single().fields["passphrase"])
        closeDialog(); assertTrue(entries.isEmpty()); capture("request-empty")
    }
    @Test fun 标题搜索空结果和读取加载失败可恢复() {
        show(); addExisting(); ready(); sharing()
        compose.onNodeWithText(text(R.string.sp_request_search)).performTextInput("missing"); compose.onNode(hasSetTextAction()).performImeAction()
        compose.waitUntil(10_000) { model.state.value.visibleSharing.isEmpty() }; capture("search-empty")
        compose.onNodeWithText(text(R.string.sp_filters_clear)).performClick(); compose.waitUntil(10_000) { model.state.value.visibleSharing.isNotEmpty() }
        readGate = CompletableDeferred(); actions(R.string.sp_request_edit)
        compose.waitUntil(10_000) { requests.state.value.loading }; capture("read-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(10_000) { !requests.state.value.loading }; capture("read-error")
        compose.onNodeWithTag("photos_request_save").assertDoesNotExist()
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); formReady(); capture("read-recovered")
        assertTrue(writes.isEmpty())
    }
    @Test fun 创建回执丢失冷恢复仅查询且持久记录无口令和路径() {
        loseCreate = true; show(); ready(); menu(R.string.sp_request_create); formReady(); subject("Synthetic uncertain collection")
        save(); pending(); capture("create-pending"); assertEquals(1, writes.size)
        val row = requests.state.value.records.single().checkpoint
        assertNull(row.request!!.targetDigest)
        val raw = Json.encodeToString(row)
        for (value in listOf("synthetic-created", "Synthetic uncertain", "/PhotoRequest", "example.invalid")) assertFalse(raw.contains(value))
        closeDialog(); compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        menu(R.string.sp_request_records); compose.waitUntil(10_000) { requests.state.value.records.isNotEmpty() }
        compose.onNodeWithTag("photos_request_resume").performClick(); pending(); capture("cold-read-only")
        assertEquals(1, writes.size); assertTrue(entries.containsKey("synthetic-created"))
    }
    @Test fun 表单新建相册未知阶段只读恢复后选择真实编号() {
        show(); ready(); menu(R.string.sp_request_create); formReady(); subject("Synthetic album collection")
        scroll("photos_request_albums").performClick(); albumReady()
        compose.onNodeWithTag("photos_request_album_list").performScrollToNode(hasTestTag("photos_request_new_album"))
        compose.onNodeWithTag("photos_request_new_album").performTextReplacement("Synthetic new album"); compose.onNodeWithTag("photos_request_new_album").performImeAction()
        albumPending = true
        compose.onNodeWithTag("photos_request_create_album").performScrollTo().performClick()
        compose.waitUntil(10_000) { !requests.state.value.working && requests.state.value.pendingAlbum != null }; capture("new-album-pending")
        assertNull(requests.state.value.draft!!.settings.albumId); assertEquals(1, writes.size)
        albumPending = false; compose.onNodeWithText(text(R.string.sp_edit_refresh)).performScrollTo().performClick()
        compose.waitUntil(10_000) { !requests.state.value.working && requests.state.value.draft?.settings?.albumId == 73L }
        scroll("photos_request_albums"); capture("new-album-selected")
        save(); finished(); capture("new-album-collected")
        assertEquals(listOf("SYNO.Foto.Browse.NormalAlbum", "SYNO.Foto.PhotoRequest"), writes.map { it.api })
        assertEquals("73", writes.last().fields["album_id"])
    }
    @Test fun 保存前连接失败保留内容恢复连接后可直接重试() {
        show(); ready(); menu(R.string.sp_request_create); formReady(); subject("Synthetic retry")
        failFolder = true; save(); compose.waitUntil(10_000) { !requests.state.value.working && requests.state.value.error != null }
        assertTrue(writes.isEmpty()); assertEquals("Synthetic retry", requests.state.value.draft!!.settings.subject)
        compose.onNodeWithTag("photos_request_save").assertIsEnabled(); capture("preflight-error")
        failFolder = false; save(); finished(); capture("preflight-retried"); assertEquals(1, writes.size)
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { SynologyPhotosLibrary(model, false, {}) } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Browse.NormalAlbum", "PhotoRequest", "Sharing.Misc")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val repo = SynologyPhotosRepository(profileId, caps, { capability, method, fields ->
            val call = Call(capability.name, method, fields)
            if (call.api.endsWith("PhotoRequest") && method == "list") { readGate?.await(); if (failRead) throw IOException("Synthetic read") }
            if (call.api.endsWith("Browse.Folder") && failFolder) throw IOException("Synthetic folder read")
            if (method in setOf("create", "update", "delete")) writes += call
            response(call)
        })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41,"uid":1041}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"entry"}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
        c.api.endsWith("Browse.Folder") -> if (c.method == "get") JsonObject(mapOf("folder" to folder(c.fields["id"]?.toLong() ?: 1))) else
            JsonObject(mapOf("list" to JsonArray(if (c.id("id") == 1L) listOf(folder(9)) else emptyList())))
        c.api.endsWith("Browse.NormalAlbum") && c.method == "list" -> JsonObject(mapOf("list" to JsonArray(listOf(album(71, "Synthetic private album"), album(72, "Synthetic contributed album", 42)) + createdAlbums.map { album(it.key, it.value) })))
        c.api.endsWith("Browse.NormalAlbum") && c.method == "create" -> {
            createdAlbums[73] = c.value("name").jsonPrimitive.content; obj("""{"album":{"id":73}}""")
        }
        c.api.endsWith("Browse.Album") && c.method == "get" -> JsonObject(mapOf("list" to JsonArray(createdAlbums[c.id("id")]?.let {
            listOf(album(c.id("id"), if (albumPending) "Synthetic waiting" else it))
        }.orEmpty())))
        c.api.endsWith("PhotoRequest") && c.method == "list" -> JsonObject(mapOf("list" to JsonArray(entries.toSortedMap().values.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()))))
        c.api.endsWith("PhotoRequest") && c.method == "create" -> {
            val raw = record("synthetic-created", SynologyPhotoRequestSettings()).toMutableMap()
            c.fields.mapValues { Json.parseToJsonElement(it.value) }.forEach { (key, value) -> if (key != "passphrase") raw[key] = value }
            raw["folder_id"] = JsonPrimitive(if (raw["folder_home_path"] == JsonPrimitive("/Synthetic folder")) 9 else 19)
            entries["synthetic-created"] = JsonObject(raw)
            if (loseCreate) throw IOException("Synthetic missing receipt")
            JsonObject(raw)
        }
        c.api.endsWith("PhotoRequest") && c.method == "update" -> {
            val id = c.value("passphrase").jsonPrimitive.content; val raw = entries.getValue(id).toMutableMap()
            c.fields.mapValues { Json.parseToJsonElement(it.value) }.forEach { (key, value) -> raw[key] = value }
            if (c.fields.containsKey("album_id")) raw.remove("album_passphrase")
            if (c.fields.containsKey("album_passphrase")) raw.remove("album_id")
            entries[id] = JsonObject(raw); obj("{}")
        }
        c.api.endsWith("PhotoRequest") && c.method == "delete" -> { c.value("passphrase").jsonArray.forEach { entries.remove(it.jsonPrimitive.content) }; obj("{}") }
        c.method in setOf("list", "list_shared_with_me_album", "get") -> obj("""{"list":[]}""")
        else -> error("Unexpected synthetic operation")
    }
    private fun folder(id: Long) = obj("""{"id":$id,"name":"${if (id == 1L) "/" else "/Synthetic folder"}","parent":${if (id == 1L) 0 else 1},"additional":{"access_permission":{"view":true,"upload":true,"manage":false}}}""")
    private fun album(id: Long, name: String, owner: Long = 41) = buildJsonObject {
        put("id", id); put("name", name); put("owner_user_id", owner); put("shared", owner != 41L)
        put("type", "normal"); put("freeze_album", false); put("temporary_shared", false)
        put("additional", buildJsonObject { if (owner != 41L) put("sharing_info", obj("""{"passphrase":"synthetic-contributor"}""")) })
    }
    private fun addExisting() { entries["synthetic-existing"] = record("synthetic-existing", SynologyPhotoRequestSettings("Synthetic existing collection", "Synthetic description",
        folderId = 9, folderPath = "/Synthetic folder", albumId = 71, sizeLimit = 1_048_577)) }
    private fun record(id: String, settings: SynologyPhotoRequestSettings) = JsonObject(SynologyPhotoRequestCodec.parameters(settings) + mapOf(
        "passphrase" to JsonPrimitive(id), "folder_id" to JsonPrimitive(settings.folderId ?: 19), "is_folder_valid" to JsonPrimitive(true),
        "album_name" to JsonPrimitive("Synthetic private album"), "sharing_link" to JsonPrimitive("https://example.invalid/synthetic-collection")))
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun formReady() { compose.waitUntil(10_000) { !requests.state.value.loading && requests.state.value.draft != null }; assertNull(requests.state.value.error) }
    private fun folderReady() { compose.waitUntil(10_000) { !requests.state.value.foldersLoading && requests.state.value.folderPath.isNotEmpty() }; assertNull(requests.state.value.folderError) }
    private fun albumReady() { compose.waitUntil(10_000) { !requests.state.value.albumsLoading && requests.state.value.albumsLoaded }; assertNull(requests.state.value.albumError) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithText(text(id)).performClick() }
    private fun sharing() { compose.onNodeWithText(text(R.string.sp_sharing)).performClick(); ready(); compose.onNodeWithText(text(R.string.sp_sharing_requests)).performClick(); ready() }
    private fun actions(id: Int) { compose.onNodeWithContentDescription(context.getString(R.string.sp_request_actions, "Synthetic existing collection")).performClick(); compose.onNodeWithText(text(id)).performClick() }
    private fun subject(value: String) { scroll("photos_request_subject").performTextReplacement(value); scroll("photos_request_description").performImeAction() }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_request_form").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun save() { compose.onNodeWithTag("photos_request_save").assertIsEnabled().performClick() }
    private fun finished() { compose.waitUntil(10_000) { !requests.state.value.working && requests.state.value.records.any { it.id == requests.state.value.activeId && it.checkpoint.finished } }; assertNull(requests.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !requests.state.value.working && requests.state.value.records.isNotEmpty() }; assertNull(requests.state.value.error); assertFalse(requests.state.value.records.single().checkpoint.finished); ready() }
    private fun closeDialog() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-request-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
