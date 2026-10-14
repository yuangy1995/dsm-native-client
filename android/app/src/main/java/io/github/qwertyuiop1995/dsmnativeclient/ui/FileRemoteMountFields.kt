package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun RemoteMountFields(feature: FileRemoteMountFeatureModel, state: FileRemoteMountState, password: String, onPassword: (String) -> Unit) {
    val setup = state.setup
    val enabled = !state.busy && !state.submitted
    val focus = LocalFocusManager.current; val keyboard = LocalSoftwareKeyboardController.current
    val endInput = { focus.clearFocus(); keyboard?.hide(); Unit }
    Text(stringResource(R.string.remote_mount_protocol), style = MaterialTheme.typography.titleSmall)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf(FileMountKind.CIFS to R.string.remote_mount_smb, FileMountKind.NFS to R.string.remote_mount_nfs).forEach { (kind, label) ->
            FilterChip(setup.kind == kind, { endInput(); onPassword(""); feature.protocol(kind) }, enabled = enabled,
                label = { Text(stringResource(label)) }, modifier = Modifier.heightIn(min = 48.dp).testTag("remote_protocol_${kind.name}"))
        }
    }
    OutlinedTextField(setup.server, { value -> feature.edit { it.copy(server = value) } }, Modifier.fillMaxWidth().testTag("remote_server"),
        label = { Text(stringResource(R.string.remote_mount_server)) }, enabled = enabled, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Done))
    OutlinedTextField(setup.remotePath, { value -> feature.edit { it.copy(remotePath = value) } }, Modifier.fillMaxWidth().testTag("remote_shared_folder"),
        label = { Text(stringResource(R.string.remote_mount_shared_folder)) }, enabled = enabled, singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done))
    if (setup.kind == FileMountKind.CIFS) {
        OutlinedTextField(setup.username, { value -> feature.edit { it.copy(username = value) } }, Modifier.fillMaxWidth().testTag("remote_username"),
            label = { Text(stringResource(R.string.remote_mount_username)) }, enabled = enabled, singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done))
        RemoteMountPassword(password, onPassword, enabled)
        OutlinedTextField(setup.domain, { value -> feature.edit { it.copy(domain = value) } }, Modifier.fillMaxWidth().testTag("remote_domain"),
            label = { Text(stringResource(R.string.remote_mount_domain)) }, enabled = enabled, singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done))
    } else {
        Text(stringResource(R.string.remote_mount_nfs_version), style = MaterialTheme.typography.titleSmall)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("3" to R.string.remote_mount_nfs3, "4" to R.string.remote_mount_nfs4).forEach { (version, label) ->
                FilterChip(setup.nfsVersion == version, { feature.edit { it.copy(nfsVersion = version, nfsTransport = if (version == "4") "tcp" else it.nfsTransport) } },
                    enabled = enabled, label = { Text(stringResource(label)) }, modifier = Modifier.heightIn(min = 48.dp).testTag("remote_nfs_$version"))
            }
        }
        Text(stringResource(R.string.remote_mount_transport), style = MaterialTheme.typography.titleSmall)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("tcp" to R.string.remote_mount_tcp, "udp" to R.string.remote_mount_udp).forEach { (transport, label) ->
                FilterChip(setup.nfsTransport == transport, { feature.edit { it.copy(nfsTransport = transport) } },
                    enabled = enabled && (transport == "tcp" || setup.nfsVersion != "4"), label = { Text(stringResource(label)) },
                    modifier = Modifier.heightIn(min = 48.dp).testTag("remote_transport_$transport"))
            }
        }
    }
    ClientGroup {
        ClientRow(stringResource(R.string.remote_mount_destination), Icons.Outlined.FolderOpen,
            detail = setup.mountPoint.ifEmpty { stringResource(R.string.iso_choose_destination) }, enabled = enabled,
            onClick = { endInput(); feature.openLocations() })
    }
    if (state.baseline == null || setup.mountPoint != state.baseline.mountPoint) Text(stringResource(R.string.remote_mount_empty_folder_hint), style = MaterialTheme.typography.bodySmall)
    if (state.baseline != null && state.baseline.mountPoint != setup.mountPoint) TextButton(feature::useOriginalDestination,
        Modifier.heightIn(min = 48.dp), enabled = enabled) { Text(stringResource(R.string.remote_mount_use_original_folder)) }
    if (!state.automaticChosen) {
        Text(stringResource(R.string.remote_mount_choose_automatic))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(false, { feature.automatic(false) }, enabled = enabled, label = { Text(stringResource(R.string.disabled)) })
            FilterChip(false, { feature.automatic(true) }, enabled = enabled, label = { Text(stringResource(R.string.enabled)) })
        }
    } else Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("remote_automatic")
        .toggleable(setup.automatic, enabled = enabled, role = Role.Checkbox, onValueChange = feature::automatic), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(setup.automatic, onCheckedChange = null)
        Text(stringResource(R.string.iso_automatic), Modifier.weight(1f).padding(start = 8.dp))
    }
}

@Composable
internal fun RemoteMountPassword(value: String, onValueChange: (String) -> Unit, enabled: Boolean) {
    OutlinedTextField(value, onValueChange, Modifier.fillMaxWidth().testTag("remote_password"), singleLine = true, enabled = enabled,
        label = { Text(stringResource(R.string.password)) }, visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done))
}
