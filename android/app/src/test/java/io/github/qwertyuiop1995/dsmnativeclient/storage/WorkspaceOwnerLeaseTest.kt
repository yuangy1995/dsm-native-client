package io.github.qwertyuiop1995.dsmnativeclient.storage

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class WorkspaceOwnerLeaseTest {
    @Test fun `重复媒体读取不重复解密但新代次必须重新核对`() {
        var version = 0L
        var reads = 0
        val lease = WorkspaceOwnerLease({ reads++ }, { version })
        repeat(1000) { lease.requireCurrent() }
        assertEquals(1, reads)
        version++
        lease.requireCurrent()
        assertEquals(2, reads)
    }

    @Test fun `核对期间发生新变更不能把旧结果缓存为最新代次`() {
        var version = 0L
        var reads = 0
        val lease = WorkspaceOwnerLease({ reads++; if (reads == 1) version++ }, { version })
        lease.requireCurrent(); lease.requireCurrent()
        assertEquals(2, reads)
    }

    @Test fun `通过另一存储实例退出后旧租约立即失效且其他账号保留`() {
        val preferences = MemoryPreferences()
        val first = SecureProfileStore(preferences)
        val second = SecureProfileStore(preferences)
        val profile = NasProfile("a", "NAS", "https://nas.example.invalid", "account-a")
        val other = profile.copy(id = "b", username = "account-b")
        val owner = first.commitConnection(first.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic-a"), null, false)
        val otherOwner = first.commitConnection(first.connectionAttempt(other.id), other, DsmSession(other.id, "synthetic-b"), null, false)
        val lease = first.lease(owner)
        val otherLease = first.lease(otherOwner)
        assertTrue(second.signOut(owner))
        assertEquals(DsmErrorKind.WORKSPACE_CHANGED, assertThrows(DsmFailure::class.java) { lease.requireCurrent() }.kind)
        otherLease.requireCurrent()
    }
}
