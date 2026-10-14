package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoAutomaticPreviewConversionFailure
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoAutomaticPreviewMedia
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** 自动任务使用统一管理互斥与持久记录；恢复只能读取，绝不重放upload或set_broken。 */
internal class SynologyPhotosAutomaticPreviewMutation(
    private val access: SynologyPhotosAutomaticPreviewAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val convert: suspend (File, SynologyPhotoAutomaticPreviewTask, File) -> SynologyPhotoAutomaticPreviewMedia,
    private val upload: suspend (ApiCapability, Long, SynologyPhotoConvertedPreview?, File?) -> Boolean,
    private val thumbnail: suspend (Long, String, SynologyPhotoSpace) -> ByteArray,
    private val downloadVideo: suspend (ApiCapability, Long, File, suspend () -> Unit) -> Unit,
    private val videoSignature: suspend (File) -> SynologyPhotoPreviewVideoSignature,
) {
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoAutomaticPreviewCodec.validate(row)
        val value = row.automaticPreview!!
        if (!access.enabled()) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
        access.validate(value.task, value.support, owner)
    }

    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess, cache: File?,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        val task = row.automaticPreview!!.task
        fun save(value: SynologyPhotoAutomaticPreviewCheckpoint) {
            val next = row.copy(automaticPreview = value)
            persist(next); row = next
        }
        val directory = temporary(cache, row.operationId)
        try {
            val source = File(directory, "source")
            access.download(task, row.automaticPreview!!.support, source)
            val prepared = try { convert(source, task, File(directory, "preview.mp4")) }
            catch (error: SynologyPhotoAutomaticPreviewConversionFailure) {
                prepare(row, owner); currentCoroutineContext().ensureActive()
                if (error.kind == SynologyPhotoAutomaticPreviewFailure.PHOTO && !task.needsThumbnail ||
                    error.kind == SynologyPhotoAutomaticPreviewFailure.VIDEO && !task.needsVideo) invalid()
                save(row.automaticPreview!!.copy(failureKind = error.kind))
                try {
                    checkAccess(owner, task.space)
                    write("Upload.ConvertedFile", 3, "set_broken", json("id" to array(task.unitId),
                        "type" to array(if (error.kind == SynologyPhotoAutomaticPreviewFailure.PHOTO) "photo" else "video")), task.space)
                    checkAccess(owner, task.space)
                    save(row.automaticPreview!!.copy(failureRecorded = true))
                } catch (failure: Exception) {
                    if (rejected(failure)) save(row.automaticPreview!!.copy(failureRejected = true))
                    throw failure
                }
                return row
            }
            if ((prepared.thumbnail != null) != task.needsThumbnail || (prepared.video != null) != task.needsVideo ||
                (prepared.signature != null) != task.needsVideo || prepared.signature?.valid() == false ||
                prepared.video?.let { !it.isFile || it.length() <= 0 || it.canonicalFile.parentFile != directory.canonicalFile } == true) invalid()
            val digests = prepared.thumbnail?.let { mapOf("xl" to digest(it.large), "sm" to digest(it.small), "m" to digest(it.medium)) }.orEmpty()
            prepare(row, owner); currentCoroutineContext().ensureActive()
            save(row.automaticPreview!!.copy(uploadAttempted = true, thumbnailDigests = digests, videoSignature = prepared.signature))
            val accepted = try {
                checkAccess(owner, task.space)
                upload(capability("Upload.ConvertedFile", 3, task.space), task.unitId, prepared.thumbnail, prepared.video)
            } catch (error: Exception) {
                if (rejected(error)) save(row.automaticPreview!!.copy(uploadRejected = true))
                throw error
            }
            checkAccess(owner, task.space)
            save(row.automaticPreview!!.copy(uploadAcknowledged = accepted, uploadRejected = !accepted))
            return row
        } finally {
            if (!directory.deleteRecursively()) throw java.io.IOException("Photo automatic preview temporary cleanup failed")
        }
    }

    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess, cache: File?): SynologyPhotoAlbumCheckpoint {
        SynologyPhotoAutomaticPreviewCodec.validate(row)
        val value = row.automaticPreview!!
        val task = value.task
        currentCoroutineContext().ensureActive(); checkAccess(owner, task.space)
        if (!value.uploadAttempted && value.failureKind == null) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        val source = access.reviewSource(task, owner)
        if (value.uploadRejected || value.failureRejected) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        if (value.failureKind != null) {
            val recorded = value.failureRecorded || source?.let {
                if (value.failureKind == SynologyPhotoAutomaticPreviewFailure.PHOTO) it.large == "broken" && it.small == "broken"
                else it.videoStatus == "broken"
            } == true
            return row.copy(automaticPreview = value.copy(failureRecorded = recorded),
                phase = if (recorded) SynologyPhotoAlbumPhase.PARTIAL else SynologyPhotoAlbumPhase.PENDING)
        }
        val matched = value.uploadAcknowledged || matches(row, owner, cache)
        currentCoroutineContext().ensureActive(); checkAccess(owner, task.space)
        return row.copy(completed = if (matched) setOf(0) else emptySet(),
            phase = if (matched) SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PENDING)
    }

    private suspend fun matches(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess, cache: File?): Boolean {
        val value = row.automaticPreview!!
        val task = value.task
        for (size in listOf("xl", "sm", "m")) if (task.needsThumbnail) {
            if (digest(thumbnail(task.unitId, size, task.space)) != value.thumbnailDigests[size]) return false
            checkAccess(owner, task.space)
        }
        if (task.needsVideo) {
            val directory = temporary(cache, row.operationId)
            try {
                val file = File(directory, "review.mov")
                downloadVideo(capability("Streaming", 2, task.space), task.unitId, file) { access.reviewSource(task, owner) }
                if (videoSignature(file) != value.videoSignature) return false
            } finally { if (!directory.deleteRecursively()) throw java.io.IOException("Photo automatic preview temporary cleanup failed") }
        }
        access.reviewSource(task, owner)
        return true
    }

    private fun temporary(cache: File?, operationId: String): File {
        if (cache?.isDirectory != true) invalid()
        return Files.createTempDirectory(cache.toPath(), "synology-photos-automatic-preview-$operationId-").toFile()
    }
    private fun rejected(error: Exception) = error is DsmFailure && error.code != null &&
        error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE)
    private fun digest(bytes: ByteArray): String {
        if (bytes.isEmpty()) invalid()
        return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
