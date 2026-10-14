package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotosServing
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner

/** 照片设置和维护共用原件编辑/上传的持久未决检查，不能只看当前页面是否忙碌。 */
internal suspend fun requireNoPendingPhotoInputs(
    edits: SynologyPhotoEditStore?, uploads: SynologyPhotoUploadStore?, owner: WorkspaceOwner,
    repository: SynologyPhotosServing,
) {
    if (edits?.records(owner, repository.photoEditIdentity())?.any { it.checkpoint.submitted && !it.checkpoint.finished } == true ||
        uploads?.records(owner, repository.uploadIdentity())?.any { !it.finished && it.entries.any { entry -> entry.checkpoint?.submitted == true && !entry.checkpoint.finished } } == true)
        throw SynologyPhotoAlbumFailure(SynologyPhotoAlbumProblem.PENDING)
}
