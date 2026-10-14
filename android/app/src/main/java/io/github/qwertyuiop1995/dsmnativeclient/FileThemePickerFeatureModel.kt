package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.OpenableColumns
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.io.File
import java.util.UUID

internal enum class FileThemePickerSource { HISTORY, NAS, DEFAULT, LOCAL }
internal data class FileThemePickerEntry(val id: String, val name: String, val image: FileThemeImage? = null, val folder: FileItem? = null)
internal data class FileThemePickerState(
    val kind: FileThemeImageKind? = null, val source: FileThemePickerSource = FileThemePickerSource.HISTORY,
    val path: String = "", val filter: String = "", val rows: Loadable<List<FileThemePickerEntry>> = Loadable.Idle,
    val nextOffset: Int = 0, val total: Int = 0, val loadingMore: Boolean = false,
    val selected: FileThemeImage? = null, val local: FileThemeUpload? = null, val preview: Loadable<Bitmap> = Loadable.Idle,
    val busy: Boolean = false, val unknownUpload: Boolean = false, val failure: DsmFailure? = null,
)

/** 选图只影响草稿；读取与系统选图回调固定原工作区，上传和页面保存分别确认。 */
internal class FileThemePickerFeatureModel(private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val canOpen: () -> Boolean, private val onBusy: (Boolean) -> Unit, private val onSelect: (FileThemeImage) -> Unit) {
    private val _state = MutableStateFlow(FileThemePickerState()); val state = _state.asStateFlow()
    private var active: DsmRepository? = null
    private var generation = 0L
    private var selectionId = UUID.randomUUID().toString()
    private var readJob: Job? = null; private var previewJob: Job? = null; private var uploadJob: Job? = null
    private var directory: File? = null; private var displayPixels = 1
    private var listedPaths = emptySet<String>()
    fun open(kind: FileThemeImageKind, cache: File, pixels: Int) {
        val repo = repository() ?: return
        if (!canOpen() || !repo.fileSettings.supportsThemeImages() || pixels <= 0) return
        invalidate(); active = repo; displayPixels = pixels
        directory = File(cache, "file-theme-${UUID.randomUUID()}")
        _state.value = FileThemePickerState(kind = kind); reload()
    }
    fun source(value: FileThemePickerSource) {
        if (!editable() || value == _state.value.source || value == FileThemePickerSource.DEFAULT && _state.value.kind != FileThemeImageKind.BACKGROUND) return
        cancelReads(); clearLocal()
        _state.update { it.copy(source = value, path = "", filter = "", rows = Loadable.Idle, selected = null, local = null,
            preview = Loadable.Idle, unknownUpload = false, failure = null, total = 0, nextOffset = 0) }
        reload()
    }
    fun filter(value: String) { if (editable()) _state.update { it.copy(filter = value) } }
    fun reload() {
        if (!editable()) return
        cancelReads(); listedPaths = emptySet()
        _state.update { it.copy(rows = Loadable.Loading, selected = null, preview = Loadable.Idle, failure = null, total = 0, nextOffset = 0, loadingMore = false) }
        load(false)
    }
    fun more() { if (editable() && !_state.value.loadingMore && _state.value.nextOffset < _state.value.total) load(true) }
    private fun load(more: Boolean) {
        val repo = current() ?: return; val ticket = generation; val value = _state.value; val kind = value.kind ?: return
        _state.update { it.copy(loadingMore = more, failure = null) }
        readJob = scope.launch {
            var next = 0; var total = 0; var paths = emptySet<String>()
            val result = captureLoadable {
                when (value.source) {
                    FileThemePickerSource.HISTORY -> repo.fileSettings.images.history(kind).map { FileThemePickerEntry(it.path, it.name, image = it) }
                    FileThemePickerSource.DEFAULT -> FileThemeImage.defaults.map { FileThemePickerEntry(it.path, it.name, image = it) }
                    FileThemePickerSource.LOCAL -> emptyList()
                    FileThemePickerSource.NAS -> {
                        val offset = if (more) value.nextOffset else 0
                        val page = if (value.path.isEmpty()) repo.listShares(offset = offset) else repo.listDirectory(value.path, offset = offset)
                        paths = page.items.map { it.path }.toSet()
                        if (page.offset != offset || page.items.size > 200 || page.total < offset || page.items.size > page.total - offset ||
                            page.items.isEmpty() && offset < page.total || paths.size != page.items.size ||
                            more && (page.total != value.total || paths.any { it in listedPaths })) throw settingsChanged()
                        next = offset + page.items.size; total = page.total
                        page.items.filter { it.isDirectory || FileThemeImage.supportsFilename(it.name) }.map { row ->
                            if (row.isDirectory) FileThemePickerEntry(row.path, row.name, folder = row)
                            else FileThemePickerEntry(row.path, row.name, image = FileThemeImage(kind, FileThemeImageSource.NAS, row.path, row.name))
                        }
                    }
                }
            }
            if (!valid(repo, ticket)) return@launch
            if (result is Loadable.Ready) listedPaths = listedPaths + paths
            _state.update { it.copy(rows = if (more && result is Loadable.Ready) Loadable.Ready((value.rows as? Loadable.Ready)?.value.orEmpty() + result.value)
                else if (more && result is Loadable.Failed) it.rows else result,
                nextOffset = if (result is Loadable.Ready) next else it.nextOffset, total = if (result is Loadable.Ready) total else it.total,
                loadingMore = false, failure = if (more && result is Loadable.Failed) result.error else null) }
        }
    }
    fun enter(row: FileThemePickerEntry) {
        if (!editable() || row !in (_state.value.rows as? Loadable.Ready)?.value.orEmpty()) return
        if (row.folder != null) {
            if (!row.folder.canRead) return
            _state.update { it.copy(path = row.folder.path, filter = "") }; reload()
        } else row.image?.let(::preview)
    }
    fun up() { if (editable() && _state.value.path.isNotEmpty()) { _state.update { it.copy(path = it.path.substringBeforeLast('/', ""), filter = "") }; reload() } }
    fun location(path: String) {
        if (editable() && (path.isEmpty() || _state.value.path.startsWith("$path/"))) {
            _state.update { it.copy(path = path, filter = "") }; reload()
        }
    }
    private fun preview(image: FileThemeImage) {
        val repo = current() ?: return; val folder = directory ?: return
        cancelReads(); val ticket = generation
        _state.update { it.copy(selected = image, local = null, preview = Loadable.Loading, failure = null, loadingMore = false) }
        previewJob = scope.launch {
            val result = captureLoadable { withContext(Dispatchers.IO) {
                folder.mkdirs(); val file = File.createTempFile("preview-", ".image", folder)
                try { repo.fileSettings.images.download(image, file); themePreview(file, displayPixels) } finally { file.delete() }
            } }
            if (valid(repo, ticket)) _state.update { it.copy(preview = result) }
        }
    }
    fun retryPreview() { if (editable()) _state.value.selected?.let(::preview) }
    fun selectionTicket(): String? = if (editable() && _state.value.source == FileThemePickerSource.LOCAL) "$selectionId:$generation" else null
    fun importLocal(context: Context, uri: Uri, ticket: String) {
        val repo = current() ?: return; val folder = directory ?: return
        if (ticket != selectionTicket()) return
        clearLocal(); previewJob?.cancel(); val localTicket = ++generation
        _state.update { it.copy(selected = null, local = null, preview = Loadable.Loading, unknownUpload = false, failure = null) }
        previewJob = scope.launch {
            var prepared: FileThemeUpload? = null
            val result = captureLoadable { withContext(Dispatchers.IO) {
                val resolver = context.contentResolver
                val filename = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let(cursor::getString) else null
                } ?: throw settingsInvalid()
                folder.mkdirs(); val file = File.createTempFile("selected-", ".image", folder)
                try {
                    val input = resolver.openInputStream(uri) ?: throw settingsInvalid()
                    input.use { source -> file.outputStream().buffered().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) { currentCoroutineContext().ensureActive(); val count = source.read(buffer); if (count < 0) break; output.write(buffer, 0, count) }
                    } }
                    val upload = prepareThemeUpload(file, filename); val bitmap = themePreview(file, displayPixels)
                    prepared = upload; bitmap
                } catch (error: Throwable) { file.delete(); throw error }
            } }
            if (valid(repo, localTicket)) _state.update { it.copy(preview = result, local = if (result is Loadable.Ready) prepared else null) }
            else prepared?.file?.delete()
        }
    }
    fun canChoose() = editable() && _state.value.preview is Loadable.Ready && _state.value.selected != null
    fun choose() { if (canChoose()) { val image = _state.value.selected!!; onSelect(image); close() } }
    fun canUpload() = editable() && _state.value.preview is Loadable.Ready && _state.value.local != null && !_state.value.unknownUpload
    fun upload() {
        val repo = current() ?: return; val value = _state.value; val input = value.local ?: return; val kind = value.kind ?: return
        if (!canUpload()) return
        cancelReads(); val ticket = generation
        _state.update { it.copy(busy = true, failure = null) }; onBusy(true)
        uploadJob = scope.launch {
            var selected: FileThemeImage? = null
            try {
                val result = repo.fileSettings.uploadThemeImageResult(input, kind, true)
                if (valid(repo, ticket)) {
                    selected = result.image
                    _state.update { it.copy(unknownUpload = result.status == FileSettingsOutcomeStatus.UNKNOWN, failure = result.failure) }
                }
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (valid(repo, ticket)) _state.update { it.copy(failure = error.asDsmFailure(), unknownUpload =
                    error is DsmFailure && error.kind == DsmErrorKind.FILE_SETTINGS_PENDING) }
            } finally {
                if (valid(repo, ticket)) { _state.update { it.copy(busy = false) }; onBusy(false) }
            }
            if (valid(repo, ticket) && selected != null) { onSelect(selected!!); close() }
        }
    }
    fun close() { if (!_state.value.busy) invalidate() }
    fun back() {
        if (!editable()) return
        if (_state.value.preview !is Loadable.Idle) {
            cancelReads(); clearLocal(); _state.update { it.copy(selected = null, local = null, preview = Loadable.Idle, unknownUpload = false, failure = null) }
        } else if (_state.value.source == FileThemePickerSource.NAS && _state.value.path.isNotEmpty()) up() else close()
    }
    fun invalidate() {
        val pendingRead = readJob; val pendingPreview = previewJob; val pendingUpload = uploadJob; val folder = directory
        cancelReads()
        if (_state.value.busy && repository() === active) onBusy(false)
        active = null; directory = null; uploadJob = null; selectionId = UUID.randomUUID().toString(); _state.value = FileThemePickerState()
        if (folder != null) scope.launch(Dispatchers.IO + NonCancellable) { pendingRead?.join(); pendingPreview?.join(); pendingUpload?.join(); folder.deleteRecursively() }
    }
    private fun clearLocal() { _state.value.local?.file?.let { file -> scope.launch(Dispatchers.IO) { file.delete() } } }
    private fun cancelReads() { generation++; readJob?.cancel(); previewJob?.cancel() }
    private fun editable() = current() != null && !_state.value.busy
    private fun valid(repo: DsmRepository, ticket: Long) = current() === repo && generation == ticket
    private fun current(): DsmRepository? = active?.takeIf { repository() === it && runCatching(it::requireCurrentOwner).isSuccess }
}
