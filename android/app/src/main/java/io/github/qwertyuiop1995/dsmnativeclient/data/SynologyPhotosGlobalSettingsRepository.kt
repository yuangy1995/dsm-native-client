package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 全局多步保存顺序固定，恢复只读已尝试步骤，不补发未执行的后续步骤。 */
internal class SynologyPhotosGlobalSettingsRepository(
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val settings: suspend (SynologyPhotoSettingsKind, SynologyPhotosMutationAccess) -> SynologyPhotoSettings,
) {
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        for (step in SynologyPhotoGlobalSettingsCodec.steps(input.settings!!)) {
            currentCoroutineContext().ensureActive(); checkAccess(owner, null)
            var value = row.settings!!; var progress = value.globalProgress!!
            progress = progress.copy(attempted = progress.attempted + step.kind)
            row = row.copy(settings = value.copy(attempted = true, globalProgress = progress)); persist(row)
            try { write(step.api, step.version, step.method, step.fields, null) }
            catch (error: DsmFailure) {
                if (error.code in setOf(105, 106, 107, 119)) {
                    row = row.copy(settings = row.settings!!.copy(globalProgress = progress.copy(rejected = progress.rejected + step.kind))); persist(row)
                }
                throw error
            }
            value = row.settings!!
            row = row.copy(settings = value.copy(globalProgress = progress.copy(acknowledged = progress.acknowledged + step.kind))); persist(row)
        }
        return row
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        checkAccess(owner, null)
        val value = row.settings!!; val progress = value.globalProgress!!; val steps = SynologyPhotoGlobalSettingsCodec.steps(value)
        val matched = mutableSetOf<SynologyPhotoGlobalStep>()
        if (progress.attempted.isNotEmpty()) {
            val actual = if (value.original is SynologyPhotoGlobalSettings) settings(SynologyPhotoSettingsKind.GLOBAL, owner) as SynologyPhotoGlobalSettings else null
            for (step in steps.filter { it.kind in progress.attempted && it.kind !in progress.rejected }) {
                val matches = if (step.kind == SynologyPhotoGlobalStep.CACHE) {
                    val cache = settings(SynologyPhotoSettingsKind.CACHE, owner) as SynologyPhotoConversionCache
                    cache.clearing == false && (step.kind in progress.acknowledged || cache.sizeBytes == 0L)
                } else actual != null && SynologyPhotoGlobalSettingsCodec.matches(step, actual)
                if (matches) matched += step.kind
            }
        }
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
        val phase = when {
            matched == steps.map { it.kind }.toSet() -> SynologyPhotoAlbumPhase.COMPLETED
            progress.attempted.all { it in matched || it in progress.rejected } -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
        return row.copy(phase = phase, settings = value.copy(rejected = phase == SynologyPhotoAlbumPhase.PARTIAL, globalProgress = progress.copy(completed = progress.completed + matched)))
    }
}
