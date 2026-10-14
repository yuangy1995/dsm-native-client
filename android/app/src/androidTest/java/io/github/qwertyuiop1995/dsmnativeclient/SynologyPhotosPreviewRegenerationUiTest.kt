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
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.time.Instant
import java.time.YearMonth
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.*
import org.junit.Assert.*

/** 正式根仓储、系统解码、媒体上传、Compose 和加密恢复；只替换网络及完成通知来源。 */
class SynologyPhotosPreviewRegenerationUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("previews-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel; private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private val previews get() = model.previewRegeneration!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set_regenerating", "regenerate_preview_by_nas", "upload", "restore_from_regenerating") }
    private val queue = ConcurrentHashMap.newKeySet<Pair<SynologyPhotoSpace, Long>>()
    private val revisions = ConcurrentHashMap<Pair<SynologyPhotoSpace, Long>, String>()
    private var originalSize = 0L
    private var shared = true; private var manage = true; private var png = true
    private var failRead = false; private var unknownUpload = false; private var rejectUpload = false; private var nasSuccess = true
    private var gate: CompletableDeferred<Unit>? = null; private var writeGate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit); writeGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) {
            store.records(owner, 41).forEach { row ->
                context.cacheDir.listFiles { file -> file.name.startsWith("synology-photos-preview-${row.id}-") }?.forEach { assertTrue(it.deleteRecursively()) }
            }
            store.removeProfile(owner.profileId)
        }
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }
    @Test fun 加载空队列错误恢复和无搜索结果不发送写入() {
        show(); ready(); gate = CompletableDeferred(); menu(); compose.waitUntil(5_000) { previews.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); compose.onNodeWithText(text(R.string.sp_previews_empty)).assertIsDisplayed(); capture("empty")
        queue += SynologyPhotoSpace.PERSONAL to 1L; failRead = true; refresh(); error(); capture("read-error")
        failRead = false; refresh(); form(); compose.onNodeWithTag("photos_previews_search").performTextInput("missing")
        compose.onNodeWithText(text(R.string.sp_previews_no_match)).assertIsDisplayed(); capture("filtered-empty")
        compose.onNodeWithTag("photos_previews_search").performTextClearance(); item(1).assertIsDisplayed(); assertTrue(writes.isEmpty())
    }
    @Test fun 图库多选更新真实三档图片保留月份分页和选择() {
        shared = false; show(); ready(); compose.runOnIdle { model.jumpToMonth(YearMonth.of(2020, 3)) }; ready()
        compose.runOnIdle { model.edits!!.selectMode(true); model.edits!!.toggle(model.state.value.items.first()) }
        val before = model.state.value; val reads = photoReads()
        compose.onNodeWithTag("photos_previews_selected").performClick(); form(); start(); compose.onNodeWithText(context.resources.getQuantityString(R.plurals.sp_previews_confirm_message, 1, 1)).assertIsDisplayed(); capture("confirmation"); cancel(); assertTrue(writes.isEmpty())
        start(); confirm(); settled(); capture("updated")
        assertEquals(listOf("set_regenerating", "upload"), writes.map { it.method })
        assertEquals(before.copy(items = model.state.value.items, groups = model.state.value.groups), model.state.value)
        assertEquals("new", model.edits!!.state.value.selected.single().thumbnail!!.revision); assertEquals(reads, photoReads())
        scroll("photos_previews_details").performClick(); compose.onNodeWithText(text(R.string.sp_previews_item_done)).performScrollTo().assertIsDisplayed(); capture("item-details")
        assertTrue(context.cacheDir.listFiles { f -> f.name.startsWith("synology-photos-preview-${previews.state.value.activeId}-") }!!.isEmpty())
    }
    @Test fun 大图入口更新后仍显示同一张照片且不重新读取时间线() {
        show(); ready(); val original = model.state.value.items.first(); val reads = photoReads()
        compose.runOnIdle { model.preview.open(original) }; compose.waitUntil(5_000) { !model.preview.state.value.loading }
        compose.onNodeWithTag("photos_preview_actions").performScrollToNode(hasTestTag("photos_previews_preview"))
        compose.onNodeWithTag("photos_previews_preview").performClick(); form(); start(); confirm(); settled()
        close(); compose.waitUntil(5_000) { !model.preview.state.value.loading }
        assertEquals(original.id, model.preview.state.value.photo!!.id); assertEquals("new", model.preview.state.value.photo!!.thumbnail!!.revision)
        assertEquals(reads, photoReads()); capture("preview-preserved")
    }
    @Test fun 两来源队列显式选择后继续共享目标不重新标记() {
        queue += SynologyPhotoSpace.PERSONAL to 1L; queue += SynologyPhotoSpace.SHARED to 2L
        show(); ready(); menu(); form(); compose.onNodeWithTag("photos_previews_start").assertIsNotEnabled()
        compose.onNode(hasText(text(R.string.sp_source_shared)) and hasAnyAncestor(isDialog())).performClick(); form()
        item(2, SynologyPhotoSpace.SHARED).performClick(); capture("shared-queue"); start(); confirm(); settled()
        assertEquals(listOf("upload"), writes.map { it.method }); assertEquals("SYNO.FotoTeam.Upload.ConvertedFile", writes.single().api)
        assertTrue(SynologyPhotoSpace.PERSONAL to 1L in queue); assertFalse(SynologyPhotoSpace.SHARED to 2L in queue)
    }
    @Test fun 未知上传冷恢复仅回读原件版本变化和队列消失共同证明完成() {
        unknownUpload = true; queue += SynologyPhotoSpace.PERSONAL to 1L; show(); ready(); menu(); form(); item(1).performClick(); start(); confirm(); pending(); capture("upload-unknown")
        cold(); menu(); form(); compose.onNodeWithTag("photos_previews_start").assertIsNotEnabled(); compose.onNodeWithTag("photos_previews_clear").assertDoesNotExist()
        scroll("photos_previews_review").performClick(); pending(); assertEquals(1, writes.size); capture("unknown-cold")
        finish(SynologyPhotoSpace.PERSONAL, 1); refresh(); settled()
        assertEquals(1, writes.size); capture("recovered-complete")
    }
    @Test fun 两条路径明确失败还原后显示逐项未完成并允许清除记录() {
        rejectUpload = true; nasSuccess = false; queue += SynologyPhotoSpace.PERSONAL to 1L
        show(); ready(); menu(); form(); item(1).performClick(); start(); confirm(); settled()
        assertEquals(listOf("upload", "regenerate_preview_by_nas", "restore_from_regenerating"), writes.map { it.method })
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, previews.state.value.records.single().checkpoint.phase)
        scroll("photos_previews_details").performClick(); compose.onNodeWithText(text(R.string.sp_previews_item_failed)).performScrollTo().assertIsDisplayed(); capture("failed-item")
        scroll("photos_previews_clear").performClick(); compose.waitUntil(5_000) { previews.state.value.records.isEmpty() }; capture("cleared")
    }
    @Test fun 预检后权限变化零写且关闭处理页面保留最终结果() {
        png = false; queue += SynologyPhotoSpace.PERSONAL to 1L; show(); ready(); menu(); form(); item(1).performClick(); start()
        manage = false; confirm(); error(); assertTrue(writes.isEmpty()); capture("permission-changed")
        manage = true; refresh(); form(); assertTrue(previews.state.value.selected.isEmpty()); item(1).performClick(); start(); writeGate = CompletableDeferred(); confirm()
        compose.waitUntil(5_000) { previews.state.value.working && writes.isNotEmpty() }; capture("updating")
        close(); compose.runOnIdle { writeGate!!.complete(Unit); writeGate = null }; compose.waitUntil(5_000) { !previews.state.value.working }
        assertFalse(previews.state.value.visible); assertEquals(listOf("regenerate_preview_by_nas"), writes.map { it.method })
        menu(); form(); assertTrue(previews.state.value.records.single().checkpoint.finished); capture("closed-then-reopened")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album", "Browse.NormalAlbum", "Browse.Folder", "Download", "RegeneratePreview", "Upload.ConvertedFile")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(160, 120, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        originalSize = image.size.toLong()
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            val request = chain.request()
            val body = if (request.method == "POST") {
                val bytes = Buffer(); request.body!!.writeTo(bytes); val payload = bytes.readUtf8()
                val id = Regex("name=\"unit_id\"[^\\r]*\\r\\n(?:[^\\r]+\\r\\n)*\\r\\n([0-9]+)\\r\\n").find(payload)!!.groupValues[1].toLong()
                val space = if (payload.contains("SYNO.FotoTeam.Upload.ConvertedFile")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
                assertTrue(payload.contains("name=\"thumb_xl\"")); assertTrue(payload.contains("name=\"thumb_sm\"")); assertTrue(payload.contains("name=\"thumb_m\""))
                calls += Call(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam.Upload.ConvertedFile" else "SYNO.Foto.Upload.ConvertedFile", "upload", mapOf("unit_id" to id.toString()))
                if (unknownUpload) throw IOException("Synthetic lost upload")
                if (!rejectUpload) finish(space, id)
                (if (rejectUpload) "{\"success\":false,\"error\":{\"code\":100}}" else "{\"success\":true}").toResponseBody("application/json".toMediaType())
            } else image.toResponseBody("image/png".toMediaType())
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", if (request.method == "POST") "application/json" else "image/png").body(body).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic", "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (method == "list_regenerating") { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            if (method == "regenerate_preview_by_nas") writeGate?.await()
            response(call)
        }, media, previewEvents = { object : SynologyPhotoPreviewEvents {
            private var id = 0L
            override suspend fun subscribe(unitId: Long) { id = unitId }
            override suspend fun completion(): Boolean { if (nasSuccess) queue.single { it.second == id }.let { finish(it.first, id) }; return nasSuccess }
            override fun close() {}
        } })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store, editStore = editStore)
    }
    private fun response(c: Call): JsonObject {
        val space = if (c.api.startsWith("SYNO.FotoTeam")) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
        return when {
            c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
            c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"management","timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"album_list_sort_by":"create_time","album_list_sort_direction":"desc","album_display_type":"all_album"}""")
            c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$shared}""")
            c.api.endsWith("Browse.Folder") -> obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"manage":$manage,"download":true}}}}""")
            c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2020,"month":3,"day":2,"item_count":1},{"year":2020,"month":3,"day":1,"item_count":1}]}]}""")
            c.api.endsWith("Browse.Item") && c.method == "list" -> list(if (c.fields["offset"] == "0") listOf(photo(2, space), photo(1, space)) else emptyList())
            c.api.endsWith("Browse.Item") && c.method == "get" -> list(Json.parseToJsonElement(c.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long, space) })
            c.api.endsWith("Browse.Category") || c.api.endsWith("Browse.Album") -> list(emptyList())
            c.method == "list_regenerating" -> queued(space)
            c.method == "set_regenerating" -> {
                val id = Json.parseToJsonElement(c.fields.getValue("item_id")).jsonArray.single().jsonPrimitive.long
                queue += space to id; list(listOf(queueItem(id)))
            }
            c.method == "regenerate_preview_by_nas" -> obj("{}")
            c.method == "restore_from_regenerating" -> {
                queue -= space to Json.parseToJsonElement(c.fields.getValue("unit_id")).jsonArray.single().jsonPrimitive.long; obj("{}")
            }
            else -> error("Unexpected synthetic call ${c.api}.${c.method}")
        }
    }
    private fun finish(space: SynologyPhotoSpace, id: Long) { revisions[space to id] = "new"; queue -= space to id }
    private fun filename(id: Long) = "Synthetic$id.${if (png) "png" else "jpg"}"
    private fun queueItem(id: Long) = buildJsonObject { put("unit_id", id); put("filename", filename(id)); put("type", "photo") }
    private fun queued(space: SynologyPhotoSpace) = list(queue.filter { it.first == space }.sortedBy { it.second }.map { queueItem(it.second) })
    private fun photo(id: Long, space: SynologyPhotoSpace) = buildJsonObject {
        val time = Instant.parse(if (id == 2L) "2020-03-02T23:07:00Z" else "2020-03-01T12:00:00Z").epochSecond
        put("id", id); put("filename", filename(id)); put("filesize", originalSize); put("time", time); put("indexed_time", time); put("folder_id", 9); put("type", "photo")
        put("additional", obj("""{"thumbnail":{"unit_id":${id + 100},"cache_key":"${revisions[space to id] ?: "old"}"},"description":"Synthetic description"}"""))
    }
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun form() { compose.waitUntil(10_000) { !previews.state.value.loading }; assertNull(previews.state.value.error) }
    private fun menu() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithTag("photos_previews_menu").performScrollTo().performClick() }
    private fun item(id: Long, space: SynologyPhotoSpace = SynologyPhotoSpace.PERSONAL) = scroll("photos_previews_item_${space}_$id")
    private fun scroll(tag: String) = compose.onNodeWithTag(tag).performScrollTo()
    private fun refresh() { compose.onNodeWithTag("photos_previews_refresh").performClick() }
    private fun start() { compose.onNodeWithTag("photos_previews_start").performClick(); compose.waitUntil(5_000) { previews.state.value.confirmation != null } }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_previews_confirm").performClick() }
    private fun settled() { compose.waitUntil(10_000) { !previews.state.value.working && !previews.state.value.loading && previews.state.value.records.any { it.id == previews.state.value.activeId && it.checkpoint.finished } }; assertNull(previews.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !previews.state.value.working && !previews.state.value.loading && previews.state.value.records.any { !it.checkpoint.finished } }; assertNull(previews.state.value.error) }
    private fun error() { compose.waitUntil(10_000) { !previews.state.value.loading && !previews.state.value.working && previews.state.value.error != null } }
    private fun close() { compose.onAllNodes(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).onLast().performClick() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun photoReads() = calls.count { it.api.endsWith("Browse.Item") && it.method == "list" }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-previews-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
