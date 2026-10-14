package io.github.qwertyuiop1995.dsmnativeclient.chat

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal enum class ChatVoiceError { PERMISSION, RECORDING, PLAYBACK }
internal data class ChatVoiceState(val visible: Boolean = false, val channelTitle: String = "", val recording: Boolean = false,
    val playing: Boolean = false, val saving: Boolean = false, val seconds: Int = 0, val draftId: String? = null,
    val error: ChatVoiceError? = null, val failure: DsmFailure? = null)

/** 只在用户点击后录音；停止/退后台释放麦克风，确认发送前保存独立草稿。 */
internal class ChatVoiceModel(private val context: Context, private val scope: CoroutineScope,
    private val actions: ChatActionModel, private val ownerProvider: () -> WorkspaceOwner?) {
    private val mutable = MutableStateFlow(ChatVoiceState())
    val state = mutable.asStateFlow()
    private var recorder: MediaRecorder? = null
    private var player: MediaPlayer? = null
    private var timer: Job? = null
    private var saving: Job? = null
    private var file: File? = null
    private var owner: WorkspaceOwner? = null
    private var channel: String? = null
    private var filename = ""
    private var startedAt = 0L

    fun permissionDenied() { mutable.value = ChatVoiceState(visible = true, error = ChatVoiceError.PERMISSION) }
    fun start(channelId: String, title: String, name: String) {
        if (state.value.recording || state.value.saving) return
        if (file != null) { mutable.update { it.copy(visible = true) }; return }
        val currentOwner = ownerProvider() ?: return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) { permissionDenied(); return }
        val directory = File(context.cacheDir, "chat-voice/${chatTextDigest(currentOwner.profileId + currentOwner.identityRevision)}")
        if (!directory.isDirectory && !directory.mkdirs()) { mutable.value = ChatVoiceState(visible = true, error = ChatVoiceError.RECORDING); return }
        val target = File(directory, UUID.randomUUID().toString() + ".m4a")
        owner = currentOwner; channel = channelId; filename = name; file = target
        mutable.value = ChatVoiceState(visible = true, channelTitle = title)
        try {
            @Suppress("DEPRECATION")
            val recording = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
            recorder = recording
            recording.setAudioSource(MediaRecorder.AudioSource.MIC)
            recording.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recording.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recording.setAudioSamplingRate(44_100)
            recording.setAudioEncodingBitRate(96_000)
            recording.setOutputFile(target.absolutePath)
            recording.setMaxDuration(300_000)
            recording.setOnInfoListener { _, what, _ -> if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) stop() }
            recording.setOnErrorListener { _, _, _ -> recordingFailed() }
            recording.prepare(); recording.start()
            startedAt = SystemClock.elapsedRealtime()
            mutable.update { it.copy(recording = true) }
            timer = scope.launch { while (state.value.recording) { delay(250)
                val elapsed = ((SystemClock.elapsedRealtime() - startedAt) / 1000).toInt().coerceIn(0, 300)
                mutable.update { it.copy(seconds = elapsed) }
                if (elapsed >= 300) stop()
            } }
        } catch (_: Exception) { recordingFailed() }
    }
    fun stop() {
        val active = recorder ?: return
        recorder = null; timer?.cancel(); timer = null
        try { active.stop() } catch (_: Exception) { active.release(); recordingFailed(); return }
        active.release()
        saveRecording()
    }
    fun retrySave() { if (!state.value.saving && !state.value.recording) saveRecording() }
    private fun saveRecording() {
        val audio = file?.takeIf { it.isFile && it.length() > 0 } ?: run { recordingFailed(); return }
        val originalOwner = owner ?: return
        val channelId = channel ?: return
        mutable.update { it.copy(recording = false, saving = true, failure = null) }
        saving = scope.launch {
            try {
                val source = UploadSource(filename, "audio/mp4", audio.length(), { audio.inputStream() })
                val id = actions.saveUnsent(ChatActionDraft(ChatActionKind.ATTACHMENT, channelId, attachment = source), originalOwner)
                if (owner == originalOwner && file === audio) mutable.update { it.copy(saving = false, draftId = id) }
            } catch (error: Exception) {
                if (error !is CancellationException && owner == originalOwner && file === audio) mutable.update { it.copy(saving = false, failure = error.asDsmFailure()) }
            }
        }
    }
    fun play() {
        if (state.value.recording || state.value.saving) return
        if (state.value.playing) { stopPlayback(); return }
        val audio = file ?: return
        try {
            val playback = MediaPlayer(); player = playback
            playback.setDataSource(audio.absolutePath)
            playback.setOnCompletionListener { stopPlayback() }
            playback.setOnErrorListener { _, _, _ -> stopPlayback(); mutable.update { it.copy(error = ChatVoiceError.PLAYBACK) }; true }
            playback.prepare(); playback.start(); mutable.update { it.copy(playing = true, error = null) }
        } catch (_: Exception) { stopPlayback(); mutable.update { it.copy(error = ChatVoiceError.PLAYBACK) } }
    }
    fun send() {
        val id = state.value.draftId ?: return
        if (state.value.saving || state.value.recording || owner?.let { ownerProvider()?.hasSameIdentity(it) } != true) return
        stopPlayback()
        if (actions.resumeReady(id)) { file?.delete(); file = null; mutable.value = ChatVoiceState(); owner = null; channel = null }
    }
    fun pause() { stop(); stopPlayback() }
    fun cancel() {
        if (state.value.saving) return
        state.value.draftId?.let { if (!actions.discard(it)) return }
        clear()
    }
    fun clear() {
        timer?.cancel(); timer = null; saving?.cancel(); saving = null
        recorder?.let { runCatching { it.stop() }; it.release() }; recorder = null
        stopPlayback(); file?.delete(); file = null; owner = null; channel = null; mutable.value = ChatVoiceState()
    }
    private fun recordingFailed() {
        recorder?.let { runCatching { it.stop() }; it.release() }; recorder = null
        timer?.cancel(); timer = null; file?.delete(); file = null
        mutable.update { it.copy(recording = false, saving = false, error = ChatVoiceError.RECORDING) }
    }
    private fun stopPlayback() { player?.let { runCatching { it.stop() }; it.release() }; player = null; mutable.update { it.copy(playing = false) } }
}
