package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientGroup

@Composable
internal fun PackageControlContent(state: NasPackageCenterState, enabled: Boolean, refresh: () -> Unit,
    request: (PackageInfo, PackageMutationOperation) -> Boolean, cancel: () -> Unit,
    confirm: (NasPackageControlConfirmation) -> Boolean, review: (PackageActivityRecord) -> Unit, discard: (String) -> Unit,
    packageIcon: (PackageInfo) -> Bitmap? = { null }, onLoadPackageIcon: ((PackageInfo) -> Unit)? = null,
    onUpdate: ((PackageInfo) -> Unit)? = null) {
    var query by rememberSaveable { mutableStateOf("") }
    val rows = state.installed.orEmpty().filter { query.isBlank() || it.name.contains(query, true) || it.id.contains(query, true) }
    val available = enabled && !state.busy && !state.fileCopying && !state.installedLoading && state.installedFailure == null &&
        state.failure == null && state.controlConfirmation == null && state.activities.all { it.terminal } &&
        state.progress?.phase !in setOf(NasPackageInstallPhase.DOWNLOADING, NasPackageInstallPhase.INSTALLING)
    LaunchedEffect(enabled) { if (!enabled) cancel() }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 16.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(query, { query = it; cancel() }, label = { Text(stringResource(R.string.pc_search)) },
                    singleLine = true, modifier = Modifier.weight(1f))
                TextButton(refresh, enabled = !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
            }
            if (state.installedLoading || state.busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
        }
        state.activities.firstOrNull { it.kind == PackageActivityKind.CONTROL }?.let { record -> item {
            PackageControlActivity(record, state.busy, { review(record) }, { discard(record.id) }, state.installed)
        } }
        state.installedFailure?.let { error -> item { PackageError(error, refresh, retry = true) } }
        when {
            state.installed == null && !state.installedLoading && state.installedFailure == null -> item {
                Text(stringResource(R.string.packages_unavailable_hint), Modifier.padding(24.dp))
            }
            state.installed?.isEmpty() == true -> item {
                Column(Modifier.padding(24.dp)) { Text(stringResource(R.string.packages_empty)); Text(stringResource(R.string.packages_empty_hint)) }
            }
            state.installed != null && rows.isEmpty() -> item { Text(stringResource(R.string.pc_control_no_matches), Modifier.padding(24.dp)) }
            else -> items(rows, key = PackageInfo::id) { row ->
                PackageManagementRow(row, available, { target, action -> request(target, action) }, packageIcon(row), onLoadPackageIcon, onUpdate,
                    allowedActions = state.controlActions)
            }
        }
    }
    state.controlConfirmation?.let { expected -> PackageMutationConfirmationDialog(expected.target, expected.action,
        onConfirm = { confirm(expected) }, onDismiss = cancel) }
}

@Composable
internal fun PackageControlActivity(record: PackageActivityRecord, busy: Boolean, review: () -> Unit, discard: () -> Unit,
    installed: List<PackageInfo>? = null) {
    val item = record.items.single()
    ClientGroup(Modifier.padding(16.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(installed?.singleOrNull { it.id == item.packageId }?.name ?: item.packageId, style = MaterialTheme.typography.titleSmall)
            Text(stringResource(when (item.phase) {
                PackageActivityPhase.COMPLETED -> when (item.step) {
                    NasPackageWriteStep.START.name -> R.string.pc_control_started
                    NasPackageWriteStep.STOP.name -> R.string.pc_control_stopped
                    else -> R.string.pc_control_uninstalled
                }
                PackageActivityPhase.REJECTED -> R.string.pc_control_rejected
                PackageActivityPhase.CANCELLED -> R.string.pc_control_not_sent
                else -> R.string.pc_control_pending
            }))
            if (record.terminal) TextButton(discard, enabled = !busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.pc_remove_record)) }
            else TextButton(review, enabled = !busy, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
        }
    }
}
