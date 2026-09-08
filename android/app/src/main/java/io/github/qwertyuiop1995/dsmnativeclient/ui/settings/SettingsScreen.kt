package io.github.qwertyuiop1995.dsmnativeclient.ui.settings

import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Tune

import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.os.LocaleListCompat
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import io.github.qwertyuiop1995.dsmnativeclient.ui.icon
import io.github.qwertyuiop1995.dsmnativeclient.ui.titleResource

@Composable
internal fun SettingsScreen(state: WorkspaceState, model: AppViewModel, onCustomizeNavigation: (() -> Unit)? = null) {
    val context = LocalContext.current
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { ClientSectionTitle(stringResource(R.string.client_appearance_preferences)) }
        item {
            ClientGroup {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.language_title), style = MaterialTheme.typography.titleSmall)
                        Text(stringResource(R.string.language_fallback_note), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    LanguageMenu()
                }
                if (onCustomizeNavigation != null) {
                    HorizontalDivider()
                    ClientRow(stringResource(R.string.client_custom_navigation), Icons.Outlined.Tune, onClick = onCustomizeNavigation)
                }
            }
        }
        item {
            ClientGroup {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(stringResource(R.string.regenerable_cache), style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.regenerable_cache_usage, formatBytes(state.regenerableCacheBytes)))
                    Text(stringResource(R.string.regenerable_cache_note), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedButton(onClick = model::clearRegenerableCaches, enabled = state.regenerableCacheBytes > 0) {
                        Text(stringResource(R.string.clear_cache))
                    }
                }
            }
        }
        item { ClientSectionTitle(stringResource(R.string.client_feature_availability)) }
        item {
            ClientGroup {
                state.availability.forEach { item ->
                    ListItem(
                        headlineContent = { Text(stringResource(item.module.titleResource())) },
                        supportingContent = { Text(if (item.isAvailable) stringResource(R.string.available)
                            else item.reason?.localize(context) ?: stringResource(R.string.unavailable)) },
                        leadingContent = { Icon(item.module.icon(), null) },
                        trailingContent = { Icon(if (item.isAvailable) Icons.Outlined.CheckCircle else Icons.Outlined.Info,
                            null, tint = if (item.isAvailable) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) },
                        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                    )
                }
            }
        }
        item { Text(stringResource(R.string.client_saved_password_note), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
internal fun LanguageMenu(modifier: Modifier = Modifier) {
    var expanded by remember { mutableStateOf(false) }
    val currentTags = AppCompatDelegate.getApplicationLocales().toLanguageTags()
    Box(modifier) {
        IconButton(onClick = { expanded = true }) {
            Icon(
                Icons.Outlined.Language,
                contentDescription = stringResource(R.string.language_title),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            LanguageMenuItem(
                title = stringResource(R.string.language_follow_system),
                selected = currentTags.isEmpty(),
            ) {
                AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())
                expanded = false
            }
            LanguageMenuItem(
                title = stringResource(R.string.language_english),
                selected = currentTags.startsWith("en"),
            ) {
                AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags("en"))
                expanded = false
            }
            LanguageMenuItem(
                title = stringResource(R.string.language_simplified_chinese),
                selected = currentTags.startsWith("zh"),
            ) {
                AppCompatDelegate.setApplicationLocales(LocaleListCompat.forLanguageTags("zh-CN"))
                expanded = false
            }
        }
    }
}

@Composable
private fun LanguageMenuItem(
    title: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    DropdownMenuItem(
        text = { Text(title) },
        leadingIcon = {
            if (selected) {
                Icon(Icons.Outlined.CheckCircle, contentDescription = null)
            }
        },
        onClick = onClick,
    )
}
