package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.OkHttpClient
import org.junit.*
import org.junit.Assert.*

/** 正式 Activity、工作区、模型、加密记录和请求编码，仅远端响应使用合成数据。 */
class VmmWorkspaceUiTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app); private val previous = profiles.lastProfileId()
    private val fixture = VmmFixture(); private val creation = VmmCreationFixture(fixture)
    private val creationReply = fixture.responseOverride
    private val tasks = VmmTaskFixture(fixture); private val taskReply = fixture.responseOverride
    private val profile = fixture.profile
    private lateinit var model: AppViewModel
    private lateinit var owner: WorkspaceOwner

    @Before fun prepare() {
        fixture.responseOverride = { call -> when {
            call.api == "SYNO.Virtualization.API.Task.Info" && call.method == "get" && call.fields["task_id"]?.jsonPrimitive?.content == creation.taskId -> creationReply(call)
            call.api in setOf("SYNO.Virtualization.API.Storage", "SYNO.Virtualization.API.Task.Info", "SYNO.FileStation.List") ||
                call.api == "SYNO.Virtualization.API.Guest.Image" && call.method == "create" -> taskReply(call)
            else -> creationReply(call)
        } }
        val session = DsmSession(profile.id, "synthetic-session")
        owner = profiles.commitConnection(profiles.connectionAttempt(profile.id), profile, session, null, false)
        compose.runOnIdle {
            val host = ViewModelProvider(compose.activity)[WorkspaceHostModel::class.java]
            assertTrue(host.select(profile.id, attemptRestore = false)); model = host.active.value.model
            val caps = fixture.capabilities()
            val repo = DsmRepository(profile, session, DsmApiClient(OkHttpClient.Builder().retryOnConnectionFailure(false).addInterceptor(fixture).build()), caps, fixture.reader(caps))
            runBlocking { repo.refreshAccess() }; repo.bindOwner(owner) { profiles.requireCurrentOwner(owner) }
            AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply { isAccessible = true }.invoke(model, repo)
            ApprovedUiFixture.setState(model, WorkspaceState(profile, availability = repo.availability(), selectedModule = Module.SETTINGS,
                supportsOfficialVirtualMachineCreation = true, supportsOfficialVirtualMachineSettings = true, supportsOfficialVirtualMachineImageImport = true))
            model.navigateTo(WorkspaceRoute.ModuleRoot(Module.VIRTUAL_MACHINES))
        }
        ready(); awaitText(text(R.string.images))
        if (captureEnabled()) {
            val c = compose.activity.resources.configuration
            File(app.getExternalFilesDir(null), "vmm-review/configuration.txt").also { it.parentFile?.mkdirs() }
                .writeText("locales=${c.locales.toLanguageTags()}\nfontScale=${c.fontScale}\nuiMode=${c.uiMode}\nwidthDp=${c.screenWidthDp}\nheightDp=${c.screenHeightDp}\n")
        }
    }
    @After fun clean() {
        if (::model.isInitialized) compose.runOnIdle { model.vmmTasks.clear(); model.vmmCreation.clear(); model.vmmSettings.clear(); model.vmmAssets.clear(); model.vmmControls.clear(); model.vmmConsole.clear(); model.selectVirtualMachineTab(VirtualMachineTab.MACHINES) }
        compose.waitForIdle()
        VmmControlStore(app).removeProfile(profile.id); VmmAssetStore(app).removeProfile(profile.id); VmmSettingsStore(app).removeProfile(profile.id)
        VmmCreationStore(app).removeProfile(profile.id); VmmTaskStore(app).removeProfile(profile.id)
        TransferStore(app).removeProfile(profile.id); profiles.removeProfile(profile.id); profiles.setLastProfileId(previous)
    }
    @Test fun controlCancelThenStartShutdownPowerOffAndDelete() {
        click(R.string.virtual_machines); awaitControls(); detail("Synthetic VM"); click(R.string.vm_start); capture("control-confirmation"); click(R.string.cancel)
        assertTrue(fixture.writes.isEmpty())
        control(R.string.vm_start); awaitControlDone(); capture("control-running")
        control(R.string.vm_stop); awaitControlDone()
        control(R.string.vm_start); awaitControlDone(); control(R.string.vm_poweroff); awaitControlDone()
        control(R.string.vm_delete); awaitControlDone(); awaitText(text(R.string.vm_empty)); capture("control-empty")
        assertEquals(listOf("poweron", "shutdown", "poweron", "poweroff", "delete"), fixture.writes.map { it.method })
        assertTrue(fixture.writes.all { it.oneShot })
    }
    @Test fun batchUnknownKeepsSecondUnsentAndRestoresWithoutReplay() {
        fixture.guests = listOf(VmmFixture.guest(), VmmFixture.guest("second", "Second VM"))
        click(R.string.virtual_machines); compose.runOnIdle { model.vmmControls.refresh() }; awaitControls()
        compose.onNodeWithContentDescription("Synthetic VM").performClick(); compose.onNodeWithContentDescription("Second VM").performClick()
        click(R.string.vm_start); fixture.after = { if (it.method == "poweron") throw IOException("Synthetic lost receipt") }; click(R.string.vm_start)
        await { !model.vmmControls.state.value.busy && model.vmmControls.state.value.record?.pending == true }
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), model.vmmControls.state.value.record!!.items.map { it.stage })
        capture("control-unknown"); fixture.after = {}
        compose.runOnIdle { model.vmmControls.clear(); model.vmmControls.refresh() }; awaitControls()
        detail("Synthetic VM"); button(R.string.vm_stop).assertIsNotEnabled(); assertEquals(1, fixture.writes.size); capture("control-restored")
    }
    @Test fun settingsRenameHardwareStartupAndInternalPriorityRoundTrip() {
        click(R.string.virtual_machines); awaitControls(); detail("Synthetic VM"); click(R.string.edit_virtual_machine); awaitSettings()
        field(R.string.virtual_machine_name).performTextReplacement("Renamed VM")
        field(R.string.virtual_machine_description).performTextReplacement("Updated synthetic description")
        field(R.string.virtual_machine_cpu).performScrollTo().performTextReplacement("4")
        field(R.string.virtual_machine_memory_mib).performScrollTo().performTextReplacement("2048")
        click(R.string.vm_startup_restore); click(R.string.vm_startup_on)
        capture("settings-form"); click(R.string.save_changes)
        await { !model.vmmSettings.state.value.busy && model.vmmSettings.state.value.records.any { it.stage == VmmStage.VERIFIED } }; ready(); awaitControls(); awaitText("Renamed VM")
        assertEquals(VmmSource.PUBLIC.guestApi, fixture.writes.single().api)
        detail("Renamed VM"); click(R.string.edit_virtual_machine); awaitSettings(); click(R.string.vm_priority_normal); click(R.string.vm_priority_high)
        click(R.string.save_changes); await { !model.vmmSettings.state.value.busy && model.vmmSettings.state.value.records.all { it.stage == VmmStage.VERIFIED } }
        assertEquals(VmmSource.INTERNAL.guestApi, fixture.writes.last().api); assertEquals(JsonPrimitive(512), fixture.writes.last().fields["cpu_weight"])
        capture("settings-complete")
    }
    @Test fun publicCreationPreservesMultipleDisksNetworksAndSeparatePowerOn() {
        click(R.string.virtual_machines); awaitControls(); click(R.string.create_virtual_machine); awaitCreation()
        field(R.string.virtual_machine_name).performTextInput("Created VM"); click(R.string.virtual_machine_next_step)
        click(R.string.virtual_machine_add_disk); assertEquals(2, model.vmmCreation.state.value.draft!!.disks.size)
        click(R.string.virtual_machine_next_step); click(R.string.virtual_machine_add_network)
        compose.onNode(hasText(text(R.string.vm_creation_power_on)) and hasClickAction()).performScrollTo().performClick()
        capture("creation-public-review"); click(R.string.create)
        await { !model.vmmCreation.state.value.busy && model.vmmCreation.state.value.records.singleOrNull()?.progress?.stage == VmmCreationStage.COMPLETE }
        assertEquals(listOf("create", "set", "poweron"), fixture.writes.map { it.method })
        assertEquals(2, fixture.writes.first().fields.getValue("vdisks").jsonArray.size); assertEquals(2, fixture.writes.first().fields.getValue("vnics").jsonArray.size)
        ready(); awaitControls(); awaitText("Created VM"); capture("creation-public-complete")
    }
    @Test fun internalTemplateCreationUsesRecordedTemplateAndOneWrite() {
        click(R.string.virtual_machines); awaitControls(); click(R.string.create_virtual_machine); awaitCreation()
        click(R.string.vm_creation_general); click(R.string.vm_creation_linux); awaitCreation()
        field(R.string.virtual_machine_name).performTextInput("Template VM"); click(R.string.virtual_machine_next_step)
        click(R.string.virtual_machine_next_step); capture("creation-template-review"); click(R.string.create)
        await { !model.vmmCreation.state.value.busy && model.vmmCreation.state.value.records.singleOrNull()?.progress?.stage == VmmCreationStage.COMPLETE }
        assertEquals(VmmSource.INTERNAL.guestApi, fixture.writes.single().api); assertEquals(JsonPrimitive("vmvga"), fixture.writes.single().fields["video_card"]); assertEquals(JsonPrimitive(1), fixture.writes.single().fields["vnics"]!!.jsonArray.single().jsonObject["vnic_type"])
        ready(); awaitControls(); awaitText("Template VM"); capture("creation-template-complete")
    }
    @Test fun networkRenameAndDeleteThenImageDeleteConfirmations() {
        click(R.string.networks); awaitAssets(VmmAssetKind.NETWORK); detail("Synthetic network"); click(R.string.vm_rename_network)
        field(R.string.network_name).performTextReplacement("Renamed network"); click(R.string.save); awaitAssetDone()
        detail("Renamed network"); click(R.string.delete); capture("network-delete-confirmation"); click(R.string.cancel)
        assertEquals(1, fixture.writes.size); detail("Renamed network"); click(R.string.delete); click(R.string.delete); awaitAssetDone(); awaitText(text(R.string.vm_network_empty))
        back(); click(R.string.images); awaitAssets(VmmAssetKind.IMAGE); detail("Synthetic image"); click(R.string.delete); capture("image-delete-confirmation"); click(R.string.delete)
        awaitAssetDone(); awaitText(text(R.string.vm_image_empty)); assertEquals(listOf("set", "delete", "delete"), fixture.writes.map { it.method })
        capture("assets-empty")
    }
    @Test fun nasImagePickerImportsAndRecreatedModelOnlyReadsOriginalTask() {
        click(R.string.images); awaitAssets(VmmAssetKind.IMAGE); click(R.string.virtual_machine_import_image)
        pickNasImage()
        field(R.string.virtual_machine_image_name).performTextReplacement("Imported from NAS"); capture("image-import-form")
        click(R.string.virtual_machine_image_import_confirm)
        await { !model.vmmTasks.state.value.busy && model.vmmTasks.state.value.imports.singleOrNull()?.progress?.stage == VmmStage.VERIFIED }
        awaitText(text(R.string.virtual_machine_image_imported), substring = true); ready(); capture("image-import-complete")
        assertEquals(1, fixture.writes.size); assertEquals("create", fixture.writes.single().method); assertTrue(tasks.tasks.containsKey(tasks.taskId))
        closeSheet(); compose.runOnIdle { model.vmmTasks.clear(); model.vmmTasks.refresh() }; await { !model.vmmTasks.state.value.busy && model.vmmTasks.state.value.loaded }
        assertEquals(1, fixture.writes.size); assertEquals(VmmStage.VERIFIED, model.vmmTasks.state.value.imports.single().progress.stage)
        ready(); awaitAssets(VmmAssetKind.IMAGE); awaitText("Imported from NAS")
    }
    @Test fun finishedTaskCleanupCancelThenPerItemReceiptAndReadback() {
        tasks.tasks["first"] = VmmTaskFixture.task(); tasks.tasks["second"] = VmmTaskFixture.task(); tasks.tasks["running"] = VmmTaskFixture.task(false)
        compose.runOnIdle { model.load(Module.VIRTUAL_MACHINES) }; ready(); click(R.string.virtual_machine_tasks)
        click(R.string.virtual_machine_clear_finished_tasks); await { model.vmmTasks.state.value.confirmation != null }; click(R.string.cancel); assertTrue(fixture.writes.isEmpty()); closeSheet()
        click(R.string.virtual_machine_clear_finished_tasks); await { model.vmmTasks.state.value.confirmation != null }; capture("task-cleanup-confirmation"); click(R.string.virtual_machine_clear_finished_tasks)
        await { !model.vmmTasks.state.value.busy && model.vmmTasks.state.value.cleanups.singleOrNull()?.pending == false }
        assertEquals(listOf(VmmStage.VERIFIED, VmmStage.VERIFIED), model.vmmTasks.state.value.cleanups.single().items.map { it.stage })
        assertEquals(setOf("running"), tasks.tasks.keys); assertEquals(listOf("clear", "clear"), fixture.writes.map { it.method }); ready(); capture("task-cleanup-complete")
    }

    @Test fun unfinishedLegacyLocalImportProtectsTaskCleanupAndDuplicateName() {
        TransferStore(app).upsertVirtualMachineImageImport(PersistedVirtualMachineImageImport(
            id = "synthetic-local-record", profileId = profile.id, sourceUri = "content://synthetic/image", sourceDisplayName = "Synthetic.img",
            expectedBytes = 1024, stagingDirectoryPath = "/synthetic", temporaryFileName = "synthetic-temp.img", imageName = "Unfinished image",
            imageType = PersistedVirtualMachineImageType.DISK, storageId = "storage-1", stage = PersistedVirtualMachineImageImportStage.FAILED,
            requiresRefresh = true, ownsPersistedReadGrant = false))
        compose.runOnIdle { assertTrue(model.vmmLocalImportsPending()); assertFalse(model.vmmTasks.requestCleanup()) }
        click(R.string.images); awaitAssets(VmmAssetKind.IMAGE); click(R.string.virtual_machine_import_image)
        pickNasImage()
        field(R.string.virtual_machine_image_name).performTextReplacement("Unfinished image"); click(R.string.virtual_machine_image_import_confirm)
        await { model.workspace.value?.message == text(R.string.vm_image_import_name_busy) }
        assertTrue(fixture.writes.isEmpty()); assertTrue(model.workspace.value!!.virtualMachineMutationState.imageImportEditorVisible)
        click(R.string.cancel)
    }

    private fun pickNasImage() {
        await { model.workspace.value?.virtualMachineMutationState?.imageImportDraft?.browserItems is Loadable.Ready }
        val form = compose.onNode(hasScrollToIndexAction() and hasAnyAncestor(isDialog()))
        form.performScrollToNode(hasText("Synthetic files")); detail("Synthetic files")
        await { model.workspace.value?.virtualMachineMutationState?.imageImportDraft?.let { it.browserPath == "/synthetic" && it.browserItems is Loadable.Ready } == true }
        form.performScrollToNode(hasText("source.img")); detail("source.img")
        form.performScrollToNode(hasText(text(R.string.virtual_machine_image_name)))
    }

    private fun ready() = await { model.workspace.value?.virtualMachines is Loadable.Ready && !model.vmmCreation.state.value.busy && !model.vmmSettings.state.value.busy && !model.vmmControls.state.value.busy && !model.vmmTasks.state.value.busy }
    private fun awaitControls() = await { model.vmmControls.state.value.loaded && !model.vmmControls.state.value.busy }
    private fun awaitSettings() = await { model.vmmSettings.state.value.editor && !model.vmmSettings.state.value.busy && model.vmmSettings.state.value.baseline != null }
    private fun awaitCreation() = await { model.vmmCreation.state.value.editor && !model.vmmCreation.state.value.busy && model.vmmCreation.state.value.resources != null }
    private fun awaitAssets(kind: VmmAssetKind) = await { !model.vmmAssets.state.value.busy && (if (kind == VmmAssetKind.IMAGE) model.vmmAssets.state.value.images != null else model.vmmAssets.state.value.networks != null) }
    private fun awaitControlDone() { await { !model.vmmControls.state.value.busy && model.vmmControls.state.value.record?.pending == false }; ready(); awaitControls() }
    private fun awaitAssetDone() { await { !model.vmmAssets.state.value.busy && model.vmmAssets.state.value.records.all { !it.pending } }; ready() }
    private fun await(condition: () -> Boolean) { compose.waitUntil(20_000, condition); compose.waitForIdle() }
    private fun text(id: Int) = compose.activity.getString(id)
    private fun awaitText(value: String, substring: Boolean = false) { compose.waitUntil(15_000) { compose.onAllNodesWithText(value, substring).fetchSemanticsNodes().isNotEmpty() }; compose.waitForIdle() }
    private fun button(id: Int) = compose.onNode(hasText(text(id)) and hasClickAction())
    private fun field(id: Int) = compose.onNode(hasText(text(id)) and hasSetTextAction())
    private fun click(id: Int) { val node = compose.onNode(hasText(text(id)) and hasClickAction() and isEnabled()); scroll(node); node.assertIsDisplayed().performClick() }
    private fun detail(value: String) { val node = compose.onNode(hasText(value) and hasClickAction()); scroll(node); node.performClick() }
    private fun closeSheet() = compose.onNodeWithContentDescription(text(R.string.close)).performClick()
    private fun control(id: Int) { detail("Synthetic VM"); click(id); click(id) }
    private fun back() = compose.onNode(hasContentDescription(text(R.string.go_up)) and hasAnySibling(hasText(text(R.string.networks)))).performClick()
    private fun scroll(node: SemanticsNodeInteraction) {
        var parent = node.fetchSemanticsNode().parent; var scrollable = false
        while (parent != null) { if (parent.config.contains(SemanticsActions.ScrollBy)) scrollable = true; parent = parent.parent }
        if (scrollable) node.performScrollTo()
    }
    private fun captureEnabled() = InstrumentationRegistry.getArguments().getString("captureWorkspaceUi") == "true"
    private fun capture(name: String) {
        if (!captureEnabled()) return
        compose.mainClock.advanceTimeBy(600); compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(200, 3_000)
        val rendered = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { compose.activity.window.decorView.postOnAnimation { compose.activity.window.decorView.postOnAnimation { rendered.countDown() } } }
        check(rendered.await(2, TimeUnit.SECONDS)); InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(app.getExternalFilesDir(null), "vmm-review/$name.png").also { it.parentFile?.mkdirs() }.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
