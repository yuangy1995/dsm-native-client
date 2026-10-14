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
import org.junit.*
import org.junit.Assert.*
import java.io.File
import java.io.IOException
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 真实文件入口、权限表单与 Repository；所有网络和账号资料仅为合成测试数据。 */
class FilePermissionUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val recovery = FilePermissionRecoveryStore(app)
    private val isoRecovery = FileISOMountRecoveryStore(app)
    private val remoteRecovery = FileRemoteMountRecoveryStore(app)
    private val previous = profiles.lastProfileId()
    private val profile = NasProfile("permission-ui-" + UUID.randomUUID(), "Permission NAS", "https://synthetic.example.invalid", "synthetic")
    private val root = FileItem("/synthetic", "Synthetic", true, canRead = true, canWrite = true)
    private val folder = FileItem("/synthetic/Folder", "Folder", true, canRead = true, canWrite = true, mountPointType = "normal")
    private val child = FileItem("/synthetic/Folder/Child", "Child", true, canRead = true, canWrite = true, mountPointType = "normal")
    private val calls = Collections.synchronizedList(mutableListOf<Map<String,String>>())
    private val original = FileACLRule("user", "synthetic-user", 1000, false, FileACLEffect.ALLOW,
        setOf(FileACLRight.READ_DATA), setOf(FileACLInheritance.THIS_FOLDER))
    @Volatile private var rules = listOf(original, original.copy(ownerType = "group", ownerName = "synthetic-group", level = 1))
    @Volatile private var acl = true
    @Volatile private var mountType = "normal"
    @Volatile private var administrator = true
    @Volatile private var mode = "755"
    @Volatile private var user = "synthetic-user"
    @Volatile private var group = "synthetic-group"
    @Volatile private var selfDenied = false
    @Volatile private var readFailure = false
    @Volatile private var statusFinished = false
    @Volatile private var partialFailure = false
    @Volatile private var taskRunning = false
    @Volatile private var emptyMembers = false
    @Volatile private var memberFailure = false
    @Volatile private var memberPaging = false
    @Volatile private var memberGate: CountDownLatch? = null
    @Volatile private var readGate: CountDownLatch? = null
    private lateinit var model: AppViewModel
    private lateinit var repo: DsmRepository
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }; calls += fields
                val data = response(fields)
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
            }.build())
            val capabilities = listOf(ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
                ApiCapability(PERMISSION_ACL_API, "entry.cgi", 1, 1), ApiCapability(PERMISSION_PROPERTY_API, "entry.cgi", 1, 1),
                ApiCapability("SYNO.FileStation.Property.ACLOwner", "entry.cgi", 1, 1), ApiCapability("SYNO.FileStation.UserGrp", "entry.cgi", 1, 1))
                .associateBy(ApiCapability::name)
            val access = WorkspaceAccessReader(capabilities, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true,
                DesktopApplication.NAS_SETTINGS to false), administrator) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(profile, session, api, capabilities, access)
            runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }; repo.filePermissions.bindRecovery(recovery)
            repo.fileMounts.bindRecovery(isoRecovery); repo.fileMounts.remote.bindRecovery(remoteRecovery)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = root.path), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        awaitText(folder.name)
    }
    @After fun clean() {
        readGate?.countDown(); memberGate?.countDown()
        compose.waitUntil(10_000) { !model.filePermissions.state.value.busy }
        compose.runOnIdle {
            model.filePermissions.invalidate(); recovery.removeProfile(profile.id); isoRecovery.removeProfile(profile.id)
        remoteRecovery.removeProfile(profile.id)
            profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
        }
    }

    @Test fun explicitRuleSurvivesRotationAndSavesOnlyAfterConcreteConfirmation() {
        mountType = ""
        open(); capture("permissions-overview")
        compose.onNodeWithTag("permission_rule_0").performScrollTo().performClick()
        compose.onNodeWithTag("permission_right_write_data").performScrollTo().performClick()
        capture("permissions-rule")
        compose.onNodeWithTag("permission_scope_child_files").performScrollTo().performClick()
        compose.onNodeWithTag("permission_scope_all_descendants").performScrollTo().performClick()
        capture("permissions-rule-scope")
        compose.onNodeWithTag("permission_rule_done").performClick()
        compose.activityRule.scenario.recreate()
        assertTrue(FileACLRight.WRITE_DATA in model.filePermissions.state.value.draft.rules.first().rights)
        compose.onNodeWithTag("permission_save").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_permissions_access_consequence)).performScrollTo().assertIsDisplayed()
        assertTrue(writes().isEmpty()); capture("permissions-confirmation")
        compose.onNodeWithTag("permission_confirm").performClick(); awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        compose.onNodeWithText(text(R.string.file_permissions_saved)).performScrollTo().assertIsDisplayed(); capture("permissions-saved")
        val write = writes().single()
        assertEquals(1, Json.parseToJsonElement(write.getValue("rules")).jsonArray.size)
        val saved = Json.parseToJsonElement(write.getValue("rules")).jsonArray.single().jsonObject
        assertEquals(JsonPrimitive(true), saved.getValue("inherit").jsonObject["child_files"])
        assertEquals(JsonPrimitive(true), saved.getValue("inherit").jsonObject["all_descendants"])
        assertEquals("false", write["acl_recur"])
        assertTrue(runBlocking { recovery.pending(owner) }.isEmpty())
    }

    @Test fun inheritedRulesAndSharedRootAreReadableAndCannotBeEdited() {
        open()
        compose.onNodeWithTag("permission_inherited_0").performScrollTo().performClick()
        compose.onNodeWithTag("permission_right_read_data").assertIsNotEnabled()
        compose.onNodeWithTag("permission_remove_rule").assertDoesNotExist()
        compose.onNodeWithText(text(R.string.file_permissions_inherited_readonly)).assertIsDisplayed(); capture("permissions-inherited")
        compose.onNodeWithTag("permission_rule_done").performClick()
        compose.onNodeWithContentDescription(text(R.string.close)).performClick()
        compose.runOnIdle { assertTrue(model.filePermissions.open(root)) }
        awaitLoaded()
        compose.onNodeWithText(text(R.string.file_permissions_readonly)).assertExists()
        compose.onNodeWithTag("permission_save").assertDoesNotExist(); assertTrue(writes().isEmpty())
    }

    @Test fun ownerSearchFiltersEmptyResultAndUsesChosenMember() {
        open()
        compose.onNodeWithText(text(R.string.file_permissions_owner), substring = false).performScrollTo().performClick()
        awaitText("new-owner")
        compose.onNodeWithTag("permission_member_query").performTextInput("missing")
        compose.onNodeWithTag("permission_member_query").performImeAction()
        awaitText(text(R.string.file_share_member_empty)); capture("permissions-member-empty")
        compose.onNodeWithTag("permission_member_query").performTextReplacement("new")
        compose.onNodeWithTag("permission_member_query").performImeAction(); awaitText("new-owner")
        compose.onNodeWithText("new-owner").performClick()
        compose.onNodeWithTag("permission_save").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_permissions_owner_consequence)).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("permission_confirm").performClick(); awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        assertEquals("new-owner", writes().single()["acl_owner"]); assertEquals("false", writes().single()["change_acl"])
    }

    @Test fun selfLockCheckStopsSaveAndOffersRecoveryWithoutSet() {
        selfDenied = true; open(); editRule()
        compose.onNodeWithTag("permission_save").performScrollTo().performClick(); compose.onNodeWithTag("permission_confirm").performClick()
        compose.waitUntil(10_000) { model.filePermissions.state.value.failure?.kind == DsmErrorKind.FILE_PERMISSIONS_SELF_DENIED }
        compose.onNodeWithText(text(R.string.file_permissions_self_denied), substring = true).performScrollTo().assertIsDisplayed()
        assertTrue(writes().isEmpty()); capture("permissions-self-lock")
        selfDenied = false; compose.onNodeWithText(text(R.string.refresh), substring = false).performScrollTo().performClick(); awaitLoaded()
        compose.onNodeWithTag("permission_save").assertIsNotEnabled()
    }

    @Test fun posixPermissionAndGroupUseCorrectFieldsAndRetainOwner() {
        acl = false; open()
        compose.onNodeWithTag("permission_mode_2_4").performScrollTo().performClick()
        compose.onNodeWithTag("permission_mode_2_1").performScrollTo().performClick()
        capture("permissions-posix")
        compose.onAllNodesWithText(text(R.string.file_permissions_group)).onFirst().performScrollTo().performClick(); awaitText("new-group")
        compose.onNodeWithText("new-group").performClick()
        compose.onNodeWithTag("permission_save").performScrollTo().performClick(); compose.onNodeWithTag("permission_confirm").performClick()
        awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        assertEquals("750", writes().single()["mode"]); assertEquals("new-group", writes().single()["group"])
        assertFalse(writes().single().containsKey("owner"))
    }

    @Test fun recursiveUnknownSurvivesCloseAndActivityRecreationAndOnlyReadsOriginalTask() {
        taskRunning = true; open(); editRule()
        compose.onNodeWithTag("permission_recursive").performScrollTo().performClick()
        compose.onNodeWithTag("permission_save").performScrollTo().performClick(); compose.onNodeWithTag("permission_confirm").performClick()
        awaitResult(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED)
        compose.onNodeWithContentDescription(text(R.string.close)).performClick(); compose.activityRule.scenario.recreate(); open()
        assertTrue(model.filePermissions.state.value.pending); compose.onNodeWithTag("permission_save").assertDoesNotExist()
        capture("permissions-pending"); statusFinished = true
        compose.onNodeWithTag("permission_refresh_result").performScrollTo().performClick(); awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        assertEquals(1, writes().size); assertTrue(calls.filter { it["method"] == "status" }.all { it["task_id"] == "synthetic-permission-task" })
    }

    @Test fun childPermissionEditorLinksToUnfinishedParentWithoutStartingAnotherChange() {
        taskRunning = true; open(); editRule()
        compose.onNodeWithTag("permission_recursive").performScrollTo().performClick()
        compose.onNodeWithTag("permission_save").performScrollTo().performClick(); compose.onNodeWithTag("permission_confirm").performClick()
        awaitResult(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED)
        compose.onNodeWithContentDescription(text(R.string.close)).performClick()
        awaitText(folder.name); compose.onNodeWithText(folder.name).performClick(); awaitText(child.name)
        open(target = child)
        assertEquals(folder.path, model.filePermissions.state.value.relatedPendingPath)
        compose.onNodeWithTag("permission_save").assertDoesNotExist()
        compose.onNodeWithTag("permission_open_related").performScrollTo().assertIsDisplayed(); capture("permissions-related")
        compose.onNodeWithTag("permission_open_related").performClick(); awaitLoaded()
        assertEquals(folder.path, model.filePermissions.state.value.path)
        statusFinished = true
        compose.onNodeWithTag("permission_refresh_result").performScrollTo().performClick(); awaitResult(MutationResultStatus.CONFIRMED_SUCCESS)
        assertEquals(1, writes().size)
    }

    @Test fun partialFailureKeepsWarningAndBlocksAnotherSave() {
        taskRunning = true; statusFinished = true; partialFailure = true; open(); editRule()
        compose.onNodeWithTag("permission_recursive").performScrollTo().performClick()
        compose.onNodeWithTag("permission_save").performScrollTo().performClick(); compose.onNodeWithTag("permission_confirm").performClick()
        awaitResult(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED)
        compose.onNodeWithText(text(R.string.file_permissions_partial)).performScrollTo().assertIsDisplayed(); capture("permissions-partial")
        partialFailure = false
        compose.onNodeWithTag("permission_refresh_result").performScrollTo().performClick()
        compose.waitUntil(10_000) { !model.filePermissions.state.value.busy }
        assertTrue(model.filePermissions.state.value.outcome!!.partialFailure); assertEquals(1, writes().size)
    }

    @Test fun loadingReadFailureEmptyRulesAndEmptyMemberListHaveUsableStates() {
        readGate = CountDownLatch(1)
        open(wait = false)
        compose.waitUntil(10_000) { model.filePermissions.state.value.snapshot is Loadable.Loading }
        compose.onNodeWithTag("file_permissions").assertExists(); capture("permissions-loading")
        readFailure = true; readGate?.countDown(); readGate = null
        awaitText(text(R.string.file_permissions_read_failed))
        compose.onNodeWithText(text(R.string.retry)).performScrollTo().assertIsDisplayed(); capture("permissions-read-failure")
        readFailure = false; rules = emptyList()
        compose.onNodeWithText(text(R.string.retry)).performClick(); awaitLoaded()
        compose.onNodeWithText(text(R.string.file_permissions_empty)).assertExists(); capture("permissions-empty")
        emptyMembers = true
        compose.onNodeWithTag("permission_add_rule").performScrollTo().performClick(); awaitText(text(R.string.file_share_member_empty))
        compose.onNodeWithText(text(R.string.file_permissions_no_members_hint)).assertIsDisplayed(); assertTrue(writes().isEmpty())
    }

    @Test fun memberLoadingFailureRetryAndPagingKeepTheSelectionUsable() {
        open(); memberGate = CountDownLatch(1); memberFailure = true; memberPaging = true
        compose.onNodeWithTag("permission_add_rule").performScrollTo().performClick()
        compose.waitUntil(10_000) { model.filePermissions.state.value.members is Loadable.Loading }
        capture("permissions-member-loading"); memberGate?.countDown(); memberGate = null
        compose.waitUntil(10_000) { model.filePermissions.state.value.members is Loadable.Failed }
        compose.onNodeWithText(text(R.string.retry)).assertIsDisplayed(); capture("permissions-member-failure")
        memberFailure = false; compose.onNodeWithText(text(R.string.retry)).performClick(); awaitText("new-owner")
        compose.onNodeWithText(text(R.string.file_share_more_members)).performClick(); awaitText("new-group")
        compose.onNodeWithText("new-group").performClick()
        assertEquals("new-group", model.filePermissions.state.value.draft.rules.last().ownerName)
        assertEquals(2, calls.count { it["api"] == "SYNO.FileStation.UserGrp" && it["offset"] == "0" })
        assertEquals(1, calls.count { it["api"] == "SYNO.FileStation.UserGrp" && it["offset"] == "1" })
        assertTrue(writes().isEmpty())
    }

    @Test fun revokedAdministratorClosesOldDraftAndConfirmationEvenWhenFilesStayAllowed() {
        open(); compose.onNodeWithText(text(R.string.file_permissions_owner)).performScrollTo().performClick(); awaitText("new-owner")
        compose.onNodeWithText("new-owner").performClick(); compose.onNodeWithTag("permission_save").performScrollTo().performClick()
        administrator = false
        compose.runOnIdle { model.refreshWorkspaceAccess() }
        compose.waitUntil(10_000) { model.filePermissions.state.value.path == null }
        compose.onNodeWithTag("permission_confirm").assertDoesNotExist(); assertTrue(writes().isEmpty())
        open(); compose.onNodeWithText(text(R.string.file_permissions_owner)).assertIsNotEnabled()
        assertTrue((model.filePermissions.state.value.snapshot as Loadable.Ready).value.canChangePermissions)
    }

    private fun open(wait: Boolean = true, target: FileItem = folder) {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(target.name).fetchSemanticsNodes().size == 1 }
        compose.onNodeWithText(target.name).assertIsDisplayed().performTouchInput { longClick() }
        compose.onNodeWithText(text(R.string.file_permissions_title)).performScrollTo().performClick()
        if (wait) awaitLoaded()
    }
    private fun editRule() {
        compose.onNodeWithTag("permission_rule_0").performScrollTo().performClick()
        compose.onNodeWithTag("permission_right_write_data").performScrollTo().performClick()
        compose.onNodeWithTag("permission_rule_done").performClick()
    }
    private fun awaitLoaded() = compose.waitUntil(10_000) { model.filePermissions.state.value.snapshot is Loadable.Ready && model.filePermissions.state.value.recoveryReadable }
    private fun awaitResult(status: MutationResultStatus) = compose.waitUntil(10_000) { !model.filePermissions.state.value.busy && model.filePermissions.state.value.outcome?.result?.status == status }
    private fun awaitText(value: String) = compose.waitUntil(10_000) { compose.onAllNodesWithText(value).fetchSemanticsNodes().isNotEmpty() }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] == "set" }.toList() }

    private fun response(fields: Map<String,String>): JsonObject = when (fields["api"]) {
        "SYNO.FileStation.List" -> when (fields["method"]) {
            "getinfo" -> { if (fields["additional"]?.contains("real_path") == true) readGate?.await(10, TimeUnit.SECONDS)
                if (readFailure) throw IOException("synthetic read failure")
                buildJsonObject { putJsonArray("files") { Json.parseToJsonElement(fields.getValue("path")).jsonArray.forEach {
                    val path = it.jsonPrimitive.content
                    add(file(listOf(root, folder, child).single { it.path == path }))
                } } } }
            "list_share" -> buildJsonObject { put("total", 1); put("offset", 0); putJsonArray("shares") { add(file(root)) } }
            "list" -> buildJsonObject { put("total", 1); put("offset", 0); putJsonArray("files") { add(file(if (fields["folder_path"] == folder.path) child else folder)) } }
            else -> error("Unexpected file method")
        }
        "SYNO.FileStation.Property.ACLOwner" -> buildJsonObject { put("name", user); put("type", "user"); put("value", "1000"); put("hasPrivilege", true) }
        "SYNO.FileStation.UserGrp" -> {
            memberGate?.await(10, TimeUnit.SECONDS)
            if (memberFailure) throw IOException("synthetic member read failure")
            val members = if (emptyMembers) emptyList() else listOf("new-owner" to "user", "new-group" to "group")
                .filter { it.first.startsWith(fields["prefix"].orEmpty()) }
            val offset = fields.getValue("offset").toInt()
            val page = members.drop(offset).take(if (memberPaging) 1 else 200)
            buildJsonObject { put("total", members.size); put("offset", offset); putJsonArray("owners") { page.forEach { (name,type) -> add(buildJsonObject { put("name", name); put("type", type) }) } } }
        }
        PERMISSION_ACL_API, PERMISSION_PROPERTY_API -> when (fields["method"]) {
            "get" -> buildJsonObject { put("is_acl", true); put("change_permission", true); put("is_inherited", true)
                putJsonArray("acl") { rules.forEach { rule -> add(buildJsonObject { permissionRulePayload(rule).forEach { (key,value) -> put(key,value) }; put("level", rule.level); rule.isInternal?.let { put("owner_is_internal", it) } }) } } }
            "check_self_denied" -> buildJsonObject { put("is_denied", selfDenied) }
            "set" -> {
                if (fields["change_acl"] == "true") rules = Json.parseToJsonElement(fields.getValue("rules")).jsonArray.map {
                    parsePermissionRule(JsonObject(it.jsonObject + mapOf("level" to JsonPrimitive(0), "owner_is_internal" to JsonPrimitive(false))))
                } + rules.filter { it.level > 0 }
                fields["acl_owner"]?.let { user = it }; fields["owner"]?.let { user = it }; fields["group"]?.let { group = it }
                fields["mode"]?.takeUnless { it == "-1" }?.let { mode = it }
                if (taskRunning) buildJsonObject { put(if (acl) "task_id" else "taskid", "synthetic-permission-task"); put("running", true) } else buildJsonObject {}
            }
            "status" -> buildJsonObject { put("finished", statusFinished); if (partialFailure) putJsonArray("errItems") { add(buildJsonObject {}) } }
            else -> error("Unexpected permission method")
        }
        else -> error("Unexpected synthetic API")
    }
    private fun file(item: FileItem) = buildJsonObject {
        put("path", item.path); put("name", item.name); put("isdir", item.isDirectory)
        putJsonObject("additional") {
            put("real_path", "/volume-synthetic" + item.path); put("mount_point_type", mountType)
            putJsonObject("owner") { put("user", user); put("group", group) }
            putJsonObject("perm") { put("is_acl_mode", acl); put("posix", mode.toInt()); putJsonObject("acl") { put("read", true); put("write", true); put("del", true) } }
        }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(app.getExternalFilesDir(null), "file-permission-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
