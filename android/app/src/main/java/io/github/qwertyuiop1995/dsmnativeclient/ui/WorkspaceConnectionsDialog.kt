package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.launch
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet

internal val LocalWorkspaceHost = staticCompositionLocalOf<WorkspaceHostModel?> { null }

internal fun needsConnectionAccount(profile: NasProfile, profiles: List<NasProfile>): Boolean = profiles.any {
    it.id != profile.id && it.username != profile.username &&
        (it.name == profile.name || it.address == profile.address && it.port == profile.port)
}

internal fun needsConnectionAddress(profile: NasProfile, profiles: List<NasProfile>): Boolean = profiles.any {
    it.id != profile.id && it.name == profile.name && it.username == profile.username &&
        (it.address != profile.address || it.port != profile.port)
}

@Composable
internal fun connectionAddress(profile: NasProfile): String = profile.port?.let {
    stringResource(R.string.workspace_address_port, profile.address, it)
} ?: profile.address

@Composable
internal fun WorkspaceConnectionPicker(items: List<WorkspaceConnectionItem>, host: WorkspaceHostModel) {
    var removal by remember { mutableStateOf<NasProfile?>(null) }
    var signOut by remember { mutableStateOf<NasProfile?>(null) }
    var renaming by remember { mutableStateOf<NasProfile?>(null) }
    val content: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items.forEach { item ->
                var menuVisible by remember(item.profile.id) { mutableStateOf(false) }
                Surface(onClick = { host.select(item.profile.id, edit = item.hasWorkspace && item.status == WorkspaceConnectionStatus.SIGN_IN) }, shape = MaterialTheme.shapes.medium,
                    color = if (item.selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface,
                    modifier = Modifier.fillMaxWidth().semantics { selected = item.selected }) {
                    Row(Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(start = 16.dp, top = 8.dp, bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(Icons.Outlined.Dns, null)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(item.profile.name, style = MaterialTheme.typography.titleSmall,
                                maxLines = 2, overflow = TextOverflow.Ellipsis)
                            if (needsConnectionAccount(item.profile, items.map { it.profile })) Text(item.profile.username,
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (needsConnectionAddress(item.profile, items.map { it.profile })) Text(connectionAddress(item.profile),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(stringResource(when (item.status) {
                                WorkspaceConnectionStatus.CONNECTED -> R.string.workspace_connected
                                WorkspaceConnectionStatus.CONNECTING -> R.string.connecting
                                WorkspaceConnectionStatus.SIGN_IN -> if (item.hasWorkspace) R.string.workspace_connection_sign_in else R.string.workspace_connection_saved
                                WorkspaceConnectionStatus.NEEDS_ATTENTION -> R.string.workspace_connection_attention
                            }), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (item.selected) Icon(Icons.Outlined.CheckCircle, stringResource(R.string.workspace_connection_selected),
                            tint = MaterialTheme.colorScheme.primary)
                        Box {
                            IconButton(onClick = { menuVisible = true }) {
                                Icon(Icons.Outlined.MoreVert, stringResource(R.string.client_device_actions))
                            }
                            DropdownMenu(menuVisible, onDismissRequest = { menuVisible = false }) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.rename)) },
                                    onClick = { menuVisible = false; renaming = item.profile })
                                DropdownMenuItem(text = { Text(stringResource(R.string.edit)) },
                                    onClick = { menuVisible = false; host.select(item.profile.id, edit = true) })
                                if (item.hasWorkspace) DropdownMenuItem(
                                    text = { Text(stringResource(R.string.sign_out_description)) },
                                    onClick = { menuVisible = false; signOut = item.profile })
                                DropdownMenuItem(text = { Text(stringResource(R.string.remove_saved_nas)) },
                                    onClick = { menuVisible = false; removal = item.profile })
                            }
                        }
                    }
                }
            }
            OutlinedButton(onClick = { host.newConnection() }, shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                Icon(Icons.Outlined.Add, null)
                Text(stringResource(R.string.client_add_nas), Modifier.padding(start = 8.dp))
            }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (maxWidth < 600.dp) ClientSheet(stringResource(R.string.switch_nas), host::dismissPicker) { content() }
        else Dialog(onDismissRequest = host::dismissPicker, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.widthIn(max = 500.dp).fillMaxWidth().padding(24.dp), shape = MaterialTheme.shapes.extraLarge) {
                Column(Modifier.heightIn(max = 640.dp).verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.switch_nas), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                        IconButton(onClick = host::dismissPicker) { Icon(Icons.Outlined.Close, stringResource(R.string.close)) }
                    }
                    content()
                }
            }
        }
    }
    removal?.let { profile -> ConfirmDialog(stringResource(R.string.remove_profile_title, connectionConfirmationName(profile, items)),
        stringResource(R.string.remove_profile_message), stringResource(R.string.remove), true,
        onConfirm = { removal = null; host.removeConnection(profile) }, onDismiss = { removal = null }) }
    signOut?.let { profile -> ConfirmDialog(stringResource(R.string.workspace_sign_out_title, connectionConfirmationName(profile, items)),
        stringResource(R.string.client_logout_hint), stringResource(R.string.sign_out_description), true,
        onConfirm = { signOut = null; host.signOut(profile.id) }, onDismiss = { signOut = null }) }
    renaming?.let { profile -> RenameConnectionDialog(profile, host) { renaming = null } }
}

@Composable
private fun RenameConnectionDialog(profile: NasProfile, host: WorkspaceHostModel, onDismiss: () -> Unit) {
    var name by remember(profile.id) { mutableStateOf(profile.name) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    AlertDialog(onDismissRequest = { if (!saving) onDismiss() }, title = { Text(stringResource(R.string.rename)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(name, { name = it; failed = false }, enabled = !saving, singleLine = true,
                label = { Text(stringResource(R.string.display_name)) }, modifier = Modifier.testTag("connection_display_name"))
            if (failed) Text(stringResource(R.string.error_connection_name_save), color = MaterialTheme.colorScheme.error)
        } },
        confirmButton = { TextButton(enabled = !saving && name.isNotBlank(), onClick = save@ {
            if (saving || name.isBlank()) return@save
            val desiredName = name
            saving = true
            scope.launch {
                val saved = suspendRunCatching { host.renameConnection(profile, desiredName) }.getOrDefault(false)
                if (saved) onDismiss() else { saving = false; failed = true }
            }
        }) {
            if (saving) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)) }
            Text(stringResource(R.string.save))
        } },
        dismissButton = { TextButton(enabled = !saving, onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}

@Composable
internal fun connectionConfirmationName(profile: NasProfile, items: List<WorkspaceConnectionItem>): String =
    connectionConfirmationName(androidx.compose.ui.platform.LocalContext.current, profile, items.map { it.profile })

internal fun connectionConfirmationName(context: android.content.Context, profile: NasProfile, profiles: List<NasProfile>): String =
    if (needsConnectionAddress(profile, profiles)) context.getString(R.string.workspace_account_page, profile.name,
        profile.port?.let { context.getString(R.string.workspace_address_port, profile.address, it) } ?: profile.address)
    else if (needsConnectionAccount(profile, profiles)) context.getString(R.string.workspace_account_page, profile.name, profile.username)
    else profile.name
