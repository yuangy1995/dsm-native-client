package io.github.qwertyuiop1995.dsmnativeclient.ui.navigation

import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material.icons.outlined.RemoveCircleOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import kotlinx.coroutines.launch
import kotlin.math.abs

/** 保存前仅修改草稿；所有固定项均可移除，入口恢复依赖始终可达的全部功能。 */
@Composable
internal fun ClientNavigationEditor(initial: PinnedModules, onSave: suspend (PinnedModules) -> Boolean, onDismiss: () -> Unit) {
    var draft by remember { mutableStateOf(initial) }
    var replacement by remember { mutableStateOf<ClientDestination?>(null) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    ClientPageDialog(stringResource(R.string.client_custom_navigation), onDismiss = { if (!saving) onDismiss() }) {
        Column(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("navigation_editor_list"), contentPadding = PaddingValues(20.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item { Text(stringResource(R.string.client_nav_hint), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant) }
                item { ClientSectionTitle(stringResource(R.string.client_pinned), stringResource(R.string.client_pinned_count, draft.items.size)) }
                items(draft.items, key = ClientDestination::id) { destination ->
                    val title = stringResource(destination.title)
                    val up = stringResource(R.string.client_move_up, title)
                    val down = stringResource(R.string.client_move_down, title)
                    var menu by remember { mutableStateOf(false) }
                    var drag by remember { mutableFloatStateOf(0f) }
                    val step = with(androidx.compose.ui.platform.LocalDensity.current) { 56.dp.toPx() }
                    ClientGroup {
                        Row(Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(start = 12.dp)
                            .semantics {
                                customActions = if (saving) emptyList() else listOf(
                                    CustomAccessibilityAction(up) { draft = draft.move(destination, -1); true },
                                    CustomAccessibilityAction(down) { draft = draft.move(destination, 1); true },
                                )
                            }, verticalAlignment = Alignment.CenterVertically) {
                            Icon(destination.icon, null)
                            Text(title, Modifier.weight(1f).padding(start = 12.dp), style = MaterialTheme.typography.bodyLarge)
                            IconButton(onClick = { draft = draft.hide(destination) }, enabled = !saving) {
                                Icon(Icons.Outlined.RemoveCircleOutline, stringResource(R.string.client_hide_destination, title))
                            }
                            Box {
                                IconButton(onClick = { menu = true }, enabled = !saving,
                                    modifier = Modifier.size(48.dp).testTag("reorder_${destination.id}")
                                        .pointerInput(destination, saving) {
                                            if (!saving) detectDragGesturesAfterLongPress(
                                                onDragStart = { drag = 0f }, onDragEnd = { drag = 0f },
                                                onDragCancel = { drag = 0f },
                                            ) { change, amount ->
                                                change.consume()
                                                drag += amount.y
                                                if (abs(drag) >= step) {
                                                    draft = draft.move(destination, if (drag > 0) 1 else -1)
                                                    drag = 0f
                                                }
                                            }
                                        }) {
                                    Icon(Icons.Outlined.DragHandle, stringResource(R.string.client_reorder, title))
                                }
                                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                                    DropdownMenuItem(text = { Text(up) }, enabled = draft.items.first() != destination,
                                        onClick = { draft = draft.move(destination, -1); menu = false })
                                    DropdownMenuItem(text = { Text(down) }, enabled = draft.items.last() != destination,
                                        onClick = { draft = draft.move(destination, 1); menu = false })
                                }
                            }
                        }
                    }
                }
                item { TextButton(onClick = { draft = PinnedModules() }, enabled = !saving, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.client_restore_defaults))
                } }
                item { HorizontalDivider(); ClientSectionTitle(stringResource(R.string.client_other_modules)) }
                items(ClientDestination.pinnable - draft.items.toSet(), key = ClientDestination::id) { destination ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag("pin_candidate_${destination.id}"), verticalAlignment = Alignment.CenterVertically) {
                        Icon(destination.icon, null)
                        Text(stringResource(destination.title), Modifier.weight(1f).padding(start = 12.dp))
                        TextButton(enabled = !saving, onClick = {
                            if (draft.items.size < 5) draft = draft.add(destination) else replacement = destination
                        }) { Text(stringResource(if (draft.items.size < 5) R.string.client_pin else R.string.client_replace)) }
                    }
                }
                item { Text(stringResource(R.string.client_hidden_note), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (failed) item { Text(stringResource(R.string.client_navigation_save_failed), color = MaterialTheme.colorScheme.error) }
            }
            Button(onClick = {
                saving = true
                scope.launch {
                    if (onSave(draft)) onDismiss() else failed = true
                    saving = false
                }
            }, enabled = !saving, modifier = Modifier.fillMaxWidth().padding(20.dp).heightIn(min = 52.dp)) {
                Text(stringResource(if (saving) R.string.processing_action else R.string.save))
            }
        }
    }
    replacement?.let { candidate ->
        var selected by remember(candidate) { mutableIntStateOf(0) }
        ClientSheet(stringResource(R.string.client_replace_title, stringResource(candidate.title)), { replacement = null }) {
            Text(stringResource(R.string.client_replace_hint), style = MaterialTheme.typography.bodySmall)
            draft.items.forEachIndexed { index, destination ->
                Surface(onClick = { selected = index }, selected = selected == index,
                    shape = MaterialTheme.shapes.small,
                    color = if (selected == index) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface) {
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(destination.icon, null)
                        Text(stringResource(destination.title), Modifier.weight(1f).padding(start = 12.dp))
                        RadioButton(selected == index, onClick = null)
                    }
                }
            }
            Button(onClick = { draft = draft.replace(selected, candidate); replacement = null },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("confirm_navigation_replacement")) { Text(stringResource(R.string.client_replace)) }
        }
    }
}
