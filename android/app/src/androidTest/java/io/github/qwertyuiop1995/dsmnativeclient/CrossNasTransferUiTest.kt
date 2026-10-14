package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/** 两个真实 Repository、原生选择器、任务详情及加密清单；网络和文件均为合成数据。 */
class CrossNasTransferUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app); private val recovery = FileRecoveryStores(app)
    private val previous = profiles.lastProfileId()
    private val source = Nas("Source NAS"); private val target = Nas("Target NAS")
    private lateinit var model: AppViewModel; private lateinit var host: WorkspaceHostModel
    private val feature get() = model.crossNasTransfers
    @Before fun prepare() {
        source.directory("/source"); source.directory("/source/Folder"); source.file("/source/Folder/a.bin"); source.file("/source/one.bin")
        target.directory("/target")
        compose.runOnIdle {
            host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            source.connect(); target.connect(); assertTrue(host.select(source.profile.id, attemptRestore = false)); model = host.active.value.model
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, source.repo)
            @Suppress("UNCHECKED_CAST")
            val cache = AppViewModel::class.java.getDeclaredField("crossNasRepositories").apply { isAccessible = true }.get(model) as MutableMap<String, DsmRepository>
            cache[target.profile.id] = target.repo
            ApprovedUiFixture.setState(model, WorkspaceState(source.profile, availability = source.repo.availability(),
                selectedModule = Module.SETTINGS, fileBrowser = FileBrowserState(path = "/source")))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        compose.waitUntil(10_000) { model.workspace.value?.files is Loadable.Ready }
    }
    @After fun cleanup() {
        compose.runOnIdle { feature.pause() }
        compose.waitUntil(10_000) { !feature.state.value.busy }
        compose.runOnIdle {
            feature.invalidate(); host.closeTaskHistory(); model.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS))
            listOf(source, target).forEach { recovery.removeProfile(it.profile.id); profiles.removeProfile(it.profile.id) }
            profiles.setLastProfileId(previous)
        }
    }
    @Test fun folderMoveCopiesThenRequiresSeparateConfirmationAndDeletesWithoutRecursion() {
        begin("/source/Folder", move = true); copied(CrossNasPhase.COPIED)
        assertTrue(source.deletes.isEmpty()); assertArrayEquals(source.contents["/source/Folder/a.bin"], target.contents["/target/Folder/a.bin"])
        capture("cross-nas-copied")
        compose.onNodeWithTag("cross_nas_remove").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.cross_nas_remove_warning, source.profile.name, target.profile.name)).assertExists(); capture("cross-nas-delete-confirm")
        compose.onNodeWithText(text(R.string.cancel)).performClick(); assertTrue(source.deletes.isEmpty())
        compose.onNodeWithTag("cross_nas_remove").performClick(); compose.onNodeWithTag("cross_nas_confirm_remove").performClick()
        copied(CrossNasPhase.FINISHED); assertEquals(listOf("/source/Folder/a.bin", "/source/Folder"), source.deletes)
        assertTrue(source.deleteRecursive.all { it == "false" }); capture("cross-nas-moved")
    }
    @Test fun unknownUploadReopensFromGlobalTasksAndRefreshNeverUploadsAgain() {
        target.corruptAfterUpload = true; begin("/source/one.bin", move = true)
        compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.selected?.hasUnknown == true }
        capture("cross-nas-interrupted"); val id = feature.state.value.selectedId!!
        compose.runOnIdle { feature.dismiss(); model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.any { it.task.id == id && it.isCrossNas } == true }
        val tag = "global_task_cross-nas:$id"
        compose.onNodeWithTag("global_task_list").performScrollToNode(hasTestTag(tag)); capture("cross-nas-global")
        compose.onNode(hasText(text(R.string.file_background_task_details)) and hasAnyAncestor(hasTestTag(tag)), useUnmergedTree = true).performClick()
        compose.waitUntil(10_000) { feature.state.value.selected?.id == id }
        compose.activityRule.scenario.recreate(); assertEquals(1, target.uploads)
        compose.onNodeWithTag("cross_nas_continue").assertDoesNotExist(); compose.onNodeWithTag("cross_nas_remove").assertDoesNotExist()
        target.contents["/target/one.bin"] = source.contents.getValue("/source/one.bin")
        compose.onNodeWithTag("cross_nas_refresh").performScrollTo().performClick(); copied(CrossNasPhase.COPIED)
        assertEquals(1, target.uploads); assertTrue(source.deletes.isEmpty()); capture("cross-nas-restored")
    }
    @Test fun sourceContentChangeAfterCopyStopsDeletionAndKeepsOriginal() {
        begin("/source/one.bin", move = true); copied(CrossNasPhase.COPIED)
        source.contents["/source/one.bin"] = byteArrayOf(3, 2, 1)
        compose.onNodeWithTag("cross_nas_remove").performScrollTo().performClick(); compose.onNodeWithTag("cross_nas_confirm_remove").performClick()
        compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.failure != null }
        assertEquals(DsmErrorKind.CROSS_NAS_CHANGED, feature.state.value.failure?.kind); assertTrue(source.deletes.isEmpty()); capture("cross-nas-source-changed")
    }
    @Test fun permissionRevocationClosesConfirmationAndRejectsStaleDelete() {
        begin("/source/one.bin", move = true); copied(CrossNasPhase.COPIED)
        compose.onNodeWithTag("cross_nas_remove").performScrollTo().performClick()
        source.allowed = false; runBlocking { source.repo.refreshAccess() }
        compose.runOnIdle {
            ApprovedUiFixture.setState(model, model.workspace.value!!.copy(availability = source.repo.availability()))
            feature.authorizationChanged(); feature.confirmRemoval()
        }
        compose.onNodeWithTag("cross_nas_dialog").assertDoesNotExist(); assertTrue(source.deletes.isEmpty())
    }
    @Test fun emptyListConflictErrorAndFinishedFilterHaveActionableStates() {
        compose.runOnIdle { feature.show() }
        compose.waitUntil(10_000) { feature.state.value.records is Loadable.Ready }
        compose.onNodeWithText(text(R.string.cross_nas_empty)).assertIsDisplayed(); capture("cross-nas-empty")
        compose.runOnIdle { feature.dismiss() }; target.file("/target/one.bin"); begin("/source/one.bin")
        compose.waitUntil(10_000) { !feature.state.value.busy && feature.state.value.failure != null }
        assertEquals(DsmErrorKind.CROSS_NAS_CONFLICT, feature.state.value.failure?.kind); capture("cross-nas-conflict")
        compose.runOnIdle { feature.dismiss(); model.cancelFileCopyMove() }; target.items.remove("/target/one.bin"); target.contents.remove("/target/one.bin")
        begin("/source/one.bin"); copied(CrossNasPhase.FINISHED)
        compose.onNodeWithTag("cross_nas_items").performScrollToNode(hasText(text(R.string.cross_nas_remaining)))
        compose.onNodeWithText(text(R.string.cross_nas_remaining)).performClick()
        compose.onNodeWithText(text(R.string.cross_nas_no_remaining)).assertIsDisplayed(); capture("cross-nas-filter-empty")
        assertEquals(1, target.uploads); assertTrue(source.deletes.isEmpty())
    }
    @Test fun copiedMoveCanKeepOriginalsFinishAndClearOnlyItsRecord() {
        begin("/source/one.bin", move = true); copied(CrossNasPhase.COPIED)
        compose.onNodeWithTag("cross_nas_keep").performScrollTo().performClick(); copied(CrossNasPhase.KEPT)
        val id = feature.state.value.selectedId!!
        compose.onNodeWithTag("cross_nas_refresh").performScrollTo().performClick(); copied(CrossNasPhase.KEPT)
        compose.onNodeWithTag("cross_nas_remove").assertDoesNotExist(); capture("cross-nas-kept")
        compose.runOnIdle { feature.dismiss(); model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.any { it.task.id == id } == true }
        val row = (host.taskCenter.state.value as Loadable.Ready).value.single { it.task.id == id }
        compose.runOnIdle { host.clearFinishedTasks(listOf(row)) }
        compose.waitUntil(10_000) { runCatching { recovery.crossNas.get(id) }.isFailure }
        assertTrue(source.items.containsKey("/source/one.bin")); assertTrue(target.items.containsKey("/target/one.bin")); assertTrue(source.deletes.isEmpty())
    }
    @Test fun targetAccountChangeRedactsRecordAndOldTaskCannotOpenDetails() {
        begin("/source/one.bin", move = true); copied(CrossNasPhase.COPIED); val id = feature.state.value.selectedId!!
        compose.runOnIdle { feature.dismiss(); model.navigateTo(WorkspaceRoute.ModuleRoot(Module.TRANSFERS)) }
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.any { it.task.id == id } == true }
        val old = (host.taskCenter.state.value as Loadable.Ready).value.single { it.task.id == id }
        compose.runOnIdle { profiles.commitConnection(profiles.connectionAttempt(target.profile.id), target.profile.copy(username = "replacement"),
            DsmSession(target.profile.id, "replacement-session"), null, false, persistSession = true) }
        compose.waitUntil(10_000) { (host.taskCenter.state.value as? Loadable.Ready)?.value?.singleOrNull { it.task.id == id }?.profile == null }
        val hidden = (host.taskCenter.state.value as Loadable.Ready).value.single { it.task.id == id }
        assertEquals(old.key, hidden.key); assertNull(hidden.crossNas)
        compose.runOnIdle { host.actOnTask(old, GlobalTransferAction.OPEN_TARGET); assertFalse(feature.state.value.visible) }
        assertTrue(source.deletes.isEmpty()); assertEquals(1, target.uploads)
    }
    @Test fun loadingAndRecordReadFailureHaveVisibleRecoveryWithoutNasWrites() {
        compose.runOnIdle { feature.show() }
        compose.waitUntil(10_000) { feature.state.value.records is Loadable.Ready }
        // 仅构造读取中的 UI 状态，避免用计时假设捕获极短的本机存储读取。
        @Suppress("UNCHECKED_CAST")
        val state = CrossNasTransferFeatureModel::class.java.getDeclaredField("_state").apply { isAccessible = true }.get(feature)
            as kotlinx.coroutines.flow.MutableStateFlow<CrossNasTransferViewState>
        compose.runOnIdle { state.value = state.value.copy(records = Loadable.Loading, reading = true) }
        compose.onAllNodes(SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo)).assertCountEquals(2)
        capture("cross-nas-loading")
        compose.runOnIdle { state.value = state.value.copy(records = Loadable.Failed(DsmFailure(null, "Synthetic read failed",
            "Retry the synthetic read", kind = DsmErrorKind.CONNECTION_FAILED)), reading = false) }
        compose.onNodeWithText(text(R.string.retry)).assertIsDisplayed(); capture("cross-nas-record-error")
        compose.onNodeWithText(text(R.string.retry)).performClick()
        compose.waitUntil(10_000) { feature.state.value.records is Loadable.Ready && !feature.state.value.reading }
        compose.onNodeWithText(text(R.string.cross_nas_empty)).assertIsDisplayed()
        assertEquals(0, target.uploads); assertTrue(source.deletes.isEmpty())
    }
    private fun begin(path: String, move: Boolean = false) {
        compose.runOnIdle { model.beginFileCopyMove(listOf(source.items.getValue(path)), if (move) FileCopyMoveOperation.MOVE else FileCopyMoveOperation.COPY) }
        compose.onNodeWithText(target.profile.name).performClick()
        compose.waitUntil(10_000) { model.workspace.value?.fileCopyMove?.targetProfileId == target.profile.id && model.workspace.value?.fileCopyMoveFolders is Loadable.Ready }
        compose.onNodeWithText(text(R.string.open)).performClick()
        compose.waitUntil(10_000) { model.workspace.value?.fileCopyMove?.location?.path == "/target" && model.workspace.value?.fileCopyMoveFolders is Loadable.Ready }
        compose.onNodeWithText(text(if (move) R.string.move_here else R.string.copy_here)).performClick()
        compose.onNodeWithText(text(R.string.cross_nas_start_copy), substring = false).let {
            compose.onNode(hasText(text(R.string.cross_nas_start_copy)) and hasClickAction()).performClick()
        }
    }
    private fun copied(phase: CrossNasPhase) = compose.waitUntil(20_000) { !feature.state.value.busy && !feature.state.value.reading && feature.state.value.selected?.phase == phase }
    private fun text(id: Int, vararg args: Any) = app.getString(id, *args)
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle(); val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "workspace-cross-nas-review/$name.png"); file.parentFile?.mkdirs()
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }; image.recycle()
    }
    private inner class Nas(name: String) {
        val profile = NasProfile("cross-ui-${UUID.randomUUID()}", name, "https://synthetic.example.invalid", "synthetic")
        val items = ConcurrentHashMap<String, FileItem>(); val contents = ConcurrentHashMap<String, ByteArray>()
        val deletes = CopyOnWriteArrayList<String>(); val deleteRecursive = CopyOnWriteArrayList<String>()
        @Volatile var uploads = 0; @Volatile var allowed = true; @Volatile var corruptAfterUpload = false
        lateinit var repo: DsmRepository
        fun directory(path: String) { items[path] = FileItem(path, path.substringAfterLast('/'), true, modifiedAtEpochSeconds = 100,
            canRead = true, canWrite = true, canDelete = true, mountPointType = "normal") }
        fun file(path: String, bytes: ByteArray = byteArrayOf(1, 2, 3)) {
            items[path] = FileItem(path, path.substringAfterLast('/'), false, size = bytes.size.toLong(), modifiedAtEpochSeconds = 100,
                canRead = true, canWrite = true, canDelete = true, mountPointType = "normal"); contents[path] = bytes
        }
        fun connect() {
            val session = DsmSession(profile.id, "synthetic-session")
            val owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false, persistSession = true)
            val client = OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val fields = request.url.queryParameterNames.associateWith { request.url.queryParameter(it).orEmpty() }.toMutableMap()
                when (val body = request.body) {
                    is FormBody -> (0 until body.size).forEach { fields[body.name(it)] = body.value(it) }
                    is MultipartBody -> {
                        val fileParts = mutableListOf<Pair<String, ByteArray>>()
                        body.parts.forEach { part ->
                            val header = part.headers?.get("Content-Disposition").orEmpty()
                            val key = Regex("name=\"([^\"]+)\"").find(header)?.groupValues?.get(1).orEmpty()
                            val filename = Regex("filename=\"([^\"]+)\"").find(header)?.groupValues?.get(1)
                            val buffer = Buffer(); part.body.writeTo(buffer)
                            if (filename != null) fileParts += filename to buffer.readByteArray() else fields[key] = buffer.readUtf8()
                        }
                        assertNull(request.url.queryParameter("_sid")); assertNull(request.url.queryParameter("SynoToken"))
                        fileParts.forEach { (filename, bytes) ->
                            assertEquals("false", fields["overwrite"]); val path = fields.getValue("path") + "/" + filename
                            assertFalse(items.containsKey(path)); file(path, if (corruptAfterUpload) byteArrayOf(3, 2, 1) else bytes); uploads++
                        }
                    }
                }
                val response = if (fields["api"] == "SYNO.FileStation.Download") {
                    contents.getValue(paths(fields.getValue("path")).single()).toResponseBody("application/octet-stream".toMediaType())
                } else buildJsonObject { put("success", true); put("data", response(fields)) }.toString().toResponseBody("application/json".toMediaType())
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(response).build()
            }.build()
            val caps = mapOf("List" to 2, "MD5" to 1, "Download" to 2, "Upload" to 2, "CheckPermission" to 3, "CreateFolder" to 2, "Delete" to 2)
                .mapKeys { "SYNO.FileStation.${it.key}" }.mapValues { (key, version) -> ApiCapability(key, "entry.cgi", 1, version) }
            val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), false) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(profile, session, DsmApiClient(client), caps, access); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }; recovery.bind(repo)
        }
        private fun response(fields: Map<String, String>): JsonObject = when (fields.getValue("api")) {
            "SYNO.FileStation.List" -> when (fields.getValue("method")) {
                "getinfo" -> buildJsonObject { put("files", JsonArray(paths(fields.getValue("path")).map { path -> items[path]?.let(::json) ?: buildJsonObject { put("path", path); put("code", 408) } })) }
                "list", "list_share" -> {
                    val rows = items.values.filter { if (fields["method"] == "list_share") it.path.count { c -> c == '/' } == 1 else crossNasParent(it.path) == fields["folder_path"] }.sortedBy { it.name }
                    val offset = fields["offset"]?.toInt() ?: 0; val limit = fields["limit"]?.toInt() ?: 500
                    buildJsonObject { put("offset", offset); put("total", rows.size); put(if (fields["method"] == "list_share") "shares" else "files", JsonArray(rows.drop(offset).take(limit).map(::json))) }
                }
                else -> error("Unexpected list action")
            }
            "SYNO.FileStation.MD5" -> if (fields["method"] == "start") buildJsonObject { put("taskid", fields.getValue("file_path")) }
                else buildJsonObject { put("finished", true); put("md5", MessageDigest.getInstance("MD5").digest(contents.getValue(fields.getValue("taskid"))).joinToString("") { "%02x".format(it) }) }
            "SYNO.FileStation.CreateFolder" -> { val path = paths(fields.getValue("folder_path")).single() + "/" + paths(fields.getValue("name")).single(); directory(path); buildJsonObject {} }
            "SYNO.FileStation.Delete" -> { if (fields["method"] == "start") paths(fields.getValue("path")).forEach { path ->
                assertEquals("false", fields["recursive"]); assertFalse(items.keys.any { it.startsWith("$path/") })
                deleteRecursive += fields.getValue("recursive"); deletes += path; items.remove(path); contents.remove(path)
            }; buildJsonObject { put("finished", true) } }
            "SYNO.FileStation.CheckPermission", "SYNO.FileStation.Upload" -> buildJsonObject {}
            else -> throw IOException("Unexpected synthetic request")
        }
        private fun paths(value: String): List<String> = (Json.parseToJsonElement(value) as? JsonArray)?.map { it.jsonPrimitive.content } ?: listOf(Json.parseToJsonElement(value).jsonPrimitive.content)
        private fun json(item: FileItem) = buildJsonObject {
            put("path", item.path); put("name", item.name); put("isdir", item.isDirectory); put("size", item.size)
            putJsonObject("additional") { put("size", item.size); put("mount_point_type", "normal")
                putJsonObject("time") { put("mtime", item.modifiedAtEpochSeconds!!) }
                putJsonObject("perm") { put("read", true); put("write", true); put("delete", true) }
            }
        }
    }
}
