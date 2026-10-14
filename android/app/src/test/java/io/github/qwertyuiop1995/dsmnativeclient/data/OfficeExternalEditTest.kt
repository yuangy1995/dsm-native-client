package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.testing.OfficeFixture
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OfficeExternalEditTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun fixture() = OfficeFixture(temporary.newFolder())
    private suspend fun refused(block: suspend () -> Unit) { try { block(); fail("Expected refusal") } catch (_: DsmFailure) { } }
    @Test fun `工作副本可写但关闭仅接收本机内容确认后才覆盖一次`() = runBlocking {
        val f = fixture(); val original = f.prepare()
        val open = f.transfer.beginExternal(original.id, f.endpoint.owner)
        assertArrayEquals(f.original, f.store.artifact(open.id, open.externalId!!).readBytes())
        f.store.artifact(open.id, open.externalId).writeBytes(f.edited)
        assertArrayEquals(f.original, f.store.artifact(open.id, open.originalId).readBytes())
        val received = f.transfer.closeExternal(open, true)
        assertEquals(OfficeDocumentPhase.CHANGED, received.phase); assertNull(received.externalId)
        assertFalse(f.store.externalActive(open)); assertEquals(0, f.endpoint.writes)
        assertArrayEquals(f.edited, f.store.artifact(received.id, received.localId).readBytes())
        refused { f.transfer.save(received.id, f.endpoint, false) }
        assertEquals(OfficeDocumentPhase.SAVED, f.transfer.save(received.id, f.endpoint, true).phase)
        assertEquals(1, f.endpoint.writes)
    }
    @Test fun `描述符开放期间不能并行编辑导入覆盖或清理`() = runBlocking {
        val f = fixture(); val row = f.changed(); val open = f.transfer.beginExternal(row.id, f.endpoint.owner)
        assertFalse(open.canSave); assertFalse(open.canImport)
        refused { f.transfer.beginExternal(row.id, f.endpoint.owner) }
        refused { f.transfer.importEdited(row.id, f.endpoint.owner, "edited.docx") { f.edited.inputStream() } }
        refused { f.transfer.save(row.id, f.endpoint, true) }; refused { f.store.discard(open, true) }
        refused { f.store.removeProfile(f.endpoint.owner.profileId) }; refused { f.transfer.receiveExternal(row.id, f.endpoint.owner) }
        assertEquals(0, f.endpoint.writes); f.transfer.closeExternal(open, true); Unit
    }
    @Test fun `重复关闭旧描述符不能释放新编辑的锁`() = runBlocking {
        val f = fixture(); val row = f.prepare(); val first = f.transfer.beginExternal(row.id, f.endpoint.owner)
        f.transfer.closeExternal(first, true)
        val second = f.transfer.beginExternal(row.id, f.endpoint.owner)
        refused { f.transfer.closeExternal(first, true) }
        assertTrue(f.store.externalActive(second)); refused { f.store.discard(second, true) }
        f.transfer.closeExternal(second, true); Unit
    }
    @Test fun `异常关闭保留工作文件可明确接收且不自动写NAS`() = runBlocking {
        val f = fixture(); val row = f.prepare(); val open = f.transfer.beginExternal(row.id, f.endpoint.owner)
        val file = f.store.artifact(open.id, open.externalId!!); file.writeBytes(f.edited)
        assertEquals(open, f.transfer.closeExternal(open, false)); assertTrue(file.exists())
        val coldStore = OfficeDocumentStore(f.preferences, f.root); val cold = OfficeDocumentTransfer(coldStore)
        assertEquals(open, coldStore.records(f.endpoint.owner).single()); assertFalse(open.canSave)
        refused { coldStore.discard(open) }; refused { cold.save(row.id, f.endpoint, true) }
        val received = cold.receiveExternal(row.id, f.endpoint.owner)
        assertArrayEquals(f.edited, coldStore.artifact(received.id, received.localId).readBytes()); assertEquals(0, f.endpoint.writes)
    }
    @Test fun `外部编辑时远端变化仍保留本机内容并拒绝覆盖`() = runBlocking {
        val f = fixture(); val row = f.prepare(); val open = f.transfer.beginExternal(row.id, f.endpoint.owner)
        f.store.artifact(open.id, open.externalId!!).writeBytes(f.edited)
        val received = f.transfer.closeExternal(open, true); f.endpoint.bytes = "other-original".toByteArray()
        refused { f.transfer.save(received.id, f.endpoint, true) }
        assertEquals(OfficeDocumentPhase.CONFLICT, f.store.get(row.id).phase); assertEquals(0, f.endpoint.writes)
        assertArrayEquals(f.edited, f.store.artifact(received.id, received.localId).readBytes())
    }
    @Test fun `账号变化不丢弃已编辑内容但新身份不能接收和保存`() = runBlocking {
        val f = fixture(); val row = f.prepare(); val open = f.transfer.beginExternal(row.id, f.endpoint.owner)
        f.store.artifact(open.id, open.externalId!!).writeBytes(f.edited)
        f.endpoint.owner = f.endpoint.owner.copy(identityRevision = "new-identity")
        val received = f.transfer.closeExternal(open, true)
        assertTrue(f.store.records(f.endpoint.owner).isEmpty()); assertEquals(OfficeDocumentPhase.CHANGED, received.phase)
        refused { f.transfer.save(received.id, f.endpoint, true) }; assertEquals(0, f.endpoint.writes)
    }
    @Test fun `接收索引保存失败仍保留可恢复工作副本`() = runBlocking {
        val f = fixture(); val row = f.prepare(); val open = f.transfer.beginExternal(row.id, f.endpoint.owner)
        val work = f.store.artifact(open.id, open.externalId!!); work.writeBytes(f.edited)
        f.preferences.commitSucceeds = false; refused { f.transfer.closeExternal(open, true) }
        assertTrue(work.exists()); assertFalse(f.store.externalActive(open)); assertEquals(0, f.endpoint.writes)
        val current = f.store.get(row.id)
        assertTrue(f.store.artifact(current.id, current.localId).isFile)
    }
    @Test fun `异常关闭后只有明确丢弃才清理本机副本`() = runBlocking {
        val f = fixture(); val row = f.prepare(); val open = f.transfer.beginExternal(row.id, f.endpoint.owner)
        f.transfer.closeExternal(open, false); refused { f.store.discard(open) }
        f.store.discard(open, discardExternal = true)
        assertFalse(f.store.directory(row.id).exists()); assertArrayEquals(f.original, f.endpoint.bytes); assertEquals(0, f.endpoint.writes)
    }
}
