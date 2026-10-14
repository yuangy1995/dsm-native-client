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
class SynologyPhotosSettingsUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("settings-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val settings get() = model.settings!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method == "set" }
    private var user = obj("""{"enable_home_service":true,"team_space_permission":"management","timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"upload_default_action":"ignore","copy_move_default_action":"skip","enable_person":true,"enable_concept":false,"enable_similar":true}""")
    private var admin = obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":false}""")
    private var failRead = false; private var apply = true; private var unknown = false; private var denied = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 显示六项加载修改直接保存图库月份不变重开读取已保存值() {
        show(); ready(); val before = model.state.value; gate = CompletableDeferred()
        menu(R.string.sp_settings_display); compose.waitUntil(5_000) { settings.state.value.loading }; capture("display-loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("display-original")
        select("photos_settings_grouping", R.string.sp_settings_group_month)
        scrollTag("photos_settings_date").performClick(); chooseText("31.12.2019")
        select("photos_settings_clock", R.string.sp_settings_clock_12)
        select("photos_settings_sort_field", R.string.sp_folder_sort_name)
        select("photos_settings_sort_direction", R.string.sp_folder_sort_descending)
        scrollTag("photos_settings_show_info").performClick(); capture("display-updated")
        save(); settled(); assertNull(settings.state.value.confirmation); capture("display-saved")
        assertEquals(6, writes.single().fields.size); assertEquals(before.items, model.state.value.items)
        assertEquals(before.selectedMonth, model.state.value.selectedMonth); assertEquals(before.navigation, model.state.value.navigation)
        assertEquals(1, model.state.value.groups.size)
        close(); capture("timeline-month-group"); menu(R.string.sp_settings_display); form()
        assertEquals(SynologyPhotoDisplaySettings.Grouping.MONTH, (settings.state.value.desired as SynologyPhotoDisplaySettings).grouping)
        compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled(); capture("display-reopened")
    }
    @Test fun 预览信息使用已选格式前三项地址和描述打开详情互斥关闭开关立即生效() {
        field("date_format", JsonPrimitive("dd.mm.yyyy")); field("time_format", JsonPrimitive("12")); show(); ready(); preview()
        compose.onNodeWithTag("photos_preview_information").assertIsDisplayed()
        compose.onNodeWithText("Synthetic description").assertIsDisplayed()
        compose.onNodeWithText("Synthetic country, Synthetic state, Synthetic county").assertIsDisplayed()
        val format = SynologyPhotoDisplayFormat.timestamp(model.state.value.access!!.displaySettings, context.resources.configuration.locales[0])
        compose.onNodeWithText(format.format(Instant.parse("2020-03-02T23:07:00Z"))).assertIsDisplayed(); capture("preview-information")
        compose.onNodeWithContentDescription(text(R.string.sp_media_info)).performClick()
        compose.onNodeWithTag("photos_preview_information").assertDoesNotExist(); capture("preview-details")
        compose.runOnIdle { model.preview.closePreview() }; ready()
        menu(R.string.sp_settings_display); form(); scrollTag("photos_settings_show_info").performClick(); save(); settled(); close(); preview()
        compose.onNodeWithTag("photos_preview_information").assertDoesNotExist(); capture("preview-information-off")
        assertEquals(mapOf("show_item_info_in_lightbox" to "false"), writes.single().fields)
    }
    @Test fun 重复文件覆盖默认取消不保存再次确认后仅写所选策略() {
        show(); ready(); menu(R.string.sp_settings_duplicates); form(); capture("duplicates-original")
        select("photos_settings_upload", R.string.sp_upload_keep_both); select("photos_settings_transfer", R.string.sp_files_replace)
        save(); compose.onNodeWithTag("photos_settings_confirm").assertIsDisplayed(); capture("overwrite-confirmation")
        compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick(); assertTrue(writes.isEmpty())
        save(); compose.onNodeWithTag("photos_settings_confirm").performClick(); settled(); capture("duplicates-saved")
        assertEquals(mapOf("upload_default_action" to "\"rename\"", "copy_move_default_action" to "\"overwrite\""), writes.single().fields)
        close(); cold(); menu(R.string.sp_settings_duplicates); form(); assertEquals(SynologyPhotoTransferDuplicate.OVERWRITE, (settings.state.value.desired as SynologyPhotoDuplicateSettings).transfer)
        select("photos_settings_transfer", R.string.sp_files_skip); save(); settled(); assertNull(settings.state.value.confirmation); assertEquals(2, writes.size)
    }
    @Test fun 识别已知限制清晰可见个人关闭和缺字段分别展示恢复说明() {
        show(); ready(); menu(R.string.sp_settings_recognition); form(); capture("recognition-options")
        scrollTag("photos_settings_recognition_SIMILAR").assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.sp_settings_admin_disabled)).assertIsDisplayed()
        scrollTag("photos_settings_recognition_SUBJECTS").performClick(); save(); settled(); assertEquals(mapOf("enable_concept" to "true"), writes.single().fields)
        close(); field("enable_home_service", JsonPrimitive(false)); cold(); menu(R.string.sp_settings_recognition); form()
        compose.onNodeWithText(text(R.string.sp_settings_home_disabled)).assertIsDisplayed(); scrollTag("photos_settings_recognition_PEOPLE").assertIsNotEnabled(); capture("recognition-home-disabled")
        close(); SynologyPhotoRecognition.entries.forEach { field(it.field, null) }; menu(R.string.sp_settings_recognition); form()
        compose.onNodeWithText(text(R.string.sp_settings_recognition_empty)).performScrollTo().assertIsDisplayed(); capture("recognition-unknown")
        compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled(); assertEquals(1, writes.size)
    }
    @Test fun 关闭正在浏览的个人分类返回相册入口共享分类仍可浏览() {
        show(); ready(); compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready()
        compose.onNodeWithText(text(R.string.sp_category_person)).performClick(); ready()
        assertEquals(SynologyPhotoCategory.PEOPLE, model.state.value.navigation.category)
        menu(R.string.sp_settings_recognition); form(); scrollTag("photos_settings_recognition_PEOPLE").performClick(); save(); settled(); close(); ready()
        assertNull(model.state.value.navigation.category); compose.onNodeWithText(text(R.string.sp_category_person)).assertDoesNotExist(); capture("personal-category-removed")
        compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        compose.onNodeWithText(text(R.string.sp_category_person)).assertIsDisplayed(); compose.onNodeWithText(text(R.string.sp_category_person)).performClick(); ready(); capture("shared-category-preserved")
        assertEquals(SynologyPhotoCategory.PEOPLE, model.state.value.navigation.category); assertEquals(1, writes.size)
    }
    @Test fun 未知保存冷启动刷新只读实际匹配后完成没有重复写入() {
        apply = false; unknown = true; show(); ready(); menu(R.string.sp_settings_display); form()
        scrollTag("photos_settings_show_info").performClick(); save(); pending(); capture("save-unknown"); assertEquals(1, writes.size)
        close(); cold(); menu(R.string.sp_settings_records); records(); capture("cold-pending")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
        compose.onNodeWithTag("photos_settings_resume").performClick(); pending(); assertEquals(1, writes.size)
        field("show_item_info_in_lightbox", JsonPrimitive(false)); compose.onNodeWithTag("photos_settings_resume").performClick(); settled(); capture("cold-completed")
        assertFalse(model.state.value.access!!.displaySettings!!.showInfo); assertEquals(1, writes.size)
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performClick(); compose.waitUntil(5_000) { settings.state.value.records.isEmpty() }
    }
    @Test fun 空记录读取失败重试并发变化和明确拒绝均有恢复路径() {
        show(); ready(); menu(R.string.sp_settings_records); compose.onNodeWithText(text(R.string.sp_settings_no_records)).assertIsDisplayed(); capture("records-empty"); close()
        failRead = true; menu(R.string.sp_settings_display); compose.waitUntil(5_000) { !settings.state.value.loading && settings.state.value.error != null }; capture("display-read-error")
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form()
        scrollTag("photos_settings_show_info").performClick(); field("time_format", JsonPrimitive("12")); save()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_settings_changed)).assertIsDisplayed(); capture("settings-concurrent-change"); assertTrue(writes.isEmpty())
        close(); menu(R.string.sp_settings_display); form(); scrollTag("photos_settings_show_info").performClick(); denied = true; save(); settled()
        compose.onNodeWithText(text(R.string.sp_settings_rejected)).assertIsDisplayed(); capture("settings-rejected"); assertEquals(1, writes.size)
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album")
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
            if (call.api.endsWith("Setting.User") && method == "get") { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api == "SYNO.Foto.Setting.User" && c.method == "get" -> user
        c.api == "SYNO.Foto.Setting.User" && c.method == "set" -> {
            if (denied) throw DsmFailure(105, "Synthetic denied", "Synthetic recovery")
            if (apply) user = JsonObject(user + c.fields.mapValues { Json.parseToJsonElement(it.value) })
            if (unknown) throw IOException("Synthetic missing receipt")
            obj("{}")
        }
        c.api.endsWith("Setting.Admin") -> admin
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true,"enable_person":true,"enable_concept":true}""")
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
    private fun form() { compose.waitUntil(10_000) { !settings.state.value.loading && settings.state.value.desired != null }; assertNull(settings.state.value.error) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); chooseText(text(id)) }
    private fun chooseText(value: String) { compose.onNode(hasText(value) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun scrollTag(tag: String): SemanticsNodeInteraction = compose.onNodeWithTag(tag).performScrollTo()
    private fun select(tag: String, id: Int) { scrollTag(tag).performClick(); chooseText(text(id)) }
    private fun save() { compose.onNodeWithTag("photos_settings_save").assertIsEnabled().performClick() }
    private fun records() { compose.waitUntil(10_000) { settings.state.value.records.isNotEmpty() } }
    private fun settled() { compose.waitUntil(10_000) { !settings.state.value.working && settings.state.value.records.any { it.id == settings.state.value.activeId && it.checkpoint.finished } }; assertNull(settings.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !settings.state.value.working && settings.state.value.records.any { !it.checkpoint.finished } }; assertNull(settings.state.value.error) }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun preview() {
        compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "Synthetic2.jpg")).performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo != null && !model.preview.state.value.loading }; assertNull(model.preview.state.value.error)
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-settings-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
