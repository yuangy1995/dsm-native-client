package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileBackgroundTaskFixture
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class FileBackgroundTaskFeatureModelTest {
    private val fixture = FileBackgroundTaskFixture()
    private var active: DsmRepository? = fixture.repository
    private var workspace = WorkspaceState(fixture.profile, availability = fixture.repository.availability(), selectedModule = Module.TRANSFERS)
    private var changes = 0
    private fun model(scope: CoroutineScope) = FileBackgroundTaskFeatureModel(scope, { active }, { workspace },
        { workspace = workspace.copy(isPerformingAction = it) }, { changes++ })
    private suspend fun await(block: () -> Boolean) = withTimeout(5000) { while (!block()) delay(5) }
    private suspend fun open(model: FileBackgroundTaskFeatureModel) {
        val page = fixture.repository.listFileBackgroundTasks(); workspace = workspace.copy(fileBackgroundTasks = Loadable.Ready(page))
        model.open(page.tasks.single()); await { model.state.value.detail is Loadable.Ready && model.state.value.pending is Loadable.Ready }
    }
    @Test fun detailsRequireLoadedTaskAndDestructiveConfirmationThenAllowSeparateClear() = runBlocking {
        val model = model(this); open(model)
        model.confirm(); assertTrue(fixture.writes().isEmpty()); model.prepare(FileBackgroundTaskAction.STOP)
        assertNotNull(model.state.value.confirmation); model.dismissConfirmation(); model.confirm(); assertTrue(fixture.writes().isEmpty())
        model.prepare(FileBackgroundTaskAction.STOP); model.confirm(); model.confirm(); await { !model.state.value.busy && changes == 1 }
        assertEquals(FileBackgroundTaskAction.STOP, model.state.value.completedAction); assertEquals(1, fixture.writes().size)
        assertFalse(model.canControl(FileBackgroundTaskAction.STOP)); assertTrue(model.canControl(FileBackgroundTaskAction.CLEAR))
        model.prepare(FileBackgroundTaskAction.CLEAR); model.confirm(); await { !model.state.value.busy && changes == 2 }
        assertEquals(FileBackgroundTaskAction.CLEAR, model.state.value.completedAction)
        assertNull((model.state.value.detail as Loadable.Ready).value); assertEquals(2, fixture.writes().size); model.invalidate()
    }
    @Test fun failedReadCannotOfferControlAndRetryLoadsActualDetails() = runBlocking {
        val page = fixture.repository.listFileBackgroundTasks(); workspace = workspace.copy(fileBackgroundTasks = Loadable.Ready(page))
        fixture.before = { throw IOException("Synthetic read failure") }; val model = model(this); model.open(page.tasks.single())
        await { model.state.value.detail is Loadable.Failed }; assertFalse(model.canControl(FileBackgroundTaskAction.STOP))
        model.prepare(FileBackgroundTaskAction.STOP); assertNull(model.state.value.confirmation)
        fixture.before = {}; model.reload(); await { model.state.value.detail is Loadable.Ready }
        assertTrue(model.canControl(FileBackgroundTaskAction.STOP)); model.invalidate()
    }
    @Test fun refreshingReusedTaskIdDoesNotKeepEarlierCompletionMessage() = runBlocking {
        val model = model(this); open(model); model.prepare(FileBackgroundTaskAction.STOP); model.confirm()
        await { !model.state.value.busy && model.state.value.completedAction == FileBackgroundTaskAction.STOP }
        fixture.rows = listOf(FileBackgroundTaskFixture.row(time = 1700000010.0)); model.reload()
        await { model.state.value.detail is Loadable.Ready }
        assertNull(model.state.value.completedAction); assertTrue(model.canControl(FileBackgroundTaskAction.STOP))
        assertEquals(1, fixture.writes().size); model.invalidate()
    }
    @Test fun unknownDisappearedTaskCanBeOpenedFromPersistedRecoveryAndRefreshNeverReplays() = runBlocking {
        val model = model(this); open(model); fixture.applyWrites = false
        model.prepare(FileBackgroundTaskAction.STOP); model.confirm(); await { !model.state.value.busy && model.pendingCurrent() != null }
        assertFalse(model.canControl(FileBackgroundTaskAction.STOP)); model.back(); fixture.rows = emptyList()
        model.openRecovery(); await { model.state.value.pending is Loadable.Ready }
        model.open((model.state.value.pending as Loadable.Ready).value.single()); await { model.state.value.detail is Loadable.Ready }
        assertNull((model.state.value.detail as Loadable.Ready).value); assertNotNull(model.pendingCurrent())
        model.reload(); await { model.state.value.detail is Loadable.Ready }; assertEquals(1, fixture.writes().size)
        fixture.rows = listOf(FileBackgroundTaskFixture.row(finished = true)); model.reload()
        await { model.state.value.completedAction == FileBackgroundTaskAction.STOP }; assertNull(model.pendingCurrent()); model.invalidate()
    }
    @Test fun revokedAccessClosesDetailsAndLateReadCannotReopenAnotherWorkspace() = runBlocking {
        val model = model(this); open(model); fixture.allowed = false; fixture.repository.refreshAccess()
        workspace = workspace.copy(availability = fixture.repository.availability()); model.authorizationChanged()
        assertNull(model.state.value.screen); assertFalse(model.canControl(FileBackgroundTaskAction.STOP))
        fixture.allowed = true; fixture.repository.refreshAccess(); workspace = workspace.copy(availability = fixture.repository.availability())
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        val page = (workspace.fileBackgroundTasks as Loadable.Ready).value
        model.open(page.tasks.single()); assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
        active = FileBackgroundTaskFixture(profileId = "different-account").repository
        model.invalidate(); release.countDown(); delay(30)
        assertNull(model.state.value.screen); assertTrue(fixture.writes().isEmpty())
    }
}
