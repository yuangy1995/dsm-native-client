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
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.withId
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*

/** 合成 NAS 驱动生产界面、实际相册仓储和加密恢复，不代表真实 NAS 验收。 */
class SynologyPhotosConditionUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("photos-condition-test-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private lateinit var editStore: SynologyPhotoEditStore
    private var epoch by mutableIntStateOf(0)
    private val albums get() = model.albums!!
    private val rules get() = albums.conditions
    private data class Call(val name: String, val method: String, val fields: Map<String, String>)
    private data class Album(var name: String, var rule: JsonObject)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("create", "set_condition", "set_name", "delete") }
    private val values = ConcurrentHashMap<Long, Album>()
    private var albumOwner = 41L
    private var sharedPermission = "management"
    private var applyWrites = true
    private var omitReceipt = false
    private var failRead = false
    private var failSuggestions = false
    private var emptySuggestions = false
    private var failCount = false
    private var itemCount = 3
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
        if (::editStore.isInitialized) editStore.removeProfile(owner.profileId)
    }

    @Test fun 创建媒体评分关键词并预览数量后真实保存() {
        show(); ready(); menu(R.string.sp_condition_create); formReady()
        compose.onNodeWithTag("photos_album_save").assertIsNotEnabled()
        name("Synthetic new rules")
        button(R.string.sp_condition_videos).performClick()
        scrollText(context.resources.getQuantityString(R.plurals.sp_condition_rating_value, 1, 1)).performClick()
        assertEquals(listOf(JsonPrimitive(1)), rules.state.value.condition!!.values("rating"))
        scrollText(context.resources.getQuantityString(R.plurals.sp_condition_rating_value, 1, 1)).performClick()
        scrollText(context.resources.getQuantityString(R.plurals.sp_condition_rating_value, 5, 5)).performClick()
        scrollTag("photos_condition_search").performTextReplacement("Synthetic keyword")
        compose.onNodeWithTag("photos_condition_search").performImeAction()
        assertEquals(listOf(JsonPrimitive(-2)), rules.state.value.condition!!.values("item_type"))
        capture("create-rules")
        itemCount = 1; scrollTag("photos_condition_preview").performClick(); countReady()
        scrollTag("photos_condition_count").assertTextEquals(context.resources.getQuantityString(R.plurals.sp_condition_count, 1, 1L)); capture("count-single")
        itemCount = 3; scrollTag("photos_condition_preview").performClick(); countReady()
        scrollTag("photos_condition_count").assertTextEquals(context.resources.getQuantityString(R.plurals.sp_condition_count, 3, 3L)); capture("count-preview")
        save(); saved(); capture("created")
        val write = writes.single(); assertEquals("create", write.method); assertEquals("SYNO.Foto.Browse.ConditionAlbum", write.name)
        val rule = obj(write.fields.getValue("condition")); assertEquals(listOf(JsonPrimitive(5)), rule["rating"]?.jsonArray)
        assertEquals("or", rule["keyword_policy"]?.jsonPrimitive?.content)
        closeDialog(); openList(); compose.onNodeWithText("Synthetic new rules").assertIsDisplayed()
    }

    @Test fun 切换来源选择实际目录日期和相机建议后保存() {
        show(); ready(); menu(R.string.sp_condition_create); formReady(); name("Synthetic shared rules")
        button(R.string.sp_source_shared).performClick(); assertEquals(SynologyPhotoSpace.SHARED, rules.state.value.condition!!.space)
        button(R.string.sp_condition_add_dates).performClick()
        scrollText(text(R.string.sp_condition_end)).performClick()
        compose.onAllNodesWithTag("photos_edit_date").onFirst().performScrollTo().performClick()
        onView(withId(android.R.id.button1)).perform(click()); onView(withId(android.R.id.button1)).perform(click())
        capture("date-boundaries")
        scrollText(text(R.string.sp_condition_browse_folders)).performClick()
        compose.waitUntil(10_000) { !rules.state.value.foldersLoading && rules.state.value.path.isNotEmpty() }
        scrollText("Synthetic folder").performClick(); compose.waitUntil(10_000) { !rules.state.value.foldersLoading && rules.state.value.path.size == 2 }
        scrollText(text(R.string.sp_condition_add_folder)).performClick(); capture("selected-folder")
        field(R.string.sp_condition_camera); scrollTag("photos_condition_search").performTextReplacement("Synthetic")
        compose.onNodeWithTag("photos_condition_search").performImeAction(); suggestionsReady()
        assertTrue(calls.any { it.method == "suggest" && it.fields["keyword"] == "\"Synthetic\"" })
        scrollText(context.getString(R.string.sp_condition_add_option, "Synthetic camera")).performClick(); capture("camera-suggestion")
        field(R.string.sp_condition_exposure)
        scrollText(context.getString(R.string.sp_condition_add_option, context.getString(R.string.sp_condition_range, "0.000125", "0.0005"))).performClick()
        capture("exposure-range")
        save(); saved()
        val rule = obj(writes.single().fields.getValue("condition"))
        assertEquals(0L, rule["user_id"]?.jsonPrimitive?.long); assertEquals(listOf(JsonPrimitive(19)), rule["folder_filter"]?.jsonArray)
        assertEquals(listOf(JsonPrimitive(9)), rule["camera"]?.jsonArray)
        val exposure = rule["exposure_time_group"]!!.jsonArray.single().jsonObject
        assertEquals(setOf("start", "end"), exposure.keys)
        assertEquals(0.000125, exposure.getValue("start").jsonPrimitive.double, 0.0)
        assertEquals(0.0005, exposure.getValue("end").jsonPrimitive.double, 0.0)
        assertFalse(exposure.getValue("start").jsonPrimitive.isString)
        assertTrue(calls.any { it.name == "SYNO.FotoTeam.Browse.Folder" && it.method == "get" && it.fields["id"] == "19" })
        assertTrue(rule["time"]!!.jsonArray.single().jsonObject.keys.containsAll(listOf("start_time", "end_time")))
        val created = albums.state.value.records.single().checkpoint.createdAlbumId!!
        values.getValue(created).rule = JsonObject(rule + ("exposure_time_group" to JsonArray(listOf(obj("""{"start":0.000125,"end":0.0005}""")))))
        closeDialog(); openList(); compose.onNodeWithText("Synthetic shared rules").performClick(); ready()
        menu(R.string.sp_album_manage); accessReady(); button(R.string.sp_condition_edit).performClick(); formReady()
        save(); saved(); assertEquals(listOf("create", "set_condition"), writes.map { it.method }); capture("exposure-reopened")
    }

    @Test fun 编辑保留无名引用未知规则并可移除已有闪光灯条件() {
        show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady()
        button(R.string.sp_condition_edit).performClick(); formReady()
        scrollText(context.getString(R.string.sp_condition_missing_name, 7L)).assertIsDisplayed(); capture("missing-reference")
        scrollText(text(R.string.sp_condition_any_rule)).performClick()
        scrollTag("condition_selected:flash:true")
        compose.onNode(hasContentDescription(text(R.string.sp_condition_remove)) and hasAnyAncestor(hasTestTag("condition_selected:flash:true"))).performClick()
        assertFalse(rules.state.value.condition!!.fields.containsKey("flash"))
        scrollText(text(R.string.sp_condition_preserve_other)).assertIsDisplayed(); capture("preserved-unknown")
        save(); saved(); capture("edited")
        val rule = values.getValue(71).rule
        assertEquals(listOf(JsonPrimitive(9), JsonPrimitive(2)), rule["future"]?.jsonArray)
        assertEquals(listOf(JsonPrimitive(7)), rule["person"]?.jsonArray); assertEquals("or", rule["person_policy"]?.jsonPrimitive?.content)
        assertEquals(setOf("id", "condition"), writes.single().fields.keys)
        assertEquals("Synthetic existing rules", values.getValue(71).name)
    }

    @Test fun 加载错误搜索为空失败数量失败和保存前撤权均可恢复() {
        show(); ready(); openAlbum(); menu(R.string.sp_album_manage); accessReady()
        gate = CompletableDeferred(); button(R.string.sp_condition_edit).performClick()
        compose.waitUntil(5_000) { albums.state.value.loading }; capture("loading")
        failRead = true; gate!!.complete(Unit); gate = null
        compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.error != null }; capture("read-error")
        compose.onNodeWithTag("photos_album_save").assertIsNotEnabled(); failRead = false
        button(R.string.sp_retry).performClick(); formReady()
        field(R.string.sp_condition_camera); emptySuggestions = true; scrollTag("photos_condition_find").performClick(); suggestionsReady()
        scrollText(text(R.string.sp_condition_no_suggestions)).assertIsDisplayed(); capture("empty-search")
        failSuggestions = true; scrollTag("photos_condition_find").performClick()
        compose.waitUntil(10_000) { !rules.state.value.searching && rules.state.value.searchError != null }
        scrollText(text(R.string.sp_condition_search_failed)).assertIsDisplayed(); capture("search-error")
        failCount = true; scrollTag("photos_condition_preview").performClick()
        compose.waitUntil(10_000) { !rules.state.value.counting && rules.state.value.countError != null }
        scrollText(text(R.string.sp_condition_count_failed)).assertIsDisplayed(); capture("count-error")
        albumOwner = 42; save(); compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.error != null }
        assertTrue(writes.isEmpty()); capture("permission-error")
    }

    @Test fun 已知创建编号重启后只刷新并保留未完成记录() {
        show(); ready(); menu(R.string.sp_condition_create); formReady(); name("Synthetic pending")
        button(R.string.sp_condition_videos).performClick(); applyWrites = false; save()
        compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.any { it.checkpoint.phase == SynologyPhotoAlbumPhase.PENDING } }
        val row = albums.state.value.records.single().checkpoint
        assertNotNull(row.createdAlbumId); capture("pending-record")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist()
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        menu(R.string.sp_album_records); compose.waitUntil(10_000) { albums.state.value.records.isNotEmpty() }
        compose.onNodeWithTag("photos_album_resume").performClick()
        compose.waitUntil(10_000) { !albums.state.value.working }; assertEquals(1, writes.size)
        capture("restored-pending")
        values.getValue(row.createdAlbumId!!).rule = row.condition!!.fields
        compose.onNodeWithTag("photos_album_resume").performClick(); saved(); capture("restored-completed")
        assertEquals(1, writes.size)
    }

    @Test fun 创建回执丢失不会同名认领且普通共享访问者不显示共享来源() {
        sharedPermission = "entry"; show(); ready(); menu(R.string.sp_condition_create); formReady(); name("Synthetic unknown")
        compose.onNodeWithText(text(R.string.sp_source_shared)).assertDoesNotExist()
        omitReceipt = true; save()
        compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.isNotEmpty() }
        assertNull(albums.state.value.records.single().checkpoint.albumId)
        compose.onNodeWithTag("photos_album_resume").performClick(); compose.waitUntil(10_000) { !albums.state.value.working }
        assertFalse(albums.state.value.records.single().checkpoint.finished); assertEquals(1, writes.size); capture("unknown-create")
    }

    private fun show() {
        store = SynologyPhotoAlbumStore(context); editStore = SynologyPhotoEditStore(context)
        values[71] = Album("Synthetic existing rules", obj("""{"user_id":41,"item_type":[],"person":[7],"person_policy":"and","flash":[true],"future":[9,2]}"""))
        model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = false, onBackup = {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.Album", "Browse.NormalAlbum", "Browse.ConditionAlbum", "Sharing.Passphrase")
        val capabilities = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix -> suffixes.map { "$prefix.$it" } }.associateWith { ApiCapability(it, "entry.cgi", 1, 5, "JSON") }
        val repository = SynologyPhotosRepository(owner.profileId, capabilities, { cap, method, fields ->
            if (cap.name.endsWith("Browse.ConditionAlbum") && method == "get") { gate?.await(); if (failRead) throw IOException("synthetic read failure") }
            val call = Call(cap.name, method, fields); calls += call; response(call)
        })
        return SynologyPhotosModel(repository, scope, uploadOwner = owner, editStore = editStore, albumStore = store)
    }
    private fun response(call: Call): JsonObject {
        fun id(key: String) = Json.parseToJsonElement(call.fields.getValue(key)).let { if (it is JsonArray) it.single().jsonPrimitive.long else it.jsonPrimitive.long }
        fun value(key: String) = Json.parseToJsonElement(call.fields.getValue(key)).jsonPrimitive.content
        fun list(rows: List<JsonObject>) = buildJsonObject { put("list", JsonArray(rows)) }
        return when {
            call.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
            call.name.endsWith("Setting.User") -> obj("""{"enable_home_service":true,"team_space_permission":"$sharedPermission"}""")
            call.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
            call.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
            call.name.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
            call.name.endsWith("Browse.Category") || call.name.endsWith("Browse.Item") -> list(emptyList())
            call.name.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"upload":false,"download":true}}""")
            call.name.endsWith("Browse.Folder") -> if (call.method == "get") {
                val id = if (call.fields.containsKey("id")) id("id") else 9
                obj("""{"folder":{"id":$id,"name":"/","parent":0,"additional":{"access_permission":{"view":true}}}}""")
            } else list(if (id("id") == 9L) listOf(obj("""{"id":19,"name":"/Synthetic folder","parent":9}""")) else emptyList())
            call.name.endsWith("Browse.Album") && call.method in setOf("get", "list") -> list((if (call.method == "get") listOf(id("id")) else values.keys.sorted()).mapNotNull { id -> values[id]?.let { album(id, it) } })
            call.name.endsWith("Browse.ConditionAlbum") -> when (call.method) {
                "get" -> list(listOf(buildJsonObject { put("id", id("id")); put("additional", buildJsonObject {
                    put("condition_object", buildJsonObject { values.getValue(id("id")).rule.forEach { (key, value) ->
                        put(key, if (key in SynologyPhotoConditionCodec.references) JsonArray(value.jsonArray.map { buildJsonObject { put("id", it) } }) else value)
                    } })
                }) }))
                "suggest" -> { if (failSuggestions) throw IOException("synthetic search failure"); if (emptySuggestions) obj("{}") else obj("""{"camera":[{"id":9,"name":"Synthetic camera"}],"exposure_time_group":[{"start":0.000125,"end":0.0005}]}""") }
                "peek_item_count" -> { if (failCount) throw IOException("synthetic count failure"); obj("""{"count":$itemCount}""") }
                "create" -> {
                    val created = (values.keys.maxOrNull() ?: 71) + 1
                    values[created] = Album(value("name"), if (applyWrites) obj(call.fields.getValue("condition")) else obj("""{"user_id":41,"item_type":[]}"""))
                    if (omitReceipt) throw IOException("synthetic connection loss")
                    obj("""{"album":{"id":$created}}""")
                }
                "set_condition" -> { if (applyWrites) values.getValue(id("id")).rule = obj(call.fields.getValue("condition")); obj("{}") }
                else -> error("Unexpected synthetic condition method")
            }
            else -> error("Unexpected synthetic request")
        }
    }
    private fun album(id: Long, row: Album) = obj("""{"id":$id,"name":${JsonPrimitive(row.name)},"type":"condition","owner_user_id":$albumOwner,"freeze_album":false,"temporary_shared":false,"passphrase":"synthetic-token","item_count":0}""")
    private fun obj(raw: String) = Json.parseToJsonElement(raw).jsonObject
    private fun text(id: Int) = context.getString(id)
    private fun button(id: Int) = compose.onNodeWithText(text(id))
    private fun scrollText(value: String): SemanticsNodeInteraction {
        compose.onNodeWithTag("photos_condition_form").performScrollToNode(hasText(value))
        return compose.onNodeWithText(value)
    }
    private fun scrollTag(value: String): SemanticsNodeInteraction {
        compose.onNodeWithTag("photos_condition_form").performScrollToNode(hasTestTag(value))
        return compose.onNodeWithTag(value)
    }
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun formReady() { compose.waitUntil(10_000) { albums.state.value.visible && !albums.state.value.loading }; assertNull(albums.state.value.error) }
    private fun accessReady() { compose.waitUntil(10_000) { !albums.state.value.loading && albums.state.value.access != null } }
    private fun suggestionsReady() { compose.waitUntil(10_000) { !rules.state.value.searching && rules.state.value.suggestions != null }; assertNull(rules.state.value.searchError) }
    private fun countReady() { compose.waitUntil(10_000) { !rules.state.value.counting && rules.state.value.count != null }; assertNull(rules.state.value.countError) }
    private fun menu(label: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); button(label).performClick() }
    private fun openList() { button(R.string.sp_library_albums).performClick(); ready() }
    private fun openAlbum() { openList(); compose.onNodeWithText(values.getValue(71).name).performClick(); ready() }
    private fun field(label: Int) { scrollTag("photos_condition_field").performClick(); button(label).performClick() }
    private fun name(value: String) {
        compose.onNodeWithTag("photos_album_name").performTextReplacement(value)
        compose.onNodeWithTag("photos_album_name").performImeAction()
        compose.waitUntil(5_000) { compose.onNodeWithTag("photos_album_save").fetchSemanticsNode().boundsInRoot.bottom > compose.onNode(isDialog()).fetchSemanticsNode().boundsInRoot.bottom * .85f }
    }
    private fun save() { compose.onNodeWithTag("photos_album_save").assertIsEnabled().performClick() }
    private fun saved() { compose.waitUntil(10_000) { !albums.state.value.working && albums.state.value.records.any { it.id == albums.state.value.activeId && it.checkpoint.finished } }; assertNull(albums.state.value.error) }
    private fun closeDialog() { compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick(); ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-condition-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
