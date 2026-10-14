package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.chat.*
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.ui.components.ClientSheet

@Composable
internal fun ChatVoicePanel(model: ChatVoiceModel) {
    val state by model.state.collectAsState()
    if (!state.visible) return
    ClientSheet(stringResource(R.string.chat_voice), model::cancel, dismissEnabled = !state.saving) {
        if (state.channelTitle.isNotBlank()) Text(state.channelTitle)
        Text(stringResource(R.string.chat_voice_duration, state.seconds / 60, state.seconds % 60), style = MaterialTheme.typography.headlineMedium)
        if (state.recording) Text(stringResource(R.string.chat_voice_limit))
        if (state.saving) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.error?.let { Text(stringResource(when (it) {
            ChatVoiceError.PERMISSION -> R.string.chat_voice_permission
            ChatVoiceError.RECORDING -> R.string.chat_voice_recording_error
            ChatVoiceError.PLAYBACK -> R.string.chat_voice_playback_error
        }), color = MaterialTheme.colorScheme.error) }
        state.failure?.let {
            Text(it.localize(LocalContext.current).combined, color = MaterialTheme.colorScheme.error)
            TextButton(onClick = model::retrySave, enabled = !state.saving, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.retry)) }
        }
        if (state.error == ChatVoiceError.PERMISSION) {
            val context = LocalContext.current
            TextButton(onClick = { context.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:${context.packageName}"))) }, modifier = Modifier.heightIn(min = 48.dp)) { Text(stringResource(R.string.chat_voice_open_settings)) }
        }
        if (state.recording) Button(onClick = model::stop, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.chat_voice_stop)) }
        else if (state.draftId != null) {
            OutlinedButton(onClick = model::play, modifier = Modifier.fillMaxWidth()) { Text(stringResource(if (state.playing) R.string.chat_voice_stop_playback else R.string.chat_voice_preview)) }
            Button(onClick = model::send, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.send_message)) }
        }
        TextButton(onClick = model::cancel, enabled = !state.saving, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(stringResource(R.string.cancel)) }
    }
}
