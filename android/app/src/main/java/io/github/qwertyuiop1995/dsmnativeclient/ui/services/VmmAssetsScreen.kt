package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable internal fun VmmAssetsScreen(model: VmmAssetModel, kind: VmmAssetKind, blocked: Boolean,
    protectedGuests: Set<String> = emptySet(), header: @Composable () -> Unit = {}, protectedAssets: Set<String> = emptySet()) {
    val state by model.state.collectAsStateWithLifecycle()
    LaunchedEffect(model, kind) { model.refresh(kind) }
    VmmAssetsContent(state, kind, blocked, protectedGuests, { model.refresh(kind) }, model::requestNetworks,
        model::saveNetworkName, model::requestImages, model::confirm, model::cancel, model::dismiss, header, protectedAssets)
}

@Composable internal fun VmmAssetsContent(state: VmmAssetState, kind: VmmAssetKind, blocked: Boolean = false,
    protectedGuests: Set<String> = emptySet(), onRefresh: () -> Unit, onNetworks: (List<VmmNetwork>, String?) -> Boolean,
    onRename: (VmmNetwork, String) -> Boolean, onImages: (List<VmmImage>) -> Boolean, onConfirm: (VmmAssetConfirmation) -> Boolean,
    onCancel: () -> Unit, onDismiss: () -> Unit, header: @Composable () -> Unit = {}, protectedAssets: Set<String> = emptySet()) {
    var query by rememberSaveable(kind) { mutableStateOf("") }
    var selected by remember(kind) { mutableStateOf(setOf<String>()) }
    var networkDetails by remember { mutableStateOf<VmmNetwork?>(null) }
    var imageDetails by remember { mutableStateOf<VmmImage?>(null) }
    var rename by remember { mutableStateOf<VmmNetwork?>(null) }; var name by remember { mutableStateOf("") }
    val networks = state.networks?.networks.orEmpty(); val images = state.images?.images.orEmpty()
    val frozen = if (kind == VmmAssetKind.NETWORK) state.networks?.frozen == true else state.images?.frozen == true
    val unavailable = state.blocked || blocked || frozen
    val protected = state.protectedIds(kind) + protectedAssets
    fun VmmNetwork.isProtected() = vmmDigest(id) in protected || guests.any { vmmDigest(it.id) in protectedGuests }
    LaunchedEffect(kind, networks, images) { selected = selected.intersect(if (kind == VmmAssetKind.NETWORK) networks.map { it.id }.toSet() else images.map { it.id }.toSet()) }
    LaunchedEffect(state.busy) { if (state.busy) { networkDetails = null; imageDetails = null; selected = emptySet() } }
    val rows = if (kind == VmmAssetKind.NETWORK) networks.map { it.id to it.name } else images.map { it.id to it.name }
    val filtered = rows.filter { it.second?.contains(query, ignoreCase = true) == true || query.isBlank() }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(query, { query = it }, stringResource(if (kind == VmmAssetKind.NETWORK) R.string.vm_network_search else R.string.vm_image_search), modifier = Modifier.weight(1f))
            IconButton(onClick = onRefresh, enabled = !state.busy) { Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh)) }
        }
        if (selected.isNotEmpty()) OutlinedButton(onClick = {
            if (kind == VmmAssetKind.NETWORK) onNetworks(networks.filter { it.id in selected }, null) else onImages(images.filter { it.id in selected })
        }, enabled = !unavailable && (if (kind == VmmAssetKind.NETWORK) networks.filter { it.id in selected }.none { it.isProtected() }
            else images.filter { it.id in selected }.all { it.canDelete && vmmDigest(it.id) !in protected }), modifier = Modifier.padding(horizontal = 16.dp)) { Text(stringResource(R.string.delete)) }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { header() }
            state.records.filter { it.kind == kind }.forEach { record -> item {
                VmmAssetActivityCard(record, rows, state.busy, onRefresh, onDismiss)
            } }
            state.failure?.let { failure -> item {
                ClientGroup { Column(Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
                    Text(vmmErrorText(failure, if (kind == VmmAssetKind.NETWORK) R.string.vm_network_changed else R.string.vm_image_changed), color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = onRefresh, enabled = !state.busy) { Text(stringResource(R.string.refresh)) }
                } }
            } }
            if (state.busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (frozen) item { Text(stringResource(R.string.vm_assets_busy)) }
            if (filtered.isEmpty() && (if (kind == VmmAssetKind.NETWORK) state.networks != null else state.images != null)) item {
                Text(stringResource(if (rows.isNotEmpty()) R.string.vm_assets_no_matches else if (kind == VmmAssetKind.NETWORK) R.string.vm_network_empty else R.string.vm_image_empty), Modifier.padding(vertical = 24.dp))
            }
            items(filtered, key = { it.first }) { (id, label) ->
                val network = networks.singleOrNull { it.id == id }; val image = images.singleOrNull { it.id == id }
                val canSelect = !unavailable && if (kind == VmmAssetKind.NETWORK) network?.isProtected() == false else image?.canDelete == true && vmmDigest(id) !in protected
                val title = label ?: stringResource(R.string.vm_image_unnamed)
                ClientGroup { ListItem(headlineContent = { Text(title) }, supportingContent = {
                    if (kind == VmmAssetKind.NETWORK && network != null) Text(stringResource(R.string.vm_connected_count, network.guests.size))
                    else if (image != null) Text(vmmImageType(image.type))
                }, leadingContent = { Checkbox(checked = id in selected, enabled = canSelect, onCheckedChange = { selected = if (it) selected + id else selected - id },
                    modifier = Modifier.semantics { contentDescription = title }) }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable {
                    if (kind == VmmAssetKind.NETWORK) networkDetails = network else imageDetails = image
                }) }
            }
        }
    }
    networkDetails?.let { original ->
        val network = networks.singleOrNull { it.id == original.id && it.identity == original.identity }
        ClientSheet(original.name, onDismiss = { networkDetails = null }) {
            if (network == null) Text(stringResource(R.string.vm_network_changed)) else {
                Text(stringResource(if (network.type == "private") R.string.vm_network_private else R.string.vm_network_external))
                Text(stringResource(R.string.vm_vlan, network.vlan))
                Text(stringResource(R.string.vm_interface_count, network.interfaces.size))
                Text(stringResource(R.string.vm_connected_count, network.guests.size))
                network.guests.forEach { guest -> Text(stringResource(R.string.vm_item_status, guest.name, stringResource(if (guest.running) R.string.vm_running else R.string.vm_stopped))) }
                OutlinedButton(onClick = { rename = network; name = network.name; networkDetails = null }, enabled = !unavailable && !network.isProtected(), modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.vm_rename_network)) }
                OutlinedButton(onClick = { if (onNetworks(listOf(network), null)) networkDetails = null }, enabled = !unavailable && !network.isProtected(), modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.delete)) }
            }
        }
    }
    imageDetails?.let { original ->
        val image = images.singleOrNull { it.id == original.id && it.identity == original.identity }
        ClientSheet(original.name ?: stringResource(R.string.vm_image_unnamed), onDismiss = { imageDetails = null }) {
            if (image == null) Text(stringResource(R.string.vm_image_changed)) else {
                Text(vmmImageType(image.type))
                if (image.copies.isNotEmpty()) Text(stringResource(R.string.vm_copy_count, image.copies.size))
                if (image.inUse == true) Text(stringResource(R.string.vm_image_in_use))
                else if (!image.canDelete) Text(stringResource(R.string.vm_image_readonly))
                OutlinedButton(onClick = { if (onImages(listOf(image))) imageDetails = null }, enabled = !unavailable && image.canDelete && vmmDigest(image.id) !in protected,
                    modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.delete)) }
            }
        }
    }
    rename?.let { target ->
        ClientSheet(stringResource(R.string.vm_rename_network), onDismiss = { if (!state.busy) rename = null }, dismissEnabled = !state.busy) {
            OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text(stringResource(R.string.network_name)) }, singleLine = true, enabled = !state.busy, modifier = Modifier.fillMaxWidth())
            Button(onClick = { if (onRename(target, name.trim())) rename = null }, enabled = !state.busy && validVmmNetworkName(name.trim()) && name.trim() != target.name, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.save)) }
            TextButton(onClick = { rename = null }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }
    state.confirmation?.takeIf { it.action == VmmAssetAction.DELETE }?.let { confirmation ->
        ClientSheet(stringResource(vmmAssetTitle(confirmation.kind, confirmation.action)), onDismiss = onCancel, dismissEnabled = !state.busy) {
            confirmation.networks.forEach { Text(it.name); Text(stringResource(R.string.vm_connected_count, it.guests.size)) }
            confirmation.images.forEach { Text(it.name ?: stringResource(R.string.vm_image_unnamed)) }
            Text(stringResource(if (confirmation.kind == VmmAssetKind.NETWORK) R.string.vm_network_delete_risk else R.string.vm_image_delete_risk))
            Button(onClick = { onConfirm(confirmation) }, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.delete)) }
            TextButton(onClick = onCancel, enabled = !state.busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable private fun VmmAssetActivityCard(record: VmmAssetActivity, rows: List<Pair<String, String?>>, busy: Boolean, onRefresh: () -> Unit, onDismiss: () -> Unit) {
    ClientGroup { Column(Modifier.fillMaxWidth().padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(vmmAssetTitle(record.kind, record.action)), style = MaterialTheme.typography.titleSmall)
        record.items.forEachIndexed { index, item ->
            val name = rows.singleOrNull { vmmDigest(it.first) == item.id }?.second ?: stringResource(R.string.vm_asset_number, index + 1)
            Text(stringResource(R.string.vm_item_status, name, stringResource(when (item.stage) {
                VmmStage.PREPARED, VmmStage.CANCELLED -> R.string.vm_not_sent
                VmmStage.SUBMITTED -> R.string.vm_result_unavailable
                VmmStage.ACCEPTED -> R.string.vm_processing
                VmmStage.REJECTED -> R.string.vm_rejected
                VmmStage.VERIFIED -> if (record.action == VmmAssetAction.RENAME) R.string.vm_renamed else R.string.vm_removed
            })))
        }
        if (record.pending) Text(stringResource(R.string.vm_pending_hint))
        TextButton(onClick = if (record.pending) onRefresh else onDismiss, enabled = !busy) { Text(stringResource(if (record.pending) R.string.refresh else R.string.close)) }
    } }
}
private fun vmmAssetTitle(kind: VmmAssetKind, action: VmmAssetAction) = when {
    action == VmmAssetAction.RENAME -> R.string.vm_rename_network
    kind == VmmAssetKind.NETWORK -> R.string.vm_delete_network
    else -> R.string.vm_delete_image
}
@Composable private fun vmmImageType(type: String?) = stringResource(when (type) { "iso" -> R.string.vm_image_iso; "disk" -> R.string.vm_image_disk; else -> R.string.images })
