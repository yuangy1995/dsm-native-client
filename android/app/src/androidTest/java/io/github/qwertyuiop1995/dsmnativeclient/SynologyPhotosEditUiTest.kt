package io.github.qwertyuiop1995.dsmnativeclient

import android.graphics.Bitmap
import android.view.KeyEvent
import android.view.accessibility.AccessibilityNodeInfo
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

/** 真实 Compose 图库、资料仓储与加密记录；所有网络/媒体均为合成测试数据。 */
class SynologyPhotosEditUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val profile = NasProfile("photos-edit-test-${UUID.randomUUID()}", "Synthetic Photos", "https://photos.example.invalid", "synthetic")
    private val owner = WorkspaceOwner(profile.id, UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoEditStore
    private lateinit var repositoryFactory: () -> SynologyPhotosRepository
    private var epoch by mutableIntStateOf(0)
    private val edits get() = model.edits!!
    private data class Call(val name: String, val method: String, val fields: Map<String, String>)
    private val writes = CopyOnWriteArrayList<Call>()
    private val items = ConcurrentHashMap<Long, JsonObject>()
    private val tags = CopyOnWriteArrayList(listOf(SynologyPhotoChoice(51, "Synthetic tag")))
    private var allowEdit = true
    private var applyWrites = true
    private var omitWriteReceipt = false
    private var failDetails = false
    private var gate: CompletableDeferred<Unit>? = null

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(profile.id)
    }

    @Test fun 网格多选评分保存并使用触控复选语义() {
        show(); ready()
        photo(91).performTouchInput { longClick() }
        photo(92).performClick()
        compose.onAllNodes(isToggleable()).assertCountEquals(2)
        compose.onNodeWithText(context.getString(R.string.items_selected_count, 2)).assertIsDisplayed()
        capture("selection")
        compose.onNodeWithText(text(R.string.sp_edit_title)).performClick(); editReady()
        compose.onNodeWithTag("photos_edit_rating_4").assertHeightIsAtLeast(48.dp).performClick()
        capture("rating-form")
        save(); saved()
        assertEquals("[91,92]", writes.single().fields["id"]); assertEquals("4", writes.single().fields["rating"])
        capture("rating-completed")
        compose.onNodeWithText(text(R.string.sp_edit_show_photos)).performScrollTo().performClick()
        compose.onNodeWithText("synthetic-92.jpg").performScrollTo().assertIsDisplayed()
        capture("record-photos")
    }

    @Test fun 预览进入编辑描述并保留多行中文英文内容() {
        show(); ready(); photo(91).performClick()
        compose.waitUntil(10_000) { model.preview.state.value.photo != null && !model.preview.state.value.loading }
        compose.onNodeWithContentDescription(text(R.string.sp_edit_title)).performScrollTo().performClick(); editReady()
        choose(R.string.sp_detail_description)
        compose.onNodeWithTag("photos_edit_description").performTextReplacement("Synthetic description\n测试资料")
        hideKeyboard(); capture("description-form")
        save(); saved()
        assertEquals(JsonPrimitive("Synthetic description\n测试资料").toString(), writes.single().fields["description"])
        capture("description-completed")
    }

    @Test fun 系统日期时间选择与相对时间修改均使用固定目标() {
        show(); ready(); selectOne()
        choose(R.string.sp_edit_date)
        compose.onNodeWithTag("photos_edit_date").performScrollTo().performClick()
        confirmSystemPicker("android:id/datePicker")
        confirmSystemPicker("android:id/timePicker")
        capture("date-form")
        save(); saved()
        val firstTime = writes.single().fields.getValue("time").toLong()
        compose.onNodeWithContentDescription(text(R.string.go_up)).performClick(); ready()
        selectOne(); choose(R.string.sp_edit_shift)
        capture("shift-form")
        save(); saved()
        assertEquals(firstTime + 3600, writes.last().fields.getValue("time").toLong())
        assertTrue(writes.all { "shift_time" !in it.fields })
    }

    @Test fun 已有标签增删与新建应用均回读真实标签() {
        show(); ready(); selectOne(); choose(R.string.sp_edit_add_tags)
        compose.waitUntil(10_000) { !edits.state.value.tagsLoading && edits.state.value.tags.isNotEmpty() }
        compose.onNodeWithText("Synthetic tag").performScrollTo().performClick()
        capture("add-tag-form"); save(); saved()
        assertEquals("add_tag", writes.last().method); assertEquals("[51]", writes.last().fields["tag"])
        closeEditor(); selectOne(); choose(R.string.sp_edit_remove_tags)
        compose.waitUntil(10_000) { !edits.state.value.tagsLoading && edits.state.value.tags.isNotEmpty() }
        compose.onNodeWithText("Synthetic tag").performScrollTo().performClick()
        capture("remove-tag-form"); save(); saved()
        assertEquals("remove_tag", writes.last().method)
        closeEditor(); selectOne(); choose(R.string.sp_edit_create_tag)
        compose.onNodeWithTag("photos_edit_tag_name").performTextInput("New synthetic tag")
        hideKeyboard(); capture("create-tag-form"); save(); saved()
        assertEquals(listOf("create", "add_tag"), writes.takeLast(2).map { it.method })
        assertEquals("[52]", writes.last().fields["tag"])
        assertEquals(2, items.size)
        closeEditor()
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithText(text(R.string.sp_edit_create_tag)).performClick(); editReady()
        compose.onNodeWithTag("photos_edit_kind").assertDoesNotExist()
        compose.onNodeWithTag("photos_edit_tag_name").performTextInput("Standalone tag")
        hideKeyboard(); capture("standalone-tag"); save(); saved()
        assertEquals("create", writes.last().method)
        assertTrue(edits.state.value.records.first { it.id == edits.state.value.activeId }.checkpoint.targets.isEmpty())
    }

    @Test fun 保存中断后重建模型只回读且完成记录可以移除() {
        show(); ready(); selectOne()
        compose.onNodeWithTag("photos_edit_rating_5").performClick()
        applyWrites = false; omitWriteReceipt = true
        save()
        compose.waitUntil(10_000) { !edits.state.value.working && edits.state.value.records.singleOrNull()?.checkpoint?.phase == SynologyPhotoEditPhase.PENDING }
        capture("pending")
        val pending = edits.state.value.records.single().checkpoint
        compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready()
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick()
        compose.onNodeWithText(text(R.string.sp_edit_records)).performClick()
        compose.waitUntil(10_000) { edits.state.value.records.isNotEmpty() }
        assertEquals(1, writes.size)
        updateItem(91, "rating", JsonPrimitive(5))
        compose.onNodeWithTag("photos_edit_resume").performScrollTo().performClick()
        saved(); assertEquals(1, writes.size)
        assertEquals(pending.operationId, edits.state.value.records.single().id)
        capture("restored-completed")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performScrollTo().performClick()
        compose.waitUntil(10_000) { edits.state.value.records.isEmpty() }
        compose.onNodeWithText(text(R.string.sp_edit_records_empty)).assertIsDisplayed(); capture("records-empty")
    }

    @Test fun 详情加载错误可重试而目录仅上传权限不能保存资料() {
        show(); ready(); gate = CompletableDeferred()
        photo(91).performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.sp_edit_title)).performClick()
        compose.waitUntil(10_000) { edits.state.value.loading }; capture("loading")
        failDetails = true; gate!!.complete(Unit); gate = null
        compose.waitUntil(10_000) { !edits.state.value.loading && edits.state.value.error != null }
        compose.onNodeWithTag("photos_edit_save").assertDoesNotExist(); capture("read-error")
        failDetails = false
        compose.onNodeWithText(text(R.string.sp_retry)).performClick(); editReady()
        allowEdit = false
        save(); compose.waitUntil(10_000) { !edits.state.value.working && edits.state.value.error != null }
        assertTrue(writes.isEmpty()); capture("permission-error")
        allowEdit = true
        compose.onNodeWithTag("photos_edit_resume").performScrollTo().performClick(); saved()
        assertEquals(1, writes.size)
    }

    private fun show() {
        store = SynologyPhotoEditStore(context)
        items[91] = item(91); items[92] = item(92)
        val bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.rgb(62, 137, 177)) }
        val image = ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() }; bitmap.recycle()
        val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .header("Content-Type", "image/png").body(image.toResponseBody("image/png".toMediaType())).build()
        }.build()
        val media = SynologyPhotosMediaTransport(profile, DsmSession(profile.id, "synthetic"), profile.address, http)
        val suffixes = listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "Browse.GeneralTag")
        val capabilities = suffixes.associate { "SYNO.Foto.$it" to ApiCapability("SYNO.Foto.$it", "entry.cgi", 1, 5, "JSON") }
        repositoryFactory = { SynologyPhotosRepository(profile.id, capabilities, { cap, method, fields ->
            if (cap.name.endsWith("Browse.Item") && method == "get") { gate?.await(); if (failDetails) throw IOException("synthetic read failure") }
            response(Call(cap.name, method, fields))
        }, media) }
        model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme {
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, canBackup = false, onBackup = {}) }
            }
        } } }
    }
    private fun makeModel() = SynologyPhotosModel(repositoryFactory(), scope, uploadOwner = owner, editStore = store)
    private fun response(call: Call): JsonObject {
        when {
            call.name.endsWith("UserInfo") -> return obj("""{"enabled":true,"id":41}""")
            call.name.endsWith("Setting.User") -> return obj("""{"enable_home_service":true,"team_space_permission":"none"}""")
            call.name.endsWith("Setting.Admin") -> return obj("""{"package_version":"synthetic"}""")
            call.name.endsWith("Setting.TeamSpace") -> return obj("""{"enabled":false}""")
            call.name.endsWith("Browse.Timeline") -> return obj("""{"section":[{"list":[{"year":2025,"month":1,"day":1,"item_count":2}]}]}""")
            call.name.endsWith("Browse.Category") -> return obj("""{"list":[]}""")
            call.name.endsWith("Browse.Folder") -> return obj("""{"folder":{"id":9,"additional":{"access_permission":{"view":true,"upload":true,"manage":$allowEdit}}}}""")
            call.name.endsWith("Browse.GeneralTag") && call.method == "list" -> return buildJsonObject { put("list", Json.encodeToJsonElement(tags.toList())) }
            call.name.endsWith("Browse.GeneralTag") && call.method == "create" -> {
                writes += call
                val tag = SynologyPhotoChoice((tags.maxOfOrNull { it.id } ?: 50) + 1, Json.parseToJsonElement(call.fields.getValue("name")).jsonPrimitive.content); tags += tag
                return buildJsonObject { put("tag", Json.encodeToJsonElement(tag)) }
            }
            call.name.endsWith("Browse.Item") && call.method in setOf("list", "get") -> {
                val ids = call.fields["id"]?.let { Json.parseToJsonElement(it).jsonArray.map { id -> id.jsonPrimitive.long } } ?: listOf(91L, 92L)
                return buildJsonObject { put("list", JsonArray(ids.mapNotNull { items[it] })) }
            }
            call.name.endsWith("Browse.Item") -> {
                writes += call
                if (applyWrites) for (id in Json.parseToJsonElement(call.fields.getValue("id")).jsonArray.map { it.jsonPrimitive.long }) {
                    if (call.method == "set") {
                        for ((key, value) in call.fields.filterKeys { it != "id" }) updateItem(id, key, Json.parseToJsonElement(value))
                    } else {
                        val selected = Json.parseToJsonElement(call.fields.getValue("tag")).jsonArray.map { it.jsonPrimitive.long }
                        val old = items.getValue(id).getValue("additional").jsonObject.getValue("tag").jsonArray
                        val next = if (call.method == "remove_tag") old.filterNot { it.jsonObject.getValue("id").jsonPrimitive.long in selected }
                            else old + tags.filter { it.id in selected }.map { Json.encodeToJsonElement(it) }
                        updateItem(id, "tag", JsonArray(next))
                    }
                }
                if (omitWriteReceipt) throw IOException("synthetic connection loss")
                return obj("{}")
            }
            else -> error("Unexpected synthetic request")
        }
    }
    private fun updateItem(id: Long, key: String, value: JsonElement) {
        val old = items.getValue(id)
        items[id] = if (key == "time") JsonObject(old + (key to value)) else JsonObject(old +
            ("additional" to JsonObject(old.getValue("additional").jsonObject + (key to value))))
    }
    private fun item(id: Long) = obj("""{"id":$id,"filename":"synthetic-$id.jpg","filesize":4,"time":1735689600,"indexed_time":1735689600,"folder_id":9,"type":"photo","additional":{"rating":0,"description":"","tag":[],"thumbnail":{"unit_id":$id,"cache_key":"r"}}}""")
    private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error); assertEquals(2, model.state.value.items.size) }
    private fun editReady() { compose.waitUntil(10_000) { edits.state.value.visible && !edits.state.value.loading && edits.state.value.detailsReady }; assertNull(edits.state.value.error) }
    private fun selectOne() { photo(91).performTouchInput { longClick() }; compose.onNodeWithText(text(R.string.sp_edit_title)).performClick(); editReady() }
    private fun choose(label: Int) { compose.onNodeWithTag("photos_edit_kind").performScrollTo().performClick(); compose.onNodeWithText(text(label)).performClick() }
    private fun save() { compose.onNodeWithTag("photos_edit_save").assertIsEnabled().performClick() }
    private fun saved() { compose.waitUntil(10_000) { !edits.state.value.working && edits.state.value.records.any { it.id == edits.state.value.activeId && it.checkpoint.phase == SynologyPhotoEditPhase.COMPLETED } }; assertNull(edits.state.value.error) }
    private fun closeEditor() { compose.onNodeWithContentDescription(text(R.string.go_up)).performClick(); ready() }
    private fun text(id: Int) = context.getString(id)
    private fun photo(id: Long) = compose.onNodeWithContentDescription(context.getString(R.string.photo_thumbnail_description, "synthetic-$id.jpg"))
    private fun hideKeyboard() { InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK), true); InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK), true); compose.waitForIdle() }
    private fun confirmSystemPicker(viewId: String) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        compose.waitUntil(10_000) { automation.rootInActiveWindow?.findAccessibilityNodeInfosByViewId(viewId)?.isNotEmpty() == true }
        val button = automation.rootInActiveWindow.findAccessibilityNodeInfosByViewId("android:id/button1").single()
        assertTrue(button.isVisibleToUser && button.isEnabled)
        assertTrue(button.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        compose.waitUntil(10_000) { automation.rootInActiveWindow?.findAccessibilityNodeInfosByViewId(viewId)?.isEmpty() == true }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onNode(isDialog())
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-edit-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
