package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.CrossNasTransferEndpoint
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.CrossNasFixture
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class CrossNasTransferFeatureModelTest {
    @Test fun copyAndMoveUseDistinctActionsAndEveryRemovalNeedsConfirmation() = runBlocking {
        val f = CrossNasFixture(); var busy = false; var created = 0
        val model = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { true }, { busy = it }, { created++ }, {}, f.queue)
        val item = f.source.file("/source/a.bin")
        assertTrue(model.start(f.target, listOf(item), f.target.items.getValue("/target"), true, "Source", "Target"))
        assertTrue(busy); assertFalse(model.start(f.target, listOf(item), f.target.items.getValue("/target"), true, "Source", "Target"))
        waitFor { !model.state.value.busy }
        assertEquals(1, created); assertEquals(CrossNasPhase.COPIED, model.state.value.selected?.phase); assertTrue(f.source.deletions.isEmpty())
        model.confirmRemoval(); assertTrue(f.source.deletions.isEmpty())
        model.requestRemoval(); assertTrue(model.state.value.confirmRemoval); model.dismissRemoval(); model.confirmRemoval()
        assertTrue(f.source.deletions.isEmpty()); model.requestRemoval(); model.confirmRemoval(); model.confirmRemoval()
        waitFor { !model.state.value.busy }
        assertEquals(CrossNasPhase.FINISHED, model.state.value.selected?.phase); assertEquals(1, f.source.deletions.size); assertFalse(busy)
        model.invalidate()
    }
    @Test fun failedPlanStaysVisibleAndLeavesOriginalPickerAvailable() = runBlocking {
        val f = CrossNasFixture(); val file = f.source.file("/source/a.bin"); f.target.file("/target/a.bin")
        var created = 0
        val model = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { true }, {}, { created++ }, {}, f.queue)
        model.start(f.target, listOf(file), f.target.items.getValue("/target"), false, "Source", "Target")
        waitFor { !model.state.value.busy }
        assertTrue(model.state.value.visible); assertNotNull(model.state.value.failure); assertEquals(0, created)
        assertTrue((model.state.value.records as Loadable.Ready).value.isEmpty()); assertEquals(0, f.target.uploads)
        model.dismiss(); assertFalse(model.state.value.visible); model.invalidate()
    }
    @Test fun recreatedModelLoadsUnknownTaskAndRefreshOnlyReads() = runBlocking {
        val f = CrossNasFixture(); f.target.failUploadAfterWrite = true
        fun feature() = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { true }, {}, {}, {}, f.queue)
        val first = feature(); first.start(f.target, listOf(f.source.file("/source/a.bin")), f.target.items.getValue("/target"), true, "Source", "Target")
        waitFor { !first.state.value.busy }; val id = first.state.value.selectedId!!
        assertTrue(first.state.value.selected!!.hasUnknown); first.invalidate()
        val restored = feature(); restored.show(id); waitFor { !restored.state.value.reading }
        restored.continueCopy(); assertEquals(1, f.target.uploads)
        restored.refresh(); waitFor { !restored.state.value.reading }
        assertEquals(CrossNasPhase.COPIED, restored.state.value.selected?.phase); assertEquals(1, f.target.uploads)
        assertTrue(f.source.deletions.isEmpty()); restored.invalidate()
    }
    @Test fun pauseRetainsUnknownAndCannotAutomaticallyResumeIt() = runBlocking {
        val f = CrossNasFixture(); f.target.delayUploadMillis = 20
        val opened = CompletableDeferred<Unit>(); f.target.beforeUpload = { opened.complete(Unit) }
        val model = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { true }, {}, {}, {}, f.queue)
        model.start(f.target, listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))), f.target.items.getValue("/target"), false, "Source", "Target")
        withTimeout(5_000) { opened.await() }; model.pause(); waitFor { !model.state.value.busy }
        assertTrue(model.state.value.selected!!.hasUnknown); model.continueCopy(); assertEquals(1, f.target.uploads); model.invalidate()
    }
    @Test fun revokedAccountCancelsWorkAndLateCallbacksCannotReopenDetails() = runBlocking {
        val f = CrossNasFixture(); var allowed = true; var active: CrossNasTransferEndpoint = f.source
        val entered = CompletableDeferred<Unit>(); f.target.delayUploadMillis = 20; f.target.beforeUpload = { entered.complete(Unit) }
        val model = CrossNasTransferFeatureModel(this, f.store, { active }, { f.target }, { allowed }, {}, {}, {}, f.queue)
        model.start(f.target, listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))), f.target.items.getValue("/target"), true, "Source", "Target")
        withTimeout(5_000) { entered.await() }; allowed = false; model.authorizationChanged()
        active = CrossNasFixture.Endpoint("another"); delay(30)
        assertFalse(model.state.value.visible); assertFalse(model.state.value.busy); assertNull(model.state.value.selectedId)
        assertTrue(f.source.deletions.isEmpty())
    }
    @Test fun permissionLossDuringWriteClearsBusyEvenBeforeTheWorkspaceObserverRuns() = runBlocking {
        val f = CrossNasFixture(); var allowed = true; var busy = false
        f.target.afterUpload = { f.source.access = false; allowed = false }
        val model = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { allowed }, { busy = it }, {}, {}, f.queue)
        model.start(f.target, listOf(f.source.file("/source/a.bin")), f.target.items.getValue("/target"), true, "Source", "Target")
        waitFor { !busy }
        assertFalse(model.state.value.visible); assertFalse(model.state.value.busy); assertNull(model.state.value.selected)
        assertTrue(f.store.records(f.source.owner).single().hasUnknown); assertTrue(f.source.deletions.isEmpty())
        model.invalidate()
    }
    @Test fun systemDenialPreventsAnyCrossNasWriteAndLeavesSourceUntouched() = runBlocking {
        val f = CrossNasFixture(); val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture().apply { denied = true }
        val model = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { true }, {}, {}, {}, f.queue, execution = execution)
        model.start(f.target, listOf(f.source.file("/source/a.bin")), f.target.items.getValue("/target"), true, "Source", "Target")
        waitFor { !model.state.value.busy }; assertEquals(0, f.target.uploads); assertTrue(f.source.deletions.isEmpty())
        assertEquals(io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.BACKGROUND_EXECUTION_UNAVAILABLE, model.state.value.failure?.kind)
        assertTrue(f.store.records(f.source.owner).isEmpty()); model.invalidate()
    }
    @Test fun systemExpirationStopsOriginalUploadAndLeavesUnknownForReadOnlyRecovery() = runBlocking {
        val f = CrossNasFixture(); val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture()
        val model = CrossNasTransferFeatureModel(this, f.store, { f.source }, { f.target }, { true }, {}, {}, {}, f.queue, execution = execution)
        val entered = CompletableDeferred<Unit>(); f.target.delayUploadMillis = 20; f.target.beforeUpload = { entered.complete(Unit) }
        model.start(f.target, listOf(f.source.file("/source/a.bin", ByteArray(1024 * 1024))), f.target.items.getValue("/target"), true, "Source", "Target")
        entered.await(); execution.leases.single().expire(); waitFor { !model.state.value.busy }
        assertTrue(model.state.value.selected!!.hasUnknown); assertTrue(f.source.deletions.isEmpty())
        assertEquals(1, execution.leases.single().finishes); model.continueCopy(); assertEquals(1, f.target.uploads); model.invalidate()
    }
    private suspend fun waitFor(condition: () -> Boolean) = withTimeout(5_000) { while (!condition()) delay(5) }
}
