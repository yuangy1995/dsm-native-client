package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid

internal object SynologyPhotoFileValidation {
    fun parent(folders: List<SynologyPhotoFolderSnapshot>): SynologyPhotoFolderSnapshot {
        val first = folders.firstOrNull() ?: invalid()
        val id = first.parentId?.takeIf { it > 0 } ?: invalid()
        val path = first.path.substringBeforeLast('/').ifEmpty { "/" }
        folders.forEach {
            SynologyPhotoFolderCodec.validate(it)
            if (it.path == "/" || it.parentId != id || it.space != first.space ||
                it.path.substringBeforeLast('/').ifEmpty { "/" } != path) invalid()
        }
        return SynologyPhotoFolderSnapshot(id, null, path.substringAfterLast('/').ifEmpty { "/" }, path, first.space)
    }

    fun accepts(row: SynologyPhotoAlbumCheckpoint, target: SynologyPhotoFolderSnapshot): Boolean {
        val files = row.files ?: return false
        if (row.action == SynologyPhotoAlbumAction.MOVE_ITEMS && files.space == SynologyPhotoSpace.SHARED && target.space == SynologyPhotoSpace.PERSONAL) return false
        if (files.space != target.space) return true
        return row.targets.none { it.folderId == target.id } && files.folders.none {
            target.id == it.parentId || target.id == it.id || SynologyPhotoFolderCodec.contains(it.path, target.path)
        }
    }

    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val files = row.files ?: invalid()
        val deletion = row.action == SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS
        if (row.targets.size + files.folders.size !in 1..100 || files.folders.map { it.id }.distinct().size != files.folders.size ||
            row.targets.any { it.id.space != files.space } || files.folders.any { it.space != files.space } ||
            deletion && files.folders.isEmpty() || deletion != (files.destination == null) || deletion != (files.duplicate == null)) invalid()
        if (files.folders.isNotEmpty()) {
            val parent = parent(files.folders)
            if (row.targets.any { it.folderId != parent.id || it.albumContext != null }) invalid()
        }
        files.destination?.let { SynologyPhotoFolderCodec.validate(it); if (!accepts(row, it)) invalid() }
        if (files.taskId?.let { it <= 0 || !row.submitted } == true || files.total?.let { it < 0 || files.taskId == null } == true ||
            files.targetVerified && (deletion || files.taskId == null || files.total == null) || files.result != null && files.taskId == null ||
            row.finished && files.result == null || !row.finished && files.result != null) invalid()
        if (row.finished && !deletion && (files.total == null || requiresTarget(row) && !files.targetVerified)) invalid()
        if (!deletion && files.total != null && (if (files.folders.isEmpty()) files.total != row.targets.size.toLong() else files.total < row.targets.size)) invalid()
        files.result?.let { result ->
            validateResult(result, files.total, files.duplicate)
            if (row.phase == SynologyPhotoAlbumPhase.COMPLETED && (result.errors != 0L || result.skipped != 0L ||
                !deletion && (files.total == null || result.completion != files.total || requiresTarget(row) && !files.targetVerified))) invalid()
            if (row.phase == SynologyPhotoAlbumPhase.PARTIAL && result.errors == 0L && result.skipped == 0L &&
                (deletion || result.completion == files.total)) invalid()
        }
    }

    fun requiresTarget(row: SynologyPhotoAlbumCheckpoint): Boolean = row.files!!.let { it.folders.isNotEmpty() || it.destination?.space != it.space }

    fun validateResult(result: SynologyPhotoFileResult, total: Long?, duplicate: SynologyPhotoTransferDuplicate?) {
        if (listOf(result.completion, result.errors, result.skipped, result.overwritten).any { it < 0 || total != null && it > total } ||
            duplicate != SynologyPhotoTransferDuplicate.OVERWRITE && result.overwritten != 0L ||
            total != null && result.completion != total && result.overwritten > result.completion) invalid()
    }
}
