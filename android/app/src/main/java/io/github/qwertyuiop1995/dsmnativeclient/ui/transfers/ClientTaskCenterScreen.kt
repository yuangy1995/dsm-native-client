package io.github.qwertyuiop1995.dsmnativeclient.ui.transfers

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.WorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.allows
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.ui.WorkspaceAccessNotice
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientModeTabs
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadsScreen

internal enum class ClientTaskSource(val title: Int) {
    PHONE(R.string.client_phone_transfers), DOWNLOADS(R.string.client_nas_downloads), NAS_FILES(R.string.client_nas_file_tasks)
}

@Composable
internal fun ClientTaskCenterScreen(state: WorkspaceState, model: AppViewModel, source: ClientTaskSource, onSource: (ClientTaskSource) -> Unit) {
    LaunchedEffect(source, state.profile.id, state.availability) {
        if (source == ClientTaskSource.NAS_FILES) model.fileBackgroundTaskControls.activate()
        else model.fileBackgroundTaskControls.invalidate()
    }
    io.github.qwertyuiop1995.dsmnativeclient.ui.CrossNasTransferDialog(model.crossNasTransfers)
    val host = io.github.qwertyuiop1995.dsmnativeclient.ui.LocalWorkspaceHost.current
    if (host != null && source == ClientTaskSource.PHONE) {
        GlobalTaskCenterContent(host, state.profile.id, onSource)
        return
    }
    Column(Modifier.fillMaxSize()) {
        ClientModeTabs(ClientTaskSource.entries.map { stringResource(it.title) }, source.ordinal) { onSource(ClientTaskSource.entries[it]) }
        Box(Modifier.weight(1f)) {
            val required = when (source) {
                ClientTaskSource.PHONE -> Module.TRANSFERS
                ClientTaskSource.DOWNLOADS -> Module.DOWNLOADS
                ClientTaskSource.NAS_FILES -> Module.FILES
            }
            if (!state.availability.allows(required)) {
                WorkspaceAccessNotice(state, required, { model.refreshWorkspaceAccess(required) },
                    { model.requestSignIn() }, Modifier.fillMaxSize())
                return@Box
            }
            when (source) {
                ClientTaskSource.PHONE -> AppTransfersContent(state, model)
                ClientTaskSource.DOWNLOADS -> DownloadsScreen(state, model)
                ClientTaskSource.NAS_FILES -> Column(Modifier.fillMaxSize()) {
                    FileBackgroundTaskRecoveryEntry(model.fileBackgroundTaskControls)
                    FileBackgroundTasksContent(
                    tasks = state.fileBackgroundTasks, isLoadingMore = state.fileBackgroundTaskIsLoadingMore,
                    loadMoreFailure = state.fileBackgroundTasksLoadMoreFailure,
                    snapshotObservedAtEpochSeconds = state.fileBackgroundTaskSnapshotObservedAtEpochSeconds,
                    isRefreshing = state.fileBackgroundTaskRefreshInProgress, refreshFailure = state.fileBackgroundTaskRefreshFailure,
                    onRefresh = model::refreshFileBackgroundTasks, onRetry = model::refreshFileBackgroundTasks,
                    onLoadMore = model::loadMoreFileBackgroundTasks,
                    onDetails = model.fileBackgroundTaskControls::open,
                )
                }
            }
        }
    }
    if (source == ClientTaskSource.NAS_FILES) FileBackgroundTaskDialog(model.fileBackgroundTaskControls)
}
