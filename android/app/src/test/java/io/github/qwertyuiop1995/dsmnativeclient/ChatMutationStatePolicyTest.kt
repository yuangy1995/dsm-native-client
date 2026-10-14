package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPoll
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPollOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.ui.canRetryChatMutation
import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatMutationStatePolicyTest {
    @Test
    fun `九类操作使用稳定标识并且目标不保存正文`() {
        val secret = "仅用于内存中的正文"
        ChatMutationOperation.entries.forEachIndexed { index, operation ->
            val target = presentationTarget(
                profileId = "profile-a",
                operation = operation,
                requestId = "request-$index",
                conversationId = "conversation-a",
                requestParts = listOf(secret, operation.name),
            )
            assertEquals(operation, target.operation)
            assertEquals(64, target.requestFingerprint.length)
            assertFalse(target.toString().contains(secret))
        }
        assertEquals(9, ChatMutationOperation.entries.size)
    }

    @Test
    fun `内容指纹区分字段边界并且配置重建保持一致`() {
        assertNotEquals(
            chatPayloadFingerprint(listOf("ab", "c")),
            chatPayloadFingerprint(listOf("a", "bc")),
        )
        val first = target(ChatMutationOperation.TEXT_SEND)
        assertEquals(first, first.copy())
    }

    @Test
    fun `八种原始结果状态均完整保留`() {
        MutationResultStatus.entries.forEach { status ->
            val entry = ChatMutationEntry(target(ChatMutationOperation.TEXT_SEND), mutationResult = result(status))
            assertEquals(status, entry.mutationResult?.status)
            assertEquals(result(status).counts, entry.mutationResult?.counts)
        }
        assertEquals(8, MutationResultStatus.entries.size)
    }

    @Test fun `显示结果保留原账号请求和会话归属`() {
        val checkpoint = ChatActionCheckpoint("request-a", ChatActionKind.ATTACHMENT, "conversation-a", "user-a", desiredDigest = chatTextDigest("body"))
        val state = ChatActionsState(listOf(ChatActionItem(checkpoint.id, checkpoint.kind, checkpoint.channelId, checkpoint)))
        val entry = state.presentation("profile-a").entries.getValue(checkpoint.id)
        assertEquals("profile-a", entry.target.profileId); assertEquals("request-a", entry.target.requestId)
        assertEquals("conversation-a", entry.target.conversationId); assertEquals(checkpoint.desiredDigest, entry.target.requestFingerprint)
    }

    @Test
    fun `在途和未回读未知结果阻止退出而收敛结果不阻止`() {
        val target = target(ChatMutationOperation.SCHEDULE_DELETE)
        assertTrue(chatMutationBlocksWorkspaceExit(ChatMutationWorkspaceState(mapOf(
            target.requestId to ChatMutationEntry(target, mutationInProgress = true),
        ))))
        val unknown = ChatMutationEntry(target, mutationResult = result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED))
        assertTrue(chatMutationBlocksWorkspaceExit(ChatMutationWorkspaceState(mapOf(target.requestId to unknown))))
        assertFalse(chatMutationBlocksWorkspaceExit(ChatMutationWorkspaceState(mapOf(
            target.requestId to unknown.copy(
                mutationRefreshCompleted = true,
                mutationVerification = ChatMutationVerification.DIFFERS,
            ),
        ))))
        val success = ChatMutationEntry(target, mutationResult = result(MutationResultStatus.CONFIRMED_SUCCESS))
        assertFalse(chatMutationBlocksWorkspaceExit(ChatMutationWorkspaceState(mapOf(target.requestId to success))))
    }

    @Test fun `删除回读和发送回读按当前执行器的稳定目标核验`() = runBlocking {
        val f = ChatProtocolFixture(); f.posts = "[${f.post()}]"
        val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello"))
        val sent = f.execute(action)
        assertEquals(ChatActionPhase.COMPLETED, sent.checkpoint.phase)
        assertEquals("post-1", sent.message!!.id)
        val reminder = ChatActionCheckpoint("reminder", ChatActionKind.REMINDER_DELETE, f.channelId, "1", messageId = "message-a",
            phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        assertEquals(ChatActionPhase.COMPLETED, f.repo.recoverAction(reminder) {}.checkpoint.phase)
        val time = System.currentTimeMillis() + 3_600_000
        f.schedules = "[${f.schedule(time)}]"
        val scheduled = reminder.copy(id = "schedule", kind = ChatActionKind.SCHEDULE_DELETE, messageId = "schedule-1", baselineAtMillis = time)
        assertEquals(ChatActionPhase.SUBMITTED, f.repo.recoverAction(scheduled) {}.checkpoint.phase)
    }

    @Test fun `投票和附件的同内容历史消息不能认领当前提交`() = runBlocking {
        for (kind in listOf(ChatActionKind.POLL_CREATE, ChatActionKind.ATTACHMENT)) {
            val f = ChatProtocolFixture()
            f.posts = if (kind == ChatActionKind.POLL_CREATE) "[${f.poll()}]" else "[${f.post("Question?", attachment = true)}]"
            f.write = { """{"success":true,"data":{}}""" }
            val action = f.prepare(ChatActionDraft(kind, f.channelId, text = "Question?", options = listOf("First", "Second"),
                multiple = true, attachment = f.source().takeIf { kind == ChatActionKind.ATTACHMENT }))
            val result = f.execute(action)
            assertEquals(ChatActionPhase.SUBMITTED, result.checkpoint.phase); assertTrue(result.message == null)
            assertTrue(f.postReads.isEmpty())
        }
    }

    @Test fun `提交后取消的显示投影保留未知计数并要求刷新`() {
        val checkpoint = ChatActionCheckpoint("request-a", ChatActionKind.ATTACHMENT, "conversation-a", "user-a",
            phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        val result = ChatActionsState(listOf(ChatActionItem(checkpoint.id, checkpoint.kind, checkpoint.channelId, checkpoint)))
            .presentation("profile-a").entries.getValue(checkpoint.id).mutationResult!!
        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.submitted); assertTrue(result.requiresRefresh); assertEquals(MutationResultCounts(0, 0, 1), result.counts)
    }

    @Test
    fun `刷新匹配会原子替换失败消息并收敛投票编辑器`() {
        val textTarget = presentationTarget(
            "profile-a", ChatMutationOperation.TEXT_SEND, "request-text", "conversation-a",
            expectedEpochMillis = 1_000, requestParts = listOf("hello"),
        )
        val local = ChatMessage(
            "local:request-text", "conversation-a", ChatUser("me", "Me", "me"),
            "hello", 1, true, clientRequestId = "request-text",
            deliveryState = ChatDeliveryState.FAILED,
        )
        val remote = local.copy(id = "remote-text", clientRequestId = null, deliveryState = ChatDeliveryState.SENT)
        val state = workspace().copy(
            selectedConversation = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
                "conversation-a", "A", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
            ),
            chatOutgoingMessages = mapOf("conversation-a" to listOf(local)),
            chatMessages = Loadable.Ready(ChatMessagePage(listOf(local), null, false)),
        )
        val converged = applyChatActionOutcome(state, completed(textTarget, remote))
        val visible = (converged.chatMessages as Loadable.Ready).value.messages
        assertFalse(visible.any { it.id == local.id })
        assertEquals(ChatDeliveryState.SENT, visible.single { it.id == remote.id }.deliveryState)
        assertEquals("request-text", converged.chatOutgoingMessages.getValue("conversation-a").single().clientRequestId)

        val pollTarget = presentationTarget(
            "profile-a", ChatMutationOperation.POLL_CREATE, "request-poll", "conversation-a",
            expectedEpochMillis = 1_000,
            requestParts = listOf("Question", "false", "false", "A", "B"),
        )
        val poll = ChatMessage(
            "remote-poll", "conversation-a", ChatUser("me", "Me", "me"), "", 1, true,
            poll = ChatPoll(
                "poll", "Question", false, false,
                options = listOf(ChatPollOption("a", "A"), ChatPollOption("b", "B")),
            ),
        )
        val pollState = applyChatActionOutcome(
            workspace().copy(
                selectedConversation = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
                    "conversation-a", "A", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
                ),
                chatPollComposerVisible = true,
                chatPollQuestion = "Question",
                chatPollOptions = listOf("A", "B"),
                chatMessages = Loadable.Ready(ChatMessagePage(emptyList(), null, false)),
            ),
            completed(pollTarget, poll),
        )
        assertFalse(pollState.chatPollComposerVisible)
        assertTrue((pollState.chatMessages as Loadable.Ready).value.messages.any { it.id == poll.id })
    }

    @Test
    fun `附件刷新匹配替换失败气泡`() {
        val target = presentationTarget(
            "profile-a", ChatMutationOperation.ATTACHMENT_SEND, "request-file", "conversation-a",
            expectedEpochMillis = 1_000, requestParts = listOf("body", "photo.jpg", "42"),
        )
        val attachment = ChatAttachment("file", "photo.jpg", "image/jpeg", 42)
        val local = ChatMessage(
            "local:request-file", "conversation-a", ChatUser("me", "Me", "me"), "body", 1, true,
            attachments = listOf(attachment), clientRequestId = "request-file",
            deliveryState = ChatDeliveryState.FAILED,
        )
        val remote = local.copy(id = "remote-file", clientRequestId = null, deliveryState = ChatDeliveryState.SENT)
        val converged = applyChatActionOutcome(
            workspace().copy(
                selectedConversation = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
                    "conversation-a", "A", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
                ),
                chatOutgoingMessages = mapOf("conversation-a" to listOf(local)),
                chatMessages = Loadable.Ready(ChatMessagePage(listOf(local), null, false)),
            ),
            completed(target, remote),
        )
        assertFalse(converged.chatOutgoingMessages.values.flatten().any { it.id == local.id })
        assertTrue(converged.chatOutgoingMessages.values.flatten().any { it.id == remote.id })
        assertFalse(converged.chatPendingAttachmentUris.containsKey(local.id))
    }

    @Test fun `回读仍未完成时保留未知而明确拒绝允许继续编辑`() {
        val checkpoint = ChatActionCheckpoint("request-a", ChatActionKind.SEND, "conversation-a", "user-a",
            phase = ChatActionPhase.SUBMITTED, submittedAtMillis = 1)
        val item = ChatActionItem(checkpoint.id, checkpoint.kind, checkpoint.channelId, checkpoint)
        val entry = ChatActionsState(listOf(item)).presentation("profile-a").entries.getValue(checkpoint.id)
        assertFalse(item.canEdit); assertTrue(item.canRefresh)
        assertFalse(chatMutationCanRemoveFailed(entry)); assertFalse(chatMutationCanContinueEditing(entry))
        val rejected = item.copy(checkpoint = checkpoint.copy(phase = ChatActionPhase.REJECTED))
        val settled = ChatActionsState(listOf(rejected)).presentation("profile-a").entries.getValue(checkpoint.id)
        assertTrue(rejected.canEdit); assertTrue(chatMutationCanRemoveFailed(settled)); assertTrue(chatMutationCanContinueEditing(settled))
    }

    @Test
    fun `跨会话迟到完成和刷新匹配只收敛目标分桶不污染当前消息页`() {
        val conversationA = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
            "conversation-a", "A", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
        )
        val conversationB = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
            "conversation-b", "B", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
        )
        val target = presentationTarget(
            "profile-a", ChatMutationOperation.TEXT_SEND, "request-a", conversationA.id,
            expectedEpochMillis = 1_000, requestParts = listOf("from A"),
        )
        val local = ChatMessage(
            "local:request-a", conversationA.id, ChatUser("me", "Me", "me"),
            "from A", 1, true, clientRequestId = "request-a",
            deliveryState = ChatDeliveryState.FAILED,
        )
        val remote = local.copy(
            id = "remote-a", clientRequestId = null, deliveryState = ChatDeliveryState.SENT,
        )
        val visibleB = ChatMessage(
            "message-b", conversationB.id, ChatUser("other", "Other", "other"),
            "stay in B", 1, false,
        )
        val state = workspace().copy(
            selectedConversation = conversationB,
            chatOutgoingMessages = mapOf(conversationA.id to listOf(local)),
            chatMessages = Loadable.Ready(ChatMessagePage(listOf(visibleB), null, false)),
        )

        val converged = applyChatActionOutcome(state, completed(target, remote))

        assertEquals(listOf(visibleB), (converged.chatMessages as Loadable.Ready).value.messages)
        assertFalse(converged.chatOutgoingMessages.getValue(conversationA.id).any { it.id == local.id })
        assertTrue(converged.chatOutgoingMessages.getValue(conversationA.id).any { it.id == remote.id })
    }

    @Test
    fun `明确移除附件失败气泡会清理目标分桶和待释放URI且不污染其他会话`() {
        val conversationA = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
            "conversation-a", "A", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
        )
        val conversationB = io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation(
            "conversation-b", "B", io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind.DIRECT,
        )
        val local = ChatMessage(
            "local:file", conversationA.id, ChatUser("me", "Me", "me"), "", 1, true,
            clientRequestId = "request-file", deliveryState = ChatDeliveryState.FAILED,
        )
        val visibleB = ChatMessage(
            "message-b", conversationB.id, ChatUser("other", "Other", "other"), "B", 1, false,
        )
        val state = workspace().copy(
            selectedConversation = conversationB,
            chatOutgoingMessages = mapOf(conversationA.id to listOf(local)),
            chatMessages = Loadable.Ready(ChatMessagePage(listOf(visibleB), null, false)),
            chatPendingAttachmentUris = mapOf(local.id to Uri.EMPTY),
        )

        val removed = removeLocalChatMessage(state, local)

        assertTrue(removed.chatOutgoingMessages.getValue(conversationA.id).isEmpty())
        assertFalse(removed.chatPendingAttachmentUris.containsKey(local.id))
        assertEquals(listOf(visibleB), (removed.chatMessages as Loadable.Ready).value.messages)
    }

    @Test
    fun `销毁工作区时待释放附件URI会去重`() {
        val state = workspace().copy(
            chatPendingAttachmentUris = mapOf(
                "local-a" to Uri.EMPTY,
                "local-a-retry" to Uri.EMPTY,
            ),
        )

        assertEquals(listOf(Uri.EMPTY), chatPendingAttachmentUrisForRelease(state))
    }

    @Test fun `回读失败或内容不同都不能把未知恢复为可重发`() = runBlocking {
        val f = ChatProtocolFixture(); val action = f.prepare(ChatActionDraft(ChatActionKind.SEND, f.channelId, text = "hello"))
        f.readFailure = IOException("synthetic readback failure")
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        f.readFailure = null; f.posts = "[${f.post("different")}]"
        assertEquals(ChatActionPhase.SUBMITTED, f.execute(action).checkpoint.phase)
        f.posts = "[${f.post()}]"
        assertEquals(ChatActionPhase.COMPLETED, f.execute(action).checkpoint.phase)
        assertEquals(1, f.writes.size)
    }

    @Test fun `附件动作预检失败时未提交投影允许处置`() {
        val item = ChatActionItem("request-a", ChatActionKind.ATTACHMENT, "conversation-a", failure = DsmFailure(null, "failed", "retry"))
        val entry = ChatActionsState(listOf(item)).presentation("profile-a").entries.getValue(item.id)
        assertFalse(entry.mutationResult!!.submitted)
        assertTrue(item.canEdit); assertTrue(chatMutationCanRemoveFailed(entry)); assertTrue(chatMutationCanContinueEditing(entry))
    }

    @Test fun `附件已预检但写前保存失败仍保留未提交阶段`() {
        val checkpoint = ChatActionCheckpoint("request-a", ChatActionKind.ATTACHMENT, "conversation-a", "user-a")
        val item = ChatActionItem(checkpoint.id, checkpoint.kind, checkpoint.channelId, checkpoint, failure = DsmFailure(null, "failed", "retry"))
        val entry = ChatActionsState(listOf(item)).presentation("profile-a").entries.getValue(item.id)
        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, entry.mutationResult!!.status)
        assertFalse(entry.mutationResult.submitted); assertEquals(MutationResultCounts(0, 0, 0), entry.mutationResult.counts)
        assertFalse(chatMutationRequiresRefresh(entry)); assertTrue(chatMutationCanRemoveFailed(entry))
    }

    @Test
    fun `重试只在失败entry空闲时可用且UI策略与状态策略一致`() {
        val target = target(ChatMutationOperation.TEXT_SEND)
        val failed = ChatMutationEntry(
            target,
            mutationResult = result(MutationResultStatus.CONFIRMED_FAILURE),
        )
        val unavailable = listOf(
            null,
            failed.copy(confirmationRequested = true),
            failed.copy(mutationInProgress = true),
            failed.copy(mutationRefreshInProgress = true),
        )
        assertTrue(failed.retryEnabled)
        assertTrue(canRetryChatMutation(failed))
        unavailable.forEach { entry ->
            assertFalse(entry?.retryEnabled ?: false)
            assertFalse(canRetryChatMutation(entry))
        }
        val succeeded = failed.copy(
            mutationResult = result(MutationResultStatus.CONFIRMED_SUCCESS),
        )
        assertFalse(succeeded.retryEnabled)
        assertFalse(canRetryChatMutation(succeeded))
    }

    @Test
    fun `真实模块导航策略阻止带未收敛Chat写操作离开`() {
        val target = target(ChatMutationOperation.TEXT_SEND)
        val blocked = workspace().copy(
            chatMutationState = ChatMutationWorkspaceState(
                mapOf(target.requestId to ChatMutationEntry(target, mutationInProgress = true)),
            ),
        )
        assertTrue(workspaceNavigationBlockedByChat(blocked, Module.FILES))
        assertFalse(workspaceNavigationBlockedByChat(blocked, Module.CHAT))
        assertFalse(workspaceNavigationBlockedByChat(workspace(), Module.FILES))
        assertFalse(
            canSafelySwitchNas(
                emptyList(),
                emptyList(),
                emptyList(),
                hasActiveChatMutation = chatMutationBlocksWorkspaceExit(blocked.chatMutationState),
            ),
        )
    }

    private fun presentationTarget(profileId: String, operation: ChatMutationOperation, requestId: String,
        conversationId: String? = null, expectedEpochMillis: Long? = null, requestParts: List<String> = emptyList()) =
        ChatMutationTarget(profileId, operation, requestId, conversationId, expectedEpochMillis = expectedEpochMillis,
            requestFingerprint = chatPayloadFingerprint(requestParts))

    private fun completed(target: ChatMutationTarget, message: ChatMessage): ChatActionOutcome {
        val kind = when (target.operation) {
            ChatMutationOperation.TEXT_SEND -> ChatActionKind.SEND
            ChatMutationOperation.ATTACHMENT_SEND -> ChatActionKind.ATTACHMENT
            ChatMutationOperation.POLL_CREATE -> ChatActionKind.POLL_CREATE
            else -> error("Unexpected presentation target")
        }
        return ChatActionOutcome(ChatActionCheckpoint(target.requestId, kind, requireNotNull(target.conversationId), "me",
            remoteId = message.id, phase = ChatActionPhase.COMPLETED, acknowledged = true, submittedAtMillis = 1), message = message)
    }

    private fun target(operation: ChatMutationOperation) = presentationTarget(
        "profile-a", operation, "request-a", "conversation-a", expectedEpochMillis = 1_000,
        requestParts = listOf("payload"),
    )

    private fun workspace() = WorkspaceState(
        NasProfile("profile-a", "NAS", "https://example.invalid", "user"),
        selectedModule = Module.CHAT,
    )

    private fun result(status: MutationResultStatus): MutationResult {
        val uncertain = status in setOf(
            MutationResultStatus.PARTIAL_SUCCESS,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        )
        val counts = when (status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> MutationResultCounts(1, 0, 0)
            MutationResultStatus.PARTIAL_SUCCESS -> MutationResultCounts(1, 0, 1)
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> MutationResultCounts(0, 0, 1)
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> MutationResultCounts(0, 0, 0)
            else -> MutationResultCounts(0, 1, 0)
        }
        return MutationResult(
            1,
            status,
            "chatTextSend",
            submitted = status !in setOf(
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                MutationResultStatus.CONFIRMED_FAILURE,
                MutationResultStatus.PERMISSION_DENIED,
                MutationResultStatus.UNSUPPORTED,
            ),
            requiresRefresh = uncertain,
            counts = counts,
            errorCategory = if (status == MutationResultStatus.CONFIRMED_SUCCESS) null
                else MutationErrorCategory.UNKNOWN,
        )
    }
}
