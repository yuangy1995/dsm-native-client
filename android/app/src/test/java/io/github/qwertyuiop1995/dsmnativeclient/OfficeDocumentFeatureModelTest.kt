package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.OfficeFixture
import io.github.qwertyuiop1995.dsmnativeclient.testing.OfficeEndpointFixture
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OfficeDocumentFeatureModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun fixture() = OfficeFixture(temporary.newFolder())
    @Test fun `opening downloads copy and saving requires a fresh explicit confirmation`() = runBlocking {
        val f = fixture(); var busy = false; var saved = 0
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { true }, { busy = it }, { saved++ })
        model.open(f.endpoint.current()); await { !model.state.value.busy }
        val row = model.state.value.selected!!; assertEquals(OfficeDocumentPhase.READY, row.phase); assertFalse(busy)
        f.transfer.importEdited(row.id, f.endpoint.owner, "copy.docx") { f.edited.inputStream() }
        model.refresh(); await { !model.state.value.busy }; model.save(); assertEquals(0, f.endpoint.writes)
        model.requestSave(); model.dismissConfirmation(); model.save(); assertEquals(0, f.endpoint.writes)
        model.requestSave(); model.save(); model.save(); await { !model.state.value.busy }
        assertEquals(OfficeDocumentPhase.SAVED, model.state.value.selected?.phase); assertEquals(1, f.endpoint.writes); assertEquals(1, saved)
        model.invalidate()
    }
    @Test fun `unknown save reopens without write and only explicit refresh checks content`() = runBlocking {
        val f = fixture(); val row = f.changed(); f.endpoint.applyUpload = false; f.endpoint.unknown = true
        f.transfer.save(row.id, f.endpoint, true)
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { true }, {}, {})
        model.show(); await { !model.state.value.busy }; model.select(row.id)
        assertEquals(1, f.endpoint.writes); model.requestSave(); model.save(); model.requestDiscard()
        assertFalse(model.state.value.confirmSave); assertFalse(model.state.value.confirmDiscard)
        f.endpoint.bytes = f.edited; model.refresh(); await { !model.state.value.busy }
        assertEquals(OfficeDocumentPhase.SAVED, model.state.value.selected?.phase); assertEquals(1, f.endpoint.writes)
        model.invalidate()
    }
    @Test fun `revocation clears busy and page even before access observer runs`() = runBlocking {
        val f = fixture(); val row = f.changed(); var allowed = true; var busy = false
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { allowed }, { busy = it }, {})
        model.show(); await { !model.state.value.busy }; model.select(row.id)
        f.endpoint.atWrite = { allowed = false; f.endpoint.granted = false }
        model.requestSave(); model.save(); await { !busy }
        assertFalse(model.state.value.visible); assertNull(model.state.value.selected)
        assertEquals(OfficeDocumentPhase.UNKNOWN, f.store.get(row.id).phase); assertEquals(1, f.endpoint.writes)
    }
    @Test fun `account change consumes no late system picker result`() = runBlocking {
        val f = fixture(); val row = f.changed(); var current: OfficeDocumentEndpoint = f.endpoint
        val model = OfficeDocumentFeatureModel(this, f.store, { error("A stale picker must never resolve") }, { current }, { true }, {}, {})
        model.show(); await { !model.state.value.busy }; model.select(row.id); model.requestPicker(OfficePickerKind.IMPORT)
        val old = model.state.value.picker!!.token
        current = OfficeEndpointFixture(f.original); model.authorizationChanged(); model.show(); await { !model.state.value.busy }
        model.pickerResult(old, null)
        assertTrue((model.state.value.records as Loadable.Ready).value.isEmpty()); assertNull(model.state.value.picker)
        assertEquals(0, f.endpoint.writes); model.invalidate()
    }
    @Test fun `switching selected record clears prior save confirmation`() = runBlocking {
        val f = fixture(); val first = f.changed(); f.endpoint.path = "/share/second.docx"; val second = f.changed()
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { true }, {}, {})
        model.show(); await { !model.state.value.busy }; model.select(first.id); model.requestSave()
        assertTrue(model.state.value.confirmSave); model.select(second.id); model.save()
        assertFalse(model.state.value.confirmSave); assertEquals(0, f.endpoint.writes); model.invalidate()
    }
    @Test fun `busy workspace prevents entering office and failed records remain retryable`() = runBlocking {
        val f = fixture(); var canStart = false
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { true }, {}, {}, { canStart })
        model.open(f.endpoint.current()); assertFalse(model.state.value.visible)
        f.preferences.edit().putString("office_v1_invalid", "invalid").commit(); canStart = true
        model.show(); await { !model.state.value.busy }; assertTrue(model.state.value.records is Loadable.Failed)
        f.preferences.edit().remove("office_v1_invalid").commit(); model.refresh(); await { !model.state.value.busy }
        assertTrue((model.state.value.records as Loadable.Ready).value.isEmpty()); assertEquals(0, f.endpoint.writes)
        model.invalidate()
    }
    @Test fun `系统拒绝文档准备和保存均不发出传输且保留副本`() = runBlocking {
        val f = fixture(); val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture().apply { denied = true }
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { true }, {}, {}, execution = execution)
        model.open(f.endpoint.current()); await { !model.state.value.busy }
        assertEquals(io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.BACKGROUND_EXECUTION_UNAVAILABLE, model.state.value.failure?.kind)
        assertTrue(f.store.records(f.endpoint.owner).isEmpty())
        val row = f.changed(); model.show(); await { !model.state.value.busy }; model.select(row.id)
        model.requestSave(); model.save(); await { !model.state.value.busy }
        assertEquals(0, f.endpoint.writes); assertEquals(OfficeDocumentPhase.CHANGED, f.store.get(row.id).phase)
        assertTrue(execution.leases.isEmpty()); model.invalidate()
    }
    @Test fun `文档准备和显式覆盖各自持有并释放系统租约`() = runBlocking {
        val f = fixture(); val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture()
        val model = OfficeDocumentFeatureModel(this, f.store, { error("No system IO") }, { f.endpoint }, { true }, {}, {}, execution = execution)
        model.open(f.endpoint.current()); await { !model.state.value.busy }
        val row = model.state.value.selected!!
        f.transfer.importEdited(row.id, f.endpoint.owner, "copy.docx") { f.edited.inputStream() }
        model.refresh(); await { !model.state.value.busy }; model.requestSave(); model.save(); await { !model.state.value.busy }
        assertEquals(1, f.endpoint.writes); assertEquals(listOf(f.endpoint.owner, f.endpoint.owner), execution.calls.map { it.first })
        assertEquals(listOf(1, 1), execution.leases.map { it.finishes }); model.invalidate()
    }
    private suspend fun await(condition: () -> Boolean) = withTimeout(5_000) { while (!condition()) delay(5) }
}
