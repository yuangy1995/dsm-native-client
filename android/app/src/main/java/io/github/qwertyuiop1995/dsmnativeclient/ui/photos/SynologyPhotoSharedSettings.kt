package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

@Composable
internal fun SharedSettings(value: SynologyPhotoSharedSettings, enabled: Boolean, change: (SynologyPhotoSettings) -> Unit, toggle: () -> Unit) {
    Text(stringResource(if (value.enabled) R.string.sp_shared_settings_on else R.string.sp_shared_settings_off), style = MaterialTheme.typography.titleMedium)
    OutlinedButton(onClick = toggle, enabled = enabled && value.canToggle, modifier = Modifier.testTag("photos_shared_toggle")) {
        Text(stringResource(if (value.enabled) R.string.sp_shared_settings_disable else R.string.sp_shared_settings_enable))
    }
    if (value.enabled && !value.personalEnabled) Text(stringResource(R.string.sp_shared_settings_last), color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (!value.enabled && value.disabledBySharedFolder == true) Text(stringResource(R.string.sp_shared_settings_folder_disabled), color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (value.enabled) {
        if (value.values.isEmpty()) Text(stringResource(R.string.sp_shared_settings_empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
        SynologyPhotoSharedSetting.entries.filter { it in value.values }.forEach { key ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SettingsSwitch(stringResource(when (key) {
                    SynologyPhotoSharedSetting.PEOPLE -> R.string.sp_settings_people
                    SynologyPhotoSharedSetting.SUBJECTS -> R.string.sp_settings_subjects
                    SynologyPhotoSharedSetting.SIMILAR -> R.string.sp_settings_similar
                    SynologyPhotoSharedSetting.PUBLIC_ROOT -> R.string.sp_shared_settings_public
                }), value.values[key] == true, enabled && key in value.editable, "photos_shared_${key.name}") {
                    change(value.copy(values = value.values + (key to it)))
                }
                if (key != SynologyPhotoSharedSetting.PUBLIC_ROOT && key !in value.editable)
                    Text(stringResource(R.string.sp_shared_settings_global_disabled), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

internal fun SynologyPhotoSettingsCheckpoint.settingsConfirmation(): Int {
    val before = original as? SynologyPhotoSharedSettings ?: return R.string.sp_settings_overwrite_risk
    val after = desired as SynologyPhotoSharedSettings
    return when {
        before.enabled != after.enabled -> if (after.enabled) R.string.sp_shared_settings_enable_risk else R.string.sp_shared_settings_disable_risk
        after.values[SynologyPhotoSharedSetting.PUBLIC_ROOT] == true -> R.string.sp_shared_settings_public_risk
        else -> R.string.sp_shared_settings_private_risk
    }
}
