package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.OfficeFixture
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

class OfficeDocumentTransferTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun fixture() = OfficeFixture(temporary.newFolder())

    @Test fun `unchanged import never uploads and original copy stays intact`() = runBlocking {
        val f = fixture(); val row = f.prepare()
        val unchanged = f.transfer.importEdited(row.id, f.endpoint.owner, "renamed.DOCX") { f.original.inputStream() }
        assertEquals(OfficeDocumentPhase.UNCHANGED, unchanged.phase)
        failure { f.transfer.save(row.id, f.endpoint, true) }
        assertEquals(0, f.endpoint.writes)
        assertArrayEquals(f.original, f.store.artifact(row.id, row.originalId).readBytes())
    }
    @Test fun `explicit save persists submission first and verifies full returned content`() = runBlocking {
        val f = fixture(); val row = f.changed()
        failure { f.transfer.save(row.id, f.endpoint, false) }; assertEquals(0, f.endpoint.writes)
        f.endpoint.atWrite = { assertEquals(OfficeDocumentPhase.SAVING, f.store.get(row.id).phase) }
        val saved = f.transfer.save(row.id, f.endpoint, true)
        assertEquals(OfficeDocumentPhase.SAVED, saved.phase)
        assertArrayEquals(f.edited, f.endpoint.bytes); assertEquals(1, f.endpoint.writes)
        f.transfer.refresh(row.id, f.endpoint); failure { f.transfer.save(row.id, f.endpoint, true) }
        assertEquals(1, f.endpoint.writes)
    }
    @Test fun `same size and timestamp with changed original bytes stops overwrite`() = runBlocking {
        val f = fixture(); val row = f.changed()
        f.endpoint.beforeSubmission = { f.endpoint.bytes = ByteArray(f.original.size) { 42 } }
        assertEquals(DsmErrorKind.OFFICE_CHANGED, failure { f.transfer.save(row.id, f.endpoint, true) }.kind)
        assertEquals(OfficeDocumentPhase.CONFLICT, f.store.get(row.id).phase); assertEquals(0, f.endpoint.writes)
        assertArrayEquals(f.edited, f.store.artifact(row.id, row.candidateId!!).readBytes())
    }
    @Test fun `unknown receipt with matching complete content confirms exactly one upload`() = runBlocking {
        val f = fixture(); val row = f.changed(); f.endpoint.unknown = true
        assertEquals(OfficeDocumentPhase.SAVED, f.transfer.save(row.id, f.endpoint, true).phase)
        assertEquals(1, f.endpoint.writes)
    }
    @Test fun `unknown mismatch restores read only and cannot discard import or replay`() = runBlocking {
        val f = fixture(); val row = f.changed(); f.endpoint.unknown = true; f.endpoint.applyUpload = false
        assertEquals(OfficeDocumentPhase.UNKNOWN, f.transfer.save(row.id, f.endpoint, true).phase)
        val restarted = OfficeDocumentTransfer(OfficeDocumentStore(f.preferences, f.root))
        assertEquals(OfficeDocumentPhase.UNKNOWN, restarted.refresh(row.id, f.endpoint).phase)
        failure { restarted.save(row.id, f.endpoint, true) }
        failure { f.store.discard(f.store.get(row.id)) }
        failure { restarted.importEdited(row.id, f.endpoint.owner, "copy.docx") { f.edited.inputStream() } }
        f.endpoint.bytes = f.edited
        assertEquals(OfficeDocumentPhase.SAVED, restarted.refresh(row.id, f.endpoint).phase)
        assertEquals(1, f.endpoint.writes)
    }
    @Test fun `cancellation after submission preserves unknown and local edited copy`() = runBlocking {
        val f = fixture(); val row = f.changed(); val entered = CompletableDeferred<Unit>()
        f.endpoint.atWrite = { entered.complete(Unit); awaitCancellation() }
        val task = launch { f.transfer.save(row.id, f.endpoint, true) }
        entered.await(); task.cancelAndJoin()
        assertEquals(OfficeDocumentPhase.UNKNOWN, f.store.get(row.id).phase)
        assertArrayEquals(f.edited, f.store.artifact(row.id, row.candidateId!!).readBytes())
        assertEquals(1, f.endpoint.writes)
    }
    @Test fun `failed durable write prevents upload and recovery cannot replay`() = runBlocking {
        val f = fixture(); val row = f.changed(); f.preferences.commitSucceeds = false
        failure { f.transfer.save(row.id, f.endpoint, true) }; assertEquals(0, f.endpoint.writes)
        f.preferences.commitSucceeds = true
        assertEquals(OfficeDocumentPhase.UNKNOWN, OfficeDocumentStore(f.preferences, f.root).records(f.endpoint.owner).single().phase)
        failure { f.transfer.save(row.id, f.endpoint, true) }; assertEquals(0, f.endpoint.writes)
    }
    @Test fun `other account and revoked write permission cannot save`() = runBlocking {
        val f = fixture(); val row = f.changed(); val owner = f.endpoint.owner
        f.endpoint.owner = owner.copy(identityRevision = "changed")
        assertTrue(f.store.records(f.endpoint.owner).isEmpty())
        failure { f.transfer.save(row.id, f.endpoint, true) }
        f.endpoint.owner = owner; f.endpoint.writable = false
        assertEquals(DsmErrorKind.PERMISSION_DENIED, failure { f.transfer.save(row.id, f.endpoint, true) }.kind)
        assertEquals(0, f.endpoint.writes); assertEquals(OfficeDocumentPhase.CHANGED, f.store.get(row.id).phase)
    }
    @Test fun `duplicate save while writing is rejected across store instances`() = runBlocking {
        val f = fixture(); val row = f.changed(); val entered = CompletableDeferred<Unit>(); val proceed = CompletableDeferred<Unit>()
        f.endpoint.atWrite = { entered.complete(Unit); proceed.await() }
        val first = async { f.transfer.save(row.id, f.endpoint, true) }
        entered.await()
        val otherStore = OfficeDocumentStore(f.preferences, f.root)
        assertEquals(OfficeDocumentPhase.SAVING, otherStore.records(f.endpoint.owner).single().phase)
        failure { OfficeDocumentTransfer(otherStore).save(row.id, f.endpoint, true) }
        proceed.complete(Unit); assertEquals(OfficeDocumentPhase.SAVED, first.await().phase)
        assertEquals(1, f.endpoint.writes)
    }
    @Test fun `wrong format and changed local snapshot leave remote and old candidate untouched`() = runBlocking {
        val f = fixture(); val row = f.changed()
        assertEquals(DsmErrorKind.OFFICE_FORMAT, failure {
            f.transfer.importEdited(row.id, f.endpoint.owner, "copy.xlsx") { f.original.inputStream() }
        }.kind)
        f.store.artifact(row.id, row.candidateId!!).writeBytes(byteArrayOf(1))
        assertEquals(DsmErrorKind.OFFICE_LOCAL, failure { f.transfer.save(row.id, f.endpoint, true) }.kind)
        assertEquals(0, f.endpoint.writes); assertArrayEquals(f.original, f.endpoint.bytes)
    }
    @Test fun `export returns edited snapshot and discard only removes local session`() = runBlocking {
        val f = fixture(); val row = f.changed(); val output = ByteArrayOutputStream()
        f.transfer.export(row.id, f.endpoint.owner) { output }
        assertArrayEquals(f.edited, output.toByteArray()); assertEquals(0, f.endpoint.writes)
        f.store.discard(row); assertTrue(f.store.records(f.endpoint.owner).isEmpty())
        assertFalse(f.store.directory(row.id).exists()); assertArrayEquals(f.original, f.endpoint.bytes)
    }
    @Test fun `process recovery preserves timestamp immutable target and pending save`() = runBlocking {
        val f = fixture(); val row = f.changed()
        failure { f.store.replace(row, row.copy(baseline = row.baseline.copy(path = "/share/other.docx"))) }
        f.store.replace(row, row.copy(phase = OfficeDocumentPhase.SAVING))
        val restored = OfficeDocumentStore(f.preferences, f.root).records(f.endpoint.owner.copy(sessionGeneration = "new")).single()
        assertEquals(OfficeDocumentPhase.UNKNOWN, restored.phase); assertEquals(row.createdAtSeconds, restored.createdAtSeconds)
        failure { f.store.replace(restored, restored.copy(phase = OfficeDocumentPhase.CHANGED)) }
        assertFalse(restored.toString().contains(row.baseline.path)); assertEquals(0, f.endpoint.writes)
    }
    @Test fun `source changes during preparation produces no editing record`() = runBlocking {
        val f = fixture(); f.endpoint.afterDownload = { f.endpoint.bytes = f.edited }
        failure { f.prepare() }; assertTrue(f.store.records(f.endpoint.owner).isEmpty())
        assertTrue(f.root.listFiles().orEmpty().isEmpty()); assertEquals(0, f.endpoint.writes)
    }

    private suspend fun failure(block: suspend () -> Any?): DsmFailure {
        try { block(); fail("expected failure") } catch (error: DsmFailure) { return error }
        throw AssertionError("unreachable")
    }
}
