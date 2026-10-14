package io.github.qwertyuiop1995.dsmnativeclient.downloads

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class DownloadActionStoreTest {
    private val owner = WorkspaceOwner("synthetic-download", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = DownloadActionStore(preferences)
    private fun step(kind: DownloadActionKind = DownloadActionKind.PAUSE, target: String = "task") = DownloadActionStep(kind, target, "a".repeat(64))
    private fun record(id: String = "one", steps: List<DownloadActionStep> = listOf(step())) = DownloadActionRecord(id, owner, steps)
    @Test fun `同账号重登恢复跨账号和NAS隔离`() {
        store.begin(record()); val next = step().copy(phase = DownloadActionPhase.SUBMITTED, accepted = true)
        store.save(owner, "one", 0, next)
        assertEquals(next, DownloadActionStore(preferences).records(owner.copy(sessionGeneration = "new")).single().steps.single())
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty()); assertTrue(store.records(owner.copy(profileId = "other")).isEmpty())
    }
    @Test fun `未知不能删除降级改对象或抹掉回执`() {
        store.begin(record()); val next = step().copy(phase = DownloadActionPhase.SUBMITTED, accepted = true); store.save(owner, "one", 0, next)
        reject { store.discard(owner, "one") }
        for (bad in listOf(next.copy(phase = DownloadActionPhase.READY), next.copy(phase = DownloadActionPhase.CANCELLED), next.copy(accepted = false), next.copy(target = "other"), next.copy(identityDigest = "b".repeat(64)))) reject { store.save(owner, "one", 0, bad) }
        assertEquals(next, store.get(owner, "one").steps.single())
    }
    @Test fun `同任务跨动作互斥但其他任务可继续`() {
        store.begin(record())
        reject { DownloadActionStore(preferences).begin(record("edit", listOf(step(DownloadActionKind.EDIT)))) }
        store.begin(record("other", listOf(step(target = "other"))))
        assertEquals(2, store.records(owner).size)
    }
    @Test fun `创建只按来源防重而不是目录或请求摘要`() {
        val source = "a".repeat(64)
        val create = DownloadActionStep(DownloadActionKind.CREATE_FILE, source, source, desired = mapOf("request_digest" to "b".repeat(64)))
        store.begin(record(steps = listOf(create)))
        reject { store.begin(record("changed", listOf(create.copy(desired = mapOf("request_digest" to "c".repeat(64)))))) }
        store.begin(record("other", listOf(create.copy(target = "d".repeat(64), identityDigest = "d".repeat(64)))))
    }
    @Test fun `尚未开始可取消但不能直接写成功且终态不可改写`() {
        store.begin(record()); reject { store.save(owner, "one", 0, step().copy(phase = DownloadActionPhase.COMPLETED)) }
        val cancelled = step().copy(phase = DownloadActionPhase.CANCELLED); store.save(owner, "one", 0, cancelled)
        reject { store.save(owner, "one", 0, step()) }
        store.discard(owner, "one"); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `坏记录原样保留并拒绝开始新写`() {
        preferences.edit().putString("download:bad", "{broken").commit()
        reject { store.records(owner) }; reject { store.begin(record()) }
        assertEquals("{broken", preferences.getString("download:bad", null))
    }
    @Test fun `写失败上抛记录不允许任意URL或密码字段`() {
        preferences.commitSucceeds = false; reject { store.begin(record()) }
        preferences.commitSucceeds = true
        reject { store.begin(record("bad", listOf(step().copy(desired = mapOf("password" to "synthetic"))))) }
    }
    @Test fun `执行中的记录不能被第二实例恢复或清理`() = runBlocking {
        store.begin(record())
        store.execute("one") {
            try { DownloadActionStore(preferences).execute("one") { fail("Cannot enter") }; fail("Expected busy") } catch (_: DsmFailure) { }
            reject { store.removeProfile(owner.profileId) }
        }
        store.removeProfile(owner.profileId); assertTrue(store.records(owner).isEmpty())
    }
    private fun reject(block: () -> Any?) { try { block(); fail("Expected rejection") } catch (_: DsmFailure) { } }
}
