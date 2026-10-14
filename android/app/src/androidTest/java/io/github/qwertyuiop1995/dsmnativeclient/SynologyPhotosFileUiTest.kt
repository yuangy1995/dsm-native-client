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

/** 生产图库、文件任务仓储、加密记录与真实图片解码；网络由明确的合成夹具替代。 */
class SynologyPhotosFileUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profileId = "files-ui-${UUID.randomUUID()}"
    private val owner = WorkspaceOwner(profileId, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var edits: SynologyPhotoEditStore
    private val files get() = model.files!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = Json.parseToJsonElement(fields.getValue(key))
        fun id(key: String) = value(key).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
    }
    private data class Folder(val path: String, val parent: Long)
    private val folderRows = ConcurrentHashMap<Pair<Boolean, Long>, Folder>().apply {
        for (shared in listOf(false, true)) {
            put(shared to 1, Folder("/", 0)); put(shared to 9, Folder("/Source", 1))
            put(shared to 10, Folder("/Source/Child", 9)); put(shared to 20, Folder("/Destination", 1))
        }
    }
    private val photoFolders = ConcurrentHashMap<Pair<Boolean, Long>, Long>().apply {
        for (shared in listOf(false, true)) { put(shared to 21, 9); put(shared to 22, 9); put(shared to 23, 10) }
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes = CopyOnWriteArrayList<Call>()
    private var browseGate: CompletableDeferred<Unit>? = null
    private var failBrowse = false; private var failPreflight = false; private var loseReceipt = false
    private var taskDone = true; private var skip = 0; private var canUpload = true
    private var sharedSourceManage = true; private var sharedSourceDownload = true
    private var receipt = obj("{}"); private var taskTotal = 0
    @After fun cleanup() {
        browseGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profileId)
        if (::edits.isInitialized) edits.removeProfile(profileId)
    }

    @Test fun 混选移动固定清单目标及来源移动后留在原目录() {
        show(); source(); selectAll(); capture("mixed-selection"); action(R.string.sp_files_move); form()
        capture("destination-root"); destination(); capture("destination-empty")
        compose.onNodeWithText(context.getString(R.string.sp_files_selection_count, 2, 1)).performClick()
        compose.onNode(hasText("Child") and hasAnyAncestor(isDialog())).assertExists()
        compose.onNode(hasText("Photo21.jpg") and hasAnyAncestor(isDialog())).assertExists(); capture("frozen-selection")
        compose.onNodeWithText(text(R.string.close)).performClick(); save(); finished(); capture("move-completed")
        val write = writes.single(); assertEquals("move", write.method); assertEquals("[21,22]", write.fields["item_id"])
        assertEquals("[10]", write.fields["folder_id"]); assertEquals("20", write.fields["target_folder_id"])
        assertEquals(obj("""{"version":2,"source_library":"personal_space","source_folder_ids":[9]}"""), Json.parseToJsonElement(write.value("extra_info").jsonPrimitive.content))
        close(); assertEquals(9L, model.state.value.navigation.folders.last().id)
        assertTrue(model.state.value.items.isEmpty()); assertTrue(model.state.value.collections.isEmpty()); capture("source-after-move")
    }
    @Test fun 共享下载权可复制到个人目录覆盖需明确确认取消不写入() {
        sharedSourceManage = false; show(); ready()
        compose.onNodeWithTag("photos_source").performClick(); choose(R.string.sp_source_shared); ready(); source(); selectAll()
        action(R.string.sp_files_copy); form(); compose.onNodeWithText(text(R.string.sp_source_personal)).performClick(); form(); destination()
        compose.onNodeWithTag("photos_files_duplicate").performClick(); choose(R.string.sp_files_replace)
        save(); capture("overwrite-confirmation"); compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick()
        assertTrue(writes.isEmpty()); compose.onNodeWithTag("photos_files_save").assertIsEnabled()
        save(); compose.onNodeWithTag("photos_files_confirm_overwrite").performClick(); finished(); capture("shared-copy-completed")
        val write = writes.single(); assertEquals("SYNO.FotoTeam.BackgroundTask.File", write.api)
        assertEquals("copy", write.method); assertEquals("\"overwrite\"", write.fields["action"]); assertFalse(write.fields.containsKey("extra_info"))
        assertEquals(SynologyPhotoSpace.PERSONAL, files.state.value.records.single().checkpoint.files!!.destination!!.space)
        close(); assertEquals(2, model.state.value.items.size); assertEquals(1, model.state.value.collections.size)
    }
    @Test fun 混合删除显示完整风险和清单取消零写入确认后回读原件与目录() {
        show(); source(); selectAll(); action(R.string.sp_files_delete); form(); capture("delete-confirmation")
        compose.onNodeWithText(text(R.string.sp_files_delete_warning)).assertExists(); assertTrue(writes.isEmpty())
        close(); assertTrue(writes.isEmpty()); action(R.string.sp_files_delete); form(); save(); finished(); capture("delete-completed")
        assertEquals(setOf("item_id", "folder_id"), writes.single().fields.keys)
        assertEquals("delete", writes.single().method); assertTrue(calls.any { it.api.endsWith("Browse.Item") && it.method == "get" })
        close(); assertEquals(9L, model.state.value.navigation.folders.last().id)
        assertTrue(model.state.value.items.isEmpty()); assertTrue(model.state.value.collections.isEmpty()); capture("deleted-empty")
    }
    @Test fun 回执丢失冷恢复不重复写入不清除未知任务() {
        loseReceipt = true; show(); source(); selectAll(); action(R.string.sp_files_move); form(); destination(); save(); pending(); capture("unknown-task")
        assertNull(files.state.value.records.single().checkpoint.files!!.taskId)
        cold(); menu(R.string.sp_files_records); records(); capture("unknown-cold-record")
        compose.onNodeWithTag("photos_files_resume").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
        assertEquals(1, writes.size); assertTrue(calls.none { it.api.endsWith("BackgroundTask.Info") })
    }
    @Test fun 已知任务冷恢复只查询固定编号部分完成如实展示() {
        taskDone = false; show(); source(); selectAll(); action(R.string.sp_files_copy); form(); destination(); save(); pending(); capture("known-pending")
        assertEquals(91L, files.state.value.records.single().checkpoint.files!!.taskId)
        cold(); menu(R.string.sp_files_records); records(); capture("known-cold-record")
        skip = 1; taskDone = true
        compose.onNodeWithTag("photos_files_resume").performClick(); finished(); capture("partial-completion")
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, files.state.value.records.single().checkpoint.phase)
        assertEquals(1, writes.size)
        assertTrue(calls.filter { it.method == "get_status" }.all { it.api == "SYNO.Foto.BackgroundTask.Info" && it.fields["id"] == "[91]" })
    }
    @Test fun 目录加载失败可重试权限与保存前错误均不写入() {
        show(); source(); selectAll(); browseGate = CompletableDeferred(); action(R.string.sp_files_copy)
        compose.waitUntil(10_000) { files.state.value.browsing }; capture("destination-loading")
        failBrowse = true; compose.runOnIdle { browseGate!!.complete(Unit); browseGate = null }
        compose.waitUntil(10_000) { !files.state.value.browsing }; capture("destination-error")
        compose.onNodeWithTag("photos_files_save").assertIsNotEnabled()
        failBrowse = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form()
        canUpload = false; destination(); capture("destination-no-permission"); compose.onNodeWithTag("photos_files_save").assertIsNotEnabled()
        canUpload = true; compose.runOnIdle { files.browse() }; form()
        failPreflight = true; save(); compose.waitUntil(10_000) { !files.state.value.working && files.state.value.error != null }; capture("preflight-error")
        assertTrue(writes.isEmpty()); assertTrue(store.records(owner, 41).isEmpty())
        failPreflight = false; save(); finished(); capture("retry-completed")
    }
    @Test fun 共享移动不提供个人来源自身及后代目录无法选择() {
        show(); ready(); compose.onNodeWithTag("photos_source").performClick(); choose(R.string.sp_source_shared); ready()
        source(); selectAll(); action(R.string.sp_files_move); form()
        assertEquals(listOf(SynologyPhotoSpace.SHARED), files.destinationSpaces)
        compose.onNodeWithTag("photos_files_target_9").performScrollTo().performClick(); form(); capture("invalid-source-destination")
        compose.onNodeWithTag("photos_files_save").assertIsNotEnabled()
        compose.onNodeWithTag("photos_files_target_10").performScrollTo().performClick(); form(); capture("invalid-descendant-destination")
        compose.onNodeWithTag("photos_files_save").assertIsNotEnabled(); assertTrue(writes.isEmpty())
    }
    @Test fun 空操作记录与预览单张复制沿原件身份完成() {
        show(); ready(); menu(R.string.sp_files_records)
        compose.onNodeWithText(text(R.string.sp_files_no_records)).assertExists(); capture("empty-records"); close(); source()
        compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Photo21.jpg")).performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo != null && !model.preview.state.value.loading }
        assertNull(model.preview.state.value.error); capture("preview-copy-entry")
        compose.onNodeWithContentDescription(text(R.string.sp_files_copy)).performScrollTo().performClick(); form(); destination()
        assertNull(model.preview.state.value.photo); assertEquals(1, files.state.value.draft!!.checkpoint.targets.size)
        assertTrue(files.state.value.draft!!.checkpoint.files!!.folders.isEmpty()); save(); finished(); capture("single-copy-completed")
        assertEquals("[21]", writes.single().fields["item_id"]); assertEquals("[]", writes.single().fields["folder_id"])
        close(); assertEquals(2, model.state.value.items.size)
    }

    private fun show() {
        store = SynologyPhotoAlbumStore(context); edits = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { SynologyPhotosLibrary(model, false, {}) } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "BackgroundTask.File", "BackgroundTask.Info")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        val profile = NasProfile(profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profileId, "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profileId, caps, { capability, method, fields ->
            val call = Call(capability.name, method, fields); calls += call
            if (call.api.endsWith("Browse.Folder") && method == "list") { browseGate?.await(); if (failBrowse) throw IOException("Synthetic folder read") }
            if (call.api.endsWith("Browse.Item") && method == "get" && failPreflight) throw IOException("Synthetic item read")
            if (call.api.endsWith("BackgroundTask.File")) writes += call
            response(call)
        }, media, canDeleteOriginals = true)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = edits)
    }
    private fun response(c: Call): JsonObject {
        val shared = c.api.contains("FotoTeam")
        return when {
            c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
            c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"entry","copy_move_default_action":"skip"}""")
            c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
            c.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
            c.api.endsWith("Browse.Folder") && c.method == "get" -> JsonObject(mapOf("folder" to folder(shared, c.fields["id"]?.toLong() ?: 1)))
            c.api.endsWith("Browse.Folder") && c.method == "list" -> list(folderRows.entries.filter { it.key.first == shared && it.value.parent == c.id("id") }
                .sortedBy { it.value.path }.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()).map { folder(shared, it.key.second) })
            c.api.endsWith("Browse.Item") && c.method == "get" -> list(c.value("id").jsonArray.mapNotNull { raw -> raw.jsonPrimitive.long.takeIf { photoFolders.containsKey(shared to it) }?.let { photo(shared, it) } })
            c.api.endsWith("Browse.Item") && c.method == "list" -> list(photoFolders.entries.filter { it.key.first == shared && it.value == c.id("folder_id") }
                .sortedBy { it.key.second }.drop(c.fields.getValue("offset").toInt()).take(c.fields.getValue("limit").toInt()).map { photo(shared, it.key.second) })
            c.api.endsWith("BackgroundTask.File") -> {
                val items = c.value("item_id").jsonArray.map { it.jsonPrimitive.long }; val folders = c.value("folder_id").jsonArray.map { it.jsonPrimitive.long }
                taskTotal = items.size + folders.size
                val target = files.state.value.draft?.checkpoint?.files?.destination ?: files.state.value.records.firstOrNull()?.checkpoint?.files?.destination
                    ?: files.state.value.folderAccess?.folder
                if (c.method != "copy") {
                    items.forEach { id -> if (c.method == "delete") photoFolders.remove(shared to id) else photoFolders[shared to id] = c.id("target_folder_id") }
                    folders.forEach { id -> if (c.method == "delete") folderRows.remove(shared to id) else {
                        val old = folderRows.getValue(shared to id); folderRows[shared to id] = Folder(target!!.path.trimEnd('/') + "/" + old.path.substringAfterLast('/'), target.id)
                    } }
                }
                receipt = buildJsonObject { put("id", 91); put("total", taskTotal); target?.takeIf { c.method != "delete" }?.let {
                    put("target_folder", buildJsonObject { put("id", it.id); put("owner_user_id", if (it.space == SynologyPhotoSpace.SHARED) 0 else 41) })
                } }
                if (loseReceipt) throw IOException("Synthetic lost receipt")
                JsonObject(mapOf("task_info" to receipt))
            }
            c.api.endsWith("BackgroundTask.Info") && c.method == "list_user_task" -> list(listOf(receipt))
            c.api.endsWith("BackgroundTask.Info") && c.method == "get_status" -> list(listOf(obj("""{"id":91,"status":"${if (taskDone) "done" else "running"}","completion":${if (taskDone) taskTotal - skip else 0},"error":0,"skip":$skip,"overwrite":0}""")))
            else -> error("Unexpected synthetic operation ${c.api} ${c.method}")
        }
    }
    private fun folder(shared: Boolean, id: Long): JsonObject {
        val row = folderRows.getValue(shared to id)
        val source = id == 9L || id == 10L
        return obj("""{"id":$id,"name":"${row.path}","parent":${row.parent},"additional":{"access_permission":{"view":true,"manage":${if (id == 20L) false else !shared || !source || sharedSourceManage},"upload":${id != 20L || canUpload},"download":${!shared || !source || sharedSourceDownload}}}}""")
    }
    private fun photo(shared: Boolean, id: Long) = obj("""{"id":$id,"filename":"Photo$id.jpg","filesize":4,"time":100,"indexed_time":200,"folder_id":${photoFolders.getValue(shared to id)},"type":"photo","additional":{"thumbnail":{"unit_id":$id,"cache_key":"synthetic"}}}""")
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun source() { ready(); compose.onNodeWithText(text(R.string.sp_library_folders)).performClick(); ready(); compose.onNodeWithText("Source").performClick(); ready() }
    private fun selectAll() { menu(R.string.sp_files_select); compose.onNodeWithText(text(R.string.sp_files_select_loaded)).performClick(); assertEquals(2, model.edits!!.state.value.selected.size); assertEquals(1, model.edits!!.state.value.selectedFolders.size) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); choose(id) }
    private fun action(id: Int) { compose.onNodeWithTag("photos_files_actions").performClick(); choose(id) }
    private fun choose(id: Int) { compose.onNode(hasText(text(id)) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun form() { compose.waitUntil(10_000) { !files.state.value.loading && !files.state.value.browsing }; assertNull(files.state.value.error); assertNull(files.state.value.browseError); assertNotNull(files.state.value.draft) }
    private fun destination() { compose.onNodeWithTag("photos_files_target_20").performScrollTo().performClick(); form() }
    private fun save() { compose.onNodeWithTag("photos_files_save").assertIsEnabled().performClick() }
    private fun records() { compose.waitUntil(10_000) { files.state.value.records.isNotEmpty() } }
    private fun finished() { compose.waitUntil(10_000) { !files.state.value.working && !files.state.value.recovering && files.state.value.records.any { it.checkpoint.finished } }; assertNull(files.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !files.state.value.working && files.state.value.records.isNotEmpty() }; assertFalse(files.state.value.records.single().checkpoint.finished); assertNull(files.state.value.error); ready() }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { close(); compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-files-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
