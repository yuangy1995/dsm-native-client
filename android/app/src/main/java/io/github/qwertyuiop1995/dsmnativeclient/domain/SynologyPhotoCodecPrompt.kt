package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
data class SynologyPhotoCodecPrompt(
    val profileId: String, val userId: Long, val isAdministrator: Boolean,
    val shouldShow: Boolean, val personalSpaceEnabled: Boolean,
) {
    val canGenerate: Boolean get() = shouldShow && (isAdministrator || personalSpaceEnabled)
    override fun toString() = "PhotoCodecPrompt"
}

/** 两阶段事实独立保留；提示保存只允许在明确未发送或拒绝后由用户继续。 */
@Serializable
data class SynologyPhotoCodecCheckpoint(
    val original: SynologyPhotoCodecPrompt, val generate: Boolean,
    val generationAttempted: Boolean = false, val generationAcknowledged: Boolean = false,
    val generationRejected: Boolean = false,
    val promptAttempts: Int = 0, val promptRejections: Int = 0,
    val promptAcknowledged: Boolean = false, val promptClosed: Boolean = false,
) {
    val retainsGeneration: Boolean get() = generationAcknowledged && !promptClosed
    val canContinue: Boolean get() = retainsGeneration && !promptAcknowledged && promptAttempts == promptRejections
    override fun toString() = "PhotoCodecCheckpoint"
}
