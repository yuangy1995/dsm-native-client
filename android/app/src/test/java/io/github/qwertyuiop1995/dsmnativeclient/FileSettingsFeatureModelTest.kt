package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileSettingsFixture
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FileSettingsFeatureModelTest {
    private val fixture = FileSettingsFixture()
    private var active: DsmRepository? = fixture.repository
    private var workspace = WorkspaceState(fixture.nas, availability = fixture.repository.availability(), selectedModule = Module.FILES)
    private fun model(scope: CoroutineScope) = FileSettingsFeatureModel(scope, { active }, { workspace }, { workspace = workspace.copy(isPerformingAction = it) })
    private suspend fun await(block: () -> Boolean) = withTimeout(5000) { while (!block()) delay(5) }
    private suspend fun general(model: FileSettingsFeatureModel) {
        assertTrue(model.open()); model.show(FileSettingsScreen.GENERAL)
        await { model.state.value.general is Loadable.Ready && model.state.value.recoveryReadable }
    }
    @Test fun themeReadFailureDoesNotInventDraftAndLayoutSaveUsesOneAction() = runBlocking {
        val model = model(this); fixture.before = { if (it["api"] == FILE_SHARING_THEME_API) throw IOException("synthetic") }
        assertTrue(model.open()); model.show(FileSettingsScreen.THEME); await { model.state.value.theme is Loadable.Failed }
        assertNull(model.state.value.themeDraft); assertFalse(model.canSave())
        fixture.before = {}; model.reload(); await { model.state.value.theme is Loadable.Ready }
        model.editTheme { it.copy(customLogo = true) }; assertFalse(model.canSave())
        model.editTheme { it.copy(customLogo = false, backgroundColor = "invalid") }; assertFalse(model.canSave())
        model.editTheme { it.copy(backgroundColor = "#123456", footer = "Synthetic footer") }; assertTrue(model.canSave())
        model.prepareSave(); model.prepareSave(); await { !model.state.value.busy && model.state.value.themeDraft?.footer == "Synthetic footer" && !model.canSave() }
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, model.state.value.outcome?.status); assertEquals(1, fixture.writes().size); model.invalidate()
    }
    @Test fun themeUnknownLocksOriginalPageAndCorePermissionRevocationClosesItsDraft() = runBlocking {
        val model = model(this); model.open(); model.show(FileSettingsScreen.THEME); await { model.state.value.theme is Loadable.Ready }
        fixture.applyWrites = false; model.editTheme { it.copy(footer = "new") }; model.prepareSave()
        await { !model.state.value.busy && model.pendingCurrent() }; model.close(); model.open(); model.show(FileSettingsScreen.THEME)
        await { model.state.value.theme is Loadable.Ready }; assertFalse(model.canEdit()); model.review(); await { !model.state.value.busy }
        assertEquals(1, fixture.writes().size)
        fixture.nasAllowed = false; fixture.repository.refreshAccess(); workspace = workspace.copy(availability = fixture.repository.availability())
        model.authorizationChanged(); assertNull(model.state.value.screen); model.invalidate()
    }
    @Test fun themeNasPickerUsesRawPageOffsetWhenOnlyLaterPageHasImages() = runBlocking {
        val model = model(this); model.open(); model.show(FileSettingsScreen.THEME); await { model.state.value.theme is Loadable.Ready }
        val cache = java.nio.file.Files.createTempDirectory("theme-model").toFile()
        fixture.overrideResponse = { fields -> if (fields["api"] == "SYNO.FileStation.List") {
            val offset = fields.getValue("offset").toInt()
            buildJsonObject { put("offset", offset); put("total", 201); putJsonArray("shares") {
                for (index in offset until minOf(offset + 200, 201)) add(buildJsonObject {
                    put("path", "/synthetic/$index.${if (index == 200) "png" else "txt"}"); put("name", "$index.${if (index == 200) "png" else "txt"}"); put("isdir", false)
                })
            } }
        } else null }
        try {
            model.themePicker.open(FileThemeImageKind.LOGO, cache, 800); model.themePicker.source(FileThemePickerSource.NAS)
            await { model.themePicker.state.value.rows is Loadable.Ready }
            assertTrue((model.themePicker.state.value.rows as Loadable.Ready).value.isEmpty()); assertEquals(200, model.themePicker.state.value.nextOffset)
            model.themePicker.more(); model.themePicker.more(); await { !model.themePicker.state.value.loadingMore }
            assertEquals("200.png", (model.themePicker.state.value.rows as Loadable.Ready).value.single().name)
            assertEquals(1, fixture.calls.count { it["api"] == "SYNO.FileStation.List" && it["offset"] == "200" })
            model.themePicker.source(FileThemePickerSource.LOCAL); val ticket = model.themePicker.selectionTicket(); assertNotNull(ticket)
            model.themePicker.source(FileThemePickerSource.HISTORY); assertNull(model.themePicker.selectionTicket())
            model.themePicker.close(); model.themePicker.open(FileThemeImageKind.LOGO, cache, 800); model.themePicker.source(FileThemePickerSource.LOCAL)
            assertNotEquals(ticket, model.themePicker.selectionTicket())
            val newModel = model(this); newModel.open(); newModel.show(FileSettingsScreen.THEME); await { newModel.state.value.theme is Loadable.Ready }
            newModel.themePicker.open(FileThemeImageKind.LOGO, cache, 800); newModel.themePicker.source(FileThemePickerSource.LOCAL)
            assertNotEquals(model.themePicker.selectionTicket(), newModel.themePicker.selectionTicket()); newModel.invalidate()
            model.invalidate(); assertNull(model.themePicker.state.value.kind)
        } finally { model.invalidate(); cache.deleteRecursively() }
    }
    @Test fun generalLoadFailureDoesNotCreateDraftAndOrdinarySaveRequiresOneButton() = runBlocking {
        val model = model(this); fixture.before = { if (it["api"] == FILE_SETTINGS_API) throw IOException("synthetic") }
        assertTrue(model.open()); model.show(FileSettingsScreen.GENERAL); await { model.state.value.general is Loadable.Failed }
        assertNull(model.state.value.generalDraft); assertFalse(model.canSave())
        fixture.before = {}; model.reload(); await { model.state.value.general is Loadable.Ready }
        assertFalse(model.canSave()); model.editGeneral { it.copy(recordsTransfers = true) }; assertTrue(model.canSave())
        model.prepareSave(); model.prepareSave(); await { !model.state.value.busy && model.state.value.generalDraft?.recordsTransfers == true && !model.canSave() }
        assertNull(model.state.value.confirmation); assertEquals(FileSettingsOutcomeStatus.COMPLETED, model.state.value.outcome?.status)
        assertEquals(1, fixture.writes().size); model.invalidate()
    }
    @Test fun broaderAccessNeedsExplicitRiskConfirmationAndChangedDraftInvalidatesIt() = runBlocking {
        val model = model(this); general(model)
        model.editGeneral { it.copy(sharing = FileSettingsScope.EVERYONE) }; model.prepareSave()
        assertEquals(setOf(FileSettingsRisk.SHARING), model.state.value.confirmation?.risks()); assertTrue(fixture.writes().isEmpty())
        model.editGeneral { it.copy(sharing = FileSettingsScope.SELECTED) }; assertNull(model.state.value.confirmation)
        model.submit(); assertTrue(fixture.writes().isEmpty())
        model.prepareSave(); model.submit(); await { !model.state.value.busy && model.state.value.generalDraft?.sharing == FileSettingsScope.SELECTED }
        assertEquals(1, fixture.writes().size); model.invalidate()
    }
    @Test fun policySelectionPreservesDraftAndCannotChangeAdministratorOrUnloadedRows() = runBlocking {
        val model = model(this); general(model); model.linkLimit("27"); model.editGeneral { it.copy(sharing = FileSettingsScope.SELECTED) }
        model.openPolicyAccounts(false); await { model.state.value.policyAccounts is Loadable.Ready }
        val rows = (model.state.value.policyAccounts as Loadable.Ready).value.items
        model.togglePolicyAccount(rows.first()); assertTrue(model.state.value.generalDraft!!.sharingAccounts.isEmpty())
        model.togglePolicyAccount(rows.last()); assertEquals(setOf(rows.last().id), model.state.value.generalDraft!!.sharingAccounts)
        model.togglePolicyAccount(rows.last().copy(name = "Unloaded")); assertEquals(1, model.state.value.generalDraft!!.sharingAccounts.size)
        model.back(); assertEquals(FileSettingsScreen.GENERAL, model.state.value.screen); assertEquals("27", model.state.value.linkLimit)
        model.prepareSave(); model.submit(); await { !model.state.value.busy && (model.state.value.general as? Loadable.Ready)?.value?.defaultLinkLimit == 27 }
        assertEquals("12", fixture.writes().single()["enabled_sharing_privilege"]); model.invalidate()
    }
    @Test fun unknownSaveRemainsReadonlyAfterReopenAndOtherSectionsStillWork() = runBlocking {
        val model = model(this); general(model); fixture.applyWrites = false
        model.editGeneral { it.copy(recordsTransfers = true) }; model.prepareSave()
        await { !model.state.value.busy && model.state.value.outcome != null }
        assertTrue(model.pendingCurrent()); assertFalse(model.canEdit()); model.close(); general(model)
        assertTrue(model.pendingCurrent()); assertFalse(model.canSave()); model.review(); await { !model.state.value.busy }
        assertEquals(1, fixture.writes().size)
        fixture.applyWrites = true; model.show(FileSettingsScreen.MOUNT_SCOPE); await { model.state.value.mountScope is Loadable.Ready }
        model.mountScope(FileMountScope.EVERYONE); model.prepareSave(); model.submit(); await { !model.state.value.busy && model.state.value.mountDraft == FileMountScope.EVERYONE }
        assertEquals(2, fixture.writes().size); assertEquals(1, model.state.value.pending.size); model.invalidate()
    }
    @Test fun numericDraftAndUnconfiguredBandwidthCannotSilentlyBecomeZeroOrUnlimited() = runBlocking {
        val model = model(this); general(model); model.editGeneral { it.copy(recordsTransfers = true) }; model.linkLimit("")
        assertFalse(model.canSave()); model.linkLimit("x"); assertEquals("", model.state.value.linkLimit)
        model.show(FileSettingsScreen.BANDWIDTH); await { model.state.value.bandwidth is Loadable.Ready }
        val row = (model.state.value.bandwidth as Loadable.Ready).value.items.single(); model.editBandwidth(row)
        assertEquals(FileBandwidthPolicy.UNCONFIGURED, model.state.value.bandwidthDraft?.policy); assertFalse(model.canSave())
        model.bandwidthDraft { it.copy(policy = FileBandwidthPolicy.ENABLED) }; model.rate(0, "9"); assertFalse(model.canSave())
        model.rate(0, "10"); assertTrue(model.canSave()); model.prepareSave()
        await { !model.state.value.busy && model.state.value.screen == FileSettingsScreen.BANDWIDTH && model.state.value.bandwidth is Loadable.Ready }
        assertEquals(FileBandwidthPolicy.ENABLED, (model.state.value.bandwidth as Loadable.Ready).value.items.single().policy)
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, model.state.value.outcome?.status)
        assertEquals(1, fixture.writes().size); model.invalidate()
    }
    @Test fun mountAccountOriginAndLockedAccountRemainBoundToCurrentSelection() = runBlocking {
        val model = model(this); assertTrue(model.open()); model.show(FileSettingsScreen.MOUNT_SCOPE); await { model.state.value.mountScope is Loadable.Ready }
        model.openMountAccounts(); await { model.state.value.mountAccounts is Loadable.Ready }
        val domain = (model.state.value.directories as Loadable.Ready).value.items.last().source
        model.source(domain); await { !model.state.value.loadingMore && (model.state.value.mountAccounts as? Loadable.Ready)?.value?.items?.singleOrNull()?.source == domain }
        val row = (model.state.value.mountAccounts as Loadable.Ready).value.items.single(); model.editMountAccount(row)
        model.accountEnabled(true); model.prepareSave(); assertNotNull(model.state.value.confirmation); assertTrue(fixture.writes().isEmpty())
        model.submit(); await { !model.state.value.busy && model.state.value.screen == FileSettingsScreen.MOUNT_ACCOUNTS && model.state.value.mountAccounts is Loadable.Ready }
        assertTrue((model.state.value.mountAccounts as Loadable.Ready).value.items.single().enabled)
        assertEquals(1, fixture.writes().size); model.invalidate()
    }
    @Test fun pagingDetectsChangedTotalAndSearchReturnsValidEmptyResult() = runBlocking {
        val model = model(this); general(model)
        fixture.users = (1L..201L).map { FileSettingsFixture.policyRow(it, "Synthetic $it", false) }
        model.openPolicyAccounts(false); await { model.state.value.policyAccounts is Loadable.Ready }
        assertEquals(200, (model.state.value.policyAccounts as Loadable.Ready).value.items.size)
        fixture.users = fixture.users + FileSettingsFixture.policyRow(202, "Synthetic 202", false)
        model.more(); model.more(); await { !model.state.value.loadingMore }
        assertNotNull(model.state.value.nextPageFailure); assertEquals(200, (model.state.value.policyAccounts as Loadable.Ready).value.items.size)
        assertEquals(1, fixture.calls.count { it["method"] == "list_user" && it["offset"] == "200" })
        model.query("Absent"); model.search(); await { model.state.value.policyAccounts is Loadable.Ready }
        assertTrue((model.state.value.policyAccounts as Loadable.Ready).value.items.isEmpty()); model.invalidate()
    }
    @Test fun revokedAccessClearsConfirmationAndLateReadCannotRestorePreviousAccount() = runBlocking {
        val model = model(this); general(model); model.editGeneral { it.copy(sharing = FileSettingsScope.EVERYONE) }; model.prepareSave()
        fixture.allowed = false; fixture.repository.refreshAccess(); model.authorizationChanged(); assertNull(model.state.value.screen)
        model.submit(); assertTrue(fixture.writes().isEmpty())
        fixture.allowed = true; fixture.repository.refreshAccess(); workspace = workspace.copy(availability = fixture.repository.availability())
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it["api"] == FILE_SETTINGS_API) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        model.open(); model.show(FileSettingsScreen.GENERAL)
        withContext(Dispatchers.IO) { assertTrue(entered.await(5, TimeUnit.SECONDS)) }
        active = null; model.invalidate(); release.countDown(); coroutineContext[Job]!!.children.toList().forEach { it.join() }
        assertNull(model.state.value.generalDraft); assertNull(model.state.value.screen); assertTrue(fixture.writes().isEmpty())
    }
}
