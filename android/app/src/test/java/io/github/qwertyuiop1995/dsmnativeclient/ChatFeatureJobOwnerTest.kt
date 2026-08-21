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
                onResult = { _, value -> published += "profile-a" to value },
            ),
        )
        val secondToken = owner.ensureSession("profile-b").token
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "conversations",
                token = secondToken,
                block = { "new-profile" },
                onResult = { _, value -> published += "profile-b" to value },
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
    fun `同一 Chat 任务替换会拒绝已取值且捕获取消的旧结果`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val token = owner.ensureSession("profile-a").token
        val oldValueReady = CompletableDeferred<Unit>()
        val keepOldTaskSuspended = CompletableDeferred<Unit>()
        val published = mutableListOf<String>()

        val oldJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = token,
                block = {
                    val value = "stale"
                    oldValueReady.complete(Unit)
                    try {
                        keepOldTaskSuspended.await()
                    } catch (_: CancellationException) {
                        // 网络结果已获得后，取消只会在最后一个挂起点恢复；必须拒绝迟到发布。
                    }
                    value
                },
                onResult = { _, value -> published += value },
            ),
        )
        oldValueReady.await()
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = token,
                block = { "latest" },
                onResult = { _, value -> published += value },
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
    fun `旧任务完成不会清除新任务所有权`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val token = owner.ensureSession("profile-a").token
        val oldStarted = CompletableDeferred<Unit>()
        val keepOldTaskSuspended = CompletableDeferred<Unit>()
        val keepNewTaskSuspended = CompletableDeferred<Unit>()

        val oldJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = token,
                block = {
                    oldStarted.complete(Unit)
                    try {
                        keepOldTaskSuspended.await()
                    } catch (_: CancellationException) {
                        "old"
                    }
                },
                onResult = { _, _ -> },
            ),
        )
        oldStarted.await()
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = token,
                block = { keepNewTaskSuspended.await() },
                onResult = { _, _ -> },
            ),
        )

        oldJob.join()
        owner.cancel("refresh")
        newJob.join()

        assertTrue(oldJob.isCancelled)
        assertTrue(newJob.isCancelled)
        scope.cancel()
    }

    @Test
    fun `取消同名任务会先使旧任务令牌失效`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val session = owner.ensureSession("profile-a").token
        val started = CompletableDeferred<ChatTaskToken>()
        val waiting = CompletableDeferred<Unit>()

        val job = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = session,
                block = { taskToken ->
                    started.complete(taskToken)
                    waiting.await()
                },
                onResult = { _, _ -> },
            ),
        )
        val taskToken = started.await()

        owner.cancel("refresh")
        job.join()

        assertTrue(job.isCancelled)
        assertFalse(owner.isCurrent(taskToken))
        scope.cancel()
    }

    @Test
    fun `旧轮询任务捕获取消后不会写入 Workspace`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val session = owner.ensureSession("profile-a").token
        val oldValueReady = CompletableDeferred<Unit>()
        val keepOldPollingSuspended = CompletableDeferred<Unit>()
        var workspaceValue = "initial"

        val oldJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = session,
                block = { taskToken ->
                    val staleValue = "stale"
                    oldValueReady.complete(Unit)
                    try {
                        keepOldPollingSuspended.await()
                    } catch (_: CancellationException) {
                        // 轮询请求已返回；继续执行前必须以完整任务令牌复核。
                    }
                    if (owner.isCurrent(taskToken)) workspaceValue = staleValue
                },
                onResult = { _, _ -> },
            ),
        )
        oldValueReady.await()
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = session,
                block = { taskToken ->
                    if (owner.isCurrent(taskToken)) workspaceValue = "latest"
                },
                onResult = { _, _ -> },
            ),
        )
        oldJob.join()
        newJob.join()

        assertEquals("latest", workspaceValue)
        scope.cancel()
    }

    @Test
    fun `旧实时连接任务不会改变连接状态或重新启动轮询`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val session = owner.ensureSession("profile-a").token
        val oldValueReady = CompletableDeferred<Unit>()
        val keepOldConnectionSuspended = CompletableDeferred<Unit>()
        var realtimeConnected = true
        var pollingStarts = 0

        val oldJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "realtime-connection",
                token = session,
                block = {
                    oldValueReady.complete(Unit)
                    try {
                        keepOldConnectionSuspended.await()
                        false
                    } catch (_: CancellationException) {
                        false
                    }
                },
                onResult = { taskToken, connected ->
                    if (owner.isCurrent(taskToken)) {
                        realtimeConnected = connected
                        if (!connected) pollingStarts += 1
                    }
                },
            ),
        )
        oldValueReady.await()
        val newJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "realtime-connection",
                token = session,
                block = { true },
                onResult = { taskToken, connected ->
                    if (owner.isCurrent(taskToken)) realtimeConnected = connected
                },
            ),
        )
        oldJob.join()
        newJob.join()

        assertTrue(realtimeConnected)
        assertEquals(0, pollingStarts)
        scope.cancel()
    }

    @Test
    fun `过期实时任务令牌不能替换当前轮询`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val session = owner.ensureSession("profile-a").token
        val oldTokenReady = CompletableDeferred<ChatTaskToken>()
        val keepOldConnectionSuspended = CompletableDeferred<Unit>()
        val keepRefreshSuspended = CompletableDeferred<Unit>()

        val oldConnection = checkNotNull(
            owner.launch(
                scope = scope,
                name = "realtime-connection",
                token = session,
                block = { taskToken ->
                    oldTokenReady.complete(taskToken)
                    try {
                        keepOldConnectionSuspended.await()
                    } catch (_: CancellationException) {
                        Unit
                    }
                },
                onResult = { _, _ -> },
            ),
        )
        val oldToken = oldTokenReady.await()
        val refresh = checkNotNull(
            owner.launch(
                scope = scope,
                name = "refresh",
                token = session,
                block = { keepRefreshSuspended.await() },
                onResult = { _, _ -> },
            ),
        )
        val currentConnection = checkNotNull(
            owner.launch(
                scope = scope,
                name = "realtime-connection",
                token = session,
                block = { Unit },
                onResult = { _, _ -> },
            ),
        )
        oldConnection.join()
        currentConnection.join()

        val stalePolling = owner.launch(
            scope = scope,
            name = "refresh",
            token = session,
            sourceToken = oldToken,
            block = { Unit },
            onResult = { _, _ -> },
        )
        owner.cancel("refresh")
        refresh.join()

        assertNull(stalePolling)
        assertTrue(refresh.isCancelled)
        scope.cancel()
    }

    @Test
    fun `资料切换和失效都会拒绝旧任务捕获取消后的结果`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val firstSession = owner.ensureSession("profile-a").token
        val firstStarted = CompletableDeferred<Unit>()
        val firstWaiting = CompletableDeferred<Unit>()
        val published = mutableListOf<String>()

        val profileJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "conversation-load",
                token = firstSession,
                block = {
                    firstStarted.complete(Unit)
                    try {
                        firstWaiting.await()
                        "profile-a"
                    } catch (_: CancellationException) {
                        "profile-a"
                    }
                },
                onResult = { _, value -> published += value },
            ),
        )
        firstStarted.await()
        owner.ensureSession("profile-b")
        profileJob.join()

        val secondSession = owner.ensureSession("profile-b").token
        val secondStarted = CompletableDeferred<Unit>()
        val secondWaiting = CompletableDeferred<Unit>()
        val invalidatedJob = checkNotNull(
            owner.launch(
                scope = scope,
                name = "message-load",
                token = secondSession,
                block = {
                    secondStarted.complete(Unit)
                    try {
                        secondWaiting.await()
                        "invalidated"
                    } catch (_: CancellationException) {
                        "invalidated"
                    }
                },
                onResult = { _, value -> published += value },
            ),
        )
        secondStarted.await()
        owner.invalidate(clearProfile = false)
        invalidatedJob.join()

        assertTrue(profileJob.isCancelled)
        assertTrue(invalidatedJob.isCancelled)
        assertEquals(emptyList<String>(), published)
        scope.cancel()
    }

    @Test
    fun `普通失败仍映射为可发布的加载失败`() = runBlocking {
        val scope = testScope()
        val owner = ChatFeatureJobOwner()
        val token = owner.ensureSession("profile-a").token
        var published: Loadable<String>? = null

        val job = checkNotNull(
            owner.launch(
                scope = scope,
                name = "conversation-load",
                token = token,
                block = {
                    captureLoadable<String> { throw IllegalStateException("ordinary failure") }
                },
                onResult = { _, value -> published = value },
            ),
        )
        job.join()

        assertFalse(job.isCancelled)
        assertTrue(published is Loadable.Failed)
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
