package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FolderUploadDialog(feature: FolderUploadFeatureModel) {
    val state by feature.ui.collectAsStateWithLifecycle()
    FolderUploadContent(state, feature::close, feature::start) { state.plan?.let { feature.retry(it.taskId) } }
}

@Composable
internal fun FolderUploadContent(state: FolderUploadUiState, onClose: () -> Unit, onStart: (Boolean) -> Unit, onRetry: () -> Unit) {
    val plan = state.plan
    if (plan == null) {
        state.message?.let { message -> AlertDialog(onDismissRequest = onClose, text = {
            Text(if (message == R.string.folder_upload_too_large) stringResource(message, MAX_FILE_TREE_DOCUMENTS) else stringResource(message))
        }, confirmButton = { TextButton(onClose) { Text(stringResource(R.string.close)) } }) }
        return
    }
    var overwrite by rememberSaveable(plan.taskId) { mutableStateOf(false) }
    var confirmOverwrite by remember { mutableStateOf(false) }
    var showProblems by rememberSaveable(plan.taskId) { mutableStateOf(false) }
    ClientPageDialog(stringResource(if (state.preview) R.string.folder_upload_title else R.string.folder_upload_details), { if (!state.busy) onClose() }) {
        Column(Modifier.fillMaxSize().testTag("folder_upload_dialog")) {
            Text(plan.rootName, Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.titleMedium)
            Text(plan.destinationPath, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodyMedium)
            val files = plan.entries.count { !it.source.isDirectory && it.source.sourceIssue == null }
            val folders = plan.entries.count { it.source.isDirectory }
            Text(stringResource(R.string.folder_upload_counts,
                pluralStringResource(R.plurals.folder_upload_file_count, files, files),
                pluralStringResource(R.plurals.folder_upload_directory_count, folders, folders)), Modifier.padding(16.dp))
            if (state.preview) {
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(overwrite, enabled = !state.busy, role = Role.Switch, onValueChange = { overwrite = it })
                    .padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.folder_upload_replace), Modifier.weight(1f))
                    Switch(overwrite, null, enabled = !state.busy)
                }
            } else {
                Text(stringResource(R.string.folder_upload_outcomes,
                    plan.entries.count { it.state == FolderUploadEntryState.SUCCEEDED },
                    plan.entries.count { it.state == FolderUploadEntryState.SKIPPED },
                    plan.entries.count { it.state !in setOf(FolderUploadEntryState.SUCCEEDED, FolderUploadEntryState.SKIPPED) }), Modifier.padding(horizontal = 16.dp))
            }
            state.message?.let { Text(stringResource(it), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(!showProblems, { showProblems = false }, label = { Text(stringResource(R.string.show_all_items)) })
                FilterChip(showProblems, { showProblems = true }, label = { Text(stringResource(R.string.folder_upload_problems)) })
            }
            val entries = plan.entries.filter { !showProblems || it.state !in setOf(FolderUploadEntryState.SUCCEEDED, FolderUploadEntryState.SKIPPED) }
            if (entries.isEmpty()) Box(Modifier.weight(1f).fillMaxWidth(), Alignment.Center) { Text(stringResource(R.string.folder_upload_no_problems)) }
            else LazyColumn(Modifier.weight(1f).testTag("folder_upload_items"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(entries, key = { it.source.id }) { entry -> ClientGroup {
                    Column(Modifier.fillMaxWidth().padding(12.dp)) {
                        Text(entry.source.relativePath, style = MaterialTheme.typography.bodyMedium)
                        Text(stringResource(folderEntryStatus(entry)), style = MaterialTheme.typography.bodySmall,
                            color = if (entry.state in setOf(FolderUploadEntryState.FAILED, FolderUploadEntryState.UNRESOLVED)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } }
            }
            if (state.preview) Button({ if (overwrite) confirmOverwrite = true else onStart(false) },
                Modifier.fillMaxWidth().padding(16.dp).heightIn(min = 48.dp).testTag("folder_upload_start"), enabled = !state.busy) {
                Text(stringResource(if (state.busy) R.string.transfer_waiting else R.string.folder_upload_title))
            } else if (state.taskState in setOf(TransferState.FAILED, TransferState.PAUSED, TransferState.CANCELLED)) {
                Button(onRetry, Modifier.fillMaxWidth().padding(16.dp).heightIn(min = 48.dp)) { Text(stringResource(R.string.folder_upload_continue)) }
            }
        }
    }
    if (confirmOverwrite) AlertDialog(onDismissRequest = { confirmOverwrite = false },
        title = { Text(stringResource(R.string.folder_upload_replace)) }, text = { Text(stringResource(R.string.folder_upload_replace_warning)) },
        confirmButton = { TextButton({ confirmOverwrite = false; onStart(true) }) { Text(stringResource(R.string.folder_upload_replace_action)) } },
        dismissButton = { TextButton({ confirmOverwrite = false }) { Text(stringResource(R.string.cancel)) } })
}

private fun folderEntryStatus(entry: FolderUploadEntry): Int = when {
    entry.source.sourceIssue != null || entry.errorKind == "SOURCE_UNAVAILABLE" -> R.string.folder_upload_source_failed
    entry.errorKind == "PARENT_UNAVAILABLE" -> R.string.folder_upload_parent_failed
    entry.errorKind == "TARGET_CONFLICT" -> R.string.folder_upload_target_conflict
    else -> when (entry.state) {
        FolderUploadEntryState.PENDING -> R.string.transfer_waiting
        FolderUploadEntryState.SUBMITTING -> R.string.transfer_uploading
        FolderUploadEntryState.SUCCEEDED -> if (entry.source.isDirectory) R.string.folder_upload_directory_ready else R.string.transfer_completed
        FolderUploadEntryState.SKIPPED -> R.string.folder_upload_skipped
        FolderUploadEntryState.FAILED -> R.string.folder_upload_item_failed
        FolderUploadEntryState.UNRESOLVED -> R.string.folder_upload_interrupted
        FolderUploadEntryState.PAUSED -> R.string.transfer_paused
        FolderUploadEntryState.CANCELLED -> R.string.transfer_cancelled
    }
}

@Composable
internal fun FileUploadSourceDialog(onClose: () -> Unit, onFiles: () -> Unit, onFolder: () -> Unit) {
    AlertDialog(onDismissRequest = onClose, title = { Text(stringResource(R.string.choose_upload_source)) },
        text = { Column {
            ActionRow(Icons.Outlined.UploadFile, stringResource(R.string.upload_files), onClick = onFiles)
            ActionRow(Icons.Outlined.FolderOpen, stringResource(R.string.upload_folder), onClick = onFolder)
            Text(stringResource(R.string.upload_folder_description), Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } }, confirmButton = { TextButton(onClose) { Text(stringResource(R.string.cancel)) } })
}
