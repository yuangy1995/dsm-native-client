package io.github.qwertyuiop1995.dsmnativeclient.ui.home

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet
import kotlinx.coroutines.launch

/** 手机沿用底部面板，平板使用紧凑对话框；保存成功前不改变工作区偏好。 */
@Composable
internal fun ClientHomeEditor(
    initial: HomeLayout,
    onSave: suspend (HomeLayout) -> Boolean,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf(initial) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val dismiss = { if (!saving) onDismiss() }
    val title = stringResource(R.string.client_customize_home)
    val content: @Composable ColumnScope.() -> Unit = {
        HomeSection.entries.forEach { section ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 56.dp)
                    .toggleable(value = draft.isVisible(section), enabled = !saving, role = Role.Switch) {
                        draft = draft.withVisibility(section, it)
                        failed = false
                    }
                    .testTag("home_section_toggle_${section.id}")
                    .padding(horizontal = 4.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(stringResource(section.title), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                Switch(checked = draft.isVisible(section), onCheckedChange = null, enabled = !saving)
            }
        }
        TextButton(onClick = { draft = HomeLayout(); failed = false }, enabled = !saving) {
            Text(stringResource(R.string.client_restore_defaults))
        }
        if (failed) {
            Text(
                stringResource(R.string.client_home_save_failed),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        Button(
            onClick = {
                if (!saving) {
                    saving = true
                    scope.launch {
                        try {
                            if (onSave(draft)) onDismiss() else failed = true
                        } finally {
                            saving = false
                        }
                    }
                }
            },
            enabled = !saving,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("home_editor_save"),
        ) {
            Text(stringResource(R.string.save))
        }
    }
    if (LocalConfiguration.current.screenWidthDp < 600) {
        ClientSheet(title, onDismiss = dismiss, content = content)
    } else {
        Dialog(onDismissRequest = dismiss) {
            Surface(shape = MaterialTheme.shapes.extraLarge, color = MaterialTheme.colorScheme.surface) {
                Column(
                    Modifier.widthIn(max = 480.dp).fillMaxWidth()
                        .verticalScroll(rememberScrollState()).padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                        IconButton(onClick = dismiss, enabled = !saving) {
                            Icon(Icons.Outlined.Close, stringResource(R.string.close))
                        }
                    }
                    content()
                }
            }
        }
    }
}
