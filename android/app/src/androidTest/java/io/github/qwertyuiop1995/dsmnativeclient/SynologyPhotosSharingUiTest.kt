package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Activity
import android.app.Instrumentation
import android.content.ClipboardManager
import android.content.Intent
import android.content.IntentFilter
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
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.ui.photos.SynologyPhotosLibrary
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*

/** 真 Compose 页面、仓储和加密恢复；接口内容均为合成数据。 */
class SynologyPhotosSharingUiTest {
    @get:Rule val compose = createComposeRule()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("photos-sharing-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private var epoch by mutableIntStateOf(0)
    private val albums get() = model.albums!!
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields[key]?.let(Json::parseToJsonElement)
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set_shared", "update") }
    private var shared = true; private var conditional = false; private var frozen = false
    private var info = obj("""{"privacy_type":"private","sharing_link":"https://example.invalid/synthetic-album","passphrase":"synthetic-only","enable_password":false,"expiration":0,"permission":[{"type":"user","id":51,"name":"Synthetic existing","role":"download"},{"type":"group","id":"51","name":"Synthetic legacy","role":"future-role"}]}""")
    private var failRead = false; private var failCandidates = false; private var updateUnknown = false; private var enableUnknown = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }
    @Test fun 只读加载共享设置可复制并调用系统分享() {
        show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady()
        gate = CompletableDeferred(); manageSharing(); compose.waitUntil(5_000) { albums.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; accessReady(); capture("sharing-current")
        assertTrue(writes.isEmpty())
        scrollTag("photos_sharing_copy").performClick()
        compose.runOnIdle { assertEquals("https://example.invalid/synthetic-album", context.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString()) }
        capture("copy-and-share")
        val monitor = Instrumentation.ActivityMonitor(IntentFilter(Intent.ACTION_CHOOSER), Instrumentation.ActivityResult(Activity.RESULT_CANCELED, null), true)
        instrumentation.addMonitor(monitor)
        try { scrollTag("photos_sharing_send").performClick(); compose.waitForIdle(); assertEquals(1, monitor.hits) }
        finally { instrumentation.removeMonitor(monitor) }
        assertTrue(writes.isEmpty())
    }
    @Test fun 范围成员权限密码和日期确认后依序写入() {
        show(); ready(); startSharing()
        choose("photos_sharing_access", R.string.sp_sharing_view); scrollText(R.string.sp_sharing_public_view_note); capture("public-scope")
        scrollTag("photos_sharing_add_member").performClick(); compose.waitUntil(10_000) { albums.sharing.state.value.candidates != null }
        capture("member-candidates")
        compose.onNodeWithTag("photos_sharing_search").performTextReplacement("missing")
        compose.onNodeWithText(text(R.string.sp_sharing_no_search_results)).assertIsDisplayed(); capture("members-search-empty")
        compose.onNodeWithTag("photos_sharing_search").performTextReplacement("Synthetic new")
        compose.onNode(hasText("Synthetic new") and !hasSetTextAction()).performClick()
        compose.onNodeWithText(text(R.string.sp_sharing_back)).performClick()
        choose("photos_sharing_role_user_52", R.string.sp_sharing_role_upload)
        choose("photos_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_sharing_password").performTextReplacement("  synthetic 密码  ")
        compose.onNodeWithTag("photos_sharing_password").performImeAction(); capture("password-form")
        choose("photos_sharing_expiration", R.string.sp_sharing_choose_date)
        onView(withId(android.R.id.button1)).perform(click()); capture("expiry-date")
        save(); settled(); capture("sharing-completed")
        assertEquals(listOf("set_shared", "update", "set_shared"), writes.map { it.method })
        val update = writes[1]; assertEquals("  synthetic 密码  ", update.value("password")!!.jsonPrimitive.content)
        assertTrue(update.value("expiration")!!.jsonPrimitive.long > 0)
        assertTrue(info.getValue("permission").jsonArray.any { it.jsonObject["role"] == JsonPrimitive("future-role") })
        assertTrue(info.getValue("permission").jsonArray.any { it.jsonObject["id"] == JsonPrimitive(52) && it.jsonObject["role"] == JsonPrimitive("upload") })
        compose.onNode(hasText(text(R.string.sp_sharing_title)) and hasClickAction()).performClick(); accessReady()
        assertEquals("", albums.sharing.state.value.password)
        scrollTag("photos_sharing_copy").assertIsDisplayed(); capture("saved-link")
    }
    @Test fun 条件相册保留未知权限并可停止分享清除密码期限() {
        conditional = true; info = JsonObject(info + mapOf("enable_password" to JsonPrimitive(true), "expiration" to JsonPrimitive(1700000000)))
        show(); ready(); startSharing()
        scrollTag("photos_sharing_role_user_51").performClick()
        compose.onNodeWithText(text(R.string.sp_sharing_role_upload)).assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_sharing_role_view)).performClick()
        scrollText(R.string.sp_sharing_role_existing); capture("conditional-existing-role")
        choose("photos_sharing_access", R.string.sp_sharing_disabled)
        choose("photos_sharing_password_mode", R.string.sp_sharing_remove_password)
        choose("photos_sharing_expiration", R.string.sp_sharing_no_expiration)
        save(); settled(); assertFalse(shared); assertEquals(false, info.getValue("enable_password").jsonPrimitive.boolean)
        assertEquals(0L, info.getValue("expiration").jsonPrimitive.long)
        assertEquals(listOf("set_shared", "update"), writes.map { it.method }); capture("sharing-stopped")
    }
    @Test fun 读取和候选失败可重试密码关闭清空且空成员可添加() {
        info = JsonObject(info + ("permission" to JsonArray(emptyList())))
        show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady(); failRead = true; manageSharing()
        compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.error != null }
        capture("read-error"); failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); accessReady()
        scrollText(R.string.sp_sharing_no_members); capture("members-empty")
        failCandidates = true; scrollTag("photos_sharing_add_member").performClick()
        compose.waitUntil(10_000) { albums.sharing.state.value.error != null && !albums.sharing.state.value.loading }
        capture("candidates-error"); failCandidates = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick()
        compose.waitUntil(10_000) { albums.sharing.state.value.candidates != null }
        compose.onNodeWithText(text(R.string.sp_sharing_back)).performClick()
        choose("photos_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_sharing_password").performTextReplacement("synthetic-secret")
        compose.onNodeWithTag("photos_sharing_password").performImeAction(); closeDialog()
        assertEquals("", albums.sharing.state.value.password); assertTrue(writes.isEmpty())
    }
    @Test fun 改密回执丢失保持关闭并明确部分修改未完成() {
        info = JsonObject(info + ("enable_password" to JsonPrimitive(true))); updateUnknown = true
        show(); ready(); startSharing(); choose("photos_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_sharing_password").performTextReplacement("synthetic-new")
        compose.onNodeWithTag("photos_sharing_password").performImeAction(); save(); settled()
        val row = albums.state.value.records.single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertFalse(row.sharingUpdateAcknowledged); assertFalse(shared)
        compose.onNodeWithText(text(R.string.sp_sharing_partial)).assertIsDisplayed(); capture("password-update-partial")
        assertEquals(listOf("set_shared", "update"), writes.map { it.method })
    }
    @Test fun 开启未知冷恢复仅刷新既有冻结分享仍可管理() {
        frozen = true; enableUnknown = true; show(); ready(); openAlbum()
        menu(R.string.sp_album_manage); accessReady()
        compose.onNodeWithTag("photos_album_sharing").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.sp_album_rename)).assertDoesNotExist(); closeDialog()
        compose.onNodeWithText(text(R.string.sp_sharing)).performScrollTo().performClick(); ready()
        compose.onNodeWithText(text(R.string.sp_sharing_with_others)).performScrollTo().performClick(); ready()
        compose.onNodeWithText("Synthetic album").performClick(); ready()
        menu(R.string.sp_album_manage); accessReady()
        compose.onNodeWithTag("photos_album_manage").performScrollToNode(hasText(text(R.string.sp_album_rename)))
        compose.onNodeWithText(text(R.string.sp_album_rename)).assertIsDisplayed()
        manageSharing(); accessReady()
        choose("photos_sharing_access", R.string.sp_sharing_download); save(); pending(); capture("enable-pending")
        closeDialog(); compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        menu(R.string.sp_album_records); compose.waitUntil(10_000) { albums.state.value.records.isNotEmpty() }
        compose.onNodeWithTag("photos_album_resume").performClick(); pending(); assertEquals(3, writes.size); capture("cold-read-only")
        shared = true; compose.onNodeWithTag("photos_album_resume").performClick(); settled(); assertEquals(3, writes.size); capture("cold-completed")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = false, onBackup = {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Browse.NormalAlbum", "Browse.ConditionAlbum", "Sharing.Passphrase", "Sharing.Misc")
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> suffixes.map { "$prefix.$it" } }.associateWith { ApiCapability(it, "entry.cgi", 1, 5, "JSON") }
        val repo = SynologyPhotosRepository(owner.profileId, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (cap.name.endsWith("Browse.Album") && method == "get") { gate?.await(); if (failRead) throw IOException("synthetic read") }
            response(call)
        })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, editStore = editStore, albumStore = store)
    }
    private fun response(call: Call): JsonObject {
        fun list(rows: List<JsonObject>) = buildJsonObject { put("list", JsonArray(rows)) }
        return when {
            call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41,"uid":1041}""")
            call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"management"}""")
            call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
            call.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
            call.api.endsWith("Browse.Item") || call.api.endsWith("Browse.Category") -> list(emptyList())
            call.api.endsWith("Browse.Album") -> list(listOf(album()))
            call.method == "list_shared_with_me_album" -> list(emptyList())
            call.method == "list_user_group" -> {
                if (failCandidates) throw IOException("synthetic candidates")
                obj("""{"list":[{"id":1041,"type":"user","name":"Synthetic self"},{"id":52,"type":"user","name":"Synthetic new"},{"id":52,"type":"group","name":"Synthetic group"}]}""")
            }
            call.method == "set_shared" -> {
                val enable = call.value("enabled")!!.jsonPrimitive.boolean
                if (enable && enableUnknown) throw IOException("synthetic enable")
                shared = enable; obj("""{"passphrase":"synthetic-only"}""")
            }
            call.method == "update" -> {
                val fields = info.toMutableMap()
                call.value("password")?.let { fields["enable_password"] = JsonPrimitive(it.jsonPrimitive.content.isNotEmpty()) }
                call.value("expiration")?.let { fields["expiration"] = it }
                call.value("permission")?.jsonArray?.forEach { entry ->
                    val change = entry.jsonObject; val member = change.getValue("member").jsonObject
                    val remove = change.getValue("action").jsonPrimitive.content == "delete"
                    if (member["type"] == JsonPrimitive("public")) fields["privacy_type"] = JsonPrimitive(if (remove) "private" else "public-${change.getValue("role").jsonPrimitive.content}")
                    val prior = fields.getValue("permission").jsonArray.filter { it.jsonObject["id"] != member["id"] || it.jsonObject["type"] != member["type"] }
                    fields["permission"] = JsonArray(prior + if (remove) emptyList() else listOf(JsonObject(member + mapOf("name" to JsonPrimitive("Synthetic added"), "role" to change.getValue("role")))))
                }
                info = JsonObject(fields); if (updateUnknown) throw IOException("synthetic update"); obj("{}")
            }
            else -> error("Unexpected synthetic operation: ${call.api}.${call.method}")
        }
    }
    private fun album() = buildJsonObject {
        put("id", 71); put("name", "Synthetic album"); put("owner_user_id", 41); put("type", if (conditional) "condition" else "normal")
        put("freeze_album", frozen); put("temporary_shared", false); put("shared", shared); put("item_count", 0)
        put("cant_migrate_condition", obj("{}")); put("additional", buildJsonObject { put("sharing_info", info); put("condition_object", obj("""{"user_id":0}""")) })
    }
    private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun accessReady() { compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.access != null }; assertNull(albums.state.value.error) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithText(text(id)).performClick() }
    private fun openAlbum() { compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready(); compose.onNodeWithText("Synthetic album").performClick(); ready() }
    private fun manageSharing() { compose.onNodeWithTag("photos_album_manage").performScrollToNode(hasTestTag("photos_album_sharing")); compose.onNodeWithTag("photos_album_sharing").performClick() }
    private fun startSharing() { openAlbum(); menu(R.string.sp_album_manage); accessReady(); manageSharing(); accessReady() }
    private fun scrollTag(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_sharing_form").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun scrollText(id: Int) { compose.onNodeWithTag("photos_sharing_form").performScrollToNode(hasText(text(id))); compose.onNodeWithText(text(id)).assertIsDisplayed() }
    private fun choose(tag: String, id: Int) { scrollTag(tag).performClick(); compose.onNodeWithText(text(id)).performClick() }
    private fun save() { compose.onNodeWithTag("photos_album_save").assertIsEnabled().performClick() }
    private fun settled() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.any { it.id == albums.state.value.activeId && it.checkpoint.finished } }; assertNull(albums.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.isNotEmpty() }; assertFalse(albums.state.value.records.single().checkpoint.finished); assertNull(albums.state.value.error) }
    private fun closeDialog() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-sharing-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
