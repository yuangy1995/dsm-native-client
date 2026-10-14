package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.nio.file.Files
import java.util.UUID
import io.github.qwertyuiop1995.dsmnativeclient.background.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal sealed interface SynologyPhotoExportRequest {
    data class Items(val photos: List<SynologyPhoto>) : SynologyPhotoExportRequest
    data class Archive(val target: SynologyPhotoArchiveTarget, val filename: String) : SynologyPhotoExportRequest
}
internal enum class SynologyPhotoExportPhase { IDLE, FORMAT, PREPARING, FILE, DIRECTORY, SAVING, FINISHED }
internal data class SynologyPhotoExportState(
    val id: String? = null,
    val request: SynologyPhotoExportRequest? = null,
    val formats: List<SynologyPhotoDownloadFormat> = emptyList(),
    val format: SynologyPhotoDownloadFormat = SynologyPhotoDownloadFormat.ORIGINAL,
    val phase: SynologyPhotoExportPhase = SynologyPhotoExportPhase.IDLE,
    val file: File? = null,
    val filename: String? = null,
    val mime: String = "application/octet-stream",
    val progress: Double? = null,
    val total: Int = 0,
    val saved: Int = 0,
    val retainedOriginals: Int = 0,
    val cancelled: Boolean = false,
    val error: Throwable? = null,
) {
    val busy: Boolean get() = phase in setOf(SynologyPhotoExportPhase.PREPARING, SynologyPhotoExportPhase.FILE, SynologyPhotoExportPhase.DIRECTORY, SynologyPhotoExportPhase.SAVING)
    val awaitingPicker: Boolean get() = phase in setOf(SynologyPhotoExportPhase.FILE, SynologyPhotoExportPhase.DIRECTORY)
}

/** 目标由系统选择器授予；实现必须仅清理自己创建的未完成文件。 */
internal fun interface SynologyPhotoExportDestination {
    suspend fun save(file: File, filename: String, mime: String, checkCurrent: suspend () -> Unit)
    suspend fun abandon() {}
}

/** 单张、固定多选和完整归档共用导出队列；不改变图库选择、月份与分页。 */
internal class SynologyPhotoExportModel(
    private val repository: SynologyPhotosServing,
    private val scope: CoroutineScope,
    private val requireOwner: () -> Unit = {},
    private val canStart: () -> Boolean = { true },
    private val beforeStart: suspend (SynologyPhotoExportRequest) -> Unit = {},
    private val execution: WorkspaceExecution? = null,
    private val owner: WorkspaceOwner? = null,
) {
    private val mutable = MutableStateFlow(SynologyPhotoExportState())
    val state = mutable.asStateFlow()
    @Volatile private var generation = 0L
    private var worker: Job? = null
    private var preparedDirectory: File? = null
    private var executionLease: WorkspaceExecutionLease? = null
    private var preparedFormat: SynologyPhotoDownloadFormat? = null

    fun open(request: SynologyPhotoExportRequest, originalJPEG: Boolean = false): Boolean {
        if (state.value.busy || !canStart()) return false
        val fixed = when (request) {
            is SynologyPhotoExportRequest.Items -> {
                if (request.photos.isEmpty() || request.photos.any { it.id.profileId != repository.profileId } ||
                    request.photos.map { it.id }.toSet().size != request.photos.size) return false
                request.copy(photos = request.photos.toList())
            }
            is SynologyPhotoExportRequest.Archive -> request.copy(target = when (val target = request.target) {
                is SynologyPhotoArchiveTarget.Selection -> target.copy(photos = target.photos.toList(), folders = target.folders.toList())
                else -> target
            })
        }
        dismiss()
        val single = (fixed as? SynologyPhotoExportRequest.Items)?.photos?.singleOrNull()
        mutable.value = SynologyPhotoExportState(id = UUID.randomUUID().toString(), request = fixed,
            phase = SynologyPhotoExportPhase.FORMAT, total = (fixed as? SynologyPhotoExportRequest.Items)?.photos?.size ?: 1,
            formats = buildList {
                add(SynologyPhotoDownloadFormat.ORIGINAL)
                if (single == null || single.supportsOptimizedJPEG) add(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG)
                if (originalJPEG && single?.supportsOriginalSizeJPEG == true) add(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG)
            })
        return true
    }

    fun prepare(format: SynologyPhotoDownloadFormat, cache: File): Job? {
        val selection = state.value
        val request = selection.request ?: return null
        if (selection.phase != SynologyPhotoExportPhase.FORMAT || format !in selection.formats || !canStart()) return null
        val token = ++generation
        mutable.update { it.copy(format = format, phase = SynologyPhotoExportPhase.PREPARING, error = null) }
        worker = scope.launch {
            var directory: File? = null
            var lease: WorkspaceExecutionLease? = null
            try {
                beforeStart(request); checkCurrent(token)
                if (request is SynologyPhotoExportRequest.Items && request.photos.size > 1) {
                    mutable.update { it.copy(phase = SynologyPhotoExportPhase.DIRECTORY) }
                    return@launch
                }
                lease = owner?.let { execution?.begin(it, WorkspaceExecutionActivity.PHOTO_EXPORT) }; executionLease = lease
                createDirectory(cache) { directory = it }
                val prepared = download(request, format, directory ?: invalid(), 0, token)
                checkCurrent(token)
                preparedDirectory = directory; directory = null; preparedFormat = prepared.format
                mutable.update { it.copy(file = prepared.file, filename = prepared.name, mime = prepared.mime, phase = SynologyPhotoExportPhase.FILE) }
            } catch (error: Exception) { failed(token, error) }
            finally { try { cleanup(directory) } finally { lease?.finish(); if (executionLease === lease) executionLease = null } }
        }
        return worker
    }

    fun deliver(id: String, destination: SynologyPhotoExportDestination, cache: File): Job? {
        val selection = state.value
        if (selection.id != id || !selection.awaitingPicker) return null
        val request = selection.request ?: return null
        val token = generation
        val directory = preparedDirectory
        preparedDirectory = null
        val actual = preparedFormat
        preparedFormat = null
        mutable.update { it.copy(phase = SynologyPhotoExportPhase.SAVING, progress = null) }
        worker = scope.launch {
            var batchDirectory: File? = null
            var lease: WorkspaceExecutionLease? = null
            try {
                lease = owner?.let { execution?.begin(it, WorkspaceExecutionActivity.PHOTO_EXPORT) }; executionLease = lease
                checkCurrent(token)
                if (selection.phase == SynologyPhotoExportPhase.FILE) {
                    val file = selection.file ?: invalid()
                    save(selection, destination, file, selection.filename ?: invalid(), selection.mime, actual, token)
                } else {
                    val photos = (request as? SynologyPhotoExportRequest.Items)?.photos ?: invalid()
                    beforeStart(request); checkCurrent(token)
                    createDirectory(cache) { batchDirectory = it }
                    for (index in photos.indices) {
                        val prepared = download(request, selection.format, batchDirectory ?: invalid(), index, token)
                        checkCurrent(token)
                        save(selection, destination, prepared.file, prepared.name, prepared.mime, prepared.format, token)
                        withContext(Dispatchers.IO) { prepared.file.delete() }
                    }
                }
                checkCurrent(token)
                mutable.update { it.copy(phase = SynologyPhotoExportPhase.FINISHED, file = null, progress = null) }
            } catch (error: Exception) { failed(token, error) }
            finally { withContext(NonCancellable) { try { destination.abandon(); cleanup(directory, batchDirectory) }
                finally { lease?.finish(); if (executionLease === lease) executionLease = null } } }
        }
        return worker
    }

    private suspend fun save(selection: SynologyPhotoExportState, destination: SynologyPhotoExportDestination, file: File,
        name: String, mime: String, actual: SynologyPhotoDownloadFormat?, token: Long) {
        val caller = currentCoroutineContext()
        // 文档关闭到完成计数之间不丢失已保存结果；复制循环仍逐块检查原任务和账号。
        withContext(NonCancellable) {
            destination.save(file, name, mime) { caller.ensureActive(); checkCurrent(token) }
            mutable.update { if (it.id != selection.id) it else it.copy(saved = it.saved + 1,
                retainedOriginals = it.retainedOriginals + if (selection.format != SynologyPhotoDownloadFormat.ORIGINAL && actual == SynologyPhotoDownloadFormat.ORIGINAL) 1 else 0) }
        }
        checkCurrent(token)
    }

    fun pickerCancelled(id: String) { if (state.value.id == id && state.value.awaitingPicker) cancel() }
    fun pickerFailed(id: String, error: Throwable) {
        if (state.value.id != id || !state.value.awaitingPicker) return
        cancel(); mutable.update { it.copy(error = error, cancelled = false) }
    }
    fun cancel() {
        generation++; worker?.cancel(); worker = null
        val directory = preparedDirectory; preparedDirectory = null; preparedFormat = null
        mutable.update { it.copy(phase = SynologyPhotoExportPhase.FINISHED, file = null, progress = null, cancelled = true) }
        if (directory != null) scope.launch(NonCancellable + Dispatchers.IO) { directory.deleteRecursively() }
    }
    fun dismiss() { cancel(); mutable.value = SynologyPhotoExportState() }
    fun deactivate(preservePicker: Boolean) { if (!preservePicker || !state.value.awaitingPicker) dismiss() }
    fun requireIdle() { if (state.value.busy) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED) }

    private data class Prepared(val file: File, val name: String, val mime: String, val format: SynologyPhotoDownloadFormat)
    private suspend fun download(request: SynologyPhotoExportRequest, format: SynologyPhotoDownloadFormat, directory: File,
        index: Int, token: Long): Prepared {
        checkCurrent(token)
        val file = File(directory, "export-$index")
        mutable.update { it.copy(progress = null) }
        val progress: (Long, Long) -> Unit = { done, total -> if (token == generation) { executionLease?.update(done, total); mutable.update {
            it.copy(progress = if (total > 0) minOf(1.0, done.toDouble() / total) else null)
        } } }
        return when (request) {
            is SynologyPhotoExportRequest.Items -> {
                val photo = request.photos[index]
                val actual = repository.download(photo, format, file, progress)
                checkCurrent(token)
                val original = safeName(photo.filename)
                val name = if (actual == SynologyPhotoDownloadFormat.ORIGINAL) original else original.substringBeforeLast('.', original) + ".jpg"
                Prepared(file, name, if (actual == SynologyPhotoDownloadFormat.ORIGINAL) "application/octet-stream" else "image/jpeg", actual)
            }
            is SynologyPhotoExportRequest.Archive -> {
                repository.downloadArchive(request.target, format, file, progress)
                checkCurrent(token)
                Prepared(file, safeName(request.filename) + ".zip", "application/zip", format)
            }
        }
    }
    private suspend fun checkCurrent(token: Long) { currentCoroutineContext().ensureActive(); if (token != generation) throw CancellationException(); requireOwner() }
    private fun failed(token: Long, error: Exception) {
        if (token == generation) mutable.update { it.copy(phase = SynologyPhotoExportPhase.FINISHED, file = null,
            progress = null, error = error.takeUnless { it is CancellationException }, cancelled = error is CancellationException) }
    }
    private suspend fun createDirectory(cache: File, own: (File) -> Unit) = withContext(Dispatchers.IO) { own(Files.createTempDirectory(cache.toPath(), "synology-photos-").toFile()) }
    private suspend fun cleanup(vararg directories: File?) = withContext(NonCancellable + Dispatchers.IO) { directories.forEach { it?.deleteRecursively() } }
    private fun safeName(value: String): String = value.substringAfterLast('/').substringAfterLast('\\').also {
        if (it.isEmpty() || it == "." || it == ".." || it.any { char -> char.code < 32 }) invalid()
    }
    private fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
}
