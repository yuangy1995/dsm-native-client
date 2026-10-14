package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

/** 人物封面可能直接使用人物编号；它不是相册或照片编号。 */
data class SynologyPhotoPersonCover(val id: Long, val revision: String, val type: Type) {
    enum class Type(val value: String) { PERSON("person"), UNIT("unit") }
}

@Serializable
data class SynologyPhotoPersonSnapshot(
    val id: Long, val name: String, val count: Int?, val space: SynologyPhotoSpace, val visible: Boolean? = null,
) {
    constructor(person: SynologyPhotoCollection) : this(person.id, person.name, person.count, person.space, person.personVisible)
    fun collection() = SynologyPhotoCollection(id, name, count = count, space = space, personVisible = visible)
    override fun toString() = "PhotoPersonSnapshot"
}

/** 首项固定为改名/合并目标；合并只保存照片编号并集，不保存人脸或媒体。 */
@Serializable
data class SynologyPhotoPeopleCheckpoint(
    val originals: List<SynologyPhotoPersonSnapshot>,
    val name: String? = null, val visible: Boolean? = null, val memberIds: Set<Long>? = null,
    val faces: SynologyPhotoPersonFacesCheckpoint? = null,
    val attempted: Boolean = false, val acknowledged: Boolean = false, val rejected: Boolean = false,
    val nameReceipt: Boolean = false, val completedIds: Set<Long> = emptySet(), val removedIds: Set<Long> = emptySet(),
) {
    val space: SynologyPhotoSpace get() = originals.first().space
    fun sameIntent(other: SynologyPhotoPeopleCheckpoint): Boolean = copy(attempted = other.attempted,
        acknowledged = other.acknowledged, rejected = other.rejected, nameReceipt = other.nameReceipt,
        completedIds = other.completedIds, removedIds = other.removedIds, faces = other.faces) == other &&
        (if (faces == null) other.faces == null else other.faces?.let(faces::sameIntent) == true)
    override fun toString() = "PhotoPeopleCheckpoint"
}

/** 人脸缩略图只在当前授权中使用；持久记录仅保存人脸与原件编号对应。 */
data class SynologyPhotoPersonFace(val id: Long, val personId: Long, val photoId: SynologyPhotoId, val revision: String? = null) {
    fun snapshot() = SynologyPhotoPersonFaceSnapshot(id, photoId)
    override fun toString() = "PhotoPersonFace"
}
@Serializable
data class SynologyPhotoPersonFaceSnapshot(val id: Long, val photoId: SynologyPhotoId) {
    override fun toString() = "PhotoPersonFaceSnapshot"
}
@Serializable
data class SynologyPhotoPersonFacesCheckpoint(
    val selected: List<SynologyPhotoPersonFaceSnapshot> = emptyList(),
    val targetReceipt: Long? = null, val coverReceipt: Long? = null,
    val removedPhotoIds: Set<Long> = emptySet(),
) {
    fun sameIntent(other: SynologyPhotoPersonFacesCheckpoint) = copy(targetReceipt = other.targetReceipt,
        coverReceipt = other.coverReceipt, removedPhotoIds = other.removedPhotoIds) == other
    override fun toString() = "PhotoPersonFacesCheckpoint"
}
