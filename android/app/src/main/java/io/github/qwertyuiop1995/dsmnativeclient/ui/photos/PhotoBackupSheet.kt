package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet

/** 原有设备备份独立于 Photos 图库，不把 Photos 项目编号转换为文件路径。 */
@Composable
internal fun PhotoBackupSheet(state: WorkspaceState, model: AppViewModel, visible: Boolean, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var showPermission by remember { mutableStateOf(false) }
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { showPermission = false }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(50)) { uris ->
        if (uris.isNotEmpty()) {
            model.enqueuePhotoBackups(uris)
            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, POST_NOTIFICATIONS_PERMISSION) != PackageManager.PERMISSION_GRANTED) showPermission = true
        }
    }
    val folder = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { it?.let(model::configurePhotoBackupSource) }
    if (visible) ClientSheet(stringResource(R.string.client_photo_backup), onDismiss) {
        if (state.supportsUploads) {
            Button(onClick = { onDismiss(); picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }) {
                Icon(Icons.Outlined.CloudUpload, null)
                Text(stringResource(R.string.back_up_selected_photos), Modifier.padding(start = 8.dp))
            }
            Text(stringResource(R.string.photo_backup_conditions), style = MaterialTheme.typography.bodySmall)
            if (state.photoBackupSourceEnabled) TextButton(onClick = model::disablePhotoBackupSource) {
                Text(stringResource(R.string.stop_automatic_photo_discovery))
            } else TextButton(onClick = { onDismiss(); folder.launch(null) }) {
                Text(stringResource(R.string.choose_automatic_backup_folder))
            }
        }
    }
    if (showPermission) AlertDialog(
        onDismissRequest = { showPermission = false },
        title = { Text(stringResource(R.string.notification_permission_title)) },
        text = { Text(stringResource(R.string.notification_permission_message)) },
        confirmButton = { TextButton(onClick = { showPermission = false; notifications.launch(POST_NOTIFICATIONS_PERMISSION) }) { Text(stringResource(R.string.allow_notifications)) } },
        dismissButton = { TextButton(onClick = { showPermission = false }) { Text(stringResource(R.string.not_now)) } },
    )
}
