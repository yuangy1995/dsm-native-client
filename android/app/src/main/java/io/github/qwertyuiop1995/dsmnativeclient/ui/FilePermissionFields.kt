package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FilePermissionRuleDialog(rule: FileACLRule, editable: Boolean, close: () -> Unit, save: (FileACLRule) -> Unit, remove: () -> Unit) {
    var draft by remember(rule) { mutableStateOf(rule) }
    ClientPageDialog(permissionOwnerName(rule), close) {
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!editable) Text(stringResource(if (rule.level > 0) R.string.file_permissions_inherited_readonly else R.string.file_permissions_readonly))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FileACLEffect.entries.forEach { effect -> FilterChip(draft.effect == effect, { draft = draft.copy(effect = effect) },
                        enabled = editable, label = { Text(stringResource(permissionEffectLabel(effect))) }) }
                }
                ClientSectionTitle(stringResource(R.string.file_permissions_actions))
                FileACLRight.entries.forEach { right -> PermissionToggle(stringResource(permissionRightLabel(right)), right in draft.rights,
                    editable, "permission_right_${right.key}") { enabled -> draft = draft.copy(rights = if (enabled) draft.rights + right else draft.rights - right) } }
                ClientSectionTitle(stringResource(R.string.file_permissions_applies_to))
                FileACLInheritance.entries.forEach { scope -> PermissionToggle(stringResource(permissionInheritanceLabel(scope)), scope in draft.inheritance,
                    editable, "permission_scope_${scope.key}") { enabled -> draft = draft.copy(inheritance = if (enabled) draft.inheritance + scope else draft.inheritance - scope) } }
                if (editable) TextButton(remove, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("permission_remove_rule")) {
                    Text(stringResource(R.string.file_permissions_remove_rule), color = MaterialTheme.colorScheme.error)
                }
            }
            Button({ if (editable) save(draft) else close() }, Modifier.fillMaxWidth().padding(16.dp).heightIn(min = 48.dp).testTag("permission_rule_done")) { Text(stringResource(R.string.done)) }
        }
    }
}

@Composable
internal fun PermissionToggle(label: String, checked: Boolean, enabled: Boolean, tag: String, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(tag).toggleable(checked, enabled = enabled, role = Role.Checkbox, onValueChange = change)
        .padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, onCheckedChange = null, enabled = enabled)
        Text(label, Modifier.weight(1f).padding(start = 8.dp), color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun FilePermissionModeFields(mode: String, enabled: Boolean, change: (String) -> Unit) {
    if (!validFilePermissionMode(mode)) return
    listOf(R.string.file_permissions_owner, R.string.file_permissions_group, R.string.file_permissions_everyone).forEachIndexed { index, label ->
        ClientSectionTitle(stringResource(label))
        listOf(4 to R.string.file_permissions_read, 2 to R.string.file_permissions_write, 1 to R.string.file_permissions_execute).forEach { (bit, resource) ->
            val value = mode[index].digitToInt()
            PermissionToggle(stringResource(resource), value and bit != 0, enabled, "permission_mode_${index}_$bit") { selected ->
                val next = if (selected) value or bit else value and bit.inv()
                change(mode.toCharArray().apply { this[index] = next.digitToChar() }.concatToString())
            }
        }
    }
}

@Composable internal fun permissionOwnerName(rule: FileACLRule) = rule.ownerName.ifBlank { stringResource(R.string.file_permissions_unknown_owner) }
@Composable internal fun permissionModeSummary(value: Char): String = listOf(4 to R.string.file_permissions_read,
    2 to R.string.file_permissions_write, 1 to R.string.file_permissions_execute).filter { value.digitToInt() and it.first != 0 }
    .map { stringResource(it.second) }.joinToString(stringResource(R.string.file_permissions_separator))
    .ifBlank { stringResource(R.string.file_permissions_no_actions) }
@Composable internal fun permissionRuleSummary(rule: FileACLRule): String {
    val separator = stringResource(R.string.file_permissions_separator)
    val rights = FileACLRight.entries.filter { it in rule.rights }.map { stringResource(permissionRightLabel(it)) }
        .joinToString(separator).ifBlank { stringResource(R.string.file_permissions_no_actions) }
    val scope = FileACLInheritance.entries.filter { it in rule.inheritance }.map { stringResource(permissionInheritanceLabel(it)) }
        .joinToString(separator).ifBlank { stringResource(R.string.file_permissions_no_scope) }
    return stringResource(R.string.file_permissions_rule_summary, permissionOwnerName(rule), stringResource(permissionEffectLabel(rule.effect)), rights, scope)
}
internal fun permissionEffectLabel(effect: FileACLEffect) = if (effect == FileACLEffect.ALLOW) R.string.file_permissions_allow else R.string.file_permissions_deny
internal fun permissionInheritanceLabel(scope: FileACLInheritance) = when (scope) {
    FileACLInheritance.CHILD_FILES -> R.string.file_permissions_child_files
    FileACLInheritance.CHILD_FOLDERS -> R.string.file_permissions_child_folders
    FileACLInheritance.THIS_FOLDER -> R.string.file_permissions_this_item
    FileACLInheritance.ALL_DESCENDANTS -> R.string.file_permissions_all_descendants
}
internal fun permissionRightLabel(right: FileACLRight) = when (right) {
    FileACLRight.READ_DATA -> R.string.file_permissions_read
    FileACLRight.WRITE_DATA -> R.string.file_permissions_write
    FileACLRight.EXECUTE -> R.string.file_permissions_execute
    FileACLRight.APPEND -> R.string.file_permissions_append
    FileACLRight.DELETE -> R.string.file_permissions_delete
    FileACLRight.DELETE_CHILDREN -> R.string.file_permissions_delete_children
    FileACLRight.READ_ATTRIBUTES -> R.string.file_permissions_read_attributes
    FileACLRight.WRITE_ATTRIBUTES -> R.string.file_permissions_write_attributes
    FileACLRight.READ_EXTENDED_ATTRIBUTES -> R.string.file_permissions_read_extended
    FileACLRight.WRITE_EXTENDED_ATTRIBUTES -> R.string.file_permissions_write_extended
    FileACLRight.READ_PERMISSIONS -> R.string.file_permissions_read_permissions
    FileACLRight.CHANGE_PERMISSIONS -> R.string.file_permissions_change_permissions
    FileACLRight.TAKE_OWNERSHIP -> R.string.file_permissions_take_ownership
}
