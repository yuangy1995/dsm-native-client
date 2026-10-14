package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.isTrustedDiskTestStatus
import io.github.qwertyuiop1995.dsmnativeclient.sameDiskTestTarget
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestType
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisProgress
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageFileCategory
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import java.text.DateFormat
import java.util.Date

@Composable
internal fun NasStorageScreen(
    snapshot: NasSettingsSnapshot,
    analysis: Loadable<StorageAnalysisSnapshot>,
    progress: StorageAnalysisProgress?,
    smartContent: @Composable () -> Unit,
    onBeginAnalysis: () -> Unit,
    onCancelAnalysis: () -> Unit,
    onReload: (() -> Unit)? = null,
) {
    var section by remember { mutableIntStateOf(0) }
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text(stringResource(R.string.storage_overview), style = MaterialTheme.typography.titleLarge)
        }
        if (!snapshot.storageAvailable) item {
            if (onReload != null) NasReadFailureNotice(onReload)
            else Text(stringResource(R.string.nas_read_failed), color = MaterialTheme.colorScheme.error)
        }
        items(snapshot.volumes, key = { "volume:${it.id}" }) { volume ->
            StorageSummaryCard(
                title = volume.name,
                value = "${formatBytes(volume.usedBytes)} / ${formatBytes(volume.totalBytes)}",
            )
        }
        items(snapshot.pools + snapshot.disks, key = { "resource:${it.id}" }) { resource ->
            StorageSummaryCard(resource.name, resource.detail)
        }
        item {
            smartContent()
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.storage_content_analysis), style = MaterialTheme.typography.titleLarge)
                Text(
                    stringResource(R.string.storage_analysis_privacy_notice),
                    style = MaterialTheme.typography.bodyMedium,
                )
                when (analysis) {
                    Loadable.Loading -> {
                        val fraction = progress?.fraction
                        if (fraction == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                        else LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                        Text(storageProgressLabel(progress))
                        OutlinedButton(onClick = onCancelAnalysis) {
                            Text(stringResource(R.string.cancel_analysis))
                        }
                    }
                    is Loadable.Failed -> {
                        Text(
                            analysis.error.localize(androidx.compose.ui.platform.LocalContext.current).combined,
                            color = MaterialTheme.colorScheme.error,
                        )
                        Button(onClick = onBeginAnalysis) { Text(stringResource(R.string.retry_analysis)) }
                    }
                    else -> Button(onClick = onBeginAnalysis) {
                        Text(stringResource(if (analysis is Loadable.Ready) R.string.analyze_again else R.string.begin_analysis))
                    }
                }
            }
        }
        val result = (analysis as? Loadable.Ready)?.value
        if (result != null) {
            item {
                Text(
                    stringResource(
                        R.string.storage_analysis_summary,
                        result.scannedFileCount,
                        formatBytes(result.scannedBytes),
                        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                            .format(Date(result.generatedAtEpochSeconds * 1_000)),
                    ),
                )
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(
                        R.string.analysis_distribution,
                        R.string.analysis_files,
                        R.string.analysis_duplicates,
                    ).forEachIndexed { index, label ->
                        FilterChip(
                            selected = section == index,
                            onClick = { section = index },
                            label = { Text(stringResource(label)) },
                        )
                    }
                }
            }
            when (section) {
                0 -> distributionItems(result)
                1 -> fileItems(result)
                else -> duplicateItems(result)
            }
        }
    }

}

@Composable
internal fun SmartTestManagementContent(
    disks: List<NasStorageDisk>,
    statuses: Map<String, Loadable<NasDiskTestStatus>>,
    target: NasStorageDisk?,
    baseline: NasDiskTestStatus?,
    type: NasDiskTestType?,
    mutationInProgress: Boolean,
    result: MutationResult?,
    failure: DsmFailure?,
    refreshFailure: DsmFailure?,
    refreshInProgress: Boolean,
    refreshCompleted: Boolean,
    enabled: Boolean,
    onLoad: (NasStorageDisk) -> Unit,
    onRequest: (NasStorageDisk, NasDiskTestType?) -> Unit,
    onRefresh: () -> Unit,
    onContinue: () -> Unit,
    onCloseResult: () -> Unit,
) {
    val trustedRefreshCompleted = refreshCompleted && refreshFailure == null
    val targetState = smartTestTargetState(
        target = target,
        baseline = baseline,
        type = type,
        disks = disks,
        statuses = statuses,
        refreshCompleted = trustedRefreshCompleted,
    )
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.drive_tests), style = MaterialTheme.typography.titleLarge)
        when {
            mutationInProgress && target != null -> ManagementSavingCard(
                title = R.string.smart_test_action_in_progress,
                targetName = target.name,
                message = R.string.smart_test_action_in_progress_message,
            )
            (result != null || failure != null) && target != null -> ManagementMutationFeedbackCard(
                targetName = target.name,
                result = result,
                failure = failure,
                refreshFailure = refreshFailure,
                refreshInProgress = refreshInProgress,
                refreshCompleted = trustedRefreshCompleted,
                targetState = targetState,
                countsLabel = R.string.smart_test_feedback_counts,
                refreshLabel = R.string.refresh_and_check_smart_test,
                onRefresh = onRefresh,
                onContinue = onContinue,
                onCloseResult = onCloseResult,
            )
        }
        when {
            disks.isEmpty() -> SmartTestStateCard(
                title = R.string.smart_test_empty_title,
                message = R.string.smart_test_empty_message,
            )
            disks.none(NasStorageDisk::supportsSmartTest) -> SmartTestStateCard(
                title = R.string.smart_test_all_unavailable_title,
                message = R.string.smart_test_all_unavailable_message,
            )
            else -> disks.forEach { disk ->
                SmartTestDiskCard(
                    disk = disk,
                    status = statuses[disk.id] ?: Loadable.Idle,
                    enabled = enabled,
                    onLoad = { onLoad(disk) },
                    onRequest = { requestedType -> onRequest(disk, requestedType) },
                )
            }
        }
    }
}

@Composable
internal fun SmartTestDiskCard(
    disk: NasStorageDisk,
    status: Loadable<NasDiskTestStatus>,
    enabled: Boolean,
    readEnabled: Boolean = enabled,
    onLoad: () -> Unit,
    onRequest: (NasDiskTestType?) -> Unit,
) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(disk.name, style = MaterialTheme.typography.titleMedium)
            val detail = listOfNotNull(
                disk.model,
                driveStateLabel(disk.smartStatus ?: disk.status),
                disk.temperatureCelsius?.let { stringResource(R.string.temperature_celsius, it) },
            ).joinToString(" · ")
            if (detail.isNotBlank()) Text(detail)
            if (!disk.supportsSmartTest) {
                SmartTestInlineState(
                    R.string.smart_test_unavailable,
                    R.string.smart_test_unavailable_recovery,
                    LiveRegionMode.Polite,
                )
            } else when (status) {
                Loadable.Idle -> SmartTestActionButton(
                    label = R.string.check_test_status,
                    description = stringResource(R.string.check_smart_test_description, disk.name),
                    enabled = readEnabled,
                    onClick = onLoad,
                )
                Loadable.Loading -> SmartTestInlineState(
                    R.string.smart_test_loading_title,
                    R.string.smart_test_loading_message,
                    LiveRegionMode.Polite,
                    showProgress = true,
                )
                is Loadable.Failed -> {
                    Column(Modifier.semantics { liveRegion = LiveRegionMode.Assertive }) {
                        Text(
                            status.error.localize(androidx.compose.ui.platform.LocalContext.current).combined,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    SmartTestActionButton(
                        label = R.string.retry,
                        description = stringResource(R.string.retry_smart_test_description, disk.name),
                        enabled = readEnabled,
                        onClick = onLoad,
                    )
                }
                is Loadable.Ready -> {
                    val value = status.value
                    if (!isTrustedDiskTestStatus(disk, value)) {
                        SmartTestInlineState(
                            R.string.smart_test_status_unavailable_title,
                            R.string.smart_test_status_unavailable_message,
                            LiveRegionMode.Assertive,
                        )
                        SmartTestActionButton(
                            label = R.string.refresh,
                            description = stringResource(R.string.refresh_smart_test_description, disk.name),
                            enabled = readEnabled,
                            onClick = onLoad,
                        )
                    } else {
                        Text(
                            when {
                                value.isRunning -> stringResource(
                                    R.string.smart_test_running,
                                    value.progressDescription ?: stringResource(R.string.progress_unknown),
                                )
                                value.isBusyWithOtherTest -> stringResource(R.string.drive_busy_with_other_test)
                                else -> stringResource(R.string.no_smart_test_running)
                            },
                        )
                        value.lastResult?.let { lastResult ->
                            Text(stringResource(
                                R.string.last_test_result,
                                driveStateLabel(lastResult) ?: stringResource(R.string.unknown_status),
                            ))
                        }
                        if (value.isHistoryAvailable) {
                            value.lastQuickTest?.let { Text(stringResource(R.string.smart_last_quick, it)) }
                            value.lastExtendedTest?.let { Text(stringResource(R.string.smart_last_extended, it)) }
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (value.isRunning) {
                                SmartTestActionButton(
                                    label = R.string.stop_test,
                                    description = stringResource(R.string.stop_smart_test_description, disk.name),
                                    enabled = enabled,
                                    destructive = true,
                                ) { onRequest(null) }
                            } else if (!value.isBusyWithOtherTest) {
                                SmartTestActionButton(
                                    label = R.string.quick_test,
                                    description = stringResource(R.string.quick_smart_test_description, disk.name),
                                    enabled = enabled,
                                ) { onRequest(NasDiskTestType.QUICK) }
                                SmartTestActionButton(
                                    label = R.string.extended_test,
                                    description = stringResource(R.string.extended_smart_test_description, disk.name),
                                    enabled = enabled,
                                ) { onRequest(NasDiskTestType.EXTENDED) }
                            }
                            SmartTestActionButton(
                                label = R.string.refresh,
                                description = stringResource(R.string.refresh_smart_test_description, disk.name),
                                enabled = readEnabled,
                                onClick = onLoad,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SmartTestActionButton(
    @androidx.annotation.StringRes label: Int,
    description: String,
    enabled: Boolean,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    OutlinedButton(
        enabled = enabled,
        onClick = onClick,
        colors = if (destructive) {
            ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
        } else ButtonDefaults.outlinedButtonColors(),
        modifier = Modifier.heightIn(min = 48.dp).semantics {
            contentDescription = description
            role = Role.Button
        },
    ) {
        Text(stringResource(label))
    }
}

@Composable
internal fun SmartTestConfirmationDialog(
    target: NasStorageDisk,
    type: NasDiskTestType?,
    onConfirm: () -> Boolean,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (type == null) R.string.stop_smart_test_title else R.string.start_smart_test_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(
                    R.string.smart_test_target_summary,
                    target.name,
                    target.model ?: stringResource(R.string.unknown_status),
                ))
                Text(stringResource(when (type) {
                    NasDiskTestType.QUICK -> R.string.quick_smart_test_impact
                    NasDiskTestType.EXTENDED -> R.string.extended_smart_test_impact
                    null -> R.string.stop_smart_test_impact
                }))
            }
        },
        confirmButton = {
            Button(onClick = { onConfirm() }) {
                Text(stringResource(when (type) {
                    NasDiskTestType.QUICK -> R.string.quick_test
                    NasDiskTestType.EXTENDED -> R.string.extended_test
                    null -> R.string.stop_test
                }))
            }
        },
        dismissButton = { OutlinedButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

internal fun smartTestTargetState(
    target: NasStorageDisk?,
    baseline: NasDiskTestStatus?,
    type: NasDiskTestType?,
    disks: List<NasStorageDisk>,
    statuses: Map<String, Loadable<NasDiskTestStatus>>,
    refreshCompleted: Boolean,
): ManagementTargetState {
    if (target == null || baseline?.diskId != target.id || !refreshCompleted) {
        return ManagementTargetState.UNAVAILABLE
    }
    val currentDisk = disks.firstOrNull { it.id == target.id } ?: return ManagementTargetState.MISSING
    if (!sameDiskTestTarget(target, currentDisk)) return ManagementTargetState.DIFFERS
    val current = (statuses[target.id] as? Loadable.Ready)?.value
        ?: return ManagementTargetState.UNAVAILABLE
    val trusted = current.diskId == target.id && if (current.isRunning) {
        !current.isBusyWithOtherTest && current.runningType != null
    } else current.runningType == null
    if (!trusted) return ManagementTargetState.UNAVAILABLE
    val matches = when (type) {
        null -> !current.isRunning && !current.isBusyWithOtherTest
        NasDiskTestType.QUICK,
        NasDiskTestType.EXTENDED,
        -> current.isRunning && current.runningType == type
    }
    return if (matches) ManagementTargetState.MATCHES else ManagementTargetState.DIFFERS
}

@Composable
private fun SmartTestStateCard(@androidx.annotation.StringRes title: Int, @androidx.annotation.StringRes message: Int) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(message))
        }
    }
}

@Composable
private fun SmartTestInlineState(
    @androidx.annotation.StringRes title: Int,
    @androidx.annotation.StringRes message: Int,
    mode: LiveRegionMode,
    showProgress: Boolean = false,
) {
    Column(Modifier.semantics { liveRegion = mode }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(title), style = MaterialTheme.typography.titleSmall)
        Text(stringResource(message))
        if (showProgress) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
private fun driveStateLabel(value: String?): String? = when (value?.trim()?.lowercase()) {
    "normal", "healthy", "ok", "success", "passed" -> stringResource(R.string.normal)
    "warning", "attention", "degraded" -> stringResource(R.string.warning)
    "error", "critical", "failed", "failing", "abnormal" -> stringResource(R.string.error)
    else -> null
}

private fun androidx.compose.foundation.lazy.LazyListScope.distributionItems(
    result: StorageAnalysisSnapshot,
) {
    item { SectionTitle(R.string.shared_folders) }
    items(result.shares, key = { "share:${it.path}" }) {
        AnalysisRow(it.name, it.usedBytes, it.fileCount)
    }
    item { SectionTitle(R.string.file_types) }
    items(result.categories, key = { "category:${it.category}" }) {
        AnalysisRow(categoryLabel(it.category), it.usedBytes, it.fileCount)
    }
    item { SectionTitle(R.string.file_owners) }
    items(result.owners, key = { "owner:${it.name}" }) {
        AnalysisRow(it.name ?: stringResource(R.string.unknown_owner), it.usedBytes, it.fileCount)
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.fileItems(result: StorageAnalysisSnapshot) {
    item { SectionTitle(R.string.large_files) }
    fileRows(result.largeFiles, "large")
    item { SectionTitle(R.string.recently_modified) }
    fileRows(result.recentlyModifiedFiles, "recent")
    item { SectionTitle(R.string.least_recently_accessed) }
    if (result.leastRecentlyAccessedFiles.isEmpty()) {
        item { Text(stringResource(R.string.access_time_unavailable)) }
    } else {
        fileRows(result.leastRecentlyAccessedFiles, "access")
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.fileRows(files: List<FileItem>, prefix: String) {
    items(files, key = { "$prefix:${it.path}" }) { file ->
        ListItem(
            headlineContent = { Text(file.name) },
            supportingContent = { Text(file.path) },
            trailingContent = { Text(formatBytes(file.size)) },
        )
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.duplicateItems(result: StorageAnalysisSnapshot) {
    if (result.duplicateCheckUnavailable) {
        item { Text(stringResource(R.string.checksum_unavailable)) }
    } else if (result.duplicateCheckWasLimited) {
        item { Text(stringResource(R.string.checksum_limited)) }
    }
    if (result.duplicateGroups.isEmpty()) {
        item { Text(stringResource(R.string.no_duplicates_found)) }
    }
    result.duplicateGroups.forEachIndexed { index, group ->
        item(key = "duplicate-header:$index") {
            SectionTitle(
                R.string.duplicate_group_summary,
                group.files.size,
                formatBytes(group.reclaimableBytes),
            )
        }
        fileRows(group.files, "duplicate:$index")
    }
}

@Composable
private fun StorageSummaryCard(title: String, value: String) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(value.ifBlank { stringResource(R.string.unknown_status) })
        }
    }
}

@Composable
private fun AnalysisRow(name: String, bytes: Long, count: Int) {
    ListItem(
        headlineContent = { Text(name) },
        supportingContent = { Text(stringResource(R.string.file_count, count)) },
        trailingContent = { Text(formatBytes(bytes)) },
    )
}

@Composable
private fun SectionTitle(resource: Int, vararg arguments: Any) {
    Text(stringResource(resource, *arguments), style = MaterialTheme.typography.titleMedium)
}

@Composable
private fun storageProgressLabel(progress: StorageAnalysisProgress?): String = when (progress?.phase) {
    "checksums" -> stringResource(R.string.verifying_file_contents, progress.completed, progress.total)
    "complete" -> stringResource(R.string.finishing_analysis)
    else -> if (progress?.total == null || progress.total == 0) {
        stringResource(R.string.preparing_analysis)
    } else {
        stringResource(R.string.scanning_shared_folders, progress.completed, progress.total)
    }
}

@Composable
private fun categoryLabel(category: StorageFileCategory): String = stringResource(
    when (category) {
        StorageFileCategory.IMAGE -> R.string.file_category_images
        StorageFileCategory.VIDEO -> R.string.file_category_videos
        StorageFileCategory.AUDIO -> R.string.file_category_audio
        StorageFileCategory.DOCUMENT -> R.string.file_category_documents
        StorageFileCategory.ARCHIVE -> R.string.file_category_archives
        StorageFileCategory.OTHER -> R.string.file_category_other
        StorageFileCategory.NO_EXTENSION -> R.string.file_category_no_extension
    },
)
