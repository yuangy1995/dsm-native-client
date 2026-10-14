package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhotoPreviewFact.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoConvertedPreview
import io.github.qwertyuiop1995.dsmnativeclient.network.SynologyPhotoPreviewEvents
import java.io.File
import java.nio.file.Files
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** 一次用户确认对应固定原件集合；每次写前保存事实，冷恢复只读。 */
internal class SynologyPhotosPreviewRepository(
    private val access: SynologyPhotosPreviewAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val download: suspend (SynologyPhoto, File, String) -> Unit,
    private val convert: suspend (File, String) -> SynologyPhotoConvertedPreview,
    private val upload: suspend (ApiCapability, Long, SynologyPhotoConvertedPreview) -> Boolean,
    private val events: () -> SynologyPhotoPreviewEvents,
) {
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess, cache: File?,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        fun progress(index: Int) = row.previews!!.progress[index]
        fun append(index: Int, vararg facts: SynologyPhotoPreviewFact) {
            val value = row.previews!!
            val next = row.copy(previews = value.copy(progress = value.progress.mapIndexed { i, item -> if (i == index) item.adding(*facts) else item }))
            persist(next); row = next
        }
        suspend fun mark(index: Int, target: SynologyPhotoEditTarget) {
            if (MARKED in progress(index)) return
            access.validateTarget(target, owner)
            if (row.previews!!.resuming) {
                if (access.queue(target.id.space, owner).none { it.matches(target) }) changed()
            } else {
                append(index, MARK_ATTEMPTED)
                val receipt = try {
                    write("RegeneratePreview", 1, "set_regenerating", json("item_id" to array(target.id.itemId)), target.id.space)
                } catch (error: Exception) {
                    if (rejected(error)) append(index, MARK_REJECTED, FAILED)
                    throw error
                }
                val entries = SynologyPhotoPreviewRegenerationCodec.queue(receipt)
                if (entries.size != 1 || !entries.single().matches(target)) invalid()
            }
            checkAccess(owner, target.id.space); append(index, MARKED)
        }
        suspend fun sendLocal(index: Int, target: SynologyPhotoEditTarget, prepared: SynologyPhotoConvertedPreview): Boolean {
            mark(index, target)
            access.validateTarget(target, owner); currentCoroutineContext().ensureActive()
            append(index, LOCAL_ATTEMPTED)
            val accepted = try { upload(capability("Upload.ConvertedFile", 3, target.id.space), target.id.itemId, prepared) }
            catch (error: Exception) {
                if (rejected(error)) append(index, LOCAL_REJECTED)
                throw error
            }
            checkAccess(owner, target.id.space)
            append(index, if (accepted) GENERATED else LOCAL_REJECTED)
            return accepted
        }
        suspend fun finishFailure(index: Int, target: SynologyPhotoEditTarget) {
            val state = progress(index)
            if (state.unknownSubmission) return
            if (state.submitted) {
                access.validateTarget(target, owner); currentCoroutineContext().ensureActive()
                append(index, RESTORE_ATTEMPTED)
                write("RegeneratePreview", 1, "restore_from_regenerating", json("unit_id" to array(target.id.itemId)), target.id.space)
                checkAccess(owner, target.id.space)
                // 还原回执不能代替队列结果；最终仅由只读恢复确认失败终态。
            } else append(index, FAILED)
        }

        for ((index, target) in row.targets.withIndex()) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
            val localFirst = target.filename.substringAfterLast('.', "").lowercase(Locale.ROOT) == "png"
            if (localFirst) {
                val prepared = local(target, owner, cache, row.operationId)
                if (prepared != null && sendLocal(index, target, prepared)) continue
            }
            var connection: SynologyPhotoPreviewEvents? = null
            try {
                try { connection = events(); connection.subscribe(target.id.itemId) }
                catch (error: Exception) {
                    currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
                    // 尚无NAS生成在途；本机转换仍是独立可用路径。
                    if (!localFirst) {
                        val prepared = local(target, owner, cache, row.operationId)
                        if (prepared != null && sendLocal(index, target, prepared)) continue
                    }
                    finishFailure(index, target); continue
                }
                mark(index, target)
                access.validateTarget(target, owner); currentCoroutineContext().ensureActive()
                append(index, NAS_ATTEMPTED)
                val accepted = try {
                    write("RegeneratePreview", 1, "regenerate_preview_by_nas", json("unit_id" to target.id.itemId), target.id.space)
                    true
                } catch (error: Exception) {
                    if (!rejected(error)) throw error
                    append(index, NAS_REJECTED)
                    if (error is DsmFailure && error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED)) throw error
                    false
                }
                val success = accepted && connection!!.completion()
                checkAccess(owner, target.id.space)
                if (success) { append(index, GENERATED); continue }
                if (accepted) append(index, NAS_FAILED)
                if (!localFirst) {
                    val prepared = local(target, owner, cache, row.operationId)
                    if (prepared != null && sendLocal(index, target, prepared)) continue
                }
                finishFailure(index, target)
            } finally { connection?.close() }
        }
        return row
    }

    private suspend fun local(target: SynologyPhotoEditTarget, owner: SynologyPhotosMutationAccess, cache: File?, operationId: String): SynologyPhotoConvertedPreview? {
        if (cache == null || target.mediaType !in setOf("photo", "video") ||
            runCatching { capability("Upload.ConvertedFile", 3, target.id.space) }.isFailure) return null
        checkAccess(owner, target.id.space)
        val directory = Files.createTempDirectory(cache.toPath(), "synology-photos-preview-$operationId-").toFile()
        val converted = try {
            val source = File(directory, "source")
            download(target.photo(), source, operationId)
            convert(source, target.mediaType)
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
            if (error is DsmFailure && error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED) ||
                error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.TARGET_CHANGED) throw error
            // 原件下载可能单独受限；只有维护资格仍成立才允许无原件下载的NAS分支。
            if (error is SynologyPhotoFailure && error.kind == SynologyPhotoFailureKind.PERMISSION) access.validateTarget(target, owner)
            null
        } finally {
            if (!directory.deleteRecursively()) throw java.io.IOException("Photo preview temporary cleanup failed")
        }
        if (converted != null) access.validateTarget(target, owner)
        return converted
    }

    suspend fun review(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        SynologyPhotoPreviewRegenerationCodec.validate(input)
        var states = input.previews!!.progress.toMutableList()
        val completed = input.completed.toMutableSet()
        for ((index, target) in input.targets.withIndex()) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, target.id.space)
            var state = states[index]
            if (state.failed) continue
            try {
                if (state.generated) {
                    val photo = access.readTarget(target, owner)
                    if (RECOVERED in state && !changedThumbnail(state, photo)) continue
                    completed += index
                } else if (!state.submitted) {
                    if (MARK_ATTEMPTED !in state || MARKED in state || MARK_REJECTED in state) state = state.adding(FAILED)
                    else if (access.queue(target.id.space, owner).any { it.matches(target) }) {
                        access.validateTarget(target, owner)
                        state = state.adding(MARKED, FAILED)
                    }
                } else if (RESTORE_ATTEMPTED in state) {
                    if (access.queue(target.id.space, owner).none { it.id == target.id.itemId }) {
                        access.readTarget(target, owner)
                        state = state.adding(RESTORED, FAILED)
                    }
                } else if (!state.unknownSubmission) state = state.adding(FAILED)
                else if (access.queue(target.id.space, owner).none { it.id == target.id.itemId }) {
                    val photo = access.readTarget(target, owner)
                    if (changedThumbnail(state, photo) && access.queue(target.id.space, owner).none { it.id == target.id.itemId }) {
                        state = state.adding(GENERATED, RECOVERED); completed += index
                    }
                }
                states[index] = state
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                checkAccess(owner, target.id.space)
                // 保留本项未知和其他项已知结果，读取失败不触发任何写入。
            }
        }
        val resolved = states.indices.all { it in completed || states[it].failed }
        return input.copy(previews = input.previews.copy(progress = states), completed = completed,
            phase = if (!resolved) SynologyPhotoAlbumPhase.PENDING else if (completed.size == states.size)
                SynologyPhotoAlbumPhase.COMPLETED else SynologyPhotoAlbumPhase.PARTIAL)
    }

    private fun changedThumbnail(state: SynologyPhotoPreviewProgress, photo: SynologyPhoto): Boolean =
        state.baselineUnitId != null && !state.baselineRevision.isNullOrEmpty() && photo.thumbnail?.let {
            it.unitId == state.baselineUnitId && it.revision.isNotEmpty() && it.revision != state.baselineRevision
        } == true
    private fun rejected(error: Exception) = error is DsmFailure && error.code != null &&
        error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
