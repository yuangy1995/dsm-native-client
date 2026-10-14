package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

/** 相册关系与条件管理；统一 Foto 路由，移出和删除容器均不调用原件删除。 */
internal class SynologyPhotosAlbumRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val details: suspend (SynologyPhoto) -> SynologyPhoto,
    private val photos: suspend (SynologyPhotoSpace, SynologyPhotoQuery, Int, Int) -> SynologyPhotoPage,
    private val photoPending: (SynologyPhotoId) -> Boolean,
    private val uid: () -> JsonPrimitive? = { null },
    private val requestSpaces: () -> Set<SynologyPhotoSpace> = { emptySet() },
    private val defaultFolderSort: () -> SynologyPhotoSort = { SynologyPhotoSort() },
    private val verifyFolderCover: suspend (SynologyPhotoFolderSnapshot, SynologyPhotoFolderCover) -> Unit = { _, _ -> invalid() },
    private val deletionEnabled: () -> Boolean = { false },
    private val applySettings: (SynologyPhotoSettings) -> Unit = {},
    private val previewDownload: suspend (SynologyPhoto, java.io.File, String) -> Unit = { _, _, _ -> invalid() },
    private val previewConvert: suspend (java.io.File, String) -> io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview =
        io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosPreviewConverter::convert,
    private val previewUpload: suspend (ApiCapability, Long, io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview) -> Boolean = { _, _, _ -> invalid() },
    private val previewEvents: () -> io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoPreviewEvents = { invalid() },
    private val automaticDownload: suspend (ApiCapability, Long, java.io.File, suspend () -> Unit) -> Unit = { _, _, _, _ -> invalid() },
    private val automaticConvert: suspend (java.io.File, SynologyPhotoAutomaticPreviewTask, java.io.File) -> io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoAutomaticPreviewMedia =
        io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosAutomaticPreviewConverter::convert,
    private val automaticUpload: suspend (ApiCapability, Long, io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview?, java.io.File?) -> Boolean = { _, _, _, _ -> invalid() },
    private val automaticThumbnail: suspend (Long, String, SynologyPhotoSpace) -> ByteArray = { _, _, _ -> invalid() },
    private val automaticVideoDownload: suspend (ApiCapability, Long, java.io.File, suspend () -> Unit) -> Unit = { _, _, _, _ -> invalid() },
    private val automaticVideoSignature: suspend (java.io.File) -> SynologyPhotoPreviewVideoSignature =
        io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosVideoSignature::read,
    private val similarAccess: (SynologyPhotoSpace) -> Unit = { invalid() },
    private val conceptAccess: (SynologyPhotoSpace) -> Unit = { invalid() },
    private val conceptThumbnail: suspend (SynologyPhotoThumbnail, SynologyPhotoSpace) -> ByteArray = { _, _ -> invalid() },
    private val peopleAccess: (SynologyPhotoSpace) -> Unit = { invalid() },
    private val personThumbnail: suspend (SynologyPhotoPersonCover, SynologyPhotoSpace) -> ByteArray = { _, _ -> invalid() },
    private val faceThumbnail: suspend (SynologyPhotoPersonFace) -> ByteArray = { invalid() },
    private val manualFaceUpload: suspend (ApiCapability, Long, ByteArray) -> Boolean = { _, _, _ -> invalid() },
) {
    private val conditions = SynologyPhotosConditionRepository(identity, checkAccess, read)
    private val sharing = SynologyPhotosSharingRepository(identity, uid, checkAccess,
        { id -> (album(id) ?: changed()).let { it to snapshot(it) } }, read, write)
    private val settings = SynologyPhotosSettingsRepository(identity, checkAccess, capability, read, write, applySettings) { id, owner ->
        (album(id) ?: changed()).also { rights(it, owner) }
    }
    private val sharedMembers = SynologyPhotosSharedMembersRepository(identity, checkAccess, capability, read, write) {
        settings.settings(SynologyPhotoSettingsTarget(SynologyPhotoSettingsKind.SHARED))
    }
    private val folderSharing = SynologyPhotosFolderSharingRepository(identity, uid, checkAccess, capability, read, write)
    private val temporary = SynologyPhotosTemporaryRepository(identity, checkAccess,
        { id -> album(id)?.let { it to snapshot(it) } }, ::members, write)
    private val requests = SynologyPhotosRequestRepository(identity, { owner, space ->
        checkAccess(owner, space); if (requestSpaces().isEmpty()) denied()
    }, read, write)
    private val folders = SynologyPhotosFolderRepository(identity, checkAccess, capability, read, write, details,
        photoPending, defaultFolderSort, verifyFolderCover)
    private val files = SynologyPhotosFileRepository(identity, checkAccess, capability, read, write, folders::access, photoPending, deletionEnabled)
    private val similar = SynologyPhotosSimilarRepository(identity, checkAccess, similarAccess, capability, read, write, folders::access, photoPending)
    private val concepts = SynologyPhotosConceptRepository(identity, checkAccess, conceptAccess, capability, read, write, photos,
        details, folders::access, photoPending, conceptThumbnail)
    private val people = SynologyPhotosPeopleRepository(identity, checkAccess, peopleAccess, capability, read, write, photos,
        folders::access, photoPending, personThumbnail, details, faceThumbnail)
    private val manualFaces = SynologyPhotosManualFacesRepository(identity,
        { owner, space -> checkAccess(owner, space); peopleAccess(space) }, people::freshAccess, capability, read, write,
        details, folders::access, photoPending, manualFaceUpload, faceThumbnail)
    private val mutex = Mutex()
    private val operations = mutableMapOf<String, SynologyPhotoAlbumCheckpoint>()
    private val background = SynologyPhotosBackgroundRepository(identity, checkAccess, capability, read, write,
        requestSpaces, folders::access) { operations.values.toList() }
    private val maintenance = SynologyPhotosMaintenanceRepository(identity, checkAccess, capability, read, write)
    private val codecPrompt = SynologyPhotosCodecPromptRepository(identity, checkAccess, capability, read, write)
    private val previewAccess = SynologyPhotosPreviewAccess(identity, checkAccess, capability, read, { id -> snapshot(album(id) ?: changed()) }, photoPending)
    private val previews = SynologyPhotosPreviewRepository(previewAccess, checkAccess, capability, write,
        previewDownload, previewConvert, previewUpload, previewEvents)
    private val automaticAccess = SynologyPhotosAutomaticPreviewAccess(identity, checkAccess, capability, read, photoPending, automaticDownload)
    private val automaticPreviews = SynologyPhotosAutomaticPreviewMutation(automaticAccess, checkAccess, capability, write,
        automaticConvert, automaticUpload, automaticThumbnail, automaticVideoDownload, automaticVideoSignature)

    fun pending(photo: SynologyPhotoId, excludingOperationId: String? = null): Boolean = operations.values.any { row ->
        row.operationId != excludingOperationId && row.submitted && !row.finished && (row.targets.any { it.id == photo } ||
            row.automaticPreview?.task?.space == photo.space || row.folder?.coverPhoto?.id == photo ||
            row.people?.let { it.space == photo.space && photo.itemId in it.memberIds.orEmpty() } == true)
    }

    suspend fun access(id: Long): SynologyPhotoAlbumAccess {
        val owner = identity()
        val album = album(id) ?: changed()
        return rights(album, owner).also { checkAccess(owner, null) }
    }

    /** 导出复用同一份最新相册权限，口令只随本次请求留在内存中。 */
    suspend fun downloadContext(id: Long, ownContribution: Boolean, archive: Boolean): Map<String, JsonElement> {
        val owner = identity()
        val album = album(id) ?: changed()
        val access = rights(album, owner)
        if (!access.canDownload && (archive || !ownContribution)) denied()
        checkAccess(owner, null)
        return if (access.isOwner) json((if (archive) "id" else "album_id") to id)
        else json("passphrase" to passphrase(album))
    }

    suspend fun condition(id: Long): SynologyPhotoAlbumCondition {
        val owner = identity()
        val value = access(id)
        if (!value.isOwner || !value.album.conditional) denied()
        return conditions.get(id, owner)
    }
    suspend fun suggestions(keyword: String, space: SynologyPhotoSpace) = conditions.suggestions(keyword, space)
    suspend fun conditionCount(condition: SynologyPhotoAlbumCondition) = conditions.count(condition)
    suspend fun sharing(id: Long) = sharing.state(id)
    suspend fun sharingRecipients() = sharing.recipients()
    suspend fun folderSharing(folder: SynologyPhotoFolderSnapshot) = folderSharing.state(folder)
    suspend fun settings(target: SynologyPhotoSettingsTarget) = settings.settings(target)
    suspend fun folderSharingRecipients() = folderSharing.recipients()
    suspend fun sharedMembers() = sharedMembers.state()
    suspend fun sharedMemberCandidates() = sharedMembers.candidates()
    suspend fun sharedMemberFolders(member: SynologyPhotoShareMemberId) = sharedMembers.folders(member)
    suspend fun temporary(id: Long) = temporary.state(id)
    suspend fun request(id: String) = requests.get(id)
    suspend fun restoredRequest(row: SynologyPhotoAlbumCheckpoint) = requests.restored(row)
    suspend fun requestAlbums() = requests.albums()
    suspend fun requestFolder(space: SynologyPhotoSpace, id: Long) = requests.folder(space, id)
    suspend fun folderAccess(space: SynologyPhotoSpace, id: Long) = folders.access(space, id)
    suspend fun transferDuplicate() = files.duplicate()
    suspend fun backgroundTasks() = background.tasks()
    suspend fun backgroundTaskErrors(task: SynologyPhotoBackgroundTask) = background.errors(task)
    suspend fun backgroundTaskTarget(task: SynologyPhotoBackgroundTask) = background.target(task)
    suspend fun maintenanceStatus(space: SynologyPhotoSpace) = maintenance.status(space)
    suspend fun similarPhotos(photo: SynologyPhoto) = similar.detail(photo)
    suspend fun similarGroupDetails(group: SynologyPhotoSimilarGroup) = similar.detail(group)
    suspend fun similarStatus(space: SynologyPhotoSpace) = similar.status(space)
    suspend fun prepareSimilar(detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit, selected: List<Long>) = similar.checkpoint(detail, edit, selected)
    suspend fun prepareSimilarUndo(original: SynologyPhotoAlbumCheckpoint): SynologyPhotoAlbumCheckpoint = mutex.withLock {
        val stored = select(original, identity())
        val existing = operations.values.singleOrNull { it.similar?.undo?.operationId == original.operationId }
        if (existing?.submitted == true) changed()
        val prepared = similar.undo(stored)
        if (existing == null) prepared else {
            val restored = prepared.copy(operationId = existing.operationId, similar = prepared.similar!!.copy(batchOrder = existing.similar!!.batchOrder))
            if (!existing.sameOperation(restored)) changed()
            existing
        }
    }
    fun clearPeopleCovers() { people.clearCovers(); concepts.clear() }
    suspend fun concepts(space: SynologyPhotoSpace) = concepts.all(space)
    suspend fun concept(id: Long, space: SynologyPhotoSpace) = concepts.get(id, space)
    suspend fun conceptPage(space: SynologyPhotoSpace, offset: Int, limit: Int) = concepts.page(space, offset, limit)
    suspend fun conceptThumbnail(concept: SynologyPhotoCollection) = concepts.thumbnail(concept)
    suspend fun prepareConcept(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoConceptSnapshot>,
        photos: List<SynologyPhoto>, visible: Boolean?) = concepts.checkpoint(action, originals, photos, visible)
    suspend fun people(space: SynologyPhotoSpace, includingHidden: Boolean) = people.people(space, includingHidden)
    suspend fun personPage(space: SynologyPhotoSpace, offset: Int, limit: Int) = people.page(space, offset, limit)
    suspend fun personThumbnail(person: SynologyPhotoCollection) = people.thumbnail(person)
    suspend fun personFaces(personId: Long, photos: List<SynologyPhoto>) = people.faces(personId, photos)
    suspend fun faceThumbnail(face: SynologyPhotoPersonFace) = people.faceThumbnail(face)
    suspend fun photoFaces(photo: SynologyPhoto) = manualFaces.faces(photo)
    suspend fun prepareManualFaces(photo: SynologyPhoto, originals: List<SynologyPhotoFaceSnapshot>, changes: List<SynologyPhotoFaceChange>) =
        manualFaces.checkpoint(photo, originals, changes)
    suspend fun preparePersonFaces(action: SynologyPhotoAlbumAction, original: SynologyPhotoPersonSnapshot,
        photos: List<SynologyPhoto>, faces: List<SynologyPhotoPersonFace>, target: SynologyPhotoPersonSnapshot?, name: String?) =
        people.faceCheckpoint(action, original, photos, faces, target, name)
    suspend fun preparePeople(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoPersonSnapshot>, name: String?, visible: Boolean?) =
        people.checkpoint(action, originals, name, visible)
    suspend fun codecPrompt() = codecPrompt.prompt()
    suspend fun preparePreviews(photos: List<SynologyPhoto>, resuming: Boolean) = previewAccess.checkpoint(photos, resuming)
    suspend fun pendingPreviews(space: SynologyPhotoSpace) = previewAccess.pending(space)
    suspend fun automaticPreviewEnabled() = automaticAccess.enabled()
    suspend fun automaticPreviewTasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) = automaticAccess.tasks(space, support)
    suspend fun automaticPreviewTasks(photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) = automaticAccess.tasks(photo, support)
    suspend fun downloadAutomaticPreviewSource(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport,
        destination: java.io.File) = automaticAccess.download(task, support, destination)
    suspend fun prepareAutomaticPreview(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport): SynologyPhotoAlbumCheckpoint {
        val owner = identity()
        val row = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = owner.userId,
            action = SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW, targets = listOfNotNull(task.source),
            automaticPreview = SynologyPhotoAutomaticPreviewCheckpoint(task, support))
        prepare(row, owner)
        return row
    }
    suspend fun prepareRequest(row: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange) {
        val owner = identity(); validatePhotoAlbumCheckpoint(row); requireOwner(row, owner)
        capability("PhotoRequest", 1, null); requests.prepare(row, change, owner)
    }

    suspend fun frozen(id: Long): SynologyPhotoFrozenAlbum {
        val owner = identity()
        val raw = album(id, frozen = true) ?: changed()
        return SynologyPhotoFrozenAlbumCodec.decode(raw, snapshot(raw), owner.userId).also { checkAccess(owner, null) }
    }

    private fun snapshot(album: JsonObject) = SynologyPhotoAlbumSnapshot(album.positive("id"), album.text("name"),
        album.positive("owner_user_id"), album.text("type"), album.optionalBoolean("freeze_album"), album.optionalBoolean("temporary_shared"))

    private suspend fun rights(album: JsonObject, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumAccess {
        val value = snapshot(album)
        val thumbnail = SynologyPhotosCodec.thumbnail(album.optionalObject("additional")?.optionalObject("thumbnail"))
        if (value.ownerUserId == owner.userId) return SynologyPhotoAlbumAccess(value, true, value.ordinary, true, thumbnail)
        val permissions = read("Sharing.Passphrase", 1, "get_permission", json("passphrase" to passphrase(album),
            "exclude_public" to false), null).obj("permission")
        return SynologyPhotoAlbumAccess(value, false, value.ordinary && permissions.permission("upload"), permissions.permission("download"), thumbnail)
    }

    private fun passphrase(album: JsonObject): String = (album.optionalText("passphrase") ?:
        album.optionalObject("additional")?.optionalObject("sharing_info")?.optionalText("passphrase"))?.takeIf { it.isNotEmpty() } ?: denied()

    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint) { prepare(row, identity()) }

    private suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): Map<String, JsonElement> {
        validatePhotoAlbumCheckpoint(row); requireOwner(row, owner)
        if (row.action.isRequest) invalid()
        if (row.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES) { manualFaces.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.EDIT_SIMILAR) {
            row.similar?.undo?.let { undo ->
                val original = operations[undo.operationId] ?: changed(); val source = original.similar ?: changed()
                if (original.userId != row.userId || original.profileId != row.profileId || !source.canUndo || source.group != row.similar.group ||
                    original.targets != row.targets || source.edit != undo.edit || source.selectedIds != undo.selectedIds || source.resultingGroup != undo.resultingGroup) changed()
            }
            similar.prepare(row, owner); return emptyMap()
        }
        if (row.action.isConcept) { concepts.prepare(row, owner); return emptyMap() }
        if (row.action.isPeople) { people.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW) { automaticPreviews.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS) { previewAccess.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.SHARED_MEMBERS) { sharedMembers.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.CODEC_PROMPT) { codecPrompt.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.MAINTAIN_LIBRARY) { maintenance.prepare(row, owner); return emptyMap() }
        if (row.action.isBackground) { background.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.SETTINGS) { settings.prepare(row, owner); return emptyMap() }
        if (row.action == SynologyPhotoAlbumAction.SHARE_FOLDER) { folderSharing.prepare(row, owner); return emptyMap() }
        if (row.action.isFileTask) { files.prepare(row, owner); return emptyMap() }
        if (row.action.isFolder) { folders.prepare(row, owner); return emptyMap() }
        checkAccess(owner, null)
        capability("Browse.Album", 4, null)
        if (row.action in setOf(SynologyPhotoAlbumAction.SHARE, SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.STOP_TEMPORARY)) {
            capability("Sharing.Passphrase", 1, null)
            checkAccess(owner, SynologyPhotoSpace.PERSONAL)
            if (row.action != SynologyPhotoAlbumAction.SHARE) capability("Browse.NormalAlbum", 1, null)
            if (row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY) capability("Browse.Album", 1, null)
        }
        else if (row.action.editsCondition) capability("Browse.ConditionAlbum", 3, null)
        else capability(if (row.action in setOf(SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE, SynologyPhotoAlbumAction.UNFREEZE))
            "Browse.NormalAlbum" else "Browse.Album", 1, null)
        if (row.action == SynologyPhotoAlbumAction.REBUILD_FROZEN) capability("Browse.Album", 1, null)
        var target: Map<String, JsonElement> = emptyMap()
        var permission: SynologyPhotoAlbumAccess? = null
        row.album?.let { expected ->
            val current = album(expected.id, row.action.restoresFrozen) ?: changed()
            if (snapshot(current) != expected) changed()
            permission = rights(current, owner)
            val access = permission!!
            val temporaryAction = expected.temporaryShare && row.action in setOf(SynologyPhotoAlbumAction.SHARE, SynologyPhotoAlbumAction.STOP_TEMPORARY)
            if (!expected.ordinary && !expected.conditional && !expected.recoverable && !temporaryAction) denied()
            if (row.action in setOf(SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE)) {
                if (!access.canContribute) denied()
                target = if (access.isOwner) json("id" to expected.id) else json("passphrase" to passphrase(current))
            } else if (!access.canManage && !(temporaryAction && access.isOwner)) denied()
            if (row.action.restoresFrozen) {
                val frozen = SynologyPhotoFrozenAlbumCodec.decode(current, expected, owner.userId)
                if (frozen.snapshot != row.frozenSnapshot) changed()
                if (row.action == SynologyPhotoAlbumAction.REBUILD_FROZEN && !frozen.canRebuild) denied()
            }
        }
        if (row.action.editsCondition) {
            conditions.validate(row.condition!!, owner)
            row.originalCondition?.let { original ->
                val current = conditions.get(row.album!!.id, owner)
                if (!SynologyPhotoConditionCodec.matches(current, original, owner.userId)) changed()
            }
        }
        if (row.action == SynologyPhotoAlbumAction.SHARE) sharing.prepare(row, owner)
        if (row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY) temporary.prepare(row, owner)
        val adding = row.action in setOf(SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.CREATE_TEMPORARY, SynologyPhotoAlbumAction.ADD)
        if (adding && row.targets.any { it.albumContext != null } && row.targets.map { it.id.space }.distinct().size > 1 && !owner.managesShared) denied()
        for (photo in row.targets) {
            if (photoPending(photo.id)) changed()
            if (row.action != SynologyPhotoAlbumAction.REMOVE) checkAccess(owner, photo.id.space)
            val current = details(photo.photo())
            if (!photo.matches(current, includeTime = true)) changed()
            when {
                row.action == SynologyPhotoAlbumAction.REMOVE -> {
                    if (permission?.isOwner != true && current.albumContext?.providerUserId != owner.userId) denied()
                }
                adding && photo.albumContext != null -> {
                    if (current.albumContext?.providerUserId != owner.userId) denied()
                }
                else -> requireSourceFolder(photo, owner)
            }
        }
        if (row.action == SynologyPhotoAlbumAction.COVER) {
            val member = members(row.album!!.id).singleOrNull { it.id == row.targets.single().id } ?: changed()
            if (!matchesMember(row.targets.single(), member, owner)) changed()
        }
        checkAccess(owner, null)
        return target
    }

    private suspend fun requireSourceFolder(photo: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess) {
        val folder = read("Browse.Folder", 2, "get", json("id" to photo.folderId,
            "additional" to array("access_permission")), photo.id.space).obj("folder")
        if (folder.positive("id") != photo.folderId) changed()
        val rights = folder.optionalObject("additional")?.optionalObject("access_permission")
        val allowed = if (photo.id.space == SynologyPhotoSpace.SHARED) owner.managesShared ||
            rights?.permission("view") == true && rights.permission("download") else
            rights?.permission("view") == true && rights.permission("manage")
        if (!allowed) denied()
        checkAccess(owner, photo.id.space)
    }

    suspend fun perform(input: SynologyPhotoAlbumCheckpoint, password: String? = null, request: SynologyPhotoRequestChange? = null, previewCache: java.io.File? = null,
        faceImages: Map<String, ByteArray> = emptyMap(),
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint =
        withContext(Dispatchers.IO) { mutex.withLock {
            val owner = identity()
            var row = select(input, owner)
            if (row.submitted) return@withLock reviewLocked(row, owner, save, previewCache = previewCache)
            if (row.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES) manualFaces.requireImages(row, faceImages)
            else if (faceImages.isNotEmpty()) invalid()
            if (row.action == SynologyPhotoAlbumAction.SHARE) sharing.requirePassword(row, password)
            else if (row.action == SynologyPhotoAlbumAction.SHARE_FOLDER) folderSharing.requirePassword(row, password)
            else if (password != null) invalid()
            val target = if (row.action.isRequest) {
                capability("PhotoRequest", 1, null)
                requests.prepare(row, request ?: invalid(), owner); emptyMap()
            } else { if (request != null) invalid(); prepare(row, owner) }
            currentCoroutineContext().ensureActive()
            row = row.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
            persist(row, save)
            row = try {
                checkAccess(owner, null)
                val items = JsonArray(row.targets.map { JsonPrimitive(it.id.itemId) })
                when (row.action) {
                    SynologyPhotoAlbumAction.EDIT_SIMILAR -> similar.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.SHOW_CONCEPTS, SynologyPhotoAlbumAction.COVER_CONCEPT, SynologyPhotoAlbumAction.REMOVE_CONCEPT_ITEMS -> concepts.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.EDIT_PHOTO_FACES -> manualFaces.execute(row, owner, faceImages) { persist(it, save) }
                    SynologyPhotoAlbumAction.RENAME_PERSON, SynologyPhotoAlbumAction.MERGE_PEOPLE, SynologyPhotoAlbumAction.SHOW_PEOPLE,
                    SynologyPhotoAlbumAction.REMOVE_PERSON_FACES, SynologyPhotoAlbumAction.REASSIGN_PERSON_FACES, SynologyPhotoAlbumAction.COVER_PERSON -> people.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW -> automaticPreviews.execute(row, owner, previewCache) { persist(it, save) }
                    SynologyPhotoAlbumAction.REGENERATE_PREVIEWS -> previews.execute(row, owner, previewCache) { persist(it, save) }
                    SynologyPhotoAlbumAction.STOP_TASK, SynologyPhotoAlbumAction.CLEAR_TASKS -> background.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.MOVE_ITEMS, SynologyPhotoAlbumAction.COPY_ITEMS, SynologyPhotoAlbumAction.DELETE_FOLDER_ITEMS -> files.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.CREATE_FOLDER, SynologyPhotoAlbumAction.RENAME_FOLDER, SynologyPhotoAlbumAction.SORT_FOLDER, SynologyPhotoAlbumAction.COVER_FOLDER -> folders.execute(row, owner)
                    SynologyPhotoAlbumAction.CREATE_REQUEST, SynologyPhotoAlbumAction.UPDATE_REQUEST, SynologyPhotoAlbumAction.DELETE_REQUEST -> requests.execute(row, request!!, owner)
                    SynologyPhotoAlbumAction.SHARED_MEMBERS -> sharedMembers.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.CODEC_PROMPT -> codecPrompt.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.MAINTAIN_LIBRARY -> maintenance.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.SETTINGS -> settings.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.SHARE_FOLDER -> folderSharing.execute(row, password, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.SHARE -> sharing.execute(row, password, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.STOP_TEMPORARY -> temporary.execute(row, owner) { persist(it, save) }
                    SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.CREATE_TEMPORARY -> {
                        val fields = json("name" to row.name!!, "item" to items) +
                            if (row.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) json("shared" to true) else emptyMap()
                        val receipt = write("Browse.NormalAlbum", 1, "create", fields, null)
                        row.copy(createdAlbumId = receipt.obj("album").positive("id"))
                    }
                    SynologyPhotoAlbumAction.CREATE_CONDITION, SynologyPhotoAlbumAction.REBUILD_FROZEN -> {
                        val receipt = write("Browse.ConditionAlbum", 3, "create", json("name" to row.name!!,
                            "condition" to SynologyPhotoConditionCodec.canonical(row.condition!!, owner.userId)), null)
                        val id = receipt.obj("album").positive("id")
                        if (id == row.album?.id) invalid()
                        row.copy(createdAlbumId = id)
                    }
                    SynologyPhotoAlbumAction.SET_CONDITION -> {
                        write("Browse.ConditionAlbum", 3, "set_condition", json("id" to row.album!!.id,
                            "condition" to SynologyPhotoConditionCodec.canonical(row.condition!!, owner.userId)), null); row
                    }
                    SynologyPhotoAlbumAction.UNFREEZE -> {
                        write("Browse.NormalAlbum", 1, "set_unfreeze", json("id" to row.album!!.id), null); row
                    }
                    SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE -> {
                        val receipt = write("Browse.NormalAlbum", 1,
                            if (row.action == SynologyPhotoAlbumAction.ADD) "add_item" else "delete_item", target + json("item" to items), null)
                        val errors = receipt["error_list"]
                        if (errors != null && errors != JsonNull && (errors !is JsonArray || errors.size > row.targets.size)) invalid()
                        row.copy(membershipHasFailures = errors is JsonArray && errors.isNotEmpty())
                    }
                    SynologyPhotoAlbumAction.RENAME -> { write("Browse.Album", 1, "set_name", json("id" to row.album!!.id, "name" to row.name!!), null); row }
                    SynologyPhotoAlbumAction.DELETE -> { write("Browse.Album", 1, "delete", json("id" to array(row.album!!.id)), null); row }
                    SynologyPhotoAlbumAction.COVER -> { write("Browse.Album", 1, "set_cover", json("id" to row.album!!.id, "id_item" to row.targets.single().id.itemId), null); row }
                }
            } catch (_: Exception) { operations[row.operationId] ?: row }
            row = row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
            withContext(NonCancellable) { persist(row, save) }
            try { reviewLocked(row, owner, save, allowFrozenDelete = true, previewCache = previewCache) } catch (_: Exception) { operations[row.operationId] ?: row }
        } }

    /** 仅显式继续已接收生成的提示保存；冷恢复和普通 perform 始终只读。 */
    suspend fun continueCodecPrompt(input: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint =
        withContext(Dispatchers.IO) { mutex.withLock {
            val owner = identity(); var row = select(input, owner)
            if (row.action != SynologyPhotoAlbumAction.CODEC_PROMPT || !row.submitted) invalid()
            row = reviewLocked(row, owner, save)
            if (row.finished) return@withLock row
            if (row.codecPrompt?.canContinue != true) changed()
            codecPrompt.prepare(row, owner)
            row = try { codecPrompt.continuePrompt(row, owner) { persist(it, save) } }
                catch (_: Exception) { operations[row.operationId] ?: row }
            withContext(NonCancellable) { persist(row, save) }
            try { reviewLocked(row, owner, save) } catch (_: Exception) { operations[row.operationId] ?: row }
        } }

    suspend fun review(input: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint =
        review(input, null, save)

    suspend fun review(input: SynologyPhotoAlbumCheckpoint, previewCache: java.io.File?, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint =
        withContext(Dispatchers.IO) { mutex.withLock { val owner = identity(); reviewLocked(select(input, owner), owner, save, previewCache = previewCache) } }

    private suspend fun reviewLocked(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit, allowFrozenDelete: Boolean = false, previewCache: java.io.File? = null): SynologyPhotoAlbumCheckpoint {
        if (!row.submitted) invalid()
        requireOwner(row, owner); checkAccess(owner, null)
        if (row.finished) { persist(row, save); return row }
        if (row.action == SynologyPhotoAlbumAction.EDIT_PHOTO_FACES) return manualFaces.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.EDIT_SIMILAR) return similar.review(row, owner).also { persist(it, save) }
        if (row.action.isConcept) return concepts.review(row, owner).also { persist(it, save) }
        if (row.action.isPeople) return people.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW) return automaticPreviews.review(row, owner, previewCache).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.REGENERATE_PREVIEWS) return previews.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.SHARED_MEMBERS) return sharedMembers.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.CODEC_PROMPT) return codecPrompt.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.MAINTAIN_LIBRARY) return maintenance.review(row, owner).also { persist(it, save) }
        if (row.action.isBackground) return background.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.SETTINGS) return settings.review(row, owner).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.SHARE_FOLDER) return folderSharing.review(row, owner).also { persist(it, save) }
        if (row.action.isFileTask) return files.review(row, owner) { persist(it, save) }
        if (row.action.isFolder) return row.copy(phase = if (folders.review(row, owner)) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING).also { persist(it, save) }
        if (row.action.isRequest) return row.copy(phase = if (requests.review(row, owner)) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.CREATE_TEMPORARY) {
            val verified = temporary.reviewCreate(row, owner)
            val done = verified != null
            return row.copy(temporaryCreatedSnapshot = verified ?: row.temporaryCreatedSnapshot, phase = if (done) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING,
                completed = if (done) row.targets.indices.toSet() else row.completed).also { persist(it, save) }
        }
        if (row.action == SynologyPhotoAlbumAction.STOP_TEMPORARY) return row.copy(phase = temporary.reviewStop(row, owner)).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.SHARE) return row.copy(phase = sharing.review(row, owner)).also { persist(it, save) }
        if (row.action == SynologyPhotoAlbumAction.REBUILD_FROZEN) return reviewFrozenReplacement(row, owner, save, allowFrozenDelete)
        val id = row.albumId ?: return row // 没有创建回执，不能搜索同名或重复创建。
        val current = album(id)
        var complete = false
        var completed = row.completed
        if (row.action == SynologyPhotoAlbumAction.DELETE) complete = current == null
        else if (row.action == SynologyPhotoAlbumAction.UNFREEZE) {
            complete = current != null && snapshot(current).let { value ->
                value.frozen == false && value.type != "condition" && value.ownerUserId == owner.userId &&
                    value.name == row.album!!.name && current.number("item_count") == row.frozenSnapshot!!.itemCount
            }
        }
        else {
            val value = current?.let(::snapshot) ?: return row
            val expectedOwner = row.album?.ownerUserId ?: owner.userId
            val expectedType = row.album?.type ?: if (row.action == SynologyPhotoAlbumAction.CREATE_CONDITION) "condition" else "normal"
            if (value.ownerUserId != expectedOwner || value.type != expectedType || !value.ordinary && !value.conditional && !value.recoverable) changed()
            when (row.action) {
                SynologyPhotoAlbumAction.CREATE_CONDITION, SynologyPhotoAlbumAction.SET_CONDITION -> {
                    val actual = conditions.get(id, owner)
                    complete = SynologyPhotoConditionCodec.matches(actual, row.condition!!, owner.userId) &&
                        (row.action != SynologyPhotoAlbumAction.CREATE_CONDITION || value.name == row.name)
                }
                SynologyPhotoAlbumAction.RENAME -> complete = value.name == row.name
                SynologyPhotoAlbumAction.COVER -> {
                    val photo = row.targets.single()
                    val matching = members(id).singleOrNull { it.id == photo.id }?.let { matchesMember(photo, it, owner) } == true
                    complete = matching && SynologyPhotosCodec.thumbnail(current.optionalObject("additional")?.optionalObject("thumbnail"))?.unitId == photo.id.itemId
                    if (complete) completed = setOf(0)
                }
                SynologyPhotoAlbumAction.CREATE, SynologyPhotoAlbumAction.ADD, SynologyPhotoAlbumAction.REMOVE -> {
                    val all = members(id)
                    val removing = row.action == SynologyPhotoAlbumAction.REMOVE
                    val actual = row.targets.indices.filterTo(mutableSetOf()) { index ->
                        val target = row.targets[index]
                        val member = all.singleOrNull { it.id == target.id }
                        if (member != null && !matchesMember(target, member, owner)) changed()
                        (member != null) != removing
                    }
                    if (!actual.containsAll(row.completed)) changed()
                    completed = actual
                    complete = actual.size == row.targets.size && (row.action != SynologyPhotoAlbumAction.CREATE ||
                        value.name == row.name && all.size == row.targets.size)
                }
                else -> Unit
            }
        }
        checkAccess(owner, null)
        val next = row.copy(completed = completed, phase = when {
            complete -> SynologyPhotoAlbumPhase.COMPLETED
            row.membershipHasFailures -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        })
        persist(next, save)
        return next
    }

    private suspend fun reviewFrozenReplacement(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit, allowDelete: Boolean): SynologyPhotoAlbumCheckpoint {
        var row = input
        val id = row.createdAlbumId ?: return row
        val created = album(id) ?: return row
        val actual = snapshot(created)
        if (actual.ownerUserId != owner.userId || !actual.conditional || actual.name != row.name || created.optionalBoolean("shared") != false)
            return row
        if (!SynologyPhotoConditionCodec.matches(conditions.get(id, owner), row.condition!!, owner.userId)) return row
        checkAccess(owner, null)
        val old = album(row.album!!.id, frozen = true)
        checkAccess(owner, null)
        fun finish(phase: SynologyPhotoAlbumPhase) = row.copy(phase = phase).also { persist(it, save) }
        if (old == null) return finish(SynologyPhotoAlbumPhase.COMPLETED)
        // 只有本次创建的连续执行可以删除旧容器；重启和刷新都只读取实际状态。
        if (!row.frozenDeletionAttempted && !allowDelete) return finish(SynologyPhotoAlbumPhase.PARTIAL)
        if (!row.frozenDeletionAttempted) {
            val original = try { SynologyPhotoFrozenAlbumCodec.decode(old, snapshot(old), owner.userId) }
            catch (_: SynologyPhotoFailure) { return finish(SynologyPhotoAlbumPhase.PARTIAL) }
            if (original.album != row.album || original.snapshot != row.frozenSnapshot) return finish(SynologyPhotoAlbumPhase.PARTIAL)
            currentCoroutineContext().ensureActive(); checkAccess(owner, null)
            row = row.copy(frozenDeletionAttempted = true)
            persist(row, save)
            try {
                checkAccess(owner, null)
                write("Browse.Album", 1, "delete", json("id" to array(row.album!!.id)), null)
            } catch (error: Exception) {
                // 仅明确的 NAS 拒绝可以终止；断网、取消和缺失回执继续保持结果未知。
                if (error is DsmFailure && error.code != null && error.kind != DsmErrorKind.INVALID_RESPONSE) {
                    row = row.copy(frozenDeletionRejected = true)
                    withContext(NonCancellable) { persist(row, save) }
                }
            }
        }
        val remains = album(row.album!!.id)
        checkAccess(owner, null)
        return finish(when {
            remains == null -> SynologyPhotoAlbumPhase.COMPLETED
            row.frozenDeletionRejected -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        })
    }

    private fun matchesMember(target: SynologyPhotoEditTarget, member: SynologyPhoto, owner: SynologyPhotosMutationAccess): Boolean {
        val expectedOwner = target.albumContext?.ownerUserId ?: if (target.id.space == SynologyPhotoSpace.SHARED) 0 else owner.userId
        return member.albumContext?.ownerUserId == expectedOwner && target.matches(member.copy(albumContext = target.albumContext))
    }

    private suspend fun members(id: Long): List<SynologyPhoto> {
        val result = mutableListOf<SynologyPhoto>()
        val seen = mutableSetOf<SynologyPhotoId>()
        var offset = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            val page = photos(SynologyPhotoSpace.PERSONAL, SynologyPhotoQuery.Album(id), offset, 500)
            if (page.items.any { !seen.add(it.id) } || page.offset != offset || page.nextOffset != offset + page.items.size ||
                page.items.size > 500 || page.hasMore && page.items.isEmpty()) invalid()
            result += page.items
            if (!page.hasMore) return result
            offset = page.nextOffset
        }
    }

    private suspend fun album(id: Long, frozen: Boolean = false): JsonObject? {
        if (id <= 0) invalid()
        val extra = if (frozen) array("sharing_info", "thumbnail", "condition_object") else array("sharing_info", "thumbnail")
        val values = read("Browse.Album", 4, "get", json("id" to array(id), "additional" to extra), null).list()
        if (values.size > 1 || values.any { it.positive("id") != id }) invalid()
        return values.singleOrNull()
    }
    private fun select(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        validatePhotoAlbumCheckpoint(row); requireOwner(row, owner)
        val previous = operations[row.operationId]
        row.similar?.undo?.let { undo ->
            if (operations.values.any { it.operationId != row.operationId && it.similar?.undo?.operationId == undo.operationId }) changed()
        }
        if (previous != null && !previous.sameOperation(row) || previous == null && !row.submitted && operations.values.any { photoAlbumsConflict(it, row) }) changed()
        return previous ?: row.also { operations[it.operationId] = it }
    }
    private fun requireOwner(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        if (row.profileId != owner.profileId || row.userId != owner.userId) denied()
    }
    private fun persist(row: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit) {
        operations[row.operationId] = row
        save(row)
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
