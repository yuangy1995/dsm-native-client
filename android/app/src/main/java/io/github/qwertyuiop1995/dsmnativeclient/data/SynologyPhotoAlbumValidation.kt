package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import java.util.UUID

internal fun validatePhotoAlbumCheckpoint(row: SynologyPhotoAlbumCheckpoint) {
    if (row.action == SynologyPhotoAlbumAction.EDIT_SIMILAR) {
        SynologyPhotoSimilarCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "similar", similar = null,
            targets = emptyList(), phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.similar != null) invalid()
    if (row.action.isConcept) {
        SynologyPhotoConceptCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "concept", concept = null,
            phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.concept != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES) {
        SynologyPhotoManualFacesCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "manual-faces", manualFaces = null,
            phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.manualFaces != null) invalid()
    if (row.action.isPeople) {
        SynologyPhotoPeopleCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "people", people = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.people != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW) {
        SynologyPhotoAutomaticPreviewCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "automatic-preview", automaticPreview = null,
            completed = emptySet(), phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.automaticPreview != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS) {
        SynologyPhotoPreviewRegenerationCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "previews", previews = null,
            targets = emptyList(), completed = emptySet(), phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.previews != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.CODEC_PROMPT) {
        SynologyPhotoCodecPromptCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "codec-prompt", codecPrompt = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.codecPrompt != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.MAINTAIN_LIBRARY) {
        SynologyPhotoMaintenanceCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "maintenance", maintenance = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.maintenance != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.SHARED_MEMBERS) {
        SynologyPhotoSharedMembersCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "shared-members", sharedMembers = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.sharedMembers != null) invalid()
    if (row.action.isBackground) {
        if (row.album != null || row.name != null || row.targets.isNotEmpty()) invalid()
        SynologyPhotoBackgroundCodec.validate(row.background ?: invalid(), row.action == SynologyPhotoAlbumAction.CLEAR_TASKS, row.phase)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "background", background = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.background != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.SETTINGS) {
        SynologyPhotoSettingsCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "settings", settings = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.settings != null) invalid()
    if (row.action == SynologyPhotoAlbumAction.SHARE_FOLDER) {
        SynologyPhotoFolderSharingCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "folder-sharing", folderSharing = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.folderSharing != null) invalid()
    if (row.action.isFileTask) {
        if (row.album != null || row.name != null) invalid()
        SynologyPhotoFileValidation.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "files", files = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.files != null) invalid()
    if (row.action.isFolder) {
        if (row.album != null || row.name != null || row.targets.isNotEmpty()) invalid()
        SynologyPhotoFolderCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "folder", folder = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.folder != null) invalid()
    if (row.action.isRequest) {
        if (row.album != null || row.name != null || row.targets.isNotEmpty()) invalid()
        SynologyPhotoRequestCodec.validate(row)
        validatePhotoAlbumCheckpoint(row.copy(action = SynologyPhotoAlbumAction.CREATE, name = "request", request = null, phase = SynologyPhotoAlbumPhase.READY))
        return
    }
    if (row.request != null) invalid()
    if (row.version != 1 || row.profileId.isBlank() || row.userId <= 0 ||
        runCatching { UUID.fromString(row.operationId).toString() != row.operationId }.getOrDefault(true) ||
        row.targets.size > 100 || row.targets.map { it.id.itemId }.distinct().size != row.targets.size) invalid()
    validatePhotoAlbumTargets(row.targets, row.profileId)
    if (row.action.creates != (row.album == null)) invalid()
    row.album?.let { if (it.id <= 0 || it.ownerUserId <= 0 || it.type.isBlank()) invalid() }
    when (row.action) {
        SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.CREATE_CONDITION, SynologyPhotoAlbumAction.REBUILD_FROZEN, SynologyPhotoAlbumAction.RENAME -> if (row.name.isNullOrBlank()) invalid()
        else -> if (row.name != null) invalid()
    }
    when (row.action) {
        SynologyPhotoAlbumAction.RENAME, SynologyPhotoAlbumAction.DELETE, SynologyPhotoAlbumAction.CREATE_CONDITION, SynologyPhotoAlbumAction.SET_CONDITION,
        SynologyPhotoAlbumAction.UNFREEZE, SynologyPhotoAlbumAction.REBUILD_FROZEN, SynologyPhotoAlbumAction.SHARE, SynologyPhotoAlbumAction.STOP_TEMPORARY -> if (row.targets.isNotEmpty()) invalid()
        SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE, SynologyPhotoAlbumAction.CREATE_TEMPORARY -> if (row.targets.isEmpty()) invalid()
        SynologyPhotoAlbumAction.COVER -> if (row.targets.size != 1) invalid()
        else -> Unit
    }
    if (row.action.editsCondition != (row.condition != null) ||
        (row.action == SynologyPhotoAlbumAction.SET_CONDITION) != (row.originalCondition != null)) invalid()
    row.condition?.let { SynologyPhotoConditionCodec.canonical(it, row.userId) }
    row.originalCondition?.let { SynologyPhotoConditionCodec.canonical(it, row.userId) }
    if (row.action == SynologyPhotoAlbumAction.SET_CONDITION && row.album?.conditional != true) invalid()
    if (row.action.restoresFrozen != (row.frozenSnapshot != null) || row.action.restoresFrozen && row.album?.recoverable != true) invalid()
    row.frozenSnapshot?.let { if (it.itemCount < 0 || !it.stateDigest.matches(Regex("[0-9a-f]{64}"))) invalid() }
    if (row.frozenDeletionAttempted && (row.action != SynologyPhotoAlbumAction.REBUILD_FROZEN || row.createdAlbumId == null || !row.submitted) ||
        row.frozenDeletionRejected && !row.frozenDeletionAttempted) invalid()
    if ((row.action == SynologyPhotoAlbumAction.SHARE) != (row.sharing != null)) invalid()
    row.sharing?.let { change ->
        SynologyPhotoSharingCodec.validate(change, row.album?.type == "condition")
        val updates = SynologyPhotoSharingCodec.changes(change).isNotEmpty() || SynologyPhotoSharingCodec.expirationChanged(change) ||
            change.password != SynologyPhotoSharingPassword.UNCHANGED
        if (row.sharingUpdateAttempted && !updates || row.sharingEnableAttempted &&
            (change.access == SynologyPhotoLinkAccess.DISABLED || updates && !row.sharingUpdateAcknowledged) ||
            row.sharingNoChanges && (change.access != change.original.access || SynologyPhotoSharingCodec.modifiesProtectionOrMembers(change) ||
                row.sharingUpdateAttempted || row.sharingEnableAttempted)) invalid()
    }
    if (row.sharingUpdateAcknowledged && !row.sharingUpdateAttempted ||
        (row.sharingUpdateAttempted || row.sharingEnableAttempted || row.sharingNoChanges) && (row.sharing == null || !row.submitted)) invalid()
    if ((row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY) != (row.temporary != null)) invalid()
    row.temporary?.let { change ->
        if (row.album?.temporaryShare != true || change.original.itemCount < 0 || !change.original.membersDigest.matches(Regex("[0-9a-f]{64}")) ||
            change.preservedCopyId?.let { it <= 0 || it == row.album.id || !change.keepCopy || row.createdAlbumId != null } == true ||
            row.createdAlbumId != null && !change.keepCopy) invalid()
        SynologyPhotoSharingCodec.validate(SynologyPhotoSharingChange(change.original.sharing, SynologyPhotoLinkAccess.DISABLED), false)
    }
    row.temporaryCreatedSnapshot?.let {
        if (row.action != SynologyPhotoAlbumAction.CREATE_TEMPORARY || !row.submitted || row.createdAlbumId == null ||
            it.itemCount != row.targets.size || !it.membersDigest.matches(Regex("[0-9a-f]{64}"))) invalid()
        SynologyPhotoSharingCodec.validate(SynologyPhotoSharingChange(it.sharing, SynologyPhotoLinkAccess.DISABLED), false)
    }
    if (row.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY && row.phase == SynologyPhotoAlbumPhase.COMPLETED && row.temporaryCreatedSnapshot == null) invalid()
    if (row.temporaryCancelRequested && row.action != SynologyPhotoAlbumAction.CREATE_TEMPORARY ||
        (row.temporaryCloseAttempted || row.temporaryClosedRevision != null || row.temporaryDeleteAttempted) && (row.temporary == null || !row.submitted) ||
        row.temporaryClosedRevision?.matches(Regex("[0-9a-f]{64}")) == false ||
        row.temporaryDeleteAttempted && (row.temporaryClosedRevision == null || row.temporary?.keepCopy == true && row.createdAlbumId == null && row.temporary.preservedCopyId == null) ||
        row.temporaryClosedRevision != null && row.temporary?.original?.sharing?.access != SynologyPhotoLinkAccess.DISABLED && !row.temporaryCloseAttempted ||
        row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY && row.phase == SynologyPhotoAlbumPhase.COMPLETED && !row.temporaryDeleteAttempted) invalid()
    if (row.action == SynologyPhotoAlbumAction.REMOVE && row.targets.any { it.albumContext?.albumId != row.album?.id }) invalid()
    if (row.createdAlbumId != null && (row.createdAlbumId <= 0 || (!row.action.createsAlbum && row.action != SynologyPhotoAlbumAction.STOP_TEMPORARY) || row.createdAlbumId == row.album?.id) ||
        row.completed.any { it !in row.targets.indices } ||
        !row.submitted && (row.createdAlbumId != null || row.membershipHasFailures || row.completed.isNotEmpty()) ||
        row.membershipHasFailures && row.action !in setOf(SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE) ||
        row.phase == SynologyPhotoAlbumPhase.PARTIAL && (when (row.action) {
            SynologyPhotoAlbumAction.REBUILD_FROZEN -> row.createdAlbumId == null || row.frozenDeletionAttempted && !row.frozenDeletionRejected
            SynologyPhotoAlbumAction.STOP_TEMPORARY -> row.temporaryDeleteAttempted
            SynologyPhotoAlbumAction.SHARE -> row.sharing!!.access == SynologyPhotoLinkAccess.DISABLED || row.sharingEnableAttempted || row.sharingNoChanges
            else -> !row.membershipHasFailures || row.completed.size == row.targets.size
        }) ||
        row.phase == SynologyPhotoAlbumPhase.COMPLETED && (row.completed.size != row.targets.size ||
            row.action.createsAlbum && row.createdAlbumId == null)) invalid()
}

internal fun photoAlbumsConflict(a: SynologyPhotoAlbumCheckpoint, b: SynologyPhotoAlbumCheckpoint): Boolean {
    if (a.profileId != b.profileId || a.userId != b.userId || a.operationId == b.operationId || !a.submitted || a.finished) return false
    if (b.action.isBackground && a.action.isFileTask) {
        val controls = b.background?.tasks.orEmpty()
        if (b.action == SynologyPhotoAlbumAction.CLEAR_TASKS) return controls.any { it.id == a.files?.taskId }
        return controls.singleOrNull()?.let { task ->
            task.id != a.files?.taskId || task.operation != when (a.action) {
                SynologyPhotoAlbumAction.COPY_ITEMS -> "copy"
                SynologyPhotoAlbumAction.MOVE_ITEMS -> "move"
                else -> ""
            }
        } ?: true
    }
    // 已提交搬移的恢复仅读取，不让停止控制记录挡住原任务取得终态。
    if (a.action.isBackground && b.action.isFileTask && b.submitted) return false
    return (a.similar != null && b.similar != null && a.similar.group.space == b.similar.group.space && a.similar.group.id == b.similar.group.id) ||
        (a.action.isConcept && b.action.isConcept && a.concept!!.space == b.concept!!.space &&
        a.concept.originals.any { old -> b.concept.originals.any { it.id == old.id } }) ||
        (a.action.isPeople && b.action.isPeople && a.people!!.space == b.people!!.space &&
        (a.people.originals.any { old -> b.people.originals.any { it.id == old.id } } ||
            a.people.faces?.targetReceipt?.let { id -> b.people.originals.any { it.id == id } } == true ||
            b.people.faces?.targetReceipt?.let { id -> a.people.originals.any { it.id == id } } == true)) ||
        (a.action.isPeople != b.action.isPeople) ||
        a.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW || b.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW ||
        a.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS || b.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS ||
        a.action == SynologyPhotoAlbumAction.CODEC_PROMPT || b.action == SynologyPhotoAlbumAction.CODEC_PROMPT ||
        a.action == SynologyPhotoAlbumAction.MAINTAIN_LIBRARY || b.action == SynologyPhotoAlbumAction.MAINTAIN_LIBRARY ||
        a.action == SynologyPhotoAlbumAction.SHARED_MEMBERS || b.action == SynologyPhotoAlbumAction.SHARED_MEMBERS || a.action.isBackground || b.action.isBackground ||
        (a.action == SynologyPhotoAlbumAction.SETTINGS || b.action == SynologyPhotoAlbumAction.SETTINGS || a.action == SynologyPhotoAlbumAction.SHARE_FOLDER || b.action == SynologyPhotoAlbumAction.SHARE_FOLDER || a.action.isFileTask || b.action.isFileTask || a.action.isRequest || b.action.isRequest || a.action.isFolder || b.action.isFolder || a.affectedAlbumIds.intersect(b.affectedAlbumIds).isNotEmpty() ||
            a.action.createsAlbum && b.action.createsAlbum && a.name == b.name ||
            a.targets.any { old -> b.targets.any { it.id == old.id } })
}

internal fun validatePhotoAlbumTargets(targets: List<SynologyPhotoEditTarget>, profileId: String) {
    targets.forEach { target ->
        if (target.id.profileId != profileId || target.id.itemId <= 0 || target.folderId <= 0 ||
            target.filename.isBlank() || target.sizeBytes < 0 || !target.takenAt.isFinite() || !target.indexedAt.isFinite() ||
            target.mediaType.isBlank()) invalid()
        target.albumContext?.let {
            if (it.albumId <= 0 || it.ownerUserId < 0 || it.providerUserId?.let { id -> id < 0 } == true ||
                (it.ownerUserId == 0L) != (target.id.space == SynologyPhotoSpace.SHARED)) invalid()
        }
    }
}
