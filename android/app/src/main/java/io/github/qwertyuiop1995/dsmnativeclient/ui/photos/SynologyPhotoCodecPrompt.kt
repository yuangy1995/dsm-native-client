package io.github.qwertyuiop1995.dsmnativeclient.ui.photos

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientPageDialog

@Composable
internal fun SynologyPhotoCodecPrompt(model: SynologyPhotoCodecPromptModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientPageDialog(stringResource(R.string.sp_codec_title), model::dismiss) {
        if (state.loading && state.prompt == null && state.records.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        } else LazyColumn(Modifier.fillMaxSize().testTag("photos_codec_list"), contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                OutlinedButton(onClick = { model.load() }, enabled = !state.loading && !state.working && state.confirmation == null,
                    modifier = Modifier.testTag("photos_codec_refresh")) { Text(stringResource(R.string.sp_edit_refresh)) }
            }
            if (state.loading || state.working) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            state.error?.let { error -> item { Text(codecPromptError(error), color = MaterialTheme.colorScheme.error) } }
            state.prompt?.let { prompt -> item {
                if (!prompt.shouldShow) Text(stringResource(R.string.sp_codec_empty))
                else Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.sp_codec_available))
                    if (!model.canGenerate) Text(stringResource(R.string.sp_codec_generation_unavailable), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val enabled = !state.loading && !state.working && !state.pending && state.confirmation == null
                    OutlinedButton(onClick = model::requestGeneration, enabled = enabled && model.canGenerate,
                        modifier = Modifier.testTag("photos_codec_generate")) { Text(stringResource(R.string.sp_codec_generate)) }
                    OutlinedButton(onClick = { model.later() }, enabled = enabled,
                        modifier = Modifier.testTag("photos_codec_later")) { Text(stringResource(R.string.sp_codec_later)) }
                }
            } }
            items(state.records, key = { it.id }) { record ->
                val row = record.checkpoint; val value = row.codecPrompt!!
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    HorizontalDivider()
                    Text(stringResource(if (value.generate) R.string.sp_codec_generate else R.string.sp_codec_later), style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(when {
                        row.phase == SynologyPhotoAlbumPhase.COMPLETED -> if (value.generate) R.string.sp_codec_received else R.string.sp_codec_saved
                        value.generationRejected || !value.generate && value.promptAttempts > 0 && value.promptAttempts == value.promptRejections -> R.string.sp_codec_rejected
                        value.canContinue -> R.string.sp_codec_partial
                        value.generationAcknowledged -> R.string.sp_codec_save_unknown
                        !value.generationAttempted && value.promptAttempts == 0 -> R.string.sp_codec_not_sent
                        else -> R.string.sp_codec_unknown
                    }))
                    val enabled = !state.working && !state.loading
                    if (value.canContinue) OutlinedButton(onClick = { model.continuePrompt(record.id) }, enabled = enabled,
                        modifier = Modifier.testTag("photos_codec_continue")) { Text(stringResource(R.string.sp_codec_continue)) }
                    if (row.submitted && !row.finished) OutlinedButton(onClick = { model.resume(record.id) }, enabled = enabled,
                        modifier = Modifier.testTag("photos_codec_review")) { Text(stringResource(R.string.sp_edit_refresh)) }
                    if (!row.submitted || row.finished) TextButton(onClick = { model.discard(record.id) }, enabled = enabled,
                        modifier = Modifier.testTag("photos_codec_clear")) { Text(stringResource(R.string.sp_edit_clear_record)) }
                }
            }
        }
    }
    state.confirmation?.let { prompt ->
        AlertDialog(onDismissRequest = model::cancelConfirmation,
            title = { Text(stringResource(R.string.sp_codec_generate)) },
            text = { Text(stringResource(if (prompt.isAdministrator) R.string.sp_codec_all_users_risk else R.string.sp_codec_personal_risk),
                Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = { model.confirm() }, enabled = !state.working,
                modifier = Modifier.testTag("photos_codec_confirm")) { Text(stringResource(R.string.sp_codec_generate)) } },
            dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun codecPromptError(error: Throwable): String = when (error) {
    is SynologyPhotoAlbumFailure -> photoAlbumError(error)
    is SynologyPhotoFailure -> stringResource(when (error.kind) {
        SynologyPhotoFailureKind.PERMISSION -> R.string.sp_codec_permission
        SynologyPhotoFailureKind.TARGET_CHANGED -> R.string.sp_codec_changed
        else -> R.string.sp_codec_failed
    })
    else -> stringResource(R.string.sp_codec_failed)
}
