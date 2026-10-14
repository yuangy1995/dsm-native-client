package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.ui.platform.LocalConfiguration
import android.app.DatePickerDialog
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
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
internal fun FileSharingDialogs(model: AppViewModel) {
    val feature = model.fileSharing
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    val state by feature.state.collectAsStateWithLifecycle()
    val editor = state.editor ?: return
    if (state.membersVisible) { FileShareMembersDialog(feature, state); return }
    val title = stringResource(when (editor) {
        FileShareEditor.CREATE -> R.string.file_share_create
        FileShareEditor.EDIT -> R.string.file_share_edit
        FileShareEditor.ACCESS -> R.string.file_share_access
    })
    ClientSheet(title, feature::close, Modifier.testTag("file_share_editor"),
        dismissEnabled = !state.busy, canDismiss = { !feature.state.value.busy }) {
        Text((state.targets.map { it.name } + state.links.map { it.name }).joinToString("\n"), maxLines = 5)
        if (state.submitted) {
            FileShareResults(state, model)
        } else {
            if (editor == FileShareEditor.ACCESS) FileShareAccessFields(feature, state)
            else {
                if (editor == FileShareEditor.EDIT) {
                    Text(stringResource(R.string.file_share_password))
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FileSharePasswordMode.entries.forEach { mode -> FilterChip(state.draft.passwordMode == mode,
                            { feature.edit { it.copy(passwordMode = mode, password = "") } }, label = {
                                Text(stringResource(when (mode) { FileSharePasswordMode.KEEP -> R.string.file_share_keep; FileSharePasswordMode.SET -> R.string.file_share_password_set; FileSharePasswordMode.REMOVE -> R.string.file_share_password_remove }))
                            }) }
                    }
                }
                if (editor == FileShareEditor.CREATE || state.draft.passwordMode == FileSharePasswordMode.SET) {
                    OutlinedTextField(state.draft.password, { value -> feature.edit { it.copy(password = value) } },
                        Modifier.fillMaxWidth().testTag("file_share_password"), singleLine = true,
                        label = { Text(stringResource(if (editor == FileShareEditor.CREATE) R.string.file_share_password_optional else R.string.file_share_password_set)) },
                        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                        isError = state.draft.password.codePointCount(0, state.draft.password.length) > 16,
                        supportingText = { Text(stringResource(R.string.file_share_password_limit)) })
                }
                FileShareDateField(R.string.file_share_available, state.draft.availableOn, editor == FileShareEditor.EDIT, R.string.file_share_immediate) { value -> feature.edit { it.copy(availableOn = value) } }
                FileShareDateField(R.string.file_share_expires, state.draft.expiresOn, editor == FileShareEditor.EDIT, R.string.file_share_no_expiry) { value -> feature.edit { it.copy(expiresOn = value) } }
                if (editor == FileShareEditor.CREATE) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(7L, 30L, 90L).forEach { days ->
                            TextButton({ feature.edit { it.copy(expiresOn = FileShareDateChange.Set(LocalDate.now().plusDays(days))) } }, Modifier.heightIn(min = 48.dp)) {
                                Text(stringResource(R.string.file_share_days, days.toInt()))
                            }
                        }
                    }
                    if (state.targets.all { it.isDirectory && it.canWrite }) {
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(state.draft.fileRequest, role = Role.Switch,
                            onValueChange = { value -> feature.edit { it.copy(fileRequest = value) } }), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.file_share_collection), Modifier.weight(1f)); Switch(state.draft.fileRequest, onCheckedChange = null)
                        }
                        if (state.draft.fileRequest) FileShareRequestFields(feature, state.draft)
                    }
                    Text(stringResource(if (state.draft.fileRequest) R.string.file_share_collection_consequence else if (state.draft.password.isEmpty())
                        R.string.file_share_public_consequence else R.string.file_share_password_consequence), style = MaterialTheme.typography.bodySmall)
                }
            }
            if (!feature.canSubmit() && editor != FileShareEditor.ACCESS) Text(stringResource(R.string.file_share_check_fields), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
            Button({ focus.clearFocus(); keyboard?.hide(); feature.submit() }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("file_share_submit"), enabled = feature.canSubmit()) {
                Text(stringResource(if (editor == FileShareEditor.CREATE) R.string.file_share_create else R.string.file_share_save))
            }
        }
    }
    if (state.confirmation) AlertDialog(onDismissRequest = feature::dismissConfirmation,
        title = { Text(stringResource(R.string.file_share_confirm_title)) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(when {
                state.draft.fileRequest -> R.string.file_share_collection_consequence
                state.draft.passwordMode != FileSharePasswordMode.KEEP && state.links.any { it.advanced?.protection == FileShareProtection.USERS } -> R.string.file_share_replace_members_consequence
                state.draft.passwordMode == FileSharePasswordMode.REMOVE -> R.string.file_share_password_remove_consequence
                state.draft.audience == FileShareAudienceChange.Anyone -> R.string.file_share_public_consequence
                else -> R.string.file_share_members_consequence
            }))
            Text((state.targets.map { it.name } + state.links.map { it.name }).joinToString("\n"))
            (state.draft.audience as? FileShareAudienceChange.Principals)?.members?.forEach { Text(it.name) }
        } },
        confirmButton = { TextButton({ feature.submit(acceptRisk = true) }, Modifier.testTag("file_share_confirm")) { Text(stringResource(if (editor == FileShareEditor.CREATE) R.string.file_share_create else R.string.file_share_save)) } },
        dismissButton = { TextButton(feature::dismissConfirmation) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun FileShareDateField(label: Int, value: FileShareDateChange, allowKeep: Boolean, clearLabel: Int, onChange: (FileShareDateChange) -> Unit) {
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    Text(stringResource(label), style = MaterialTheme.typography.titleSmall)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (allowKeep) FilterChip(value == FileShareDateChange.Keep, { onChange(FileShareDateChange.Keep) }, label = { Text(stringResource(R.string.file_share_keep)) })
        FilterChip(value == FileShareDateChange.Clear, { onChange(FileShareDateChange.Clear) }, label = { Text(stringResource(clearLabel)) })
        FilterChip(value is FileShareDateChange.Set, {
            focus.clearFocus(); keyboard?.hide()
            val date = (value as? FileShareDateChange.Set)?.date ?: LocalDate.now()
            DatePickerDialog(context, { _, year, month, day -> onChange(FileShareDateChange.Set(LocalDate.of(year, month + 1, day))) },
                date.year, date.monthValue - 1, date.dayOfMonth).show()
        }, label = { Text((value as? FileShareDateChange.Set)?.date?.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
            .withLocale(LocalConfiguration.current.locales[0])) ?: stringResource(R.string.file_share_custom_date)) })
    }
}

@Composable
private fun FileShareRequestFields(feature: FileSharingFeatureModel, draft: FileShareDraft) {
    OutlinedTextField(draft.requestName, { value -> feature.edit { it.copy(requestName = value) } }, Modifier.fillMaxWidth().testTag("file_share_request_name"),
        label = { Text(stringResource(R.string.file_share_request_name)) }, singleLine = true)
    OutlinedTextField(draft.requestMessage, { value -> feature.edit { it.copy(requestMessage = value) } }, Modifier.fillMaxWidth().testTag("file_share_request_message"),
        label = { Text(stringResource(R.string.file_share_request_message)) }, minLines = 2, maxLines = 5)
}

@Composable
private fun FileShareAccessFields(feature: FileSharingFeatureModel, state: FileSharingState) {
    val original = state.links.single().advanced ?: return
    if (!original.isFileRequest) {
        Text(stringResource(R.string.file_share_audience), style = MaterialTheme.typography.titleSmall)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(state.draft.audience == FileShareAudienceChange.Keep, { feature.edit { it.copy(audience = FileShareAudienceChange.Keep) } }, label = { Text(stringResource(R.string.file_share_keep)) })
            FilterChip(state.draft.audience == FileShareAudienceChange.Anyone, { feature.edit { it.copy(audience = FileShareAudienceChange.Anyone) } }, label = { Text(stringResource(R.string.file_share_anyone)) })
            FilterChip(state.draft.audience is FileShareAudienceChange.Principals, feature::openMembers, label = { Text(stringResource(R.string.file_share_named_members)) })
        }
        (state.draft.audience as? FileShareAudienceChange.Principals)?.members?.forEach { Text(it.name, style = MaterialTheme.typography.bodySmall) }
    }
    OutlinedTextField(state.draft.maximumAccesses, { value -> feature.edit { it.copy(maximumAccesses = value) } },
        Modifier.fillMaxWidth().testTag("file_share_access_count"), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        isError = state.draft.maximumAccesses.toIntOrNull()?.let { it in 0..9999 } != true,
        label = { Text(stringResource(R.string.file_share_access_count)) }, supportingText = { Text(stringResource(R.string.file_share_access_count_hint)) })
    if (original.isFileRequest) {
        Text(stringResource(if (original.allowsUpload) R.string.file_share_collection_receiving else R.string.file_share_collection_closed))
        FileShareRequestFields(feature, state.draft)
    }
}

@Composable
private fun FileShareResults(state: FileSharingState, model: AppViewModel) {
    if (state.busy) {
        LinearProgressIndicator(Modifier.fillMaxWidth())
        Text(stringResource(R.string.file_share_saving))
        if (state.targets.size + state.links.size > 1) TextButton(model.fileSharing::stopAfterCurrent, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.file_share_stop_remaining)) }
    }
    state.results.forEach { result ->
        ClientGroup {
            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(result.name, style = MaterialTheme.typography.titleSmall)
                Text(stringResource(when (result.outcome.result.status) {
                    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.file_share_saved
                    MutationResultStatus.CONFIRMED_FAILURE -> R.string.file_share_failed
                    MutationResultStatus.PERMISSION_DENIED -> R.string.file_share_denied
                    MutationResultStatus.UNSUPPORTED -> R.string.file_share_unsupported
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.file_share_cancelled
                    else -> R.string.file_share_unknown
                }))
                result.outcome.link?.let { FileShareLinkActions(listOf(it), model) }
            }
        }
    }
    val links = state.results.mapNotNull { it.outcome.link }
    if (links.size > 1) FileShareLinkActions(links, model)
    if (!state.busy) TextButton(model.fileSharing::close, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.close)) }
}
