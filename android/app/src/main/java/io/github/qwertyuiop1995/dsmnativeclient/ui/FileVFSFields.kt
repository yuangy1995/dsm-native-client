package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.FileVFSFeatureModel
import io.github.qwertyuiop1995.dsmnativeclient.FileVFSState
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileVFSProtocol

@Composable
internal fun FileVFSFields(feature: FileVFSFeatureModel, state: FileVFSState, password: String, onPassword: (String) -> Unit,
                          replacePassword: Boolean, onReplacePassword: (Boolean) -> Unit) {
    val setup = state.setup
    val enabled = !state.busy && !state.submitted
    var advanced by remember(state.baseline) { mutableStateOf(false) }
    Text(stringResource(R.string.vfs_protocol), style = MaterialTheme.typography.titleSmall)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        feature.options().filter(FileVFSProtocol::supportsServerSetup).forEach { option ->
            FilterChip(setup.protocolId == option.id, { onPassword(""); feature.protocol(option.id) }, enabled = enabled && state.baseline == null,
                label = { Text(option.name) }, modifier = Modifier.heightIn(min = 48.dp).testTag("vfs_protocol_${option.id}"))
        }
    }
    FileVFSField(setup.alias, { value -> feature.edit { it.copy(alias = value) } }, R.string.vfs_alias, "vfs_alias", enabled)
    FileVFSField(setup.hostname, { value -> feature.edit { it.copy(hostname = value) } }, R.string.vfs_server, "vfs_server", enabled, KeyboardType.Uri)
    var portText by remember(state.baseline, setup.protocolId, setup.port) { mutableStateOf(setup.port.takeIf { it > 0 }?.toString().orEmpty()) }
    FileVFSField(portText, { value -> portText = value; feature.edit { it.copy(port = value.toIntOrNull() ?: 0) } }, R.string.vfs_port, "vfs_port", enabled, KeyboardType.Number)
    FileVFSField(setup.account, { value -> feature.edit { it.copy(account = value) } }, R.string.vfs_account, "vfs_account", enabled)
    if (state.baseline != null) FileVFSToggle(replacePassword, onReplacePassword, R.string.vfs_replace_password, "vfs_replace_password", enabled)
    if (state.baseline == null || replacePassword) OutlinedTextField(password, onPassword, Modifier.fillMaxWidth().testTag("vfs_password"),
        enabled = enabled, singleLine = true, label = { Text(stringResource(R.string.password)) }, visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done))
    if (setup.protocolId in setOf("dav", "davs")) FileVFSField(setup.folder, { value -> feature.edit { it.copy(folder = value) } },
        R.string.vfs_folder, "vfs_folder", enabled)
    TextButton({ advanced = !advanced }, Modifier.heightIn(min = 48.dp).testTag("vfs_advanced")) { Text(stringResource(R.string.vfs_advanced)) }
    if (advanced) {
        FileVFSField(setup.codepage, { value -> feature.edit { it.copy(codepage = value) } }, R.string.vfs_encoding, "vfs_encoding", enabled)
        if (setup.protocolId == "ftp") FileVFSToggle(setup.usesOneConnection, { value -> feature.edit { it.copy(usesOneConnection = value) } },
            R.string.vfs_one_connection, "vfs_one_connection", enabled)
    }
}

@Composable
private fun FileVFSField(value: String, onChange: (String) -> Unit, label: Int, tag: String, enabled: Boolean, keyboard: KeyboardType = KeyboardType.Text) {
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth().testTag(tag), label = { Text(stringResource(label)) }, enabled = enabled,
        singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = keyboard, imeAction = ImeAction.Done))
}

@Composable
private fun FileVFSToggle(value: Boolean, onChange: (Boolean) -> Unit, label: Int, tag: String, enabled: Boolean) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag).toggleable(value, enabled = enabled, role = Role.Checkbox, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically) {
        Checkbox(value, onCheckedChange = null)
        Text(stringResource(label), Modifier.weight(1f).padding(start = 8.dp))
    }
}
