package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.containers.*
import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

@Composable internal fun ContainerImagesScreen(model: ContainerImageModel, canSearch: Boolean, onSearch: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(model) { if (model.state.value.confirmation == null) model.refresh() }
    LaunchedEffect(model, owner) { owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) { while (isActive) { delay(5_000); model.poll() } } }
    ContainerImagesContent(state, canSearch, model::refresh, onSearch, model::requestDelete, model::dismiss)
}

@Composable internal fun ContainerImagesContent(state: ContainerImageState, canSearch: Boolean, onRefresh: () -> Unit, onSearch: () -> Unit,
    onDelete: (List<ContainerImageEntry>) -> Boolean, onDismiss: (String) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var selection by remember { mutableStateOf(setOf<String>()) }
    var details by remember { mutableStateOf<ContainerImageEntry?>(null) }
    // 下载进度定时读取不能关闭用户正在查看的详情或清空其他映像的选择。
    LaunchedEffect(state.images) {
        selection = selection.intersect(state.images.map { it.id }.toSet())
    }
    val filtered = state.images.filter { (it.reference ?: it.repository).contains(query, ignoreCase = true) }
    val selected = state.images.filter { it.id in selection }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(query, { query = it }, stringResource(R.string.cm_image_search), modifier = Modifier.weight(1f))
            IconButton(onClick = onRefresh, enabled = !state.busy) { Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh)) }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (canSearch) OutlinedButton(onClick = onSearch, enabled = !state.busy) { Text(stringResource(R.string.search_images)) }
            if (selected.isNotEmpty()) OutlinedButton(onClick = { onDelete(selected) }, enabled = !state.busy && selected.all { it.canDelete }) { Text(stringResource(R.string.cm_image_delete)) }
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.failure?.let { error -> item { Text(containerErrorText(error), color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) } }
            if (state.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            items(state.activities, key = { "activity:${it.id}" }) { activity -> ContainerImageActivityCard(activity, state.readings[activity.id], state.busy, state.failure != null, onRefresh) { onDismiss(activity.id) } }
            if (!state.usageAvailable) item { Text(stringResource(R.string.cm_image_usage_unknown)) }
            if (state.loaded && filtered.isEmpty()) item { Text(stringResource(if (state.images.isEmpty()) R.string.cm_image_empty else R.string.cm_image_no_matches), Modifier.padding(vertical = 24.dp)) }
            items(filtered, key = { it.id }) { entry ->
                val label = entry.reference ?: entry.repository
                ClientGroup { ListItem(headlineContent = { Text(label) }, supportingContent = {
                    Column { entry.sizeBytes?.let { Text(Formatter.formatFileSize(LocalContext.current, it)) }
                        if (entry.inUse == true) Text(stringResource(R.string.cm_image_used)) }
                }, leadingContent = { Checkbox(checked = entry.id in selection, enabled = !state.busy && entry.canDelete,
                    onCheckedChange = { selection = if (it) selection + entry.id else selection - entry.id }, modifier = Modifier.semantics { contentDescription = label }) },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { details = entry }) }
            }
        }
    }
    details?.let { selectedEntry ->
        val entry = state.images.singleOrNull { it.id == selectedEntry.id }
        ClientSheet(selectedEntry.reference ?: selectedEntry.repository, onDismiss = { details = null }) {
            if (entry == null) Text(stringResource(R.string.cm_image_changed)) else {
                entry.sizeBytes?.let { Text(Formatter.formatFileSize(LocalContext.current, it)) }
                Text(stringResource(when (entry.inUse) { true -> R.string.cm_image_used; false -> R.string.cm_image_unused; null -> R.string.cm_image_usage_unknown }))
                Button(onClick = { if (onDelete(listOf(entry))) details = null }, enabled = !state.busy && entry.canDelete) { Text(stringResource(R.string.cm_image_delete)) }
            }
        }
    }
}

@Composable private fun ContainerImageActivityCard(activity: ContainerImageActivity, reading: ContainerImagePullReading?, busy: Boolean, readFailed: Boolean, onRefresh: () -> Unit, onDismiss: () -> Unit) {
    ClientGroup {
        Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(if (activity.operation == ContainerImageOperation.PULL) R.string.cm_image_download else R.string.cm_image_delete), style = MaterialTheme.typography.titleSmall)
            reading?.let { if (it.repository != null && it.tag != null) Text(imageReference(it.repository, it.tag)) }
            if (activity.operation == ContainerImageOperation.PULL) {
                Text(stringResource(when (activity.stage) {
                    ContainerStage.PREPARED, ContainerStage.CANCELLED -> R.string.cm_not_sent
                    ContainerStage.SUBMITTED -> R.string.cm_result_unavailable
                    ContainerStage.ACCEPTED -> if (activity.task == null || readFailed) R.string.cm_result_unavailable else R.string.cm_image_downloading
                    ContainerStage.VERIFIED -> R.string.cm_image_available
                    ContainerStage.REJECTED -> R.string.cm_image_failed
                }))
                if (activity.pending && !readFailed && reading?.percentage != null) LinearProgressIndicator(progress = { reading.percentage }, modifier = Modifier.fillMaxWidth())
            } else {
                Text(stringResource(R.string.cm_image_removed_count, activity.removed.size, activity.targets.size))
                if (activity.stage == ContainerStage.REJECTED) Text(stringResource(R.string.cm_rejected))
                if (activity.stage == ContainerStage.CANCELLED) Text(stringResource(R.string.cm_not_sent))
            }
            if (activity.pending) Text(stringResource(if (activity.operation == ContainerImageOperation.PULL && activity.task == null) R.string.cm_image_no_receipt else R.string.cm_image_pending))
            TextButton(onClick = if (activity.pending) onRefresh else onDismiss, enabled = !busy) { Text(stringResource(if (activity.pending) R.string.refresh else R.string.close)) }
        }
    }
}

@Composable internal fun ContainerImageDialogs(model: ContainerImageModel) {
    val state by model.state.collectAsStateWithLifecycle()
    ContainerImageConfirmationSheet(state.confirmation, state.busy, model::cancel, model::confirm)
}
@Composable internal fun ContainerImageConfirmationSheet(confirmation: ContainerImageConfirmation?, busy: Boolean, onCancel: () -> Unit, onConfirm: (ContainerImageConfirmation) -> Boolean) {
    confirmation ?: return
    val title = if (confirmation is ContainerImageConfirmation.Pull) R.string.cm_image_download else R.string.cm_image_delete
    ClientSheet(stringResource(title), onDismiss = onCancel, dismissEnabled = !busy) {
        when (confirmation) {
            is ContainerImageConfirmation.Pull -> { Text(imageReference(confirmation.repository, confirmation.tag)); Text(stringResource(R.string.cm_image_download_risk)) }
            is ContainerImageConfirmation.Delete -> { confirmation.targets.forEach { Text(it.reference ?: it.repository) }; Text(stringResource(R.string.cm_image_delete_risk)) }
        }
        Button(onClick = { onConfirm(confirmation) }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(title)) }
        TextButton(onClick = onCancel, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
    }
}
