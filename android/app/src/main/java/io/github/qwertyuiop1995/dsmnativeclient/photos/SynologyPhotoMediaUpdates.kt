package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job

/** 原件旋转和预览更新只替换命中的照片，保留图库窗口和选择。 */
internal class SynologyPhotoMediaUpdates(
    private val repository: SynologyPhotosServing,
    private val active: () -> Boolean, private val generation: () -> Long,
    private val checkCurrent: suspend (Long) -> Unit,
    private val preview: SynologyPhotoPreviewModel, private val thumbnails: SynologyPhotoThumbnailStore,
    private val items: () -> List<SynologyPhoto>, private val replaceItems: (List<SynologyPhoto>) -> Unit,
    private val edits: () -> SynologyPhotoEditModel?,
) {
    suspend fun thumbnail(photo: SynologyPhoto): ByteArray {
        val token = generation()
        return thumbnails.load(photo) { repository.thumbnail(photo) }.also { checkCurrent(token) }
    }

    suspend fun albumThumbnail(id: Long): ByteArray {
        val token = generation()
        return thumbnails.loadAlbum(repository.profileId, id) { repository.albumThumbnail(id) }.also { checkCurrent(token) }
    }

    suspend fun folderThumbnail(folder: SynologyPhotoCollection, cover: SynologyPhotoFolderCover): ByteArray {
        val token = generation()
        return thumbnails.loadFolder(repository.profileId, folder, cover) { repository.folderThumbnail(folder, cover) }.also { checkCurrent(token) }
    }

    val canRotate: Boolean get() {
        val current = preview.state.value; val photo = current.photo ?: return false
        val editor = edits() ?: return false
        return active() && repository.canEditPhotos && photo.supportsRotation && current.imageReady && current.image != null &&
            !current.loading && current.error == null && current.rotationDegrees == 0f && !editor.blocks(photo)
    }
    fun rotate(): Job? {
        if (!canRotate) return null
        val photo = preview.state.value.photo ?: return null
        val work = edits()?.rotate(photo) ?: return null
        preview.beginRotation(photo); return work
    }
    suspend fun rotationFinished(row: SynologyPhotoEditCheckpoint?) {
        val target = row?.targets?.singleOrNull()
        if (row?.phase != SynologyPhotoEditPhase.COMPLETED || target == null) { preview.clearRotation(); return }
        if (!active()) return
        val token = generation()
        preview.state.value.photo?.takeIf { target.matches(it, includeTime = true) }?.let { preview.open(it, preserveRotation = true) }
        update(target, token) { it.orientation == (row.edit as SynologyPhotoEdit.Rotation).expectedOrientation }
    }
    suspend fun previewsUpdated(targets: List<SynologyPhotoEditTarget>) {
        if (!active()) return
        val token = generation()
        for (target in targets) {
            val updated = update(target, token) { true }
            if (updated != null && preview.state.value.photo?.let { target.matches(it, includeTime = true) } == true) preview.open(updated)
        }
    }
    private suspend fun update(target: SynologyPhotoEditTarget, token: Long, matches: (SynologyPhoto) -> Boolean): SynologyPhoto? {
        try {
            val updated = repository.details(target.photo()); checkCurrent(token)
            if (!target.matches(updated, includeTime = true) || !matches(updated)) return null
            thumbnails.invalidate(updated); checkCurrent(token)
            replaceItems(items().map { old -> if (target.matches(old, includeTime = true)) updated else old })
            edits()?.updatePhoto(updated); return updated
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            // 当前预览可独立重试；暂时读取失败不清空图库或移动浏览位置。
            return null
        }
    }
}
