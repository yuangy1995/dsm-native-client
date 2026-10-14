package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoPreviewState(
    val photo: SynologyPhoto? = null,
    val image: ByteArray? = null,
    val source: RandomAccessMediaSource? = null,
    val loading: Boolean = false,
    val imageReady: Boolean = false,
    val rotationDegrees: Float = 0f,
    val playingMotion: Boolean = false,
    val error: Throwable? = null,

)

/** 大图与媒体源持有独立代次，不允许上一张照片的迟到结果替换当前预览。 */
internal class SynologyPhotoPreviewModel(
    private val repository: SynologyPhotosServing,
    private val scope: CoroutineScope,
    private val items: () -> List<SynologyPhoto>,
) {
    private val mutable = MutableStateFlow(SynologyPhotoPreviewState())
    val state = mutable.asStateFlow()
    private var generation = 0L
    private var previewJob: Job? = null

    fun open(photo: SynologyPhoto, playMotion: Boolean = false, preserveRotation: Boolean = false): Job? {
        if (photo.id.profileId != repository.profileId) return null
        val previous = state.value.takeIf { preserveRotation && it.photo?.id == photo.id }
        closePreview()
        val token = generation
        mutable.update { it.copy(photo = photo, loading = true, playingMotion = playMotion,
            image = previous?.image, rotationDegrees = previous?.rotationDegrees ?: 0f) }
        previewJob = scope.launch {
            try {
                val detail = repository.details(photo)
                checkCurrent(token)
                mutable.update { it.copy(photo = detail) }
                if (detail.mediaType == "video" || (detail.canPlayMotion && playMotion)) {
                    val source = repository.videoSource(detail)
                    try { checkCurrent(token) } catch (error: Throwable) { source.close(); throw error }
                    mutable.update { it.copy(source = source) }
                } else {
                    val data = repository.thumbnail(detail, large = true)
                    checkCurrent(token)
                    mutable.update { it.copy(image = data, rotationDegrees = 0f, playingMotion = false) }
                }
            } catch (error: Exception) {
                if (error !is CancellationException && token == generation) mutable.update { it.copy(error = error) }
            } finally { if (token == generation) mutable.update { it.copy(loading = false) } }
        }
        return previewJob
    }

    fun imageReady(data: ByteArray) {
        if (state.value.image === data && !state.value.loading) mutable.update { it.copy(imageReady = true) }
    }

    fun beginRotation(photo: SynologyPhoto) {
        if (state.value.photo != photo) return
        if (state.value.playingMotion) toggleMotion()
        mutable.update { it.copy(rotationDegrees = -90f) }
    }

    fun clearRotation() { mutable.update { it.copy(rotationDegrees = 0f) } }

    fun toggleMotion() {
        val photo = state.value.photo?.takeIf { it.canPlayMotion } ?: return
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
        mutable.update { it.copy(photo = null, source = null, image = null, loading = false, error = null, playingMotion = false, imageReady = false, rotationDegrees = 0f) }
    }

    fun deactivate() { closePreview() }
    private suspend fun checkCurrent(token: Long) { currentCoroutineContext().ensureActive(); if (token != generation) throw CancellationException() }
}
