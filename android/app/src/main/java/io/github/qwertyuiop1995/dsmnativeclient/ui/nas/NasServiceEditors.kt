package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings

@Composable
internal fun FileServiceDialog(
    baseline: NasFileServiceSettings,
    restoredDraft: NasFileServiceSettings?,
    onDraftChange: (NasFileServiceSettings) -> Unit,
    onSave: (NasFileServiceSettings) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember(baseline, restoredDraft) { mutableStateOf(restoredDraft ?: baseline) }
    LaunchedEffect(draft) { onDraftChange(draft) }
    val validation = fileServiceValidation(draft)
    SettingsDialog(
        title = stringResource(R.string.file_services),
        valid = validation == null,
        changed = draft != baseline,
        onSave = { onSave(draft) },
        onDismiss = onDismiss,
    ) {
        NullableSettingsSwitch(R.string.smb_service, draft.isSmbEnabled) {
            draft = draft.copy(isSmbEnabled = it)
        }
        NullableSettingsSwitch(R.string.nfs_service, draft.isNfsEnabled) {
            draft = draft.copy(isNfsEnabled = it)
        }
        NullableSettingsSwitch(R.string.ftp_service, draft.isFtpEnabled) {
            draft = draft.copy(isFtpEnabled = it)
        }
        NullableSettingsSwitch(R.string.ftps_service, draft.isFtpsEnabled) {
            draft = draft.copy(isFtpsEnabled = it)
        }
        draft.ftpPort?.let { port ->
            PortField(port, R.string.ftp_port, validation == ServiceValidation.FTP_PORT) {
                draft = draft.copy(ftpPort = it)
            }
        }
        NullableSettingsSwitch(R.string.sftp_service, draft.isSftpEnabled) {
            draft = draft.copy(isSftpEnabled = it)
        }
        draft.sftpPort?.let { port ->
            PortField(port, R.string.sftp_port, validation == ServiceValidation.SFTP_PORT) {
                draft = draft.copy(sftpPort = it)
            }
        }
        NullableSettingsSwitch(R.string.ssdp_discovery, draft.isSsdpEnabled) {
            draft = draft.copy(isSsdpEnabled = it)
        }
        NullableSettingsSwitch(R.string.bonjour_discovery, draft.isBonjourEnabled) {
            draft = draft.copy(isBonjourEnabled = it)
        }
        NullableSettingsSwitch(R.string.smb_time_machine, draft.isSmbTimeMachineEnabled) {
            draft = draft.copy(isSmbTimeMachineEnabled = it)
        }
        validation?.let {
            Text(
                stringResource(
                    if (it == ServiceValidation.PORT_CONFLICT) R.string.file_service_port_conflict
                    else if (it == ServiceValidation.TIME_MACHINE) R.string.time_machine_requires_smb
                    else R.string.invalid_port,
                ),
                color = MaterialTheme.colorScheme.error,
            )
        }
        Text(
            stringResource(R.string.file_services_impact_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun TerminalSettingsDialog(
    baseline: NasTerminalSettings,
    restoredDraft: NasTerminalSettings?,
    onDraftChange: (NasTerminalSettings) -> Unit,
    onSave: (NasTerminalSettings) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember(baseline, restoredDraft) { mutableStateOf(restoredDraft ?: baseline) }
    LaunchedEffect(draft) { onDraftChange(draft) }
    val invalidPort = draft.sshPort?.let { it !in 1..65_535 } == true
    SettingsDialog(
        title = stringResource(R.string.remote_terminal),
        valid = !invalidPort,
        changed = draft != baseline,
        onSave = { onSave(draft) },
        onDismiss = onDismiss,
    ) {
        SettingsSwitch(R.string.ssh_service, draft.isSshEnabled) {
            draft = draft.copy(isSshEnabled = it)
        }
        SettingsSwitch(R.string.telnet_service, draft.isTelnetEnabled) {
            draft = draft.copy(isTelnetEnabled = it)
        }
        draft.sshPort?.let { port ->
            PortField(port, R.string.ssh_port, invalidPort) { draft = draft.copy(sshPort = it) }
        }
        Text(
            stringResource(R.string.terminal_security_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun ProxySettingsDialog(
    baseline: NasProxySettings,
    restoredDraft: NasProxySettings?,
    onDraftChange: (NasProxySettings) -> Unit,
    onSave: (NasProxySettings) -> Unit,
    onDismiss: () -> Unit,
) {
    val initial = restoredDraft ?: baseline
    var enabled by rememberSaveable(baseline, restoredDraft) { mutableStateOf(initial.isEnabled) }
    var host by rememberSaveable(baseline, restoredDraft) { mutableStateOf(initial.host) }
    var portText by rememberSaveable(baseline, restoredDraft) {
        mutableStateOf(initial.port?.toString().orEmpty())
    }
    val port = portText.toIntOrNull()
    val hostInvalid = enabled && !isValidProxyHost(host.trim())
    val portInvalid = enabled && (port == null || port !in 1..65_535)
    val draft = NasProxySettings(enabled, host.trim(), port)
    val changed = enabled != baseline.isEnabled || enabled &&
        (draft.host != baseline.host.trim() || draft.port != baseline.port)
    LaunchedEffect(draft) { onDraftChange(draft) }
    SettingsDialog(
        title = stringResource(R.string.internet_proxy),
        valid = !hostInvalid && !portInvalid,
        changed = changed,
        onSave = { onSave(draft) },
        onDismiss = onDismiss,
    ) {
        SettingsSwitch(R.string.use_internet_proxy, enabled) { enabled = it }
        if (enabled) {
            OutlinedTextField(
                value = host,
                onValueChange = { host = it },
                label = { Text(stringResource(R.string.proxy_host)) },
                isError = hostInvalid,
                supportingText = if (hostInvalid) {
                    { Text(stringResource(R.string.invalid_proxy_host)) }
                } else null,
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = portText,
                onValueChange = { portText = it.filter(Char::isDigit).take(5) },
                label = { Text(stringResource(R.string.proxy_port)) },
                isError = portInvalid,
                supportingText = if (portInvalid) { { Text(stringResource(R.string.invalid_port)) } } else null,
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Text(
            stringResource(R.string.proxy_impact_hint),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SettingsDialog(
    title: String,
    valid: Boolean,
    changed: Boolean,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 560.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) { content() }
        },
        confirmButton = {
            TextButton(enabled = valid && changed, onClick = onSave) { Text(stringResource(R.string.continue_action)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun NullableSettingsSwitch(label: Int, value: Boolean?, onChange: (Boolean) -> Unit) {
    value?.let { SettingsSwitch(label, it, onChange) }
}

@Composable
private fun SettingsSwitch(label: Int, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .toggleable(value = value, role = Role.Switch, onValueChange = onChange)
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(label), modifier = Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = null)
    }
}

@Composable
private fun PortField(value: Int, label: Int, isError: Boolean, onChange: (Int) -> Unit) {
    var text by remember(value) { mutableStateOf(value.toString()) }
    OutlinedTextField(
        value = text,
        onValueChange = {
            text = it.filter(Char::isDigit).take(5)
            onChange(text.toIntOrNull() ?: 0)
        },
        label = { Text(stringResource(label)) },
        isError = isError,
        supportingText = if (isError) { { Text(stringResource(R.string.invalid_port)) } } else null,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = Modifier.fillMaxWidth(),
    )
}

private enum class ServiceValidation { FTP_PORT, SFTP_PORT, PORT_CONFLICT, TIME_MACHINE }

private fun fileServiceValidation(value: NasFileServiceSettings): ServiceValidation? = when {
    value.ftpPort?.let { it !in 1..65_535 } == true -> ServiceValidation.FTP_PORT
    value.sftpPort?.let { it !in 1..65_535 } == true -> ServiceValidation.SFTP_PORT
    value.isSmbTimeMachineEnabled == true && value.isSmbEnabled == false -> ServiceValidation.TIME_MACHINE
    (value.isFtpEnabled == true || value.isFtpsEnabled == true) && value.isSftpEnabled == true &&
        value.ftpPort != null && value.ftpPort == value.sftpPort -> ServiceValidation.PORT_CONFLICT
    else -> null
}

private fun isValidProxyHost(value: String): Boolean =
    value.isNotBlank() && value.length <= 255 && "://" !in value &&
        value.none { it.isWhitespace() || it in "/?#@" }
