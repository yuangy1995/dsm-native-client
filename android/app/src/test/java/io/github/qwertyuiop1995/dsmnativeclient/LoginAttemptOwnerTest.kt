package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LoginAttemptOwnerTest {
    @Test fun 取消连接后不执行后续提交() = runTest {
        val owner = LoginAttemptOwner()
        var committed = false
        owner.launch(this) { delay(100); committed = true }
        runCurrent()
        assertTrue(owner.cancel())
        advanceUntilIdle()
        assertFalse(committed)
        assertFalse(owner.isActive)
    }
    @Test fun 取消不进入业务失败或会话清理分支() = runTest {
        val owner = LoginAttemptOwner()
        var failures = 0
        owner.launch(this) { suspendRunCatching { delay(100) }.onFailure { failures++ } }
        runCurrent(); owner.cancel(); advanceUntilIdle()
        assertEquals(0, failures)
    }
    @Test fun 非协作返回后仍必须检查取消再提交() = runTest {
        val owner = LoginAttemptOwner()
        var committed = false
        owner.launch(this) {
            withContext(NonCancellable) { delay(100) }
            currentCoroutineContext().ensureActive()
            committed = true
        }
        runCurrent(); owner.cancel(); advanceUntilIdle()
        assertFalse(committed)
    }
    @Test fun 新尝试替代旧尝试且旧完成回调不会清除新拥有者() = runTest {
        val owner = LoginAttemptOwner()
        val completions = mutableListOf<String>()
        owner.launch(this) { delay(100); completions += "old" }
        runCurrent()
        owner.launch(this) { delay(20); completions += "new" }
        runCurrent()
        assertTrue(owner.isActive)
        advanceUntilIdle()
        assertEquals(listOf("new"), completions)
        assertFalse(owner.isActive)
    }
    @Test fun 已完成连接不可再次取消() = runTest {
        val owner = LoginAttemptOwner()
        owner.launch(this) {}
        advanceUntilIdle()
        assertFalse(owner.cancel())
    }
    @Test fun 取消后迟到的网络失败不会改写下一次连接状态() = runTest {
        val owner = LoginAttemptOwner()
        var status = "initial"
        owner.launch(this) {
            suspendRunCatching {
                withContext(NonCancellable) { delay(100); throw java.io.IOException("synthetic") }
            }.onFailure {
                currentCoroutineContext().ensureActive()
                status = "old failure"
            }
        }
        runCurrent()
        owner.cancel()
        owner.launch(this) { status = "new success" }
        advanceUntilIdle()
        assertEquals("new success", status)
    }
}
