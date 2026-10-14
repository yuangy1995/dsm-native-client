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

/** 正式成员仓储、页面和加密记录使用合成数据，所有照片传输均由本地拦截器提供。 */
class SynologyPhotosSharedMembersUiTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = WorkspaceOwner("members-ui-${UUID.randomUUID()}", UUID.randomUUID().toString(), UUID.randomUUID().toString())
    private lateinit var model: SynologyPhotosModel
    private lateinit var store: SynologyPhotoAlbumStore
    private val feature get() = model.sharedMembers!!
    private var epoch by mutableIntStateOf(0)
    private data class Call(val api: String, val method: String, val fields: Map<String, String>)
    private val calls = CopyOnWriteArrayList<Call>()
    private val writes get() = calls.filter { it.method in setOf("update_permission", "update_all_by_member", "update_by_member") }
    private var members = listOf(member(50, "Synthetic member", "entry", false), member(41, "Synthetic administrator", "management", true),
        member(2, "administrators", "management", true, "group"), member(80, "Synthetic existing permission", "future", false))
    private val candidates = listOf(recipient(41, "Synthetic administrator"), recipient(50, "Synthetic member"), recipient(70, "Synthetic new member"), recipient(2, "administrators", "group"))
    private val folders = linkedMapOf(2L to folder(2, 1, "/Synthetic folder", "view"), 3L to folder(3, 2, "/Synthetic folder/Child", "view"), 4L to folder(4, 1, "/Synthetic public folder", null, "public-download"))
    private var ownRole = "management"; private var administrator = true; private var userId = 41L; private var enabled = true
    private var failMembers = false; private var failCandidates = false; private var failFolders = false
    private var failingMethod: String? = null; private var applyFailed = false; private var denied = false
    private var gate: CompletableDeferred<Unit>? = null
    private var afterWrite: () -> Unit = {}

    @After fun cleanup() {
        gate?.complete(Unit)
        if (::model.isInitialized) model.close()
        runBlocking { scope.coroutineContext[Job]!!.cancelAndJoin() }
        if (::store.isInitialized) store.removeProfile(owner.profileId)
    }
    @Test fun 加载搜索保护未知角色备份确认取消与保存保持个人位置() {
        show(); ready(); val before = model.state.value; gate = CompletableDeferred(); menu(R.string.sp_members_title)
        compose.waitUntil(5_000) { feature.state.value.loading }; capture("loading")
        compose.runOnIdle { gate!!.complete(Unit); gate = null }; form(); capture("members")
        search("administrators"); compose.onNodeWithText(text(R.string.sp_members_protected)).performScrollTo().assertIsDisplayed(); capture("protected")
        compose.onAllNodesWithTag("photos_members_remove_group_2").assertCountEquals(0)
        search("existing"); compose.onNodeWithText(text(R.string.sp_members_unknown)).performScrollTo().assertIsDisplayed(); capture("unknown-role")
        search("no-result"); compose.onNodeWithText(text(R.string.sp_sharing_no_search_results)).performScrollTo().assertIsDisplayed(); capture("search-empty")
        search("Synthetic member"); node("photos_members_backup_user_50").performClick(); save(); capture("confirmation"); cancel(); assertTrue(writes.isEmpty())
        save(); confirm(); settled(); capture("saved")
        assertEquals(1, writes.size); assertEquals("update_permission", writes.single().method)
        val sent = Json.parseToJsonElement(writes.single().fields.getValue("list")).jsonArray.single().jsonObject
        assertEquals(JsonPrimitive(true), sent["auto_backup"]); assertEquals(JsonPrimitive(50), sent["id"])
        assertEquals(before.items, model.state.value.items); assertEquals(before.selectedMonth, model.state.value.selectedMonth)
    }
    @Test fun 新增自定义先开目录取消零写父撤权清子草稿完成后统一保存() {
        show(); ready(); menu(R.string.sp_members_title); form(); add(); choose(70); directory(); capture("new-member-folders")
        folderNode("photos_members_expand_2").performClick(); folderRole(2, R.string.sp_sharing_role_view)
        folderRole(3, R.string.sp_sharing_role_upload); folderRole(2, R.string.sp_members_no_direct)
        folderNode("photos_members_folder_role_3").assertIsNotEnabled()
        compose.onNodeWithText(text(R.string.sp_members_children_cleared)).performScrollTo().assertIsDisplayed(); capture("parent-removed")
        compose.onNodeWithTag("photos_members_folder_cancel").performClick()
        assertFalse(feature.state.value.members.any { it.grant.id == id(70) }); assertTrue(writes.isEmpty())
        choose(70); directory(); folderRole(2, R.string.sp_sharing_role_upload); done(); assertTrue(writes.isEmpty())
        assertTrue(feature.state.value.members.any { it.grant.id == id(70) }); save(); capture("new-member-confirmation"); cancel(); assertTrue(writes.isEmpty())
        save(); confirm(); settled(); capture("new-member-saved")
        assertEquals(listOf("update_permission", "update_by_member"), writes.map { it.method })
        val direct = Json.parseToJsonElement(writes.last().fields.getValue("permission")).jsonObject
        assertEquals(JsonPrimitive(70), direct["id"]); assertEquals(JsonPrimitive("upload"), direct.getValue("list").jsonArray.single().jsonObject["role"])
    }
    @Test fun 管理降级取消保持原值批量备份不改保护成员新增管理固定开启备份() {
        show(); ready(); menu(R.string.sp_members_title); form(); search("administrator")
        node("photos_members_backup_user_41").assertIsNotEnabled(); node("photos_members_role_user_41").performClick(); chooseText(text(R.string.sp_members_entry)); directory()
        compose.onNodeWithTag("photos_members_folder_cancel").performClick(); assertEquals("management", feature.state.value.members.first { it.grant.id == id(41) }.grant.role)
        node("photos_members_role_user_41").performClick(); chooseText(text(R.string.sp_members_entry)); directory(); done()
        assertTrue(feature.state.value.members.first { it.grant.id == id(41) }.grant.autoBackup)
        node("photos_members_backup_all").performClick(); chooseText(text(R.string.sp_members_backup_none))
        assertFalse(feature.state.value.members.first { it.grant.id == id(41) }.grant.autoBackup)
        assertTrue(feature.state.value.members.first { it.grant.protected }.grant.autoBackup); add()
        candidateNode("photos_members_new_role").performClick(); chooseText(text(R.string.sp_members_management)); choose(70)
        search("new member"); node("photos_members_backup_user_70").assertIsOn().assertIsNotEnabled(); capture("new-management")
        save(); confirm(); settled(); assertEquals(1, writes.size)
    }
    @Test fun 候选与目录错误可独立重试既有成员可继续编辑() {
        show(); ready(); menu(R.string.sp_members_title); form(); failCandidates = true; add()
        compose.waitUntil(5_000) { feature.state.value.candidatesError != null }; capture("candidate-error")
        compose.onNodeWithText(text(R.string.sp_members_back)).performScrollTo().performClick(); node("photos_members_backup_user_50").performClick()
        assertTrue(feature.canSave); failFolders = true; node("photos_members_folders_user_50").performClick()
        compose.waitUntil(5_000) { feature.state.value.directory?.error != null }; capture("folder-error")
        failFolders = false; compose.onNodeWithText(text(R.string.sp_retry)).performScrollTo().performClick(); directory()
        folderNode("photos_members_folder_search").performTextInput("missing"); compose.onNodeWithText(text(R.string.sp_members_no_matches)).assertIsDisplayed(); capture("folder-search-empty")
        compose.onNodeWithTag("photos_members_folder_cancel").performClick(); save(); confirm(); settled(); assertEquals(1, writes.size)
    }
    @Test fun 名单空共享关闭读取失败无目录与公开下限状态() {
        members = emptyList(); show(); ready(); menu(R.string.sp_members_title); form()
        compose.onNodeWithText(text(R.string.sp_members_empty)).assertIsDisplayed(); capture("empty"); close()
        enabled = false; menu(R.string.sp_members_title); form(); compose.onNodeWithText(text(R.string.sp_members_disabled)).assertIsDisplayed(); capture("disabled"); close()
        enabled = true; failMembers = true; menu(R.string.sp_members_title)
        compose.waitUntil(5_000) { feature.state.value.error != null && !feature.state.value.loading }; capture("load-error")
        failMembers = false; compose.onNodeWithText(text(R.string.sp_retry)).performClick(); form(); add(); choose(70); directory()
        folderNode("photos_members_folder_role_4").assertIsEnabled()
        compose.onNodeWithText(context.getString(R.string.sp_members_public_minimum, text(R.string.sp_sharing_role_download))).performScrollTo().assertIsDisplayed(); capture("public-minimum")
        compose.onNodeWithTag("photos_members_folder_cancel").performClick(); close(); folders.clear(); menu(R.string.sp_members_title); form(); add(); choose(70); directory()
        compose.onNodeWithText(text(R.string.sp_members_no_folders)).assertIsDisplayed(); capture("no-folders"); assertTrue(writes.isEmpty())
    }
    @Test fun 连续批量后单项失败展示部分保存重开读真实目录权限() {
        show(); ready(); menu(R.string.sp_members_title); form(); node("photos_members_folders_user_50").performClick(); directory()
        batch("UPLOAD", true); batch("VIEW", true); folderRole(2, R.string.sp_folder_sharing_role_manage); capture("batch-and-single"); done()
        save(); failingMethod = "update_by_member"; denied = true; confirm(); settled()
        assertEquals(listOf("update_all_by_member", "update_by_member"), writes.map { it.method }); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, feature.state.value.records.single().checkpoint.phase)
        // 连续草稿压成最后一次全体查看，再以单项上传/管理补齐；第二步拒绝后只保留查看。
        assertEquals(JsonPrimitive("view"), Json.parseToJsonElement(writes.first().fields.getValue("permission")).jsonObject["role"])
        val changes = Json.parseToJsonElement(writes.last().fields.getValue("permission")).jsonObject.getValue("list").jsonArray.map { it.jsonObject }
        assertEquals(mapOf(2L to "manage", 3L to "upload", 4L to "upload"), changes.associate { it.getValue("folder_id").jsonPrimitive.long to it.getValue("role").jsonPrimitive.content })
        compose.onNodeWithText(text(R.string.sp_members_partial)).assertIsDisplayed(); capture("partial")
        compose.onNodeWithTag("photos_members_reopen").performClick(); form(); node("photos_members_folders_user_50").performClick(); directory()
        folderNode("photos_members_folder_role_2").assertTextContains(text(R.string.sp_sharing_role_view)); capture("partial-reopened")
        assertEquals(2, writes.size)
    }
    @Test fun 未知结果冷恢复只读后来实际匹配才完成且不重复保存() {
        show(); ready(); menu(R.string.sp_members_title); form(); node("photos_members_backup_user_50").performClick(); save()
        failingMethod = "update_permission"; confirm(); pending(); capture("pending"); assertEquals(1, writes.size)
        close(); cold(); menu(R.string.sp_members_records); records(); compose.onNodeWithTag("photos_members_resume").performClick(); pending(); assertEquals(1, writes.size)
        members = members.map { if (it["id"] == JsonPrimitive(50)) JsonObject(it + ("auto_backup" to JsonPrimitive(true))) else it }
        compose.onNodeWithTag("photos_members_resume").performClick(); settled(); capture("recovered"); assertEquals(1, writes.size)
        assertEquals(setOf(0), feature.state.value.records.single().checkpoint.sharedMembers!!.completed)
    }
    @Test fun 失去管理员或成员快照变化拒绝写入且非管理员无入口() {
        show(); ready(); menu(R.string.sp_members_title); form(); node("photos_members_backup_user_50").performClick(); save(); administrator = false; confirm()
        failed(); capture("administrator-revoked"); assertTrue(writes.isEmpty()); close(); cold(); assertFalse(feature.available)
        compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); compose.onAllNodesWithTag("photos_members_menu").assertCountEquals(0)
        compose.onNode(hasText(text(R.string.sp_settings_display)) and hasAnyAncestor(isPopup())).performScrollTo().performClick(); close()
        administrator = true; cold(); menu(R.string.sp_members_title); form(); node("photos_members_backup_user_50").performClick(); save()
        members = members + member(90, "Synthetic concurrent member", "entry", false); confirm(); failed(); capture("concurrent-members"); assertTrue(writes.isEmpty())
    }
    @Test fun 本人共享降级清除旧照片并返回同一月份且角色从实际设置读取() {
        show(); ready(); compose.onNodeWithTag("photos_source").performClick(); chooseText(text(R.string.sp_source_shared)); ready()
        compose.runOnIdle { model.jumpToMonth(YearMonth.of(2020, 3)) }; ready(); val before = model.state.value
        menu(R.string.sp_members_title); form(); node("photos_members_backup_user_50").performClick(); save(); afterWrite = { ownRole = "entry" }
        confirm(); settled(); ready(); assertFalse(model.state.value.access!!.canManageSharedSpace)
        assertEquals(before.selectedMonth, model.state.value.selectedMonth); assertEquals(SynologyPhotoSpace.SHARED, model.state.value.navigation.space)
        assertEquals(listOf(1L), model.state.value.items.map { it.id.itemId }); close(); capture("shared-access-updated")
    }
    private fun show() {
        store = SynologyPhotoAlbumStore(context); model = makeModel()
        compose.setContent { key(epoch) { LanStashTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) { SynologyPhotosLibrary(model, false, {}) }
        } } } }
    }
    private fun makeModel(): SynologyPhotosModel {
        val caps = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Sharing.Misc", "Sharing.FolderBatchPermission",
                "Browse.Folder", "Browse.Timeline", "Browse.Item", "Browse.Category", "Browse.Person", "Browse.Concept", "Browse.Album")
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
            if (method == "list_permission") { gate?.await(); if (failMembers) throw IOException("Synthetic members") }
            response(call)
        }, media)
        return SynologyPhotosModel(repo, scope, zone = ZoneOffset.UTC, uploadOwner = owner, albumStore = store)
    }
    private fun response(c: Call): JsonObject = when {
        c.api.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$userId,"is_admin":$administrator}""")
        c.api.endsWith("Setting.User") && c.method == "get" -> obj("""{"enable_home_service":true,"team_space_permission":"$ownRole","timeline_group_unit":"day","date_format":"yyyy-mm-dd","time_format":"24","item_sort_by":"takentime","sort_direction":"asc","show_item_info_in_lightbox":true,"upload_default_action":"ignore","copy_move_default_action":"skip","enable_person":true,"enable_concept":true,"enable_similar":true}""")
        c.api.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic","enable_person":true,"enable_concept":true,"enable_similar":true}""")
        c.method in setOf("update_permission", "update_all_by_member", "update_by_member") -> {
            if (c.method != failingMethod || applyFailed) apply(c)
            afterWrite()
            if (c.method == failingMethod) { if (denied) throw DsmFailure(400, "Synthetic", "Synthetic") else throw IOException("Synthetic lost receipt") }
            obj("{}")
        }
        c.method == "list_permission" -> JsonObject(mapOf("_array" to JsonArray(members)))
        c.api.endsWith("Setting.TeamSpace") -> obj("""{"enabled":$enabled,"enable_person":true,"enable_concept":true,"enable_similar":true}""")
        c.method == "list_user_group" -> { if (failCandidates) throw IOException("Synthetic candidates"); list(candidates) }
        c.api.endsWith("Browse.Folder") && c.method == "get" -> {
            if (failFolders) throw IOException("Synthetic folders")
            JsonObject(mapOf("folder" to if (c.fields["id"] == null) obj("""{"id":1,"name":"/","parent":0}""") else folders.getValue(c.fields.getValue("id").toLong())))
        }
        c.api.endsWith("Browse.Folder") && c.method == "list" -> list(folders.values.filter { it["parent"] == JsonPrimitive(c.fields.getValue("id").toLong()) }.drop(c.fields.getValue("offset").toInt()).take(200))
        c.api.endsWith("Browse.Timeline") -> obj("""{"section":[{"list":[{"year":2020,"month":3,"day":2,"item_count":1},{"year":2020,"month":3,"day":1,"item_count":1}]}]}""")
        c.api.endsWith("Browse.Item") && c.method == "list" -> list(if (c.fields["offset"] != "0") emptyList() else if (c.api.startsWith("SYNO.FotoTeam") && ownRole == "entry") listOf(photo(1)) else listOf(photo(2), photo(1)))
        c.api.endsWith("Browse.Item") && c.method == "get" -> list(Json.parseToJsonElement(c.fields.getValue("id")).jsonArray.map { photo(it.jsonPrimitive.long) })
        c.method == "get_album_list_order" -> obj("""{"album_list_sort_by":"album_name","album_list_sort_direction":"asc"}""")
        c.method == "get_album_list_display" -> obj("""{"album_display_type":"all_album"}""")
        c.api.endsWith("Browse.Category") -> list(emptyList())
        c.api.endsWith("Browse.Person") || c.api.endsWith("Browse.Concept") || c.api.endsWith("Browse.Album") -> list(emptyList())
        else -> error("Unexpected synthetic call ${c.api}.${c.method}")
    }
    private fun apply(c: Call) {
        if (c.method == "update_permission") {
            Json.parseToJsonElement(c.fields.getValue("list")).jsonArray.forEach { raw ->
                val value = raw.jsonObject; val old = members.firstOrNull { sameId(it, value) }
                members = members.filterNot { sameId(it, value) }
                if (value.getValue("action") != JsonPrimitive("delete")) members += JsonObject(value - "action" + ("name" to (old?.get("name") ?: candidates.first { sameId(it, value) }.getValue("name"))))
            }; return
        }
        val permission = Json.parseToJsonElement(c.fields.getValue("permission")).jsonObject
        val member = (permission["member"] as? JsonObject) ?: permission
        fun set(id: Long, role: String?) {
            val raw = folders.getValue(id); val sharing = raw.getValue("additional").jsonObject.getValue("sharing_info").jsonObject
            val grants = sharing.getValue("permission").jsonArray.filterNot { sameId(it.jsonObject, member) }.toMutableList()
            if (role != null) grants += buildJsonObject { put("id", member.getValue("id")); put("type", member.getValue("type")); put("role", role) }
            folders[id] = JsonObject(raw + ("additional" to buildJsonObject { put("sharing_info", JsonObject(sharing + ("permission" to JsonArray(grants)))) }))
        }
        if (c.method == "update_all_by_member") {
            val batch = SynologyPhotoMemberFolderBatch(SynologyPhotoFolderMemberRole.from(permission.getValue("role").jsonPrimitive.content)!!, permission.getValue("action") == JsonPrimitive("check_all"))
            folders.keys.toList().forEach { id ->
                val role = folders.getValue(id).getValue("additional").jsonObject.getValue("sharing_info").jsonObject.getValue("permission").jsonArray.firstOrNull { sameId(it.jsonObject, member) }?.jsonObject?.get("role")?.jsonPrimitive?.content
                set(id, batch.applying(role))
            }
        } else permission.getValue("list").jsonArray.forEach { raw ->
            val value = raw.jsonObject; val id = value.getValue("folder_id").jsonPrimitive.long; val role = value["role"]?.jsonPrimitive?.content
            set(id, role)
            if (role == null && folders.getValue(id).getValue("additional").jsonObject.getValue("sharing_info").jsonObject["privacy_type"] == JsonPrimitive("private"))
                folders.values.filter { it["parent"] == JsonPrimitive(id) }.map { it.getValue("id").jsonPrimitive.long }.forEach { set(it, null) }
        }
    }
    private fun photo(id: Long) = buildJsonObject {
        val time = Instant.parse(if (id == 2L) "2020-03-02T23:07:00Z" else "2020-03-01T12:00:00Z").epochSecond
        put("id", id); put("filename", "Synthetic$id.jpg"); put("filesize", 4); put("time", time); put("indexed_time", time); put("folder_id", 9); put("type", "photo")
        put("additional", obj("""{"thumbnail":{"unit_id":$id,"cache_key":"synthetic"}}"""))
    }
    private fun text(id: Int) = context.getString(id)
    private fun ready() { compose.waitUntil(10_000) { model.state.value.loaded && !model.state.value.loading }; assertNull(model.state.value.error) }
    private fun form() { compose.waitUntil(10_000) { !feature.state.value.loading && feature.state.value.original != null }; assertNull(feature.state.value.error) }
    private fun directory() { compose.waitUntil(10_000) { feature.state.value.directory?.let { !it.loading && it.edit != null } == true }; assertNull(feature.state.value.directory!!.error) }
    private fun menu(id: Int) { compose.onNodeWithContentDescription(text(R.string.sp_edit_actions)).performClick(); chooseText(text(id)) }
    private fun chooseText(value: String) { compose.onNode(hasText(value) and hasAnyAncestor(isPopup())).performScrollTo().performClick() }
    private fun node(tag: String, list: String = "photos_members_form"): SemanticsNodeInteraction {
        compose.onNodeWithTag(list).performScrollToNode(hasTestTag(tag)); return compose.onNodeWithTag(tag)
    }
    private fun folderNode(tag: String) = node(tag, "photos_members_directories")
    private fun candidateNode(tag: String) = node(tag, "photos_members_candidates")
    private fun search(value: String) { node("photos_members_search").performTextReplacement(value) }
    private fun add() { node("photos_members_add").performClick(); compose.waitUntil(5_000) { !feature.state.value.candidatesLoading } }
    private fun choose(id: Long) { candidateNode("photos_members_choose_user_$id").performClick() }
    private fun folderRole(id: Long, label: Int) { folderNode("photos_members_folder_role_$id").performClick(); chooseText(text(label)) }
    private fun batch(role: String, grant: Boolean) { folderNode("photos_members_folder_all").performClick(); compose.onNodeWithTag("photos_members_batch_${role}_$grant").performScrollTo().performClick() }
    private fun done() { compose.onNodeWithTag("photos_members_folder_done").performClick() }
    private fun save() { compose.onNodeWithTag("photos_members_save").assertIsEnabled().performClick() }
    private fun confirm() { compose.onNodeWithTag("photos_members_confirm").performClick() }
    private fun cancel() { compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick() }
    private fun settled() { compose.waitUntil(10_000) { !feature.state.value.working && feature.state.value.records.any { it.id == feature.state.value.activeId && it.checkpoint.finished } }; assertNull(feature.state.value.error); ready() }
    private fun pending() { compose.waitUntil(10_000) { !feature.state.value.working && feature.state.value.records.any { !it.checkpoint.finished } }; assertNull(feature.state.value.error) }
    private fun failed() { compose.waitUntil(10_000) { !feature.state.value.working && feature.state.value.error != null } }
    private fun records() { compose.waitUntil(5_000) { feature.state.value.records.isNotEmpty() } }
    private fun close() { repeat(3) { if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isNotEmpty()) compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnyAncestor(isDialog())).performClick() }; ready() }
    private fun cold() { compose.runOnIdle { model.close(); model = makeModel(); epoch++ }; ready() }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.mainClock.advanceTimeByFrame(); compose.waitForIdle()
        val root = if (compose.onAllNodes(isDialog()).fetchSemanticsNodes().isEmpty()) compose.onRoot() else compose.onAllNodes(isDialog()).onLast()
        val bitmap = root.captureToImage().asAndroidBitmap()
        val file = File(context.getExternalFilesDir(null), "workspace-photos-shared-members-review/$name.png").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(values: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(values)))
        private fun id(value: Long) = SynologyPhotoShareMemberId("user", JsonPrimitive(value))
        private fun sameId(a: JsonObject, b: JsonObject) = a["id"] == b["id"] && a["type"] == b["type"]
        private fun recipient(id: Long, name: String, type: String = "user") = buildJsonObject { put("id", id); put("type", type); put("name", name) }
        private fun member(id: Long, name: String, role: String, backup: Boolean, type: String = "user") = JsonObject(recipient(id, name, type) + mapOf("permission" to JsonPrimitive(role), "auto_backup" to JsonPrimitive(backup)))
        private fun folder(id: Long, parent: Long, name: String, role: String?, privacy: String = "private") = buildJsonObject {
            put("id", id); put("parent", parent); put("name", name); put("additional", buildJsonObject { put("sharing_info", buildJsonObject {
                put("privacy_type", privacy); put("permission", JsonArray(if (role == null) emptyList() else listOf(obj("""{"type":"user","id":50,"role":"$role"}"""))))
            }) })
        }
    }
}
