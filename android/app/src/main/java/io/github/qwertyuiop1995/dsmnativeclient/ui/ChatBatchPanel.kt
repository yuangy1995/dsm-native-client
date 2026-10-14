package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
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
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet

@Composable
internal fun ChatBatchPanel(state: ChatBatchesState, actions: ChatActionsState, model: ChatBatchModel, actionModel: ChatActionModel) {
    if (state.focusedId == null) return
    val batch = state.focused
    ClientSheet(stringResource(batch?.record?.kind?.titleResource() ?: R.string.chat_batches), { model.focus(null) }) {
        state.failure?.let { Text(it.localize(LocalContext.current).combined) }
        if (batch == null) {
            if (state.items.isEmpty()) Text(stringResource(R.string.chat_activity_empty))
            state.items.asReversed().forEach { row -> TextButton(onClick = { model.focus(row.record.id) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(stringResource(R.string.chat_batch_title, stringResource(row.record.kind.titleResource()), row.record.actionIds.size))
            } }
        } else {
            val items = batch.record.actionIds.map { id -> actions.items.firstOrNull { it.id == id } }
            Text(stringResource(R.string.chat_batch_progress, items.count { it?.checkpoint?.phase == ChatActionPhase.COMPLETED }, items.size))
            if (batch.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            batch.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
            if (batch.confirmation && batch.record.kind == ChatActionKind.DELETE) Text(stringResource(R.string.chat_delete_batch_warning, items.size))
            if (batch.confirmation && batch.record.kind == ChatActionKind.CLOSE) Text(stringResource(R.string.chat_close_conversation_warning))
            items.filterNotNull().forEach { item ->
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    item.draft?.conversation?.title?.takeIf { it.isNotBlank() }?.let { Text(it) }
                    item.draft?.original?.body?.takeIf { it.isNotBlank() }?.let { Text(it, maxLines = 3) }
                    Text(stringResource(item.statusResource()))
                    item.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
                    if (item.canRefresh) TextButton(onClick = { actionModel.refresh(item.id) }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
                }
            }
            val pending = items.any { it?.checkpoint?.phase == ChatActionPhase.SUBMITTED }
            if (pending) Text(stringResource(R.string.chat_action_delayed))
            if (!batch.busy && !pending && items.any { it != null && it.checkpoint?.finished != true }) Button(onClick = { model.continueBatch(batch.record.id) },
                enabled = items.none { it == null || it.busy }, modifier = Modifier.fillMaxWidth().testTag("chat_batch_continue")) {
                Text(stringResource(if (batch.confirmation) batch.record.kind.titleResource() else R.string.continue_action))
            }
            if (!batch.busy && !pending) TextButton(onClick = { model.discard(batch.record.id) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.remove)) }
        }
    }
}
