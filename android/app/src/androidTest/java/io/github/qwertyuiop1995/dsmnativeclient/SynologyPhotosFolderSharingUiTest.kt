package io.github.qwertyuiop1995.dsmnativeclient

import android.content.ClipboardManager
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

/** 合成共享目录驱动实际图库、权限仓储、Compose 与 Android 加密恢复。 */
class SynologyPhotosFolderSharingUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("folder-sharing-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val sharing get() = model.folderSharing!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>) {
        fun value(key: String) = fields[key]?.let(Json::parseToJsonElement)
    }
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("update", "set_config") }
    private var info = obj("""{"privacy_type":"private","sharing_link":"https://example.invalid/synthetic-folder","enable_password":false,"permission":[{"type":"user","id":51,"name":"Synthetic existing","role":"download"},{"type":"group","id":"51","name":"Synthetic legacy","role":"future-role"}]}""")
    private var shared = true; private var config = false; private var management = true
    private var failRead = false; private var failCandidates = false; private var emptyCandidates = false
    private var updateUnknown = false; private var applyUpdate = true; private var configFailure = false; private var denied = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 目录菜单加载当前权限复制链接且零写入() {
        show(); rootFolders(); gate = CompletableDeferred()
        compose.onNodeWithContentDescription(text(R.string.sp_folder_actions, "Synthetic folder")).performClick(); choose(R.string.sp_folder_sharing_title)
        compose.waitUntil(5_000) { sharing.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("current-permissions")
        scrollTag("photos_folder_sharing_copy").performClick()
        compose.runOnIdle { assertEquals("https://example.invalid/synthetic-folder", context.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString()) }
        capture("copy-link"); assertTrue(writes.isEmpty()); close()
        compose.onNodeWithText("Synthetic folder").performClick(); ready(); menu(R.string.sp_folder_sharing_title); form(); assertEquals(9L, sharing.state.value.original!!.snapshot.folder.id)
        capture("current-folder-entry"); assertTrue(writes.isEmpty())
    }
    @Test fun 范围成员密码和子目录覆盖取消零写确认后依序保存() {
        show(); start(); select("photos_folder_sharing_access", R.string.sp_sharing_download)
        scrollTag("photos_folder_sharing_add_member").performClick(); candidates(); capture("member-candidates")
        compose.onNodeWithTag("photos_folder_sharing_search").performTextReplacement("missing")
        compose.onNodeWithText(text(R.string.sp_sharing_no_search_results)).assertIsDisplayed(); capture("member-search-empty")
        compose.onNodeWithTag("photos_folder_sharing_search").performTextReplacement("Synthetic new")
        compose.onNode(hasText("Synthetic new") and !hasSetTextAction()).performClick()
        compose.onNodeWithText(text(R.string.sp_sharing_back)).performClick()
        select("photos_folder_sharing_role_user_52", R.string.sp_folder_sharing_role_manage)
        select("photos_folder_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_folder_sharing_password").performTextReplacement("  synthetic 密码  ")
        compose.onNodeWithTag("photos_folder_sharing_password").performImeAction()
        scrollTag("photos_folder_sharing_children").performClick(); capture("subfolder-option")
        save(); capture("risk-confirmation"); assertTrue(writes.isEmpty())
        compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick(); assertTrue(writes.isEmpty())
        save(); confirm(); settled(); capture("permissions-completed")
        assertEquals(listOf("update", "set_config"), writes.map { it.method }); assertTrue(config)
        val changes = writes[0].value("permission")!!.jsonArray; assertEquals(3, changes.size)
        assertTrue(changes.all { it.jsonObject["member"] == null && it.jsonObject["action"] == JsonPrimitive("update") })
        assertTrue(changes.any { it.jsonObject["role"] == JsonPrimitive("future-role") }); assertTrue(changes.any { it.jsonObject["role"] == JsonPrimitive("manage") })
        assertEquals("  synthetic 密码  ", writes[0].value("password")!!.jsonPrimitive.content)
        close(); menu(R.string.sp_folder_sharing_title); form(); assertEquals("", sharing.state.value.password)
        scrollTag("photos_folder_sharing_copy").assertIsDisplayed(); capture("saved-permissions")
    }
    @Test fun 单独换密直接保存移除密码需要说明后果() {
        show(); start(); select("photos_folder_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_folder_sharing_password").performTextReplacement("Synthetic password")
        compose.onNodeWithTag("photos_folder_sharing_password").performImeAction(); save(); settled()
        assertEquals(1, writes.size); assertNull(sharing.state.value.confirmation); capture("password-saved")
        close(); menu(R.string.sp_folder_sharing_title); form(); select("photos_folder_sharing_password_mode", R.string.sp_sharing_remove_password)
        save(); compose.onNodeWithText(text(R.string.sp_folder_sharing_password_risk)).assertIsDisplayed(); capture("password-removal-confirmation")
        confirm(); settled(); assertEquals(JsonPrimitive(""), writes.last().value("password")); assertEquals(JsonPrimitive(false), info["enable_password"])
        capture("password-removed")
    }
    @Test fun 第二层父限制保持只读普通共享账号没有权限入口() {
        shared = false; show(); startChild(); form()
        compose.onNodeWithText(text(R.string.sp_folder_sharing_inherited)).assertIsDisplayed()
        compose.onNodeWithTag("photos_folder_sharing_save").assertIsNotEnabled(); compose.onNodeWithTag("photos_folder_sharing_access").assertIsNotEnabled()
        capture("parent-restriction"); scrollTag("photos_folder_sharing_copy").assertIsDisplayed()
        compose.onNodeWithTag("photos_folder_sharing_children").assertDoesNotExist(); assertTrue(writes.isEmpty())
        close(); management = false; cold(); rootFolders()
        compose.onNodeWithText("Synthetic folder").performClick(); ready()
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNode(hasText(text(R.string.sp_folder_sharing_title)) and hasAnyAncestor(isPopup())).assertDoesNotExist()
        capture("entry-permission-menu"); assertTrue(writes.isEmpty())
    }
    @Test fun 未知权限保存重启后只读恢复且不重发() {
        updateUnknown = true; applyUpdate = false; show(); start(); select("photos_folder_sharing_access", R.string.sp_sharing_view)
        save(); confirm(); pending(); capture("unknown-operation"); assertEquals(1, writes.size)
        close(); cold(); menu(R.string.sp_folder_sharing_records); records(); capture("cold-record")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
        compose.onNodeWithTag("photos_folder_sharing_resume").performClick(); pending(); assertEquals(1, writes.size)
        info = JsonObject(info + ("privacy_type" to JsonPrimitive("public-view")))
        compose.onNodeWithTag("photos_folder_sharing_resume").performClick(); settled(); assertEquals(1, writes.size); capture("cold-completed")
    }
    @Test fun 空记录成员空内容和读取候选错误可重试关闭清除密码() {
        info = JsonObject(info + ("permission" to JsonArray(emptyList()))); show(); ready()
        menu(R.string.sp_folder_sharing_records); compose.waitUntil(10_000) { sharing.state.value.recordsPage }
        compose.onNodeWithText(text(R.string.sp_folder_sharing_no_records)).assertIsDisplayed(); capture("records-empty"); close()
        failRead = true; start(waitForForm = false); readError(); capture("read-error")
        failRead = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form()
        scrollText(R.string.sp_sharing_no_members); capture("members-empty")
        failCandidates = true; scrollTag("photos_folder_sharing_add_member").performClick()
        compose.waitUntil(10_000) { sharing.state.value.membersError != null && !sharing.state.value.membersLoading }; capture("candidates-error")
        failCandidates = false; emptyCandidates = true; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); candidates()
        compose.onNodeWithText(text(R.string.sp_sharing_no_candidates)).assertIsDisplayed(); capture("candidates-empty")
        compose.onNodeWithText(text(R.string.sp_sharing_back)).performClick()
        select("photos_folder_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_folder_sharing_password").performTextReplacement("Synthetic secret")
        compose.onNodeWithTag("photos_folder_sharing_password").performImeAction(); close()
        assertEquals("", sharing.state.value.password); assertTrue(writes.isEmpty())
    }
    @Test fun 保存前并发改变拒绝旧表单重新打开后明确拒绝不误报成功() {
        show(); start(); select("photos_folder_sharing_access", R.string.sp_sharing_view)
        info = JsonObject(info + ("changed_elsewhere" to JsonPrimitive(true)))
        save(); confirm(); compose.waitUntil(10_000) { !sharing.state.value.working && sharing.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_folder_sharing_changed)).assertIsDisplayed(); capture("changed-original"); assertTrue(writes.isEmpty())
        close(); menu(R.string.sp_folder_sharing_title); form(); select("photos_folder_sharing_access", R.string.sp_sharing_view)
        denied = true; save(); confirm(); settled(); compose.onNodeWithText(text(R.string.sp_folder_sharing_rejected)).assertIsDisplayed()
        assertTrue(sharing.state.value.records.single().checkpoint.folderSharing!!.rejected); capture("explicit-rejection"); assertEquals(1, writes.size)
    }
    @Test fun 默认选项失败明确部分完成换密丢回执不能追认成功() {
        configFailure = true; show(); start(); select("photos_folder_sharing_access", R.string.sp_sharing_view)
        scrollTag("photos_folder_sharing_children").performClick(); save(); confirm(); settled()
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, sharing.state.value.records.single().checkpoint.phase)
        compose.onNodeWithText(text(R.string.sp_folder_sharing_partial)).assertIsDisplayed(); capture("default-partial"); assertEquals(2, writes.size)
        close(); menu(R.string.sp_folder_sharing_title); form(); select("photos_folder_sharing_password_mode", R.string.sp_sharing_set_password)
        scrollTag("photos_folder_sharing_password").performTextReplacement("Synthetic new password")
        compose.onNodeWithTag("photos_folder_sharing_password").performImeAction(); updateUnknown = true; save(); pending(); capture("password-receipt-unknown")
        assertEquals(3, writes.size); assertFalse(sharing.state.value.records.first().checkpoint.folderSharing!!.updateAcknowledged)
        close(); cold(); menu(R.string.sp_folder_sharing_records); records()
        compose.onNodeWithTag("photos_folder_sharing_resume").performClick(); pending(); assertEquals(3, writes.size); capture("password-cold-pending")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val names = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Sharing.Misc").map { "SYNO.Foto.$it" } +
            listOf("Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Sharing.FolderPermission").map { "SYNO.FotoTeam.$it" }
        val caps = names.associateWith { ApiCapability(it, "entry.cgi", 1, 5, "JSON") }
        val repo = SynologyPhotosRepository(owner.profileId, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (method == "get" && fields["additional"]?.contains("sharing_info") == true) {
                gate?.await(); if (failRead) throw IOException("Synthetic read failure")
            }
            response(call)
        })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(call: Call): JsonObject = when {
        call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41,"uid":1041}""")
        call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":false,"team_space_permission":"${if (management) "management" else "entry"}"}""")
        call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
        call.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
        call.api.endsWith("Browse.Item") || call.api.endsWith("Browse.Category") -> obj("""{"list":[]}""")
        call.api.endsWith("Browse.Folder") && call.method == "get" -> buildJsonObject { put("folder", folder(call.value("id")?.jsonPrimitive?.long ?: 1)) }
        call.api.endsWith("Browse.Folder") && call.method == "list" -> buildJsonObject {
            val id = call.value("id")!!.jsonPrimitive.long
            put("list", JsonArray(if (id == 1L) listOf(folder(9)) else if (id == 9L) listOf(folder(10)) else emptyList()))
        }
        call.method == "get_config" -> buildJsonObject { put("set_to_subfolder", config) }
        call.method == "get_folder_link" -> obj("""{"folder_link":"https://example.invalid/synthetic-folder"}""")
        call.method == "list_user_group" -> {
            if (failCandidates) throw IOException("Synthetic candidates")
            if (emptyCandidates) obj("""{"list":[]}""") else obj("""{"list":[{"id":1041,"type":"user","name":"Synthetic self"},{"id":52,"type":"user","name":"Synthetic new"},{"id":52,"type":"group","name":"Synthetic group"}]}""")
        }
        call.method == "update" -> {
            if (denied) throw DsmFailure(105, "Synthetic denied", "Synthetic recovery")
            if (applyUpdate) {
                val access = call.value("privacy_type")!!.jsonPrimitive.content; shared = access != "management"
                val fields = (info + ("privacy_type" to JsonPrimitive(access))).toMutableMap()
                call.value("password")?.let { fields["enable_password"] = JsonPrimitive(it.jsonPrimitive.content.isNotEmpty()) }
                call.value("permission")?.jsonArray?.forEach { entry ->
                    val change = entry.jsonObject
                    val previous = fields.getValue("permission").jsonArray.filterNot { it.jsonObject["id"] == change["id"] && it.jsonObject["type"] == change["type"] }
                    fields["permission"] = JsonArray(previous + if (change["action"] == JsonPrimitive("delete")) emptyList() else
                        listOf(JsonObject(change.filterKeys { it != "action" } + ("name" to JsonPrimitive("Synthetic member")))))
                }
                info = JsonObject(fields)
            }
            if (updateUnknown) throw IOException("Synthetic lost update receipt"); obj("{}")
        }
        call.method == "set_config" -> {
            if (configFailure) throw IOException("Synthetic config failure")
            config = call.value("set_to_subfolder")!!.jsonPrimitive.boolean; obj("{}")
        }
        else -> error("Unexpected synthetic operation: ${call.api}.${call.method}")
    }
    private fun folder(id: Long) = buildJsonObject {
        put("id", id); put("name", when (id) { 1L -> "/"; 9L -> "/Synthetic folder"; else -> "/Synthetic folder/Synthetic child" })
        put("parent", when (id) { 1L -> 0; 9L -> 1; else -> 9 }); put("shared", if (id == 9L) shared else true)
        put("additional", buildJsonObject { put("sharing_info", info); put("access_permission", obj("""{"view":true,"download":true,"upload":true,"manage":false}""")) })
    }
    private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
    private fun text(id: Int, vararg arguments: Any) = context.getString(id, *arguments)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun rootFolders() { ready(); compose.onNodeWithText(text(R.string.sp_library_folders)).performClick(); ready() }
    private fun start(waitForForm: Boolean = true) { rootFolders(); compose.onNodeWithText("Synthetic folder").performClick(); ready(); menu(R.string.sp_folder_sharing_title); if (waitForForm) form() }
    private fun startChild() { rootFolders(); compose.onNodeWithText("Synthetic folder").performClick(); ready(); compose.onNodeWithText("Synthetic child").performClick(); ready(); menu(R.string.sp_folder_sharing_title) }
    private fun form() { compose.waitUntil(10_000) { !sharing.state.value.loading && sharing.state.value.original != null }; assertNull(sharing.state.value.error) }
    private fun readError() { compose.waitUntil(10_000) { !sharing.state.value.loading && sharing.state.value.error != null } }
    private fun candidates() { compose.waitUntil(10_000) { !sharing.state.value.membersLoading && sharing.state.value.candidates != null }; assertNull(sharing.state.value.membersError) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); choose(id) }
    private fun choose(id: Int) { compose.onNode(hasText(text(id)) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun select(tag: String, id: Int) { scrollTag(tag).performClick(); choose(id) }
    private fun scrollTag(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_folder_sharing_form").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun scrollText(id: Int) { compose.onNodeWithTag("photos_folder_sharing_form").performScrollToNode(hasText(text(id))); compose.onNodeWithText(text(id)).assertIsDisplayed() }
    private fun save() { compose.onNodeWithTag("photos_folder_sharing_save").assertIsEnabled().performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_folder_sharing_confirm").performClick() }
    private fun records() { compose.waitUntil(10_000) { sharing.state.value.records.isNotEmpty() } }
    private fun settled() { compose.waitUntil(10_000) { !sharing.state.value.working && sharing.state.value.records.any { it.id == sharing.state.value.activeId && it.checkpoint.finished } }; assertNull(sharing.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !sharing.state.value.working && sharing.state.value.records.any { !it.checkpoint.finished } }; assertNull(sharing.state.value.error) }
    private fun close() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-folder-sharing-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
