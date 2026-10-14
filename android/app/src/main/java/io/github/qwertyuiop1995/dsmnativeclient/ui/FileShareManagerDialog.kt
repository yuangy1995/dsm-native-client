package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.ui.platform.LocalResources
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
internal fun FileShareManagerDialog(workspace: WorkspaceState, model: AppViewModel, onClose: () -> Unit) {
    val state by model.fileSharing.state.collectAsStateWithLifecycle()
    if (state.editor != null) return
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var unavailable by remember { mutableStateOf(false) }
    var qrLink by remember { mutableStateOf<FileShareLink?>(null) }
    val links = (workspace.fileShareLinks as? Loadable.Ready)?.value.orEmpty()
    val selection = links.filter { it.id in selected }
    val filtered = links.filter { it.name.contains(query, ignoreCase = true) }
    fun edit(items: List<FileShareLink>, access: Boolean = false) { if (!model.fileSharing.openEdit(items, access)) unavailable = true }
    ClientPageDialog(stringResource(R.string.manage_share_links), onClose) {
        Column(Modifier.fillMaxSize().testTag("file_share_manager")) {
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                ClientSearchField(query, { query = it }, stringResource(R.string.file_share_filter), Modifier.weight(1f),
                    onSearch = { focus.clearFocus(); keyboard?.hide() })
                IconButton(model::loadFileShareLinks, enabled = !state.busy && workspace.fileShareLinks !is Loadable.Loading) {
                    Icon(Icons.Outlined.Refresh, stringResource(R.string.refresh))
                }
            }
            if (selection.isNotEmpty()) {
                FlowRow(Modifier.padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    IconButton({ selected = emptySet() }) { Icon(Icons.Outlined.Close, stringResource(R.string.clear_selection)) }
                    Text(stringResource(R.string.items_selected_count, selection.size), Modifier.padding(vertical = 12.dp))
                    FileShareLinkActions(selection, model)
                    TextButton({ edit(selection) }, enabled = !workspace.isPerformingAction, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.file_share_edit)) }
                    TextButton({ model.requestFileShareLinkDeletion(selection.map { it.id }) }, enabled = !workspace.isPerformingAction,
                        modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.delete_share_link), color = MaterialTheme.colorScheme.error) }
                }
            }
            if (state.pending.isNotEmpty()) {
                Text(stringResource(R.string.file_share_pending, state.pending.size), Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
            }
            state.failure?.let { Text(it.localize(context).combined, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) }
            when (val result = workspace.fileShareLinks) {
                Loadable.Idle, Loadable.Loading -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                is Loadable.Failed -> FileShareEmpty(Modifier.weight(1f), stringResource(R.string.manage_share_links_load_failed), result.error.localize(context).combined,
                    stringResource(R.string.retry), model::loadFileShareLinks)
                is Loadable.Ready -> when {
                    result.value.isEmpty() -> FileShareEmpty(Modifier.weight(1f), stringResource(R.string.manage_share_links_empty), stringResource(R.string.manage_share_links_empty_description),
                        stringResource(R.string.close), onClose)
                    filtered.isEmpty() -> FileShareEmpty(Modifier.weight(1f), stringResource(R.string.file_share_filter_empty), stringResource(R.string.file_share_filter_empty_hint),
                        stringResource(R.string.file_share_clear_filter), { query = "" })
                    else -> LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(filtered, key = FileShareLink::id) { link ->
                            ClientGroup {
                                Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(link.id in selected, role = Role.Checkbox,
                                        onValueChange = { checked -> selected = if (checked) selected + link.id else selected - link.id }), verticalAlignment = Alignment.CenterVertically) {
                                        Checkbox(link.id in selected, onCheckedChange = null)
                                        Text(link.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                                    }
                                    Text(stringResource(when (link.status) {
                                        FileShareStatus.VALID -> R.string.file_share_status_valid
                                        FileShareStatus.INVALID -> R.string.file_share_status_invalid
                                        FileShareStatus.INACTIVE -> R.string.file_share_status_inactive
                                        FileShareStatus.EXPIRED -> R.string.file_share_status_expired
                                        FileShareStatus.BROKEN -> R.string.file_share_status_broken
                                        FileShareStatus.UNKNOWN -> R.string.file_share_status_unknown
                                    }), style = MaterialTheme.typography.bodySmall)
                                    if (link.passwordKnown && link.hasPassword) Text(stringResource(R.string.share_link_password_protected), style = MaterialTheme.typography.bodySmall)
                                    link.availableAt?.let { Text(stringResource(R.string.file_share_available_on, shareDisplayDate(it, context)), style = MaterialTheme.typography.bodySmall) }
                                    link.expiresAt?.let { Text(stringResource(R.string.share_link_expires_at, shareDisplayDate(it, context)), style = MaterialTheme.typography.bodySmall) }
                                    if (link.advanced?.isFileRequest == true) Text(stringResource(R.string.file_share_collection), style = MaterialTheme.typography.bodySmall)
                                    else if (link.advanced?.protection == FileShareProtection.USERS) Text(stringResource(R.string.file_share_named_members), style = MaterialTheme.typography.bodySmall)
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        IconButton({ model.copyFileShareLink(link) }, enabled = !workspace.isPerformingAction) { Icon(Icons.Outlined.ContentCopy, stringResource(R.string.copy_share_link)) }
                                        ShareLinkButton(listOf(link))
                                        IconButton({ qrLink = link }, enabled = !workspace.isPerformingAction) { Icon(Icons.Outlined.QrCode, stringResource(R.string.file_share_qr)) }
                                        IconButton({ edit(listOf(link)) }, enabled = !workspace.isPerformingAction) { Icon(Icons.Outlined.Edit, stringResource(R.string.file_share_edit)) }
                                        if (link.advanced != null) IconButton({ edit(listOf(link), access = true) }, enabled = !workspace.isPerformingAction) { Icon(Icons.Outlined.ManageAccounts, stringResource(R.string.file_share_access)) }
                                        IconButton({ model.requestFileShareLinkDeletion(listOf(link.id)) }, enabled = !workspace.isPerformingAction) { Icon(Icons.Outlined.DeleteOutline, stringResource(R.string.delete_share_link), tint = MaterialTheme.colorScheme.error) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (unavailable) AlertDialog(onDismissRequest = { unavailable = false },
        title = { Text(stringResource(R.string.file_share_edit_unavailable)) }, text = { Text(stringResource(R.string.file_share_edit_unavailable_hint)) },
        confirmButton = { TextButton({ unavailable = false; model.loadFileShareLinks() }) { Text(stringResource(R.string.refresh)) } },
        dismissButton = { TextButton({ unavailable = false }) { Text(stringResource(R.string.close)) } })
    qrLink?.let { FileShareQrDialog(it) { qrLink = null } }
}

@Composable
internal fun FileShareLinkActions(links: List<FileShareLink>, model: AppViewModel) {
    val context = LocalContext.current
    val resources = LocalResources.current
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton({
        if (links.size == 1) model.copyFileShareLink(links.single())
        else (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(
            ClipData.newPlainText(resources.getString(R.string.share_link_clip_label), links.joinToString("\n") { it.url }))
        }, Modifier.heightIn(min = 48.dp)) { Icon(Icons.Outlined.ContentCopy, null); Text(stringResource(R.string.copy_share_link), Modifier.padding(start = 8.dp)) }
        ShareLinkButton(links, showLabel = true)
    }
}

@Composable
private fun ShareLinkButton(links: List<FileShareLink>, showLabel: Boolean = false) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val share = {
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, links.joinToString("\n") { it.url })
        context.startActivity(Intent.createChooser(intent, resources.getString(R.string.file_share_system)))
    }
    if (showLabel) TextButton(share, Modifier.heightIn(min = 48.dp)) {
        Icon(Icons.Outlined.Share, null); Text(stringResource(R.string.file_share_system), Modifier.padding(start = 8.dp))
    } else IconButton(share) { Icon(Icons.Outlined.Share, stringResource(R.string.file_share_system)) }
}

@Composable
internal fun FileShareEmpty(modifier: Modifier, title: String, detail: String, action: String, onAction: () -> Unit) {
    Box(modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.Link, null, Modifier.size(40.dp))
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(detail, style = MaterialTheme.typography.bodyMedium)
            TextButton(onAction, Modifier.heightIn(min = 48.dp)) { Text(action) }
        }
    }
}

private fun shareDisplayDate(value: String, context: Context): String = runCatching {
    LocalDate.parse(value.take(10)).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(context.resources.configuration.locales[0])) +
        if (value.length == 19) " " + value.takeLast(8) else ""
}.getOrDefault(value)
