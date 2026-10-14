package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 主题显示与封面快照；只保存管理所需身份，不保存照片或认证内容。 */
@Serializable
data class SynologyPhotoConceptSnapshot(
    val id: Long, val name: String, val space: SynologyPhotoSpace,
    val visible: Boolean?, val count: Int?, val displayThreshold: Int?,
    val coverUnitId: Long? = null, val coverRevision: String? = null,
) {
    constructor(value: SynologyPhotoCollection) : this(value.id, value.name, value.space, value.conceptVisible,
        value.count, value.conceptDisplayThreshold, value.thumbnail?.unitId, value.thumbnail?.revision)
    val appearsInList: Boolean get() = visible != false && (count == null || displayThreshold == null || count >= displayThreshold)
    fun collection() = SynologyPhotoCollection(id, name, count = count, space = space, conceptVisible = visible,
        conceptDisplayThreshold = displayThreshold, thumbnail = coverUnitId?.let { SynologyPhotoThumbnail(it, coverRevision!!) })
    override fun toString() = "PhotoConceptSnapshot"
}

@Serializable
data class SynologyPhotoConceptCheckpoint(
    val originals: List<SynologyPhotoConceptSnapshot>, val visible: Boolean? = null,
    val attempted: Boolean = false, val acknowledged: Boolean = false, val rejected: Boolean = false,
    val completedIds: Set<Long> = emptySet(), val removedPhotoIds: Set<Long> = emptySet(),
    val updated: List<SynologyPhotoConceptSnapshot> = emptyList(),
) {
    val space: SynologyPhotoSpace get() = originals.first().space
    fun sameIntent(other: SynologyPhotoConceptCheckpoint) = copy(attempted = other.attempted,
        acknowledged = other.acknowledged, rejected = other.rejected,
        completedIds = other.completedIds, removedPhotoIds = other.removedPhotoIds, updated = other.updated) == other
    override fun toString() = "PhotoConceptCheckpoint"
}
