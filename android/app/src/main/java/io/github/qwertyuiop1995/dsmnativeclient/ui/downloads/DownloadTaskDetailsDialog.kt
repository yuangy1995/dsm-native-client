package io.github.qwertyuiop1995.dsmnativeclient.ui.downloads

import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.ui.displayName
import io.github.qwertyuiop1995.dsmnativeclient.ui.formatBytes
import java.text.DateFormat
import java.text.NumberFormat
import java.util.Date
import java.util.Locale

@Composable
internal fun DownloadTaskDetailsDialog(task: DownloadTask, onDismiss: () -> Unit) {
    ClientPageDialog(task.title.ifBlank { stringResource(R.string.unnamed_download) }, onDismiss) {
        Column(Modifier.fillMaxSize()) {
            DownloadTaskDetailsContent(task, Modifier.weight(1f).fillMaxWidth())
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.close)) }
        }
    }
}

/** 宽屏详情区与窄屏弹窗共享同一套内容，避免两种布局的字段和空状态漂移。 */
@Composable
internal fun DownloadTaskDetailsPane(
    task: DownloadTask,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 24.dp, top = 12.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                task.title.ifBlank { stringResource(R.string.unnamed_download) },
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.titleLarge,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            IconButton(onClick = onDismiss) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = stringResource(R.string.close),
                )
            }
        }
        HorizontalDivider()
        DownloadTaskDetailsContent(
            task = task,
            modifier = Modifier.weight(1f).fillMaxWidth(),
        )
    }
}

@Composable
private fun DownloadTaskDetailsContent(
    task: DownloadTask,
    modifier: Modifier = Modifier,
) {
    var tab by rememberSaveable(task.id) { mutableIntStateOf(0) }
    val titles = listOf(
        stringResource(R.string.download_detail_general),
        stringResource(R.string.download_detail_files),
        stringResource(R.string.download_detail_trackers),
        stringResource(R.string.download_detail_peers),
    )
    Column(modifier) {
        ScrollableTabRow(selectedTabIndex = tab, edgePadding = 0.dp) {
            titles.forEachIndexed { index, title ->
                Tab(
                    selected = tab == index,
                    onClick = { tab = index },
                    text = { Text(title) },
                )
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (tab) {
                0 -> DownloadGeneralDetails(task, Modifier.fillMaxSize())
                1 -> DownloadFileDetails(task, Modifier.fillMaxSize())
                2 -> DownloadTrackerDetails(task, Modifier.fillMaxSize())
                else -> DownloadPeerDetails(task, Modifier.fillMaxSize())
            }
        }
    }
}

@Composable
private fun DownloadGeneralDetails(task: DownloadTask, modifier: Modifier = Modifier) {
    LazyColumn(modifier) {
        item { DetailRow(stringResource(R.string.download_detail_status), task.status.displayName()) }
        task.type?.takeIf(String::isNotBlank)?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_type), value.uppercase(Locale.ROOT)) }
        }
        task.size?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_total_size), formatBytes(value)) }
        }
        task.transferred?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_downloaded), formatBytes(value)) }
        }
        task.downloadSpeed?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_download_speed), speed(value)) }
        }
        task.uploadSpeed?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_upload_speed), speed(value)) }
        }
        task.destination?.takeIf(String::isNotBlank)?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_destination), value) }
        }
        task.createdAtEpochSeconds?.let { value ->
            item {
                DetailRow(
                    stringResource(R.string.download_detail_created),
                    DateFormat.getDateTimeInstance().format(Date(value * 1_000)),
                )
            }
        }
        task.priority?.takeIf(String::isNotBlank)?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_priority), value) }
        }
        task.totalPeers?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_total_peers), value.toString()) }
        }
        task.connectedSeeders?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_connected_seeders), value.toString()) }
        }
        task.connectedLeechers?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_connected_leechers), value.toString()) }
        }
        task.error?.takeIf(String::isNotBlank)?.let { value ->
            item { DetailRow(stringResource(R.string.download_detail_error), value) }
        }
    }
}

@Composable
private fun DownloadFileDetails(task: DownloadTask, modifier: Modifier = Modifier) {
    if (task.files.isEmpty()) {
        DownloadDetailEmpty(R.string.download_detail_no_files, modifier)
        return
    }
    LazyColumn(modifier) {
        itemsIndexed(task.files, key = { index, file -> "$index:${file.name}:${file.size}" }) { _, file ->
            ListItem(
                headlineContent = { Text(file.name, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                supportingContent = {
                    Column {
                        Text(
                            listOfNotNull(
                                file.size?.let(::formatBytes),
                                file.priority?.takeIf(String::isNotBlank),
                            ).joinToString(" · "),
                        )
                        val total = file.size
                        val downloaded = file.downloaded
                        if (total != null && total > 0 && downloaded != null) {
                            val progressDescription = stringResource(
                                R.string.download_detail_file_progress,
                                file.name,
                                formatBytes(downloaded),
                                formatBytes(total),
                            )
                            LinearProgressIndicator(
                                progress = {
                                    (downloaded.toFloat() / total.toFloat()).coerceIn(0f, 1f)
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = 6.dp)
                                    .semantics { stateDescription = progressDescription },
                            )
                        }
                    }
                },
            )
            HorizontalDivider()
        }
    }
}

@Composable
private fun DownloadTrackerDetails(task: DownloadTask, modifier: Modifier = Modifier) {
    if (task.trackers.isEmpty()) {
        DownloadDetailEmpty(R.string.download_detail_no_trackers, modifier)
        return
    }
    LazyColumn(modifier) {
        itemsIndexed(task.trackers, key = { index, tracker -> "$index:${tracker.url}" }) { _, tracker ->
            ListItem(
                headlineContent = {
                    Text(tracker.url, maxLines = 2, overflow = TextOverflow.Ellipsis)
                },
                supportingContent = {
                    Text(
                        listOfNotNull(
                            tracker.status,
                            tracker.seeds?.let {
                                stringResource(R.string.download_detail_seed_count, it)
                            },
                            tracker.peers?.let {
                                stringResource(R.string.download_detail_peer_count, it)
                            },
                            tracker.updateTimerSeconds?.let {
                                stringResource(R.string.download_detail_update_in, it)
                            },
                        ).joinToString(" · "),
                    )
                },
            )
            HorizontalDivider()
        }
    }
}

@Composable
private fun DownloadPeerDetails(task: DownloadTask, modifier: Modifier = Modifier) {
    if (task.peers.isEmpty()) {
        DownloadDetailEmpty(R.string.download_detail_no_peers, modifier)
        return
    }
    LazyColumn(modifier) {
        itemsIndexed(task.peers, key = { index, peer -> "$index:${peer.address}:${peer.agent}" }) { _, peer ->
            ListItem(
                headlineContent = { Text(peer.agent ?: stringResource(R.string.download_detail_unknown_client)) },
                supportingContent = {
                    Text(
                        listOfNotNull(
                            peer.address,
                            peer.progress?.let { value ->
                                NumberFormat.getPercentInstance().format(value)
                            },
                            peer.downloadSpeed?.let {
                                stringResource(R.string.download_detail_down_value, speed(it))
                            },
                            peer.uploadSpeed?.let {
                                stringResource(R.string.download_detail_up_value, speed(it))
                            },
                        ).joinToString(" · "),
                    )
                },
            )
            HorizontalDivider()
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = { Text(value) },
    )
    HorizontalDivider()
}

@Composable
private fun DownloadDetailEmpty(@StringRes message: Int, modifier: Modifier = Modifier) {
    Text(
        stringResource(message),
        modifier = modifier.fillMaxWidth().padding(24.dp),
    )
}

@Composable
private fun speed(value: Long): String =
    stringResource(R.string.download_detail_speed_value, formatBytes(value))
