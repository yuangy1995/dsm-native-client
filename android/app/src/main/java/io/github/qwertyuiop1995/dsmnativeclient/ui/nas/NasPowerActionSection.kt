package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerStage
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasPowerActionModel
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasPowerActionState

@Composable
internal fun NasPowerActionSection(model: NasPowerActionModel, enabled: Boolean) {
    val state by model.state.collectAsState()
    var recovery by remember(state.record?.id) { mutableStateOf(false) }
    LaunchedEffect(model) { model.refresh() }
    LaunchedEffect(state.canRestore) { if (!state.canRestore) recovery = false }
    NasPowerActionContent(state, enabled, { model.request(it) }, model::refresh, { recovery = true }, model::dismiss)
    state.confirmation?.let { action ->
        PowerActionConfirmationDialog(action, { model.confirm(action) }, model::cancel)
    }
    if (recovery && state.canRestore && !state.busy) AlertDialog(
        onDismissRequest = { recovery = false },
        title = { Text(stringResource(R.string.power_restore_title)) },
        text = { Text(stringResource(R.string.power_restore_message)) },
        confirmButton = { TextButton(enabled = enabled, onClick = {
            state.record?.let { model.restore(it) }; recovery = false
        }) { Text(stringResource(R.string.power_device_restored)) } },
        dismissButton = { TextButton(onClick = { recovery = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun NasPowerActionContent(state: NasPowerActionState, enabled: Boolean, onAction: (NasPowerAction) -> Unit,
    onRefresh: () -> Unit, onRestore: () -> Unit, onDismiss: () -> Unit) {
    ListItem(headlineContent = { Text(stringResource(R.string.nas_power)) },
        supportingContent = { Text(stringResource(R.string.nas_power_hint)) },
        leadingContent = { Icon(Icons.Outlined.PowerSettingsNew, null) })
    if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 16.dp))
    val record = state.record
    if (record != null || state.failure != null) Card(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (record != null) {
                Text(stringResource(when (record.stage) {
                    NasPowerStage.ACCEPTED -> if (record.action == NasPowerAction.SHUTDOWN) R.string.shutdown_accepted else R.string.reboot_accepted
                    NasPowerStage.SUBMITTED -> R.string.power_result_needs_device_check_title
                    NasPowerStage.PREPARED -> R.string.power_request_sending
                    NasPowerStage.REJECTED -> R.string.settings_feedback_failed_title
                    NasPowerStage.CANCELLED -> R.string.power_not_sent
                }), style = MaterialTheme.typography.titleMedium)
                if (record.stage == NasPowerStage.ACCEPTED) Text(stringResource(R.string.power_accepted_not_completed))
                if (record.stage == NasPowerStage.SUBMITTED) Text(stringResource(R.string.power_result_needs_device_check_message))
                when {
                    record.restored -> Text(stringResource(R.string.power_restored_message))
                    record.needsRecovery && !state.canRestore -> Text(stringResource(R.string.power_sign_in_again))
                }
            }
            state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.canRestore) TextButton(enabled = enabled && !state.busy, onClick = onRestore, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text(stringResource(R.string.power_restore_title))
                }
                if (state.failure != null) TextButton(enabled = !state.busy, onClick = onRefresh, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
                if (!state.blocked) TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.done)) }
            }
        }
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        TextButton(enabled = enabled && !state.blocked && state.confirmation == null, onClick = { onAction(NasPowerAction.REBOOT) }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
            Text(stringResource(R.string.restart_nas))
        }
        TextButton(enabled = enabled && !state.blocked && state.confirmation == null, onClick = { onAction(NasPowerAction.SHUTDOWN) }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
            Text(stringResource(R.string.shut_down_nas), color = MaterialTheme.colorScheme.error)
        }
    }
}
