package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.SystemFileSettingsContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import org.junit.*
import org.junit.Assert.*

class SystemFileSettingsUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val store = SystemDocumentStore(app)
    private val previous = profiles.lastProfileId()
    private val fixture = SystemFileFixture()
    private lateinit var model: AppViewModel
    private lateinit var host: WorkspaceHostModel
    private lateinit var repository: DsmRepository
    @Before fun prepare() {
        val owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        val repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        repository = repo
        compose.runOnIdle {
            host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(fixture.profile.id, attemptRestore = false)); model = host.active.value.model
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(fixture.profile, availability = repo.availability(), selectedModule = Module.SETTINGS))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.SETTINGS))
        }
    }
    @After fun cleanup() { store.removeProfile(fixture.profile.id); profiles.removeProfile(fixture.profile.id); profiles.setLastProfileId(previous) }
    private fun text(id: Int) = compose.activity.getString(id)
    private fun idle() = compose.waitUntil(8_000) { !host.systemFiles.state.value.busy && host.systemFiles.state.value.rows is Loadable.Ready }
    @Test fun settingsEntryReadOnlyEnableAndSeparateEditingConfirmation() {
        compose.onNodeWithText(text(R.string.system_files_title)).performScrollTo().performClick(); idle()
        val enable = "system_files_enable_${fixture.profile.id}"
        val edit = "system_files_edit_${fixture.profile.id}"
        compose.onNodeWithTag(enable).assertIsOff().assertHeightIsAtLeast(48.dp).performClick(); idle()
        assertFalse(store.locations().single { it.owner.profileId == fixture.profile.id }.editing)
        compose.onNodeWithTag(edit).performScrollTo().assertIsOff().performClick()
        compose.onNodeWithTag("system_files_confirm_edit").assertExists()
        captureSystemIntegration(compose.activity, "files-edit-confirmation")
        compose.onNode(hasText(text(R.string.cancel)) and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
        compose.onNodeWithTag(edit).assertIsOff().performClick()
        compose.onNodeWithTag("system_files_confirm_edit").performClick(); idle()
        compose.onNodeWithTag(edit).assertIsOn()
        captureSystemIntegration(compose.activity, "files-enabled")
        compose.onNodeWithText(text(R.string.system_files_edit_hint)).assertExists()
        compose.onNodeWithTag(enable).performScrollTo().performClick(); idle()
        assertFalse(store.locations().single { it.owner.profileId == fixture.profile.id }.enabled)
        assertFalse(store.locations().single { it.owner.profileId == fixture.profile.id }.editing)
    }
    @Test fun systemDocumentPickerSelectsTheRegisteredNasAndReadsChosenFile() {
        compose.onNodeWithText(text(R.string.system_files_title)).performScrollTo().performClick(); idle()
        compose.onNodeWithTag("system_files_enable_${fixture.profile.id}").performClick(); idle()
        fixture.entries["/share/document.docx"] = SystemFileFixture.item("/share/document.docx")
        val location = store.locations().single { it.owner.profileId == fixture.profile.id }
        val share = store.document(location, "/share", true)
        val authority = app.packageName + ".documents"
        val field = NasDocumentsProvider::class.java.getDeclaredField("runtime\$delegate").apply { isAccessible = true }
        val provider = app.contentResolver.acquireContentProviderClient(authority)!!.use { it.localContentProvider as NasDocumentsProvider }
        val previousRuntime = field.get(provider)
        field.set(provider, lazyOf(SystemDocumentRuntime(store, profiles, { repository }, io.github.qwertyuiop1995.dsmnativeclient.data.files.OfficeDocumentStore(app))))
        val selected = java.util.concurrent.atomic.AtomicReference<android.net.Uri?>()
        var launcher: androidx.activity.result.ActivityResultLauncher<android.content.Intent>? = null
        try {
            compose.runOnIdle {
                host.systemFiles.hide()
                val registration = compose.activity.activityResultRegistry.register("synthetic-system-picker",
                    androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()) { result ->
                    if (result.resultCode == android.app.Activity.RESULT_OK) selected.set(result.data?.data)
                }
                launcher = registration
                registration.launch(android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(android.content.Intent.CATEGORY_OPENABLE); type = "*/*"
                    putExtra(android.provider.DocumentsContract.EXTRA_INITIAL_URI, android.provider.DocumentsContract.buildDocumentUri(authority, share.id))
                })
            }
            val automation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation
            fun find(node: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
                if (node == null) return null
                if (node.text?.toString() == "document.docx") return node
                for (index in 0 until node.childCount) find(node.getChild(index))?.let { return it }
                return null
            }
            compose.waitUntil(12_000) { find(automation.rootInActiveWindow) != null }
            var node = checkNotNull(find(automation.rootInActiveWindow))
            repeat(8) { if (!node.isClickable) node.parent?.let { node = it } }
            assertTrue(node.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
            compose.waitUntil(10_000) { selected.get() != null }
            val uri = checkNotNull(selected.get())
            val reference = store.document(android.provider.DocumentsContract.getDocumentId(uri))
            assertEquals(location.id, reference.locationId); assertEquals("/share/document.docx", reference.path)
            app.contentResolver.openInputStream(uri)!!.use { assertEquals("abc", it.reader().readText()) }
        } finally {
            launcher?.let { registration -> compose.runOnIdle { registration.unregister() } }
            field.set(provider, previousRuntime)
        }
    }
}

class SystemFileSettingsStateUiTest {
    @get:Rule val compose = androidx.compose.ui.test.junit4.createComposeRule()
    private val context get() = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
    @Test fun darkLargeTextFiveStatesAndBusySwitches() {
        val profile = NasProfile("synthetic-profile", "Synthetic NAS", "https://synthetic.example.invalid", "synthetic")
        val owner = WorkspaceOwner(profile.id, "identity", "session")
        val location = SystemFileLocation(owner = owner)
        val rows = listOf(SystemFileSetting(profile, location, true), SystemFileSetting(profile.copy(id = "second", name = "Second NAS"), null, false))
        var state by mutableStateOf(SystemFileSettingsState(visible = true, rows = Loadable.Loading))
        var retries = 0; var changes = 0
        compose.setContent { CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 2f)) {
            LanStashTheme(darkTheme = true) { SystemFileSettingsContent(state, {}, { retries++ }, { state = state.copy(filter = it) },
                { _, _ -> changes++ }, {}, { _, _ -> changes++ }) }
        } }
        compose.onNodeWithTag("system_files_settings").assertExists()
        compose.runOnIdle { state = state.copy(rows = Loadable.Ready(emptyList())) }
        compose.onNodeWithText(context.getString(R.string.system_files_empty)).assertExists()
        compose.runOnIdle { state = state.copy(rows = Loadable.Failed(DsmFailure(null, "synthetic", "retry", kind = DsmErrorKind.REQUEST_FAILED))) }
        compose.onNode(hasText(context.getString(R.string.retry)) and hasClickAction()).performClick(); assertEquals(1, retries)
        compose.runOnIdle { state = state.copy(rows = Loadable.Ready(rows)) }
        compose.onNodeWithText(profile.name).assertExists()
        compose.onNode(hasText(context.getString(R.string.system_files_find_connection)) and hasSetTextAction()).performTextInput("absent")
        compose.onNodeWithText(context.getString(R.string.system_files_no_matches)).assertExists()
        compose.onNode(hasText("absent") and hasSetTextAction()).performTextClearance()
        compose.onNodeWithTag("system_files_enable_${profile.id}").performScrollTo().assertHeightIsAtLeast(48.dp).assertIsOn()
        compose.onNodeWithContentDescription(context.getString(R.string.system_files_show_name, profile.name)).assertExists()
        compose.runOnIdle { state = state.copy(busy = true) }
        compose.onNodeWithTag("system_files_enable_${profile.id}").assertIsNotEnabled()
        compose.onNodeWithTag("system_files_edit_${profile.id}").performScrollTo().assertIsNotEnabled(); assertEquals(0, changes)
    }
}
