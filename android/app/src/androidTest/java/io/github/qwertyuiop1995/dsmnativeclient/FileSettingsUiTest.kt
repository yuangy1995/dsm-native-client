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

/** 从正式文件菜单进入；只替代 NAS 网络，保存经过真实权限、请求、加密恢复和回读。 */
class FileSettingsUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val recovery = FileRecoveryStores(app)
    private val previous = profiles.lastProfileId()?.takeUnless { it.startsWith("settings-ui-") }
    private val nas = NasProfile("settings-ui-" + UUID.randomUUID(), "Settings NAS", "https://synthetic.example.invalid", "synthetic")
    private val calls = Collections.synchronizedList(mutableListOf<Map<String, String>>())
    private lateinit var model: AppViewModel
    private lateinit var repo: DsmRepository
    @Volatile private var allowed = true
    @Volatile private var readFailure = false
    @Volatile private var applyWrites = true
    @Volatile private var emptyAccounts = false
    @Volatile private var policyCount = 2
    @Volatile private var gate: CountDownLatch? = null
    private var scopeValue = "admin"
    private var accountEnabled = false
    private var selectedIds = emptyList<Long>()
    private var general = buildJsonObject {
        put("transfer_log_enable", false); put("use_unix_default_perm", false); put("enable_list_usergrp", false)
        for (key in listOf("sharing_allow", "file_request_allow", "rf_allow", "vd_allow")) put(key, "admin")
        for (key in listOf("sharing_privilege", "sharing_group_privilege", "file_request_privilege", "file_request_group_privilege")) putJsonObject(key) { putJsonArray("items") {} }
        put("sharing_default_limit", "0"); put("bandwidth_enable", "bandwidth_disable"); put("schedule_plan", ""); put("enable_sharing_custom_setting", "false")
    }
    private var rate: JsonObject? = null

    @Before fun prepare() {
        profiles.profiles().filter { it.id.startsWith("settings-ui-") }.forEach { recovery.removeProfile(it.id); profiles.removeProfile(it.id) }
        val session = DsmSession(nas.id, "synthetic-session")
        val owner = profiles.commitConnection(profiles.connectionAttempt(nas.id), nas, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(nas.id, attemptRestore = false)); model = host.active.value.model
            val api = DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor { chain ->
                val request = chain.request(); val form = request.body as FormBody
                val fields = (0 until form.size).associate { form.name(it) to form.value(it) }; calls += fields
                val data = response(fields); assertNull(request.url.query)
                Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
            }.build())
            val caps = listOf(FILE_SETTINGS_API, FILE_SETTINGS_PRINCIPAL_API, FILE_MOUNT_USER_API, FILE_DIRECTORY_LDAP_API, FILE_DIRECTORY_DOMAIN_API,
                FILE_BANDWIDTH_API, "SYNO.Core.System", "SYNO.FileStation.List").associateWith {
                ApiCapability(it, "entry.cgi", 1, if (it in setOf(FILE_DIRECTORY_DOMAIN_API, "SYNO.FileStation.List")) 2 else 1)
            }
            val access = WorkspaceAccessReader(caps, { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to allowed), true) }, { error("Unexpected fallback") }, {})
            repo = DsmRepository(nas, session, api, caps, access); runBlocking { repo.refreshAccess() }
            repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }; recovery.bind(repo)
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(nas, availability = repo.availability(), selectedModule = Module.SETTINGS,
                fileBrowser = FileBrowserState(path = "/synthetic"), files = Loadable.Ready(FilePage(emptyList(), 0, 0))))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.FILES))
        }
        compose.waitUntil(10_000) { model.workspace.value?.files is Loadable.Ready }
    }
    @After fun clean() {
        gate?.countDown(); gate = null
        compose.waitUntil(10_000) { !model.fileSettings.state.value.busy }
        compose.runOnIdle { model.fileSettings.invalidate(); recovery.removeProfile(nas.id); profiles.removeProfile(nas.id); profiles.setLastProfileId(previous) }
    }
    @Test fun generalFailureRetryAndOrdinarySaveUseRealMenuAndOneSaveButton() {
        openRoot(); readFailure = true; gate = CountDownLatch(1)
        compose.onNodeWithText(text(R.string.file_settings_general)).performClick()
        compose.waitUntil(10_000) { model.fileSettings.state.value.general is Loadable.Loading }; capture("settings-loading")
        gate?.countDown(); gate = null
        compose.waitUntil(10_000) { model.fileSettings.state.value.general is Loadable.Failed }; capture("settings-error")
        compose.onNodeWithTag("settings_save").assertDoesNotExist(); readFailure = false
        compose.onNodeWithTag("settings_retry").performClick(); generalReady(); capture("settings-general")
        compose.onNodeWithTag("settings_transfers").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().assertIsEnabled().performClick()
        outcome(FileSettingsOutcomeStatus.COMPLETED); generalReady()
        assertEquals(1, writes().size); assertEquals("true", writes().single()["transfer_log_enable"])
        compose.onNodeWithTag("settings_save").performScrollTo().assertIsNotEnabled(); capture("settings-saved")
    }
    @Test fun selectedSharingAccountsSurviveRecreationAndConfirmOnlyWidenedAccess() {
        openGeneral(); choose("settings_sharing", R.string.file_settings_selected_accounts)
        compose.onNodeWithTag("settings_share_accounts").performScrollTo().performClick(); policyReady()
        compose.onNodeWithTag("settings_policy_USER_0").assertIsNotEnabled()
        compose.onNodeWithTag("settings_policy_USER_12").performScrollTo().performClick(); capture("settings-accounts")
        compose.onNodeWithTag("settings_accounts_done").performClick(); fill("settings_link_limit", "17")
        compose.activityRule.scenario.recreate()
        compose.onNodeWithTag("settings_link_limit").performScrollTo().assertTextEquals(text(R.string.file_settings_link_limit), "17")
        compose.onNodeWithTag("settings_save").performScrollTo().performClick()
        compose.onNodeWithText(text(R.string.file_settings_risk_sharing)).assertExists(); assertTrue(writes().isEmpty()); capture("settings-risk")
        compose.onNodeWithTag("settings_confirm_save").performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("12", writes().single()["enabled_sharing_privilege"]); assertEquals("17", writes().single()["sharing_default_limit"])
    }
    @Test fun remoteAccessAndDomainGroupChangesSaveIndependently() {
        openRoot(); compose.onNodeWithText(text(R.string.file_settings_remote_access)).performClick(); scopeReady()
        choose("settings_mount_scope", R.string.file_settings_selected_accounts)
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); compose.onNodeWithTag("settings_confirm_save").performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        compose.onNodeWithTag("settings_mount_accounts").performScrollTo().performClick(); mountReady()
        compose.onNodeWithTag("settings_source").performClick(); compose.onNodeWithText("Directory display").performClick(); mountReady()
        compose.onNodeWithTag("settings_account_kind").performClick(); compose.onNodeWithText(text(R.string.file_settings_groups)).performClick(); mountReady(); capture("settings-domain-list")
        compose.onNodeWithText("Synthetic group").performScrollTo().performClick()
        compose.onNodeWithTag("settings_account_enabled").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); capture("settings-mount-risk")
        compose.onNodeWithTag("settings_confirm_save").performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED); mountReady()
        assertEquals(2, writes().size); assertEquals("{\"user_enabled_type\":\"custom\"}", writes().first()["settings"])
        assertEquals("{\"group_settings\":[{\"gid\":20,\"enabled\":true}]}", writes().last()["settings"])
        assertTrue(calls.any { it["domain"] == "DIRECTORY-REQUEST" && it["content"] == "group_settings" }); capture("settings-mount-saved")
    }
    @Test fun accountListEmptyAndSearchEmptyRemainDistinctAndRecoverable() {
        openRoot(); compose.onNodeWithText(text(R.string.file_settings_remote_access)).performClick(); scopeReady()
        emptyAccounts = true; compose.onNodeWithTag("settings_mount_accounts").performScrollTo().performClick(); mountReady()
        compose.onNodeWithText(text(R.string.file_settings_accounts_empty)).assertIsDisplayed(); capture("settings-empty")
        emptyAccounts = false; compose.onNodeWithTag("settings_refresh_accounts").performClick(); mountReady()
        compose.onNodeWithTag("settings_account_search").performTextReplacement("no-match"); compose.onNodeWithTag("settings_account_search").performImeAction(); mountReady()
        compose.onNodeWithText(text(R.string.no_items_match_filter)).assertIsDisplayed(); capture("settings-filter-empty")
        compose.onNodeWithTag("settings_account_search").performTextClearance(); compose.onNodeWithTag("settings_account_search").performImeAction(); mountReady()
        compose.onNodeWithText("Synthetic user").assertIsDisplayed(); assertTrue(writes().isEmpty())
    }
    @Test fun unconfiguredBandwidthAndSundayScheduleKeepNativeValues() {
        openRoot(); compose.onNodeWithText(text(R.string.file_settings_bandwidth)).performClick(); bandwidthReady()
        compose.onNodeWithText(text(R.string.file_settings_inherited)).assertIsDisplayed(); capture("settings-bandwidth-unconfigured")
        compose.onNodeWithText("Synthetic user").performClick(); compose.onNodeWithTag("settings_save").performScrollTo().assertIsNotEnabled()
        choose("settings_account_policy", R.string.file_settings_scheduled_limit)
        fill("settings_rate_0", "10"); fill("settings_rate_1", "20"); fill("settings_rate_2", "30"); fill("settings_rate_3", "40")
        choose("settings_schedule_paint", R.string.file_settings_alternate_limit)
        compose.onNodeWithTag("settings_schedule_hour_0").performScrollTo().performClick(); capture("settings-schedule")
        compose.onNodeWithTag("settings_schedule_hour_23").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED); bandwidthReady()
        val written = Json.parseToJsonElement(writes().single().getValue("bandwidths")).jsonArray.single().jsonObject
        assertEquals("2" + "1".repeat(167), written.getValue("schedule_plan").jsonPrimitive.content)
        assertEquals(40, written.getValue("download_limit_2").jsonPrimitive.int); assertEquals("scheduled", written.getValue("policy").jsonPrimitive.content)
    }
    @Test fun weeklyServiceScheduleAndNumericValidationDoNotCreateDefaultWrites() {
        openGeneral(); fill("settings_link_limit", ""); compose.onNodeWithTag("settings_save").performScrollTo().assertIsNotEnabled()
        fill("settings_link_limit", "0"); choose("settings_bandwidth_policy", R.string.file_settings_scheduled_limit)
        choose("settings_schedule_paint", R.string.file_settings_unlimited)
        compose.onNodeWithTag("settings_schedule_fill_day").performScrollTo().performClick(); capture("settings-service-schedule")
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("0".repeat(24) + "1".repeat(144), writes().single()["schedule_plan"])
        assertEquals("bandwidth_schedule", writes().single()["bandwidth_enable"])
    }
    @Test fun unknownSaveSurvivesReopenAndOnlyReadsUntilDesiredStateAppears() {
        openGeneral(); applyWrites = false; compose.onNodeWithTag("settings_transfers").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.UNKNOWN); capture("settings-pending")
        back(); back(); compose.activityRule.scenario.recreate(); openGeneral()
        compose.onNodeWithTag("settings_transfers").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("settings_review").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.UNKNOWN); assertEquals(1, writes().size)
        general = JsonObject(general + ("transfer_log_enable" to JsonPrimitive(true)))
        compose.onNodeWithTag("settings_review").performScrollTo().performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED); generalReady()
        compose.onNodeWithTag("settings_transfers").performScrollTo().assertIsEnabled().assertIsOn(); assertEquals(1, writes().size)
    }
    @Test fun revokedPermissionDismissesRiskPromptWithoutSaving() {
        openGeneral(); compose.onNodeWithTag("settings_show_accounts").performScrollTo().performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); compose.onNodeWithTag("settings_confirm_save").assertExists()
        allowed = false; compose.runOnIdle { model.refreshWorkspaceAccess() }
        compose.waitUntil(10_000) { model.fileSettings.state.value.screen == null }
        compose.onNodeWithTag("settings_confirm_save").assertDoesNotExist(); assertTrue(writes().isEmpty())
    }
    @Test fun policyAccountPaginationSelectsAndSavesAnAccountBeyondTheFirstPage() {
        policyCount = 201; openGeneral(); choose("settings_sharing", R.string.file_settings_selected_accounts)
        compose.onNodeWithTag("settings_share_accounts").performScrollTo().performClick(); policyReady()
        compose.onNodeWithTag("settings_more").assertIsEnabled().performClick()
        compose.waitUntil(10_000) { (model.fileSettings.state.value.policyAccounts as? Loadable.Ready)?.value?.items?.size == 201 }
        compose.onNodeWithTag("settings_account_rows").performScrollToNode(hasTestTag("settings_policy_USER_201"))
        compose.onNodeWithTag("settings_policy_USER_201").performClick(); capture("settings-accounts-page-two")
        compose.onNodeWithTag("settings_more").assertDoesNotExist(); compose.onNodeWithTag("settings_accounts_done").performClick()
        compose.onNodeWithTag("settings_save").performScrollTo().performClick(); compose.onNodeWithTag("settings_confirm_save").performClick(); outcome(FileSettingsOutcomeStatus.COMPLETED)
        assertEquals("201", writes().single()["enabled_sharing_privilege"])
        assertTrue(calls.count { it["method"] == "list_user" && it["offset"] == "200" } >= 2)
    }
    private fun openRoot() {
        compose.onNodeWithContentDescription(text(R.string.client_file_options)).performClick()
        compose.onNodeWithText(text(R.string.file_settings_title)).performScrollTo().performClick()
        compose.waitUntil(10_000) { model.fileSettings.state.value.recoveryReadable }
    }
    private fun openGeneral() { openRoot(); compose.onNodeWithText(text(R.string.file_settings_general)).performClick(); generalReady() }
    private fun generalReady() = compose.waitUntil(10_000) { model.fileSettings.state.value.general is Loadable.Ready && model.fileSettings.state.value.recoveryReadable }
    private fun scopeReady() = compose.waitUntil(10_000) { model.fileSettings.state.value.mountScope is Loadable.Ready }
    private fun policyReady() = compose.waitUntil(10_000) { model.fileSettings.state.value.policyAccounts is Loadable.Ready }
    private fun mountReady() = compose.waitUntil(10_000) { model.fileSettings.state.value.mountAccounts is Loadable.Ready && model.fileSettings.state.value.directories is Loadable.Ready }
    private fun bandwidthReady() = compose.waitUntil(10_000) { model.fileSettings.state.value.bandwidth is Loadable.Ready }
    private fun outcome(value: FileSettingsOutcomeStatus) = compose.waitUntil(10_000) { !model.fileSettings.state.value.busy && model.fileSettings.state.value.outcome?.status == value }
    private fun fill(tag: String, value: String) { compose.onNodeWithTag(tag).performScrollTo().performTextReplacement(value); compose.onNodeWithTag(tag).performImeAction() }
    private fun choose(tag: String, option: Int) { compose.onNodeWithTag(tag).performScrollTo().performClick(); compose.onNodeWithText(text(option)).performClick() }
    private fun back() { compose.onNodeWithContentDescription(text(R.string.go_up)).performClick() }
    private fun text(id: Int) = app.getString(id)
    private fun writes() = synchronized(calls) { calls.filter { it["method"] == "set" }.toList() }
    private fun response(fields: Map<String, String>): JsonObject {
        val api = fields.getValue("api"); val method = fields.getValue("method")
        if (method == "set") {
            if (applyWrites) when (api) {
                FILE_SETTINGS_API -> {
                    var next = general.toMutableMap()
                    fields.forEach { (key, value) -> if (key in general) next[key] = if (key in setOf("transfer_log_enable", "use_unix_default_perm", "enable_list_usergrp")) JsonPrimitive(value.toBooleanStrict()) else JsonPrimitive(value) }
                    fields["enabled_sharing_privilege"]?.let { selectedIds = it.split(',').map(String::toLong) }
                    next["sharing_privilege"] = buildJsonObject { put("items", JsonArray(selectedIds.map { buildJsonObject { put("uid", it); put("enabled", true) } })) }
                    general = JsonObject(next)
                }
                FILE_MOUNT_USER_API -> {
                    val value = Json.parseToJsonElement(fields.getValue("settings")).jsonObject
                    value["user_enabled_type"]?.let { scopeValue = it.jsonPrimitive.content } ?: run {
                        accountEnabled = value.values.single().jsonArray.single().jsonObject.getValue("enabled").jsonPrimitive.boolean
                    }
                }
                FILE_BANDWIDTH_API -> rate = Json.parseToJsonElement(fields.getValue("bandwidths")).jsonArray.single().jsonObject
                else -> error("Unexpected synthetic write")
            }
            return buildJsonObject {}
        }
        if (api == FILE_SETTINGS_API) { gate?.await(10, TimeUnit.SECONDS); if (readFailure) throw IOException("synthetic settings read failure"); return general }
        return when (api) {
            FILE_SETTINGS_PRINCIPAL_API -> {
                val user = method == "list_user"
                val rows = if (!user) listOf(accountRow(20, false)) else if (policyCount == 2) listOf(accountRow(0, true, true), accountRow(12, true))
                    else (1..policyCount).map { JsonObject(accountRow(it.toLong(), true) + ("name" to JsonPrimitive("Synthetic user $it"))) }
                page(fields, if (user) "users" else "groups", rows)
            }
            FILE_MOUNT_USER_API -> if (fields["content"] == "user_enabled_type") buildJsonObject { put("user_enabled_type", scopeValue) }
                else page(fields, "usergrp_settings", if (emptyAccounts) emptyList() else listOf(accountRow(if (fields["usergroup"] == "user") 12 else 20, fields["usergroup"] == "user", mount = true)))
            FILE_DIRECTORY_LDAP_API -> buildJsonObject { put("enable_client", true) }
            FILE_DIRECTORY_DOMAIN_API -> when (method) {
                "get" -> buildJsonObject { put("enable_domain", true) }; "test_dc" -> buildJsonObject { put("test_join_success", true) }
                else -> buildJsonObject { putJsonArray("domain_list") { add(JsonArray(listOf(JsonPrimitive("Directory display"), JsonPrimitive("DIRECTORY-REQUEST"), JsonPrimitive("Synthetic")))) } }
            }
            FILE_BANDWIDTH_API -> page(fields, "bandwidths", listOf(rate ?: buildJsonObject {
                put("name", "Synthetic user"); put("protocol", "FileStation"); put("owner_type", fields.getValue("owner_type")); put("policy", "notexist"); put("schedule_plan", "")
                for (key in listOf("upload_limit_1", "download_limit_1", "upload_limit_2", "download_limit_2")) put(key, 0)
            }))
            "SYNO.FileStation.List" -> buildJsonObject { put("total", 0); put("offset", 0); putJsonArray("files") {}; putJsonArray("shares") {} }
            else -> error("Unexpected synthetic read")
        }
    }
    private fun accountRow(id: Long, user: Boolean, admin: Boolean = false, mount: Boolean = false) = buildJsonObject {
        put(if (user) "uid" else "gid", if (mount) JsonPrimitive(id.toString()) else JsonPrimitive(id))
        put("name", if (admin) "Administrator" else if (user) "Synthetic user" else "Synthetic group")
        put("is_admin", admin); put("enabled", accountEnabled); put("is_modifiable", !admin)
    }
    private fun page(fields: Map<String, String>, key: String, rows: List<JsonObject>): JsonObject {
        val query = fields["query"] ?: fields["substr"].orEmpty(); val matches = rows.filter { it.getValue("name").jsonPrimitive.content.contains(query, true) }
        val offset = fields.getValue("offset").toInt()
        return buildJsonObject { put("total", matches.size); put("offset", offset); put(key, JsonArray(matches.drop(offset).take(fields.getValue("limit").toInt()))) }
    }
    private fun capture(name: String) {
        if (InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") != "true") return
        compose.waitForIdle(); val instrumentation = InstrumentationRegistry.getInstrumentation(); instrumentation.uiAutomation.waitForIdle(150, 5_000)
        val drawn = CountDownLatch(1)
        instrumentation.runOnMainSync { val frames = android.view.Choreographer.getInstance(); frames.postFrameCallback { frames.postFrameCallback { drawn.countDown() } } }
        assertTrue(drawn.await(5, TimeUnit.SECONDS))
        val bitmap = instrumentation.uiAutomation.takeScreenshot(); val file = File(app.getExternalFilesDir(null), "file-settings-review/$name.png")
        file.parentFile?.mkdirs(); file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
}
