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
import androidx.compose.ui.unit.dp
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

/** 生产图库、相册仓储及加密记录的原生流程；网络和图片均为合成测试资料。 */
class SynologyPhotosAlbumUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profile = NasProfile("photos-album-test-${UUID.randomUUID()}", "Synthetic Photos", "https://photos.example.invalid", "synthetic")
    private val owner = WorkspaceOwner(profile.id, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private lateinit var repositoryFactory: () -> SynologyPhotosRepository
    private var epoch by mutableIntStateOf(0)
    private val albums get() = model.albums!!
    private data class Call(val name: String, val method: String, val fields: Map<String, String>)
    private data class Album(var name: String, val members: MutableSet<Long> = ConcurrentHashMap.newKeySet(), var cover: Long? = null)
    private val writes = CopyOnWriteArrayList<Call>()
    private val values = ConcurrentHashMap<Long, Album>()
    private var home = true
    private var albumOwner = 41L
    private var allowContribute = true
    private var applyWrites = true
    private var omitReceipt = false
    private var failAccess = false
    private var noAddable = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profile.id)
        if (::editStore.isInitialized) editStore.removeProfile(profile.id)
    }

    @Test fun 新建空相册和网格多选创建均使用实际编号() {
        show(); ready(); menu(R.string.sp_album_create); formReady()
        compose.onNodeWithTag("photos_album_save").assertIsNotEnabled()
        name("Empty synthetic album"); capture("create-empty-form"); save(); saved()
        assertEquals("[]", writes.single().fields["item"])
        closeDialog(); ready()
        photo(91).performTouchInput { longClick() }; photo(92).performClick()
        compose.onAllNodes(isToggleable()).assertCountEquals(2)
        selectionAction(R.string.sp_album_create); formReady()
        name("Selected 合成相册"); capture("create-selected-form"); save(); saved()
        assertEquals("[91,92]", writes.last().fields["item"])
        assertEquals(2, values.getValue(albums.state.value.records.first { it.id == albums.state.value.activeId }.checkpoint.createdAlbumId!!).members.size)
        capture("create-completed")
        closeDialog(); openAlbumList(); capture("album-list")
        compose.onNodeWithText("Selected 合成相册").performClick(); ready()
        assertEquals(2, model.state.value.items.size)
    }

    @Test fun 加入相册选择封面和移出均保留原件() {
        show(); ready(); photo(92).performTouchInput { longClick() }
        selectionAction(R.string.sp_album_add); formReady()
        compose.waitUntil(10_000) { !albums.state.value.albumsLoading }
        compose.onNodeWithText("Synthetic album").assertHeightIsAtLeast(48.dp).performClick(); formReady()
        capture("add-form"); save(); saved()
        assertEquals(mapOf("id" to "71", "item" to "[92]"), writes.last().fields)
        closeDialog(); openAlbum(); photo(92).performTouchInput { longClick() }
        selectionAction(R.string.sp_album_cover); formReady(); capture("cover-form"); save(); saved()
        assertEquals(92L, values.getValue(71).cover)
        closeDialog(); ready(); photo(92).performTouchInput { longClick() }
        selectionAction(R.string.sp_album_remove); formReady()
        compose.onNodeWithText(text(R.string.sp_album_remove_note)).performScrollTo().assertIsDisplayed()
        capture("remove-confirmation"); save(); saved()
        assertEquals(setOf(91L), values.getValue(71).members)
        closeDialog(); compose.runOnIdle { model.selectSection(SynologyPhotosSection.TIMELINE) }; ready()
        assertEquals(2, model.state.value.items.size)
        assertEquals(listOf("add_item", "set_cover", "delete_item"), writes.map { it.method })
    }

    @Test fun 改名同步导航删除相册回到列表并保留照片() {
        show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady()
        capture("manage"); compose.onNodeWithText(text(R.string.sp_album_rename)).performClick(); formReady()
        name("Renamed synthetic album"); capture("rename-form"); save(); saved()
        assertEquals("Renamed synthetic album", model.state.value.navigation.album?.name)
        closeDialog(); ready(); menu(R.string.sp_album_manage); accessReady()
        compose.onNodeWithText(text(R.string.sp_album_delete)).performClick(); formReady()
        compose.onNodeWithText(text(R.string.sp_album_delete_note)).performScrollTo().assertIsDisplayed()
        capture("delete-confirmation"); save(); saved()
        assertTrue(values.isEmpty()); assertNull(model.state.value.navigation.album)
        closeDialog(); ready(); compose.onNodeWithText(text(R.string.sp_library_no_albums)).assertIsDisplayed(); capture("albums-empty")
        compose.runOnIdle { model.selectSection(SynologyPhotosSection.TIMELINE) }; ready()
        assertEquals(2, model.state.value.items.size)
        assertEquals(listOf("set_name", "delete"), writes.map { it.method })
        assertTrue(writes.all { it.name.endsWith("Browse.Album") })
    }

    @Test fun 中断重建只回读且跨照片编辑不能绕过未完成相册操作() {
        show(); ready(); photo(91).performTouchInput { longClick() }
        selectionAction(R.string.sp_album_create); formReady(); name("Pending synthetic album")
        applyWrites = false; save()
        compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.singleOrNull()?.checkpoint?.phase == SynologyPhotoAlbumPhase.PENDING }
        val row = albums.state.value.records.single().checkpoint
        capture("pending")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        photo(91).performTouchInput { longClick() }; compose.onNodeWithText(text(R.string.sp_edit_title)).performClick()
        compose.waitUntil(10_000) { model.edits!!.state.value.detailsReady }
        compose.onNodeWithTag("photos_edit_rating_4").performClick()
        compose.onNodeWithTag("photos_edit_save").performClick()
        compose.waitUntil(10_000) { !model.edits!!.state.value.working && model.edits!!.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_album_conflict)).assertIsDisplayed(); capture("pending-blocks-edit")
        assertEquals(1, writes.size)
        closeDialog(); ready(); menu(R.string.sp_album_records)
        compose.waitUntil(10_000) { albums.state.value.records.isNotEmpty() }
        values.getValue(row.createdAlbumId!!).members += 91L
        compose.onNodeWithTag("photos_album_resume").performScrollTo().performClick(); saved()
        assertEquals(1, writes.size); assertEquals(row.operationId, albums.state.value.records.single().id)
        capture("restored-completed")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performScrollTo().performClick()
        compose.waitUntil(10_000) { albums.state.value.records.isEmpty() }
        compose.onNodeWithText(text(R.string.sp_album_no_records)).assertIsDisplayed(); capture("records-empty")
    }

    @Test fun 加载失败可重试而失去权限与没有可加入相册不发送写入() {
        show(); ready(); openAlbum(); gate = CompletableDeferred()
        menu(R.string.sp_album_manage); compose.waitUntil(10_000) { albums.state.value.loading }; capture("loading")
        failAccess = true; gate!!.complete(Unit); gate = null
        compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.error != null }
        capture("read-error"); failAccess = false
        compose.onNodeWithText(text(R.string.sp_retry)).performClick(); accessReady()
        compose.onNodeWithText(text(R.string.sp_album_rename)).performClick(); formReady(); name("Denied synthetic album")
        albumOwner = 42; save()
        compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.error != null }
        assertTrue(writes.isEmpty()); capture("permission-error")
        closeDialog(); compose.runOnIdle { model.selectSection(SynologyPhotosSection.TIMELINE) }; ready()
        photo(92).performTouchInput { longClick() }; noAddable = true
        selectionAction(R.string.sp_album_add); formReady()
        compose.waitUntil(10_000) { !albums.state.value.albumsLoading }
        compose.onNodeWithText(text(R.string.sp_album_none_addable)).assertIsDisplayed()
        compose.onNodeWithTag("photos_album_save").assertIsNotEnabled(); capture("no-addable-albums")
        assertTrue(writes.isEmpty())
    }

    @Test fun 无原来源的贡献者可移出本人贡献但不能改名删除() {
        home = false; albumOwner = 42; show(); ready(); openAlbum()
        menu(R.string.sp_album_manage); accessReady()
        compose.onNodeWithText(text(R.string.sp_album_rename)).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_album_delete)).assertDoesNotExist(); capture("contributor-manage")
        closeDialog(); photo(91).performTouchInput { longClick() }; selectionAction(R.string.sp_album_remove); formReady()
        capture("contributor-remove"); save(); saved()
        assertEquals(setOf("passphrase", "item"), writes.single().fields.keys)
        assertTrue(values.getValue(71).members.isEmpty())
        assertFalse(writes.any { it.name.endsWith("Browse.Item") })
    }

    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context)
        values[71] = Album("Synthetic album").apply { members += 91L }
        val bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.rgb(62, 137, 177)) }
        val image = ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() }; bitmap.recycle()
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Browse.NormalAlbum", "Sharing.Passphrase")
        val capabilities = suffixes.associate { "SYNO.Foto.$it" to ApiCapability("SYNO.Foto.$it", "entry.cgi", 1, 5, "JSON") }
        repositoryFactory = { SynologyPhotosRepository(profile.id, capabilities, { cap, method, fields ->
            if (cap.name.endsWith("Browse.Album") && method == "get") { gate?.await(); if (failAccess) throw IOException("synthetic read failure") }
            response(Call(cap.name, method, fields))
        }, media) }
        model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme {
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = false, onBackup = {}) }
            }
        } } }
    }
    private fun makeModel() = SynologyPhotosModel(repositoryFactory(), scope, uploadOwner = owner, editStore = editStore, albumStore = store)
    private fun response(call: Call): JsonObject {
        fun ids(key: String) = Json.parseToJsonElement(call.fields.getValue(key)).let { value -> if (value is JsonArray) value.map { it.jsonPrimitive.long } else listOf(value.jsonPrimitive.long) }
        fun value(key: String) = Json.parseToJsonElement(call.fields.getValue(key)).jsonPrimitive.content
        fun list(rows: List<JsonObject>) = buildJsonObject { put("list", JsonArray(rows)) }
        return when {
            call.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
            call.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"none"}""")
            call.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            call.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":false}""")
            call.name.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2025,"month":1,"day":1,"item_count":2}]}]}""")
            call.name.endsWith("Browse.Category") -> list(emptyList())
            call.name.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":$allowContribute,"download":true}}""")
            call.name.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"upload":true,"manage":true}}}}""")
            call.name.endsWith("Browse.Album") && call.method in setOf("get", "list") -> {
                val selected = if (call.method == "get") ids("id") else values.keys.sorted().drop(call.fields.getValue("offset").toInt()).take(call.fields.getValue("limit").toInt())
                list(selected.mapNotNull { id -> values[id]?.let { album(id, it) } })
            }
            call.name.endsWith("Browse.NormalAlbum") && call.method == "list" -> list(if (noAddable) emptyList() else values.keys.sorted().map { album(it, values.getValue(it)) })
            call.name.endsWith("Browse.Item") && call.method in setOf("get", "list") -> {
                val albumId = call.fields["album_id"]?.toLong()
                val selected = if (call.method == "get") ids("id") else (if (albumId == null) listOf(91L, 92L) else values.getValue(albumId).members.sorted())
                    .drop(call.fields.getValue("offset").toInt()).take(call.fields.getValue("limit").toInt())
                list(selected.map { item(it, albumId != null) })
            }
            call.name.endsWith("Browse.NormalAlbum") || call.name.endsWith("Browse.Album") -> {
                writes += call
                var receipt = obj("{}")
                val id = call.fields["id"]?.let { ids("id").single() } ?: 71
                when (call.method) {
                    "create" -> {
                        val created = (values.keys.maxOrNull() ?: 99) + 1
                        values[created] = Album(value("name")).apply { if (applyWrites) members += ids("item") }
                        receipt = obj("""{"album":{"id":$created}}""")
                    }
                    "set_name" -> if (applyWrites) values.getValue(id).name = value("name")
                    "delete" -> if (applyWrites) values.remove(id)
                    "set_cover" -> if (applyWrites) values.getValue(id).cover = ids("id_item").single()
                    "add_item" -> if (applyWrites) values.getValue(id).members += ids("item")
                    "delete_item" -> if (applyWrites) values.getValue(id).members.removeAll(ids("item").toSet())
                    else -> error("Unexpected synthetic write")
                }
                if (omitReceipt) throw IOException("synthetic connection loss")
                receipt
            }
            else -> error("Unexpected synthetic request")
        }
    }
    private fun album(id: Long, row: Album) = obj("""{"id":$id,"name":${JsonPrimitive(row.name)},"type":"normal","owner_user_id":$albumOwner,"freeze_album":false,"temporary_shared":false,"passphrase":"synthetic-token","item_count":${row.members.size},"additional":${if (row.cover == null) "{}" else """{"thumbnail":{"unit_id":${row.cover},"cache_key":"synthetic"}}"""}}""")
    private fun item(id: Long, inAlbum: Boolean) = obj("""{"id":$id,"filename":"synthetic-$id.jpg","filesize":4,"time":1735689600,"indexed_time":1735689600,"folder_id":9,"type":"photo",${if (inAlbum) "\"owner_user_id\":41," else ""}"additional":{"provider_user_id":41,"rating":0,"description":"","tag":[],"thumbnail":{"unit_id":$id,"cache_key":"r"}}}""")
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun formReady() { compose.waitUntil(10_000) { albums.state.value.visible && !albums.state.value.loading }; assertNull(albums.state.value.error) }
    private fun accessReady() { compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.access != null }; assertNull(albums.state.value.error) }
    private fun menu(label: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithText(text(label)).performClick() }
    private fun selectionAction(label: Int) { compose.onNodeWithText(text(R.string.sp_album_manage)).performClick(); compose.onNodeWithText(text(label)).performClick() }
    private fun openAlbumList() { compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready() }
    private fun openAlbum() { if (!model.state.value.navigation.showsCollectionRoot) openAlbumList(); compose.onNodeWithText(values.getValue(71).name).performClick(); ready() }
    private fun name(value: String) { compose.onNodeWithTag("photos_album_name").performTextReplacement(value); hideKeyboard() }
    private fun save() { compose.onNodeWithTag("photos_album_save").assertIsEnabled().performClick() }
    private fun saved() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.any { it.id == albums.state.value.activeId && it.checkpoint.phase == SynologyPhotoAlbumPhase.COMPLETED } }; assertNull(albums.state.value.error) }
    private fun closeDialog() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun text(id: Int) = context.getString(id)
    private fun photo(id: Long) = compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "synthetic-$id.jpg"))
    private fun hideKeyboard() {
        compose.onNodeWithTag("photos_album_name").performImeAction()
        // 等待系统键盘退出后的实际布局，不把过渡帧当作表单截图。
        compose.waitUntil(5_000) {
            val root = compose.onNode(isDialog()).fetchSemanticsNode().boundsInRoot
            compose.onNodeWithTag("photos_album_save").fetchSemanticsNode().boundsInRoot.bottom > root.bottom * .85f
        }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-album-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
