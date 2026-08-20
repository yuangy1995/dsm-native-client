package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CoroutineResultTest {
    @Test
    fun `挂起结果辅助函数保留普通失败`() = runBlocking {
        val expected = IllegalStateException("synthetic failure")

        val result = suspendRunCatching<String> { throw expected }

        assertSame(expected, result.exceptionOrNull())
    }

    @Test
    fun `挂起结果辅助函数原样传播取消`() = runBlocking {
        val expected = CancellationException("synthetic cancellation")

        val actual = captureCancellation {
            suspendRunCatching<String> { throw expected }
        }

        assertSame(expected, actual)
    }

    @Test
    fun `capture 取消不会写入失败状态`() = runBlocking {
        var updated: Loadable<String>? = null
        val expected = CancellationException("capture cancelled")

        val actual = captureCancellation {
            updated = captureLoadable { throw expected }
        }

        assertSame(expected, actual)
        assertNull(updated)
    }

    @Test
    fun `Profile 替换后旧取消不会落入新状态`() = runBlocking {
        var currentProfileId = "profile-a"
        var nextProfileState: Loadable<String>? = null
        val expected = CancellationException("profile switched")

        val actual = captureCancellation {
            val result = captureLoadable {
                currentProfileId = "profile-b"
                throw expected
            }
            if (currentProfileId == "profile-a") {
                nextProfileState = result
            }
        }

        assertSame(expected, actual)
        assertTrue(currentProfileId == "profile-b")
        assertNull(nextProfileState)
    }

    private suspend fun captureCancellation(block: suspend () -> Unit): CancellationException {
        try {
            block()
        } catch (error: CancellationException) {
            return error
        }
        throw AssertionError("预期取消异常继续传播")
    }
}
