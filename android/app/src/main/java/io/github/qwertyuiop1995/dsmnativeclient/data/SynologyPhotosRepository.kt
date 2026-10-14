package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotosMediaTransport
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoPreviewEvents
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosPreviewConverter
import io.github.qwertyuiop1995.dsmnativeclient.network.photoApiPath
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.encode
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.number
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalLong
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalList
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalObject
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalText
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.permission
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import java.io.File
import java.net.URI
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/**
 * Synology Photos 内部接口适配；请求契约来自 photos-library-read.md 与 photos-item-deletion.md。
 * 每个实例绑定一个已登录账号；按来源与相册上下文读取，原件删除逐次检查权限与身份。
 */
class SynologyPhotosRepository internal constructor(
    override val profileId: String,
    capabilities: Map<String, ApiCapability>,
    private val callTransport: suspend (ApiCapability, String, Map<String, String>) -> JsonObject,
    private val media: SynologyPhotosMediaTransport? = null,
    override val canDeleteOriginals: Boolean = false,
    private val uploadTransport: SynologyPhotosUploadTransport? = null,
    private val previewEvents: (() -> SynologyPhotoPreviewEvents)? = null,
    private val previewConverter: suspend (File, String) -> SynologyPhotoConvertedPreview = SynologyPhotosPreviewConverter::convert,
    private val automaticConverter: suspend (File, SynologyPhotoAutomaticPreviewTask, File) -> io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoAutomaticPreviewMedia =
        io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosAutomaticPreviewConverter::convert,
    private val automaticVideoSignature: suspend (File) -> SynologyPhotoPreviewVideoSignature =
        io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotosVideoSignature::read,
) : SynologyPhotosServing {
    constructor(profile: NasProfile, session: DsmSession, api: DsmApiClient, capabilities: Map<String, ApiCapability>) :
        this(profile.id, capabilities, { capability, method, parameters ->
            api.call(profile, session, capability, method, parameters, oneShot = true)
        }, api.photosMedia(profile, session), canDeleteOriginals = true,
            uploadTransport = { capability, method, parameters, source, progress ->
                api.uploadPhoto(profile, session, capability, method, parameters, source, progress)
            })

    private val capabilities = capabilities.toMap()
    private val accessGeneration = AtomicLong()
    @Volatile private var hasPhotosAccess = false
    @Volatile private var allowedSpaces = emptySet<SynologyPhotoSpace>()
    private var currentUserId: Long? = null
    private var currentUserUid: JsonPrimitive? = null
    private var supportsOriginalSizeJPEG = false
    private var managesSharedSpace = false
    private var isPhotosAdministrator = false
    private var defaultFolderSort = SynologyPhotoSort()
    private var personalRecognition = emptyMap<SynologyPhotoCategory, Boolean>()
    private var sharedCategories = emptySet<SynologyPhotoCategory>()
    override val canUploadPhotos: Boolean get() = uploadTransport != null
    private val uploads = SynologyPhotosUploadRepository(
        identity = ::mutationAccess,
        checkAccess = { expected, space ->
            requireGeneration(expected.generation, space)
            if (mutationAccess() != expected) denied()
        },
        capability = ::capability, read = ::read, write = ::call, upload = uploadTransport,
    )
    override val canEditPhotos: Boolean get() = runCatching { capability("Browse.Item", 2) }.isSuccess
    private val edits: SynologyPhotosEditRepository = SynologyPhotosEditRepository(identity = ::mutationAccess,
        checkAccess = { expected, space ->
            requireGeneration(expected.generation, space)
            if (mutationAccess() != expected) denied()
        }, capability = ::capability, read = ::read, write = ::call, details = ::details,
        deletionPending = { deletions.pending(it) || albumMutations.pending(it) })
    override suspend fun photoEditIdentity(): Long = mutationAccess().userId
    override suspend fun photoTags(space: SynologyPhotoSpace, offset: Int, limit: Int) = edits.tags(space, offset, limit)
    override suspend fun preparePhotoEdit(checkpoint: SynologyPhotoEditCheckpoint) = edits.prepare(checkpoint)
    override suspend fun performPhotoEdit(checkpoint: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit) = edits.perform(checkpoint, save)
    override suspend fun reviewPhotoEdit(checkpoint: SynologyPhotoEditCheckpoint, save: (SynologyPhotoEditCheckpoint) -> Unit) = edits.review(checkpoint, save)

    override val canManageAlbums: Boolean get() = runCatching { capability("Browse.NormalAlbum", 1); capability("Browse.Album", 4) }.isSuccess
    private val albumMutations: SynologyPhotosAlbumRepository = SynologyPhotosAlbumRepository(identity = ::mutationAccess,
        checkAccess = { expected, space ->
            requireGeneration(expected.generation, space)
            if (mutationAccess() != expected) denied()
        }, capability = ::capability, read = ::read, write = ::call, details = ::details, photos = ::photos,
        photoPending = { deletions.pending(it) || edits.pending(it) }, uid = { currentUserUid }, requestSpaces = { allowedSpaces },
        similarAccess = ::requireSimilarAccess, conceptAccess = ::requireConceptAccess, conceptThumbnail = { cover, space -> media().thumbnail(cover, false, space) },
        peopleAccess = ::requirePeopleAccess, personThumbnail = { cover, space -> media().personThumbnail(cover, space) },
        faceThumbnail = { media().faceThumbnail(it) },
        manualFaceUpload = { cap, id, jpeg -> media().uploadFace(cap, id, jpeg) },
        previewDownload = { photo, file, operation -> exports.download(photo, SynologyPhotoDownloadFormat.ORIGINAL, file, { _, _ -> }, operation) },
        previewConvert = previewConverter, previewUpload = { cap, unit, value -> media().uploadPreview(cap, unit, value) },
        previewEvents = { previewEvents?.invoke() ?: media().previewEvents() },
        automaticDownload = { cap, unit, destination, beforeCommit -> media().downloadPreviewUnit(cap, unit, destination, beforeCommit) },
        automaticConvert = automaticConverter,
        automaticUpload = { cap, unit, thumbnail, video -> media().uploadAutomaticPreview(cap, unit, thumbnail, video) },
        automaticThumbnail = { unit, size, space -> media().previewThumbnail(unit, size, space) },
        automaticVideoDownload = { cap, unit, destination, beforeCommit -> media().downloadConvertedPreview(cap, unit, destination, beforeCommit) },
        automaticVideoSignature = automaticVideoSignature,
        applySettings = ::applySettings, defaultFolderSort = { defaultFolderSort }, deletionEnabled = { canDeleteOriginals }, verifyFolderCover = { folder, cover ->
            val data = media().folderThumbnail(folder.id, cover.copy(revision = UUID.randomUUID().toString()), folder.space)
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                val bitmap = android.graphics.ImageDecoder.decodeBitmap(android.graphics.ImageDecoder.createSource(java.nio.ByteBuffer.wrap(data))) { decoder, info, _ ->
                    val longest = maxOf(info.size.width, info.size.height)
                    if (longest <= 0) invalid()
                    val ratio = minOf(1.0, 512.0 / longest)
                    decoder.setTargetSize(maxOf(1, (info.size.width * ratio).toInt()), maxOf(1, (info.size.height * ratio).toInt()))
                    decoder.allocator = android.graphics.ImageDecoder.ALLOCATOR_SOFTWARE
                }
                bitmap.recycle()
            }
        })
    override val canManageConditionAlbums: Boolean get() = canManageAlbums && runCatching { capability("Browse.ConditionAlbum", 3) }.isSuccess
    override val canManageAlbumSharing: Boolean get() = runCatching { capability("Browse.Album", 4); capability("Sharing.Passphrase", 1) }.isSuccess
    override val canManagePhotoRequests: Boolean get() = runCatching { capability("PhotoRequest", 1) }.isSuccess
    override val canManageFolders: Boolean get() = SynologyPhotoSpace.entries.any { runCatching { capability("Browse.Folder", 2, it) }.isSuccess }
    override val canManageSharedMembers: Boolean get() = isPhotosAdministrator && runCatching {
        listOf("UserInfo", "Setting.TeamSpace", "Setting.User", "Setting.Admin", "Sharing.Misc").forEach { capability(it, 1) }
        capability("Browse.Folder", 2, SynologyPhotoSpace.SHARED); capability("Sharing.FolderBatchPermission", 1, SynologyPhotoSpace.SHARED)
    }.isSuccess
    override suspend fun sharedMembers() = albumMutations.sharedMembers()
    override suspend fun sharedMemberCandidates() = albumMutations.sharedMemberCandidates()
    override suspend fun sharedMemberFolders(member: SynologyPhotoShareMemberId) = albumMutations.sharedMemberFolders(member)
    override val canManageFolderSharing: Boolean get() = runCatching {
        capability("Browse.Folder", 2, SynologyPhotoSpace.SHARED); capability("Sharing.FolderPermission", 1, SynologyPhotoSpace.SHARED)
    }.isSuccess
    override val canTransferPhotos: Boolean get() = canRunFileTasks && runCatching { capability("Setting.User", 1) }.isSuccess
    override val canDeleteFolders: Boolean get() = canDeleteOriginals && canRunFileTasks
    override val canControlBackgroundTasks: Boolean get() = runCatching { capability("BackgroundTask.Info", 1) }.isSuccess
    override val canRespondToCodecPrompt: Boolean get() = hasPhotosAccess && runCatching {
        listOf("UserInfo", "Setting.User", "Setting.Wizard").forEach { capability(it, 1) }
    }.isSuccess
    override val canGenerateCodecPreviews: Boolean get() = canRespondToCodecPrompt && runCatching { capability("Index", 1) }.isSuccess
    override fun canRegeneratePreviews(space: SynologyPhotoSpace): Boolean = space in allowedSpaces && (media != null || previewEvents != null) && runCatching {
        capability("RegeneratePreview", 1, space); capability("Browse.Item", 5, space); capability("Browse.Folder", 2, space)
    }.isSuccess
    override suspend fun pendingPreviewRegenerations(space: SynologyPhotoSpace) = albumMutations.pendingPreviews(space)
    override fun canGenerateAutomaticPreviews(space: SynologyPhotoSpace): Boolean = space in allowedSpaces && media != null && runCatching {
        capability("Upload.ConvertedFile", 3, space); capability("Download", 2, space)
    }.isSuccess
    override suspend fun automaticPreviewEnabled() = albumMutations.automaticPreviewEnabled()
    override suspend fun automaticPreviewTasks(space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) = albumMutations.automaticPreviewTasks(space, support)
    override suspend fun automaticPreviewTasks(photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) = albumMutations.automaticPreviewTasks(photo, support)
    override suspend fun downloadAutomaticPreviewSource(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport,
        destination: File) = albumMutations.downloadAutomaticPreviewSource(task, support, destination)
    override suspend fun prepareAutomaticPreview(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport) =
        albumMutations.prepareAutomaticPreview(task, support)
    override suspend fun performAutomaticPreview(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (checkpoint.action != SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW) invalid()
        return albumMutations.perform(checkpoint, previewCache = cache, save = save)
    }
    override suspend fun reviewAutomaticPreview(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (checkpoint.action != SynologyPhotoAlbumAction.GENERATE_AUTOMATIC_PREVIEW) invalid()
        return albumMutations.review(checkpoint, previewCache = cache, save = save)
    }
    override suspend fun preparePreviewRegeneration(photos: List<SynologyPhoto>, resuming: Boolean) = albumMutations.preparePreviews(photos, resuming)
    override suspend fun performPreviewRegeneration(checkpoint: SynologyPhotoAlbumCheckpoint, cache: File,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (checkpoint.action != SynologyPhotoAlbumAction.REGENERATE_PREVIEWS) invalid()
        return albumMutations.perform(checkpoint, previewCache = cache, save = save)
    }
    override suspend fun codecPrompt() = albumMutations.codecPrompt()
    override suspend fun continueCodecPrompt(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit) = albumMutations.continueCodecPrompt(checkpoint, save)
    override fun canMaintainLibrary(space: SynologyPhotoSpace): Boolean = space in allowedSpaces && (space != SynologyPhotoSpace.SHARED || isPhotosAdministrator) && runCatching {
        capability("UserInfo", 1); capability("Setting.User", 1); capability("Index", 1, space)
        if (space == SynologyPhotoSpace.SHARED) capability("Setting.TeamSpace", 1)
    }.isSuccess
    override suspend fun maintenanceStatus(space: SynologyPhotoSpace) = albumMutations.maintenanceStatus(space)
    override fun canManageConcepts(space: SynologyPhotoSpace, editingPhotos: Boolean): Boolean = runCatching {
        requireConceptAccess(space); mutationAccess()
        capability("Browse.Concept", 2, space)
        capability("UserInfo", 1); capability("Setting.User", 1); capability("Setting.Admin", 1)
        if (space == SynologyPhotoSpace.SHARED) capability("Setting.TeamSpace", 1)
        if (editingPhotos) { capability("Browse.Item", 5, space); capability("Browse.Timeline", 5, space); capability("Browse.Folder", 2, space) }
    }.isSuccess
    private fun requireConceptAccess(space: SynologyPhotoSpace) {
        requireAccess(space)
        if (space == SynologyPhotoSpace.SHARED && (!managesSharedSpace || SynologyPhotoCategory.SUBJECTS !in sharedCategories) ||
            space == SynologyPhotoSpace.PERSONAL && personalRecognition[SynologyPhotoCategory.SUBJECTS] == false) denied()
    }
    override suspend fun managementConcepts(space: SynologyPhotoSpace) = albumMutations.concepts(space)
    override suspend fun concept(id: Long, space: SynologyPhotoSpace) = albumMutations.concept(id, space)
    override suspend fun conceptThumbnail(concept: SynologyPhotoCollection) = albumMutations.conceptThumbnail(concept)
    override suspend fun prepareConceptChange(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoConceptSnapshot>,
        photos: List<SynologyPhoto>, visible: Boolean?) = albumMutations.prepareConcept(action, originals, photos, visible)
    private fun requireSimilarAccess(space: SynologyPhotoSpace) {
        requireAccess(space)
        if (space == SynologyPhotoSpace.PERSONAL && personalRecognition[SynologyPhotoCategory.SIMILAR] != true ||
            space == SynologyPhotoSpace.SHARED && (!managesSharedSpace || SynologyPhotoCategory.SIMILAR !in sharedCategories)) denied()
        listOf("Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline").forEach { capability(it, 1, space) }
    }
    override fun canManageSimilar(space: SynologyPhotoSpace): Boolean = runCatching {
        requireSimilarAccess(space); mutationAccess(); capability("Browse.Item", 5, space); capability("Browse.Folder", 2, space)
        listOf("UserInfo", "Setting.User", "Setting.Admin").forEach { capability(it, 1) }
        if (space == SynologyPhotoSpace.SHARED) capability("Setting.TeamSpace", 1)
    }.isSuccess
    override suspend fun similarPhotos(photo: SynologyPhoto) = albumMutations.similarPhotos(photo)
    override suspend fun similarGroupDetails(group: SynologyPhotoSimilarGroup) = albumMutations.similarGroupDetails(group)
    override suspend fun similarStatus(space: SynologyPhotoSpace) = albumMutations.similarStatus(space)
    override suspend fun prepareSimilarChange(detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit, selectedIds: List<Long>) =
        albumMutations.prepareSimilar(detail, edit, selectedIds)
    override suspend fun prepareSimilarUndo(original: SynologyPhotoAlbumCheckpoint) = albumMutations.prepareSimilarUndo(original)
    override fun canManagePeople(space: SynologyPhotoSpace, merging: Boolean): Boolean = runCatching {
        requirePeopleAccess(space); mutationAccess()
        capability("Browse.Person", if (merging) 2 else 1, space)
        capability("UserInfo", 1); capability("Setting.User", 1); capability("Setting.Admin", 1)
        if (space == SynologyPhotoSpace.SHARED) capability("Setting.TeamSpace", 1)
        if (merging) { capability("Browse.Timeline", 5, space); capability("Browse.Item", 4, space); capability("Browse.Folder", 2, space) }
    }.isSuccess
    private fun requirePeopleAccess(space: SynologyPhotoSpace) {
        requireAccess(space)
        if (space == SynologyPhotoSpace.SHARED && (!managesSharedSpace || SynologyPhotoCategory.PEOPLE !in sharedCategories) ||
            space == SynologyPhotoSpace.PERSONAL && personalRecognition[SynologyPhotoCategory.PEOPLE] == false) denied()
    }
    override fun canManagePersonFaces(space: SynologyPhotoSpace): Boolean = canManagePeople(space) && runCatching {
        capability("Browse.Item", 5, space); capability("Browse.Folder", 2, space)
    }.isSuccess
    override suspend fun personFaces(personId: Long, photos: List<SynologyPhoto>) = albumMutations.personFaces(personId, photos)
    override fun canEditPhotoFaces(photo: SynologyPhoto): Boolean = photo.mediaType != "video" && photo.id.profileId == profileId &&
        canManagePersonFaces(photo.id.space) && runCatching {
            capability("Browse.Item", 6, photo.id.space); capability("Browse.Person", 3, photo.id.space); capability("Upload.Face", 1, photo.id.space)
            if (photo.albumContext != null) capability("Browse.Album", 4)
        }.isSuccess
    override suspend fun photoFaces(photo: SynologyPhoto) = albumMutations.photoFaces(photo)
    override suspend fun prepareManualFaces(photo: SynologyPhoto, originals: List<SynologyPhotoFaceSnapshot>, changes: List<SynologyPhotoFaceChange>) =
        albumMutations.prepareManualFaces(photo, originals, changes)
    override suspend fun performManualFaces(checkpoint: SynologyPhotoAlbumCheckpoint, images: Map<String, ByteArray>,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (checkpoint.action != SynologyPhotoAlbumAction.EDIT_PHOTO_FACES) invalid()
        return albumMutations.perform(checkpoint, faceImages = images, save = save)
    }
    override suspend fun faceThumbnail(face: SynologyPhotoPersonFace) = albumMutations.faceThumbnail(face)
    override suspend fun preparePersonFaces(action: SynologyPhotoAlbumAction, original: SynologyPhotoPersonSnapshot,
        photos: List<SynologyPhoto>, faces: List<SynologyPhotoPersonFace>, target: SynologyPhotoPersonSnapshot?, name: String?) =
        albumMutations.preparePersonFaces(action, original, photos, faces, target, name)
    override suspend fun managementPeople(space: SynologyPhotoSpace, includingHidden: Boolean) = albumMutations.people(space, includingHidden)
    override suspend fun personThumbnail(person: SynologyPhotoCollection) = albumMutations.personThumbnail(person)
    override suspend fun preparePeopleChange(action: SynologyPhotoAlbumAction, originals: List<SynologyPhotoPersonSnapshot>, name: String?, visible: Boolean?) =
        albumMutations.preparePeople(action, originals, name, visible)
    override suspend fun backgroundTasks() = albumMutations.backgroundTasks()
    override suspend fun backgroundTaskErrors(task: SynologyPhotoBackgroundTask) = albumMutations.backgroundTaskErrors(task)
    override suspend fun backgroundTaskTarget(task: SynologyPhotoBackgroundTask) = albumMutations.backgroundTaskTarget(task)
    private val canRunFileTasks: Boolean get() = SynologyPhotoSpace.entries.any { space -> runCatching {
        capability("BackgroundTask.File", 1, space); capability("BackgroundTask.Info", 1)
        capability("Browse.Folder", 2, space); capability("Browse.Item", 5, space)
    }.isSuccess }
    override fun canManageSettings(kind: SynologyPhotoSettingsKind): Boolean = runCatching {
        when (kind) {
            SynologyPhotoSettingsKind.CACHE -> { if (!isPhotosAdministrator) denied(); capability("UserInfo", 1); capability("Download", 2) }
            SynologyPhotoSettingsKind.SHARED, SynologyPhotoSettingsKind.GLOBAL -> {
                if (!isPhotosAdministrator) denied()
                listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace").forEach { capability(it, 1) }
            }
            SynologyPhotoSettingsKind.ALBUM_SORT -> { capability("Browse.Album", 1); capability("Browse.Album", 4) }
            SynologyPhotoSettingsKind.LIST_SORT -> capability("Browse.Album", 2)
            SynologyPhotoSettingsKind.LIST_DISPLAY -> capability("Browse.Album", 3)
            else -> { capability("Setting.User", 1); if (kind == SynologyPhotoSettingsKind.RECOGNITION) capability("Setting.Admin", 1) }
        }
    }.isSuccess
    override suspend fun photoSettings(kind: SynologyPhotoSettingsKind) = photoSettings(SynologyPhotoSettingsTarget(kind))
    override suspend fun photoSettings(target: SynologyPhotoSettingsTarget) = albumMutations.settings(target)
    private fun applySettings(value: SynologyPhotoSettings) {
        when (value) {
            is SynologyPhotoGlobalSettings -> {
                applySettings(value.recognition()); supportsOriginalSizeJPEG = value.supportsOriginalJPEG
                listOf(SynologyPhotoCategory.PEOPLE to SynologyPhotoRecognition.PEOPLE, SynologyPhotoCategory.SUBJECTS to SynologyPhotoRecognition.SUBJECTS, SynologyPhotoCategory.SIMILAR to SynologyPhotoRecognition.SIMILAR).forEach { (category, key) ->
                    val global = value.values[SynologyPhotoGlobalSetting.entries.first { it.field == key.field }]
                    sharedCategories = when {
                        !value.sharedEnabled || value.sharedRole == SynologyPhotoSharedSettings.Role.NONE || value.sharedRecognition[key] == false || global == false -> sharedCategories - category
                        value.sharedRecognition[key] == true -> sharedCategories + category
                        else -> sharedCategories
                    }
                }
            }
            is SynologyPhotoSharedSettings -> {
                allowedSpaces = if (value.canAccess) allowedSpaces + SynologyPhotoSpace.SHARED else allowedSpaces - SynologyPhotoSpace.SHARED
                managesSharedSpace = value.canAccess && value.role == SynologyPhotoSharedSettings.Role.MANAGEMENT
                sharedCategories = if (value.canAccess) setOf(SynologyPhotoCategory.RECENT, SynologyPhotoCategory.LOCATIONS, SynologyPhotoCategory.TAGS, SynologyPhotoCategory.VIDEOS) +
                    listOf(SynologyPhotoCategory.PEOPLE to SynologyPhotoSharedSetting.PEOPLE, SynologyPhotoCategory.SUBJECTS to SynologyPhotoSharedSetting.SUBJECTS, SynologyPhotoCategory.SIMILAR to SynologyPhotoSharedSetting.SIMILAR)
                        .mapNotNull { (category, key) -> category.takeIf { value.values[key] == true && value.global[key] == true } } else emptySet()
            }
            is SynologyPhotoDisplaySettings -> defaultFolderSort = value.sort
            is SynologyPhotoRecognitionSettings -> personalRecognition = listOf(
                SynologyPhotoCategory.PEOPLE to SynologyPhotoRecognition.PEOPLE, SynologyPhotoCategory.SUBJECTS to SynologyPhotoRecognition.SUBJECTS, SynologyPhotoCategory.SIMILAR to SynologyPhotoRecognition.SIMILAR,
            ).mapNotNull { (category, key) ->
                val personal = value.personal[key]; val global = value.global[key]
                when { !value.personalEnabled || global == false -> category to false
                    personal != null -> category to personal
                    else -> null }
            }.toMap()
            else -> Unit
        }
    }
    override suspend fun transferDuplicate() = albumMutations.transferDuplicate()
    override suspend fun folderAccess(space: SynologyPhotoSpace, id: Long) = albumMutations.folderAccess(space, id)
    override suspend fun folderSharing(folder: SynologyPhotoFolderSnapshot) = albumMutations.folderSharing(folder)
    override suspend fun folderSharingRecipients() = albumMutations.folderSharingRecipients()
    override suspend fun folderThumbnail(folder: SynologyPhotoCollection, cover: SynologyPhotoFolderCover): ByteArray {
        val generation = accessGeneration.get(); requireAccess(folder.space)
        if (cover !in folder.folderCovers) invalid()
        return media().folderThumbnail(folder.id, cover, folder.space).also { requireGeneration(generation, folder.space) }
    }
    override suspend fun photoRequest(id: String) = albumMutations.request(id)
    override suspend fun restoredPhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint) = albumMutations.restoredRequest(checkpoint)
    override suspend fun photoRequestAlbums() = albumMutations.requestAlbums()
    override suspend fun photoRequestFolder(space: SynologyPhotoSpace, id: Long) = albumMutations.requestFolder(space, id)
    override suspend fun preparePhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange) = albumMutations.prepareRequest(checkpoint, change)
    override suspend fun performPhotoRequest(checkpoint: SynologyPhotoAlbumCheckpoint, change: SynologyPhotoRequestChange,
        save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (!checkpoint.action.isRequest) invalid()
        return albumMutations.perform(checkpoint, request = change, save = save)
    }
    override suspend fun temporaryAlbum(id: Long) = albumMutations.temporary(id)
    override suspend fun albumSharing(id: Long) = albumMutations.sharing(id)
    override suspend fun sharingRecipients() = albumMutations.sharingRecipients()
    override suspend fun albumCondition(id: Long) = albumMutations.condition(id)
    override suspend fun frozenAlbum(id: Long) = albumMutations.frozen(id)
    override suspend fun conditionSuggestions(keyword: String, space: SynologyPhotoSpace) = albumMutations.suggestions(keyword, space)
    override suspend fun conditionItemCount(condition: SynologyPhotoAlbumCondition) = albumMutations.conditionCount(condition)
    override suspend fun albumAccess(id: Long) = albumMutations.access(id)
    override suspend fun preparePhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint) = albumMutations.prepare(checkpoint)
    override suspend fun performPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit) = albumMutations.perform(checkpoint, save = save)
    override suspend fun performPhotoSharing(checkpoint: SynologyPhotoAlbumCheckpoint, password: String?, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (checkpoint.action != SynologyPhotoAlbumAction.SHARE) invalid()
        return albumMutations.perform(checkpoint, password, save = save)
    }
    override suspend fun performPhotoFolderSharing(checkpoint: SynologyPhotoAlbumCheckpoint, password: String?, save: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (checkpoint.action != SynologyPhotoAlbumAction.SHARE_FOLDER) invalid()
        return albumMutations.perform(checkpoint, password, save = save)
    }
    override suspend fun reviewPhotoAlbum(checkpoint: SynologyPhotoAlbumCheckpoint, save: (SynologyPhotoAlbumCheckpoint) -> Unit) = albumMutations.review(checkpoint, save = save)
    override suspend fun albumThumbnail(id: Long): ByteArray {
        val generation = accessGeneration.get()
        val current = albumAccess(id)
        val result = media().thumbnail(current.thumbnail ?: invalid(), false, SynologyPhotoSpace.PERSONAL, id)
        requireGeneration(generation, null)
        return result
    }

    private fun mutationAccess(): SynologyPhotosMutationAccess {
        requireAccess()
        return SynologyPhotosMutationAccess(profileId, currentUserId?.takeIf { it > 0 } ?: denied(), accessGeneration.get(), managesSharedSpace)
    }
    override suspend fun uploadIdentity(): Long = mutationAccess().userId
    override suspend fun uploadDuplicatePolicy() = uploads.duplicatePolicy()
    override suspend fun addableAlbums(offset: Int, limit: Int) = uploads.addableAlbums(offset, limit)
    override suspend fun prepareUploadTarget(target: SynologyPhotoUploadTarget) = uploads.prepare(target)
    override suspend fun performPhotoUpload(checkpoint: SynologyPhotoUploadCheckpoint, source: File?,
        save: (SynologyPhotoUploadCheckpoint) -> Unit, progress: (Long, Long) -> Unit) = uploads.perform(checkpoint, source, save, progress)
    override suspend fun reviewPhotoUpload(checkpoint: SynologyPhotoUploadCheckpoint, save: (SynologyPhotoUploadCheckpoint) -> Unit) = uploads.review(checkpoint, save)

    override suspend fun access(): SynologyPhotoAccess {
        hasPhotosAccess = false; allowedSpaces = emptySet(); currentUserId = null; currentUserUid = null
        supportsOriginalSizeJPEG = false; managesSharedSpace = false; isPhotosAdministrator = false; defaultFolderSort = SynologyPhotoSort(); personalRecognition = emptyMap(); sharedCategories = emptySet()
        val generation = accessGeneration.incrementAndGet()
        albumMutations.clearPeopleCovers()
        val identity = call("UserInfo", 1, "me")
        if (!identity.boolean("enabled")) denied()
        val user = call("Setting.User", 1, "get")
        val homeEnabled = user.boolean("enable_home_service")
        val teamPermission = user.text("team_space_permission")
        val admin = call("Setting.Admin", 1, "get")
        val team = call("Setting.TeamSpace", 1, "get")
        val teamEnabled = team.boolean("enabled") && teamPermission in setOf("entry", "management")
        val packageVersion = admin.optionalText("package_version").orEmpty()
        val userId = identity.optionalLong("id")?.also { if (it <= 0) invalid() }
        val recognition = listOf(SynologyPhotoCategory.PEOPLE to "enable_person", SynologyPhotoCategory.SUBJECTS to "enable_concept", SynologyPhotoCategory.SIMILAR to "enable_similar")
        val personal = recognition.mapNotNull { (category, key) ->
            val value = user.optionalBoolean(key); val global = admin.optionalBoolean(key)
            when { value != null -> category to (value && global != false); global == false -> category to false; else -> null }
        }.toMap()
        val shared = setOf(SynologyPhotoCategory.RECENT, SynologyPhotoCategory.LOCATIONS, SynologyPhotoCategory.TAGS, SynologyPhotoCategory.VIDEOS) +
            recognition.mapNotNull { (category, key) -> category.takeIf { team.optionalBoolean(key) == true && admin.optionalBoolean(key) != false } }
        currentCoroutineContext().ensureActive()
        if (generation != accessGeneration.get()) throw CancellationException()
        allowedSpaces = buildSet { if (homeEnabled) add(SynologyPhotoSpace.PERSONAL); if (teamEnabled) add(SynologyPhotoSpace.SHARED) }
        currentUserId = userId; personalRecognition = personal; sharedCategories = shared
        isPhotosAdministrator = identity.optionalBoolean("is_admin") == true
        currentUserUid = (identity["uid"] as? JsonPrimitive)?.takeIf(SynologyPhotoSharingCodec::validId)
        managesSharedSpace = teamEnabled && teamPermission == "management"
        defaultFolderSort = SynologyPhotoFolderCodec.sort(user, fieldKey = "item_sort_by")
        supportsOriginalSizeJPEG = runCatching { user.optionalObject("ame_status")?.optionalBoolean("has_hevc") == true &&
            admin.optionalBoolean("enable_converted_original_jpeg") == true }.getOrDefault(false)
        hasPhotosAccess = true
        return SynologyPhotoAccess(allowedSpaces.toList(), packageVersion, managesSharedSpace, runCatching { SynologyPhotoSettingsCodec.display(user) }.getOrNull(), supportsOriginalSizeJPEG)
    }

    override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?): List<SynologyPhotoDay> {
        requireAccess(space)
        if (query is SynologyPhotoQuery.Category && space == SynologyPhotoSpace.PERSONAL && personalRecognition[query.category] == false) denied()
        val parameters = mutableMapOf<String, JsonElement>("timeline_group_unit" to JsonPrimitive("day"))
        var api = "Browse.Timeline"
        var version = 5
        var method = "get"
        when (query) {
            null, is SynologyPhotoQuery.Timeline -> Unit
            is SynologyPhotoQuery.Similar -> { requireSimilarAccess(space); api = "Browse.SimilarTimeline"; version = 1; method = "get_similar" }
            is SynologyPhotoQuery.Search -> {
                api = "Search.Search"; version = 2; method = "get_search_timeline"
                parameters["keyword"] = JsonPrimitive(query.keyword)
            }
            is SynologyPhotoQuery.Filtered -> {
                version = 3; method = "get_with_filter"
                parameters.putAll(SynologyPhotosCodec.filterParameters(query.filter))
            }
            is SynologyPhotoQuery.Category -> parameters[categoryParameter(query.category)] = JsonPrimitive(query.id.also { if (it <= 0) invalid() })
            else -> invalid()
        }
        return SynologyPhotosCodec.days(read(api, version, method, parameters, space))
    }

    override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int): SynologyPhotoPage {
        val scope = space.takeUnless { query is SynologyPhotoQuery.Album }
        requireAccess(scope)
        if (query is SynologyPhotoQuery.Category && space == SynologyPhotoSpace.PERSONAL && personalRecognition[query.category] == false) denied()
        val parameters = pageParameters(offset, limit).toMutableMap()
        parameters["additional"] = array("thumbnail", "resolution", "orientation", "video_convert", "video_meta", "address")
        var api = "Browse.Item"
        var version = 4
        var method = "list"
        fun range(start: Long, end: Long) {
            SynologyPhotosCodec.time(start, end)
            parameters["start_time"] = JsonPrimitive(start)
            parameters["end_time"] = JsonPrimitive(end)
        }
        when (query) {
            is SynologyPhotoQuery.Timeline -> range(query.start, query.end)
            is SynologyPhotoQuery.Similar -> { requireSimilarAccess(space); api = "Browse.SimilarItem"; version = 1; method = "list_similar"; range(query.start, query.end) }
            is SynologyPhotoQuery.Search -> {
                api = "Search.Search"; version = 1; method = "list_item"
                parameters["keyword"] = JsonPrimitive(query.keyword)
                range(query.start, query.end)
            }
            is SynologyPhotoQuery.Folder -> {
                if (query.id <= 0) invalid()
                parameters.putAll(json("folder_id" to query.id, "sort_by" to query.sort.field.value, "sort_direction" to query.sort.direction.value))
                parameters["additional"] = array("thumbnail", "resolution", "orientation", "video_convert", "video_meta")
            }
            is SynologyPhotoQuery.Album -> {
                if (query.id <= 0) invalid()
                parameters.putAll(json("album_id" to query.id, "sort_by" to query.sort.field.value, "sort_direction" to query.sort.direction.value))
                parameters["additional"] = array("thumbnail", "resolution", "orientation", "video_convert", "video_meta", "provider_user_id")
            }
            SynologyPhotoQuery.Recent -> { api = "Browse.RecentlyAdded"; version = 1; parameters["additional"] = array("thumbnail") }
            is SynologyPhotoQuery.Filtered -> {
                version = 2; method = "list_with_filter"
                parameters.putAll(SynologyPhotosCodec.filterParameters(query.filter))
                SynologyPhotosCodec.time(query.start, query.end)
                val start = maxOf(query.start, query.filter.startTime ?: query.start)
                val end = minOf(query.end, query.filter.endTime ?: query.end)
                if (start > end) return SynologyPhotoPage(emptyList(), offset, offset, false)
                parameters["time"] = SynologyPhotosCodec.time(start, end)
            }
            is SynologyPhotoQuery.Category -> {
                if (query.id <= 0) invalid()
                parameters[categoryParameter(query.category)] = JsonPrimitive(query.id)
                range(query.start, query.end)
            }
        }
        val payload = read(api, version, method, parameters, scope).list()
        val items = payload.map { item ->
            if (query is SynologyPhotoQuery.Album) {
                val owner = item.number("owner_user_id").also { if (it < 0) invalid() }
                val provider = item.optionalObject("additional")?.optionalLong("provider_user_id")?.also { if (it < 0) invalid() }
                val context = SynologyPhotoAlbumContext(query.id, owner, provider)
                SynologyPhotosCodec.photo(item, profileId, if (owner == 0L) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL, context)
            } else SynologyPhotosCodec.photo(item, profileId, space).let { photo ->
                if (query !is SynologyPhotoQuery.Similar) photo else {
                    val group = SynologyPhotoSimilarCodec.group(item.obj("similar"), profileId, space)!!
                    if (photo.id.itemId !in group.photoIds) invalid()
                    photo.copy(similarGroup = group)
                }
            }
        }
        if (items.size > limit || items.map { it.id }.distinct().size != items.size) invalid()
        // 游标按服务端原始条数推进，不使用时间轴计数、客户端去重后的数量或虚构 total。
        return SynologyPhotoPage(items, offset, offset + payload.size, payload.size == limit)
    }

    override suspend fun rootFolder(space: SynologyPhotoSpace): SynologyPhotoCollection {
        requireAccess(space)
        val folder = read("Browse.Folder", 2, "get", json("name" to "/", "additional" to array("access_permission")), space).obj("folder")
        if (!(space == SynologyPhotoSpace.SHARED && managesSharedSpace) &&
            folder.optionalObject("additional")?.optionalObject("access_permission")?.permission("view") != true) denied()
        return SynologyPhotosCodec.collection(folder, folder = true).copy(space = space, sort = SynologyPhotoFolderCodec.sort(folder, defaultFolderSort))
    }

    override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int): List<SynologyPhotoCollection> =
        folders(space, parentId, offset, limit, SynologyPhotoSort.Direction.ASCENDING)

    override suspend fun folders(space: SynologyPhotoSpace, parentId: Long, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction): List<SynologyPhotoCollection> {
        requireAccess(space)
        if (parentId <= 0) invalid()
        val parameters = pageParameters(offset, limit) + json("id" to parentId, "sort_by" to "filename",
            "sort_direction" to direction.value, "additional" to array("thumbnail"))
        return SynologyPhotosCodec.collectionPage(read("Browse.Folder", 2, "list", parameters, space), limit, folder = true, parentId = parentId).map { it.copy(space = space) }
    }

    override suspend fun albums(offset: Int, limit: Int): List<SynologyPhotoCollection> = albums(offset, limit, null, null)
    override suspend fun albums(offset: Int, limit: Int, display: SynologyPhotoAlbumDisplay?, sort: SynologyPhotoAlbumListSort?): List<SynologyPhotoCollection> {
        if (sort != null && sort.field !in SynologyPhotoAlbumListScope.ALBUMS.fields) invalid()
        var parameters = pageParameters(offset, limit) + json("category" to (display ?: SynologyPhotoAlbumDisplay.ALL).category,
            "additional" to array("thumbnail", "sharing_info"))
        if (sort != null) parameters += json("sort_by" to sort.field.value, "sort_direction" to sort.direction.value)
        return SynologyPhotosCodec.collectionPage(read("Browse.Album", 4, "list", parameters), limit)
    }

    override suspend fun categories(space: SynologyPhotoSpace): Set<SynologyPhotoCategory> {
        requireAccess(space)
        if (space == SynologyPhotoSpace.SHARED && !managesSharedSpace) return emptySet()
        return read("Browse.Category", 3, "get").list().mapNotNull { entry ->
            SynologyPhotoCategory.entries.firstOrNull { it.serverId == entry.text("id") }
        }.filter { category ->
            if (category == SynologyPhotoCategory.SIMILAR) runCatching { requireSimilarAccess(space) }.isSuccess
            else if (space == SynologyPhotoSpace.PERSONAL) personalRecognition[category] != false else {
                val (suffix, version) = categoryCapability(category)
                category in sharedCategories && runCatching { capability(suffix, version, space) }.isSuccess
            }
        }.toSet()
    }

    override suspend fun categoryItems(category: SynologyPhotoCategory, offset: Int, limit: Int, space: SynologyPhotoSpace): List<SynologyPhotoCollection> {
        requireAccess(space)
        if (space == SynologyPhotoSpace.SHARED && (!managesSharedSpace || category !in sharedCategories) ||
            space == SynologyPhotoSpace.PERSONAL && personalRecognition[category] == false) denied()
        if (category in setOf(SynologyPhotoCategory.RECENT, SynologyPhotoCategory.VIDEOS, SynologyPhotoCategory.SIMILAR)) invalid()
        if (category == SynologyPhotoCategory.SUBJECTS) return albumMutations.conceptPage(space, offset, limit)
        if (category == SynologyPhotoCategory.PEOPLE) return albumMutations.personPage(space, offset, limit)
        val (suffix, version) = categoryCapability(category)
        return SynologyPhotosCodec.collectionPage(read(suffix, version, "list",
            pageParameters(offset, limit) + json("additional" to array("thumbnail")), space), limit).map { it.copy(space = space) }
    }

    private fun categoryCapability(category: SynologyPhotoCategory): Pair<String, Int> = when (category) {
        SynologyPhotoCategory.PEOPLE -> "Browse.Person" to 1
        SynologyPhotoCategory.SUBJECTS -> "Browse.Concept" to 2
        SynologyPhotoCategory.LOCATIONS -> "Browse.Geocoding" to 1
        SynologyPhotoCategory.TAGS -> "Browse.GeneralTag" to 1
        SynologyPhotoCategory.RECENT -> "Browse.RecentlyAdded" to 1
        SynologyPhotoCategory.VIDEOS -> "Browse.Item" to 4
        SynologyPhotoCategory.SIMILAR -> "Browse.SimilarItem" to 1
    }

    override suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int): List<SynologyPhotoSharedEntry> = sharedEntries(scope, offset, limit, null)
    override suspend fun sharedEntries(scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?): List<SynologyPhotoSharedEntry> {
        if (sort != null && (scope == SynologyPhotoShareScope.REQUESTS || sort.field !in SynologyPhotoAlbumListScope.WITH_ME.fields)) invalid()
        var parameters = pageParameters(offset, limit)
        if (sort != null) parameters += json("sort_by" to sort.field.value, "sort_direction" to sort.direction.value)
        val values: List<SynologyPhotoSharedEntry>
        when (scope) {
            SynologyPhotoShareScope.REQUESTS -> values = read("PhotoRequest", 1, "list", parameters).list().map {
                SynologyPhotoSharedEntry(it.text("passphrase"), it.text("subject"), url = safeSharingUrl(it.optionalText("sharing_link")))
            }
            SynologyPhotoShareScope.WITH_ME -> {
                parameters += json("additional" to array("sharing_info", "thumbnail", "access_permission"))
                values = read("Sharing.Misc", 2, "list_shared_with_me_album", parameters).list().map(::sharedAlbum)
            }
            SynologyPhotoShareScope.WITH_OTHERS -> {
                parameters += json("category" to "shared", "sort_by" to (sort?.field?.value ?: "share_modify_time"), "sort_direction" to (sort?.direction?.value ?: "desc"),
                    "additional" to array("thumbnail", "sharing_info"))
                values = read("Browse.Album", 4, "list", parameters).list().map(::sharedAlbum)
            }
        }
        if (values.size > limit || values.map { it.id }.distinct().size != values.size) invalid()
        return values
    }

    override suspend fun filterOptions(space: SynologyPhotoSpace): SynologyPhotoFilterOptions = SynologyPhotosCodec.filterOptions(read("Search.Filter", 3, "list",
        json("additional" to array("thumbnail"), "setting" to JsonObject(listOf(
            "item_type", "time", "person", "geocoding", "rating", "general_tag", "camera", "lens", "iso", "aperture",
            "focal_length_group", "exposure_time_group",
        ).associateWith { JsonPrimitive(true) })), space))

    override suspend fun thumbnail(photo: SynologyPhoto, large: Boolean): ByteArray {
        requireReadablePhoto(photo)
        val generation = accessGeneration.get()
        val result = media().thumbnail(photo.thumbnail ?: invalid(), large, photo.id.space, photo.albumContext?.albumId)
        requireGeneration(generation, readSpace(photo))
        return result
    }

    override suspend fun details(photo: SynologyPhoto): SynologyPhoto {
        requireReadablePhoto(photo)
        val item = readPhoto(photo, "Browse.Item", 5, "get", json("id" to array(photo.id.itemId), "additional" to array(
            "description", "tag", "exif", "resolution", "orientation", "gps", "video_meta", "video_convert", "thumbnail",
            "address", "geocoding_id", "rating", "motion_photo", "person", "provider_user_id",
        ))).list().singleOrNull() ?: invalid()
        val context = photo.albumContext?.let {
            if (item.number("owner_user_id") != it.ownerUserId) invalid()
            it.copy(providerUserId = item.optionalObject("additional")?.optionalLong("provider_user_id")?.also { id -> if (id < 0) invalid() })
        }
        return SynologyPhotosCodec.photo(item, profileId, photo.id.space, context).copy(similarGroup = photo.similarGroup).also { if (it.id != photo.id) invalid() }
    }

    /** 测试可独立核对选源；实况必须使用视频单元 ID，不复用照片或缩略图单元 ID。 */
    internal suspend fun videoRequest(photo: SynologyPhoto): Pair<ApiCapability, Pair<String, Map<String, String>>> {
        requireReadablePhoto(photo)
        if (photo.mediaType !in setOf("video", "live")) invalid()
        val entry: JsonObject
        var id = photo.id.itemId
        var type = "item"
        if (photo.mediaType == "live") {
            val parent = readPhoto(photo, "Browse.Unit", 1, "get", json("id_item" to array(id), "additional" to array(
                "orientation", "resolution", "thumbnail", "video_meta", "video_convert",
            ))).list().singleOrNull() ?: invalid()
            if (parent.number("id_item") != id) invalid()
            entry = parent.list("unit").filter { it.text("live_type") == "video" }.singleOrNull() ?: invalid()
            id = entry.positive("id"); type = "unit"
        } else {
            entry = readPhoto(photo, "Browse.Item", 5, "get", json("id" to array(id), "additional" to array("video_convert"))).list().singleOrNull() ?: invalid()
            if (entry.number("id") != id || entry.text("type") != "video") invalid()
        }
        val conversions = entry.optionalObject("additional")?.optionalList("video_convert").orEmpty().map { it.text("quality") }
        val quality = listOf("raw", "orig_h264", "high", "medium", "low", "mobile").firstOrNull { it in conversions }
        return if (quality == null || quality == "raw") {
            capability("Download", 2, readSpace(photo)) to ("download" to encode(readParameters(photo, json((if (type == "unit") "unit_id" else "item_id") to array(id)))))
        } else {
            capability("Streaming", 2, readSpace(photo)) to ("streaming" to encode(readParameters(photo, json("id" to id, "type" to type, "quality" to quality, "use_mov" to true))))
        }
    }

    override suspend fun videoSource(photo: SynologyPhoto): RandomAccessMediaSource {
        val generation = accessGeneration.get()
        val (capability, request) = videoRequest(photo)
        val source = media().video(capability, request.first, request.second)
        try { requireGeneration(generation, readSpace(photo)); return source } catch (error: Throwable) { source.close(); throw error }
    }

    private val exports = SynologyPhotosExportRepository(profileId, accessGeneration::get, ::requireGeneration,
        { currentUserId }, { allowedSpaces }, { managesSharedSpace }, { supportsOriginalSizeJPEG }, ::capability, ::read, ::call,
        ::details, albumMutations::downloadContext, { photo, operation -> deletions.pending(photo) || edits.pending(photo) || albumMutations.pending(photo, operation) }, ::media)
    override suspend fun downloadOriginal(photo: SynologyPhoto, destination: File, progress: (Long, Long) -> Unit) {
        download(photo, SynologyPhotoDownloadFormat.ORIGINAL, destination, progress)
    }
    override suspend fun download(photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, destination: File, progress: (Long, Long) -> Unit) =
        exports.download(photo, format, destination, progress)
    override suspend fun downloadArchive(target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, destination: File, progress: (Long, Long) -> Unit) =
        exports.archive(target, format, destination, progress)

    private val deletions: SynologyPhotosDeletionRepository = SynologyPhotosDeletionRepository(identity = ::mutationAccess,
        checkAccess = { expected, space ->
            requireGeneration(expected.generation, space)
            if (mutationAccess() != expected) denied()
        }, capability = ::capability, read = ::read, write = ::call,
        photoPending = { edits.pending(it) || albumMutations.pending(it) }, enabled = { canDeleteOriginals })
    override suspend fun prepareDeletion(photo: SynologyPhoto) = deletions.prepare(photo)
    override suspend fun deletionTarget(checkpoint: SynologyPhotoDeletionCheckpoint) = deletions.target(checkpoint)
    override suspend fun performPhotoDeletion(photo: SynologyPhoto, checkpoint: SynologyPhotoDeletionCheckpoint,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit) = deletions.perform(photo, checkpoint, save)
    override suspend fun reviewPhotoDeletion(checkpoint: SynologyPhotoDeletionCheckpoint,
        save: (SynologyPhotoDeletionCheckpoint) -> Unit) = deletions.review(checkpoint, save)
    override fun canDelete(photo: SynologyPhoto): Boolean = canDeleteOriginals && photo.id.profileId == profileId &&
        photo.id.space in allowedSpaces && (photo.id.space == SynologyPhotoSpace.SHARED ||
            photo.albumContext == null || photo.albumContext.ownerUserId == currentUserId)

    private fun requireReadablePhoto(photo: SynologyPhoto) {
        if (photo.id.profileId != profileId || photo.id.itemId <= 0) denied()
        val context = photo.albumContext
        requireAccess(readSpace(photo))
        if (context != null && (context.albumId <= 0 || context.ownerUserId < 0 ||
            photo.id.space != if (context.ownerUserId == 0L) SynologyPhotoSpace.SHARED else SynologyPhotoSpace.PERSONAL)) denied()
    }
    private fun readSpace(photo: SynologyPhoto): SynologyPhotoSpace? = photo.id.space.takeIf { photo.albumContext == null }
    private fun readParameters(photo: SynologyPhoto, parameters: Map<String, JsonElement>): Map<String, JsonElement> =
        photo.albumContext?.let { parameters + json("album_id" to it.albumId) } ?: parameters
    private suspend fun readPhoto(photo: SynologyPhoto, suffix: String, version: Int, method: String, parameters: Map<String, JsonElement>): JsonObject =
        read(suffix, version, method, readParameters(photo, parameters), readSpace(photo))
    private fun requireAccess(space: SynologyPhotoSpace? = null) {
        if (!hasPhotosAccess || space != null && space !in allowedSpaces) denied()
    }
    private suspend fun requireGeneration(generation: Long, space: SynologyPhotoSpace? = null) {
        currentCoroutineContext().ensureActive()
        if (generation != accessGeneration.get()) throw CancellationException()
        requireAccess(space)
    }
    private suspend fun read(suffix: String, version: Int, method: String, parameters: Map<String, JsonElement> = emptyMap(), space: SynologyPhotoSpace? = null): JsonObject {
        requireAccess(space)
        val generation = accessGeneration.get()
        return call(suffix, version, method, parameters, space).also { requireGeneration(generation, space) }
    }
    private suspend fun call(suffix: String, version: Int, method: String, parameters: Map<String, JsonElement> = emptyMap(), space: SynologyPhotoSpace? = null): JsonObject =
        callTransport(capability(suffix, version, space), method, encode(parameters))
    private fun capability(suffix: String, version: Int, space: SynologyPhotoSpace? = null): ApiCapability {
        val name = "${if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam" else "SYNO.Foto"}.$suffix"
        val value = capabilities[name] ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
        if (value.name != name || version !in value.minVersion..value.maxVersion || !value.requestFormat.equals("JSON", true)) {
            throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
        }
        try { photoApiPath(value.path) } catch (_: IllegalArgumentException) { throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE) }
        return value.copy(minVersion = version, maxVersion = version)
    }
    private fun media(): SynologyPhotosMediaTransport = media ?: throw SynologyPhotoFailure(SynologyPhotoFailureKind.UNAVAILABLE)
    private fun pageParameters(offset: Int, limit: Int): Map<String, JsonElement> {
        if (offset < 0 || limit !in 1..500 || offset > Int.MAX_VALUE - limit) invalid()
        return json("offset" to offset, "limit" to limit)
    }
    private fun categoryParameter(category: SynologyPhotoCategory): String = category.parameter ?: invalid()
    private fun sharedAlbum(value: JsonObject): SynologyPhotoSharedEntry = value.positive("id").let {
        SynologyPhotoSharedEntry(it.toString(), value.text("name"), albumId = it, isTemporary = value.optionalBoolean("temporary_shared") == true)
    }
    private fun safeSharingUrl(value: String?): String? = value?.let {
        runCatching { URI(it) }.getOrNull()?.takeIf { uri -> uri.scheme == "https" && uri.host != null && uri.userInfo == null }?.toString()
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
