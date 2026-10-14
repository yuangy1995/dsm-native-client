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

/** 生产图库与相册记录，接口和媒体全部合成，拦截器不访问真实网络。 */
class SynologyPhotosTemporaryUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profile = NasProfile("photos-temporary-${UUID.randomUUID()}", "Synthetic Photos", "https://photos.example.invalid", "synthetic")
    private val owner = WorkspaceOwner(profile.id, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private lateinit var factory: () -> SynologyPhotosRepository
    private var epoch by mutableIntStateOf(0)
    private val albums get() = model.albums!!
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields[key]?.let(Json::parseToJsonElement)
        fun ids(key: String) = value(key)!!.let { if (it is JsonArray) it.map { v -> v.jsonPrimitive.long } else listOf(it.jsonPrimitive.long) }
    }
    private data class Album(val name: String, val temporary: Boolean = true, var shared: Boolean = true,
        val members: Set<Long> = setOf(91L, 92L), var privacy: String = "private")
    private val values = ConcurrentHashMap<Long, Album>()
    private val writes = CopyOnWriteArrayList<Call>()
    private var createGate: CompletableDeferred<Unit>? = null
    private var readGate: CompletableDeferred<Unit>? = null
    private var failRead = false; private var failCopy = false; private var skipDelete = false

    @After fun cleanup() {
        createGate?.complete(Unit); readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profile.id)
        if (::editStore.isInitialized) editStore.removeProfile(profile.id)
    }
    @Test fun 所选照片创建临时分享配置并保留链接() {
        show(); ready(); selectCreate(); name("Synthetic selected share"); capture("create-form"); save()
        prepared(); capture("sharing-prepared"); assertEquals("true", writes.single().fields["shared"])
        assertEquals("[91,92]", writes.single().fields["item"])
        compose.onNodeWithTag("photos_sharing_form").performScrollToNode(hasTestTag("photos_sharing_copy"))
        compose.onNodeWithTag("photos_sharing_copy").assertIsEnabled(); save(); finished(); capture("configured")
        assertNull(albums.state.value.temporaryPreparationId)
        closeDialog(); assertTrue(values.containsKey(72)); assertEquals(listOf("create"), writes.map { it.method })
    }
    @Test fun 准备完成后返回会停止分享且不删除原照片() {
        show(); ready(); selectCreate(); name("Synthetic cancelled share"); save(); prepared()
        capture("cancel-ready"); compose.onNodeWithText(text(R.string.sp_temporary_cancel)).performClick()
        compose.waitUntil(10_000) { !albums.state.value.working && !values.containsKey(72) }; ready()
        assertEquals(listOf("create", "set_shared", "delete"), writes.map { it.method })
        assertEquals(2, model.state.value.items.size); capture("cancelled-library")
        menu(R.string.sp_album_records); recordsReady(); capture("cancel-completed")
    }
    @Test fun 创建中取消等待可靠编号且不重复发送() {
        show(); ready(); createGate = CompletableDeferred(); selectCreate(); name("Synthetic slow share"); save()
        compose.waitUntil(10_000) { writes.any { it.method == "create" } }; capture("creating")
        compose.onNodeWithText(text(R.string.sp_temporary_cancel)).performClick()
        compose.onNodeWithText(text(R.string.sp_temporary_cancelling)).assertIsNotEnabled(); capture("cancel-requested")
        compose.runOnIdle { createGate!!.complete(Unit) }
        compose.waitUntil(10_000) { !albums.state.value.working && writes.size == 3 }; ready()
        assertFalse(values.containsKey(72)); assertEquals(listOf("create", "set_shared", "delete"), writes.map { it.method }); capture("cancel-after-create")
    }
    @Test fun 停止分享可保留普通相册且先完成复制() {
        show(); ready(); openTemporary(); capture("temporary-manage")
        compose.onNodeWithText(text(R.string.sp_album_delete)).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_album_rename)).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_temporary_stop)).performClick(); accessReady()
        compose.onNodeWithText(text(R.string.sp_temporary_keep_copy)).performScrollTo().assertIsOff().performClick().assertIsOn(); capture("stop-keep-confirmation")
        save(); finished(); capture("stop-kept")
        assertEquals(listOf("copy", "set_shared", "delete"), writes.map { it.method })
        assertFalse(values.containsKey(71)); assertEquals(setOf(91L, 92L), values.getValue(73).members)
        assertFalse(values.getValue(73).temporary); assertFalse(values.getValue(73).shared)
        closeDialog(); ready(); assertNull(model.state.value.navigation.album); capture("ordinary-album-list")
    }
    @Test fun 加载和读取错误可恢复停止回执未知冷恢复仅查询() {
        show(); ready(); openTemporary()
        readGate = CompletableDeferred(); compose.onNodeWithText(text(R.string.sp_temporary_stop)).performClick()
        compose.waitUntil(5_000) { albums.state.value.loading }; capture("stop-loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.error != null }; capture("stop-read-error")
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); accessReady()
        skipDelete = true; save(); pending(); capture("cleanup-pending")
        assertEquals(2, writes.size); closeDialog()
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        menu(R.string.sp_album_records); recordsReady(); compose.onNodeWithTag("photos_album_resume").performClick(); pending()
        assertEquals(2, writes.size); capture("cold-read-only")
        values.remove(71); compose.onNodeWithTag("photos_album_resume").performClick(); finished()
        assertEquals(2, writes.size); capture("cold-completed")
    }
    @Test fun 未取得副本编号保持原分享且记录不误报完成() {
        failCopy = true; show(); ready(); openTemporary()
        compose.onNodeWithText(text(R.string.sp_temporary_stop)).performClick(); accessReady()
        compose.onNodeWithText(text(R.string.sp_temporary_keep_copy)).performScrollTo().performClick(); save(); pending()
        assertTrue(values.getValue(71).shared); assertTrue(values.containsKey(73)); assertEquals(listOf("copy"), writes.map { it.method })
        capture("copy-unknown"); compose.onNodeWithTag("photos_album_resume").performClick(); pending(); assertEquals(1, writes.size)
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); values[71] = Album("Synthetic existing share")
        val bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.rgb(62, 137, 177)) }
        val image = ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() }; bitmap.recycle()
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Browse.NormalAlbum", "Sharing.Passphrase")
        val caps = suffixes.associate { "SYNO.Foto.$it" to ApiCapability("SYNO.Foto.$it", "entry.cgi", 1, 5, "JSON") }
        factory = { SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields)
            if (cap.name.endsWith("Browse.Album") && method == "get") { readGate?.await(); if (failRead) throw IOException("synthetic read") }
            if (method in setOf("create", "copy", "delete", "set_shared")) writes += call
            if (method == "create") createGate?.await()
            response(call)
        }, media) }
        model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = false, onBackup = {}) }
        } } } }
    }
    private fun makeModel() = SynologyPhotosModel(factory(), scope, uploadOwner = owner, editStore = editStore, albumStore = store)
    private fun response(call: Call): JsonObject {
        fun list(rows: List<JsonObject>) = buildJsonObject { put("list", JsonArray(rows)) }
        return when {
            call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41,"uid":1041}""")
            call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"none"}""")
            call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":false}""")
            call.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2025,"month":1,"day":1,"item_count":2}]}]}""")
            call.api.endsWith("Browse.Category") -> list(emptyList())
            call.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"manage":true,"download":true}}}}""")
            call.api.endsWith("Browse.Item") -> {
                val albumId = call.fields["album_id"]?.toLong()
                val ids = if (call.method == "get") call.ids("id") else (if (albumId == null) listOf(91L, 92L) else values.getValue(albumId).members.sorted())
                    .drop(call.fields.getValue("offset").toInt()).take(call.fields.getValue("limit").toInt())
                list(ids.map { item(it, albumId != null) })
            }
            call.api.endsWith("Browse.Album") && call.method in setOf("get", "list") -> {
                val ids = if (call.method == "get") call.ids("id") else values.keys.sorted().drop(call.fields.getValue("offset").toInt()).take(call.fields.getValue("limit").toInt())
                list(ids.mapNotNull { id -> values[id]?.let { album(id, it) } })
            }
            call.method == "create" -> { values[72] = Album(call.value("name")!!.jsonPrimitive.content, members = call.ids("item").toSet()); obj("""{"album":{"id":72}}""") }
            call.method == "copy" -> {
                values[73] = values.getValue(call.ids("source_album_id").single()).copy(temporary = false, shared = false)
                if (failCopy) throw IOException("synthetic unknown copy"); obj("""{"album":{"id":73}}""")
            }
            call.method == "set_shared" -> { values.getValue(call.ids("album_id").single()).shared = call.value("enabled")!!.jsonPrimitive.boolean; obj("""{"passphrase":"synthetic-secret"}""") }
            call.method == "delete" -> { if (!skipDelete) values.remove(call.ids("id").single()); obj("{}") }
            else -> error("Unexpected synthetic request ${call.api}.${call.method}")
        }
    }
    private fun album(id: Long, row: Album) = obj("""{"id":$id,"name":${JsonPrimitive(row.name)},"type":"normal","owner_user_id":41,"freeze_album":false,"temporary_shared":${row.temporary},"shared":${row.shared},"item_count":${row.members.size},"additional":{"sharing_info":{"privacy_type":"${row.privacy}","sharing_link":"https://example.invalid/synthetic","passphrase":"synthetic-secret","enable_password":false,"expiration":0,"permission":[]}}}""")
    private fun item(id: Long, inAlbum: Boolean) = obj("""{"id":$id,"filename":"synthetic-$id.jpg","filesize":4,"time":1735689600,"indexed_time":1735689600,"folder_id":9,"type":"photo",${if (inAlbum) "\"owner_user_id\":41," else ""}"additional":{"provider_user_id":41,"rating":0,"description":"","tag":[],"thumbnail":{"unit_id":$id,"cache_key":"r"}}}""")
    private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun accessReady() { compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.access != null }; assertNull(albums.state.value.error) }
    private fun recordsReady() { compose.waitUntil(10_000) { albums.state.value.records.isNotEmpty() } }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithText(text(id)).performClick() }
    private fun selectCreate() {
        photo(91).performTouchInput { longClick() }; photo(92).performClick()
        compose.onNodeWithText(text(R.string.sp_album_manage)).performClick(); compose.onNodeWithText(text(R.string.sp_temporary_create)).performClick()
        compose.onNodeWithTag("photos_album_save").assertIsNotEnabled()
    }
    private fun photo(id: Long) = compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "synthetic-$id.jpg"))
    private fun openTemporary() {
        compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready(); compose.onNodeWithText("Synthetic existing share").performClick(); ready()
        menu(R.string.sp_album_manage); accessReady()
    }
    private fun name(value: String) { compose.onNodeWithTag("photos_album_name").performTextReplacement(value); compose.onNodeWithTag("photos_album_name").performImeAction() }
    private fun save() { compose.onNodeWithTag("photos_album_save").assertIsEnabled().performClick() }
    private fun prepared() { compose.waitUntil(10_000) { !albums.state.value.working && !albums.state.value.loading && albums.state.value.temporaryPreparationId != null && albums.sharing.state.value.original != null }; assertNull(albums.state.value.error); ready() }
    private fun finished() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.any { it.id == albums.state.value.activeId && it.checkpoint.phase == SynologyPhotoAlbumPhase.COMPLETED } }; assertNull(albums.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.isNotEmpty() }; assertFalse(albums.state.value.records.single().checkpoint.finished); assertNull(albums.state.value.error); ready() }
    private fun closeDialog() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-temporary-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
