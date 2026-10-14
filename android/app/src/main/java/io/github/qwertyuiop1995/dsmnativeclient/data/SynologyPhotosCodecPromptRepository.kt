package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 新格式提示统一 Foto 路由；全用户生成只确认接收，不以单一来源计数证明完成。 */
internal class SynologyPhotosCodecPromptRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    suspend fun prompt(): SynologyPhotoCodecPrompt = prompt(identity())
    private suspend fun prompt(owner: SynologyPhotosMutationAccess): SynologyPhotoCodecPrompt {
        checkAccess(owner, null)
        listOf("UserInfo", "Setting.User", "Setting.Wizard").forEach { capability(it, 1, null) }
        val actual = read("UserInfo", 1, "me", emptyMap(), null)
        if (!actual.boolean("enabled") || actual.positive("id") != owner.userId) denied()
        val administrator = actual.boolean("is_admin")
        val home = read("Setting.User", 1, "get", emptyMap(), null).boolean("enable_home_service")
        val show = SynologyPhotoCodecPromptCodec.shouldShow(read("Setting.Wizard", 1, "get", emptyMap(), null))
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
        return SynologyPhotoCodecPrompt(owner.profileId, owner.userId, administrator, show, home)
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        SynologyPhotoCodecPromptCodec.validate(row)
        val value = row.codecPrompt!!
        if (value.original.profileId != owner.profileId || value.original.userId != owner.userId || prompt(owner) != value.original) changed()
        if (value.generate && !value.generationAcknowledged) capability("Index", 1, null)
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        prepare(input, owner)
        var row = input
        if (row.codecPrompt!!.generate) {
            row = row.copy(codecPrompt = row.codecPrompt!!.copy(generationAttempted = true))
            currentCoroutineContext().ensureActive(); checkAccess(owner, null); persist(row)
            try { write("Index", 1, if (row.codecPrompt!!.original.isAdministrator) "reindex_all_user" else "reindex", json("type" to "thumbnail"), null) }
            catch (error: DsmFailure) {
                if (rejected(error)) persist(row.copy(codecPrompt = row.codecPrompt!!.copy(generationRejected = true)))
                throw error
            }
            row = row.copy(codecPrompt = row.codecPrompt!!.copy(generationAcknowledged = true)); persist(row)
        }
        return savePrompt(row, owner, persist)
    }
    suspend fun continuePrompt(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        if (row.codecPrompt?.canContinue != true) changed()
        prepare(row, owner)
        return savePrompt(row.copy(phase = SynologyPhotoAlbumPhase.PENDING), owner, persist)
    }
    private suspend fun savePrompt(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        val value = input.codecPrompt!!
        val row = input.copy(codecPrompt = value.copy(promptAttempts = Math.addExact(value.promptAttempts, 1)))
        currentCoroutineContext().ensureActive(); checkAccess(owner, null); persist(row)
        val fields = json("prompt" to JsonArray(listOf(JsonObject(json("name" to "new_codec_installed", "show" to false)))))
        try { write("Setting.Wizard", 1, "set", fields, null) }
        catch (error: DsmFailure) {
            if (rejected(error)) persist(row.copy(codecPrompt = row.codecPrompt!!.copy(promptRejections = value.promptRejections + 1)))
            throw error
        }
        return row.copy(codecPrompt = row.codecPrompt!!.copy(promptAcknowledged = true)).also(persist)
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        checkAccess(owner, null)
        val value = row.codecPrompt!!
        if (value.generate && (!value.generationAttempted || value.generationRejected) ||
            !value.generate && value.promptAttempts == value.promptRejections) return row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
        val actual = prompt(owner)
        return when {
            !actual.shouldShow && (!value.generate || value.generationAcknowledged) ->
                row.copy(codecPrompt = value.copy(promptClosed = true), phase = SynologyPhotoAlbumPhase.COMPLETED)
            value.canContinue -> row.copy(phase = SynologyPhotoAlbumPhase.PARTIAL)
            else -> row.copy(phase = SynologyPhotoAlbumPhase.PENDING)
        }
    }
    private fun rejected(error: DsmFailure) = error.code != null && error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE)
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
