package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.ui.LoadableContent
import kotlinx.coroutines.awaitCancellation

@Composable internal fun ContainerEventsScreen(model: AppViewModel) {
    val state by model.containerEvents.collectAsStateWithLifecycle()
    val owner = LocalLifecycleOwner.current
    LaunchedEffect(model, owner) {
        owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try { model.loadContainerEvents(); awaitCancellation() } finally { model.stopContainerEvents() }
        }
    }
    ContainerEventsContent(state, model::loadContainerEvents)
}

@Composable internal fun ContainerEventsContent(state: Loadable<List<LogEntry>>, onRefresh: () -> Unit) {
    LoadableContent(state, stringResource(R.string.no_log_entries), stringResource(R.string.no_log_entries_description), onRefresh) {
        LogList(it, true, onRefresh)
    }
}
