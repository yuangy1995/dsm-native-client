package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.text.format.Formatter
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*

@Composable
internal fun GlobalSettings(value: SynologyPhotoGlobalSettings, state: SynologyPhotoSettingsState, model: SynologyPhotoSettingsModel) {
    if (value.values.isEmpty() && value.excludedExtensions == null) Text(stringResource(R.string.sp_global_empty))
    SynologyPhotoGlobalSetting.entries.filter { it in value.values }.forEach { key ->
        SettingsSwitch(stringResource(key.globalLabel()), value.values[key] == true, state.canEdit && key in value.editable, "photos_global_${key.name}") {
            model.edit(value.copy(values = value.values + (key to it)))
        }
        if (key == SynologyPhotoGlobalSetting.ORIGINAL_JPEG && value.hasHEVC != true)
            Text(stringResource(R.string.sp_global_codec_required), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    value.excludedExtensions?.let { selected ->
        var expanded by rememberSaveable { mutableStateOf(false) }
        OutlinedButton(onClick = { expanded = !expanded }, modifier = Modifier.testTag("photos_global_formats")) {
            Text(stringResource(if (expanded) R.string.sp_global_formats_hide else R.string.sp_global_formats_show, selected.size))
        }
        if (expanded) {
            val original = state.original as SynologyPhotoGlobalSettings
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                (SynologyPhotoGlobalSettings.supportedExtensions + original.excludedExtensions.orEmpty()).sorted().forEach { extension ->
                    FilterChip(selected = extension in selected, enabled = state.canEdit,
                        onClick = { model.edit(value.copy(excludedExtensions = if (extension in selected) selected - extension else selected + extension)) },
                        label = { Text(extension) }, modifier = Modifier.heightIn(min = 48.dp).testTag("photos_global_format_$extension"))
                }
            }
        }
    }
    if (model.available(SynologyPhotoSettingsKind.CACHE)) { HorizontalDivider(); ConversionCache(state, model) }
}

@Composable
internal fun ConversionCache(state: SynologyPhotoSettingsState, model: SynologyPhotoSettingsModel) {
    Text(stringResource(R.string.sp_global_cache), style = MaterialTheme.typography.titleMedium)
    if (state.cacheLoading) LinearProgressIndicator(Modifier.fillMaxWidth().testTag("photos_cache_loading"))
    state.cache?.let { cache ->
        Text(Formatter.formatFileSize(LocalContext.current, cache.sizeBytes), Modifier.testTag("photos_cache_size"))
        if (cache.clearing) Text(stringResource(R.string.sp_global_clearing), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (state.cacheError != null) Text(stringResource(R.string.sp_global_cache_failed), color = MaterialTheme.colorScheme.error)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { model.refreshCache() }, enabled = !state.cacheLoading && !state.working && state.confirmation == null, modifier = Modifier.testTag("photos_cache_refresh")) {
            Text(stringResource(R.string.refresh))
        }
        OutlinedButton(onClick = model::clearCache, enabled = state.cache?.canClear == true && !state.cacheLoading && !state.working && state.confirmation == null,
            modifier = Modifier.testTag("photos_cache_clear")) { Text(stringResource(R.string.sp_global_clear_cache)) }
    }
}

@Composable
internal fun GlobalSettingsConfirmation(value: SynologyPhotoSettingsCheckpoint) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (value.original is SynologyPhotoConversionCache) Text(stringResource(R.string.sp_global_clear_risk))
        else {
            val before = value.original as SynologyPhotoGlobalSettings; val after = value.desired as SynologyPhotoGlobalSettings
            Text(stringResource(R.string.sp_global_save_risk))
            if (before.personalRecognition != after.personalRecognition || before.sharedRecognition != after.sharedRecognition ||
                listOf(SynologyPhotoGlobalSetting.PEOPLE, SynologyPhotoGlobalSetting.SUBJECTS, SynologyPhotoGlobalSetting.SIMILAR).any { before.values[it] == true && after.values[it] == false })
                Text(stringResource(R.string.sp_global_recognition_risk))
            if (before.values[SynologyPhotoGlobalSetting.USER_SHARING] == true && after.values[SynologyPhotoGlobalSetting.USER_SHARING] == false)
                Text(stringResource(R.string.sp_global_sharing_risk))
            if (before.values[SynologyPhotoGlobalSetting.GUEST_INFO] == false && after.values[SynologyPhotoGlobalSetting.GUEST_INFO] == true)
                Text(stringResource(R.string.sp_global_guest_risk))
            if (before.excludedExtensions != after.excludedExtensions) Text(stringResource(R.string.sp_global_formats_risk))
            if (before.values[SynologyPhotoGlobalSetting.ORIGINAL_JPEG] == true && after.values[SynologyPhotoGlobalSetting.ORIGINAL_JPEG] == false)
                Text(stringResource(R.string.sp_global_clear_risk))
        }
    }
}

private fun SynologyPhotoGlobalSetting.globalLabel(): Int = when (this) {
    SynologyPhotoGlobalSetting.PEOPLE -> R.string.sp_settings_people
    SynologyPhotoGlobalSetting.SUBJECTS -> R.string.sp_settings_subjects
    SynologyPhotoGlobalSetting.SIMILAR -> R.string.sp_settings_similar
    SynologyPhotoGlobalSetting.USER_SHARING -> R.string.sp_global_user_sharing
    SynologyPhotoGlobalSetting.GUEST_INFO -> R.string.sp_global_guest_info
    SynologyPhotoGlobalSetting.ORIGINAL_JPEG -> R.string.sp_global_original_jpeg
}
