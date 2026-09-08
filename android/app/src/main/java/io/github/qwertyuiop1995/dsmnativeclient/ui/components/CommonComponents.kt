package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image as FoundationImage
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AdminPanelSettings
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.NetworkCheck
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.LoginState
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResourceLabel
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferDirection
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineOverview
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.login.LoginScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.nas.NasSettingsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.settings.LanguageMenu
import io.github.qwertyuiop1995.dsmnativeclient.ui.settings.SettingsScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.ContainersScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.services.VirtualMachinesScreen
import io.github.qwertyuiop1995.dsmnativeclient.ui.transfers.TransfersScreen
import java.text.DateFormat
import java.util.Date

@Composable
internal fun <T> LoadableContent(
    value: Loadable<T>,
    emptyTitle: String,
    emptyMessage: String,
    onRetry: () -> Unit,
    content: @Composable (T) -> Unit,
) {
    PageStateContent(
        state = value.toPageUiState(isEmpty = { data ->
            data is Collection<*> && data.isEmpty()
        }),
        emptyTitle = emptyTitle,
        emptyMessage = emptyMessage,
        emptyIcon = Icons.Outlined.Info,
        filteredEmptyTitle = emptyTitle,
        filteredEmptyMessage = emptyMessage,
        filteredEmptyIcon = Icons.Outlined.Info,
        onRetry = onRetry,
        content = content,
    )
}

@Composable
internal fun <T> PageStateContent(
    state: PageUiState<T>,
    emptyTitle: String,
    emptyMessage: String,
    emptyIcon: ImageVector,
    filteredEmptyTitle: String,
    filteredEmptyMessage: String,
    filteredEmptyIcon: ImageVector,
    onRetry: () -> Unit,
    content: @Composable (T) -> Unit,
) {
    val loadingDescription = stringResource(R.string.loading)
    val context = LocalContext.current
    when (state) {
        PageUiState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                Modifier.semantics { contentDescription = loadingDescription },
            )
        }
        PageUiState.Empty -> EmptyState(emptyTitle, emptyMessage, emptyIcon)
        PageUiState.FilteredEmpty -> EmptyState(
            filteredEmptyTitle,
            filteredEmptyMessage,
            filteredEmptyIcon,
        )
        is PageUiState.Error -> {
            val error = state.failure.localize(context)
            ErrorState(error.message, error.recovery, onRetry)
        }
        is PageUiState.Content -> content(state.value)
    }
}

@Composable
internal fun ResourceList(
    resources: List<ManagedResource>,
    emptyTitle: String,
    onSelect: (ManagedResource) -> Unit,
    headerAction: (@Composable () -> Unit)? = null,
) {
    if (resources.isEmpty() && headerAction == null) {
        EmptyState(emptyTitle, stringResource(R.string.no_category_items), Icons.Outlined.Info)
        return
    }
    LazyColumn {
        headerAction?.let { action ->
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp),
                    horizontalArrangement = Arrangement.End,
                ) { action() }
            }
        }
        items(resources, key = ManagedResource::id) { resource ->
            ListItem(
                headlineContent = {
                    Text(resource.displayName(), maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                supportingContent = {
                    Text(
                        resource.detail.ifBlank { resource.state.displayName() },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                leadingContent = { StatusIcon(resource.state) },
                trailingContent = {
                    IconButton(onClick = { onSelect(resource) }) {
                        Icon(Icons.Outlined.MoreVert, contentDescription = stringResource(R.string.more_actions))
                    }
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 48.dp)
                    .clickable { onSelect(resource) },
            )
            HorizontalDivider(Modifier.padding(start = 72.dp))
        }
    }
}

@Composable
internal fun ErrorBanner(message: String) {
    Card(
        shape = MaterialTheme.shapes.medium,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
        modifier = Modifier.semantics {
            contentDescription = message
            liveRegion = LiveRegionMode.Assertive
        },
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Outlined.ErrorOutline, null, tint = MaterialTheme.colorScheme.error)
            Text(
                message,
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
private fun ErrorState(message: String, recovery: String, onRetry: () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .semantics { liveRegion = LiveRegionMode.Assertive },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(MaterialTheme.colorScheme.errorContainer),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.ErrorOutline,
                    contentDescription = null,
                    modifier = Modifier.size(36.dp),
                    tint = MaterialTheme.colorScheme.error,
                )
            }
            Text(
                message,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                recovery,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
            Button(
                onClick = onRetry,
                shape = MaterialTheme.shapes.medium,
            ) {
                Text(stringResource(R.string.retry))
            }
        }
    }
}

@Composable
internal fun EmptyState(title: String, message: String, icon: ImageVector) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(68.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    modifier = Modifier.size(34.dp),
                    tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.8f),
                )
            }
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                message,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
internal fun ActionRow(
    icon: ImageVector,
    title: String,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(MaterialTheme.shapes.small)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        )
        Text(
            title,
            fontWeight = FontWeight.Medium,
            color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
internal fun ConfirmDialog(
    title: String,
    message: String,
    confirm: String,
    destructive: Boolean,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        shape = MaterialTheme.shapes.extraLarge,
        title = { Text(title, fontWeight = FontWeight.Bold) },
        text = { Text(message) },
        confirmButton = {
            Button(
                onClick = onConfirm,
                shape = MaterialTheme.shapes.medium,
                colors = if (destructive) {
                    androidx.compose.material3.ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError,
                    )
                } else {
                    androidx.compose.material3.ButtonDefaults.buttonColors()
                },
            ) { Text(confirm, fontWeight = FontWeight.Bold) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun TextInputDialog(
    title: String,
    label: String,
    initial: String = "",
    confirm: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var value by rememberSaveable { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        shape = MaterialTheme.shapes.extraLarge,
        title = { Text(title, fontWeight = FontWeight.Bold) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text(label) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            Button(
                onClick = { onConfirm(value) },
                enabled = value.isNotBlank(),
                shape = MaterialTheme.shapes.medium,
            ) { Text(confirm, fontWeight = FontWeight.Bold) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
internal fun StatusIcon(state: ResourceState) {
    Icon(
        when (state) {
            ResourceState.RUNNING -> Icons.Outlined.PlayArrow
            ResourceState.HEALTHY -> Icons.Outlined.CheckCircle
            ResourceState.WAITING -> Icons.Outlined.HourglassTop
            ResourceState.WARNING -> Icons.Outlined.WarningAmber
            ResourceState.ERROR -> Icons.Outlined.ErrorOutline
            ResourceState.PAUSED -> Icons.Outlined.Pause
            else -> Icons.Outlined.Info
        },
        contentDescription = state.displayName(),
        tint = when (state) {
            ResourceState.RUNNING, ResourceState.HEALTHY -> MaterialTheme.colorScheme.primary
            ResourceState.WARNING -> MaterialTheme.colorScheme.tertiary
            ResourceState.ERROR -> MaterialTheme.colorScheme.error
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        },
    )
}

@Composable
internal fun ManagedResource.displayName(): String = when (localizedLabel) {
    ManagedResourceLabel.SECURITY_AUTO_BLOCK -> stringResource(R.string.security_auto_block)
    ManagedResourceLabel.SECURITY_DOS_PROTECTION -> stringResource(R.string.security_dos_protection)
    ManagedResourceLabel.SECURITY_FIREWALL -> stringResource(R.string.security_firewall)
    null -> name.ifBlank { stringResource(R.string.unnamed_item) }
}

@Composable
internal fun ResourceState.displayName(): String = when (this) {
    ResourceState.RUNNING -> stringResource(R.string.running)
    ResourceState.STOPPED -> stringResource(R.string.stopped)
    ResourceState.PAUSED -> stringResource(R.string.paused)
    ResourceState.WAITING -> stringResource(R.string.waiting)
    ResourceState.HEALTHY -> stringResource(R.string.normal)
    ResourceState.WARNING -> stringResource(R.string.needs_attention)
    ResourceState.ERROR -> stringResource(R.string.abnormal)
    ResourceState.UNKNOWN -> stringResource(R.string.unknown_status)
}

internal fun formatBytes(value: Long): String {
    if (value < 1024) return "$value B"
    val units = listOf("KB", "MB", "GB", "TB", "PB")
    var amount = value.toDouble()
    var index = -1
    while (amount >= 1024 && index < units.lastIndex) {
        amount /= 1024
        index += 1
    }
    return if (amount >= 100) "%.0f %s".format(amount, units[index])
    else "%.1f %s".format(amount, units[index])
}

@Composable
internal fun formatRemainingDuration(seconds: Long): String {
    val safe = seconds.coerceAtLeast(0)
    val hours = safe / 3_600
    val minutes = (safe % 3_600) / 60
    return if (hours > 0) {
        stringResource(R.string.remaining_hours_minutes, hours, minutes)
    } else {
        stringResource(R.string.remaining_minutes, maxOf(1, (safe + 59) / 60))
    }
}
