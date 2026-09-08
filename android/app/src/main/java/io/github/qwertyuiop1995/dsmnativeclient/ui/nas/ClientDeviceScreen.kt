package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.NasSettingsTab
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*

internal enum class DeviceCategory(val title: Int, val detail: Int, val tabs: List<NasSettingsTab>) {
    STORAGE(R.string.client_storage_category, R.string.client_storage_category_detail, listOf(NasSettingsTab.STORAGE, NasSettingsTab.PERFORMANCE)),
    SECURITY(R.string.client_security_category, R.string.client_security_category_detail, listOf(NasSettingsTab.ACCOUNT, NasSettingsTab.SECURITY)),
    NETWORK(R.string.client_network_category, R.string.client_network_category_detail, listOf(NasSettingsTab.NETWORKS, NasSettingsTab.CONNECTIONS)),
    SYSTEM(R.string.client_system_category, R.string.client_system_category_detail,
        listOf(NasSettingsTab.OVERVIEW, NasSettingsTab.HARDWARE_AND_POWER, NasSettingsTab.REGION_AND_TIME, NasSettingsTab.SERVICES, NasSettingsTab.LOGS, NasSettingsTab.PACKAGES));
    val icon: ImageVector get() = when (this) {
        STORAGE -> Icons.Outlined.Storage
        SECURITY -> Icons.Outlined.Security
        NETWORK -> Icons.Outlined.Language
        SYSTEM -> Icons.Outlined.Settings
    }
}

internal fun NasSettingsTab.clientTitle(): Int = when (this) {
    NasSettingsTab.OVERVIEW -> R.string.overview
    NasSettingsTab.PERFORMANCE -> R.string.performance
    NasSettingsTab.STORAGE -> R.string.storage
    NasSettingsTab.PACKAGES -> R.string.packages
    NasSettingsTab.ACCOUNT -> R.string.account
    NasSettingsTab.LOGS -> R.string.logs
    NasSettingsTab.CONNECTIONS -> R.string.connections
    NasSettingsTab.SERVICES -> R.string.services
    NasSettingsTab.REGION_AND_TIME -> R.string.region_and_time
    NasSettingsTab.NETWORKS -> R.string.networks
    NasSettingsTab.SECURITY -> R.string.security
    NasSettingsTab.HARDWARE_AND_POWER -> R.string.hardware_and_power
}

@Composable
internal fun ClientDeviceScreen(state: WorkspaceState, category: DeviceCategory?, onCategory: (DeviceCategory) -> Unit,
    onTab: (NasSettingsTab) -> Unit, onOpen: (ClientDestination) -> Unit, onRefresh: () -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (category == null) {
            item {
                ClientGroup {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            Icon(Icons.Outlined.Dns, null, Modifier.size(52.dp))
                            Column(Modifier.weight(1f)) {
                                Text(state.profile.name, style = MaterialTheme.typography.titleMedium)
                                Text(stringResource(R.string.client_current_device), style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { onOpen(ClientDestination.SETTINGS) }) {
                                Icon(Icons.Outlined.Settings, stringResource(R.string.client_app_settings))
                            }
                        }
                        when (val snapshot = state.nasSettings) {
                            Loadable.Idle -> Text(stringResource(R.string.client_device_status_unavailable), style = MaterialTheme.typography.bodySmall)
                            Loadable.Loading -> LinearProgressIndicator(Modifier.fillMaxWidth())
                            is Loadable.Failed -> {
                                Text(stringResource(R.string.client_device_status_unavailable), style = MaterialTheme.typography.bodySmall)
                                TextButton(onClick = onRefresh) { Text(stringResource(R.string.retry)) }
                            }
                            is Loadable.Ready -> {
                                if (snapshot.value.system == null && snapshot.value.volumes.isEmpty()) {
                                    Text(stringResource(R.string.client_device_status_unavailable), style = MaterialTheme.typography.bodySmall)
                                    TextButton(onClick = onRefresh) { Text(stringResource(R.string.retry)) }
                                }
                                snapshot.value.system?.let { Text(it.model, style = MaterialTheme.typography.bodySmall) }
                                val total = snapshot.value.volumes.sumOf { it.totalBytes }
                                val used = snapshot.value.volumes.sumOf { it.usedBytes }
                                if (total > 0) {
                                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                        Text(stringResource(R.string.storage_space), style = MaterialTheme.typography.bodyMedium)
                                        Text(stringResource(R.string.client_storage_usage, formatBytes(used), formatBytes(total)),
                                            style = MaterialTheme.typography.bodySmall)
                                    }
                                    LinearProgressIndicator(progress = { (used.toFloat() / total).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
                                }
                            }
                        }
                        TextButton(onClick = { onTab(NasSettingsTab.PERFORMANCE) }) { Text(stringResource(R.string.performance)) }
                    }
                }
            }
            item { ClientSectionTitle(stringResource(R.string.client_manage_device)) }
            DeviceCategory.entries.chunked(2).forEach { row ->
                item {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        row.forEach { section ->
                            Surface(onClick = { onCategory(section) }, modifier = Modifier.weight(1f),
                                color = MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.medium,
                                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                                Column(Modifier.fillMaxWidth().heightIn(min = 112.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Icon(section.icon, null)
                                    Text(stringResource(section.title), style = MaterialTheme.typography.titleSmall)
                                    Text(stringResource(section.detail), style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }
            }
            item { ClientSectionTitle(stringResource(R.string.client_packages_services)) }
            item { ClientFeatureGrid(listOf(ClientDestination.DOWNLOADS, ClientDestination.CONTAINERS, ClientDestination.VIRTUAL_MACHINES), onSelect = onOpen) }
            item { ClientRow(stringResource(R.string.client_all_packages), Icons.Outlined.Apps) { onTab(NasSettingsTab.PACKAGES) } }
        } else {
            item {
                ClientGroup {
                    category.tabs.forEach { tab ->
                        ClientRow(stringResource(tab.clientTitle()), category.icon) { onTab(tab) }
                    }
                }
            }
        }
    }
}
