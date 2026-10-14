package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileArchiveDialog(feature: FileArchiveFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    val editor = state.editor ?: return
    if (state.locationsVisible) { FileArchiveDestinationDialog(feature, state); return }
    if (state.browserVisible) { FileArchiveBrowserDialog(feature, state); return }
    val extraction = editor == FileArchiveEditor.EXTRACT
    ClientSheet(stringResource(if (extraction) R.string.extract_archive else R.string.create_archive), feature::close,
        Modifier.testTag("file_archive_editor")) {
        val focus = LocalFocusManager.current
        val keyboard = LocalSoftwareKeyboardController.current
        val finishInput = { focus.clearFocus(); keyboard?.hide(); Unit }
        state.sources.forEach { Text(it.name) }
        ClientGroup {
            ClientRow(stringResource(R.string.archive_destination), Icons.Outlined.FolderOpen,
                detail = state.destination?.path ?: stringResource(R.string.archive_choose_destination), onClick = { finishInput(); feature.openLocations() })
        }
        if (!extraction) {
            OutlinedTextField(state.archiveName, { feature.editCompression(name = it) }, Modifier.fillMaxWidth().testTag("archive_name"),
                label = { Text(stringResource(R.string.archive_name)) }, singleLine = true)
            ClientSectionTitle(stringResource(R.string.archive_format))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ArchiveFormat.entries.forEach { format -> FilterChip(state.format == format, { finishInput(); feature.editCompression(format = format) },
                    label = { Text(stringResource(if (format == ArchiveFormat.ZIP) R.string.archive_format_zip else R.string.archive_format_7z)) }) }
            }
            ClientSectionTitle(stringResource(R.string.archive_compression_level))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ArchiveCompressionLevel.entries.forEach { level -> FilterChip(state.level == level, { finishInput(); feature.editCompression(level = level) },
                    label = { Text(stringResource(when (level) {
                        ArchiveCompressionLevel.STORE -> R.string.archive_level_store
                        ArchiveCompressionLevel.FASTEST -> R.string.archive_level_fastest
                        ArchiveCompressionLevel.MODERATE -> R.string.archive_level_moderate
                        ArchiveCompressionLevel.BEST -> R.string.archive_level_best
                    })) }) }
            }
        }
        OutlinedTextField(state.options.password.orEmpty(), { value -> feature.editOptions { it.copy(password = value.takeIf(String::isNotEmpty)) } },
            Modifier.fillMaxWidth().testTag("archive_password"), label = { Text(stringResource(R.string.archive_password_optional)) },
            singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { finishInput() }))
        if (extraction) {
            ClientSectionTitle(stringResource(R.string.archive_filename_encoding))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(null to R.string.archive_encoding_auto, "chs" to R.string.archive_encoding_chs,
                    "cht" to R.string.archive_encoding_cht, "enu" to R.string.archive_encoding_enu,
                    "jpn" to R.string.archive_encoding_jpn, "krn" to R.string.archive_encoding_krn).forEach { (value, label) ->
                    FilterChip(state.options.codepage == value, { finishInput(); feature.editOptions { it.copy(codepage = value) } }, label = { Text(stringResource(label)) })
                }
            }
            if (state.page is Loadable.Loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            (state.page as? Loadable.Failed)?.let { Text(it.error.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton({ finishInput(); feature.reload() }, Modifier.heightIn(min = 48.dp).testTag("archive_read"), enabled = state.page !is Loadable.Loading) { Text(stringResource(R.string.archive_read_contents)) }
                TextButton({ finishInput(); feature.openBrowser() }, Modifier.heightIn(min = 48.dp).testTag("archive_browse"), enabled = state.page is Loadable.Ready) { Text(stringResource(R.string.archive_browse_contents)) }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(state.extractAll, { feature.setExtractAll(true) }, label = { Text(stringResource(R.string.archive_extract_all)) })
                FilterChip(!state.extractAll, { finishInput(); feature.setExtractAll(false); feature.openBrowser() }, label = { Text(stringResource(R.string.archive_extract_selected)) })
            }
            if (!state.extractAll) Text(pluralStringResource(R.plurals.archive_selected_count, state.selected.size, state.selected.size))
            ArchiveToggle(stringResource(R.string.archive_create_subfolder), state.options.createSubfolder, "archive_create_subfolder") { value -> feature.editOptions { it.copy(createSubfolder = value) } }
            ArchiveToggle(stringResource(R.string.archive_keep_directories), state.options.keepDirectories, "archive_keep_directories") { value -> feature.editOptions { it.copy(keepDirectories = value) } }
            ArchiveToggle(stringResource(R.string.archive_replace_existing), state.options.overwrite, "archive_overwrite") { value -> feature.editOptions { it.copy(overwrite = value) } }
        }
        if (state.destination?.canWrite == false) Text(stringResource(R.string.archive_choose_writable_destination), color = MaterialTheme.colorScheme.error)
        state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
        Button({ finishInput(); feature.submit() }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("archive_submit"), enabled = feature.canSubmit()) {
            Text(stringResource(if (extraction) R.string.extract else R.string.create))
        }
    }
    if (state.confirmation) AlertDialog(onDismissRequest = feature::dismissConfirmation,
        title = { Text(stringResource(R.string.archive_replace_title)) }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.archive_replace_warning)); Text(state.destination?.path.orEmpty())
            }
        }, confirmButton = { TextButton({ feature.submit(acceptOverwrite = true) }, Modifier.testTag("archive_confirm_overwrite")) { Text(stringResource(R.string.archive_replace_and_extract)) } },
        dismissButton = { TextButton(feature::dismissConfirmation) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun ArchiveToggle(label: String, checked: Boolean, tag: String, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag).toggleable(checked, role = Role.Checkbox, onValueChange = change), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, onCheckedChange = null); Text(label, Modifier.weight(1f).padding(start = 8.dp))
    }
}
