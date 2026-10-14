package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import kotlinx.coroutines.flow.distinctUntilChanged

@Composable
internal fun ChatContentPanels(workspace: WorkspaceState, model: AppViewModel, contentVisible: Boolean = true) {
    val state by model.chatContent.state.collectAsState()
    var selected by remember { mutableStateOf<ChatMessage?>(null) }
    var forward by remember { mutableStateOf<List<ChatMessage>?>(null) }
    val panel = state.panel ?: return
    val title = stringResource(when (panel) {
        ChatContentPanel.SEARCH -> R.string.chat_search_messages
        ChatContentPanel.THREAD -> R.string.chat_replies
        ChatContentPanel.PINNED -> R.string.chat_pinned_messages
        ChatContentPanel.EDIT -> R.string.chat_edit_message
    })
    if (panel == ChatContentPanel.EDIT) ClientSheet(title, model.chatContent::close) {
        when (val editing = state.editing) {
            is Loadable.Ready -> {
                OutlinedTextField(state.editText, model.chatContent::updateEdit, Modifier.fillMaxWidth().testTag("chat_edit_text"), label = { Text(stringResource(R.string.message)) }, minLines = 3)
                Button(onClick = model.chatContent::saveEdit, enabled = state.editText.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.save)) }
            }
            is Loadable.Failed -> Text(editing.error.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
            else -> LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    } else ClientPageDialog(title, model.chatContent::close) {
        Column(Modifier.fillMaxSize().widthIn(max = 960.dp)) {
            if (panel == ChatContentPanel.SEARCH) Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(state.query, model.chatContent::updateQuery, Modifier.weight(1f).testTag("chat_search_query"),
                    label = { Text(stringResource(R.string.chat_search_messages)) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { model.chatContent.search() }))
                TextButton(onClick = { model.chatContent.search() }, enabled = state.query.isNotBlank()) { Text(stringResource(R.string.chat_search)) }
            }
            state.failure?.let { Text(it.localize(LocalContext.current).combined, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
            when (panel) {
                ChatContentPanel.SEARCH -> when (val results = state.search) {
                    Loadable.Idle -> ChatReadEmpty(R.string.chat_search_hint)
                    Loadable.Loading -> ChatReadLoading()
                    is Loadable.Failed -> ChatReadFailure(results.error) { model.chatContent.search() }
                    is Loadable.Ready -> if (results.value.messages.isEmpty()) ChatReadEmpty(R.string.chat_search_empty) else {
                        LazyColumn(Modifier.weight(1f)) {
                            items(results.value.messages, key = { "${it.conversationId}:${it.id}" }) { message ->
                                ChatReadMessage(message, { model.chatContent.openThread(message) }, { selected = message })
                            }
                            if (results.value.nextOffset != null) item {
                                TextButton(onClick = { model.chatContent.search(more = true) }, enabled = !state.searchLoadingMore,
                                    modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.chat_more_results)) }
                            }
                        }
                    }
                }
                ChatContentPanel.PINNED -> when (val pinned = state.pinned) {
                    is Loadable.Ready -> if (pinned.value.isEmpty()) ChatReadEmpty(R.string.chat_pinned_empty) else LazyColumn(Modifier.weight(1f)) {
                        items(pinned.value, key = { it.id }) { message -> ChatReadMessage(message, { model.chatContent.openThread(message) }, { selected = message }) }
                    }
                    is Loadable.Failed -> ChatReadFailure(pinned.error) { state.channelId?.let(model.chatContent::openPinned) }
                    else -> ChatReadLoading()
                }
                ChatContentPanel.THREAD -> when (val thread = state.thread) {
                    is Loadable.Ready -> {
                        val listState = rememberLazyListState()
                        val outgoing = workspace.chatOutgoingMessages[thread.value.root.conversationId].orEmpty().filter { it.threadId == thread.value.root.id && it.id != thread.value.root.id }
                        val replies = (thread.value.replies.messages + outgoing).distinctBy { it.id }.sortedBy { it.createdAtEpochMillis }
                        LaunchedEffect(listState, replies, contentVisible, selected, forward) {
                            snapshotFlow { listState.layoutInfo.visibleItemsInfo.map { it.key } }.distinctUntilChanged().collect { visible ->
                                if (contentVisible && selected == null && forward == null)
                                    replies.lastOrNull { it.id in visible }?.let { model.chatContent.markVisible(it, thread = true) }
                            }
                        }
                        LazyColumn(Modifier.weight(1f), state = listState) {
                            item(key = "root") { ChatReadMessage(thread.value.root, {}, { selected = thread.value.root }); HorizontalDivider() }
                            if (thread.value.replies.hasMore) item {
                                TextButton(onClick = model.chatContent::loadOlderReplies, enabled = !state.threadLoadingMore,
                                    modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.load_older_messages)) }
                            }
                            if (replies.isEmpty()) item { Text(stringResource(R.string.chat_replies_empty), Modifier.padding(16.dp)) }
                            items(replies, key = { it.id }) { message -> ChatReadMessage(message, {}, { selected = message }) }
                        }
                        ChatComposer(state.reply, true, model.chatContent::updateReply, model.chatContent::sendReply)
                    }
                    is Loadable.Failed -> ChatReadFailure(thread.error, model.chatContent::retryThread)
                    else -> ChatReadLoading()
                }
                else -> Unit
            }
        }
    }
    selected?.let { message -> ChatMessageActionsSheet(message, workspace, model, { selected = null },
        onForward = { forward = listOf(message); selected = null }) }
    forward?.let { messages -> ChatForwardSheet(messages, workspace, model, { forward = null }) }
}

@Composable
internal fun ChatReadMessage(message: ChatMessage, onOpen: () -> Unit, onMore: () -> Unit) {
    ListItem(headlineContent = { Text(message.sender?.displayName ?: stringResource(R.string.unknown_sender), style = MaterialTheme.typography.labelLarge) },
        supportingContent = { Column {
            if (message.body.isNotBlank()) Text(message.body)
            message.poll?.let { Text(it.question) }
            message.attachments.forEach { Text(it.name) }
            if (message.deliveryState == ChatDeliveryState.SENDING) Text(stringResource(R.string.message_sending))
            if (message.deliveryState == ChatDeliveryState.FAILED) Text(stringResource(R.string.chat_action_waiting))
        } }, trailingContent = { IconButton(onClick = onMore) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.chat_message_options)) } },
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClick = onOpen).padding(vertical = 4.dp))
}
@Composable private fun ChatReadEmpty(resource: Int) { Box(Modifier.fillMaxSize().padding(24.dp), Alignment.Center) { Text(stringResource(resource)) } }
@Composable private fun ChatReadLoading() { Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() } }
@Composable private fun ChatReadFailure(failure: DsmFailure, retry: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(failure.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
        TextButton(onClick = retry) { Text(stringResource(R.string.retry)) }
    }
}
