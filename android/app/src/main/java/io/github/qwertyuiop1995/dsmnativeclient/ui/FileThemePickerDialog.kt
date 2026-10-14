package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FileThemePickerDialog(feature: FileThemePickerFeatureModel, state: FileThemePickerState) {
    val context = LocalContext.current
    var ticket by rememberSaveable { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        val selectedTicket = ticket; ticket = null
        if (uri != null && selectedTicket != null) feature.importLocal(context, uri, selectedTicket)
    }
    val localChoose = {
        ticket = feature.selectionTicket(); if (ticket != null) launcher.launch("image/*")
    }
    ClientPageDialog(stringResource(if (state.kind == FileThemeImageKind.LOGO) R.string.file_theme_choose_logo else R.string.file_theme_choose_background), feature::back) {
        Column(Modifier.fillMaxSize().testTag("theme_image_picker")) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FileSettingsChoice(stringResource(R.string.file_theme_source), state.source,
                    FileThemePickerSource.entries.filter { it != FileThemePickerSource.DEFAULT || state.kind == FileThemeImageKind.BACKGROUND },
                    { stringResource(it.label()) }, feature::source, !state.busy, "theme_image_source")
                if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            if (state.preview !is Loadable.Idle || state.source == FileThemePickerSource.LOCAL) {
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    state.selected?.let { Text(themeImageName(it), style = MaterialTheme.typography.titleMedium) }
                    state.local?.let { Text(it.filename, style = MaterialTheme.typography.titleMedium) }
                    when (val preview = state.preview) {
                        is Loadable.Ready -> Image(preview.value.asImageBitmap(), stringResource(R.string.file_theme_image_preview),
                            Modifier.fillMaxWidth().heightIn(min = 180.dp, max = 320.dp).testTag("theme_image_preview"), contentScale = ContentScale.Fit)
                        is Loadable.Loading -> Box(Modifier.fillMaxWidth().height(180.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                        is Loadable.Failed -> {
                            Text(if (state.source == FileThemePickerSource.LOCAL) stringResource(R.string.file_theme_image_failed) else preview.error.localize(context).combined,
                                color = MaterialTheme.colorScheme.error)
                            if (state.source != FileThemePickerSource.LOCAL) OutlinedButton(feature::retryPreview, Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
                        }
                        else -> Unit
                    }
                    state.failure?.let { Text(it.localize(context).combined, color = MaterialTheme.colorScheme.error) }
                    if (state.unknownUpload) {
                        Text(stringResource(R.string.file_theme_upload_unknown), Modifier.testTag("theme_upload_unknown"))
                        OutlinedButton({ feature.source(FileThemePickerSource.HISTORY) }, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) {
                            Text(stringResource(R.string.file_theme_history))
                        }
                    }
                    if (state.source == FileThemePickerSource.LOCAL) {
                        Text(stringResource(R.string.file_theme_supported))
                        OutlinedButton(localChoose, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("theme_choose_local"), enabled = !state.busy) {
                            Text(stringResource(R.string.file_theme_choose_local))
                        }
                        if (state.local != null) {
                            Text(stringResource(R.string.file_theme_upload_hint))
                            Button(feature::upload, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("theme_upload"), feature.canUpload()) { Text(stringResource(R.string.file_theme_upload_choose)) }
                        }
                    } else Button(feature::choose, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("theme_use_image"), feature.canChoose()) { Text(stringResource(R.string.file_theme_use_image)) }
                }
            } else {
                if (state.source == FileThemePickerSource.NAS) Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()).testTag("theme_image_path")) {
                        TextButton({ feature.location("") }, Modifier.heightIn(min = 48.dp), enabled = state.path.isNotEmpty()) { Text(stringResource(R.string.shared_folders)) }
                        val segments = state.path.split('/').filter(String::isNotEmpty)
                        segments.forEachIndexed { index, segment ->
                            TextButton({ feature.location("/" + segments.take(index + 1).joinToString("/")) }, Modifier.heightIn(min = 48.dp), enabled = index < segments.lastIndex) { Text(segment) }
                        }
                    }
                    TextButton(feature::reload, Modifier.heightIn(min = 48.dp), enabled = state.rows !is Loadable.Loading) { Text(stringResource(R.string.refresh)) }
                }
                ClientSearchField(state.filter, feature::filter, stringResource(R.string.file_theme_filter), Modifier.padding(12.dp).testTag("theme_image_filter"))
                val rows = (state.rows as? Loadable.Ready)?.value.orEmpty().filter {
                    (it.image?.let { image -> themeImageName(image, context) } ?: it.name).contains(state.filter, true)
                }
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    PageStateContent(state.rows.toPageUiState(isEmpty = { it.isEmpty() }, isFilteredEmpty = { it.isNotEmpty() && rows.isEmpty() }),
                        emptyTitle = stringResource(R.string.file_theme_empty), emptyMessage = stringResource(R.string.file_theme_empty_hint), emptyIcon = Icons.Outlined.Image,
                        filteredEmptyTitle = stringResource(R.string.no_items_match_filter), filteredEmptyMessage = stringResource(R.string.change_file_filter_hint), filteredEmptyIcon = Icons.Outlined.Image,
                        onRetry = feature::reload) {
                        LazyColumn(Modifier.fillMaxSize().testTag("theme_image_list"), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(rows, key = FileThemePickerEntry::id) { row -> ClientGroup {
                                ClientRow(row.image?.let { themeImageName(it) } ?: row.name, if (row.folder != null) Icons.Outlined.Folder else Icons.Outlined.Image,
                                    enabled = row.folder?.canRead != false, onClick = { feature.enter(row) })
                            } }
                        }
                    }
                }
                state.failure?.let { Text(it.localize(context).combined, Modifier.padding(12.dp), color = MaterialTheme.colorScheme.error) }
                FlowRow(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (state.source != FileThemePickerSource.NAS) OutlinedButton(feature::reload, Modifier.heightIn(min = 48.dp), enabled = state.rows !is Loadable.Loading) { Text(stringResource(R.string.refresh)) }
                    if (state.nextOffset < state.total) OutlinedButton(feature::more, Modifier.heightIn(min = 48.dp).testTag("theme_more"), enabled = !state.loadingMore) { Text(stringResource(R.string.file_settings_more)) }
                }
                if (state.loadingMore) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
    }
}
@Composable
internal fun themeImageName(image: FileThemeImage) = themeImageName(image, LocalContext.current)
internal fun themeImageName(image: FileThemeImage, context: android.content.Context) = if (image.source == FileThemeImageSource.DEFAULT)
    context.getString(R.string.file_theme_default_name, FileThemeImage.defaults.indexOfFirst { it.path == image.path } + 1) else image.name

internal fun FileThemePickerSource.label() = when (this) {
    FileThemePickerSource.HISTORY -> R.string.file_theme_history; FileThemePickerSource.NAS -> R.string.file_theme_nas
    FileThemePickerSource.DEFAULT -> R.string.file_theme_defaults; FileThemePickerSource.LOCAL -> R.string.file_theme_local
}
