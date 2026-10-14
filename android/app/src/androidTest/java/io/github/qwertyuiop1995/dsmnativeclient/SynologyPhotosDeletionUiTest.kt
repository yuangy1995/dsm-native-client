package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
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

/** 合成 NAS 驱动生产图库、逐项删除仓储和加密记录，实际运行 Compose 与图片解码。 */
class SynologyPhotosDeletionUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profileId = "deletion-ui-${UUID.randomUUID()}"
    private val owner = WorkspaceOwner(profileId, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoDeletionStore
    private lateinit var edits: SynologyPhotoEditStore
    private lateinit var albums: SynologyPhotoAlbumStore
    private val deletion get() = model.deletion
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun ids(key: String) = Json.parseToJsonElement(fields.getValue(key)).jsonArray.map { it.jsonPrimitive.long }
    }
    private val originals = ConcurrentHashMap<Pair<Boolean, Long>, String>().apply {
        for (shared in listOf(false, true)) for (id in listOf(21L, 22L)) put(shared to id, "Photo$id.jpg")
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes = CopyOnWriteArrayList<Call>()
    private var readGate: CompletableDeferred<Unit>? = null
    private var failRead = false
    private var unknown = false
    private var denied = false
    private var sharedManage = true

    @After fun cleanup() {
        readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profileId)
        if (::edits.isInitialized) edits.removeProfile(profileId)
        if (::albums.isInitialized) albums.removeProfile(profileId)
    }

    @Test fun 预览单张删除取消零写入确认后关闭已删原件() {
        show(); source(); preview(21)
        compose.onNodeWithContentDescription(text(R.string.sp_delete_action)).performScrollTo().performClick(); form()
        capture("preview-confirmation"); assertEquals(listOf(21L), deletion.state.value.candidate!!.map { it.id.itemId })
        close(); assertNotNull(model.preview.state.value.photo); assertTrue(writes.isEmpty())
        compose.onNodeWithContentDescription(text(R.string.sp_delete_action)).performScrollTo().performClick(); form()
        confirm(); finished(); capture("preview-completed")
        assertNull(model.preview.state.value.photo); assertEquals("[21]", writes.single().fields["item_id"])
        assertEquals("[]", writes.single().fields["folder_id"]); close()
        assertEquals(listOf(22L), model.state.value.items.map { it.id.itemId }); capture("single-remaining")
    }

    @Test fun 批量清单逐项删除完成仍停留原目录() {
        show(); source(); select(); open(); form(); capture("batch-confirmation")
        compose.onNode(hasText("Photo21.jpg") and hasAnyAncestor(hasTestTag("photos_deletion_selection"))).assertExists()
        compose.onNode(hasText("Photo22.jpg") and hasAnyAncestor(hasTestTag("photos_deletion_selection"))).performScrollTo().assertIsDisplayed()
        assertTrue(writes.isEmpty()); confirm(); finished(); capture("batch-completed")
        assertEquals(listOf("[21]", "[22]"), writes.map { it.fields["item_id"] })
        assertTrue(writes.all { it.api == "SYNO.Foto.BackgroundTask.File" && it.method == "delete" && it.fields.keys == setOf("item_id", "folder_id") })
        assertEquals(2, record().count(SynologyPhotoDeletionPhase.CONFIRMED)); close()
        assertEquals(9L, model.state.value.navigation.folders.last().id); assertTrue(model.state.value.items.isEmpty()); capture("deleted-empty")
    }

    @Test fun 共享上传权不足以删除恢复管理权后使用共享原件接口() {
        sharedManage = false; show(); ready()
        compose.onNodeWithTag("photos_source").performClick(); choose(R.string.sp_source_shared); ready(); source(); select(); open(); error()
        compose.onNodeWithText(text(R.string.sp_delete_denied)).assertExists(); capture("shared-denied")
        assertTrue(writes.isEmpty()); assertTrue(store.records(owner, 41).isEmpty())
        sharedManage = true; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form(); confirm(); finished(); capture("shared-completed")
        assertTrue(writes.all { it.api == "SYNO.FotoTeam.BackgroundTask.File" })
        assertEquals(2, originals.keys.count { !it.first }); assertEquals(0, originals.keys.count { it.first })
    }

    @Test fun 未知结果停止后续冷恢复只读完成后剩余项重新确认() {
        unknown = true; show(); source(); select(); open(); form(); confirm(); pending(); capture("unknown-record")
        assertEquals(1, writes.size); assertEquals(1, record().count(SynologyPhotoDeletionPhase.PREPARED))
        cold(); menu(R.string.sp_deletion_records); records(); capture("unknown-cold-record")
        compose.onNodeWithTag("photos_deletion_resume").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist(); assertEquals(1, writes.size)
        originals.remove(false to 21L)
        compose.waitUntil(20_000) { record().count(SynologyPhotoDeletionPhase.SUBMITTED) == 0 && !deletion.state.value.recovering }
        capture("cold-read-completed"); compose.onNodeWithTag("photos_deletion_resume").performScrollTo().performClick(); form(); capture("remaining-confirmation")
        assertEquals(listOf(22L), deletion.state.value.candidate!!.map { it.id.itemId }); assertEquals(1, writes.size)
        unknown = false; confirm(); finished(); capture("resumed-completed")
        assertEquals(listOf("[21]", "[22]"), writes.map { it.fields["item_id"] })
    }

    @Test fun 取消剩余项保留未知删除记录且重启不重发() {
        unknown = true; show(); source(); select(); open(); form(); confirm(); pending()
        compose.onNodeWithTag("photos_deletion_cancel_remaining").performScrollTo().performClick()
        compose.waitUntil(10_000) { !deletion.state.value.checking && record().count(SynologyPhotoDeletionPhase.CANCELLED) == 1 }
        capture("remaining-cancelled"); assertEquals(1, record().count(SynologyPhotoDeletionPhase.SUBMITTED))
        assertFalse(record().finished); compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
        cold(); menu(R.string.sp_deletion_records); records(); capture("cancelled-cold-record")
        assertEquals(1, record().count(SynologyPhotoDeletionPhase.CANCELLED)); assertEquals(1, writes.size)
        assertEquals(2, originals.keys.count { !it.first })
    }

    @Test fun 明确拒绝停止该批次剩余项可重新确认() {
        denied = true; show(); source(); select(); open(); form(); confirm()
        compose.waitUntil(10_000) { !deletion.state.value.writing && deletion.state.value.error != null }; records(); capture("explicit-denial")
        assertEquals(1, record().count(SynologyPhotoDeletionPhase.REJECTED)); assertEquals(1, record().count(SynologyPhotoDeletionPhase.PREPARED))
        assertEquals(1, writes.size); compose.onNodeWithTag("photos_deletion_resume").performScrollTo().performClick(); form()
        assertEquals(listOf(22L), deletion.state.value.candidate!!.map { it.id.itemId })
        denied = false; confirm(); finished(); capture("denial-remaining-completed")
        assertEquals(1, record().count(SynologyPhotoDeletionPhase.REJECTED)); assertEquals(1, record().count(SynologyPhotoDeletionPhase.CONFIRMED))
        assertEquals(setOf(false to 21L), originals.keys.filter { !it.first }.toSet())
    }

    @Test fun 空记录加载失败和确认后读取失败均可恢复且不先写入() {
        show(); ready(); menu(R.string.sp_deletion_records)
        compose.waitUntil(10_000) { !deletion.state.value.checking }
        compose.onNodeWithText(text(R.string.sp_deletion_empty)).assertExists(); capture("empty-records"); close(); source(); select()
        readGate = CompletableDeferred(); open(); compose.waitUntil(10_000) { deletion.state.value.checking }; capture("preflight-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }; error(); capture("preflight-error")
        assertTrue(writes.isEmpty()); failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form()
        failRead = true; confirm(); error(); capture("confirmation-read-error")
        assertEquals(2, deletion.state.value.candidate!!.size); assertTrue(writes.isEmpty()); assertTrue(store.records(owner, 41).isEmpty())
        failRead = false; confirm(); finished(); capture("preflight-retry-completed")
    }

    @Test fun 冷恢复剩余原件变化拒绝继续仍可取消未发送项() {
        unknown = true; show(); source(); select(); open(); form(); confirm(); pending(); cold()
        originals.remove(false to 21L); originals[false to 22L] = "Changed.jpg"
        menu(R.string.sp_deletion_records); records()
        compose.waitUntil(20_000) { record().count(SynologyPhotoDeletionPhase.SUBMITTED) == 0 && !deletion.state.value.recovering }
        compose.onNodeWithTag("photos_deletion_resume").performScrollTo().performClick(); error(); capture("changed-original-error")
        compose.onNodeWithText(text(R.string.sp_delete_changed)).assertExists(); assertNull(deletion.state.value.candidate); assertEquals(1, writes.size)
        close(); menu(R.string.sp_deletion_records); records()
        compose.onNodeWithTag("photos_deletion_cancel_remaining").performScrollTo().performClick(); finished(); capture("changed-remaining-cancelled")
        assertEquals(1, record().count(SynologyPhotoDeletionPhase.CANCELLED)); assertEquals(1, writes.size)
    }

    private fun show() {
        store = SynologyPhotoDeletionStore(context); edits = SynologyPhotoEditStore(context); albums = SynologyPhotoAlbumStore(context)
        model = makeModel()
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
            if (call.api.endsWith("Browse.Item") && method == "get") { readGate?.await(); if (failRead) throw IOException("Synthetic item read") }
            response(call)
        }, media, canDeleteOriginals = true)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, editStore = edits, albumStore = albums, deletionStore = store)
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
            c.api.endsWith("Browse.Folder") && c.method == "list" -> list(if (c.fields["id"] == "1") listOf(folder(shared, 9)) else emptyList())
            c.api.endsWith("Browse.Item") && c.method == "get" -> list(c.ids("id").mapNotNull { id -> originals[shared to id]?.let { photo(shared, id) } })
            c.api.endsWith("Browse.Item") && c.method == "list" -> list(if (c.fields["folder_id"] == "9") originals.keys.filter { it.first == shared }.sortedBy { it.second }.map { photo(shared, it.second) } else emptyList())
            c.api.endsWith("BackgroundTask.File") && c.method == "delete" -> {
                writes += c
                if (denied) throw DsmFailure(105, "Synthetic permission failure", "Synthetic", false)
                if (unknown) throw IOException("Synthetic lost response")
                c.ids("item_id").forEach { originals.remove(shared to it) }; obj("{}")
            }
            else -> error("Unexpected synthetic operation ${c.api} ${c.method}")
        }
    }
    private fun folder(shared: Boolean, id: Long) = obj("""{"id":$id,"name":"${if (id == 1L) "/" else "/Source"}","parent":${if (id == 1L) 0 else 1},"additional":{"access_permission":{"view":true,"manage":${!shared || sharedManage},"upload":true,"download":true}}}""")
    private fun photo(shared: Boolean, id: Long) = buildJsonObject {
        put("id", id); put("filename", originals.getValue(shared to id)); put("filesize", 4); put("time", 100); put("indexed_time", 200); put("folder_id", 9); put("type", "photo")
        put("additional", obj("""{"thumbnail":{"unit_id":$id,"cache_key":"synthetic"}}"""))
    }
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading && !deletion.state.value.checking }; assertNull(model.state.value.error) }
    private fun source() { ready(); compose.onNodeWithText(text(R.string.sp_library_folders)).performClick(); ready(); compose.onNodeWithText("Source").performClick(); ready() }
    private fun preview(id: Long) {
        compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Photo$id.jpg")).performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo != null && !model.preview.state.value.loading }; assertNull(model.preview.state.value.error)
    }
    private fun select() { menu(R.string.sp_files_select); compose.onNodeWithText(text(R.string.sp_files_select_loaded)).performClick(); assertEquals(2, model.edits!!.state.value.selected.size) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); choose(id) }
    private fun choose(id: Int) { compose.onNode(hasText(text(id)) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun open() { compose.onNodeWithTag("photos_deletion_selected").assertIsEnabled().performClick() }
    private fun form() { compose.waitUntil(10_000) { !deletion.state.value.checking }; assertNull(deletion.state.value.error); assertNotNull(deletion.state.value.candidate) }
    private fun error() { compose.waitUntil(10_000) { !deletion.state.value.checking && !deletion.state.value.writing && deletion.state.value.error != null } }
    private fun confirm() { compose.onNodeWithTag("photos_deletion_confirm").assertIsEnabled().performClick() }
    private fun records() { compose.waitUntil(10_000) { deletion.state.value.records.isNotEmpty() && !deletion.state.value.checking } }
    private fun record() = deletion.state.value.records.single()
    private fun finished() {
        compose.waitUntil(10_000) { !deletion.state.value.writing && !deletion.state.value.checking && !deletion.state.value.recovering && deletion.state.value.records.singleOrNull()?.finished == true }
        assertNull(deletion.state.value.error)
    }
    private fun pending() {
        compose.waitUntil(10_000) { !deletion.state.value.writing && deletion.state.value.records.isNotEmpty() }
        assertNull(deletion.state.value.error); assertEquals(1, record().count(SynologyPhotoDeletionPhase.SUBMITTED))
    }
    private fun close() { compose.onAllNodes(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).onLast().performClick(); ready() }
    private fun cold() { close(); compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-deletions-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
