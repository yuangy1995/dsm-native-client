package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun ChatMessageActionsSheet(message: ChatMessage, state: WorkspaceState, model: AppViewModel,
    onDismiss: () -> Unit, onForward: () -> Unit, onSelect: (() -> Unit)? = null) {
    var vote by remember(message.id) { mutableStateOf(false) }
    var choices by remember(message.id, message.poll) { mutableStateOf(message.poll?.options?.filter { it.isSelectedByCurrentUser }?.map { it.id }?.toSet().orEmpty()) }
    ClientSheet(stringResource(if (vote) R.string.chat_vote else R.string.chat_message_options), onDismiss) {
        if (message.body.isNotBlank()) Text(message.body, maxLines = 5)
        if (message.deliveryState != ChatDeliveryState.SENT || message.id.startsWith("local:")) {
            ClientRow(stringResource(R.string.chat_activity), Icons.Outlined.Schedule) { model.chatActions.focus(message.clientRequestId); onDismiss() }
        } else if (vote) {
            message.poll?.let { poll ->
                Text(poll.question)
                poll.options.forEach { option ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(option.id in choices, role = Role.Checkbox) { selected ->
                        choices = if (selected) { if (poll.allowsMultipleSelection) choices + option.id else setOf(option.id) } else choices - option.id
                    }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(option.id in choices, null)
                        Text(stringResource(R.string.chat_poll_option_result, option.text, option.voteCount), Modifier.weight(1f))
                    }
                }
                Button(onClick = { model.chatActions.request(ChatActionDraft(ChatActionKind.VOTE, message.conversationId,
                    original = message, choiceIds = choices)); onDismiss() }, enabled = choices.isNotEmpty(), modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.chat_vote))
                }
            }
        } else {
            ClientRow(stringResource(R.string.chat_reply), Icons.Outlined.ChatBubbleOutline) { onDismiss(); model.chatContent.openThread(message) }
            if (message.isMine && message.poll == null && !message.isEncrypted && message.kind in setOf("normal", "file"))
                ClientRow(stringResource(R.string.chat_edit_message), Icons.Outlined.Edit) { onDismiss(); model.chatContent.edit(message) }
            message.poll?.takeIf { it.canVote && !it.isClosed && (it.closesAtEpochMillis ?: Long.MAX_VALUE) > System.currentTimeMillis() }?.let {
                ClientRow(stringResource(R.string.chat_vote), Icons.Outlined.Poll) { vote = true }
            }
            val conversation = (state.conversations as? Loadable.Ready)?.value?.firstOrNull { it.id == message.conversationId }
                ?: state.selectedConversation?.takeIf { it.id == message.conversationId }
            if (conversation?.kind == ConversationKind.GROUP) ClientRow(stringResource(if (message.isPinned) R.string.chat_unpin_message else R.string.chat_pin_message), Icons.Outlined.PushPin) {
                model.chatActions.request(ChatActionDraft(if (message.isPinned) ChatActionKind.UNPIN else ChatActionKind.PIN, message.conversationId, original = message)); onDismiss()
            }
            if (message.poll == null && !message.isEncrypted) ClientRow(stringResource(R.string.chat_forward), Icons.Outlined.Share) { onForward() }
            if (message.isMine && (message.threadId == null || message.threadId == message.id)) ClientRow(stringResource(R.string.chat_delete_message), Icons.Outlined.Delete) {
                model.chatActions.request(ChatActionDraft(ChatActionKind.DELETE, message.conversationId, original = message, conversation = conversation), confirm = true); onDismiss()
            }
            onSelect?.let { ClientRow(stringResource(R.string.chat_select_messages), Icons.Outlined.Checklist) { it(); onDismiss() } }
        }
    }
}

@Composable
internal fun ChatForwardSheet(messages: List<ChatMessage>, state: WorkspaceState, model: AppViewModel, onDismiss: () -> Unit) {
    var selected by remember(messages) { mutableStateOf(emptySet<String>()) }
    val sourceIds = messages.map { it.conversationId }.toSet()
    val channels = (state.conversations as? Loadable.Ready)?.value.orEmpty().filter { !it.isEncrypted && it.id !in sourceIds }
    ClientSheet(stringResource(R.string.chat_forward), onDismiss) {
        if (channels.isEmpty()) Text(stringResource(R.string.chat_forward_empty))
        channels.forEach { channel -> Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .toggleable(channel.id in selected, role = Role.Checkbox) { checked -> selected = if (checked) selected + channel.id else selected - channel.id },
            verticalAlignment = Alignment.CenterVertically) {
            Checkbox(channel.id in selected, null)
            Text(channel.title.ifBlank { stringResource(R.string.unnamed_conversation) }, Modifier.weight(1f))
        } }
        TextButton(onClick = model::openNewChatConversation, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.new_conversation)) }
        Button(onClick = {
            val drafts = messages.map { ChatActionDraft(ChatActionKind.FORWARD, it.conversationId, original = it, targetIds = selected.sorted()) }
            if (messages.size == 1) { model.chatActions.request(drafts.single()); onDismiss() }
            else if (model.chatBatches.request(drafts)) onDismiss()
        }, enabled = selected.isNotEmpty(), modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.chat_forward)) }
    }
}
