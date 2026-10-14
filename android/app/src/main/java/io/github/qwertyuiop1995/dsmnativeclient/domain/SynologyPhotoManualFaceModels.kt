package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable
import kotlin.math.abs

/** 坐标对应已按显示方向解码的整张图片；不修改原件。 */
@Serializable
data class SynologyPhotoFaceBounds(val x: Double, val y: Double, val width: Double, val height: Double) {
    val valid: Boolean get() = listOf(x, y, width, height).all { it.isFinite() } &&
        x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    fun matches(other: SynologyPhotoFaceBounds): Boolean =
        abs(x - other.x) < 0.000001 && abs(y - other.y) < 0.000001 &&
            abs(width - other.width) < 0.000001 && abs(height - other.height) < 0.000001
}

@Serializable
data class SynologyPhotoFaceSnapshot(val id: Long, val personId: Long, val name: String, val bounds: SynologyPhotoFaceBounds) {
    fun matches(other: SynologyPhotoFaceSnapshot): Boolean = id == other.id && personId == other.personId &&
        name == other.name && bounds.matches(other.bounds)
    override fun toString() = "PhotoFaceSnapshot"
}
data class SynologyPhotoFaceRegion(val face: SynologyPhotoFaceSnapshot, val revision: String? = null)

/** 图像只作为本次调用的内存参数；恢复记录只保存裁剪摘要和明确回执。 */
@Serializable
sealed interface SynologyPhotoFaceChange {
    val key: String
    @Serializable
    data class Add(val temporaryId: String, val bounds: SynologyPhotoFaceBounds,
        val person: SynologyPhotoPersonSnapshot?, val name: String, val jpegDigest: String) : SynologyPhotoFaceChange {
        override val key: String get() = "new-$temporaryId"
        override fun toString() = "PhotoFaceChange.Add"
    }
    @Serializable
    data class Remove(val original: SynologyPhotoFaceSnapshot) : SynologyPhotoFaceChange {
        override val key: String get() = "old-${original.id}"
        override fun toString() = "PhotoFaceChange.Remove"
    }
    @Serializable
    data class Reassign(val original: SynologyPhotoFaceSnapshot, val person: SynologyPhotoPersonSnapshot?, val name: String) : SynologyPhotoFaceChange {
        override val key: String get() = "old-${original.id}"
        override fun toString() = "PhotoFaceChange.Reassign"
    }
}

@Serializable
data class SynologyPhotoManualFacesCheckpoint(
    val originals: List<SynologyPhotoFaceSnapshot>, val changes: List<SynologyPhotoFaceChange>,
    val addAttempted: Boolean = false, val addAcknowledged: Boolean = false, val addRejected: Boolean = false,
    val newIds: Map<String, Long> = emptyMap(), val uploadAttempted: Set<Long> = emptySet(), val uploaded: Set<Long> = emptySet(),
    val attempted: Set<String> = emptySet(), val acknowledged: Set<String> = emptySet(), val rejected: Set<String> = emptySet(),
    val personReceipts: Map<String, Long> = emptyMap(), val completed: Set<String> = emptySet(), val failed: Set<String> = emptySet(),
) {
    fun sameIntent(other: SynologyPhotoManualFacesCheckpoint): Boolean = originals == other.originals && changes == other.changes
    override fun toString() = "PhotoManualFacesCheckpoint"
}
