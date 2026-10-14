package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import kotlinx.coroutines.delay

@Composable internal fun NasSmartTestSection(model: NasSmartTestModel, enabled: Boolean) {
    val state by model.state.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(model, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            model.refresh()
            while (true) { delay(4_000); model.pollRunning() }
        }
    }
    NasSmartTestContent(state, enabled, model::refresh, model::load, model::request, model::cancel, model::confirm, model::dismiss)
}

@Composable internal fun NasSmartTestContent(state: NasSmartState, enabled: Boolean = true, onRefresh: () -> Unit,
    onLoad: (NasStorageDisk) -> Unit, onRequest: (NasStorageDisk, NasDiskTestType?) -> Boolean,
    onCancel: () -> Unit, onConfirm: (NasSmartConfirmation) -> Boolean, onDismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val matches = state.disks.filter { query.isBlank() || it.name.contains(query.trim(), true) || it.model?.contains(query.trim(), true) == true }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.drive_tests), style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(query, { query = it; onCancel() }, label = { Text(stringResource(R.string.smart_search)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = onRefresh, enabled = enabled && !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.smart_refresh_drives)) }
        if (state.busy || !state.loaded && state.failure == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.record?.let { record ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.disks.singleOrNull { smartIdentity(it) == record.identity }?.let { Text(it.name, style = MaterialTheme.typography.titleMedium) }
                    val label = when (record.stage) {
                        NasSmartStage.VERIFIED -> if (record.action == NasSmartAction.STOP) R.string.smart_test_stopped else R.string.smart_activity_running
                        NasSmartStage.REJECTED -> R.string.smart_activity_rejected
                        NasSmartStage.CANCELLED -> R.string.smart_activity_not_sent
                        NasSmartStage.PREPARED -> R.string.smart_test_action_in_progress_message
                        else -> R.string.smart_activity_pending
                    }
                    Text(stringResource(label))
                    if (!record.pending) TextButton(onClick = onDismiss, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.done)) }
                }
            }
        }
        state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) }
        if (state.loaded && !state.busy && state.failure == null && matches.isEmpty()) Text(stringResource(
            if (state.disks.isEmpty()) R.string.smart_test_empty_message else R.string.smart_no_matches))
        matches.forEach { disk ->
            SmartTestDiskCard(disk, state.statuses[disk.id] ?: Loadable.Idle, enabled && !state.blocked,
                readEnabled = enabled && !state.busy && state.record?.pending != true, onLoad = { onLoad(disk) }, onRequest = { onRequest(disk, it) })
            if (disk.id in state.historyFailures) Text(stringResource(R.string.smart_history_failed), color = MaterialTheme.colorScheme.error)
        }
    }
    state.confirmation?.let { confirmation -> SmartTestConfirmationDialog(confirmation.disk, confirmation.action.type, { onConfirm(confirmation) }, onCancel) }
}
