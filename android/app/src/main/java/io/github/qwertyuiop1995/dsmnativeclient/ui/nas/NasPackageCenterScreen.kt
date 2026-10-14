package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.*
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*

@Composable
internal fun NasPackageCenterScreen(snapshot: NasSettingsSnapshot, workspace: WorkspaceState, app: AppViewModel) {
    val model = app.packageCenter
    val state by model.state.collectAsStateWithLifecycle()
    var tab by rememberSaveable(workspace.profile.id) { mutableIntStateOf(0) }
    var selected by remember { mutableStateOf<NasPackageEntry?>(null) }
    var optionsVisible by remember { mutableStateOf(false) }
    var fileToken by remember { mutableStateOf<Long?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) fileToken?.let { app.choosePackageFile(uri, it) }
        fileToken = null
    }
    LaunchedEffect(model, workspace.profile.id) { model.restore() }
    LaunchedEffect(tab, workspace.profile.id) {
        when (tab) { 1 -> model.catalog(); 2 -> model.preferences(); 3 -> model.sources(); 4 -> model.restore() }
    }
    LaunchedEffect(state.progress?.id, state.progress?.phase) { if (state.progress?.phase == NasPackageInstallPhase.OPTIONS) optionsVisible = true }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf(R.string.pc_installed, R.string.pc_catalog, R.string.module_settings, R.string.pc_sources, R.string.pc_activity).forEachIndexed { index, title ->
                FilterChip(selected = tab == index, onClick = { tab = index }, label = { Text(stringResource(title)) })
            }
        }
        state.progress?.let { progress -> PackageProgressCard(progress, state.busy, model::refreshProgress, model::cancel) { optionsVisible = true } }
        state.failure?.let { PackageError(it, model::dismissFailure) }
        Box(Modifier.weight(1f)) {
            when (tab) {
                0 -> NasPackageManagementScreen(snapshot, workspace, app)
                1 -> PackageCatalogContent(state, model::catalog, onSelect = { selected = it }, onPrepare = { model.prepare(listOf(it)) },
                    onChooseFile = { fileToken = model.selectionToken; picker.launch(arrayOf("*/*")) }, onUpload = model::upload, onClearFile = model::clearFile)
                2 -> PackagePreferencesContent(state, model::preferences, model::savePreferences)
                3 -> PackageSourcesContent(state, model::sources, model::saveSource)
                4 -> PackageActivityContent(state.activities, state.busy, model::review, model::discard)
            }
        }
    }
    selected?.let { entry ->
        ClientSheet(entry.name, onDismiss = { selected = null }) {
            Text(stringResource(R.string.pc_version, entry.version))
            if (entry.publisher.isNotEmpty()) Text(entry.publisher)
            if (entry.description.isNotEmpty()) SelectionContainer { Text(packagePlainText(entry.description)) }
            if (entry.releaseNotes.isNotEmpty()) { ClientSectionTitle(stringResource(R.string.pc_release_notes)); SelectionContainer { Text(packagePlainText(entry.releaseNotes)) } }
            if (entry.installedVersion == null || entry.updateAvailable) Button(onClick = { selected = null; model.prepare(listOf(entry)) }, enabled = !state.busy) {
                Text(stringResource(if (entry.installedVersion == null) R.string.pc_install else R.string.pc_update))
            }
        }
    }
    state.plan?.let { PackagePlanSheet(it, state.busy, model::dismissPlan, model::start) }
    if (optionsVisible) state.progress?.configuration?.let { configuration ->
        PackageOptionsSheet(configuration, state.busy, onDismiss = { optionsVisible = false }, onInstall = model::configure)
    }
}

@Composable
private fun PackageCatalogContent(state: NasPackageCenterState, refresh: () -> Unit, onSelect: (NasPackageEntry) -> Unit,
    onPrepare: (NasPackageEntry) -> Unit, onChooseFile: () -> Unit, onUpload: () -> Unit, onClearFile: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var category by rememberSaveable { mutableStateOf("") }
    var updates by rememberSaveable { mutableStateOf(false) }
    val entries = state.catalog?.entries.orEmpty().filter { entry ->
        (query.isBlank() || entry.name.contains(query, true) || entry.packageId.contains(query, true)) &&
            (category.isEmpty() || category in entry.categories || category == "@community" && !entry.official) && (!updates || entry.updateAvailable)
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            ClientSectionTitle(stringResource(R.string.pc_catalog), stringResource(R.string.refresh), refresh)
            OutlinedTextField(query, { query = it }, label = { Text(stringResource(R.string.pc_search)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(updates, { updates = !updates }, label = { Text(stringResource(R.string.pc_updates)) })
                FilterChip(category.isEmpty(), { category = "" }, label = { Text(stringResource(R.string.pc_all_categories)) })
                state.catalog?.categories.orEmpty().forEach { item -> FilterChip(category == item.id, { category = item.id }, label = { Text(item.name) }) }
                FilterChip(category == "@community", { category = "@community" }, label = { Text(stringResource(R.string.pc_community)) })
            }
        }
        item {
            ClientGroup {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.pc_manual_install), style = MaterialTheme.typography.titleSmall)
                    state.fileName?.let { Text(it) }
                    if (state.fileCopying) LinearProgressIndicator(Modifier.fillMaxWidth())
                    Row(Modifier.horizontalScroll(rememberScrollState())) {
                        TextButton(onChooseFile, enabled = !state.busy && !state.fileCopying) { Text(stringResource(R.string.pc_choose_spk)) }
                        if (state.fileName != null) {
                            TextButton(onUpload, enabled = !state.busy) { Text(stringResource(R.string.pc_upload_prepare)) }
                            TextButton(onClearFile, enabled = !state.busy) { Text(stringResource(R.string.cancel)) }
                        }
                    }
                }
            }
        }
        if (state.catalogLoading) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        state.catalogFailure?.let { item { PackageError(it, refresh, retry = true) } }
        if (category == "@community" && state.catalog?.communityAvailable == false) item { Text(stringResource(R.string.pc_community_unavailable), color = MaterialTheme.colorScheme.error) }
        if (!state.catalogLoading && state.catalogFailure == null && state.catalog != null && entries.isEmpty()) item {
            Text(stringResource(if (query.isNotBlank() || category.isNotEmpty() || updates) R.string.pc_no_matches else R.string.pc_catalog_empty))
        }
        items(entries, key = { it.id }) { entry ->
            ClientGroup {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    TextButton(onClick = { onSelect(entry) }, contentPadding = PaddingValues(0.dp)) { Text(entry.name, style = MaterialTheme.typography.titleMedium) }
                    Text(stringResource(R.string.pc_version, entry.version), style = MaterialTheme.typography.bodySmall)
                    if (entry.installedVersion == null || entry.updateAvailable) TextButton(onClick = { onPrepare(entry) }, enabled = !state.busy) {
                        Text(stringResource(if (entry.installedVersion == null) R.string.pc_install else R.string.pc_update))
                    }
                }
            }
        }
    }
}

@Composable
internal fun PackageError(error: Exception, onAction: () -> Unit, retry: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(12.dp)) {
        Text(packageErrorText(error), color = MaterialTheme.colorScheme.error)
        TextButton(onAction) { Text(stringResource(if (retry) R.string.retry else R.string.close)) }
    }
}
@Composable
internal fun packageErrorText(error: Exception): String = if (error is NasPackageFailure) stringResource(when (error.problem) {
    NasPackageProblem.INCOMPLETE -> R.string.pc_error_incomplete
    NasPackageProblem.CHANGED -> R.string.pc_error_changed
    NasPackageProblem.BUSY -> R.string.pc_error_busy
    NasPackageProblem.DEPENDENCIES -> R.string.pc_error_dependencies
    NasPackageProblem.VOLUME -> R.string.pc_error_volume
    NasPackageProblem.BETA_AGREEMENT -> R.string.pc_error_beta
    NasPackageProblem.PURCHASE -> R.string.pc_error_purchase
    NasPackageProblem.SIGNATURE -> R.string.pc_error_signature
    NasPackageProblem.CUSTOM_OPTIONS -> R.string.pc_error_custom
    NasPackageProblem.OPTIONS_REQUIRED -> R.string.pc_error_options
    NasPackageProblem.INVALID_FILE -> R.string.pc_error_file
    NasPackageProblem.INVALID_SOURCE -> R.string.pc_error_source
    NasPackageProblem.DUPLICATE_SOURCE -> R.string.pc_error_duplicate
    NasPackageProblem.UNKNOWN -> R.string.pc_error_unknown
    NasPackageProblem.FAILED -> R.string.pc_error_failed
}) else error.asDsmFailure().localize(LocalContext.current).combined

internal fun packagePlainText(value: String): String = android.text.Html.fromHtml(value, android.text.Html.FROM_HTML_MODE_COMPACT).toString().trim()
