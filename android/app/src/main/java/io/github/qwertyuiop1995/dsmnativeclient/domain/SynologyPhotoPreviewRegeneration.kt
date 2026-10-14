package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 每项事实只追加；接收生成请求、得到完成结果与读取到最终照片分别处理。 */
@Serializable
enum class SynologyPhotoPreviewFact {
    MARK_ATTEMPTED, MARKED, MARK_REJECTED, LOCAL_ATTEMPTED, LOCAL_REJECTED,
    NAS_ATTEMPTED, NAS_REJECTED, NAS_FAILED, RESTORE_ATTEMPTED, RESTORED, GENERATED, RECOVERED, FAILED,
}

@Serializable
data class SynologyPhotoPreviewProgress(
    val baselineUnitId: Long? = null, val baselineRevision: String? = null,
    val facts: Set<SynologyPhotoPreviewFact> = emptySet(),
) {
    operator fun contains(fact: SynologyPhotoPreviewFact) = fact in facts
    fun adding(vararg values: SynologyPhotoPreviewFact) = copy(facts = facts + values)
    val submitted: Boolean get() = SynologyPhotoPreviewFact.LOCAL_ATTEMPTED in facts || SynologyPhotoPreviewFact.NAS_ATTEMPTED in facts
    val generated: Boolean get() = SynologyPhotoPreviewFact.GENERATED in facts
    val failed: Boolean get() = SynologyPhotoPreviewFact.FAILED in facts
    val unknownSubmission: Boolean get() = !generated && (
        SynologyPhotoPreviewFact.LOCAL_ATTEMPTED in facts && SynologyPhotoPreviewFact.LOCAL_REJECTED !in facts ||
            SynologyPhotoPreviewFact.NAS_ATTEMPTED in facts && SynologyPhotoPreviewFact.NAS_REJECTED !in facts && SynologyPhotoPreviewFact.NAS_FAILED !in facts)
    override fun toString() = "PhotoPreviewProgress(facts=$facts)"
}

@Serializable
data class SynologyPhotoPreviewRegeneration(val resuming: Boolean, val progress: List<SynologyPhotoPreviewProgress>) {
    fun sameIntent(other: SynologyPhotoPreviewRegeneration): Boolean = resuming == other.resuming &&
        progress.size == other.progress.size && progress.zip(other.progress).all { (old, fresh) -> old.copy(facts = fresh.facts) == fresh }
    override fun toString() = "PhotoPreviewRegeneration(count=${progress.size}, resuming=$resuming)"
}
