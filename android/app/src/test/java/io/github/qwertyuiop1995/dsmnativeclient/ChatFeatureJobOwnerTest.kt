package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
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

class ChatFeatureJobOwnerTest {
    @Test
    fun `Chat 读取取消向上传播且不发布普通结果`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val token = owner.ensureSession("profile-a").token
        val expected = CancellationException("chat read cancelled")
        var published: String? = null
        var completion: Throwable? = null

        val job = checkNotNull(
            owner.launch(
                scope = scope,
                name = "messages",
                token = token,
                block = { throw expected },
                onResult = { value -> published = value },
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
    fun `切换资料会取消旧 Chat 读取且只允许新资料发布`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val firstToken = owner.ensureSession("profile-a").token
        val firstValue = CompletableDeferred<String>()
        val published = mutableListOf<Pair<String, String>>()

        val oldJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "conversations",
                token = firstToken,
                block = { firstValue.await() },
                onResult = { value -> published += "profile-a" to value },
            ),
        )
        val secondToken = owner.ensureSession("profile-b").token
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "conversations",
                token = secondToken,
                block = { "new-profile" },
                onResult = { value -> published += "profile-b" to value },
            ),
        )
        oldJob.join()
        newJob.join()

        assertTrue(oldJob.isCancelled)
        assertFalse(newJob.isCancelled)
        assertEquals(listOf("profile-b" to "new-profile"), published)
        scope.cancel()
    }

    @Test
    fun `同一 Chat 任务替换会取消旧任务且保留新任务所有权`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val token = owner.ensureSession("profile-a").token
        val oldValue = CompletableDeferred<String>()
        val published = mutableListOf<String>()

        val oldJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = token,
                block = { oldValue.await() },
                onResult = published::add,
            ),
        )
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = token,
                block = { "latest" },
                onResult = published::add,
            ),
        )
        oldJob.join()
        newJob.join()

        assertTrue(oldJob.isCancelled)
        assertFalse(newJob.isCancelled)
        assertEquals(listOf("latest"), published)
        scope.cancel()
    }

    @Test
    fun `离开 Chat 后保留同一资料但使旧代次失效`() {
        val owner = ChatFeatureJobOwner()
        val previous = owner.ensureSession("profile-a")

        owner.invalidate(clearProfile = false)
        val resumed = owner.ensureSession("profile-a")

        assertFalse(resumed.changed)
        assertEquals("profile-a", resumed.token.profileId)
        assertTrue(resumed.token.generation > previous.token.generation)
        assertFalse(owner.isCurrent(previous.token))
        assertTrue(owner.isCurrent(resumed.token))
    }

    @Test
    fun `AppViewModel 保持 Chat 公开兼容门面`() {
        assertEquals(
            "openConversation",
            AppViewModel::class.java
                .getMethod("openConversation", ChatConversation::class.java)
                .name,
        )
        assertEquals(
            "toggleChatConversationPin",
            AppViewModel::class.java.getMethod("toggleChatConversationPin", String::class.java).name,
        )
        assertEquals("closeConversation", AppViewModel::class.java.getMethod("closeConversation").name)
        assertEquals(
            "loadOlderChatMessages",
            AppViewModel::class.java.getMethod("loadOlderChatMessages").name,
        )
    }

    private fun testScope(): CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
}
