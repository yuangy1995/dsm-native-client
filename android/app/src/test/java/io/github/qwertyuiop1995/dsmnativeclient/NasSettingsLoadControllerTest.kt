package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NasSettingsLoadControllerTest {
    @Test
    fun `NAS 设置加载取消向上传播且不写入普通失败状态`() = runBlocking {
        val scope = testScope()
        val controller = NasSettingsLoadController()
        val expected = CancellationException("nas settings cancelled")
        var published: Loadable<String>? = null
        var completion: Throwable? = null

        val job = checkNotNull(
            controller.start(
                scope = scope,
                profileId = "profile-a",
                onStart = { true },
                load = { throw expected },
                onResult = { _, value -> published = value },
            ),
        )
        job.invokeOnCompletion { completion = it }
        job.join()

        assertTrue(job.isCancelled)
        assertSame(expected, completion)
        assertNull(published)
        scope.cancel()
    }

    @Test
    fun `切换资料会取消旧 NAS 加载且旧结果不会污染新资料`() = runBlocking {
        val scope = testScope()
        val controller = NasSettingsLoadController()
        val firstValue = CompletableDeferred<String>()
        val published = mutableListOf<Pair<String, Loadable<String>>>()

        val oldJob = checkNotNull(
            controller.start(
                scope = scope,
                profileId = "profile-a",
                onStart = { true },
                load = { firstValue.await() },
                onResult = { token, value -> published += token.profileId to value },
            ),
        )
        val newJob = checkNotNull(
            controller.start(
                scope = scope,
                profileId = "profile-b",
                onStart = { true },
                load = { "new-profile" },
                onResult = { token, value -> published += token.profileId to value },
            ),
        )
        oldJob.join()
        newJob.join()

        assertTrue(oldJob.isCancelled)
        assertFalse(newJob.isCancelled)
        assertEquals(listOf("profile-b" to Loadable.Ready("new-profile")), published)
        scope.cancel()
    }

    @Test
    fun `普通 NAS 设置异常仍映射为失败状态`() = runBlocking {
        val scope = testScope()
        val controller = NasSettingsLoadController()
        var published: Loadable<String>? = null

        val job = checkNotNull(
            controller.start(
                scope = scope,
                profileId = "profile-a",
                onStart = { true },
                load = { throw IllegalStateException("synthetic failure") },
                onResult = { _, value -> published = value },
            ),
        )
        job.join()

        assertFalse(job.isCancelled)
        assertTrue(published is Loadable.Failed)
        scope.cancel()
    }

    private fun testScope(): CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
}
