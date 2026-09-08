package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ConversationList(state: WorkspaceState, model: AppViewModel, modifier: Modifier = Modifier.fillMaxSize()) {
    var query by rememberSaveable(state.profile.id) { mutableStateOf("") }
    var searchVisible by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf<ChatConversation?>(null) }
    val entry = LocalClientEntry.current
    val focus = LocalFocusManager.current
    val optionsLabel = stringResource(R.string.client_conversation_options)
    LaunchedEffect(entry?.revision) { if (entry?.action == ClientEntryAction.SEARCH) searchVisible = true; entry?.consume() }
    BackHandler(enabled = searchVisible) { query = ""; searchVisible = false }
    val newConversation = stringResource(R.string.new_conversation)
    Scaffold(modifier = modifier, contentWindowInsets = WindowInsets(0), floatingActionButton = {
        ExtendedFloatingActionButton(onClick = model::openNewChatConversation,
            icon = { Icon(Icons.Outlined.PersonAdd, null) }, text = { Text(newConversation) },
            modifier = Modifier.semantics { contentDescription = newConversation },
            containerColor = MaterialTheme.colorScheme.primary, contentColor = MaterialTheme.colorScheme.onPrimary)
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (searchVisible) Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                ClientSearchField(query, { query = it }, stringResource(R.string.client_search_conversations), Modifier.weight(1f))
                IconButton(onClick = { query = ""; searchVisible = false }) { Icon(Icons.Outlined.Close, stringResource(R.string.close)) }
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                LoadableContent(state.conversations, stringResource(R.string.no_conversations),
                    stringResource(R.string.no_conversations_description), onRetry = { model.load(Module.CHAT) }) { conversations ->
                    val visible = conversations.filter { it.title.contains(query.trim(), ignoreCase = true) }
                    if (visible.isEmpty()) EmptyState(stringResource(R.string.client_no_matching_conversations),
                        stringResource(R.string.client_search_recovery), Icons.Outlined.Search)
                    else LazyColumn(contentPadding = PaddingValues(bottom = 96.dp)) {
                        items(visible, key = ChatConversation::id) { conversation ->
                            ListItem(
                                headlineContent = { Text(conversation.title.ifBlank { stringResource(R.string.unnamed_conversation) },
                                    fontWeight = if (conversation.unreadCount > 0) FontWeight.Bold else FontWeight.Medium,
                                    maxLines = 2, overflow = TextOverflow.Ellipsis) },
                                supportingContent = { Text(conversation.latestPreview ?: pluralStringResource(R.plurals.member_count,
                                    conversation.memberCount, conversation.memberCount), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                leadingContent = {
                                    Box(Modifier.size(44.dp).clip(CircleShape).background(MaterialTheme.colorScheme.secondaryContainer), Alignment.Center) {
                                        Icon(if (conversation.kind == ConversationKind.GROUP) Icons.Outlined.Group else Icons.Outlined.ChatBubbleOutline,
                                            null, tint = MaterialTheme.colorScheme.primary)
                                    }
                                },
                                trailingContent = {
                                    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                        if (conversation.unreadCount > 0) Badge { Text(conversation.unreadCount.coerceAtMost(99).toString()) }
                                        if (conversation.isPinnedLocally) Icon(Icons.Outlined.PushPin, null, Modifier.size(14.dp))
                                    }
                                },
                                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                                modifier = Modifier.fillMaxWidth().heightIn(min = 80.dp).combinedClickable(
                                    onClick = { focus.clearFocus(); model.openConversation(conversation) },
                                    onLongClickLabel = optionsLabel, onLongClick = { selected = conversation }),
                            )
                            HorizontalDivider(Modifier.padding(start = 76.dp))
                        }
                    }
                }
            }
        }
    }
    selected?.let { conversation ->
        ClientSheet(conversation.title.ifBlank { stringResource(R.string.unnamed_conversation) }, { selected = null }) {
            ClientRow(stringResource(if (conversation.isPinnedLocally) R.string.unpin_conversation else R.string.pin_conversation,
                conversation.title), Icons.Outlined.PushPin) { model.toggleChatConversationPin(conversation.id); selected = null }
        }
    }
}
