package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.ui.platform.LocalResources
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.POST_NOTIFICATIONS_PERMISSION
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem

internal class FileDownloadLauncher(private val launch: (List<FileItem>, io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource?) -> Unit) {
    operator fun invoke(items: List<FileItem>) = launch(items, null)
    fun remote(source: io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource) = launch(listOf(source.item()), source)
}

/** 系统保存位置选择器的单一入口；请求重建与通知授权沿用文件页原有流程。 */
@Composable
internal fun rememberFileDownloadLauncher(state: WorkspaceState, model: AppViewModel): FileDownloadLauncher {
    val context = LocalContext.current
    val resources = LocalResources.current
    var pendingDownload by rememberSaveable(
        state.profile.id,
        stateSaver = PendingDownloadRequestStateSaver,
    ) { mutableStateOf(PendingDownloadRequestState()) }
    var showNotificationPermission by remember { mutableStateOf(false) }

    fun handleDownloadDestination(uri: android.net.Uri?) {
        val resolution = resolveDownloadDestination(
            pending = pendingDownload,
            activeOwner = model.workspaceOwner,
            destinationSelected = uri != null,
        )
        pendingDownload = resolution.nextPending
        when (resolution.decision) {
            DownloadDestinationDecision.CANCELLED -> Unit
            DownloadDestinationDecision.DISCARD_ORPHAN -> {
                if (uri != null) model.discardUnmatchedDownloadDestination(uri)
            }
            DownloadDestinationDecision.ENQUEUE -> {
                if (uri == null) return
                val request = resolution.request ?: run {
                    model.discardUnmatchedDownloadDestination(uri)
                    return
                }
                val enqueueResult = model.enqueueDownload(request, uri)
                val permissionGranted = ContextCompat.checkSelfPermission(
                    context,
                    POST_NOTIFICATIONS_PERMISSION,
                ) == PackageManager.PERMISSION_GRANTED
                if (shouldRequestDownloadNotificationPermission(
                        enqueueResult = enqueueResult,
                        sdkInt = Build.VERSION.SDK_INT,
                        notificationPermissionGranted = permissionGranted,
                    )
                ) {
                    showNotificationPermission = true
                }
            }
        }
    }

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { showNotificationPermission = false }
    val fileDownloadLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/octet-stream"),
        onResult = ::handleDownloadDestination,
    )
    val folderDownloadLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip"),
        onResult = ::handleDownloadDestination,
    )
    fun downloadSelection(items: List<FileItem>, source: io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource?) {
        val owner = model.workspaceOwner ?: return
        if (items.isEmpty() || items.any { !it.canRead } || pendingDownload.request != null) return
        if (source != null && (source.profile.owner != owner || items.size != 1 || !source.matches(items.single()))) return
        val archive = items.size > 1 || items.single().isDirectory
        val title = if (items.size > 1) resources.getString(R.string.download_selected_zip_name)
            else if (archive) "${items.single().name}.zip" else items.single().name
        pendingDownload = PendingDownloadRequestState(if (source == null) pendingDownloadRequest(owner, items, title)
            else PendingDownloadRequest(owner, items, title, source))
        if (archive) folderDownloadLauncher.launch(title) else fileDownloadLauncher.launch(title)
    }

    if (showNotificationPermission) {
        AlertDialog(
            onDismissRequest = { showNotificationPermission = false },
            title = { Text(stringResource(R.string.notification_permission_title)) },
            text = { Text(stringResource(R.string.notification_permission_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showNotificationPermission = false
                        notificationPermissionLauncher.launch(POST_NOTIFICATIONS_PERMISSION)
                    },
                ) {
                    Text(stringResource(R.string.allow_notifications))
                }
            },
            dismissButton = {
                TextButton(onClick = { showNotificationPermission = false }) {
                    Text(stringResource(R.string.not_now))
                }
            },
        )
    }
    return FileDownloadLauncher(::downloadSelection)
}
