package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun ChatActionPanel(state: ChatActionsState, model: ChatActionModel) {
    if (state.focusedId == null) return
    val item = state.focused
    ClientSheet(stringResource(item?.kind?.titleResource() ?: R.string.chat_activity), { model.focus(null) }) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            state.storageFailure?.let {
                Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
                TextButton(onClick = model::restore) { Text(stringResource(R.string.retry)) }
            }
            if (item == null) {
                if (state.restoring) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (state.items.isEmpty() && !state.restoring && state.storageFailure == null) Text(stringResource(R.string.chat_activity_empty))
                state.items.asReversed().forEach { row ->
                    TextButton(onClick = { model.focus(row.id) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Column(Modifier.fillMaxWidth()) {
                            Text(stringResource(row.kind.titleResource()))
                            Text(stringResource(row.statusResource()), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            } else {
                item.draft?.conversation?.title?.takeIf { it.isNotBlank() }?.let { Text(it) }
                item.draft?.original?.body?.takeIf { it.isNotBlank() }?.let { Text(it, maxLines = 5) }
                item.draft?.text?.takeIf { it.isNotBlank() && it != item.draft.original?.body }?.let { Text(it, maxLines = 5) }
                item.draft?.attachment?.displayName?.let { Text(it) }
                if (item.confirmation) Text(stringResource(when (item.kind) {
                    ChatActionKind.DELETE -> R.string.chat_delete_message_warning
                    ChatActionKind.CLOSE -> R.string.chat_close_conversation_warning
                    ChatActionKind.REMINDER_DELETE -> R.string.remove_chat_reminder_message
                    ChatActionKind.SCHEDULE_DELETE -> R.string.cancel_scheduled_message_message
                    else -> R.string.chat_apply_change
                })) else Text(stringResource(item.statusResource()))
                if (item.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                item.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
                if (item.checkpoint?.phase == ChatActionPhase.SUBMITTED) Text(stringResource(R.string.chat_action_delayed))
                if (item.kind == ChatActionKind.FORWARD) item.checkpoint?.forwardTargets?.let { targets ->
                    Text(stringResource(R.string.chat_forward_progress, targets.count { it.confirmedId != null }, targets.size))
                }
                if (item.confirmation) {
                    Button(onClick = { model.confirm(item.id) }, modifier = Modifier.fillMaxWidth().testTag("chat_action_confirm")) { Text(stringResource(item.kind.titleResource())) }
                    TextButton(onClick = { model.cancel(item.id) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) }
                } else {
                    if (item.canEdit && item.draft != null) {
                        if (item.kind == ChatActionKind.DELETE) Text(stringResource(R.string.chat_delete_message_warning))
                        if (item.kind == ChatActionKind.CLOSE) Text(stringResource(R.string.chat_close_conversation_warning))
                        Button(onClick = { if (item.checkpoint?.phase == ChatActionPhase.REJECTED) model.retryRejected(item.id) else model.resumeReady(item.id) }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(item.kind.titleResource()))
                        }
                    }
                    if (item.canRefresh) OutlinedButton(onClick = { model.refresh(item.id) }, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Outlined.Refresh, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.refresh))
                    }
                    if (item.canContinueGroup) Button(onClick = { model.refresh(item.id, continueGroup = true) }, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.chat_continue_group))
                    }
                    if (!item.busy && item.checkpoint?.phase != ChatActionPhase.SUBMITTED) TextButton(
                        onClick = { model.discard(item.id) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                        Text(stringResource(R.string.remove))
                    }
                    TextButton(onClick = { model.focus(null) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.close)) }
                }
            }
        }
    }
}

internal fun ChatActionKind.titleResource(): Int = when (this) {
    ChatActionKind.SEND -> R.string.send_message
    ChatActionKind.ATTACHMENT -> R.string.chat_attachment_action
    ChatActionKind.REPLY -> R.string.chat_reply
    ChatActionKind.EDIT -> R.string.chat_edit_message
    ChatActionKind.VOTE -> R.string.chat_vote
    ChatActionKind.PIN -> R.string.chat_pin_message
    ChatActionKind.UNPIN -> R.string.chat_unpin_message
    ChatActionKind.DELETE -> R.string.chat_delete_message
    ChatActionKind.CLOSE -> R.string.chat_close_conversation
    ChatActionKind.REMINDER_SET -> R.string.chat_reminders
    ChatActionKind.REMINDER_DELETE -> R.string.remove_chat_reminder_title
    ChatActionKind.SCHEDULE_CREATE -> R.string.chat_schedule_action
    ChatActionKind.SCHEDULE_DELETE -> R.string.cancel_scheduled_message_title
    ChatActionKind.POLL_CREATE -> R.string.create_chat_poll
    ChatActionKind.DIRECT -> R.string.new_conversation
    ChatActionKind.GROUP -> R.string.private_group_name
    ChatActionKind.FORWARD -> R.string.chat_forward
}

internal fun ChatActionItem.statusResource(): Int = when {
    busy -> R.string.chat_action_working
    confirmation -> R.string.chat_apply_change
    checkpoint?.phase == ChatActionPhase.COMPLETED -> R.string.chat_action_complete
    checkpoint?.phase == ChatActionPhase.SUBMITTED -> R.string.chat_action_waiting
    checkpoint?.phase == ChatActionPhase.REJECTED || failure != null -> R.string.chat_action_failed
    else -> R.string.chat_action_unsent
}
