package io.github.qwertyuiop1995.dsmnativeclient.data.chat

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPoll
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class DsmChatRepositoryCancellationTest {
    @Test
    fun `用户读取取消不会降级为空映射继续组装会话`() = runBlocking {
        val expected = CancellationException("users cancelled")
        val gateway = CancellingUsersGateway(expected)

        val actual = captureCancellation { DsmChatRepository(gateway).conversations() }

        assertSame(expected, actual)
        assertEquals(0, gateway.conversationsReadCount)
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

private class CancellingUsersGateway(
    private val cancellation: CancellationException,
) : DsmChatRepositoryGateway {
    var conversationsReadCount = 0

    override suspend fun usersData(): JsonObject = throw cancellation

    override suspend fun conversationsData(): JsonObject {
        conversationsReadCount += 1
        return JsonObject(emptyMap())
    }

    override suspend fun messagesData(conversationId: String, offset: Int, limit: Int): JsonObject =
        JsonObject(emptyMap())

    override suspend fun conversationMembersData(conversationId: String): JsonObject =
        JsonObject(emptyMap())

    override fun supportsConversationMembers(): Boolean = false

    override fun invalidConversationRequest(): DsmFailure = error("不应读取无效会话")

    override fun unsupportedConversationRead(): DsmFailure = error("不应读取成员")

    override fun username(): String = "synthetic-user"

    override fun currentUserId(): String? = null

    override fun updateCurrentUserId(userId: String) = Unit

    override fun poll(post: JsonObject, messageId: String): ChatPoll? = null
}
