package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AdminPanelSettings
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.NetworkCheck
import androidx.compose.material.icons.outlined.LinkOff
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.NasSettingsTab
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.ui.ActionRow
import io.github.qwertyuiop1995.dsmnativeclient.ui.ConfirmDialog
import io.github.qwertyuiop1995.dsmnativeclient.ui.LoadableContent
import io.github.qwertyuiop1995.dsmnativeclient.ui.ResourceList
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.LogList

@Composable
internal fun NasSettingsScreen(state: WorkspaceState, model: AppViewModel) {
    val tab = state.nasPerformance.selectedTab.ordinal
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxWidth().weight(1f)) {
            LoadableContent(
                value = state.nasSettings,
                emptyTitle = stringResource(R.string.temporarily_unavailable),
                emptyMessage = stringResource(R.string.admin_permission_recovery),
                onRetry = { model.load(Module.NAS_SETTINGS) },
            ) { snapshot ->
                NasSettingsTab(
                    state = state,
                    snapshot = snapshot,
                    tab = tab,
                    storageAnalysis = state.storageAnalysis,
                    storageAnalysisProgress = state.storageAnalysisProgress,
                    diskTestStatuses = state.diskTestStatuses,
                    performanceHistory = state.nasPerformance.history,
                    performanceIsLoading = state.nasPerformance.isLoading,
                    performanceError = state.nasPerformance.error,
                    performanceIsPaused = state.nasPerformance.isPaused,
                    systemUpdate = state.nasSystemUpdate,
                    fileServiceSettingsDraft = state.fileServiceSettingsDraft,
                    fileServiceMutationResult = state.fileServiceMutationResult,
                    fileServiceMutationFailure = state.fileServiceMutationFailure,
                    fileServiceMutationInProgress = state.fileServiceMutationInProgress,
                    fileServiceMutationRefreshCompleted = state.fileServiceMutationRefreshCompleted,
                    terminalSettingsDraft = state.terminalSettingsDraft,
                    terminalMutationResult = state.terminalMutationResult,
                    terminalMutationFailure = state.terminalMutationFailure,
                    terminalMutationInProgress = state.terminalMutationInProgress,
                    terminalMutationRefreshCompleted = state.terminalMutationRefreshCompleted,
                    proxySettingsDraft = state.proxySettingsDraft,
                    proxyMutationResult = state.proxyMutationResult,
                    proxyMutationFailure = state.proxyMutationFailure,
                    proxyMutationInProgress = state.proxyMutationInProgress,
                    proxyMutationRefreshCompleted = state.proxyMutationRefreshCompleted,
                    regionSettingsDraft = state.regionSettingsDraft,
                    regionMutationResult = state.regionMutationResult,
                    regionMutationFailure = state.regionMutationFailure,
                    regionMutationInProgress = state.regionMutationInProgress,
                    regionMutationRefreshCompleted = state.regionMutationRefreshCompleted,
                    connectionMutationTarget = state.connectionMutationTarget,
                    connectionMutationResult = state.connectionMutationResult,
                    connectionMutationFailure = state.connectionMutationFailure,
                    connectionMutationRefreshFailure = state.connectionMutationRefreshFailure,
                    connectionMutationInProgress = state.connectionMutationInProgress,
                    connectionMutationRefreshInProgress = state.connectionMutationRefreshInProgress,
                    connectionMutationRefreshCompleted = state.connectionMutationRefreshCompleted,
                    isPerformingAction = state.isPerformingAction,
                    model = model,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun NasSettingsTab(
    state: WorkspaceState,
    snapshot: NasSettingsSnapshot,
    tab: Int,
    storageAnalysis: io.github.qwertyuiop1995.dsmnativeclient.Loadable<io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisSnapshot>,
    storageAnalysisProgress: io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisProgress?,
    diskTestStatuses: Map<String, io.github.qwertyuiop1995.dsmnativeclient.Loadable<io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestStatus>>,
    performanceHistory: List<io.github.qwertyuiop1995.dsmnativeclient.domain.PerformanceSample>,
    performanceIsLoading: Boolean,
    performanceError: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    performanceIsPaused: Boolean,
    systemUpdate: io.github.qwertyuiop1995.dsmnativeclient.Loadable<io.github.qwertyuiop1995.dsmnativeclient.domain.NasSystemUpdateInfo>,
    fileServiceSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings?,
    fileServiceMutationResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?,
    fileServiceMutationFailure: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    fileServiceMutationInProgress: Boolean,
    fileServiceMutationRefreshCompleted: Boolean,
    terminalSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings?,
    terminalMutationResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?,
    terminalMutationFailure: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    terminalMutationInProgress: Boolean,
    terminalMutationRefreshCompleted: Boolean,
    proxySettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings?,
    proxyMutationResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?,
    proxyMutationFailure: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    proxyMutationInProgress: Boolean,
    proxyMutationRefreshCompleted: Boolean,
    regionSettingsDraft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings?,
    regionMutationResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?,
    regionMutationFailure: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    regionMutationInProgress: Boolean,
    regionMutationRefreshCompleted: Boolean,
    connectionMutationTarget: io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection?,
    connectionMutationResult: io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?,
    connectionMutationFailure: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    connectionMutationRefreshFailure: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    connectionMutationInProgress: Boolean,
    connectionMutationRefreshInProgress: Boolean,
    connectionMutationRefreshCompleted: Boolean,
    isPerformingAction: Boolean,
    model: AppViewModel,
) {
    when (tab) {
        0 -> LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                snapshot.system?.let { system ->
                    SummaryCard(stringResource(R.string.system)) {
                        SummaryLine(stringResource(R.string.device_name), system.serverName)
                        SummaryLine(stringResource(R.string.model), system.model)
                        SummaryLine("DSM", system.dsmVersion)
                        system.uptimeSeconds?.let {
                            SummaryLine(stringResource(R.string.uptime), formatDuration(it))
                        }
                    }
                }
            }
            item {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    MetricCard(
                        stringResource(R.string.storage_space),
                        snapshot.volumes.size.toString(),
                        Icons.Outlined.Storage,
                    )
                    MetricCard(
                        stringResource(R.string.packages),
                        snapshot.packages.size.toString(),
                        Icons.Outlined.Dns,
                    )
                    MetricCard(
                        stringResource(R.string.active_connections),
                        snapshot.connections.size.toString(),
                        Icons.Outlined.NetworkCheck,
                    )
                    MetricCard(
                        stringResource(R.string.account),
                        snapshot.accounts.size.toString(),
                        Icons.Outlined.AdminPanelSettings,
                    )
                }
            }
            item {
                NasSystemUpdateCard(
                    state = systemUpdate,
                    onCheck = model::checkNasSystemUpdate,
                )
            }
        }
        1 -> NasPerformanceScreen(
            history = performanceHistory,
            isLoading = performanceIsLoading,
            error = performanceError,
            isPaused = performanceIsPaused,
            onStart = { model.setNasPerformanceVisible(true) },
            onStop = { model.setNasPerformanceVisible(false) },
            onTogglePause = model::toggleNasPerformancePause,
            onRetry = model::retryNasPerformance,
        )
        2 -> NasStorageScreen(
            snapshot = snapshot,
            analysis = storageAnalysis,
            progress = storageAnalysisProgress,
            diskTestStatuses = diskTestStatuses,
            diskTestMutationTarget = state.diskTestMutationTarget,
            diskTestMutationBaseline = state.diskTestMutationBaseline,
            diskTestMutationOperation = state.diskTestMutationOperation,
            diskTestMutationConfirmationRequested = state.diskTestMutationConfirmationRequested,
            diskTestMutationInProgress = state.diskTestMutationInProgress,
            diskTestMutationResult = state.diskTestMutationResult,
            diskTestMutationFailure = state.diskTestMutationFailure,
            diskTestMutationRefreshFailure = state.diskTestMutationRefreshFailure,
            diskTestMutationRefreshInProgress = state.diskTestMutationRefreshInProgress,
            diskTestMutationRefreshCompleted = state.diskTestMutationRefreshCompleted,
            diskTestActionsEnabled = state.diskTestMutationTarget == null && !state.isPerformingAction &&
                !state.diskTestMutationInProgress &&
                !state.diskTestMutationRefreshInProgress && state.diskTestMutationResult == null &&
                state.diskTestMutationFailure == null && !state.diskTestMutationConfirmationRequested,
            onBeginAnalysis = model::beginStorageAnalysis,
            onCancelAnalysis = model::cancelStorageAnalysis,
            onLoadDiskTest = model::loadDiskTestStatus,
            onRequestDiskTest = { disk, baseline, operation ->
                model.requestDiskTestMutation(disk, baseline, operation)
            },
            onConfirmDiskTest = model::confirmDiskTestMutation,
            onCancelDiskTestConfirmation = { model.cancelDiskTestMutationConfirmation() },
            onRefreshDiskTest = model::refreshDiskTestMutation,
            onContinueDiskTest = { model.dismissDiskTestMutationResult() },
            onCloseDiskTestResult = { model.dismissDiskTestMutationResult() },
        )
        3 -> NasPackageManagementScreen(snapshot, state, model)
        4 -> NasDirectoryManagementScreen(snapshot, state, model)
        5 -> LogList(
            logs = snapshot.logs,
            isAvailable = snapshot.logsAvailable,
            onRetry = { model.load(Module.NAS_SETTINGS) },
        )
        6 -> NasConnectionScreen(
            connections = snapshot.connections,
            connectionsAvailable = snapshot.connectionsAvailable,
            target = connectionMutationTarget,
            mutationResult = connectionMutationResult,
            mutationFailure = connectionMutationFailure,
            refreshFailure = connectionMutationRefreshFailure,
            mutationInProgress = connectionMutationInProgress,
            refreshInProgress = connectionMutationRefreshInProgress,
            refreshCompleted = connectionMutationRefreshCompleted,
            isPerformingAction = isPerformingAction,
            model = model,
        )
        7 -> NasServiceSettingsScreen(
            snapshot = snapshot,
            savedDraft = fileServiceSettingsDraft,
            mutationResult = fileServiceMutationResult,
            mutationFailure = fileServiceMutationFailure,
            mutationInProgress = fileServiceMutationInProgress,
            mutationRefreshCompleted = fileServiceMutationRefreshCompleted,
            savedTerminalDraft = terminalSettingsDraft,
            terminalMutationResult = terminalMutationResult,
            terminalMutationFailure = terminalMutationFailure,
            terminalMutationInProgress = terminalMutationInProgress,
            terminalMutationRefreshCompleted = terminalMutationRefreshCompleted,
            savedProxyDraft = proxySettingsDraft,
            proxyMutationResult = proxyMutationResult,
            proxyMutationFailure = proxyMutationFailure,
            proxyMutationInProgress = proxyMutationInProgress,
            proxyMutationRefreshCompleted = proxyMutationRefreshCompleted,
            isPerformingAction = isPerformingAction,
            model = model,
        )
        8 -> NasRegionSettingsScreen(
            settings = snapshot.regionSettings,
            savedDraft = regionSettingsDraft,
            mutationResult = regionMutationResult,
            mutationFailure = regionMutationFailure,
            mutationInProgress = regionMutationInProgress,
            mutationRefreshCompleted = regionMutationRefreshCompleted,
            isPerformingAction = isPerformingAction,
            model = model,
        )
        9 -> EthernetAndDdnsList(snapshot = snapshot, state = state, model = model)
        10 -> NasSecuritySettingsScreen(
            settings = snapshot.securitySettings,
            settingsAvailable = snapshot.securitySettingsAvailable,
            fallback = snapshot.security,
            state = state,
            model = model,
        )
        else -> NasHardwareSettingsScreen(
            settings = snapshot.hardwareSettings,
            settingsAvailable = snapshot.hardwareSettingsAvailable,
            state = state,
            model = model,
        )
    }
}

@Composable
private fun SummaryCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            content()
        }
    }
}

@Composable
private fun SummaryLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        Text(
            label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Text(value, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun MetricCard(title: String, value: String, icon: ImageVector) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
        modifier = Modifier.width(156.dp),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(22.dp),
                )
            }
            Text(
                value,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.ExtraBold,
            )
            Text(
                title,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun formatDuration(seconds: Long): String {
    val days = seconds / 86_400
    val hours = (seconds % 86_400) / 3_600
    return if (days > 0) {
        stringResource(R.string.days_hours, days, hours)
    } else {
        stringResource(R.string.hours_only, hours)
    }
}
