package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CloudUpload
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.time.format.DateTimeFormatter

/** 手机使用触控标签和全屏预览，大屏保留自适应网格和可并排的详情。 */
@Composable
internal fun SynologyPhotosLibrary(model: SynologyPhotosModel, canBackup: Boolean, onBackup: () -> Unit) {
    val state by model.state.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val context = LocalContext.current
    var search by rememberSaveable(model.profileId) { mutableStateOf("") }
    var filters by remember { mutableStateOf(false) }
    var months by remember { mutableStateOf(false) }
    DisposableEffect(model, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> model.activate()
                Lifecycle.Event.ON_STOP -> model.deactivate(preservePreparedExport = true)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) model.activate()
        onDispose { lifecycle.removeObserver(observer); model.deactivate(preservePreparedExport = context.photoActivity()?.isChangingConfigurations == true) }
    }
    LaunchedEffect(state.navigation.keyword) { search = state.navigation.keyword }
    BackHandler(state.navigation.canGoBack && !filters && !months) { model.goBack() }
    Column(Modifier.fillMaxSize()) {
        ClientToolbar(
            title = state.navigation.categoryItem?.name ?: state.navigation.album?.name ?: state.navigation.folders.lastOrNull()?.name
                ?: stringResource(state.navigation.category?.label() ?: state.navigation.section.label()),
            onBack = if (state.navigation.canGoBack) ({ model.goBack(); Unit }) else null,
        ) {
            if (canBackup) IconButton(onClick = onBackup) { Icon(Icons.Outlined.CloudUpload, stringResource(R.string.client_photo_backup)) }
            IconButton(onClick = { model.refresh() }, enabled = !state.loading) { Icon(Icons.Outlined.Refresh, stringResource(R.string.sp_library_refresh)) }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(SynologyPhotosSection.entries, key = { it.name }) { section ->
                FilterChip(state.navigation.section == section, onClick = { model.selectSection(section) }, label = { Text(stringResource(section.label())) })
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            ClientSearchField(search, { search = it }, stringResource(R.string.sp_library_search), Modifier.weight(1f), onSearch = { model.search(search) })
            IconButton(onClick = { filters = true; model.loadFilterOptions() }) { Icon(Icons.Outlined.FilterList, stringResource(R.string.sp_filters)) }
            if (state.months.isNotEmpty()) IconButton(onClick = { months = true }) { Icon(Icons.Outlined.CalendarMonth, stringResource(R.string.sp_timeline_navigator)) }
        }
        if (state.navigation.filter.isActive) TextButton(onClick = { model.applyFilter(SynologyPhotoFilter()) }, modifier = Modifier.padding(horizontal = 12.dp)) {
            Text(stringResource(R.string.sp_filters_clear))
        }
        if (state.navigation.section == SynologyPhotosSection.SHARING && state.navigation.album == null) {
            LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(SynologyPhotoShareScope.entries) { scope ->
                    FilterChip(state.navigation.shareScope == scope, { model.selectShareScope(scope) }, label = { Text(stringResource(scope.label())) })
                }
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                state.loading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                state.empty && state.error != null -> PhotoErrorPanel(state.error!!, onRetry = { model.refresh() }, Modifier.align(Alignment.Center))
                else -> SynologyPhotosGrid(state, model)
            }
        }
    }
    if (filters) SynologyPhotoFilters(state, onRetry = { model.loadFilterOptions() }, onDismiss = { filters = false }) { filter ->
        filters = false; model.applyFilter(filter)
    }
    if (months) ClientPageDialog(stringResource(R.string.sp_timeline_navigator), { months = false }) {
        val locale = LocalConfiguration.current.locales[0]
        val format = remember(locale) { DateTimeFormatter.ofPattern("LLLL yyyy", locale) }
        LazyColumn(Modifier.fillMaxSize()) {
            items(state.months, key = { it.toString() }) { month ->
                ListItem(headlineContent = { Text(month.format(format)) }, modifier = Modifier.clickable {
                    months = false; model.jumpToMonth(month)
                })
            }
        }
    }
    SynologyPhotoPreview(model)
    SynologyPhotoDeletionDialogs(model)
}

@Composable
internal fun PhotoErrorPanel(error: Throwable, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(photoError(error), color = MaterialTheme.colorScheme.error)
        Button(onClick = onRetry) { Text(stringResource(R.string.sp_retry)) }
    }
}

@Composable
private fun SynologyPhotoDeletionDialogs(model: SynologyPhotosModel) {
    val state by model.deletion.state.collectAsState()
    state.candidate?.let { photo ->
        AlertDialog(
            onDismissRequest = model.deletion::cancelCandidate,
            title = { Text(stringResource(R.string.sp_delete_title)) },
            text = { Text(stringResource(R.string.sp_delete_confirm, photo.filename)) },
            confirmButton = { TextButton(onClick = { model.deletion.confirm() }) { Text(stringResource(R.string.sp_delete_action)) } },
            dismissButton = { TextButton(onClick = model.deletion::cancelCandidate) { Text(stringResource(R.string.sp_delete_cancel)) } },
        )
    }
    if (state.pending != null) AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.sp_delete_title)) },
        text = { Column {
            Text(stringResource(R.string.sp_delete_pending))
            state.error?.let { Text(photoError(it), color = MaterialTheme.colorScheme.error) }
            if (state.writing) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp))
        } },
        confirmButton = { TextButton(onClick = { model.deletion.review() }, enabled = !state.writing) { Text(stringResource(R.string.sp_delete_review)) } },
    )
}

private fun Context.photoActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.takeIf { it !== this }?.photoActivity()
    else -> null
}
