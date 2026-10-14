package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun PackagePreferencesContent(state: NasPackageCenterState, refresh: () -> Unit, save: (NasPackagePreferences) -> Unit) {
    val baseline = state.preferences
    var draft by remember(baseline) { mutableStateOf(baseline) }
    val value = draft
    val writable = !state.busy && !state.preferencesLoading && state.activities.all { it.terminal }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { ClientSectionTitle(stringResource(R.string.pc_preferences), stringResource(R.string.refresh), refresh) }
        if (state.preferencesLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        state.preferencesFailure?.let { item { PackageError(it, refresh, retry = true) } }
        if (value != null) {
            item {
                PackageToggle(stringResource(R.string.pc_beta), value.beta, writable) { draft = value.copy(beta = it) }
                PackageToggle(stringResource(R.string.pc_email), value.email, writable) { draft = value.copy(email = it) }
                PackageToggle(stringResource(R.string.pc_desktop), value.desktop, writable) { draft = value.copy(desktop = it) }
                PackageChoice(stringResource(R.string.pc_auto_updates), value.policy.name, updatePolicies(), writable) { draft = value.copy(policy = NasPackageUpdatePolicy.valueOf(it)) }
                if (value.volumes.size > 1) PackageChoice(stringResource(R.string.pc_location), value.defaultVolume,
                    listOf(NasPackageChoice("", stringResource(R.string.pc_ask_location))) + value.volumes, writable) { draft = value.copy(defaultVolume = it) }
            }
            if (value.policy == NasPackageUpdatePolicy.SELECTED) {
                if (value.packages.any { it.policy == null }) item { Text(stringResource(R.string.pc_unknown_preferences)) }
                items(value.packages, key = { it.id }) { item ->
                    PackageChoice(item.name, item.policy?.name.orEmpty(), updatePolicies(includeSelected = false), writable && item.automaticAllowed && item.policy != null) { policy ->
                        draft = value.copy(packages = value.packages.map { if (it.id == item.id) it.copy(policy = NasPackageUpdatePolicy.valueOf(policy)) else it })
                    }
                }
            }
            item {
                Button(onClick = { save(value) }, enabled = writable && value != baseline && (value.policy != NasPackageUpdatePolicy.SELECTED || value.packages.none { it.policy == null }),
                    modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.save_changes)) }
            }
        }
    }
}
@Composable
private fun updatePolicies(includeSelected: Boolean = true): List<NasPackageChoice> = NasPackageUpdatePolicy.entries.filter { includeSelected || it != NasPackageUpdatePolicy.SELECTED }.map {
    NasPackageChoice(it.name, stringResource(when (it) {
        NasPackageUpdatePolicy.MANUAL -> R.string.pc_policy_manual
        NasPackageUpdatePolicy.LATEST -> R.string.pc_policy_latest
        NasPackageUpdatePolicy.IMPORTANT -> R.string.pc_policy_important
        NasPackageUpdatePolicy.SELECTED -> R.string.pc_policy_selected
    }))
}

@Composable
internal fun PackageSourcesContent(state: NasPackageCenterState, refresh: () -> Unit, save: (NasPackageSource?, NasPackageSource?) -> Unit) {
    var editing by remember { mutableStateOf(false) }
    var original by remember { mutableStateOf<NasPackageSource?>(null) }
    var deleting by remember { mutableStateOf<NasPackageSource?>(null) }
    val writable = !state.busy && !state.sourcesLoading && state.sources != null && state.activities.all { it.terminal }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            ClientSectionTitle(stringResource(R.string.pc_sources), stringResource(R.string.refresh), refresh)
            TextButton(onClick = { original = null; editing = true }, enabled = writable) { Text(stringResource(R.string.pc_add_source)) }
        }
        if (state.sourcesLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        state.sourcesFailure?.let { item { PackageError(it, refresh, retry = true) } }
        if (state.sources?.isEmpty() == true && !state.sourcesLoading && state.sourcesFailure == null) item { Text(stringResource(R.string.pc_sources_empty)) }
        items(state.sources.orEmpty(), key = { it.url }) { source ->
            ClientGroup {
                Column(Modifier.padding(12.dp)) {
                    Text(source.name, style = MaterialTheme.typography.titleSmall); Text(source.url)
                    Row {
                        TextButton(onClick = { original = source; editing = true }, enabled = writable) { Text(stringResource(R.string.pc_edit_source)) }
                        TextButton(onClick = { deleting = source }, enabled = writable) { Text(stringResource(R.string.pc_remove_source)) }
                    }
                }
            }
        }
    }
    if (editing) PackageSourceSheet(original, onDismiss = { editing = false }, onSave = { save(original, it); editing = false })
    deleting?.let { source -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text(stringResource(R.string.pc_remove_source)) },
        text = { Text(stringResource(R.string.pc_remove_source_message, source.name)) },
        confirmButton = { TextButton(onClick = { save(source, null); deleting = null }) { Text(stringResource(R.string.pc_remove_source)) } },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.cancel)) } }) }
}
@Composable
private fun PackageSourceSheet(original: NasPackageSource?, onDismiss: () -> Unit, onSave: (NasPackageSource) -> Unit) {
    var name by remember(original) { mutableStateOf(original?.name.orEmpty()) }
    var address by remember(original) { mutableStateOf(original?.url.orEmpty()) }
    var accepted by remember(original) { mutableStateOf(false) }
    ClientSheet(stringResource(if (original == null) R.string.pc_add_source else R.string.pc_edit_source), onDismiss) {
        OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.pc_source_name)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(address, { address = it; accepted = false }, label = { Text(stringResource(R.string.pc_source_address)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
        if (address.trim().startsWith("http://", true)) Text(stringResource(R.string.pc_source_http), color = MaterialTheme.colorScheme.error)
        PackageToggle(stringResource(R.string.pc_source_trust), accepted) { accepted = it }
        Button(onClick = { onSave(NasPackageSource(name, address)) }, enabled = accepted && name.isNotBlank() && address.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.save_changes))
        }
    }
}

@Composable
internal fun PackageActivityContent(records: List<PackageActivityRecord>, busy: Boolean, review: (PackageActivityRecord) -> Unit, discard: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (records.isEmpty()) item { Text(stringResource(R.string.pc_activity_empty)) }
        items(records, key = { it.id }) { record ->
            if (record.kind == PackageActivityKind.CONTROL) {
                PackageControlActivity(record, busy, { review(record) }, { discard(record.id) })
                return@items
            }
            ClientGroup {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(when (record.kind) { PackageActivityKind.SETTINGS -> R.string.pc_preferences; PackageActivityKind.SOURCE -> R.string.pc_sources; PackageActivityKind.INSTALL -> R.string.pc_install_plan; PackageActivityKind.CONTROL -> R.string.pc_installed }), style = MaterialTheme.typography.titleSmall)
                    record.items.forEach { item ->
                        if (item.packageId.isNotEmpty()) Text(stringResource(R.string.pc_activity_package, item.packageId, item.version))
                        Text(stringResource(when (item.phase) {
                            PackageActivityPhase.READY -> R.string.pc_not_started
                            PackageActivityPhase.SUBMITTED -> R.string.pc_status_unavailable
                            PackageActivityPhase.PREPARED -> R.string.pc_options
                            PackageActivityPhase.COMPLETED -> R.string.pc_completed
                            PackageActivityPhase.REJECTED -> R.string.pc_failed
                            PackageActivityPhase.CANCELLED -> R.string.pc_cancelled
                            PackageActivityPhase.INTERRUPTED -> R.string.pc_preparation_interrupted
                        }))
                    }
                    if (!record.terminal) TextButton(onClick = { review(record) }, enabled = !busy) { Text(stringResource(R.string.refresh)) }
                    else TextButton(onClick = { discard(record.id) }, enabled = !busy) { Text(stringResource(R.string.pc_remove_record)) }
                }
            }
        }
    }
}
