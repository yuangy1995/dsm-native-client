package io.github.qwertyuiop1995.dsmnativeclient.ui.transfers

import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.CardDefaults
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.runtime.remember

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.FilterChip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskSummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.EmptyState
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatRemainingDuration

internal enum class TransferSourceFilter {
    ALL,
    DOWNLOADS,
    UPLOADS,
    NAS_TASKS,
}

internal enum class TransferPage { APP_TRANSFERS, FILE_TASKS }

internal enum class FileBackgroundTaskFilter { ALL, ACTIVE, FINISHED }

internal data class UploadMutationFeedbackPolicy(
    @StringRes val stage: Int,
    @StringRes val message: Int,
    val result: MutationResult,
)

internal fun uploadMutationFeedbackPolicy(
    task: io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask,
): UploadMutationFeedbackPolicy? {
    val lifecycle = task.uploadMutation ?: return null
    val uploadResult = lifecycle.uploadResult
    val result = uploadResult ?: lifecycle.directoryResult ?: return null
    if (uploadResult == null && result.status == MutationResultStatus.CONFIRMED_SUCCESS &&
        task.state == TransferState.FAILED
    ) return null
    val stage = if (uploadResult != null) {
        R.string.transfer_mutation_upload_stage
    } else {
        R.string.transfer_mutation_folder_stage
    }
    val message = when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> if (uploadResult != null) {
            R.string.transfer_mutation_upload_confirmed
        } else {
            R.string.transfer_mutation_folder_confirmed
        }
        MutationResultStatus.PARTIAL_SUCCESS -> R.string.service_action_partial
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> R.string.service_action_unverified
        MutationResultStatus.PERMISSION_DENIED -> R.string.service_action_permission_denied
        MutationResultStatus.UNSUPPORTED -> R.string.service_action_unsupported
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.service_action_cancelled
        MutationResultStatus.CONFIRMED_FAILURE -> R.string.service_action_failed
    }
    return UploadMutationFeedbackPolicy(stage, message, result)
}

internal fun TransferSourceFilter.matches(direction: TransferDirection): Boolean = when (this) {
    TransferSourceFilter.ALL -> true
    TransferSourceFilter.DOWNLOADS -> direction == TransferDirection.DOWNLOAD
    TransferSourceFilter.UPLOADS -> direction == TransferDirection.UPLOAD
    TransferSourceFilter.NAS_TASKS -> direction == TransferDirection.SERVER
}

@Composable
internal fun TransfersScreen(state: WorkspaceState, model: AppViewModel) {
    var source by rememberSaveable { mutableStateOf(ClientTaskSource.PHONE) }
    ClientTaskCenterScreen(state, model, source) {
        if (it == ClientTaskSource.DOWNLOADS) model.select(io.github.qwertyuiop1995.dsmnativeclient.domain.Module.DOWNLOADS)
        else source = it
    }
}

@Composable
internal fun AppTransfersContent(state: WorkspaceState, model: AppViewModel) {
    if (state.transfers.isEmpty()) {
        EmptyState(
            stringResource(R.string.no_transfer_tasks),
            stringResource(R.string.transfers_description),
            Icons.Outlined.SwapVert,
        )
        return
    }

    var sourceFilter by rememberSaveable(state.profile.id) {
        mutableStateOf(TransferSourceFilter.ALL)
    }
    var statusFilter by rememberSaveable { mutableStateOf(ClientTaskStatus.ACTIVE) }
    var optionsVisible by remember { mutableStateOf(false) }
    val filteredTransfers = state.transfers.filter { sourceFilter.matches(it.direction) && statusFilter.matches(it) }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(statusFilter == ClientTaskStatus.ACTIVE, onClick = { statusFilter = ClientTaskStatus.ACTIVE },
                    label = { Text(stringResource(R.string.client_active_tasks)) })
                FilterChip(statusFilter == ClientTaskStatus.FINISHED, onClick = { statusFilter = ClientTaskStatus.FINISHED },
                    label = { Text(stringResource(R.string.client_finished_tasks)) })
            }
            IconButton(onClick = { optionsVisible = true }) { Icon(Icons.Outlined.Tune, stringResource(R.string.transfer_filter_source)) }
        }
        if (optionsVisible) ClientSheet(stringResource(R.string.transfer_filter_source), { optionsVisible = false }) {
        LazyRow(
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(TransferSourceFilter.entries, key = TransferSourceFilter::name) { filter ->
                FilterChip(
                    selected = sourceFilter == filter,
                    onClick = { sourceFilter = filter },
                    label = { Text(stringResource(filter.labelResource())) },
                )
            }
        }
        if (state.transfers.any {
                it.state in setOf(
                    TransferState.SUCCEEDED,
                    TransferState.FAILED,
                    TransferState.CANCELLED,
                )
            }) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = model::clearFinishedTransfers) {
                    Text(stringResource(R.string.clear_finished_transfers))
                }
            }
        }
        }
        if (filteredTransfers.isEmpty()) {
            Box(
                modifier = Modifier.weight(1f).fillMaxWidth(),
            ) {
                EmptyState(
                    stringResource(R.string.no_filtered_transfer_tasks),
                    stringResource(R.string.no_filtered_transfer_tasks_description),
                    Icons.Outlined.SwapVert,
                )
            }
            return@Column
        }
        LazyColumn(
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(filteredTransfers, key = { it.id }) { task ->
                TransferTaskCard(
                    task = task,
                    canPause = model.canPauseTransfer(task.id),
                    canResume = model.canResumeTransfer(task.id),
                    canRetry = model.canRetryTransfer(task.id),
                    onPause = { model.pauseTransfer(task.id) },
                    onResume = { model.resumeTransfer(task.id) },
                    onCancel = { model.cancelTransfer(task.id) },
                    onRetry = { model.retryTransfer(task.id) },
                    canRefreshTarget = model.canRefreshFileServerTransfer(task.id),
                    isRefreshingTarget = task.fileServerMutation?.refreshInProgress == true,
                    onOpenAndRefreshTarget = { model.openAndRefreshFileServerTransferTarget(task.id) },
                )
            }
        }
    }
}

@Composable
internal fun FileBackgroundTasksContent(
    tasks: Loadable<FileBackgroundTaskPage>,
    isLoadingMore: Boolean,
    loadMoreFailure: DsmFailure?,
    snapshotObservedAtEpochSeconds: Long? = null,
    isRefreshing: Boolean = false,
    refreshFailure: DsmFailure? = null,
    onRefresh: () -> Unit,
    onRetry: () -> Unit,
    onLoadMore: () -> Unit,
) {
    var filter by rememberSaveable { mutableStateOf(FileBackgroundTaskFilter.ALL) }
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                stringResource(R.string.file_background_tasks_title),
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            IconButton(
                onClick = onRefresh,
                enabled = !isRefreshing,
                modifier = Modifier.size(48.dp),
            ) {
                Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh))
            }
        }
        if (snapshotObservedAtEpochSeconds != null) {
            FileBackgroundTaskSnapshotStatus(
                isRefreshing = isRefreshing,
                refreshFailure = refreshFailure,
            )
        }
        LazyRow(
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(FileBackgroundTaskFilter.entries, key = FileBackgroundTaskFilter::name) { option ->
                FilterChip(
                    selected = filter == option,
                    onClick = { filter = option },
                    label = { Text(stringResource(option.labelResource())) },
                )
            }
        }
        when (tasks) {
            Loadable.Idle, Loadable.Loading -> Box(
                Modifier.fillMaxSize().semantics { liveRegion = LiveRegionMode.Polite },
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Text(
                        stringResource(R.string.file_background_tasks_loading),
                        modifier = Modifier.padding(top = 12.dp),
                    )
                }
            }

            is Loadable.Failed -> {
                val failure = tasks.error.localize(LocalContext.current)
                Box(
                    Modifier.fillMaxSize().semantics { liveRegion = LiveRegionMode.Assertive },
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(Icons.Outlined.ErrorOutline, contentDescription = null)
                        Text(failure.message, style = MaterialTheme.typography.titleMedium)
                        Text(failure.recovery, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Button(onClick = onRetry, modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.retry))
                        }
                    }
                }
            }

            is Loadable.Ready -> {
                val page = tasks.value
                val visibleTasks = page.tasks.filter(filter::matches)
                if (page.tasks.isEmpty()) {
                    EmptyState(
                        stringResource(R.string.no_file_background_tasks),
                        stringResource(R.string.no_file_background_tasks_description),
                        Icons.Outlined.SwapVert,
                    )
                } else if (visibleTasks.isEmpty()) {
                    Column(Modifier.fillMaxSize()) {
                        Box(Modifier.weight(1f).fillMaxWidth()) {
                            EmptyState(
                                stringResource(R.string.no_filtered_file_background_tasks),
                                stringResource(R.string.no_filtered_file_background_tasks_description),
                                Icons.Outlined.SwapVert,
                            )
                        }
                        if (page.hasMore) FileBackgroundTasksLoadMoreFooter(
                            loading = isLoadingMore,
                            failure = loadMoreFailure,
                            onLoadMore = onLoadMore,
                        )
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.weight(1f),
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        items(visibleTasks, key = FileBackgroundTaskSummary::id) { task ->
                            FileBackgroundTaskCard(task)
                        }
                        if (page.hasMore) {
                            item {
                                FileBackgroundTasksLoadMoreFooter(
                                    loading = isLoadingMore,
                                    failure = loadMoreFailure,
                                    onLoadMore = onLoadMore,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FileBackgroundTaskSnapshotStatus(
    isRefreshing: Boolean,
    refreshFailure: DsmFailure?,
) {
    val localizedFailure = refreshFailure?.localize(LocalContext.current)
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .semantics {
                liveRegion = if (refreshFailure != null) {
                    LiveRegionMode.Assertive
                } else {
                    LiveRegionMode.Polite
                }
            },
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            when {
                isRefreshing -> CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                refreshFailure != null -> Icon(
                    Icons.Outlined.ErrorOutline,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                )
                else -> Icon(Icons.Outlined.Info, contentDescription = null)
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    stringResource(
                        when {
                            isRefreshing -> R.string.file_background_tasks_snapshot_refreshing
                            refreshFailure != null -> R.string.file_background_tasks_snapshot_refresh_failed
                            else -> R.string.file_background_tasks_snapshot_saved
                        },
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = if (refreshFailure != null) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
                if (localizedFailure != null) {
                    Text(
                        localizedFailure.recovery,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun FileBackgroundTasksLoadMoreFooter(
    loading: Boolean,
    failure: DsmFailure?,
    onLoadMore: () -> Unit,
) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        failure?.let {
            val localized = it.localize(LocalContext.current)
            Card(
                Modifier
                    .fillMaxWidth()
                    .semantics { liveRegion = LiveRegionMode.Assertive },
            ) {
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
                    Text(
                        stringResource(R.string.file_background_tasks_load_more_failed),
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        localized.recovery,
                        modifier = Modifier.padding(top = 6.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        TextButton(
            onClick = onLoadMore,
            enabled = !loading,
            modifier = Modifier.heightIn(min = 48.dp),
        ) {
            if (loading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            Text(
                stringResource(
                    if (loading) R.string.file_background_tasks_loading_more
                    else R.string.file_background_tasks_load_more,
                ),
                modifier = Modifier.padding(start = if (loading) 8.dp else 0.dp),
            )
        }
    }
}

@Composable
internal fun FileBackgroundTaskCard(task: FileBackgroundTaskSummary) {
    Card {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(task.kind.labelResource()),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                stringResource(task.state.labelResource()),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
            if (task.state == FileBackgroundTaskState.ACTIVE) {
                task.progress?.toFloat()?.let { progress ->
                    LinearProgressIndicator(
                        progress = { progress.coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        stringResource(
                            R.string.nas_task_percent_progress,
                            (progress * 100).toInt().coerceIn(0, 100),
                        ),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            if (task.processedItemCount != null && task.totalItemCount != null) {
                Text(
                    stringResource(
                        R.string.file_background_task_items_progress,
                        task.processedItemCount,
                        task.totalItemCount,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (task.processedBytes != null && task.totalBytes != null) {
                Text(
                    stringResource(
                        R.string.transfer_bytes_progress,
                        formatBytes(task.processedBytes),
                        formatBytes(task.totalBytes),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

@Composable
internal fun TransferTaskCard(
    task: io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask,
    canPause: Boolean,
    canResume: Boolean,
    canRetry: Boolean,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
    canRefreshTarget: Boolean = false,
    isRefreshingTarget: Boolean = false,
    onOpenAndRefreshTarget: () -> Unit = {},
) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val actionsAtBottom = maxWidth < 480.dp || LocalDensity.current.fontScale >= 1.5f
            val actions: @Composable () -> Unit = {
                TransferActions(
                    state = task.state,
                    direction = task.direction,
                    canPause = canPause,
                    canResume = canResume,
                    canRetry = canRetry,
                    onPause = onPause,
                    onResume = onResume,
                    onCancel = onCancel,
                    onRetry = onRetry,
                    canCancelTask = task.canCancel,
                )
            }
            Column(Modifier.fillMaxWidth()) {
                ListItem(
                    headlineContent = {
                        Text(task.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    },
                    supportingContent = { TransferTaskDetails(task) },
                    leadingContent = {
                        Icon(
                            when (task.state) {
                                TransferState.SUCCEEDED -> Icons.Outlined.CheckCircle
                                TransferState.FAILED -> Icons.Outlined.ErrorOutline
                                TransferState.CANCELLED -> Icons.Outlined.Info
                                else -> when (task.direction) {
                                    TransferDirection.DOWNLOAD -> Icons.Outlined.Download
                                    TransferDirection.UPLOAD -> Icons.Outlined.UploadFile
                                    TransferDirection.SERVER -> Icons.Outlined.SwapVert
                                }
                            },
                            contentDescription = null,
                            tint = when (task.state) {
                                TransferState.SUCCEEDED -> MaterialTheme.colorScheme.primary
                                TransferState.FAILED -> MaterialTheme.colorScheme.error
                                else -> MaterialTheme.colorScheme.onSurfaceVariant
                            },
                        )
                    },
                    trailingContent = if (actionsAtBottom) null else actions,
                )
                if (actionsAtBottom) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        actions()
                    }
                }
                if (canRefreshTarget || isRefreshingTarget) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        TextButton(
                            onClick = onOpenAndRefreshTarget,
                            enabled = canRefreshTarget && !isRefreshingTarget,
                            modifier = Modifier.heightIn(min = 48.dp),
                        ) {
                            if (isRefreshingTarget) {
                                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            }
                            Text(
                                stringResource(
                                    if (isRefreshingTarget) R.string.refreshing_affected_folder
                                    else R.string.open_and_refresh_affected_folder,
                                ),
                                modifier = Modifier.padding(start = if (isRefreshingTarget) 8.dp else 0.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun TransferTaskDetails(
    task: io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask,
    nowEpochMillis: Long = System.currentTimeMillis(),
) {
    val fileServerMutation = task.fileServerMutation
    val uploadMutationFeedback = uploadMutationFeedbackPolicy(task)
    val statusLiveRegion = if (
        task.errorMessage != null || task.requiresRefresh || fileServerMutation?.refreshFailure != null ||
        fileServerMutation?.verification?.let { it != FileServerMutationVerification.MATCHES } == true ||
        uploadMutationFeedback?.result?.status?.let {
            it != MutationResultStatus.CONFIRMED_SUCCESS
        } == true
    ) {
        LiveRegionMode.Assertive
    } else {
        LiveRegionMode.Polite
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        val transferProgress = task.progress
        val isActive = task.state in setOf(
            TransferState.WAITING,
            TransferState.RUNNING,
            TransferState.CANCELLING,
        )
        val shouldShowProgress = isActive || task.direction != TransferDirection.SERVER
        if (shouldShowProgress) {
            if (transferProgress != null) {
                LinearProgressIndicator(
                    progress = { transferProgress },
                    modifier = Modifier.fillMaxWidth(),
                )
            } else if (isActive) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
        }
        if (task.direction == TransferDirection.SERVER) {
            transferProgress?.takeIf { isActive }?.let { progress ->
                Text(
                    stringResource(
                        R.string.nas_task_percent_progress,
                        (progress * 100).toInt().coerceIn(0, 100),
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            Text(
                stringResource(
                    R.string.transfer_bytes_progress,
                    formatBytes(task.completedBytes),
                    task.totalBytes?.let(::formatBytes)
                        ?: stringResource(R.string.unknown_size),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (task.state == TransferState.RUNNING) {
                task.speedBytesPerSecond(nowEpochMillis)?.let { speed ->
                    val remaining = task.estimatedRemainingSeconds(nowEpochMillis)
                    Text(
                        if (remaining == null) {
                            stringResource(R.string.transfer_speed, formatBytes(speed))
                        } else {
                            stringResource(
                                R.string.transfer_speed_remaining,
                                formatBytes(speed),
                                formatRemainingDuration(remaining),
                            )
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        Column(
            modifier = Modifier.semantics { liveRegion = statusLiveRegion },
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                task.detail,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            task.errorMessage?.let { message ->
                Text(
                    message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (task.requiresRefresh) {
                Text(
                    stringResource(
                        if (task.direction == TransferDirection.SERVER) {
                            R.string.nas_task_refresh_before_retry
                        } else {
                            R.string.transfer_refresh_before_retry
                        },
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            uploadMutationFeedback?.let { feedback ->
                Text(
                    stringResource(feedback.stage),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(feedback.message),
                    style = MaterialTheme.typography.bodySmall,
                    color = if (feedback.result.status == MutationResultStatus.CONFIRMED_SUCCESS) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.error
                    },
                )
                feedback.result.counts.takeIf {
                    it.succeeded > 0 || it.failed > 0 || it.unknown > 0
                }?.let { counts ->
                    Text(
                        stringResource(
                            R.string.transfer_mutation_counts,
                            counts.succeeded,
                            counts.failed,
                            counts.unknown,
                        ),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            fileServerMutation?.refreshFailure?.let { failure ->
                Text(
                    failure.localize(LocalContext.current).combined,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            fileServerMutation?.verification?.let { verification ->
                Text(
                    stringResource(verification.messageResource()),
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@androidx.annotation.StringRes
private fun FileServerMutationVerification.messageResource(): Int = when (this) {
    FileServerMutationVerification.MATCHES -> R.string.affected_folder_refresh_matches
    FileServerMutationVerification.DIFFERS -> R.string.affected_folder_refresh_differs
    FileServerMutationVerification.DISAPPEARED -> R.string.affected_folder_refresh_disappeared
    FileServerMutationVerification.UNAVAILABLE -> R.string.affected_folder_refresh_unavailable
}

@androidx.annotation.StringRes
private fun TransferSourceFilter.labelResource(): Int = when (this) {
    TransferSourceFilter.ALL -> R.string.transfer_filter_all
    TransferSourceFilter.DOWNLOADS -> R.string.transfer_filter_downloads
    TransferSourceFilter.UPLOADS -> R.string.transfer_filter_uploads
    TransferSourceFilter.NAS_TASKS -> R.string.transfer_filter_nas_tasks
}

private fun TransferPage.labelResource(): Int = when (this) {
    TransferPage.APP_TRANSFERS -> R.string.app_transfers_title
    TransferPage.FILE_TASKS -> R.string.file_background_tasks_title
}

private fun FileBackgroundTaskFilter.matches(task: FileBackgroundTaskSummary): Boolean = when (this) {
    FileBackgroundTaskFilter.ALL -> true
    FileBackgroundTaskFilter.ACTIVE -> task.state == FileBackgroundTaskState.ACTIVE
    FileBackgroundTaskFilter.FINISHED -> task.state == FileBackgroundTaskState.FINISHED
}

private fun FileBackgroundTaskFilter.labelResource(): Int = when (this) {
    FileBackgroundTaskFilter.ALL -> R.string.file_background_task_filter_all
    FileBackgroundTaskFilter.ACTIVE -> R.string.file_background_task_filter_active
    FileBackgroundTaskFilter.FINISHED -> R.string.file_background_task_filter_finished
}

private fun FileBackgroundTaskKind.labelResource(): Int = when (this) {
    FileBackgroundTaskKind.COPY_OR_MOVE -> R.string.file_background_task_kind_copy_move
    FileBackgroundTaskKind.DELETE -> R.string.file_background_task_kind_delete
    FileBackgroundTaskKind.COMPRESS -> R.string.file_background_task_kind_compress
    FileBackgroundTaskKind.EXTRACT -> R.string.file_background_task_kind_extract
}

private fun FileBackgroundTaskState.labelResource(): Int = when (this) {
    FileBackgroundTaskState.ACTIVE -> R.string.file_background_task_state_active
    FileBackgroundTaskState.FINISHED -> R.string.file_background_task_state_finished
}

@Composable
internal fun TransferActions(
    state: TransferState,
    direction: TransferDirection,
    canPause: Boolean,
    canResume: Boolean,
    canRetry: Boolean,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
    canCancelTask: Boolean = true,
) {
    when {
        state == TransferState.CANCELLING -> Text(
            stringResource(R.string.transfer_cancelling),
            style = MaterialTheme.typography.labelMedium,
        )

        canResume -> Column(horizontalAlignment = Alignment.End) {
            TextButton(onClick = onResume, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.resume_download))
            }
            TextButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.cancel))
            }
        }

        canPause -> TextButton(onClick = onPause, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(stringResource(R.string.pause_download))
        }

        canRetry -> TextButton(onClick = onRetry, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(
                stringResource(
                    if (direction == TransferDirection.DOWNLOAD) {
                        R.string.resume_download
                    } else {
                        R.string.retry_from_start
                    },
                ),
            )
        }

        canCancelTask &&
            state in setOf(TransferState.WAITING, TransferState.RUNNING, TransferState.PAUSED) -> {
            TextButton(onClick = onCancel, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.cancel))
            }
        }
    }
}
