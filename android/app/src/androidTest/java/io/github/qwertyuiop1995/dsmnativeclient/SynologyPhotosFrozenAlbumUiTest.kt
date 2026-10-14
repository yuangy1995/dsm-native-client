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
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoConditionCodec
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

/** 实际仓储与加密存储的合成冻结相册流程，不访问 NAS 或真实相册。 */
class SynologyPhotosFrozenAlbumUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("photos-frozen-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private var epoch by mutableIntStateOf(0)
    private val albums get() = model.albums!!
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("set_unfreeze", "create", "delete") }
    private var oldExists = true; private var oldFrozen = true; private var oldName = "Synthetic frozen album"
    private var oldRule = obj("""{"user_id":41,"item_type":[],"rating":[3]}""")
    private var newName: String? = null; private var newRule: JsonObject? = null
    private var changeOld = false; private var deleteUnknown = false; private var createUnknown = false
    private var failFrozenRead = false; private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }

    @Test fun 保存普通相册保留原编号并恢复普通管理() {
        show(); ready(); openAlbum()
        gate = CompletableDeferred(); menu(R.string.sp_album_manage)
        compose.waitUntil(5_000) { albums.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; accessReady()
        capture("manage-frozen"); manageButton(R.string.sp_frozen_save).performClick(); accessReady()
        compose.onNodeWithText(text(R.string.sp_frozen_save_note)).assertIsDisplayed(); capture("save-regular-confirm")
        save(); settled(); assertEquals(1, writes.size); assertEquals("set_unfreeze", writes.single().method)
        assertEquals("71", writes.single().fields["id"]); assertFalse(model.state.value.navigation.album!!.isFrozen)
        assertFalse(model.state.value.navigation.album!!.isConditional); capture("regular-completed")
        closeDialog(); menu(R.string.sp_album_manage); accessReady()
        manageButton(R.string.sp_album_rename).assertIsDisplayed(); compose.onNodeWithText(text(R.string.sp_frozen_rebuild)).assertDoesNotExist()
        capture("manage-regular")
    }

    @Test fun 重建展示旧条件与分享后果并跳转真实新相册() {
        show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady()
        manageButton(R.string.sp_frozen_rebuild).performClick(); accessReady()
        scrollConditionText(R.string.sp_frozen_sharing_note).assertIsDisplayed(); capture("sharing-consequence")
        scrollConditionText(R.string.sp_frozen_other_rules).assertIsDisplayed(); capture("unsupported-rules")
        compose.onNodeWithTag("photos_condition_form").performScrollToNode(hasTestTag("photos_album_name"))
        compose.onNodeWithTag("photos_album_name").performTextReplacement("Synthetic replacement")
        compose.onNodeWithTag("photos_album_name").performImeAction()
        assertFalse(albums.conditions.state.value.condition!!.fields.containsKey("future"))
        compose.onNodeWithTag("photos_album_save").assertTextEquals(text(R.string.sp_frozen_replace))
        save(); settled(); assertFalse(oldExists); assertEquals(listOf("create", "delete"), writes.map { it.method })
        assertEquals(72L, model.state.value.navigation.album!!.id); assertEquals("Synthetic replacement", model.state.value.navigation.album!!.name)
        capture("replacement-completed"); closeDialog(); openList()
        compose.onNodeWithText("Synthetic replacement").assertIsDisplayed(); compose.onNodeWithText(oldName).assertDoesNotExist(); capture("replacement-list")
    }

    @Test fun 只有共享来源的旧规则只提供普通恢复并可清理完成记录() {
        oldRule = obj("""{"user_id":0}"""); show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady()
        compose.onNodeWithText(text(R.string.sp_frozen_rebuild)).assertDoesNotExist()
        manageButton(R.string.sp_frozen_save).performClick(); accessReady(); capture("regular-only")
        save(); settled(); compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performClick()
        compose.waitUntil(5_000) { albums.state.value.records.isEmpty() }
        compose.onNodeWithText(text(R.string.sp_album_no_records)).assertIsDisplayed(); capture("records-empty")
        assertEquals(1, writes.size)
    }

    @Test fun 旧相册在创建期间改变时保留两者且页面说明部分完成() {
        changeOld = true; show(); ready(); startRebuild(); save(); settled()
        val row = albums.state.value.records.single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertEquals(listOf("create"), writes.map { it.method })
        compose.onNodeWithText(text(R.string.sp_frozen_partial)).assertIsDisplayed()
        compose.onNodeWithText(text(R.string.sp_edit_continue)).assertDoesNotExist(); capture("both-kept")
        assertEquals(72L, model.state.value.navigation.album!!.id)
        closeDialog(); openList(); compose.onNodeWithText(oldName).assertIsDisplayed(); compose.onNodeWithText(newName!!).assertIsDisplayed(); capture("both-albums-list")
    }

    @Test fun 删除结果未知冷启动只读刷新直到旧相册实际消失() {
        deleteUnknown = true; show(); ready(); startRebuild(); save(); pending()
        val row = albums.state.value.records.single().checkpoint; assertTrue(row.frozenDeletionAttempted)
        capture("delete-pending"); closeDialog()
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        menu(R.string.sp_album_records); compose.waitUntil(10_000) { albums.state.value.records.isNotEmpty() }
        compose.onNodeWithTag("photos_album_resume").performClick(); pending()
        assertEquals(2, writes.size); assertTrue(oldExists); capture("cold-read-only")
        oldExists = false; compose.onNodeWithTag("photos_album_resume").performClick(); settled()
        assertEquals(2, writes.size); capture("cold-completed")
    }

    @Test fun 读取失败可重试创建回执丢失不认领同名相册() {
        show(); ready(); openAlbum(); failFrozenRead = true; menu(R.string.sp_album_manage)
        compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.error != null }
        capture("read-error"); assertNotNull(albums.state.value.access)
        failFrozenRead = false; manageButton(R.string.sp_retry).performClick(); accessReady()
        manageButton(R.string.sp_frozen_rebuild).performClick(); accessReady()
        createUnknown = true; save(); pending()
        assertNull(albums.state.value.records.single().checkpoint.createdAlbumId)
        assertTrue(oldExists); assertEquals(1, writes.size); capture("create-unknown")
        compose.onNodeWithTag("photos_album_resume").performClick(); pending(); assertEquals(1, writes.size)
        assertFalse(calls.any { it.method == "list" && it.fields.values.any { v -> v == newName } })
    }

    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = false, onBackup = {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Browse.NormalAlbum", "Browse.ConditionAlbum")
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> suffixes.map { "$prefix.$it" } }.associateWith { ApiCapability(it, "entry.cgi", 1, 5, "JSON") }
        val repo = SynologyPhotosRepository(owner.profileId, caps, { cap, method, fields ->
            val call = Call(cap.name, method, fields); calls += call
            if (cap.name.endsWith("Browse.Album") && method == "get" && fields["additional"]?.contains("condition_object") == true) {
                gate?.await(); if (failFrozenRead) throw IOException("synthetic read failure")
            }
            response(call)
        })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, editStore = editStore, albumStore = store)
    }
    private fun response(call: Call): JsonObject {
        fun id() = Json.parseToJsonElement(call.fields.getValue("id")).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
        fun list(rows: List<JsonObject>) = buildJsonObject { put("list", JsonArray(rows)) }
        return when {
            call.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
            call.api.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"management"}""")
            call.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            call.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
            call.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
            call.api.endsWith("Browse.Item") || call.api.endsWith("Browse.Category") -> list(emptyList())
            call.api.endsWith("Browse.Album") && call.method in setOf("get", "list") -> list((if (call.method == "get") listOf(id()) else listOf(71L, 72L)).mapNotNull { album(it) })
            call.api.endsWith("Browse.NormalAlbum") && call.method == "set_unfreeze" -> { oldFrozen = false; obj("{}") }
            call.api.endsWith("Browse.ConditionAlbum") && call.method == "create" -> {
                newName = Json.parseToJsonElement(call.fields.getValue("name")).jsonPrimitive.content
                newRule = obj(call.fields.getValue("condition")); if (changeOld) oldName = "Synthetic changed album"
                if (createUnknown) throw IOException("synthetic receipt loss")
                obj("""{"album":{"id":72}}""")
            }
            call.api.endsWith("Browse.ConditionAlbum") && call.method == "get" -> list(listOf(buildJsonObject {
                put("id", 72); put("additional", buildJsonObject { put("condition_object", referenceRule(newRule!!)) })
            }))
            call.api.endsWith("Browse.Album") && call.method == "delete" -> {
                assertEquals(71L, id()); if (deleteUnknown) throw IOException("synthetic deletion loss")
                oldExists = false; obj("{}")
            }
            else -> error("Unexpected synthetic operation")
        }
    }
    private fun album(id: Long): JsonObject? {
        if (id == 71L && !oldExists || id == 72L && newName == null) return null
        return buildJsonObject {
            put("id", id); put("name", if (id == 71L) oldName else newName!!); put("owner_user_id", 41)
            put("type", if (id == 71L && !oldFrozen) "normal" else "condition"); put("freeze_album", id == 71L && oldFrozen)
            put("temporary_shared", false); put("item_count", 0); put("shared", id == 71L)
            put("cant_migrate_condition", obj("""{"recently_comment":[7],"future":[9]}"""))
            put("additional", buildJsonObject {
                put("condition_object", referenceRule(if (id == 71L) oldRule else newRule!!))
                put("sharing_info", obj("""{"privacy_type":"public-view","passphrase":"synthetic-only"}"""))
            })
        }
    }
    private fun referenceRule(rule: JsonObject) = buildJsonObject { rule.forEach { (key, value) ->
        put(key, if (key in SynologyPhotoConditionCodec.references) JsonArray(value.jsonArray.map { buildJsonObject { put("id", it) } }) else value)
    } }
    private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun accessReady() { compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.access != null }; assertNull(albums.state.value.error) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithText(text(id)).performClick() }
    private fun openList() { compose.onNodeWithText(text(R.string.sp_library_albums)).performClick(); ready() }
    private fun openAlbum() { openList(); compose.onNodeWithText(oldName).performClick(); ready() }
    private fun startRebuild() { openAlbum(); menu(R.string.sp_album_manage); accessReady(); manageButton(R.string.sp_frozen_rebuild).performClick(); accessReady() }
    private fun manageButton(id: Int): SemanticsNodeInteraction {
        compose.onNodeWithTag("photos_album_manage").performScrollToNode(hasText(text(id)))
        return compose.onNodeWithText(text(id))
    }
    private fun scrollConditionText(id: Int): SemanticsNodeInteraction {
        compose.onNodeWithTag("photos_condition_form").performScrollToNode(hasText(text(id)))
        return compose.onNodeWithText(text(id))
    }
    private fun save() { compose.onNodeWithTag("photos_album_save").assertIsEnabled().performClick() }
    private fun settled() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.any { it.id == albums.state.value.activeId && it.checkpoint.finished } }; assertNull(albums.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.isNotEmpty() }; assertFalse(albums.state.value.records.single().checkpoint.finished); assertNull(albums.state.value.error) }
    private fun closeDialog() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-frozen-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
