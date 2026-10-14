package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasDdnsActivityStoreTest {
    private val prefs = MemoryPreferences(); private val store = NasDdnsActivityStore(prefs)
    private val owner = WorkspaceOwner("synthetic", "identity", "session")
    private fun record(id: String = "one", operation: DdnsMutationOperation = DdnsMutationOperation.SAVE) = NasDdnsRecordActivity(id, owner, operation,
        providerDigest = "a".repeat(64), targetDigest = "b".repeat(64).takeIf { operation == DdnsMutationOperation.SAVE }, requiresAcceptance = true)
    @Test fun `不可伪造接受或关闭持久未知而旧身份记录仍隔离`() {
        val r = record(); store.begin(r); store.checkpoint(owner, r.id, NasServiceStage.SUBMITTED)
        assertTrue(runCatching { store.checkpoint(owner, r.id, NasServiceStage.VERIFIED) }.isFailure)
        assertTrue(runCatching { store.dismiss(owner, r.id) }.isFailure); assertTrue(runCatching { store.begin(record("duplicate")) }.isFailure)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
        store.checkpoint(owner, r.id, NasServiceStage.ACCEPTED); store.checkpoint(owner, r.id, NasServiceStage.VERIFIED)
        store.dismiss(owner, r.id); assertTrue(store.records(owner).single().accepted)
    }
    @Test fun `瞬时未知关闭只隐藏原事实且重启不丢失`() {
        val r = record(operation = DdnsMutationOperation.TEST); store.begin(r); store.checkpoint(owner, r.id, NasServiceStage.SUBMITTED)
        store.dismiss(owner, r.id); val reopened = NasDdnsActivityStore(prefs).records(owner).single()
        assertEquals(NasServiceStage.SUBMITTED, reopened.stage); assertFalse(reopened.accepted); assertTrue(reopened.dismissed)
        store.begin(record("explicit-next")); assertEquals(2, store.records(owner).size)
    }
    @Test fun `损坏记录和落盘失败保持明确失败`() {
        prefs.edit().putString("ddns:broken", "invalid").commit()
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, (runCatching { store.records(owner) }.exceptionOrNull() as DsmFailure).kind)
        prefs.edit().remove("ddns:broken").commit(); assertTrue(runCatching { store.records(owner) }.isFailure)
        val otherPrefs = MemoryPreferences(); val other = NasDdnsActivityStore(otherPrefs); otherPrefs.commitSucceeds = false
        assertTrue(runCatching { other.begin(record()) }.isFailure)
    }
    @Test fun `跨实例执行及连接删除互斥`() = runBlocking {
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val running = launch { store.execute(owner) { entered.complete(Unit); release.await() } }; entered.await()
        assertTrue(runCatching { NasDdnsActivityStore(prefs).execute(owner) {} }.isFailure)
        assertTrue(runCatching { store.removeProfile(owner.profileId) }.isFailure)
        release.complete(Unit); running.join(); store.execute(owner) {}; store.removeProfile(owner.profileId)
    }
}
