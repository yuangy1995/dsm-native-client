package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.ui.ConversationDetail
import io.github.qwertyuiop1995.dsmnativeclient.ui.theme.LanStashTheme
import java.text.DateFormat
import java.util.Date
import org.junit.Rule
import org.junit.Test

class ChatMessageAccessibilityTest {
    @get:Rule
    val rule = createComposeRule()

    @Test
    fun 消息按发送者时间内容状态提供单一摘要且操作仍可访问() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val sender = ChatUser("member-1", "Synthetic sender", "synthetic")
        val createdAt = 1_800_000_000L
        val time = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
            .format(Date(createdAt * 1_000))
        val conversation = ChatConversation(
            id = "channel-1",
            title = "Synthetic chat",
            kind = ConversationKind.DIRECT,
        )
        val failedRequestId = "request-failed"
        val messages = listOf(
            ChatMessage(
                id = "sent",
                conversationId = conversation.id,
                sender = sender,
                body = "Accessible sent body",
                createdAtEpochSeconds = createdAt,
                isMine = true,
                deliveryState = ChatDeliveryState.SENT,
            ),
            ChatMessage(
                id = "received",
                conversationId = conversation.id,
                sender = sender,
                body = "Accessible received body",
                createdAtEpochSeconds = createdAt,
                isMine = false,
                deliveryState = ChatDeliveryState.SENT,
            ),
            ChatMessage(
                id = "failed",
                conversationId = conversation.id,
                sender = sender,
                body = "Accessible failed body",
                createdAtEpochSeconds = createdAt,
                isMine = true,
                clientRequestId = failedRequestId,
                deliveryState = ChatDeliveryState.FAILED,
            ),
            ChatMessage(
                id = "attachment",
                conversationId = conversation.id,
                sender = sender,
                body = "",
                createdAtEpochSeconds = createdAt,
                isMine = false,
                attachments = listOf(ChatAttachment("attachment-1", "Synthetic.pdf", "application/pdf", 8)),
            ),
        )

        rule.setContent {
            LanStashTheme {
                ConversationDetail(
                    state = WorkspaceState(
                        profile = NasProfile(
                            "synthetic",
                            "Synthetic",
                            "https://nas.example.invalid",
                            "operator",
                        ),
                        selectedModule = Module.CHAT,
                        selectedConversation = conversation,
                        conversations = Loadable.Ready(listOf(conversation)),
                        chatMessages = Loadable.Ready(ChatMessagePage(messages, null, false)),
                        chatMutationState = ChatMutationWorkspaceState(
                            mapOf(
                                failedRequestId to ChatMutationEntry(
                                    target = ChatMutationTarget(
                                        profileId = "synthetic",
                                        operation = ChatMutationOperation.TEXT_SEND,
                                        requestId = failedRequestId,
                                        conversationId = conversation.id,
                                        requestFingerprint = "0".repeat(64),
                                    ),
                                    mutationResult = MutationResult(
                                        schemaVersion = 1,
                                        status = MutationResultStatus.CONFIRMED_FAILURE,
                                        operation = "chatTextSend",
                                        submitted = false,
                                        requiresRefresh = false,
                                        counts = MutationResultCounts(0, 1, 0),
                                    ),
                                    generation = 1,
                                ),
                            ),
                        ),
                    ),
                    model = model,
                )
            }
        }

        listOf(
            "Accessible sent body" to R.string.message_sent,
            "Accessible received body" to R.string.message_received,
            "Accessible failed body" to R.string.message_send_failed,
        ).forEach { (body, status) ->
            rule.onNodeWithContentDescription(
                context.getString(
                    R.string.message_accessibility_delivery,
                    sender.displayName,
                    time,
                    body,
                    context.getString(status),
                ),
            ).assertIsDisplayed()
        }
        rule.onNodeWithContentDescription(
            context.getString(
                R.string.message_accessibility_delivery,
                sender.displayName,
                time,
                context.resources.getQuantityString(R.plurals.message_attachment_content, 1, 1),
                context.getString(R.string.message_received),
            ),
        ).assertIsDisplayed()
        rule.onAllNodesWithContentDescription(context.getString(R.string.chat_message_options))
            .assertCountEquals(messages.size)
        rule.onNodeWithContentDescription(context.getString(R.string.remove_failed_message))
            .assertIsDisplayed()
    }

    @Test
    fun 未确认发送必须保留气泡刷新且不能重发或移除() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = AppViewModel(ApplicationProvider.getApplicationContext<Application>())
        val conversation = ChatConversation(
            id = "channel-1",
            title = "Synthetic chat",
            kind = ConversationKind.DIRECT,
        )
        val requestId = "request-unverified"
        val target = ChatMutationTarget(
            profileId = "synthetic",
            operation = ChatMutationOperation.TEXT_SEND,
            requestId = requestId,
            conversationId = conversation.id,
            requestFingerprint = "0".repeat(64),
        )
        val message = ChatMessage(
            id = "local:$requestId",
            conversationId = conversation.id,
            sender = ChatUser("current", "Operator", "operator"),
            body = "Unverified body",
            createdAtEpochSeconds = 1_800_000_000L,
            isMine = true,
            clientRequestId = requestId,
            deliveryState = ChatDeliveryState.FAILED,
        )
        val result = MutationResult(
            schemaVersion = 1,
            status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            operation = "chatTextSend",
            submitted = true,
            requiresRefresh = true,
            counts = MutationResultCounts(0, 0, 1),
        )
        rule.setContent {
            LanStashTheme {
                ConversationDetail(
                    state = WorkspaceState(
                        profile = NasProfile(
                            "synthetic",
                            "Synthetic",
                            "https://nas.example.invalid",
                            "operator",
                        ),
                        selectedModule = Module.CHAT,
                        selectedConversation = conversation,
                        conversations = Loadable.Ready(listOf(conversation)),
                        chatMessages = Loadable.Ready(ChatMessagePage(listOf(message), null, false)),
                        chatMutationState = ChatMutationWorkspaceState(
                            entries = mapOf(
                                requestId to ChatMutationEntry(
                                    target = target,
                                    mutationResult = result,
                                    generation = 1,
                                ),
                            ),
                        ),
                    ),
                    model = model,
                )
            }
        }

        rule.onNodeWithText(context.getString(R.string.chat_action_waiting))
            .assertIsDisplayed()
        rule.onNodeWithText(context.getString(R.string.refresh)).assertIsDisplayed()
        rule.onAllNodesWithText(context.getString(R.string.retry_send)).assertCountEquals(0)
        rule.onAllNodesWithText(context.getString(R.string.chat_mutation_continue_editing))
            .assertCountEquals(0)
        rule.onAllNodesWithContentDescription(context.getString(R.string.remove_failed_message))
            .assertCountEquals(0)
    }
}
