package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoSlideshowState(
    val active: Boolean = false,
    val playing: Boolean = false,
    val loading: Boolean = false,
    val mediaToken: Long = 0,
    val ready: Boolean = false,
    val error: Throwable? = null,
)

/** 冻结原查询，以独立游标补页；预览资源复用同一加载器，不改变图库月份、分页或选择。 */
internal class SynologyPhotoSlideshowModel(
    private val repository: SynologyPhotosServing,
    private val scope: CoroutineScope,
    private val pageSize: Int,
) {
    private val mutable = MutableStateFlow(SynologyPhotoSlideshowState())
    val state = mutable.asStateFlow()
    private val photos = mutableListOf<SynologyPhoto>()
    val preview = SynologyPhotoPreviewModel(repository, scope) { photos }
    private var space = SynologyPhotoSpace.PERSONAL
    private var query: SynologyPhotoQuery? = null
    private var offset = 0
    private var hasMore = true
    val previewItems: List<SynologyPhoto> get() = photos.toList()
    val previewComplete: Boolean get() = !hasMore
    private var generation = 0L
    private var mediaSerial = 0L
    private var work: Job? = null
    private var timer: Job? = null
    private var ended = false
    private var retryDirection: Int? = null

    fun start(space: SynologyPhotoSpace, query: SynologyPhotoQuery, photo: SynologyPhoto): Job? {
        if (!belongs(photo, space, query)) return null
        stop()
        this.space = space; this.query = query
        mutable.value = SynologyPhotoSlideshowState(active = true, playing = true)
        return show(photo)
    }

    fun startGroup(detail: SynologyPhotoSimilarDetail, photo: SynologyPhoto): Job? {
        if (photo.id !in detail.photos.map { it.id } || detail.photos.any { it.id.profileId != repository.profileId ||
                it.id.space != detail.group.space || it.albumContext != null }) return null
        stop(); space = detail.group.space; photos.addAll(detail.photos); hasMore = false
        mutable.value = SynologyPhotoSlideshowState(active = true, playing = true)
        return show(photo)
    }

    suspend fun previewsUpdated(task: SynologyPhotoAutomaticPreviewTask) {
        if (!state.value.active) return
        val token = generation
        for (photo in photos.toList().filter { it.id.space == task.space && (task.source?.matches(it, includeTime = true) == true || it.thumbnail?.unitId == task.unitId) }) {
            val updated = try { repository.details(photo) } catch (error: Exception) { if (error is CancellationException) throw error; continue }
            if (generation != token || !state.value.active) return
            if (!SynologyPhotoEditTarget(photo).matches(updated, includeTime = true)) continue
            val index = photos.indexOfFirst { it.id == updated.id }; if (index >= 0) photos[index] = updated
            if (preview.state.value.photo?.id == updated.id) { work?.cancel(); show(updated) }
        }
    }

    fun togglePlaying() {
        if (!state.value.active || state.value.error != null) return
        if (state.value.playing) pause()
        else {
            mutable.update { it.copy(playing = true) }
            if (ended) move(1) else armTimer()
        }
    }

    fun pause() {
        timer?.cancel(); timer = null
        mutable.update { it.copy(playing = false) }
    }

    /** 解码后的图片真正进入画面，或当前视频已准备好，才接受就绪回调。 */
    fun mediaReady(token: Long) {
        if (!accepts(token) || state.value.error != null || state.value.ready) return
        mutable.update { it.copy(ready = true) }
        armTimer()
    }

    fun videoFinished(token: Long) {
        if (!accepts(token) || preview.state.value.source == null || ended || state.value.error != null) return
        ended = true
        if (state.value.playing) move(1)
    }

    fun mediaFailed(token: Long, error: Throwable) {
        if (!accepts(token)) return
        retryDirection = null
        fail(error)
    }

    fun retry(): Job? {
        if (!state.value.active || state.value.loading || state.value.error == null) return null
        val direction = retryDirection
        return if (direction != null) move(direction) else preview.state.value.photo?.let(::show)
    }

    fun move(direction: Int): Job? {
        if (!state.value.active || state.value.loading || direction !in setOf(-1, 1)) return null
        val current = preview.state.value.photo?.id ?: return null
        val token = generation
        timer?.cancel(); timer = null
        mutable.update { it.copy(loading = true, error = null) }
        retryDirection = direction
        work = scope.launch {
            try {
                var index = photos.indexOfFirst { it.id == current }
                while (index < 0 && hasMore) {
                    loadPage(token)
                    index = photos.indexOfFirst { it.id == current }
                }
                if (index < 0) invalid()
                if (direction < 0 && index == 0) while (hasMore) loadPage(token)
                if (direction > 0 && index == photos.lastIndex && hasMore) loadPage(token)
                checkCurrent(token)
                val next = (index + direction + photos.size) % photos.size
                loadMedia(photos[next], token)
            } catch (error: Exception) {
                if (error !is CancellationException && token == generation) fail(error)
            } finally {
                if (token == generation) { mutable.update { it.copy(loading = false) }; armTimer() }
            }
        }
        return work
    }

    private fun show(photo: SynologyPhoto): Job {
        val token = generation
        timer?.cancel(); timer = null
        mutable.update { it.copy(loading = true, error = null) }
        work = scope.launch {
            try { loadMedia(photo, token) }
            catch (error: Exception) {
                if (error !is CancellationException && token == generation) fail(error)
            } finally {
                if (token == generation) { mutable.update { it.copy(loading = false) }; armTimer() }
            }
        }
        return work!!
    }

    private suspend fun loadMedia(photo: SynologyPhoto, token: Long) {
        retryDirection = null; ended = false
        mutable.update { it.copy(mediaToken = ++mediaSerial, ready = false, error = null) }
        preview.open(photo)?.join()
        checkCurrent(token)
        preview.state.value.error?.let { throw it }
    }

    private suspend fun loadPage(token: Long) {
        val frozen = query ?: throw CancellationException()
        val page = repository.photos(space, frozen, offset, pageSize)
        checkCurrent(token)
        val known = photos.mapTo(mutableSetOf()) { it.id }
        if (page.offset != offset || page.items.size > pageSize || page.nextOffset != offset + page.items.size ||
            page.hasMore && page.items.isEmpty() || page.items.any { !belongs(it, space, frozen) || !known.add(it.id) }) invalid()
        photos += page.items
        offset = page.nextOffset; hasMore = page.hasMore
    }

    private fun belongs(photo: SynologyPhoto, space: SynologyPhotoSpace, query: SynologyPhotoQuery): Boolean {
        if (photo.id.profileId != repository.profileId) return false
        if (query !is SynologyPhotoQuery.Album) return photo.id.space == space && photo.albumContext == null
        val context = photo.albumContext ?: return false
        return context.albumId == query.id && context.ownerUserId >= 0 &&
            photo.id.space == if (context.ownerUserId == 0L) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL
    }

    private fun armTimer() {
        timer?.cancel(); timer = null
        val value = state.value
        if (!value.active || !value.playing || value.loading || !value.ready || value.error != null || preview.state.value.source != null) return
        val token = value.mediaToken
        timer = scope.launch { delay(3_000); if (accepts(token) && state.value.playing) move(1) }
    }

    private fun fail(error: Throwable) {
        pause()
        mutable.update { it.copy(error = error, ready = false) }
    }

    fun stop() {
        generation++; work?.cancel(); work = null; timer?.cancel(); timer = null
        preview.closePreview(); photos.clear(); offset = 0; hasMore = true; query = null
        ended = false; retryDirection = null
        mutable.value = SynologyPhotoSlideshowState(mediaToken = ++mediaSerial)
    }

    private fun accepts(token: Long) = state.value.active && state.value.mediaToken == token
    private suspend fun checkCurrent(token: Long) { currentCoroutineContext().ensureActive(); if (!state.value.active || token != generation) throw CancellationException() }
    private fun invalid(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.INVALID_RESPONSE)
}
