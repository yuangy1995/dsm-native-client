package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAccessState
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.localization.messageResource

@Composable
internal fun WorkspaceAccessNotice(state: WorkspaceState, module: Module,
    onRefresh: () -> Unit, onSignIn: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    val entry = state.availability.firstOrNull { it.module == module }
    val text = state.access.failure?.localize(LocalContext.current)?.combined
        ?: stringResource(entry?.reason?.messageResource() ?: R.string.module_access_unread)
    Column(modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)) {
        Icon(Icons.Outlined.Lock, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(stringResource(module.titleResource()), style = MaterialTheme.typography.titleMedium)
        Text(text, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
        if ((entry?.access == ModuleAccessState.AUTHENTICATION_REQUIRED ||
                state.access.failure?.kind == io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.WORKSPACE_CHANGED) && onSignIn != null) {
            Button(onClick = onSignIn) { Text(stringResource(R.string.workspace_sign_in_again)) }
        } else {
            Button(onClick = onRefresh, enabled = !state.access.refreshing) { Text(stringResource(R.string.refresh)) }
        }
    }
}
