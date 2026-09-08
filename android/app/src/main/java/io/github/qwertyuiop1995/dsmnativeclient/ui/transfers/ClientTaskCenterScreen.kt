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
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientModeTabs
import io.github.qwertyuiop1995.dsmnativeclient.ui.downloads.DownloadsScreen

internal enum class ClientTaskSource(val title: Int) {
    PHONE(R.string.client_phone_transfers), DOWNLOADS(R.string.client_nas_downloads), NAS_FILES(R.string.client_nas_file_tasks)
}

@Composable
internal fun ClientTaskCenterScreen(state: WorkspaceState, model: AppViewModel, source: ClientTaskSource, onSource: (ClientTaskSource) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        ClientModeTabs(ClientTaskSource.entries.map { stringResource(it.title) }, source.ordinal) { onSource(ClientTaskSource.entries[it]) }
        Box(Modifier.weight(1f)) {
            when (source) {
                ClientTaskSource.PHONE -> AppTransfersContent(state, model)
                ClientTaskSource.DOWNLOADS -> DownloadsScreen(state, model)
                ClientTaskSource.NAS_FILES -> FileBackgroundTasksContent(
                    tasks = state.fileBackgroundTasks, isLoadingMore = state.fileBackgroundTaskIsLoadingMore,
                    loadMoreFailure = state.fileBackgroundTasksLoadMoreFailure,
                    snapshotObservedAtEpochSeconds = state.fileBackgroundTaskSnapshotObservedAtEpochSeconds,
                    isRefreshing = state.fileBackgroundTaskRefreshInProgress, refreshFailure = state.fileBackgroundTaskRefreshFailure,
                    onRefresh = model::refreshFileBackgroundTasks, onRetry = model::refreshFileBackgroundTasks,
                    onLoadMore = model::loadMoreFileBackgroundTasks,
                )
            }
        }
    }
}
