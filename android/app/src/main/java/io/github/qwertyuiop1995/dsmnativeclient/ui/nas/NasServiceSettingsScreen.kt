package io.github.qwertyuiop1995.dsmnativeclient.ui.nas

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FolderShared
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.AppViewModel
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasServiceEditorState
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.ui.ConfirmDialog
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize

@Composable
internal fun NasServiceSettingsScreen(
    snapshot: NasSettingsSnapshot,
    isPerformingAction: Boolean,
    model: AppViewModel,
) {
    val services = model.nasServices
    val serviceStates by services.state.collectAsState()
    LaunchedEffect(services) { services.load() }
    NasServiceSettingsContent(snapshot, isPerformingAction, serviceStates, services::begin, services::draft, services::save,
        { services.refresh(it) }, { kind, discard -> services.dismiss(kind, discard) })
}

@Composable
internal fun NasServiceSettingsContent(snapshot: NasSettingsSnapshot, isPerformingAction: Boolean,
    serviceStates: Map<NasServiceKind, NasServiceEditorState>, onBegin: (NasServiceValue) -> Boolean,
    onDraft: (NasServiceKind, NasServiceValue?) -> Unit, onSave: (NasServiceKind) -> Boolean,
    onRefresh: (NasServiceKind) -> Unit, onDismiss: (NasServiceKind, Boolean) -> Unit) {
    val filesState = serviceStates.getValue(NasServiceKind.FILES)
    val terminalState = serviceStates.getValue(NasServiceKind.TERMINAL)
    val proxyState = serviceStates.getValue(NasServiceKind.PROXY)
    val savedDraft = (filesState.draft as? NasServiceValue.Files)?.settings
    val savedTerminalDraft = (terminalState.draft as? NasServiceValue.Terminal)?.settings
    val savedProxyDraft = (proxyState.draft as? NasServiceValue.Proxy)?.settings
    val mutationResult = filesState.result
    val mutationFailure = filesState.failure
    val mutationInProgress = filesState.saving
    val mutationRefreshCompleted = !filesState.blocked && mutationResult != null
    val terminalMutationResult = terminalState.result
    val terminalMutationFailure = terminalState.failure
    val terminalMutationInProgress = terminalState.saving
    val terminalMutationRefreshCompleted = !terminalState.blocked && terminalMutationResult != null
    val proxyMutationResult = proxyState.result
    val proxyMutationFailure = proxyState.failure
    val proxyMutationInProgress = proxyState.saving
    val proxyMutationRefreshCompleted = !proxyState.blocked && proxyMutationResult != null
    var editFiles by rememberSaveable { mutableStateOf(false) }
    var confirmFiles by rememberSaveable { mutableStateOf(false) }
    var fileSaveRequested by rememberSaveable { mutableStateOf(false) }
    var editTerminal by rememberSaveable { mutableStateOf(false) }
    var confirmTerminal by rememberSaveable { mutableStateOf(false) }
    var terminalSaveRequested by rememberSaveable { mutableStateOf(false) }
    var editProxy by rememberSaveable { mutableStateOf(false) }
    var confirmProxy by rememberSaveable { mutableStateOf(false) }
    var proxySaveRequested by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(mutationInProgress, mutationResult, mutationFailure) {
        when {
            mutationInProgress -> fileSaveRequested = true
            shouldReopenFileServiceEditor(
                saveRequested = fileSaveRequested,
                mutationInProgress = mutationInProgress,
                mutationResult = mutationResult,
                mutationFailure = mutationFailure,
            ) -> {
                fileSaveRequested = false
                editFiles = true
            }
            fileSaveRequested -> fileSaveRequested = false
        }
    }
    LaunchedEffect(
        terminalMutationInProgress,
        terminalMutationResult,
        terminalMutationFailure,
    ) {
        when {
            terminalMutationInProgress -> terminalSaveRequested = true
            shouldReopenTerminalEditor(
                saveRequested = terminalSaveRequested,
                mutationInProgress = terminalMutationInProgress,
                mutationResult = terminalMutationResult,
                mutationFailure = terminalMutationFailure,
            ) -> {
                terminalSaveRequested = false
                editTerminal = true
            }
            terminalSaveRequested -> terminalSaveRequested = false
        }
    }
    LaunchedEffect(proxyMutationInProgress, proxyMutationResult, proxyMutationFailure) {
        when {
            proxyMutationInProgress -> proxySaveRequested = true
            shouldReopenProxyEditor(
                saveRequested = proxySaveRequested,
                mutationInProgress = proxyMutationInProgress,
                mutationResult = proxyMutationResult,
                mutationFailure = proxyMutationFailure,
            ) -> {
                proxySaveRequested = false
                editProxy = true
            }
            proxySaveRequested -> proxySaveRequested = false
        }
    }
    LazyColumn {
        if (serviceStates.values.any { it.busy && !it.saving }) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (fileSaveRequested || mutationInProgress) {
            item {
                FileServiceSavingCard()
            }
        } else {
            mutationResult?.let { result ->
                item {
                    val policy = fileServiceFeedbackPolicy(result)
                    FileServiceMutationFeedbackCard(
                        result = result,
                        canDismiss = !filesState.blocked,
                        refreshCompleted = mutationRefreshCompleted,
                        canContinueEditing = !filesState.blocked && savedDraft != null &&
                            (!policy.mustRefreshBeforeEditing || mutationRefreshCompleted),
                        onRefresh = { onRefresh(NasServiceKind.FILES) },
                        onContinueEditing = {
                            editFiles = savedDraft != null
                            onDismiss(NasServiceKind.FILES, false)
                        },
                        onDismiss = { onDismiss(NasServiceKind.FILES, true) },
                    )
                }
            }
            mutationFailure?.let { failure ->
                item {
                    FileServiceMutationFailureCard(
                        failure = failure,
                        canDismiss = !filesState.blocked,
                        canContinueEditing = !filesState.blocked && savedDraft != null,
                        onContinueEditing = {
                            editFiles = savedDraft != null
                            onDismiss(NasServiceKind.FILES, false)
                        },
                        onDismiss = { onDismiss(NasServiceKind.FILES, true) },
                    )
                }
            }
        }
        if (terminalSaveRequested || terminalMutationInProgress) {
            item {
                TerminalSavingCard()
            }
        } else {
            terminalMutationResult?.let { result ->
                item {
                    val policy = terminalFeedbackPolicy(result)
                    TerminalMutationFeedbackCard(
                        result = result,
                        canDismiss = !terminalState.blocked,
                        refreshCompleted = terminalMutationRefreshCompleted,
                        canContinueEditing = !terminalState.blocked && savedTerminalDraft != null &&
                            (!policy.mustRefreshBeforeEditing || terminalMutationRefreshCompleted),
                        onRefresh = {
                            onRefresh(NasServiceKind.TERMINAL)
                        },
                        onContinueEditing = {
                            editTerminal = savedTerminalDraft != null
                            onDismiss(NasServiceKind.TERMINAL, false)
                        },
                        onDismiss = { onDismiss(NasServiceKind.TERMINAL, true) },
                    )
                }
            }
            terminalMutationFailure?.let { failure ->
                item {
                    TerminalMutationFailureCard(
                        failure = failure,
                        canDismiss = !terminalState.blocked,
                        canContinueEditing = !terminalState.blocked && savedTerminalDraft != null,
                        onContinueEditing = {
                            editTerminal = savedTerminalDraft != null
                            onDismiss(NasServiceKind.TERMINAL, false)
                        },
                        onDismiss = { onDismiss(NasServiceKind.TERMINAL, true) },
                    )
                }
            }
        }
        if (proxySaveRequested || proxyMutationInProgress) {
            item {
                ProxySavingCard()
            }
        } else {
            proxyMutationResult?.let { result ->
                item {
                    val policy = proxyFeedbackPolicy(result)
                    ProxyMutationFeedbackCard(
                        result = result,
                        canDismiss = !proxyState.blocked,
                        refreshCompleted = proxyMutationRefreshCompleted,
                        canContinueEditing = !proxyState.blocked && savedProxyDraft != null &&
                            (!policy.mustRefreshBeforeEditing || proxyMutationRefreshCompleted),
                        onRefresh = {
                            onRefresh(NasServiceKind.PROXY)
                        },
                        onContinueEditing = {
                            editProxy = savedProxyDraft != null
                            onDismiss(NasServiceKind.PROXY, false)
                        },
                        onDismiss = { onDismiss(NasServiceKind.PROXY, true) },
                    )
                }
            }
            proxyMutationFailure?.let { failure ->
                item {
                    ProxyMutationFailureCard(
                        failure = failure,
                        canDismiss = !proxyState.blocked,
                        canContinueEditing = !proxyState.blocked && savedProxyDraft != null,
                        onContinueEditing = {
                            editProxy = savedProxyDraft != null
                            onDismiss(NasServiceKind.PROXY, false)
                        },
                        onDismiss = { onDismiss(NasServiceKind.PROXY, true) },
                    )
                }
            }
        }
        snapshot.fileServiceSettings?.let { settings ->
            item {
                SettingsSummaryRow(
                    title = stringResource(R.string.file_services),
                    detail = fileServiceSummary(settings),
                    icon = { Icon(Icons.Outlined.FolderShared, null) },
                    onEdit = {
                        editFiles = onBegin(NasServiceValue.Files(settings))
                    },
                    enabled = !isPerformingAction && !filesState.blocked && mutationResult == null && mutationFailure == null,
                )
            }
        }
        snapshot.terminalSettings?.let { settings ->
            item {
                SettingsSummaryRow(
                    title = stringResource(R.string.remote_terminal),
                    detail = terminalSummary(settings),
                    icon = { Icon(Icons.Outlined.Terminal, null) },
                    onEdit = {
                        editTerminal = onBegin(NasServiceValue.Terminal(settings))
                    },
                    enabled = !isPerformingAction && !terminalState.blocked && terminalMutationResult == null &&
                        terminalMutationFailure == null,
                )
            }
        } ?: run {
            if (snapshot.fileServiceSettings != null || snapshot.proxySettings != null) {
                item {
                    SettingsUnavailableRow(
                        title = stringResource(R.string.remote_terminal),
                        detail = stringResource(R.string.terminal_settings_unavailable_hint),
                        icon = { Icon(Icons.Outlined.Terminal, null) },
                    )
                }
            }
        }
        snapshot.proxySettings?.let { settings ->
            item {
                SettingsSummaryRow(
                    title = stringResource(R.string.internet_proxy),
                    detail = if (settings.isEnabled) settings.host else stringResource(R.string.service_disabled),
                    icon = { Icon(Icons.Outlined.Public, null) },
                    onEdit = {
                        editProxy = onBegin(NasServiceValue.Proxy(settings))
                    },
                    enabled = !isPerformingAction && !proxyState.blocked && !proxyMutationInProgress &&
                        proxyMutationResult == null && proxyMutationFailure == null,
                )
            }
        } ?: run {
            if (snapshot.fileServiceSettings != null || snapshot.terminalSettings != null) {
                item {
                    SettingsUnavailableRow(
                        title = stringResource(R.string.internet_proxy),
                        detail = stringResource(R.string.proxy_settings_unavailable_hint),
                        icon = { Icon(Icons.Outlined.Public, null) },
                    )
                }
            }
        }
        if (
            snapshot.fileServiceSettings == null && snapshot.terminalSettings == null &&
            snapshot.proxySettings == null
        ) {
            item {
                Column(Modifier.fillMaxWidth().padding(24.dp)) {
                    Text(stringResource(R.string.no_service_settings), style = MaterialTheme.typography.titleMedium)
                    Text(
                        stringResource(R.string.no_service_settings_hint),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
    if (editFiles) (filesState.original as? NasServiceValue.Files)?.settings?.let { baseline ->
        FileServiceDialog(
            baseline = baseline,
            restoredDraft = savedDraft,
            onDraftChange = { onDraft(NasServiceKind.FILES, NasServiceValue.Files(it)) },
            onSave = {
                onDraft(NasServiceKind.FILES, NasServiceValue.Files(it))
                confirmFiles = true
                editFiles = false
            },
            onDismiss = {
                onDraft(NasServiceKind.FILES, null)
                editFiles = false
            },
        )
    }
    if (editTerminal) (terminalState.original as? NasServiceValue.Terminal)?.settings?.let { baseline ->
        TerminalSettingsDialog(
            baseline = baseline,
            restoredDraft = savedTerminalDraft,
            onDraftChange = { onDraft(NasServiceKind.TERMINAL, NasServiceValue.Terminal(it)) },
            onSave = {
                onDraft(NasServiceKind.TERMINAL, NasServiceValue.Terminal(it))
                confirmTerminal = true
                editTerminal = false
            },
            onDismiss = {
                onDraft(NasServiceKind.TERMINAL, null)
                editTerminal = false
            },
        )
    }
    if (editProxy) (proxyState.original as? NasServiceValue.Proxy)?.settings?.let { baseline ->
        ProxySettingsDialog(
            baseline = baseline,
            restoredDraft = savedProxyDraft,
            onDraftChange = { onDraft(NasServiceKind.PROXY, NasServiceValue.Proxy(it)) },
            onSave = {
                onDraft(NasServiceKind.PROXY, NasServiceValue.Proxy(it))
                confirmProxy = true
                editProxy = false
            },
            onDismiss = {
                onDraft(NasServiceKind.PROXY, null)
                editProxy = false
            },
        )
    }
    if (confirmFiles) savedDraft?.let { value ->
        ConfirmDialog(
            title = stringResource(R.string.save_file_services_title),
            message = stringResource(R.string.save_file_services_message),
            confirm = stringResource(R.string.save),
            destructive = true,
            onConfirm = {
                if (onSave(NasServiceKind.FILES)) {
                    fileSaveRequested = true
                    confirmFiles = false
                }
            },
            onDismiss = {
                confirmFiles = false
                editFiles = true
            },
        )
    }
    if (confirmTerminal) savedTerminalDraft?.let { value ->
        ConfirmDialog(
            title = stringResource(R.string.save_terminal_title),
            message = stringResource(R.string.save_terminal_message),
            confirm = stringResource(R.string.save),
            destructive = true,
            onConfirm = {
                if (onSave(NasServiceKind.TERMINAL)) {
                    terminalSaveRequested = true
                    confirmTerminal = false
                }
            },
            onDismiss = {
                confirmTerminal = false
                editTerminal = true
            },
        )
    }
    if (confirmProxy) savedProxyDraft?.let { value ->
        ConfirmDialog(
            title = stringResource(R.string.save_proxy_title),
            message = stringResource(R.string.save_proxy_message),
            confirm = stringResource(R.string.save),
            destructive = true,
            onConfirm = {
                if (onSave(NasServiceKind.PROXY)) {
                    proxySaveRequested = true
                    confirmProxy = false
                }
            },
            onDismiss = {
                confirmProxy = false
                editProxy = true
            },
        )
    }
}

@Composable
internal fun FileServiceSavingCard() = SettingsSavingCard(
    title = R.string.file_service_saving_title,
    message = R.string.file_service_saving_message,
)

@Composable
internal fun TerminalSavingCard() = SettingsSavingCard(
    title = R.string.terminal_saving_title,
    message = R.string.terminal_saving_message,
)

@Composable
internal fun ProxySavingCard() = SettingsSavingCard(
    title = R.string.proxy_saving_title,
    message = R.string.proxy_saving_message,
)

@Composable
private fun SettingsSavingCard(@StringRes title: Int, @StringRes message: Int) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                stringResource(title),
                style = MaterialTheme.typography.titleMedium,
            )
            Text(stringResource(message))
            LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

@Composable
internal fun FileServiceMutationFeedbackCard(
    result: MutationResult,
    canDismiss: Boolean = true,
    refreshCompleted: Boolean,
    canContinueEditing: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val policy = fileServiceFeedbackPolicy(result)
    SettingsMutationFeedbackCard(
        result = result,
        canDismiss = canDismiss,
        title = policy.title,
        message = policy.message,
        canRefresh = policy.canRefresh,
        mustRefreshBeforeEditing = policy.mustRefreshBeforeEditing,
        isAssertive = policy.isAssertive,
        counts = R.string.file_service_feedback_counts,
        refreshCompletedMessage = R.string.file_service_refresh_completed,
        refreshAction = R.string.refresh_and_check_settings,
        discardAction = R.string.discard_file_service_draft,
        refreshCompleted = refreshCompleted,
        canContinueEditing = canContinueEditing,
        onRefresh = onRefresh,
        onContinueEditing = onContinueEditing,
        onDismiss = onDismiss,
    )
}

@Composable
internal fun TerminalMutationFeedbackCard(
    result: MutationResult,
    canDismiss: Boolean = true,
    refreshCompleted: Boolean,
    canContinueEditing: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val policy = terminalFeedbackPolicy(result)
    SettingsMutationFeedbackCard(
        result = result,
        canDismiss = canDismiss,
        title = policy.title,
        message = policy.message,
        canRefresh = policy.canRefresh,
        mustRefreshBeforeEditing = policy.mustRefreshBeforeEditing,
        isAssertive = policy.isAssertive,
        counts = R.string.terminal_feedback_counts,
        refreshCompletedMessage = R.string.terminal_refresh_completed,
        refreshAction = R.string.refresh_and_check_terminal_settings,
        discardAction = R.string.discard_terminal_draft,
        refreshCompleted = refreshCompleted,
        canContinueEditing = canContinueEditing,
        onRefresh = onRefresh,
        onContinueEditing = onContinueEditing,
        onDismiss = onDismiss,
    )
}

@Composable
internal fun ProxyMutationFeedbackCard(
    result: MutationResult,
    canDismiss: Boolean = true,
    refreshCompleted: Boolean,
    canContinueEditing: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val policy = proxyFeedbackPolicy(result)
    SettingsMutationFeedbackCard(
        result = result,
        canDismiss = canDismiss,
        title = policy.title,
        message = policy.message,
        canRefresh = policy.canRefresh,
        mustRefreshBeforeEditing = policy.mustRefreshBeforeEditing,
        isAssertive = policy.isAssertive,
        counts = R.string.proxy_feedback_counts,
        refreshCompletedMessage = R.string.proxy_refresh_completed,
        refreshAction = R.string.refresh_and_check_proxy_settings,
        discardAction = R.string.discard_proxy_draft,
        refreshCompleted = refreshCompleted,
        canContinueEditing = canContinueEditing,
        onRefresh = onRefresh,
        onContinueEditing = onContinueEditing,
        onDismiss = onDismiss,
    )
}

@Composable
private fun SettingsMutationFeedbackCard(
    result: MutationResult,
    canDismiss: Boolean = true,
    @StringRes title: Int,
    @StringRes message: Int,
    canRefresh: Boolean,
    mustRefreshBeforeEditing: Boolean,
    isAssertive: Boolean,
    @StringRes counts: Int,
    @StringRes refreshCompletedMessage: Int,
    @StringRes refreshAction: Int,
    @StringRes discardAction: Int,
    refreshCompleted: Boolean,
    canContinueEditing: Boolean,
    onRefresh: () -> Unit,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val success = result.status == MutationResultStatus.CONFIRMED_SUCCESS
    val error = result.status == MutationResultStatus.PERMISSION_DENIED ||
        result.status == MutationResultStatus.CONFIRMED_FAILURE
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .semantics {
                liveRegion = if (isAssertive) LiveRegionMode.Assertive else LiveRegionMode.Polite
            },
        colors = CardDefaults.cardColors(
            containerColor = if (success) {
                MaterialTheme.colorScheme.secondaryContainer
            } else if (error) {
                MaterialTheme.colorScheme.errorContainer
            } else {
                MaterialTheme.colorScheme.tertiaryContainer
            },
        ),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(message))
            val resultCounts = result.counts
            if (resultCounts.succeeded + resultCounts.failed + resultCounts.unknown > 0) {
                Text(
                    stringResource(
                        counts,
                        resultCounts.succeeded,
                        resultCounts.failed,
                        resultCounts.unknown,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (canRefresh) {
                TextButton(onClick = onRefresh, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(refreshAction))
                }
            }
            if (refreshCompleted && mustRefreshBeforeEditing) {
                Text(
                    stringResource(refreshCompletedMessage),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (!success && canContinueEditing) {
                TextButton(onClick = onContinueEditing, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(R.string.continue_editing))
                }
            }
            if (canDismiss) TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) {
                Text(
                    stringResource(
                        if (success) R.string.done else discardAction,
                    ),
                )
            }
        }
    }
}

@Composable
internal fun FileServiceMutationFailureCard(
    failure: DsmFailure,
    canDismiss: Boolean = true,
    canContinueEditing: Boolean,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    SettingsMutationFailureCard(
        failure = failure,
        canDismiss = canDismiss,
        title = R.string.file_service_feedback_failed_title,
        discardAction = R.string.discard_file_service_draft,
        canContinueEditing = canContinueEditing,
        onContinueEditing = onContinueEditing,
        onDismiss = onDismiss,
    )
}

@Composable
internal fun TerminalMutationFailureCard(
    failure: DsmFailure,
    canDismiss: Boolean = true,
    canContinueEditing: Boolean,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    SettingsMutationFailureCard(
        failure = failure,
        canDismiss = canDismiss,
        title = R.string.file_service_feedback_failed_title,
        discardAction = R.string.discard_terminal_draft,
        canContinueEditing = canContinueEditing,
        onContinueEditing = onContinueEditing,
        onDismiss = onDismiss,
    )
}

@Composable
internal fun ProxyMutationFailureCard(
    failure: DsmFailure,
    canDismiss: Boolean = true,
    canContinueEditing: Boolean,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    SettingsMutationFailureCard(
        failure = failure,
        canDismiss = canDismiss,
        title = R.string.file_service_feedback_failed_title,
        discardAction = R.string.discard_proxy_draft,
        canContinueEditing = canContinueEditing,
        onContinueEditing = onContinueEditing,
        onDismiss = onDismiss,
    )
}

@Composable
private fun SettingsMutationFailureCard(
    failure: DsmFailure,
    canDismiss: Boolean = true,
    @StringRes title: Int,
    @StringRes discardAction: Int,
    canContinueEditing: Boolean,
    onContinueEditing: () -> Unit,
    onDismiss: () -> Unit,
) {
    val localized = failure.localize(LocalContext.current)
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .semantics { liveRegion = LiveRegionMode.Assertive },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                stringResource(title),
                style = MaterialTheme.typography.titleMedium,
            )
            Text(localized.combined)
            if (canContinueEditing) {
                TextButton(onClick = onContinueEditing, modifier = Modifier.align(Alignment.End)) {
                    Text(stringResource(R.string.continue_editing))
                }
            }
            if (canDismiss) TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(discardAction))
            }
        }
    }
}

@Composable
private fun SettingsSummaryRow(
    title: String,
    detail: String,
    icon: @Composable () -> Unit,
    onEdit: () -> Unit,
    enabled: Boolean = true,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        leadingContent = icon,
        trailingContent = {
            val editDescription = stringResource(R.string.nas_edit_settings_accessibility, title)
            TextButton(onClick = onEdit, enabled = enabled, modifier = Modifier.semantics { contentDescription = editDescription }) {
                Icon(Icons.Outlined.Edit, null)
                Text(stringResource(R.string.edit))
            }
        },
    )
    HorizontalDivider(Modifier.padding(start = 72.dp))
}

@Composable
private fun SettingsUnavailableRow(
    title: String,
    detail: String,
    icon: @Composable () -> Unit,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        leadingContent = icon,
    )
    HorizontalDivider(Modifier.padding(start = 72.dp))
}

@Composable
private fun fileServiceSummary(value: NasFileServiceSettings): String {
    val enabled = listOfNotNull(
        stringResource(R.string.smb_short_name).takeIf { value.isSmbEnabled == true },
        stringResource(R.string.nfs_short_name).takeIf { value.isNfsEnabled == true },
        stringResource(R.string.ftp_short_name).takeIf { value.isFtpEnabled == true },
        stringResource(R.string.ftps_short_name).takeIf { value.isFtpsEnabled == true },
        stringResource(R.string.sftp_short_name).takeIf { value.isSftpEnabled == true },
    )
    return enabled.joinToString(" · ").ifBlank { stringResource(R.string.all_file_services_disabled) }
}

@Composable
private fun terminalSummary(value: NasTerminalSettings): String = listOfNotNull(
    stringResource(R.string.ssh_short_name).takeIf { value.isSshEnabled },
    stringResource(R.string.telnet_short_name).takeIf { value.isTelnetEnabled },
).joinToString(" · ").ifBlank { stringResource(R.string.service_disabled) }
