package io.github.qwertyuiop1995.dsmnativeclient.ui.navigation

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigationStatusResource

@Composable
internal fun ClientBottomNavigation(pinned: PinnedModules, selected: ClientDestination,
    onSelect: (ClientDestination) -> Unit, unreadCount: Int = 0, modifier: Modifier = Modifier,
    availability: List<ModuleAvailability> = emptyList()) {
    if (pinned.items.isEmpty()) return
    Surface(color = MaterialTheme.colorScheme.surface, modifier = modifier.testTag("client_bottom_navigation")) {
        Column {
            HorizontalDivider()
            Row(Modifier.fillMaxWidth().navigationBarsPadding()) {
                pinned.items.forEach { destination ->
                    val label = stringResource(destination.title)
                    val reason = availability.firstOrNull { it.module == destination.module }.navigationStatusResource()?.let { stringResource(it) }
                    Column(
                        Modifier.weight(1f).fillMaxWidth().heightIn(min = 72.dp)
                            .selectable(selected == destination, role = Role.Tab, onClick = { onSelect(destination) })
                            .padding(vertical = 10.dp).semantics { contentDescription = label; reason?.let { stateDescription = it } },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        BadgedBox(badge = { if (destination == ClientDestination.CHAT && unreadCount > 0) Badge {
                            Text(unreadCount.coerceAtMost(99).toString())
                        } }) {
                            Icon(destination.icon, null, tint = if (selected == destination) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface, modifier = Modifier.size(24.dp))
                        }
                        Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 2,
                            overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                            color = if (selected == destination) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                    }
                }
            }
        }
    }
}

@Composable
internal fun ClientFeatureGrid(destinations: List<ClientDestination>, pinned: PinnedModules? = null,
    availability: List<ModuleAvailability> = emptyList(),
    onSelect: (ClientDestination) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        destinations.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { destination ->
                    val reason = availability.firstOrNull { it.module == destination.module }.navigationStatusResource()?.let { stringResource(it) }
                    Surface(onClick = { onSelect(destination) }, modifier = Modifier.weight(1f).semantics { reason?.let { stateDescription = it } },
                        shape = MaterialTheme.shapes.small,
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                        color = MaterialTheme.colorScheme.surface) {
                        Box {
                            Column(Modifier.fillMaxWidth().heightIn(min = 88.dp).padding(12.dp),
                                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(destination.icon, null, Modifier.size(26.dp))
                                Text(stringResource(destination.title), style = MaterialTheme.typography.labelMedium,
                                    textAlign = TextAlign.Center)
                                if (reason != null) Text(stringResource(R.string.unavailable), style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (pinned?.items?.contains(destination) == true) Icon(Icons.Outlined.PushPin, null,
                                Modifier.align(Alignment.TopEnd).padding(4.dp).size(14.dp), tint = MaterialTheme.colorScheme.primary)
                        }
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}
