package io.github.qwertyuiop1995.dsmnativeclient.ui.settings

import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.POST_NOTIFICATIONS_PERMISSION
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.chat.ChatNoticeModel

@Composable
internal fun ChatNoticePreferences(model: ChatNoticeModel) {
    val state by model.state.collectAsState()
    val context = LocalContext.current
    val title = stringResource(R.string.chat_notices_title)
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { model.setEnabled(true) }
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            Switch(state.enabled, onCheckedChange = { enabled ->
                if (enabled && Build.VERSION.SDK_INT >= 33) permission.launch(POST_NOTIFICATIONS_PERMISSION)
                else model.setEnabled(enabled)
            }, enabled = !state.changing, modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).semantics { contentDescription = title })
        }
        Text(stringResource(R.string.chat_notices_limitations), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        val error = state.error ?: R.string.chat_notices_denied.takeIf { state.enabled && !state.allowed }
        if (error != null) {
            Text(stringResource(error), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = {
                if (!state.allowed) context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
                else model.changed()
            }) { Text(stringResource(if (!state.allowed) R.string.chat_notices_settings else R.string.retry)) }
        }
    }
}
