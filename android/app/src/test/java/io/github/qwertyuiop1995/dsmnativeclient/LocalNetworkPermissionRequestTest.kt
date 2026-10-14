package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

class LocalNetworkPermissionRequestTest {
    @Test fun `授权结果只继续原尝试`() = runTest {
        val request = LocalNetworkPermissionRequest()
        val first = async(start = CoroutineStart.UNDISPATCHED) { request.request() }
        val id = request.pending.value!!
        request.complete("another-attempt", true)
        assertFalse(first.isCompleted)
        request.complete(id, true)
        assertTrue(first.await()); assertNull(request.pending.value)
    }

    @Test fun `取消后迟到授权不能继续后来的账号`() = runTest {
        val request = LocalNetworkPermissionRequest()
        val first = async(start = CoroutineStart.UNDISPATCHED) { request.request() }
        val old = request.pending.value!!
        first.cancelAndJoin(); assertNull(request.pending.value)
        val second = async(start = CoroutineStart.UNDISPATCHED) { request.request() }
        request.complete(old, true); assertFalse(second.isCompleted)
        request.complete(request.pending.value, false)
        assertFalse(second.await()); assertNull(request.pending.value)
    }
}
