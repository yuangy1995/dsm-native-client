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
class SynologyPhotosSharedSettingsUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("shared-settings-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val settings get() = model.settings!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set", "set_enable") }
    private var user = obj("""{"enable_home_service":true,"team_space_permission":"management","timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"upload_default_action":"ignore","copy_move_default_action":"skip","enable_person":true,"enable_concept":false,"enable_similar":true}""")
    private var admin = obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":false}""")
    private var team = obj("""{"enabled":true,"enable_person":true,"enable_concept":false,"enable_similar":true,"allow_root_folder_public":false}""")
    private var administrator = true; private var currentUserId = 41L
    private var failRead = false; private var apply = true; private var unknown = false; private var denied = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 共享选项加载只读已知全局限制普通修改直接保存() {
        show(); ready(); gate = CompletableDeferred()
        menu(R.string.sp_shared_settings_title); compose.waitUntil(5_000) { settings.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("options")
        scrollTag("photos_shared_SIMILAR").assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.sp_shared_settings_global_disabled)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(text(R.string.sp_settings_admin_disabled)).assertDoesNotExist()
        scrollTag("photos_shared_PEOPLE").performClick(); scrollTag("photos_shared_SUBJECTS").performClick(); capture("changed")
        save(); settled(); assertNull(settings.state.value.confirmation); capture("saved")
        assertEquals(mapOf("enable_person" to "false", "enable_concept" to "true"), writes.single().fields)
        assertEquals("SYNO.Foto.Setting.TeamSpace", writes.single().api)
        close(); menu(R.string.sp_shared_settings_title); form(); compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled()
        assertEquals(false, (settings.state.value.desired as SynologyPhotoSharedSettings).values[SynologyPhotoSharedSetting.PEOPLE]); capture("reopened")
    }
    @Test fun 顶层公开权限说明后果取消零写确认仅保存差量() {
        show(); ready(); menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_PUBLIC_ROOT").performClick(); save()
        compose.onNodeWithText(text(R.string.sp_shared_settings_public_risk)).assertIsDisplayed(); capture("public-confirmation")
        cancel(); assertTrue(writes.isEmpty()); save(); confirm(); settled(); capture("public-saved")
        assertEquals(mapOf("allow_root_folder_public" to "true"), writes.single().fields)
        close(); menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_PUBLIC_ROOT").performClick(); save()
        compose.onNodeWithText(text(R.string.sp_shared_settings_private_risk)).assertIsDisplayed(); capture("private-confirmation")
        confirm(); settled(); assertEquals(2, writes.size)
    }
    @Test fun 停用与启用单独确认个人位置保持真实默认值重新读取() {
        show(); ready(); val before = model.state.value
        menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_toggle").performClick()
        compose.onNodeWithText(text(R.string.sp_shared_settings_disable_risk)).assertIsDisplayed(); capture("disable-confirmation")
        cancel(); assertTrue(writes.isEmpty()); scrollTag("photos_shared_toggle").performClick(); confirm(); settled(); capture("disabled-record")
        assertEquals(before.items, model.state.value.items); assertEquals(before.navigation, model.state.value.navigation); assertEquals(before.selectedMonth, model.state.value.selectedMonth)
        assertEquals(mapOf("enabled" to "false"), writes.single().fields); assertEquals("set_enable", writes.single().method)
        close(); menu(R.string.sp_shared_settings_title); form(); compose.onNodeWithText(text(R.string.sp_shared_settings_off)).assertIsDisplayed(); capture("disabled")
        scrollTag("photos_shared_toggle").performClick(); compose.onNodeWithText(text(R.string.sp_shared_settings_enable_risk)).assertIsDisplayed(); capture("enable-confirmation")
        confirm(); settled(); compose.waitUntil(5_000) { SynologyPhotoSpace.SHARED in model.state.value.access!!.spaces }
        close(); menu(R.string.sp_shared_settings_title); form()
        assertEquals(false, (settings.state.value.desired as SynologyPhotoSharedSettings).values[SynologyPhotoSharedSetting.PEOPLE]); capture("enabled-defaults")
        assertEquals(2, writes.size); assertTrue(writes.all { it.fields.keys == setOf("enabled") })
    }
    @Test fun 最后图库禁止停用共享文件夹关闭提供恢复说明仍可尝试启用() {
        field("enable_home_service", JsonPrimitive(false)); show(); ready(); menu(R.string.sp_shared_settings_title); form()
        scrollTag("photos_shared_toggle").assertIsNotEnabled(); compose.onNodeWithText(text(R.string.sp_shared_settings_last)).performScrollTo().assertIsDisplayed(); capture("last-library")
        close(); field("enable_home_service", JsonPrimitive(true)); team = JsonObject(team + mapOf("enabled" to JsonPrimitive(false), "team_space_disabled_by_share_folder_disabled" to JsonPrimitive(true)))
        cold(); menu(R.string.sp_shared_settings_title); form(); compose.onNodeWithText(text(R.string.sp_shared_settings_folder_disabled)).performScrollTo().assertIsDisplayed(); capture("folder-disabled")
        scrollTag("photos_shared_toggle").assertIsEnabled().performClick(); confirm(); settled(); assertEquals(1, writes.size)
        close(); team = obj("""{"enabled":true}"""); menu(R.string.sp_shared_settings_title); form()
        compose.onNodeWithText(text(R.string.sp_shared_settings_empty)).performScrollTo().assertIsDisplayed(); compose.onNodeWithTag("photos_settings_save").assertIsNotEnabled(); capture("unknown-options")
    }
    @Test fun 未知启停冷恢复只读取实际完成后离开旧来源() {
        apply = false; unknown = true; show(); ready(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_toggle").performClick(); confirm(); pending(); capture("unknown-save")
        close(); cold(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready(); menu(R.string.sp_settings_records); records(); capture("cold-pending")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist(); compose.onNodeWithTag("photos_settings_resume").performClick(); pending(); assertEquals(1, writes.size)
        team = JsonObject(team + ("enabled" to JsonPrimitive(false))); compose.onNodeWithTag("photos_settings_resume").performClick(); settled()
        compose.waitUntil(5_000) { model.state.value.navigation.space == SynologyPhotoSpace.PERSONAL && !model.state.value.loading }; capture("cold-completed")
        assertEquals(1, writes.size); compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performClick(); compose.waitUntil(5_000) { settings.state.value.records.isEmpty() }
        close(); capture("personal-after-disabled")
    }
    @Test fun 读取失败并发变化明确拒绝与空记录均可恢复() {
        show(); ready(); menu(R.string.sp_settings_records); compose.onNodeWithText(text(R.string.sp_settings_no_records)).assertIsDisplayed(); capture("records-empty"); close()
        failRead = true; menu(R.string.sp_shared_settings_title); compose.waitUntil(5_000) { !settings.state.value.loading && settings.state.value.error != null }; capture("read-failed")
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form(); scrollTag("photos_shared_PEOPLE").performClick()
        team = JsonObject(team + ("enable_concept" to JsonPrimitive(true))); save(); compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_settings_changed)).assertIsDisplayed(); capture("concurrent-change"); assertTrue(writes.isEmpty())
        close(); menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_PEOPLE").performClick(); denied = true; save(); settled()
        compose.onNodeWithText(text(R.string.sp_settings_rejected)).assertIsDisplayed(); capture("rejected"); assertEquals(1, writes.size)
    }
    @Test fun 共享管理角色不替代管理员保存前撤权和换用户不写入() {
        administrator = false; show(); ready(); compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithText(text(R.string.sp_shared_settings_title)).assertDoesNotExist(); capture("nonadministrator-menu")
        compose.onNodeWithText(text(R.string.sp_settings_display)).performScrollTo().performClick(); form(); close()
        administrator = true; cold(); menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_PEOPLE").performClick(); administrator = false; save()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_settings_permission)).assertIsDisplayed(); capture("administrator-revoked"); assertTrue(writes.isEmpty())
        close(); administrator = true; menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_PEOPLE").performClick(); currentUserId = 42; save()
        compose.waitUntil(5_000) { !settings.state.value.working && settings.state.value.error != null }; assertTrue(writes.isEmpty()); capture("identity-changed")
    }
    @Test fun 关闭共享当前分类回相册入口停用共享来源切回个人() {
        show(); ready(); compose.runOnIdle { model.selectSpace(SynologyPhotoSpace.SHARED) }; ready()
        compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready(); compose.onNodeWithText(text(R.string.sp_category_person)).performClick(); ready()
        menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_PEOPLE").performClick(); save(); settled(); close(); ready()
        assertNull(model.state.value.navigation.category); compose.onNodeWithText(text(R.string.sp_category_person)).assertDoesNotExist(); capture("category-removed")
        menu(R.string.sp_shared_settings_title); form(); scrollTag("photos_shared_toggle").performClick(); confirm(); settled()
        compose.waitUntil(5_000) { model.state.value.navigation.space == SynologyPhotoSpace.PERSONAL && !model.state.value.loading }; close(); capture("source-closed")
        assertEquals(2, writes.size)
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
            if (call.api.endsWith("Setting.TeamSpace") && method == "get") { gate?.await(); if (failRead) throw IOException("Synthetic read") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$currentUserId,"is_admin":$administrator}""")
        c.api == "SYNO.Foto.Setting.User" && c.method == "get" -> user
        c.api == "SYNO.Foto.Setting.TeamSpace" && c.method in setOf("set", "set_enable") -> {
            if (denied) throw DsmFailure(105, "Synthetic denied", "Synthetic recovery")
            if (apply) {
                team = JsonObject(team + c.fields.mapValues { Json.parseToJsonElement(it.value) })
                if (c.method == "set_enable") team = JsonObject(team + ("enable_person" to JsonPrimitive(false)))
            }
            if (unknown) throw IOException("Synthetic missing receipt")
            obj("{}")
        }
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
    private fun form() { compose.waitUntil(10_000) { !settings.state.value.loading && settings.state.value.desired != null }; assertNull(settings.state.value.error) }
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
        val file = File(context.getExternalFilesDir(null), "workspace-photos-shared-settings-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
