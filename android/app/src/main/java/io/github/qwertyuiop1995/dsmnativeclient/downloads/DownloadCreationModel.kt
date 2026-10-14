package io.github.qwertyuiop1995.dsmnativeclient.downloads

import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class DownloadCreationFormState(
    val visible: Boolean = false, val uri: String = "", val title: String? = null,
    val destination: String = "", val password: String = "", val filename: String? = null,
    val copying: Boolean = false, val failure: DsmFailure? = null,
)

/** 表单绑定打开时连接；任务文件先复制到私有临时目录，选择文件本身不发送请求。 */
internal class DownloadCreationModel(
    private val scope: CoroutineScope, private val connection: () -> Any?,
    private val directory: () -> File, private val actions: DownloadActionModel,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutable = MutableStateFlow(DownloadCreationFormState())
    val state = mutable.asStateFlow()
    private var owner: Any? = null
    private var generation = 0L
    private var source: UploadSource? = null
    private var file: File? = null
    private var job: Job? = null
    fun open(uri: String = "", title: String? = null): Boolean {
        val current = connection() ?: return false
        clear(); owner = current
        mutable.value = DownloadCreationFormState(visible = true, uri = uri, title = title)
        return true
    }
    fun update(uri: String = state.value.uri, destination: String = state.value.destination, password: String = state.value.password) {
        if (!current() || state.value.copying) return
        mutable.update { it.copy(uri = uri.take(16_384), destination = destination.take(2_048), password = password, failure = null) }
    }
    fun clear() {
        generation++; job?.cancel(); job = null; owner = null; source = null; file?.delete(); file = null
        mutable.value = DownloadCreationFormState()
    }
    val selectionToken: Long get() = generation
    fun chooseFile(expectedToken: Long = generation, resolve: suspend () -> UploadSource): Boolean {
        if (!current() || !state.value.visible || expectedToken != generation || state.value.copying) return false
        val token = generation
        mutable.update { it.copy(copying = true, failure = null) }
        job = scope.launch(dispatcher) {
            var copy: File? = null
            try {
                val original = resolve()
                val extension = original.displayName.substringAfterLast('.', "").lowercase()
                if (extension !in setOf("torrent", "nzb", "txt") || original.contentLength !in 1..100L * 1024 * 1024) {
                    throw DsmFailure(null, "This file cannot create downloads", "Choose a torrent, NZB, or text file up to 100 MB.", kind = DsmErrorKind.UPLOAD_FAILED)
                }
                val folder = directory().also { check(it.mkdirs() || it.isDirectory) }
                copy = File(folder, "${UUID.randomUUID()}.$extension")
                var count = 0L
                original.openInputStream().use { input -> copy.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val length = input.read(buffer); if (length < 0) break
                        count += length
                        if (count > original.contentLength) throw DsmFailure(null, "The file changed while opening it", "Choose the file again.", kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH)
                        output.write(buffer, 0, length)
                    }
                } }
                if (count != original.contentLength) throw DsmFailure(null, "The complete file could not be opened", "Choose the file again.", kind = DsmErrorKind.UPLOAD_LENGTH_MISMATCH)
                if (!current() || token != generation) return@launch
                file?.delete(); file = copy
                val kept = copy
                source = original.copy(openInputStream = { kept.inputStream() })
                mutable.update { it.copy(filename = original.displayName, uri = "", title = null, copying = false) }
                copy = null
            } catch (_: CancellationException) { }
            catch (error: Exception) { if (current() && token == generation) mutable.update { it.copy(copying = false, failure = error.asDsmFailure()) } }
            finally { copy?.delete() }
        }
        return true
    }
    fun useLink() {
        if (!current() || state.value.copying) return
        source = null; file?.delete(); file = null
        mutable.update { it.copy(filename = null, password = "") }
    }
    fun submit(): Boolean {
        if (!current() || state.value.copying) return false
        val draft = state.value
        val prepared = source
        val ownedFile = file
        val accepted = if (prepared != null) actions.createFile(prepared, draft.destination.takeIf(String::isNotEmpty),
            draft.password.takeIf(String::isNotEmpty), cleanup = { ownedFile?.delete() })
        else if (draft.uri.isNotBlank()) actions.createLink(draft.uri, draft.destination.takeIf(String::isNotEmpty)) else false
        if (accepted) { file = null; clear(); actions.show() }
        return accepted
    }
    private fun current(): Boolean = owner != null && owner === connection()
}
