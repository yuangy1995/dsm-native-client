package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R

@Composable
internal fun VirtualMachineTaskCleanupConfirmationDialog(
    taskCount: Int,
    onConfirm: () -> Boolean,
    onDismiss: () -> Boolean,
) {
    AlertDialog(
        onDismissRequest = { onDismiss() },
        title = { Text(stringResource(R.string.virtual_machine_clear_finished_tasks_title)) },
        text = {
            Text(
                pluralStringResource(
                    R.plurals.virtual_machine_clear_finished_tasks_message,
                    taskCount,
                    taskCount,
                ),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm() },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.virtual_machine_clear_finished_tasks)) }
        },
        dismissButton = {
            TextButton(
                onClick = { onDismiss() },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.cancel)) }
        },
    )
}
