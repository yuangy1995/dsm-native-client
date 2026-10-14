package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

@Serializable internal enum class OfficeDocumentPhase { READY, CHANGED, UNCHANGED, SAVING, SAVED, CONFLICT, UNKNOWN }

/** 只保存原文件身份；账号/地址、凭据和系统文档 URI 不进入恢复索引。 */
@Serializable internal data class OfficeDocumentBaseline(
    val path: String, val name: String, val size: Long, val modifiedAt: Long?, val mountType: String?,
) {
    constructor(item: FileItem) : this(item.path, item.name, item.size, item.modifiedAtEpochSeconds, item.mountPointType)
    fun matches(item: FileItem) = !item.isDirectory && path == item.path && name == item.name && size == item.size &&
        modifiedAt == item.modifiedAtEpochSeconds && mountType == item.mountPointType
    fun asItem() = FileItem(path, name, false, size, modifiedAt, mountPointType = mountType)
    override fun toString() = "OfficeDocumentBaseline"
}

@Serializable internal data class OfficeDocumentFingerprint(val bytes: Long, val md5: String, val sha256: String) {
    val valid get() = bytes >= 0 && md5.matches(Regex("[a-f0-9]{32}")) && sha256.matches(Regex("[a-f0-9]{64}"))
    override fun toString() = "OfficeDocumentFingerprint(bytes=$bytes)"
}

@Serializable internal data class OfficeDocumentRecord(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val baseline: OfficeDocumentBaseline, val originalId: String = UUID.randomUUID().toString(),
    val originalFingerprint: OfficeDocumentFingerprint, val candidateId: String? = null,
    val candidateFingerprint: OfficeDocumentFingerprint? = null, val phase: OfficeDocumentPhase = OfficeDocumentPhase.READY,
    val createdAtSeconds: Long = System.currentTimeMillis() / 1_000,
    val externalId: String? = null,
) {
    val uncertain get() = phase in setOf(OfficeDocumentPhase.SAVING, OfficeDocumentPhase.UNKNOWN)
    val canImport get() = !uncertain && phase != OfficeDocumentPhase.SAVED && externalId == null
    val canSave get() = phase == OfficeDocumentPhase.CHANGED && externalId == null
    val localId get() = candidateId ?: originalId
    val localFingerprint get() = candidateFingerprint ?: originalFingerprint
    override fun toString() = "OfficeDocumentRecord($phase)"
}

internal object OfficeDocumentPolicy {
    val mimeTypes = mapOf("doc" to "application/msword", "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel", "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint", "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation")
    fun supports(item: FileItem) = !item.isDirectory && item.extension in mimeTypes && isFileMutationPath(item.path) &&
        item.path.count { it == '/' } >= 2 && item.path.substringAfterLast('/') == item.name &&
        item.name.none { it in "\\\r\n\u0000" } && item.path.split('/').none { it == "#recycle" } &&
        isNormalFileMountType(item.mountPointType) && item.canRead && item.size >= 0 && item.modifiedAtEpochSeconds != null
    fun mime(name: String) = mimeTypes[name.substringAfterLast('.', "").lowercase()] ?: "application/octet-stream"
}

internal class OfficeDocumentDigest : OutputStream() {
    private val md5 = MessageDigest.getInstance("MD5")
    private val sha256 = MessageDigest.getInstance("SHA-256")
    private var count = 0L
    override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
    override fun write(bytes: ByteArray, offset: Int, length: Int) {
        md5.update(bytes, offset, length); sha256.update(bytes, offset, length); count += length
    }
    fun finish() = OfficeDocumentFingerprint(count, md5.digest().hex(), sha256.digest().hex())
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
}

internal suspend fun officeFingerprint(file: File): OfficeDocumentFingerprint {
    if (!file.isFile) throw officeLocalFailure()
    val digest = OfficeDocumentDigest()
    file.inputStream().use { input ->
        val bytes = ByteArray(64 * 1024)
        while (true) {
            currentCoroutineContext().ensureActive()
            val count = input.read(bytes)
            if (count < 0) break
            digest.write(bytes, 0, count)
        }
    }
    return digest.finish()
}

internal fun officeChanged() = DsmFailure(null, "The original file changed", "Save your edited copy elsewhere and reopen the latest original.", kind = DsmErrorKind.OFFICE_CHANGED)
internal fun officeLocalFailure() = DsmFailure(null, "The local copy could not be read", "Choose your edited file again, or save another copy.", kind = DsmErrorKind.OFFICE_LOCAL)
internal fun officeFormatFailure() = DsmFailure(null, "The selected file has a different format", "Choose an edited file in the same format as the original.", kind = DsmErrorKind.OFFICE_FORMAT)
internal fun officePending() = DsmFailure(null, "This file has an unfinished save", "Open the editing copy and refresh its status.", kind = DsmErrorKind.OFFICE_PENDING)
