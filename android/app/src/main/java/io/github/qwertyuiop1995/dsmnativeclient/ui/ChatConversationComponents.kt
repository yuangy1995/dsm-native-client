package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.AlarmAdd
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material.icons.outlined.Poll
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.ChatMutationEntry
import io.github.qwertyuiop1995.dsmnativeclient.ChatMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.chatMutationCanRemoveFailed
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import java.text.DateFormat
import java.util.Date

/**
 * 聊天会话组件仅消费现有状态并通过既有 ViewModel 事件出口发起操作，保持页面交互与生命周期不变。
 */
internal fun WorkspaceState.chatMutationInProgress(
    vararg operations: ChatMutationOperation,
): Boolean = chatMutationState.entries.values.any { entry ->
    entry.target.operation in operations &&
        (entry.confirmationRequested || entry.mutationInProgress || entry.mutationRefreshInProgress)
}

@Composable
internal fun ConversationList(
    state: WorkspaceState,
    model: AppViewModel,
    modifier: Modifier = Modifier.fillMaxSize(),
) {
    Column(modifier) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.module_chat),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = model::openNewChatConversation) {
                Icon(Icons.Outlined.PersonAdd, stringResource(R.string.new_conversation))
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            LoadableContent(
                value = state.conversations,
                emptyTitle = stringResource(R.string.no_conversations),
                emptyMessage = stringResource(R.string.no_conversations_description),
                onRetry = { model.load(io.github.qwertyuiop1995.dsmnativeclient.domain.Module.CHAT) },
            ) { conversations ->
                LazyColumn(Modifier.fillMaxSize()) {
                    items(conversations, key = { it.id }) { conversation ->
                        ListItem(
                            headlineContent = {
                                Text(conversation.title.ifBlank { stringResource(R.string.unnamed_conversation) })
                            },
                            supportingContent = {
                                Text(
                                    conversation.latestPreview ?: pluralStringResource(
                                        R.plurals.member_count,
                                        conversation.memberCount,
                                        conversation.memberCount,
                                    ),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            leadingContent = { Icon(Icons.Outlined.ChatBubbleOutline, contentDescription = null) },
                            trailingContent = {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    if (conversation.unreadCount > 0) {
                                        Badge {
                                            Text(conversation.unreadCount.coerceAtMost(99).toString())
                                        }
                                    }
                                    IconButton(
                                        onClick = { model.toggleChatConversationPin(conversation.id) },
                                    ) {
                                        Icon(
                                            Icons.Outlined.PushPin,
                                            contentDescription = stringResource(
                                                if (conversation.isPinnedLocally) {
                                                    R.string.unpin_conversation
                                                } else {
                                                    R.string.pin_conversation
                                                },
                                                conversation.title,
                                            ),
                                            tint = if (conversation.isPinnedLocally) {
                                                MaterialTheme.colorScheme.primary
                                            } else {
                                                MaterialTheme.colorScheme.onSurfaceVariant
                                            },
                                        )
                                    }
                                }
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .clickable { model.openConversation(conversation) }
                                .semantics(mergeDescendants = true) {},
                        )
                        HorizontalDivider(Modifier.padding(start = 72.dp))
                    }
                }
            }
        }
    }
}

@Composable
internal fun ConversationDetail(
    state: WorkspaceState,
    model: AppViewModel,
    showBack: Boolean = true,
    modifier: Modifier = Modifier.fillMaxSize(),
) {
    val conversation = state.selectedConversation ?: return
    val context = LocalContext.current
    val reminderMutationInProgress = state.chatMutationInProgress(
        ChatMutationOperation.REMINDER_SET,
        ChatMutationOperation.REMINDER_DELETE,
    )
    var pendingSave by remember { mutableStateOf<Pair<String, ChatAttachment>?>(null) }
    val attachmentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
        onResult = { uri -> if (uri != null) model.sendChatAttachment(uri) },
    )
    val attachmentSaver = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/octet-stream"),
        onResult = { uri ->
            val pending = pendingSave
            if (uri != null && pending != null) model.saveChatAttachment(pending.first, pending.second, uri)
            pendingSave = null
        },
    )
    Column(modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (showBack) {
                IconButton(onClick = model::closeConversation) {
                    Icon(
                        Icons.AutoMirrored.Outlined.ArrowBack,
                        contentDescription = stringResource(R.string.back_to_conversations),
                    )
                }
            }
            Text(
                conversation.title.ifBlank { stringResource(R.string.unnamed_conversation) },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 8.dp).weight(1f),
            )
            if (conversation.kind == ConversationKind.GROUP) {
                IconButton(onClick = model::showChatMembers) {
                    Icon(Icons.Outlined.Group, stringResource(R.string.view_group_members))
                }
            }
            if (state.supportsChatReminders) {
                IconButton(onClick = model::showChatReminders) {
                    Icon(Icons.Outlined.Notifications, stringResource(R.string.manage_chat_reminders))
                }
            }
            if (state.supportsChatScheduledMessages) {
                IconButton(onClick = model::showChatScheduledMessages) {
                    Icon(Icons.Outlined.Schedule, stringResource(R.string.manage_scheduled_messages))
                }
            }
            if (state.supportsChatPollCreation) {
                IconButton(onClick = model::openChatPollComposer) {
                    Icon(Icons.Outlined.Poll, stringResource(R.string.create_chat_poll))
                }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (val messages = state.chatMessages) {
                Loadable.Idle, Loadable.Loading -> Box(Modifier.fillMaxSize(), Alignment.Center) {
                    CircularProgressIndicator()
                }
                is Loadable.Failed -> PhotoFailureForChat(messages, model, conversation)
                is Loadable.Ready -> if (messages.value.messages.isEmpty()) {
                    EmptyState(
                        stringResource(R.string.no_messages),
                        stringResource(R.string.no_messages_description),
                        Icons.Outlined.ChatBubbleOutline,
                    )
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        if (messages.value.hasMore) {
                            item {
                                Box(Modifier.fillMaxWidth().padding(8.dp), Alignment.Center) {
                                    Button(
                                        onClick = model::loadOlderChatMessages,
                                        enabled = !state.chatIsLoadingMore,
                                    ) {
                                        if (state.chatIsLoadingMore) {
                                            CircularProgressIndicator(Modifier.size(18.dp))
                                        }
                                        Text(stringResource(R.string.load_older_messages))
                                    }
                                }
                            }
                        }
                        items(messages.value.messages, key = ChatMessage::id) { message ->
                            val mutation = state.chatMutationState.entry(message.clientRequestId)
                            MessageBubble(
                                message = message,
                                mutation = mutation,
                                onRetry = { model.retryChatMessage(message.id) },
                                onRemove = { model.removeFailedChatMessage(message.id) },
                                onCancelUpload = { model.cancelChatAttachment(message.id) },
                                thumbnail = state.chatAttachmentThumbnails[message.id],
                                onPreviewAttachment = { attachment ->
                                    model.previewChatAttachment(message.id, attachment)
                                },
                                onSaveAttachment = { attachment ->
                                    pendingSave = message.id to attachment
                                    attachmentSaver.launch(attachment.name)
                                },
                                onSetReminder = {
                                    showChatReminderPicker(context) { remindAt ->
                                        model.setChatReminder(message.id, remindAt)
                                    }
                                },
                                canSetReminder = state.supportsChatReminders,
                                reminderMutationInProgress = reminderMutationInProgress,
                                onRefreshMutation = {
                                    mutation?.let { model.refreshChatMutation(it.target.requestId) } ?: false
                                },
                                onContinueEditingMutation = {
                                    mutation?.let {
                                        model.continueEditingChatMutation(it.target.requestId)
                                    } ?: false
                                },
                                onDismissMutation = {
                                    mutation?.let { model.dismissChatMutation(it.target.requestId) } ?: false
                                },
                                onCancelMutation = {
                                    mutation?.let { model.cancelChatMutation(it.target.requestId) } ?: false
                                },
                            )
                        }
                        item { Spacer(Modifier.padding(bottom = 12.dp)) }
                    }
                }
            }
        }
        ChatComposer(
            text = state.chatDrafts[conversation.id].orEmpty(),
            enabled = state.chatMessages is Loadable.Ready,
            onTextChange = model::updateChatDraft,
            onSend = model::sendChatMessage,
            onAttach = { attachmentPicker.launch(arrayOf("image/*", "video/*", "application/*", "text/*", "audio/*")) },
        )
    }
}

@Composable
internal fun MessageBubble(
    message: ChatMessage,
    mutation: ChatMutationEntry?,
    onRetry: () -> Unit,
    onRemove: () -> Boolean,
    onCancelUpload: () -> Unit,
    thumbnail: Loadable<ByteArray>?,
    onPreviewAttachment: (ChatAttachment) -> Unit,
    onSaveAttachment: (ChatAttachment) -> Unit,
    onSetReminder: () -> Unit,
    canSetReminder: Boolean,
    reminderMutationInProgress: Boolean,
    onRefreshMutation: () -> Boolean,
    onContinueEditingMutation: () -> Boolean,
    onDismissMutation: () -> Boolean,
    onCancelMutation: () -> Boolean,
) {
    val sender = message.sender?.displayName ?: stringResource(R.string.unknown_sender)
    val time = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
        .format(Date(message.createdAtEpochSeconds * 1_000))
    val mutationDelivery = if (mutation != null) chatMutationFeedbackMessage(mutation) else null
    val delivery = mutationDelivery ?: when (
        message.deliveryState
    ) {
        ChatDeliveryState.SENDING -> stringResource(R.string.message_sending)
        ChatDeliveryState.FAILED -> stringResource(R.string.message_send_failed)
        ChatDeliveryState.SENT -> stringResource(
            if (message.isMine) R.string.message_sent else R.string.message_received,
        )
    }
    val accessibilityContent = when {
        message.body.isNotBlank() -> message.body
        message.attachments.isNotEmpty() -> pluralStringResource(
            R.plurals.message_attachment_content,
            message.attachments.size,
            message.attachments.size,
        )
        message.poll != null -> stringResource(R.string.message_poll_content, message.poll.question)
        else -> stringResource(R.string.message_empty_content)
    }
    val spoken = stringResource(
        R.string.message_accessibility_delivery,
        sender,
        time,
        accessibilityContent,
        delivery,
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .semantics { contentDescription = spoken },
        horizontalArrangement = if (message.isMine) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 520.dp)
                .background(
                    if (message.isMine) MaterialTheme.colorScheme.primaryContainer
                    else MaterialTheme.colorScheme.surfaceVariant,
                    RoundedCornerShape(16.dp),
                )
                .padding(12.dp),
        ) {
            Text(
                sender,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clearAndSetSemantics {},
            )
            if (message.body.isNotBlank()) {
                Text(
                    message.body,
                    modifier = Modifier.padding(top = 4.dp).clearAndSetSemantics {},
                )
            }
            message.attachments.forEach { attachment ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                ) {
                    Icon(Icons.Outlined.AttachFile, contentDescription = null)
                    Text(
                        attachment.name,
                        modifier = Modifier.padding(start = 4.dp).weight(1f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (message.deliveryState == ChatDeliveryState.SENT) {
                        if (attachment.isPreviewableImage() || attachment.isPreviewableVideo()) {
                            TextButton(onClick = { onPreviewAttachment(attachment) }) {
                                if (thumbnail is Loadable.Loading) {
                                    CircularProgressIndicator(Modifier.size(18.dp))
                                } else {
                                    Text(stringResource(R.string.preview_attachment))
                                }
                            }
                        }
                        IconButton(onClick = { onSaveAttachment(attachment) }) {
                            Icon(
                                Icons.Outlined.Download,
                                stringResource(R.string.save_attachment, attachment.name),
                            )
                        }
                    }
                }
            }
            message.poll?.let { poll ->
                Text(
                    stringResource(
                        if (poll.allowsMultipleSelection) {
                            R.string.chat_poll_multiple
                        } else {
                            R.string.chat_poll_single
                        },
                    ),
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(top = 8.dp),
                )
                poll.options.forEach { option ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    ) {
                        if (option.isSelectedByCurrentUser) {
                            Icon(
                                Icons.Outlined.Check,
                                contentDescription = stringResource(R.string.chat_poll_selected),
                                modifier = Modifier.size(18.dp),
                            )
                        }
                        Text(
                            stringResource(
                                R.string.chat_poll_option_result,
                                option.text,
                                option.voteCount,
                            ),
                            modifier = Modifier.padding(start = 4.dp),
                        )
                    }
                }
                if (poll.isAnonymous) {
                    Text(
                        stringResource(R.string.chat_poll_anonymous),
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
                if (poll.isClosed) {
                    Text(
                        stringResource(R.string.chat_poll_closed),
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
            message.attachmentProgress?.let { progress ->
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                )
                Text(
                    stringResource(R.string.attachment_upload_progress, (progress * 100).toInt()),
                    style = MaterialTheme.typography.labelSmall,
                )
                TextButton(onClick = onCancelUpload, enabled = progress < 1f) {
                    Text(stringResource(R.string.cancel_upload))
                }
            }
            Text(
                time,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp).clearAndSetSemantics {},
            )
            if (canSetReminder && message.deliveryState == ChatDeliveryState.SENT) {
                TextButton(
                    onClick = onSetReminder,
                    enabled = !reminderMutationInProgress,
                ) {
                    Icon(Icons.Outlined.AlarmAdd, contentDescription = null)
                    Text(
                        stringResource(R.string.set_chat_reminder),
                        modifier = Modifier.padding(start = 4.dp),
                    )
                }
            }
            when (message.deliveryState) {
                ChatDeliveryState.SENDING -> Text(
                    stringResource(R.string.message_sending),
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(top = 4.dp).clearAndSetSemantics {},
                )
                ChatDeliveryState.FAILED -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (canRetryChatMutation(mutation)) {
                            Button(onClick = onRetry) {
                                Text(stringResource(R.string.retry_send))
                            }
                        }
                        if (chatMutationCanRemoveFailed(mutation)) {
                            IconButton(onClick = { onRemove() }) {
                                Icon(
                                    Icons.Outlined.Close,
                                    stringResource(R.string.remove_failed_message),
                                )
                            }
                        }
                    }
                }
                ChatDeliveryState.SENT -> Unit
            }
            mutation?.let {
                val failedMessage = message.deliveryState == ChatDeliveryState.FAILED
                ChatSendMutationFeedback(
                    entry = it,
                    onRefresh = onRefreshMutation,
                    onContinueEditing = onContinueEditingMutation,
                    onDismiss = if (failedMessage) onRemove else onDismissMutation,
                    onCancel = onCancelMutation,
                    canClose = if (failedMessage) {
                        chatMutationCanRemoveFailed(it)
                    } else {
                        canDismissChatMutationFeedback(it)
                    },
                )
            }
        }
    }
}
