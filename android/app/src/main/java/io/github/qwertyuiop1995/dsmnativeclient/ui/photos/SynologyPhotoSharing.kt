package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.app.DatePickerDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoSharingCodec
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable
internal fun ColumnScope.PhotoSharingForm(album: SynologyPhotoAlbumState, model: SynologyPhotoAlbumModel) {
    val sharing by model.sharing.state.collectAsState()
    val original = sharing.original
    val enabled = !album.working && album.access?.let { it.canManage || it.isOwner && it.album.temporaryShare } == true
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    if (sharing.selectingMembers) { SharingMembers(sharing, model.sharing, enabled); return }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_sharing_form"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (original == null) item { Button(onClick = model::retryAccess) { Text(stringResource(R.string.sp_retry)) } }
        else {
            item { Text(original.album.name, style = MaterialTheme.typography.titleMedium) }
            item { SharingChoice(stringResource(R.string.sp_sharing_access), stringResource(sharing.access.label()),
                SynologyPhotoLinkAccess.entries.map { it to stringResource(it.label()) }, enabled, "photos_sharing_access", model.sharing::access) }
            if (sharing.access in setOf(SynologyPhotoLinkAccess.VIEW, SynologyPhotoLinkAccess.DOWNLOAD)) item {
                Text(stringResource(if (sharing.access == SynologyPhotoLinkAccess.VIEW) R.string.sp_sharing_public_view_note else R.string.sp_sharing_public_download_note),
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            item { Text(stringResource(R.string.sp_sharing_members), style = MaterialTheme.typography.titleSmall) }
            if (sharing.members == null) item { Text(stringResource(R.string.sp_sharing_members_unreadable), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            else {
                if (sharing.members!!.isEmpty()) item { Text(stringResource(R.string.sp_sharing_no_members), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(sharing.members!!, key = { "${it.id.type}:${it.id.value}" }) { grant ->
                    val name = sharing.names[grant.id].orEmpty()
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(name, style = MaterialTheme.typography.titleSmall)
                                Text(stringResource(if (grant.id.type == "group") R.string.sp_sharing_group else R.string.sp_sharing_user), style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { model.sharing.remove(grant.id) }, enabled = enabled) {
                                Icon(Icons.Outlined.Close, stringResource(R.string.sp_sharing_remove_member, name))
                            }
                        }
                        SharingChoice(stringResource(R.string.sp_sharing_role), stringResource(grant.role.roleLabel()),
                            sharing.roles.map { it to stringResource(it.roleLabel()) }, enabled, "photos_sharing_role_${grant.id.type}_${grant.id.value}") { model.sharing.role(grant.id, it) }
                    }
                }
                item { OutlinedButton(onClick = { model.sharing.selectMembers() }, enabled = enabled, modifier = Modifier.fillMaxWidth().testTag("photos_sharing_add_member")) {
                    Text(stringResource(R.string.sp_sharing_add_member))
                } }
            }
            item { SharingChoice(stringResource(R.string.password), stringResource(sharing.passwordMode.label()),
                SynologyPhotoSharingPassword.entries.map { it to stringResource(it.label()) }, enabled, "photos_sharing_password_mode", model.sharing::passwordMode) }
            if (sharing.passwordMode == SynologyPhotoSharingPassword.UNCHANGED) item {
                Text(stringResource(when (original.snapshot.hasPassword) { true -> R.string.sp_sharing_password_on; false -> R.string.sp_sharing_password_off; null -> R.string.sp_sharing_password_unknown }),
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (sharing.passwordMode == SynologyPhotoSharingPassword.SET) item {
                OutlinedTextField(sharing.password, model.sharing::password, Modifier.fillMaxWidth().testTag("photos_sharing_password"),
                    label = { Text(stringResource(R.string.sp_sharing_new_password)) }, singleLine = true, enabled = enabled,
                    visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focus.clearFocus(); keyboard?.hide() }))
            }
            item { SharingExpiration(sharing, model.sharing, enabled) }
            item { SharingLink(sharing, enabled) }
        }
    }
    HorizontalDivider()
    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)) {
        if (album.temporaryPreparationId != null) OutlinedButton(onClick = model::dismiss, enabled = !album.working) {
            Text(stringResource(R.string.sp_temporary_cancel))
        }
        Button(onClick = { focus.clearFocus(); keyboard?.hide(); model.save() }, enabled = enabled && sharing.valid, modifier = Modifier.testTag("photos_album_save")) {
            Text(stringResource(R.string.sp_sharing_save))
        }
    }
}

@Composable
internal fun <T> SharingChoice(label: String, value: String, choices: List<Pair<T, String>>, enabled: Boolean, tag: String, select: (T) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(label, style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag)) {
                Text(value, Modifier.weight(1f)); Icon(Icons.Outlined.ExpandMore, null)
            }
            DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
                choices.forEach { (choice, title) -> DropdownMenuItem(text = { Text(title) }, onClick = { expanded = false; select(choice) }) }
            }
        }
    }
}

@Composable
private fun SharingExpiration(state: SynologyPhotoSharingState, model: SynologyPhotoSharingModel, enabled: Boolean) {
    val context = LocalContext.current
    val locale = LocalConfiguration.current.locales[0]
    val zone = ZoneId.systemDefault()
    val seconds = state.expiration ?: state.original?.snapshot?.expiration
    val format = remember(locale, zone) { DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).withZone(zone) }
    val displayed = when { seconds == null -> stringResource(R.string.sp_sharing_expiration_unknown)
        seconds == 0L -> stringResource(R.string.sp_sharing_no_expiration)
        else -> runCatching { format.format(Instant.ofEpochSecond(seconds)) }.getOrElse { stringResource(R.string.sp_sharing_expiration_unknown) } }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SharingChoice(stringResource(R.string.sp_sharing_expiration), displayed, listOf(
            0 to stringResource(R.string.sp_sharing_keep_expiration), 1 to stringResource(R.string.sp_sharing_no_expiration),
            2 to stringResource(R.string.sp_sharing_choose_date)), enabled, "photos_sharing_expiration") { choice -> when (choice) {
                0 -> model.expiration(null)
                1 -> model.expiration(0)
                else -> {
                    val initial = runCatching { seconds?.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).atZone(zone).toLocalDate() } }.getOrNull() ?: LocalDate.now(zone)
                    DatePickerDialog(context, { _, year, month, day -> model.expiration(photoSharingExpiration(LocalDate.of(year, month + 1, day), zone)) },
                        initial.year, initial.monthValue - 1, initial.dayOfMonth).show()
                }
            } }
    }
}

@Composable
private fun SharingLink(state: SynologyPhotoSharingState, enabled: Boolean) {
    val url = state.original?.url ?: return
    val change = state.change ?: return
    if (change.access != change.original.access || SynologyPhotoSharingCodec.modifiesProtectionOrMembers(change)) return
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val shareTitle = stringResource(R.string.sp_sharing_send_link)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = {
            clipboard.setText(AnnotatedString(url)); Toast.makeText(context, R.string.share_link_existing_copied, Toast.LENGTH_SHORT).show()
        }, enabled = enabled, modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("photos_sharing_copy")) { Text(stringResource(R.string.sp_copy_link)) }
        OutlinedButton(onClick = {
            try { context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url), shareTitle)) }
            catch (_: ActivityNotFoundException) { Toast.makeText(context, R.string.sp_sharing_send_unavailable, Toast.LENGTH_LONG).show() }
        }, enabled = enabled, modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("photos_sharing_send")) { Text(shareTitle) }
    }
}

@Composable
private fun ColumnScope.SharingMembers(state: SynologyPhotoSharingState, model: SynologyPhotoSharingModel, enabled: Boolean) {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val existing = state.members.orEmpty().mapTo(mutableSetOf()) { it.id }
    val candidates = state.candidates.orEmpty().filter { it.id !in existing && it.name.contains(state.search.trim(), ignoreCase = true) }
    LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("photos_sharing_candidates"), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { TextButton(onClick = { focus.clearFocus(); keyboard?.hide(); model.closeMembers() }) { Text(stringResource(R.string.sp_sharing_back)) } }
        item { OutlinedTextField(state.search, model::search, Modifier.fillMaxWidth().testTag("photos_sharing_search"),
            label = { Text(stringResource(R.string.sp_sharing_search)) }, singleLine = true, enabled = enabled) }
        when {
            state.loading -> item { CircularProgressIndicator() }
            state.error != null -> item {
                Text(photoAlbumError(state.error), color = MaterialTheme.colorScheme.error)
                Button(onClick = { model.selectMembers() }, enabled = enabled) { Text(stringResource(R.string.sp_retry)) }
            }
            candidates.isEmpty() -> item { Text(stringResource(if (state.search.isBlank()) R.string.sp_sharing_no_candidates else R.string.sp_sharing_no_search_results)) }
            else -> items(candidates, key = { "${it.id.type}:${it.id.value}" }) { recipient ->
                OutlinedButton(onClick = { model.add(recipient) }, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(recipient.name)
                        Text(stringResource(if (recipient.id.type == "group") R.string.sp_sharing_group else R.string.sp_sharing_user), style = MaterialTheme.typography.bodySmall)
                    }
                    Text(stringResource(R.string.sp_sharing_add))
                }
            }
        }
    }
}

private fun SynologyPhotoLinkAccess.label() = when (this) {
    SynologyPhotoLinkAccess.DISABLED -> R.string.sp_sharing_disabled
    SynologyPhotoLinkAccess.INVITED -> R.string.sp_sharing_invited
    SynologyPhotoLinkAccess.VIEW -> R.string.sp_sharing_view
    SynologyPhotoLinkAccess.DOWNLOAD -> R.string.sp_sharing_download
}
internal fun SynologyPhotoSharingPassword.label() = when (this) {
    SynologyPhotoSharingPassword.UNCHANGED -> R.string.sp_sharing_keep_password
    SynologyPhotoSharingPassword.SET -> R.string.sp_sharing_set_password
    SynologyPhotoSharingPassword.REMOVE -> R.string.sp_sharing_remove_password
}
private fun String.roleLabel() = when (this) {
    "view" -> R.string.sp_sharing_role_view
    "download" -> R.string.sp_sharing_role_download
    "upload" -> R.string.sp_sharing_role_upload
    else -> R.string.sp_sharing_role_existing
}
