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

/** 生产仓储、图库、任务控制及加密记录；所有响应均为明确合成数据，不访问真实NAS。 */
class SynologyPhotosBackgroundUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("background-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val tasks get() = model.background!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val version: Int, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("abort_task", "clear_completed_task") }
    private val rows = CopyOnWriteArrayList<JsonObject>()
    private var readGate: CompletableDeferred<Unit>? = null
    private var failRead = false; private var failErrors = false; private var failNames = false; private var failStatus = false
    private var apply = true; private var loseReceipt = false; private var rejectId: Long? = null
    private var home = true; private var folderView = true
    private var errorRows = listOf(obj("""{"type":"item","id":21,"reason":"space_full"}"""), obj("""{"type":"folder","id":9,"reason":"quota_full"}"""))

    @After fun cleanup() {
        readGate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 加载失败重试空内容筛选和未知类型使用真实状态() {
        show(); ready(); readGate = CompletableDeferred(); open()
        compose.waitUntil(5_000) { tasks.state.value.loading }; capture("loading")
        failRead = true; compose.runOnIdle { readGate!!.complete(Unit); readGate = null }
        compose.waitUntil(5_000) { tasks.state.value.listError != null && !tasks.state.value.loading }
        compose.onNodeWithText(text(R.string.sp_tasks_load_failed)).assertIsDisplayed(); capture("read-failed")
        failRead = false; refresh(); loaded(); compose.onNodeWithText(text(R.string.sp_tasks_empty)).assertIsDisplayed(); capture("empty")
        rows += task(91); rows += task(92, "done", completion = 10); rows += task(93, "future", operation = "future")
        refresh(); loaded(); scroll("photos_task_91").assertIsDisplayed(); capture("active-task")
        filter("FINISHED"); scroll("photos_task_92").assertIsDisplayed(); capture("finished-filter")
        rows.removeIf { it["id"]!!.jsonPrimitive.long == 92L }; refresh(); loaded()
        compose.onNodeWithText(text(R.string.sp_tasks_filter_empty)).assertIsDisplayed(); capture("filter-empty")
        filter("ALL"); scroll("photos_task_93").assertIsDisplayed(); capture("unknown-readonly")
        compose.onNodeWithTag("photos_task_stop_93").assertDoesNotExist(); compose.onNodeWithTag("photos_task_clear_93").assertDoesNotExist()
        assertTrue(writes.isEmpty())
    }
    @Test fun 停止确认取消零写入确认后保留已完成内容且操作记录独立() {
        rows += task(91); show(); ready(); open(); loaded(); scroll("photos_task_stop_91").performClick(); confirmation(); capture("stop-confirmation")
        compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick(); assertTrue(writes.isEmpty())
        scroll("photos_task_stop_91").performClick(); confirmation(); confirm(); settled(); loaded()
        compose.onNodeWithText(text(R.string.sp_tasks_stopped)).performScrollTo().assertIsDisplayed(); capture("stopped-kept-content")
        history(); capture("stop-record")
        compose.onNodeWithText(text(R.string.sp_tasks_stop_done)).performScrollTo().assertIsDisplayed()
        assertEquals(1, writes.size); assertEquals("[91]", writes.single().fields["id"])
        assertEquals("SYNO.Foto.BackgroundTask.Info", writes.single().api); assertEquals(1, writes.single().version)
        assertEquals(2L, rows.single()["completion"]!!.jsonPrimitive.long)
    }
    @Test fun 清理只针对确认快照新完成任务保留且逐项拒绝显示部分结果() {
        rows += task(91, "done", completion = 10); rows += task(92, "done", completion = 10)
        show(); ready(); open(); loaded(); scroll("photos_tasks_clear_finished").performClick(); confirmation(); capture("clear-confirmation")
        rows += task(93, "done", completion = 10); rejectId = 92
        confirm(); settled(); history(); capture("clear-partial")
        assertEquals(listOf("91", "92"), writes.map { it.fields["id"] }); assertEquals(setOf(92L, 93L), rows.map { it["id"]!!.jsonPrimitive.long }.toSet())
        val record = tasks.state.value.records.single().checkpoint
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, record.phase); assertEquals(setOf(91L), record.background!!.completed); assertEquals(setOf(92L), record.background!!.rejected)
        assertTrue(calls.none { it.method == "delete" }); assertTrue(writes.all { it.fields.keys == setOf("id") })
    }
    @Test fun 回执丢失冷恢复只读取原任务完成后才允许清除记录() {
        rows += task(91); apply = false; loseReceipt = true
        show(); ready(); open(); loaded(); scroll("photos_task_stop_91").performClick(); confirmation(); confirm(); pending(); history(); capture("pending-control")
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).assertDoesNotExist(); assertEquals(1, writes.size)
        close(); cold(); open(); loaded(); history(); capture("cold-pending")
        scroll("photos_tasks_review").performClick(); pending(); assertEquals(1, writes.size)
        replace(91, task(91, "done")); scroll("photos_tasks_review").performClick(); settled(); capture("cold-completed")
        compose.onNodeWithText(text(R.string.sp_tasks_stop_done)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(text(R.string.sp_edit_clear_record)).performScrollTo().performClick()
        compose.waitUntil(5_000) { tasks.state.value.records.isEmpty() }; assertEquals(1, writes.size)
    }
    @Test fun 失败详情补充名称按目标来源失败仍保留原因并支持重试() {
        rows += task(91, "done", completion = 10, errors = 2); show(); ready(); open(); loaded()
        failErrors = true; scroll("photos_task_errors_91").performClick(); compose.waitUntil(5_000) { tasks.state.value.errorsFailure != null }
        compose.onNodeWithText(text(R.string.sp_tasks_errors_failed)).assertIsDisplayed(); capture("errors-failed")
        failErrors = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); errorsLoaded()
        compose.onNodeWithText("Synthetic21.jpg").assertIsDisplayed(); capture("errors-names")
        compose.onNodeWithTag("photos_task_errors").performScrollToNode(hasText("Source")); compose.onNodeWithText("Source").assertIsDisplayed(); capture("errors-folder")
        assertTrue(calls.filter { it.api.endsWith("Browse.Item") && it.method == "get" }.all { it.api == "SYNO.FotoTeam.Browse.Item" && it.version == 5 && it.fields["additional"] == "[\"folder\"]" })
        closeTop(); failNames = true; scroll("photos_task_errors_91").performClick(); errorsLoaded()
        compose.onNodeWithText(text(R.string.sp_tasks_reason_space)).assertIsDisplayed(); capture("errors-name-unavailable")
        assertNull(tasks.state.value.errors.first().name); assertEquals(2, tasks.state.value.errors.size); assertTrue(writes.isEmpty())
        closeTop(); errorRows = emptyList(); scroll("photos_task_errors_91").performClick(); errorsLoaded()
        compose.onNodeWithText(text(R.string.sp_tasks_errors_empty)).assertIsDisplayed(); capture("errors-empty")
    }
    @Test fun 目标目录重新检查权限失败留在页面成功跳转完整路径() {
        rows += task(91, "done", completion = 10); show(); ready(); open(); loaded()
        folderView = false; scroll("photos_task_target_91").performClick(); compose.waitUntil(5_000) { tasks.state.value.error != null && !tasks.state.value.navigating }
        assertTrue(tasks.state.value.visible); assertEquals(SynologyPhotosSection.TIMELINE, model.state.value.navigation.section); capture("target-denied")
        folderView = true; scroll("photos_task_target_91").performClick(); compose.waitUntil(10_000) { !tasks.state.value.visible }; ready(); capture("target-opened")
        assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
        assertEquals(listOf(1L, 20L), model.state.value.navigation.folders.map { it.id }); assertTrue(writes.isEmpty())
    }
    @Test fun 个人图库关闭仍读取统一用户任务确认后身份变化不发送() {
        home = false; rows += task(91); show(); ready(); open(); loaded(); capture("shared-only-tasks")
        assertEquals(listOf(SynologyPhotoSpace.SHARED), model.state.value.access!!.spaces)
        scroll("photos_task_stop_91").performClick(); confirmation(); replace(91, task(91, created = 101.5)); confirm()
        compose.waitUntil(5_000) { !tasks.state.value.working && tasks.state.value.error != null }
        compose.onNodeWithText(text(R.string.sp_tasks_changed)).performScrollTo().assertIsDisplayed(); capture("task-identity-changed")
        assertTrue(writes.isEmpty()); assertTrue(store.records(owner, 41).isEmpty())
        assertTrue(calls.filter { it.method == "list_user_task" }.all { it.api == "SYNO.Foto.BackgroundTask.Info" && it.version == 1 && it.fields.isEmpty() })
    }
    @Test fun 原复制未决可停止同任务原记录读取结束前不允许清理() {
        rows += task(91); show(seedFile = true); ready(); open(); loaded(); scroll("photos_task_stop_91").performClick(); confirmation()
        failStatus = true; confirm(); settled(); loaded(); capture("original-file-pending")
        scroll("photos_task_clear_91").performClick(); compose.waitUntil(5_000) { !tasks.state.value.preparing && tasks.state.value.error != null }
        assertNull(tasks.state.value.confirmation); assertEquals(1, writes.size); capture("clear-blocked-by-file")
        failStatus = false
        compose.runOnIdle { model.files!!.resume(store.records(owner, 41).single { it.checkpoint.files != null }.id) }
        compose.waitUntil(10_000) { store.records(owner, 41).single { it.checkpoint.files != null }.checkpoint.finished }
        scroll("photos_task_clear_91").performClick(); confirmation(); confirm(); settled(); loaded(); capture("cleared-after-file-review")
        assertEquals(listOf("abort_task", "clear_completed_task"), writes.map { it.method })
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, store.records(owner, 41).single { it.checkpoint.files != null }.checkpoint.phase)
    }
    private fun show(seedFile: Boolean = false) {
        store = SynologyPhotoAlbumStore(context)
        if (seedFile) {
            val row = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
                action = SynologyPhotoAlbumAction.COPY_ITEMS, files = SynologyPhotoFileCheckpoint(SynologyPhotoSpace.PERSONAL,
                    folders = listOf(SynologyPhotoFolderSnapshot(9, 1, "Source", "/Source", SynologyPhotoSpace.PERSONAL)),
                    destination = SynologyPhotoFolderSnapshot(20, 1, "Target", "/Target", SynologyPhotoSpace.SHARED), duplicate = SynologyPhotoTransferDuplicate.SKIP)))
            store.begin(row); store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING))
            store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.PENDING,
                files = row.checkpoint.files!!.copy(taskId = 91, total = 10, targetVerified = true)))
        }
        model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Timeline", "Browse.Item", "Browse.Folder", "Browse.Category", "BackgroundTask.File", "BackgroundTask.Info")
                .map { "$prefix.$it" to ApiCapability("$prefix.$it", "entry.cgi", 1, 5, "JSON") }
        }.toMap()
        val repo = SynologyPhotosRepository(owner.profileId, caps, { capability, method, fields ->
            val call = Call(capability.name, capability.maxVersion, method, fields); calls += call
            if (method == "list_user_task") { readGate?.await(); if (failRead) throw IOException("Synthetic task read") }
            response(call)
        })
        return SynologyPhotosModel(repo, scope, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":41}""")
        c.api.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"entry","copy_move_default_action":"skip"}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[]}""")
        c.api.endsWith("Browse.Item") && c.method == "list" -> list(emptyList())
        c.api.endsWith("Browse.Item") && c.method == "get" -> {
            if (failNames) throw IOException("Synthetic names unavailable")
            list(listOf(obj("""{"id":21,"filename":"Synthetic21.jpg","additional":{"folder":"/Target"}}""")))
        }
        c.api.endsWith("Browse.Folder") && c.method == "get" -> {
            if (failNames) throw IOException("Synthetic folder name unavailable")
            val id = c.fields["id"]?.toLong() ?: 1L
            val path = when (id) { 1L -> "/"; 9L -> "/Source"; else -> "/Target" }
            obj("""{"folder":{"id":$id,"name":"$path","parent":${if (id == 1L) 0 else 1},"additional":{"access_permission":{"view":$folderView,"manage":true,"upload":true,"download":true}}}}""")
        }
        c.api.endsWith("Browse.Folder") && c.method == "list" -> list(emptyList())
        c.method == "list_user_task" -> list(rows.toList())
        c.method == "get_status" -> {
            if (failStatus) throw IOException("Synthetic original task status")
            list(rows.toList())
        }
        c.method == "get_error_detail" -> { if (failErrors) throw IOException("Synthetic details"); list(errorRows) }
        c.method in setOf("abort_task", "clear_completed_task") -> {
            val value = Json.parseToJsonElement(c.fields.getValue("id")); val id = (if (value is JsonArray) value.single() else value).jsonPrimitive.long
            if (rejectId == id) throw DsmFailure(105, "Synthetic denied", "Synthetic recovery")
            if (apply) {
                if (c.method == "clear_completed_task") rows.removeIf { it["id"]!!.jsonPrimitive.long == id }
                else replace(id, JsonObject(rows.single { it["id"]!!.jsonPrimitive.long == id } + ("status" to JsonPrimitive("done"))))
            }
            if (loseReceipt) throw IOException("Synthetic receipt lost")
            obj("{}")
        }
        else -> error("Unexpected synthetic operation ${c.api}.${c.method}")
    }
    private fun task(id: Long, status: String = "processing", completion: Int = 2, errors: Int = 0, operation: String = "copy", created: Double = 100.5) =
        obj("""{"id":$id,"operation":"$operation","status":"$status","create_time":$created,"total":10,"completion":$completion,"error":$errors,"skip":0,"overwrite":0,"target_folder":{"id":20,"owner_user_id":0}}""")
    private fun replace(id: Long, row: JsonObject) { val index = rows.indexOfFirst { it["id"]!!.jsonPrimitive.long == id }; rows[index] = row }
    private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun open() { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onNodeWithTag("photos_tasks_menu").performScrollTo().performClick() }
    private fun loaded() { compose.waitUntil(10_000) { tasks.state.value.loaded && !tasks.state.value.loading }; assertNull(tasks.state.value.listError) }
    private fun scroll(tag: String): SemanticsNodeInteraction { compose.onNodeWithTag("photos_tasks_list").performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag) }
    private fun filter(name: String) { scroll("photos_tasks_filter_$name").performClick() }
    private fun refresh() { scroll("photos_tasks_refresh").performClick() }
    private fun history() { scroll("photos_tasks_history").performClick(); compose.waitUntil(5_000) { tasks.state.value.recordsPage } }
    private fun confirmation() { compose.waitUntil(5_000) { tasks.state.value.confirmation != null }; compose.onNodeWithTag("photos_tasks_confirm").assertIsDisplayed() }
    private fun confirm() { compose.onNodeWithTag("photos_tasks_confirm").performClick() }
    private fun settled() { compose.waitUntil(10_000) { !tasks.state.value.working && tasks.state.value.records.any { it.id == tasks.state.value.activeId && it.checkpoint.finished } }; assertNull(tasks.state.value.error) }
    private fun pending() { compose.waitUntil(10_000) { !tasks.state.value.working && tasks.state.value.hasPending } }
    private fun errorsLoaded() { compose.waitUntil(5_000) { tasks.state.value.errorTask != null && !tasks.state.value.errorsLoading }; assertNull(tasks.state.value.errorsFailure) }
    private fun closeTop() { compose.onAllNodes(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).onLast().performClick() }
    private fun close() { closeTop(); ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-tasks-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object { private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject }
}
