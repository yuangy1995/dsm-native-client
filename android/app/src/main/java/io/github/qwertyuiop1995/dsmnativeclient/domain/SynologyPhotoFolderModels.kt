package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
data class SynologyPhotoSort(val field: Field = Field.TAKEN_TIME, val direction: Direction = Direction.ASCENDING) {
    @Serializable enum class Field(val value: String) { FILENAME("filename"), FILESIZE("filesize"), ITEM_TYPE("item_type"), TAKEN_TIME("takentime") }
    @Serializable enum class Direction(val value: String) { ASCENDING("asc"), DESCENDING("desc") }
}

/** 路径是 NAS 对象身份的一部分，不能当作本机路径使用。 */
@Serializable
data class SynologyPhotoFolderSnapshot(val id: Long, val parentId: Long?, val name: String, val path: String, val space: SynologyPhotoSpace) {
    fun collection() = SynologyPhotoCollection(id, name, parentId = parentId, space = space, path = path)
    override fun toString() = "PhotoFolderSnapshot"
}

data class SynologyPhotoFolderCover(val revision: String, val sequence: Long? = null, val unitId: Long? = null)
data class SynologyPhotoFolderAccess(
    val folder: SynologyPhotoFolderSnapshot, val canCreate: Boolean, val canManage: Boolean,
    val sort: SynologyPhotoSort, val explicitSort: SynologyPhotoSort?, val covers: List<SynologyPhotoFolderCover> = emptyList(),
    val canUpload: Boolean = false, val canDownload: Boolean = false,
)

/** 与相册管理共用阶段、账号互斥和加密存储；只保存恢复所需身份和目标值。 */
@Serializable
data class SynologyPhotoFolderCheckpoint(
    val target: SynologyPhotoFolderSnapshot,
    val name: String? = null,
    val sort: SynologyPhotoSort? = null,
    val coverPhoto: SynologyPhotoEditTarget? = null,
    val createdFolderId: Long? = null,
    val coverAcknowledged: Boolean = false,
) {
    override fun toString() = "PhotoFolderCheckpoint"
}
