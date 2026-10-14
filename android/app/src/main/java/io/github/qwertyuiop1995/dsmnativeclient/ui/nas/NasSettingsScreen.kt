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
                    performanceHistory = state.nasPerformance.history,
                    performanceIsLoading = state.nasPerformance.isLoading,
                    performanceError = state.nasPerformance.error,
                    performanceIsPaused = state.nasPerformance.isPaused,
                    systemUpdate = state.nasSystemUpdate,
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
    performanceHistory: List<io.github.qwertyuiop1995.dsmnativeclient.domain.PerformanceSample>,
    performanceIsLoading: Boolean,
    performanceError: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure?,
    performanceIsPaused: Boolean,
    systemUpdate: io.github.qwertyuiop1995.dsmnativeclient.Loadable<io.github.qwertyuiop1995.dsmnativeclient.domain.NasSystemUpdateInfo>,
    isPerformingAction: Boolean,
    model: AppViewModel,
) {
    when (tab) {
        0 -> LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (!snapshot.systemAvailable || !snapshot.storageAvailable || !snapshot.packagesAvailable ||
                !snapshot.accountsAvailable || !snapshot.connectionsAvailable) item {
                NasReadFailureNotice { model.load(Module.NAS_SETTINGS) }
            }
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
                        if (snapshot.storageAvailable) snapshot.volumes.size.toString() else stringResource(R.string.unknown_status),
                        Icons.Outlined.Storage,
                    )
                    MetricCard(
                        stringResource(R.string.packages),
                        if (snapshot.packagesAvailable) snapshot.packages.size.toString() else stringResource(R.string.unknown_status),
                        Icons.Outlined.Dns,
                    )
                    MetricCard(
                        stringResource(R.string.active_connections),
                        if (snapshot.connectionsAvailable) snapshot.connections.size.toString() else stringResource(R.string.unknown_status),
                        Icons.Outlined.NetworkCheck,
                    )
                    MetricCard(
                        stringResource(R.string.account),
                        if (snapshot.accountsAvailable) snapshot.accounts.size.toString() else stringResource(R.string.unknown_status),
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
            smartContent = { NasSmartTestSection(model.nasSmart, !state.isPerformingAction) },
            onBeginAnalysis = model::beginStorageAnalysis,
            onCancelAnalysis = model::cancelStorageAnalysis,
            onReload = { model.load(Module.NAS_SETTINGS) },
        )
        3 -> NasPackageCenterScreen(snapshot, state, model)
        4 -> NasDirectoryManagementScreen(snapshot, state, model)
        5 -> NasLogsScreen(model.nasObservation)
        6 -> NasConnectionScreen(model.nasConnections, isPerformingAction)
        7 -> NasServiceSettingsScreen(snapshot = snapshot, isPerformingAction = isPerformingAction, model = model)
        8 -> NasRegionSettingsScreen(
            settings = snapshot.regionSettings,
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
        12 -> NasScheduledTaskScreen(model.nasScheduledTasks)
        13 -> NasProcessesScreen(model.nasObservation)
        else -> NasHardwareSettingsScreen(
            settings = snapshot.hardwareSettings,
            settingsAvailable = snapshot.hardwareSettingsAvailable,
            state = state,
            model = model,
        )
    }
}

@Composable
internal fun NasReadFailureNotice(onReload: () -> Unit) {
    io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientGroup {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.nas_read_failed), color = MaterialTheme.colorScheme.error)
            TextButton(onClick = onReload) { Text(stringResource(R.string.retry)) }
        }
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
