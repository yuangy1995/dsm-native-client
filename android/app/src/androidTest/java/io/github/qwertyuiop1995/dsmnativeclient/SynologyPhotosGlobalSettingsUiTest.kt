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
import java.time.*
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.*
import org.junit.Assert.*

/** 正式图库/设置仓储、加密记录与媒体加载使用合成响应，不访问真实 NAS。 */
class SynologyPhotosGlobalSettingsUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("global-settings-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val settings get() = model.settings!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set", "clear_cache") }
    private var user = obj("""{"enable_home_service":true,"team_space_permission":"management","timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"upload_default_action":"ignore","copy_move_default_action":"skip","enable_person":true,"enable_concept":false,"enable_similar":true,"ame_status":{"has_hevc":true}}""")
    private var admin = obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":true,"enable_user_sharing":true,"display_photo_info_to_guest":false,"enable_converted_original_jpeg":true,"exclude_extension":["legacy","jpg"]}""")
    private var team = obj("""{"enabled":true,"enable_person":true,"enable_concept":false,"enable_similar":true,"allow_root_folder_public":false}""")
    private var administrator = true; private var currentUserId = 41L
    private var failRead = false; private var failCache = false; private var failureApi: String? = null; private var applyFailedWrite = false; private var denied = false
    private var cacheSize = 400L; private var cacheStatus = "idle"; private var cacheAfterClear = 0L; private var processingAfterClear = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 全局加载六项格式保留未知大小写保存联动并保持个人位置() {
        show(); ready(); val before = model.state.value; gate = CompletableDeferred()
        menu(R.string.sp_global_title); compose.waitUntil(5_000) { settings.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("options")
        SynologyPhotoGlobalSetting.entries.forEach { scrollTag("photos_global_${it.name}").assertIsEnabled() }
        scrollTag("photos_global_PEOPLE").performClick(); scrollTag("photos_global_formats").performClick()
        scrollTag("photos_global_format_legacy").assertIsSelected().performClick()
        scrollTag("photos_global_format_jpg").assertIsSelected(); scrollTag("photos_global_format_PNG").performClick(); capture("formats")
        scrollTag("photos_global_formats").performClick(); save(); capture("global-confirmation"); cancel(); assertTrue(writes.isEmpty())
        save(); confirm(); settled(); capture("saved")
        assertEquals(listOf("SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace"), writes.map { it.api })
        assertEquals(mapOf("enable_person" to "false", "exclude_extension" to "[\"PNG\",\"jpg\"]"), writes.first().fields)
        assertEquals(before.items, model.state.value.items); assertEquals(before.selectedMonth, model.state.value.selectedMonth); assertEquals(before.navigation, model.state.value.navigation)
        close(); menu(R.string.sp_global_title); form(); compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled()
        assertEquals(setOf("PNG", "jpg"), (settings.state.value.desired as SynologyPhotoGlobalSettings).excludedExtensions); capture("reopened")
    }
    @Test fun 关闭原尺寸JPEG先清缓存全局个人共享四步并更新真实下载能力() {
        show(); ready(); assertTrue(model.state.value.access!!.supportsOriginalSizeJPEG)
        menu(R.string.sp_global_title); form(); scrollTag("photos_global_PEOPLE").performClick(); scrollTag("photos_global_ORIGINAL_JPEG").performClick()
        scrollTag("photos_global_GUEST_INFO").performClick(); save()
        compose.onNodeWithText(text(R.string.sp_global_clear_risk)).performScrollTo().assertIsDisplayed(); capture("jpeg-clear-confirmation")
        confirm(); settled(); capture("jpeg-saved")
        assertEquals(listOf("SYNO.Foto.Download", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace"), writes.map { it.api })
        assertTrue(writes.first().fields.isEmpty()); assertEquals("clear_cache", writes.first().method); assertFalse(model.state.value.access!!.supportsOriginalSizeJPEG)
        close(); menu(R.string.sp_global_title); form(); scrollTag("photos_global_ORIGINAL_JPEG").assertIsOff(); capture("jpeg-disabled")
    }
    @Test fun 单独清缓存取消零写确认允许新缓存并展示真实大小() {
        cacheAfterClear = 80; show(); ready(); val before = model.state.value
        menu(R.string.sp_global_title); form(); scrollTag("photos_cache_clear").performClick()
        compose.onNodeWithText(text(R.string.sp_global_clear_risk)).assertIsDisplayed(); capture("cache-confirmation"); cancel(); assertTrue(writes.isEmpty())
        scrollTag("photos_cache_clear").performClick(); confirm(); settled(); capture("cache-completed")
        assertEquals("SYNO.Foto.Download", writes.single().api); assertTrue(writes.single().fields.isEmpty()); assertEquals(80L, cacheSize)
        assertEquals(before.items, model.state.value.items); close(); menu(R.string.sp_global_title); form(); scrollTag("photos_cache_size").assertIsDisplayed(); capture("new-cache-size")
    }
    @Test fun 清理中和丢回执冷恢复只读不能重复发送() {
        processingAfterClear = true; show(); ready(); menu(R.string.sp_global_title); form(); scrollTag("photos_cache_clear").performClick(); confirm(); pending(); capture("cache-processing-record")
        close(); menu(R.string.sp_global_title); form(); scrollTag("photos_cache_clear").assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.sp_global_clearing)).performScrollTo().assertIsDisplayed(); capture("cache-processing")
        cacheStatus = "idle"; cacheSize = 120; scrollTag("photos_cache_refresh").performClick(); form(); close(); menu(R.string.sp_settings_records); records()
        compose.onNodeWithTag("photos_settings_resume").performClick(); settled(); assertEquals(1, writes.size)
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performClick(); compose.waitUntil(5_000) { settings.state.value.records.isEmpty() }; close()
        processingAfterClear = false; failureApi = "SYNO.Foto.Download"; menu(R.string.sp_global_title); form(); scrollTag("photos_cache_clear").performClick(); confirm(); pending(); capture("cache-unknown")
        close(); cold(); menu(R.string.sp_settings_records); records(); compose.onNodeWithTag("photos_settings_resume").performClick(); pending(); assertEquals(2, writes.size); capture("cache-cold-pending")
        cacheSize = 0; compose.onNodeWithTag("photos_settings_resume").performClick(); settled(); capture("cache-cold-completed"); assertEquals(2, writes.size)
    }
    @Test fun 部分保存显示真实结果重新打开只保存剩余差异() {
        failureApi = "SYNO.Foto.Setting.User"; denied = true; show(); ready(); menu(R.string.sp_global_title); form()
        scrollTag("photos_global_PEOPLE").performClick(); save(); confirm(); settled()
        compose.onNodeWithText(text(R.string.sp_global_partial)).assertIsDisplayed(); capture("partial")
        assertEquals(2, writes.size); assertEquals(setOf(SynologyPhotoGlobalStep.ADMIN), settings.state.value.records.single().checkpoint.settings!!.globalProgress!!.completed)
        close(); failureApi = null; denied = false; menu(R.string.sp_global_title); form(); scrollTag("photos_global_PEOPLE").assertIsOff()
        compose.onNodeWithTag("photos_settings_save").assertIsEnabled(); capture("remaining-differences"); save(); confirm(); settled(); capture("remaining-saved")
        assertEquals(listOf("SYNO.Foto.Setting.User", "SYNO.Foto.Setting.TeamSpace"), writes.takeLast(2).map { it.api }); assertEquals(4, writes.size)
    }
    @Test fun 未知首步冷恢复不补发且关闭当前共享分类返回相册() {
        failureApi = "SYNO.Foto.Setting.Admin"; show(); ready(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready(); compose.onNodeWithText(text(R.string.sp_category_person)).performClick(); ready()
        menu(R.string.sp_global_title); form(); scrollTag("photos_global_PEOPLE").performClick(); save(); confirm(); pending(); capture("unknown-global")
        close(); cold(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready(); compose.onNodeWithText(text(R.string.sp_category_person)).performClick(); ready()
        menu(R.string.sp_settings_records); records(); compose.onNodeWithTag("photos_settings_resume").performClick(); pending(); assertEquals(1, writes.size)
        admin = JsonObject(admin + ("enable_person" to JsonPrimitive(false))); compose.onNodeWithTag("photos_settings_resume").performClick(); settled(); capture("unknown-partial")
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, settings.state.value.records.single().checkpoint.phase); close(); ready(); assertNull(model.state.value.navigation.category)
        compose.onNodeWithText(text(R.string.sp_category_person)).assertDoesNotExist(); capture("shared-category-removed"); assertEquals(1, writes.size)
    }
    @Test fun 五态读取重试缓存错误独立缺HEVC只读未知字段不猜选项() {
        show(); ready(); menu(R.string.sp_settings_records); compose.onNodeWithText(text(R.string.sp_settings_no_records)).assertIsDisplayed(); capture("records-empty"); close()
        failRead = true; menu(R.string.sp_global_title); compose.waitUntil(5_000) { !settings.state.value.loading && settings.state.value.error != null }; capture("read-failed")
        failRead = false; failCache = true; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form()
        compose.onNodeWithText(text(R.string.sp_global_cache_failed)).performScrollTo().assertIsDisplayed(); capture("cache-failed")
        scrollTag("photos_global_USER_SHARING").performClick(); save(); confirm(); settled(); assertEquals(1, writes.size); close()
        failCache = false; field("ame_status", obj("""{"has_hevc":false}""")); menu(R.string.sp_global_title); form()
        scrollTag("photos_global_ORIGINAL_JPEG").assertIsNotEnabled(); compose.onNodeWithText(text(R.string.sp_global_codec_required)).performScrollTo().assertIsDisplayed(); capture("codec-required"); close()
        admin = obj("""{"package_version":"synthetic"}"""); menu(R.string.sp_global_title); form()
        compose.onNodeWithText(text(R.string.sp_global_empty)).assertIsDisplayed(); compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled(); capture("unknown-options")
    }
    @Test fun 管理员入口及保存前撤权身份和完整原值变化均拒绝写入() {
        administrator = false; show(); ready(); compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithText(text(R.string.sp_global_title)).assertDoesNotExist(); capture("nonadministrator-menu")
        compose.onNodeWithText(text(R.string.sp_settings_display)).performScrollTo().performClick(); form(); close()
        administrator = true; cold(); menu(R.string.sp_global_title); form(); scrollTag("photos_global_USER_SHARING").performClick(); save(); administrator = false; confirm()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }; capture("administrator-revoked"); assertTrue(writes.isEmpty()); close()
        administrator = true; menu(R.string.sp_global_title); form(); scrollTag("photos_global_USER_SHARING").performClick(); save(); currentUserId = 42; confirm()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }; capture("identity-changed"); assertTrue(writes.isEmpty()); close()
        currentUserId = 41; menu(R.string.sp_global_title); form(); scrollTag("photos_global_USER_SHARING").performClick(); save()
        team = JsonObject(team + ("enable_concept" to JsonPrimitive(true))); confirm()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_settings_changed)).assertIsDisplayed(); capture("concurrent-change"); assertTrue(writes.isEmpty())
    }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_settings_confirm").performClick() }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Download", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val image = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888); bitmap.eraseColor(android.graphics.Color.rgb(80, 140, 190))
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle(); output.toByteArray()
        }
        val profile = NasProfile(owner.profileId, "Synthetic", "https://example.invalid", "tester")
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val repo = SynologyPhotosRepository(profile.id, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (call.api.endsWith("Setting.TeamSpace") && method == "get") { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$currentUserId,"is_admin":$administrator}""")
        c.api == "SYNO.Foto.Setting.User" && c.method == "get" -> user
        c.method in setOf("set", "clear_cache") -> {
            val failing = c.api == failureApi
            if (failing && denied) throw DsmFailure(105, "Synthetic denied", "Synthetic recovery")
            if (!failing || applyFailedWrite) when (c.api) {
                "SYNO.Foto.Setting.Admin" -> admin = JsonObject(admin + c.fields.mapValues { Json.parseToJsonElement(it.value) })
                "SYNO.Foto.Setting.User" -> user = JsonObject(user + c.fields.mapValues { Json.parseToJsonElement(it.value) })
                "SYNO.Foto.Setting.TeamSpace" -> team = JsonObject(team + c.fields.mapValues { Json.parseToJsonElement(it.value) })
                "SYNO.Foto.Download" -> { cacheSize = cacheAfterClear; cacheStatus = if (processingAfterClear) "processing" else "idle" }
                else -> error("Unexpected synthetic write")
            }
            if (failing) throw IOException("Synthetic missing receipt")
            obj("{}")
        }
        c.method == "get_cache_status" -> { if (failCache) throw IOException("Synthetic cache"); obj("""{"status":"$cacheStatus"}""") }
        c.method == "calculate_cache_size" -> obj("""{"cache_size":$cacheSize}""")
        c.api.endsWith("Setting.Admin") -> admin
        c.api.endsWith("Setting.TeamSpace") && c.method == "get" -> team
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2020,"month":3,"day":2,"item_count":1},{"year":2020,"month":3,"day":1,"item_count":1}]}]}""")
        c.api.endsWith("Browse.Item") && c.method == "list" -> list(if (c.fields["offset"] == "0") listOf(photo(2), photo(1)) else emptyList())
        c.api.endsWith("Browse.Item") && c.method == "get" -> list(Json.parseToJsonElement(c.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long) })
        c.method == "get_album_list_order" -> obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc"}""")
        c.method == "get_album_list_display" -> obj("""{"album_display_type":"all_album"}""")
        c.api.endsWith("Browse.Category") -> obj("""{"list":[{"id":"person"},{"id":"concept"},{"id":"video"}]}""")
        c.api.endsWith("Browse.Person") || c.api.endsWith("Browse.Concept") || c.api.endsWith("Browse.Album") -> list(emptyList())
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun photo(id: Long) = buildJsonObject {
        val time = Instant.parse(if (id == 2L) "2020-03-02T23:07:00Z" else "2020-03-01T12:00:00Z").epochSecond
        put("id", id); put("filename", "Synthetic$id.jpg"); put("filesize", 4); put("time", time); put("indexed_time", time); put("folder_id", 9); put("type", "photo")
        put("additional", obj("""{"thumbnail":{"unit_id":$id,"cache_key":"synthetic"},"description":"Synthetic description","address":{"country":"Synthetic country","state":"Synthetic state","county":"Synthetic county","city":"Synthetic city"}}"""))
    }
    private fun field(key: String, value: JsonElement?) { user = JsonObject(if (value == null) user - key else user + (key to value)) }
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun form() { compose.waitUntil(10_000) { !settings.state.value.loading && !settings.state.value.cacheLoading && settings.state.value.desired != null }; assertNull(settings.state.value.error) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); chooseText(text(id)) }
    private fun chooseText(value: String) { compose.onNode(hasText(value) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun scrollTag(tag: String): SemanticsNodeInteraction = compose.onNodeWithTag(tag).performScrollTo()
    private fun save() { compose.onNodeWithTag("photos_settings_save").assertIsEnabled().performClick() }
    private fun records() { compose.waitUntil(10_000) { settings.state.value.records.isNotEmpty() } }
    private fun settled() { compose.waitUntil(10_000) { !settings.state.value.working && settings.state.value.records.any { it.id == settings.state.value.activeId && it.checkpoint.finished } }; assertNull(settings.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !settings.state.value.working && settings.state.value.records.any { !it.checkpoint.finished } }; assertNull(settings.state.value.error) }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-global-settings-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
