package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.serialization.json.*

internal object SynologyPhotoCodecPromptCodec {
    fun shouldShow(value: JsonObject): Boolean {
        val prompts = value["prompt"] as? JsonArray ?: invalid()
        val entries = prompts.map { raw ->
            val entry = raw as? JsonObject ?: invalid()
            entry.text("name") to entry.boolean("show")
        }.filter { it.first == "new_codec_installed" }
        if (entries.size > 1) invalid()
        return entries.singleOrNull()?.second ?: false
    }
    fun validate(row: SynologyPhotoAlbumCheckpoint) {
        val value = row.codecPrompt ?: invalid(); val original = value.original
        if (original.profileId != row.profileId || original.userId != row.userId || !original.shouldShow ||
            value.generate && !original.canGenerate || row.album != null || row.name != null || row.targets.isNotEmpty() ||
            !row.submitted && (value.generationAttempted || value.promptAttempts != 0 || value.promptClosed) ||
            value.generationAttempted && !value.generate || value.generationAcknowledged && (!value.generationAttempted || value.generationRejected) ||
            value.generationRejected && !value.generationAttempted ||
            value.promptAttempts < 0 || value.promptRejections < 0 || value.promptRejections > value.promptAttempts ||
            value.promptAttempts - value.promptRejections > 1 || value.promptAttempts > 0 && value.generate && !value.generationAcknowledged ||
            value.promptAcknowledged && value.promptAttempts != value.promptRejections + 1 ||
            value.promptClosed && (value.generate && !value.generationAcknowledged || !value.generate && value.promptAttempts == 0) ||
            row.phase == SynologyPhotoAlbumPhase.COMPLETED && !value.promptClosed ||
            row.phase == SynologyPhotoAlbumPhase.PARTIAL && (if (value.generate)
                value.generationAttempted && !value.generationRejected && !value.canContinue
            else value.promptAttempts != value.promptRejections)) invalid()
    }
    fun advances(before: SynologyPhotoCodecCheckpoint, next: SynologyPhotoCodecCheckpoint): Boolean =
        (!before.generationAttempted || next.generationAttempted) && (!before.generationAcknowledged || next.generationAcknowledged) &&
            (!before.generationRejected || next.generationRejected) && (!before.promptAcknowledged || next.promptAcknowledged) &&
            (!before.promptClosed || next.promptClosed) && next.promptAttempts >= before.promptAttempts && next.promptRejections >= before.promptRejections
}
