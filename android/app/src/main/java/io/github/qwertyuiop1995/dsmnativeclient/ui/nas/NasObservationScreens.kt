package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.compose.foundation.clickable
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
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasObservationModel
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.*
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@Composable internal fun NasLogsScreen(model: NasObservationModel) {
    val state by model.state.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }; var level by rememberSaveable { mutableStateOf<LogLevel?>(null) }
    val page = state.logs
    LaunchedEffect(model) { model.logs(0, 100) }
    DisposableEffect(model) { onDispose { model.leaveLogs() } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton({ model.logs() }, enabled = !state.logsLoading) { Text(stringResource(R.string.refresh)) }
            listOf(50, 100, 200).forEach { limit -> FilterChip((page?.limit ?: 100) == limit, { model.logs(0, limit) },
                enabled = !state.logsLoading, label = { Text(stringResource(R.string.nas_log_page_size, limit)) }) }
        }
        ClientSearchField(query, { query = it }, stringResource(R.string.nas_log_search_page), Modifier.padding(12.dp))
        Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(level == null, { level = null }, label = { Text(stringResource(R.string.all)) })
            LogLevel.entries.forEach { value -> FilterChip(level == value, { level = value }, label = { Text(logLevelText(value)) }) }
        }
        if (state.logsLoading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(12.dp))
        state.logsFailure?.let { ObservationError(it, model::retryLogs) }
        if (page != null) {
            Text(if (page.total == null) stringResource(R.string.nas_log_page_unknown, page.offset / page.limit + 1)
                else stringResource(R.string.nas_log_page_known, page.offset / page.limit + 1, page.total),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
            val filtered = page.entries.filter { (level == null || it.level == level) &&
                (query.isBlank() || listOf(it.message, it.account.orEmpty(), it.source.orEmpty()).any { text -> text.contains(query, true) }) }
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (filtered.isEmpty()) item { Text(stringResource(if (page.entries.isEmpty()) R.string.no_log_entries else R.string.no_matching_log_entries))
                    Text(stringResource(if (page.entries.isEmpty()) R.string.no_log_entries_description else R.string.no_matching_log_entries_description)) }
                items(filtered, key = { it.id }) { entry -> ClientGroup {
                    Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClickLabel = stringResource(R.string.nas_log_details)) { model.inspectLog(entry) }
                        .padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(entry.message, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        Text(logLevelText(entry.level), style = MaterialTheme.typography.labelMedium)
                        entry.time?.let { Text(observationTime(it), style = MaterialTheme.typography.bodySmall) }
                        listOfNotNull(entry.account, entry.source).filter { it.isNotBlank() }.takeIf { it.isNotEmpty() }?.let { Text(it.joinToString(" · "), style = MaterialTheme.typography.bodySmall) }
                    }
                } }
            }
            Row(Modifier.padding(12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton({ model.logs((page.offset - page.limit).coerceAtLeast(0), page.limit) }, enabled = !state.logsLoading && page.offset > 0) { Text(stringResource(R.string.previous_page)) }
                OutlinedButton({ model.logs(page.offset + page.limit, page.limit) }, enabled = !state.logsLoading && page.hasNext) { Text(stringResource(R.string.next_page)) }
            }
        }
    }
    state.selectedLog?.let { entry -> ClientSheet(stringResource(R.string.nas_log_details), model::closeLog) {
        Text(logLevelText(entry.level)); entry.time?.let { Text(observationTime(it)) }
        entry.account?.let { Text(stringResource(R.string.nas_log_account, it)) }; entry.source?.let { Text(stringResource(R.string.nas_log_source, it)) }
        SelectionContainer { Text(entry.message) }
    } }
}

@Composable internal fun NasProcessesScreen(model: NasObservationModel) {
    val state by model.state.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }; var showGroups by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(model) { model.processes() }
    DisposableEffect(model) { onDispose { model.leaveProcesses() } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(model::processes, enabled = !state.processesLoading) { Text(stringResource(R.string.refresh)) }
            FilterChip(!showGroups, { showGroups = false }, label = { Text(stringResource(R.string.nas_processes)) })
            FilterChip(showGroups, { showGroups = true }, label = { Text(stringResource(R.string.nas_process_groups)) })
        }
        ClientSearchField(query, { query = it }, stringResource(R.string.nas_process_search), Modifier.padding(12.dp))
        if (state.processesLoading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(12.dp))
        state.processesFailure?.let { ObservationError(it, model::processes) }
        val directory = state.processes
        if (directory != null) LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (directory.truncated) item { Text(stringResource(R.string.nas_process_truncated)) }
            if (directory.groupsUnavailable) item { Text(stringResource(R.string.nas_groups_unavailable)) }
            if (!showGroups) {
                val rows = directory.processes.filter { it.name.contains(query, true) || it.id.contains(query) || it.groupId.orEmpty().contains(query, true) }
                    .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
                if (rows.isEmpty()) item { ObservationEmpty(query.isNotBlank()) }
                items(rows, key = { it.id }) { process -> ClientGroup {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(process.name, style = MaterialTheme.typography.titleSmall)
                        Text(stringResource(R.string.nas_process_id, process.id))
                        process.status?.let { Text(it) }; process.groupId?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                    }
                } }
            } else {
                val rows = directory.groups.filter { it.name.contains(query, true) || it.id.contains(query, true) }
                    .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
                if (rows.isEmpty() && !directory.groupsUnavailable) item { ObservationEmpty(query.isNotBlank()) }
                items(rows, key = { it.id }) { group -> ClientGroup {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(group.name, style = MaterialTheme.typography.titleSmall); group.status?.let { Text(it) }
                        group.count?.let { Text(stringResource(R.string.nas_process_group_count, it)) }
                    }
                } }
            }
        }
    }
}
@Composable private fun ObservationEmpty(filtered: Boolean) {
    Text(stringResource(if (filtered) R.string.nas_process_no_matches else R.string.nas_process_empty))
    Text(stringResource(if (filtered) R.string.st_filter_hint else R.string.nas_process_empty_hint))
}
@Composable private fun ObservationError(error: Exception, onRetry: () -> Unit) {
    ClientGroup(Modifier.padding(12.dp)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(if ((error as? DsmFailure)?.kind == DsmErrorKind.FEATURE_UNSUPPORTED) R.string.nas_observation_unsupported else R.string.nas_read_failed), color = MaterialTheme.colorScheme.error)
            TextButton(onRetry) { Text(stringResource(R.string.retry)) }
        }
    }
}
@Composable private fun logLevelText(level: LogLevel) = stringResource(when (level) {
    LogLevel.INFO -> R.string.info; LogLevel.WARNING -> R.string.warning; LogLevel.ERROR -> R.string.error; LogLevel.UNKNOWN -> R.string.other
})
@Composable private fun observationTime(raw: String): String {
    val locale = LocalConfiguration.current.locales[0]
    val time = runCatching { LocalDateTime.parse(raw) }.getOrNull()
        ?: runCatching { LocalDateTime.parse(raw, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")) }.getOrNull()
    return time?.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale)) ?: raw
}
