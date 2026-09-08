package io.github.qwertyuiop1995.dsmnativeclient.ui.services

import androidx.compose.ui.res.stringResource
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.ErrorOutline
import io.github.qwertyuiop1995.dsmnativeclient.R

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/** 套件分区采用可直接进入的入口网格，不让手机横向寻找长标签列。 */
@Composable
internal fun ClientServiceSections(titles: List<String>, onSelect: (Int) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        titles.indices.toList().chunked(3).forEach { indices ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                indices.forEach { index ->
                    Surface(onClick = { onSelect(index) }, modifier = Modifier.weight(1f),
                        shape = MaterialTheme.shapes.small, color = MaterialTheme.colorScheme.surface,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)) {
                        Column(Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(10.dp),
                            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Outlined.FolderOpen, null, tint = MaterialTheme.colorScheme.primary)
                            Text(titles[index], style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
                repeat(3 - indices.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
internal fun ServiceSectionUnavailable(onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.ErrorOutline, contentDescription = null)
        Text(
            stringResource(R.string.service_section_unavailable_title),
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            stringResource(R.string.service_section_unavailable_message),
            modifier = Modifier.padding(top = 8.dp),
        )
        TextButton(onClick = onRetry, modifier = Modifier.padding(top = 8.dp)) {
            Text(stringResource(R.string.retry))
        }
    }
}
