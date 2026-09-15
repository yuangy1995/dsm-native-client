package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoPreviewState(
    val photo: SynologyPhoto? = null,
    val image: ByteArray? = null,
    val source: RandomAccessMediaSource? = null,
    val loading: Boolean = false,
    val playingMotion: Boolean = false,
    val error: Throwable? = null,
    val saving: Boolean = false,
    val saveProgress: Double? = null,
    val exportFile: File? = null,
    val saveError: Throwable? = null,
    val saved: Boolean = false,
)

/** 大图、媒体源与导出各自持有代次，不允许上一张照片的迟到结果替换当前预览。 */
internal class SynologyPhotoPreviewModel(
    private val repository: SynologyPhotosServing,
    private val scope: CoroutineScope,
    private val items: () -> List<SynologyPhoto>,
) {
    private val mutable = MutableStateFlow(SynologyPhotoPreviewState())
    val state = mutable.asStateFlow()
    private var generation = 0L
    private var previewJob: Job? = null
    @Volatile private var exportGeneration = 0L
    private var exportJob: Job? = null
    private var exportDirectory: File? = null

    fun open(photo: SynologyPhoto, playMotion: Boolean = false): Job? {
        if (photo.id.profileId != repository.profileId || photo.id.space != SynologyPhotoSpace.PERSONAL) return null
        closePreview()
        val token = generation
        mutable.update { it.copy(photo = photo, loading = true, playingMotion = playMotion) }
        previewJob = scope.launch {
            try {
                val detail = repository.details(photo)
                checkCurrent(token)
                mutable.update { it.copy(photo = detail) }
                if (detail.mediaType == "video" || (detail.mediaType == "live" && playMotion)) {
                    val source = repository.videoSource(detail)
                    try { checkCurrent(token) } catch (error: Throwable) { source.close(); throw error }
                    mutable.update { it.copy(source = source) }
                } else {
                    val data = repository.thumbnail(detail, large = true)
                    checkCurrent(token)
                    mutable.update { it.copy(image = data) }
                }
            } catch (error: Exception) {
                if (error !is CancellationException && token == generation) mutable.update { it.copy(error = error) }
            } finally { if (token == generation) mutable.update { it.copy(loading = false) } }
        }
        return previewJob
    }

    fun toggleMotion() {
        val photo = state.value.photo?.takeIf { it.mediaType == "live" } ?: return
        if (state.value.playingMotion) {
            generation++; previewJob?.cancel(); state.value.source?.close()
            mutable.update { it.copy(source = null, playingMotion = false, loading = false, error = null) }
            if (state.value.image == null) open(photo)
            return
        }
        val token = ++generation
        previewJob?.cancel()
        mutable.update { it.copy(loading = true, playingMotion = true, error = null) }
        previewJob = scope.launch {
            try {
                val source = repository.videoSource(photo)
                try { checkCurrent(token) } catch (error: Throwable) { source.close(); throw error }
                mutable.update { it.copy(source = source) }
            } catch (error: Exception) {
                if (error !is CancellationException && token == generation) mutable.update { it.copy(error = error, playingMotion = false) }
            } finally { if (token == generation) mutable.update { it.copy(loading = false) } }
        }
    }

    fun adjacent(direction: Int) {
        val photos = items()
        val index = photos.indexOfFirst { it.id == state.value.photo?.id }
        if (index >= 0 && index + direction in photos.indices) open(photos[index + direction])
    }
    fun canMove(direction: Int): Boolean {
        val photos = items()
        val index = photos.indexOfFirst { it.id == state.value.photo?.id }
        return index >= 0 && index + direction in photos.indices
    }

    fun closePreview() {
        generation++; previewJob?.cancel(); previewJob = null
        state.value.source?.close()
        mutable.update { it.copy(photo = null, source = null, image = null, loading = false, error = null, playingMotion = false) }
    }

    /** 先校验原件，再交给系统“创建文档”；失败不碰用户选择的文件。 */
    fun prepareExport(photo: SynologyPhoto, cacheDirectory: File): Job? {
        if (state.value.saving || photo.id.profileId != repository.profileId) return null
        cancelExport()
        val token = ++exportGeneration
        mutable.update { it.copy(saving = true, saveError = null, saved = false, saveProgress = null) }
        exportJob = scope.launch {
            var directory: File? = null
            try {
                val destination = withContext(Dispatchers.IO) {
                    val name = safeFilename(photo.filename)
                    val folder = Files.createTempDirectory(cacheDirectory.toPath(), "synology-photos-").toFile()
                    directory = folder
                    File(folder, name)
                }
                repository.downloadOriginal(photo, destination) { done, total ->
                    if (token == exportGeneration) mutable.update { it.copy(saveProgress = if (total > 0) minOf(1.0, done.toDouble() / total) else null) }
                }
                currentCoroutineContext().ensureActive()
                if (token != exportGeneration) throw CancellationException()
                exportDirectory = directory
                mutable.update { it.copy(exportFile = destination) }
            } catch (error: Exception) {
                withContext(NonCancellable + Dispatchers.IO) { directory?.deleteRecursively() }
                if (error !is CancellationException && token == exportGeneration) mutable.update { it.copy(saveError = error) }
            } finally { if (token == exportGeneration) mutable.update { it.copy(saving = false) } }
        }
        return exportJob
    }

    /** 输出目的地由 UI 的系统选择器提供；不把 URI 或真实文件内容写入日志。 */
    fun finishExport(error: Throwable? = null, saved: Boolean = false) {
        cancelExport()
        mutable.update { it.copy(saveError = error, saved = saved) }
    }

    fun cancelExport() {
        exportGeneration++; exportJob?.cancel(); exportJob = null
        val directory = exportDirectory
        exportDirectory = null
        mutable.update { it.copy(exportFile = null, saving = false, saveProgress = null) }
        if (directory != null) scope.launch(NonCancellable + Dispatchers.IO) { directory.deleteRecursively() }
    }

    fun deactivate(preservePreparedExport: Boolean = false) {
        closePreview()
        // 系统文档选择器会让 Activity 暂停；已校验的临时原件由选择器结果负责释放。
        if (!preservePreparedExport || state.value.exportFile == null) cancelExport()
    }
    private suspend fun checkCurrent(token: Long) { currentCoroutineContext().ensureActive(); if (token != generation) throw CancellationException() }

    private fun safeFilename(value: String): String {
        val name = value.substringAfterLast('/').substringAfterLast('\\')
        if (name.isEmpty() || name == "." || name == ".." || name.any { it.code < 32 }) {
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
        }
        return name
    }
}
