package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun FilePermissionDialog(feature: FilePermissionFeatureModel) {
    val state by feature.state.collectAsStateWithLifecycle()
    val path = state.path ?: return
    var selectedRule by remember(path) { mutableStateOf<Pair<Boolean, Int>?>(null) }
    if (state.memberPurpose != null) { FilePermissionMembersDialog(feature, state); return }
    val snapshot = (state.snapshot as? Loadable.Ready)?.value
    val editable = !state.busy && !state.submitted && !state.pending && state.relatedPendingPath == null && state.recoveryReadable
    selectedRule?.let { selected ->
        val rule = (if (selected.first) snapshot?.inheritedRules else state.draft.rules)?.getOrNull(selected.second)
        if (rule != null) {
            FilePermissionRuleDialog(rule, editable && !selected.first && snapshot?.canChangePermissions == true,
                { selectedRule = null }, { replacement ->
                    feature.edit { draft -> draft.copy(rules = draft.rules.toMutableList().apply { set(selected.second, replacement) }) }
                    selectedRule = null
                }, {
                    feature.edit { draft -> draft.copy(rules = draft.rules.toMutableList().apply { removeAt(selected.second) }) }
                    selectedRule = null
                })
            return
        }
    }
    ClientSheet(stringResource(R.string.file_permissions_title), feature::close, Modifier.testTag("file_permissions"),
        dismissEnabled = !state.busy, canDismiss = { !feature.state.value.busy }) {
        Text(snapshot?.target?.name ?: path.substringAfterLast('/'), style = MaterialTheme.typography.titleSmall)
        when (val result = state.snapshot) {
            Loadable.Idle, Loadable.Loading -> Box(Modifier.fillMaxWidth().heightIn(min = 180.dp), contentAlignment = androidx.compose.ui.Alignment.Center) { CircularProgressIndicator() }
            is Loadable.Failed -> {
                Text(stringResource(R.string.file_permissions_read_failed), style = MaterialTheme.typography.titleSmall)
                Text(result.error.localize(LocalContext.current).combined)
                Button(feature::reload, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
            }
            is Loadable.Ready -> {
                val current = result.value
                val ownerEditable = editable && (if (current.isACL) current.owner?.canChange == true else current.canChangePermissions)
                if (!current.canChangePermissions && current.owner?.canChange != true) Text(stringResource(R.string.file_permissions_readonly), style = MaterialTheme.typography.bodySmall)
                ClientGroup {
                    ClientRow(stringResource(R.string.file_permissions_owner), Icons.Outlined.Person,
                        state.draft.owner?.name ?: current.owner?.name ?: current.posixOwner ?: stringResource(R.string.file_permissions_unknown_owner),
                        enabled = ownerEditable) { feature.openMembers(FilePermissionMemberPurpose.OWNER) }
                    if (!current.isACL) ClientRow(stringResource(R.string.file_permissions_group), Icons.Outlined.Group,
                        state.draft.group?.name ?: current.posixGroup, enabled = ownerEditable) { feature.openMembers(FilePermissionMemberPurpose.GROUP) }
                }
                if (editable && (state.draft.owner != null || state.draft.group != null)) TextButton({ feature.edit { it.copy(owner = null, group = null) } }) {
                    Text(stringResource(R.string.file_permissions_keep_owner))
                }
                if (current.isACL) {
                    ClientSectionTitle(stringResource(R.string.file_permissions_explicit))
                    if (state.draft.rules.isEmpty()) Text(stringResource(R.string.file_permissions_empty), style = MaterialTheme.typography.bodySmall)
                    state.draft.rules.forEachIndexed { index, rule ->
                        Box(Modifier.testTag("permission_rule_$index")) {
                            ClientRow(permissionOwnerName(rule), Icons.Outlined.Security, stringResource(permissionEffectLabel(rule.effect))) {
                                selectedRule = false to index
                            }
                        }
                    }
                    if (editable && current.canChangePermissions && state.draft.rules.size < 200) OutlinedButton(
                        { feature.openMembers(FilePermissionMemberPurpose.RULE) }, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("permission_add_rule")) {
                        Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.file_permissions_add_rule))
                    }
                    if (current.inheritedRules.isNotEmpty()) {
                        ClientSectionTitle(stringResource(R.string.file_permissions_inherited))
                        current.inheritedRules.forEachIndexed { index, rule ->
                            Box(Modifier.testTag("permission_inherited_$index")) {
                                ClientRow(permissionOwnerName(rule), Icons.Outlined.Security, stringResource(permissionEffectLabel(rule.effect))) { selectedRule = true to index }
                            }
                        }
                    }
                } else FilePermissionModeFields(state.draft.posixMode, editable && current.canChangePermissions) { mode -> feature.edit { it.copy(posixMode = mode) } }
                if (editable && current.target.isDirectory && (current.canChangePermissions || current.owner?.canChange == true)) PermissionToggle(
                    stringResource(R.string.file_permissions_children), state.draft.recursive, true, "permission_recursive") { value -> feature.edit { it.copy(recursive = value) } }
                state.outcome?.let { outcome -> Text(stringResource(when {
                    outcome.partialFailure -> R.string.file_permissions_partial
                    outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS -> R.string.file_permissions_saved
                    outcome.result.status == MutationResultStatus.PERMISSION_DENIED -> R.string.file_permissions_denied
                    else -> R.string.file_permissions_pending
                }), Modifier.testTag("permission_result")) }
                if (state.pending && state.outcome == null) Text(stringResource(R.string.file_permissions_pending))
                state.relatedPendingPath?.let { Text(stringResource(R.string.file_permissions_related, it.substringAfterLast('/'))) }
                state.failure?.let { Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error) }
                if (state.busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(stringResource(R.string.file_permissions_saving)) }
                else if (state.relatedPendingPath != null) Button(feature::openRelatedChange, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("permission_open_related")) {
                    Text(stringResource(R.string.file_permissions_open_related))
                }
                else if (state.pending) Button(feature::refreshResult, Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("permission_refresh_result")) { Text(stringResource(R.string.refresh)) }
                else if (state.submitted || !state.recoveryReadable) Button(feature::reload, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.refresh)) }
                else if (current.canChangePermissions || current.owner?.canChange == true) Button({ feature.submit() },
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("permission_save"), enabled = feature.canSubmit()) { Text(stringResource(R.string.save_changes)) }
            }
        }
    }
    if (state.confirmation) PermissionConfirmation(feature, state)
}

@Composable
private fun PermissionConfirmation(feature: FilePermissionFeatureModel, state: FilePermissionState) {
    val change = feature.change() ?: return
    AlertDialog(onDismissRequest = feature::dismissConfirmation, title = { Text(stringResource(R.string.file_permissions_confirm)) },
        text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(change.baseline.target.name)
            Text(stringResource(R.string.file_permissions_account, state.account))
            Text(stringResource(if (change.recursive) R.string.file_permissions_recursive_consequence else R.string.file_permissions_current_only))
            if (change.owner != null || change.group != null) {
                Text(stringResource(R.string.file_permissions_owner_consequence))
                change.owner?.let { Text(stringResource(R.string.file_permissions_owner_change,
                    change.baseline.owner?.name ?: change.baseline.posixOwner.orEmpty(), it.name)) }
                change.group?.let { Text(stringResource(R.string.file_permissions_group_change, change.baseline.posixGroup.orEmpty(), it.name)) }
            }
            if (change.explicitRules != null || change.posixMode != null) Text(stringResource(R.string.file_permissions_access_consequence))
            change.posixMode?.let { mode ->
                val labels = listOf(R.string.file_permissions_owner, R.string.file_permissions_group, R.string.file_permissions_everyone)
                mode.forEachIndexed { index, value ->
                    val old = change.baseline.posixMode?.getOrNull(index)
                    if (old != null && old != value) Text(stringResource(R.string.file_permissions_mode_change,
                        stringResource(labels[index]), permissionModeSummary(old), permissionModeSummary(value)))
                }
            }
            val old = change.baseline.explicitRules
            change.explicitRules?.let { next ->
                val (removed, added) = changedFilePermissionRules(old, next)
                removed.forEach { rule -> Text(stringResource(R.string.file_permissions_before, permissionRuleSummary(rule))) }
                added.forEach { rule -> Text(stringResource(R.string.file_permissions_after, permissionRuleSummary(rule))) }
            }
        } },
        confirmButton = { TextButton({ feature.submit(true) }, Modifier.testTag("permission_confirm")) { Text(stringResource(R.string.save_changes)) } },
        dismissButton = { TextButton(feature::dismissConfirmation) { Text(stringResource(R.string.cancel)) } })
}
