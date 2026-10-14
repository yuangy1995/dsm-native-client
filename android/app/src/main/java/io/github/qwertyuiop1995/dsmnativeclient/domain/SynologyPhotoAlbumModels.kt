package io.github.qwertyuiop1995.dsmnativeclient.domain

import java.util.UUID
import kotlinx.serialization.Serializable

/** 只保存相册身份；分享口令、链接与权限原始响应留在仓储请求内。 */
@Serializable
data class SynologyPhotoAlbumSnapshot(
    val id: Long, val name: String, val ownerUserId: Long, val type: String,
    val frozen: Boolean?, val temporary: Boolean?,
) {
    val ordinary: Boolean get() = type == "normal" && frozen != true && temporary != true
    val conditional: Boolean get() = type == "condition" && frozen != true && temporary != true
    val recoverable: Boolean get() = frozen == true && temporary != true && type in setOf("normal", "condition")
    val temporaryShare: Boolean get() = temporary == true && type == "normal" && frozen != true
    override fun toString() = "PhotoAlbumSnapshot"
}

data class SynologyPhotoAlbumAccess(
    val album: SynologyPhotoAlbumSnapshot, val isOwner: Boolean, val canContribute: Boolean,
    val canDownload: Boolean, val thumbnail: SynologyPhotoThumbnail? = null,
) {
    val canManage: Boolean get() = isOwner && (album.ordinary || album.conditional || album.recoverable)
}

@Serializable
enum class SynologyPhotoAlbumAction { CREATE, RENAME, DELETE, ADD, REMOVE, COVER, CREATE_CONDITION, SET_CONDITION, UNFREEZE, REBUILD_FROZEN, SHARE, CREATE_TEMPORARY, STOP_TEMPORARY, CREATE_REQUEST, UPDATE_REQUEST, DELETE_REQUEST, CREATE_FOLDER, RENAME_FOLDER, SORT_FOLDER, COVER_FOLDER, MOVE_ITEMS, COPY_ITEMS, DELETE_FOLDER_ITEMS, SHARE_FOLDER, SHARED_MEMBERS, MAINTAIN_LIBRARY, CODEC_PROMPT, REGENERATE_PREVIEWS, GENERATE_AUTOMATIC_PREVIEW, RENAME_PERSON, MERGE_PEOPLE, SHOW_PEOPLE, REMOVE_PERSON_FACES, REASSIGN_PERSON_FACES, COVER_PERSON, EDIT_PHOTO_FACES, SHOW_CONCEPTS, COVER_CONCEPT, REMOVE_CONCEPT_ITEMS, EDIT_SIMILAR, SETTINGS, STOP_TASK, CLEAR_TASKS;
    val isConcept: Boolean get() = this in setOf(SHOW_CONCEPTS, COVER_CONCEPT, REMOVE_CONCEPT_ITEMS)
    val isPeople: Boolean get() = this in setOf(RENAME_PERSON, MERGE_PEOPLE, SHOW_PEOPLE) || isPersonFaces
    val isPersonFaces: Boolean get() = this in setOf(REMOVE_PERSON_FACES, REASSIGN_PERSON_FACES, COVER_PERSON)
    val isRequest: Boolean get() = this in setOf(CREATE_REQUEST, UPDATE_REQUEST, DELETE_REQUEST)
    val isFolder: Boolean get() = this in setOf(CREATE_FOLDER, RENAME_FOLDER, SORT_FOLDER, COVER_FOLDER)
    val isFileTask: Boolean get() = this in setOf(MOVE_ITEMS, COPY_ITEMS, DELETE_FOLDER_ITEMS)
    val isBackground: Boolean get() = this == STOP_TASK || this == CLEAR_TASKS
    val creates: Boolean get() = this == CREATE || this == CREATE_CONDITION || this == CREATE_TEMPORARY
    val createsAlbum: Boolean get() = creates || this == REBUILD_FROZEN
    val editsCondition: Boolean get() = this == CREATE_CONDITION || this == SET_CONDITION || this == REBUILD_FROZEN
    val restoresFrozen: Boolean get() = this == UNFREEZE || this == REBUILD_FROZEN
}
@Serializable
enum class SynologyPhotoAlbumPhase { READY, SUBMITTING, PENDING, COMPLETED, PARTIAL }

@Serializable
data class SynologyPhotoAlbumCheckpoint(
    val version: Int = 1,
    val profileId: String, val userId: Long,
    val operationId: String = UUID.randomUUID().toString(),
    val action: SynologyPhotoAlbumAction,
    val album: SynologyPhotoAlbumSnapshot? = null,
    val name: String? = null,
    // 复用已存在的必要原件快照，不另存媒体、位置或 EXIF。
    val targets: List<SynologyPhotoEditTarget> = emptyList(),
    val phase: SynologyPhotoAlbumPhase = SynologyPhotoAlbumPhase.READY,
    val createdAlbumId: Long? = null,
    val membershipHasFailures: Boolean = false,
    val completed: Set<Int> = emptySet(),
    val condition: SynologyPhotoAlbumCondition? = null,
    val originalCondition: SynologyPhotoAlbumCondition? = null,
    val frozenSnapshot: SynologyPhotoFrozenAlbumSnapshot? = null,
    val frozenDeletionAttempted: Boolean = false,
    val frozenDeletionRejected: Boolean = false,
    val sharing: SynologyPhotoSharingChange? = null,
    val sharingUpdateAttempted: Boolean = false,
    val sharingUpdateAcknowledged: Boolean = false,
    val sharingEnableAttempted: Boolean = false,
    val sharingNoChanges: Boolean = false,
    val temporary: SynologyPhotoTemporaryChange? = null,
    val temporaryCloseAttempted: Boolean = false,
    val temporaryClosedRevision: String? = null,
    val temporaryDeleteAttempted: Boolean = false,
    val temporaryCancelRequested: Boolean = false,
    val temporaryCreatedSnapshot: SynologyPhotoTemporarySnapshot? = null,
    val request: SynologyPhotoRequestCheckpoint? = null,
    val folder: SynologyPhotoFolderCheckpoint? = null,
    val files: SynologyPhotoFileCheckpoint? = null,
    val folderSharing: SynologyPhotoFolderSharingCheckpoint? = null,
    val settings: SynologyPhotoSettingsCheckpoint? = null,
    val sharedMembers: SynologyPhotoSharedMembersCheckpoint? = null,
    val background: SynologyPhotoBackgroundCheckpoint? = null,
    val maintenance: SynologyPhotoMaintenanceCheckpoint? = null,
    val codecPrompt: SynologyPhotoCodecCheckpoint? = null,
    val previews: SynologyPhotoPreviewRegeneration? = null,
    val automaticPreview: SynologyPhotoAutomaticPreviewCheckpoint? = null,
    val people: SynologyPhotoPeopleCheckpoint? = null,
    val manualFaces: SynologyPhotoManualFacesCheckpoint? = null,
    val concept: SynologyPhotoConceptCheckpoint? = null,
    val similar: SynologyPhotoSimilarCheckpoint? = null,
) {
    val submitted: Boolean get() = phase != SynologyPhotoAlbumPhase.READY
    val finished: Boolean get() = phase in setOf(SynologyPhotoAlbumPhase.COMPLETED, SynologyPhotoAlbumPhase.PARTIAL) && codecPrompt?.retainsGeneration != true
    val albumId: Long? get() = album?.id ?: createdAlbumId
    val affectedAlbumIds: Set<Long> get() = setOfNotNull(album?.id, createdAlbumId, temporary?.preservedCopyId)
    fun sameOperation(other: SynologyPhotoAlbumCheckpoint): Boolean = copy(phase = other.phase,
        createdAlbumId = other.createdAlbumId, membershipHasFailures = other.membershipHasFailures, completed = other.completed,
        frozenDeletionAttempted = other.frozenDeletionAttempted, frozenDeletionRejected = other.frozenDeletionRejected,
        sharingUpdateAttempted = other.sharingUpdateAttempted, sharingUpdateAcknowledged = other.sharingUpdateAcknowledged,
        sharingEnableAttempted = other.sharingEnableAttempted, sharingNoChanges = other.sharingNoChanges,
        temporaryCloseAttempted = other.temporaryCloseAttempted, temporaryClosedRevision = other.temporaryClosedRevision,
        temporaryDeleteAttempted = other.temporaryDeleteAttempted, temporaryCancelRequested = other.temporaryCancelRequested,
        temporaryCreatedSnapshot = other.temporaryCreatedSnapshot,
        request = request?.copy(targetDigest = other.request?.targetDigest),
        folder = folder?.copy(createdFolderId = other.folder?.createdFolderId, coverAcknowledged = other.folder?.coverAcknowledged == true),
        folderSharing = folderSharing?.copy(updateAttempted = other.folderSharing?.updateAttempted == true,
            updateAcknowledged = other.folderSharing?.updateAcknowledged == true, configAttempted = other.folderSharing?.configAttempted == true,
            rejected = other.folderSharing?.rejected == true),
        settings = settings?.copy(attempted = other.settings?.attempted == true, rejected = other.settings?.rejected == true, globalProgress = other.settings?.globalProgress),
        sharedMembers = sharedMembers?.copy(attempted = other.sharedMembers?.attempted.orEmpty(), acknowledged = other.sharedMembers?.acknowledged.orEmpty(),
            rejected = other.sharedMembers?.rejected.orEmpty(), completed = other.sharedMembers?.completed.orEmpty()),
        background = background?.copy(attempted = other.background?.attempted.orEmpty(), rejected = other.background?.rejected.orEmpty(),
            completed = other.background?.completed.orEmpty()),
        maintenance = maintenance?.copy(attempted = other.maintenance?.attempted == true,
            acknowledged = other.maintenance?.acknowledged == true, rejected = other.maintenance?.rejected == true),
        codecPrompt = codecPrompt?.copy(generationAttempted = other.codecPrompt?.generationAttempted == true,
            generationAcknowledged = other.codecPrompt?.generationAcknowledged == true, generationRejected = other.codecPrompt?.generationRejected == true,
            promptAttempts = other.codecPrompt?.promptAttempts ?: 0, promptRejections = other.codecPrompt?.promptRejections ?: 0,
            promptAcknowledged = other.codecPrompt?.promptAcknowledged == true, promptClosed = other.codecPrompt?.promptClosed == true),
        previews = other.previews,
        automaticPreview = other.automaticPreview,
        people = other.people,
        manualFaces = other.manualFaces,
        concept = other.concept,
        similar = other.similar,
        files = files?.copy(taskId = other.files?.taskId, total = other.files?.total,
            targetVerified = other.files?.targetVerified == true, result = other.files?.result)) == other &&
        (if (previews == null) other.previews == null else other.previews?.let(previews::sameIntent) == true) &&
        (if (automaticPreview == null) other.automaticPreview == null else other.automaticPreview?.let(automaticPreview::sameIntent) == true) &&
        (if (people == null) other.people == null else other.people?.let(people::sameIntent) == true) &&
        (if (concept == null) other.concept == null else other.concept?.let(concept::sameIntent) == true) &&
        (if (similar == null) other.similar == null else other.similar?.let(similar::sameIntent) == true) &&
        (if (manualFaces == null) other.manualFaces == null else other.manualFaces?.let(manualFaces::sameIntent) == true)
    override fun toString() = "PhotoAlbumCheckpoint(action=$action, phase=$phase)"
}

/** 冻结恢复只保存状态摘要；原始分享配置、链接和口令不进入恢复文件。 */
@Serializable
data class SynologyPhotoFrozenAlbumSnapshot(val itemCount: Long, val stateDigest: String, val shared: Boolean)

data class SynologyPhotoFrozenAlbum(
    val album: SynologyPhotoAlbumSnapshot, val snapshot: SynologyPhotoFrozenAlbumSnapshot,
    val unsupportedKeys: Set<String>, val rebuildCondition: SynologyPhotoAlbumCondition?,
) {
    val canRebuild: Boolean get() = rebuildCondition != null
    override fun toString() = "PhotoFrozenAlbum"
}
