package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath
import kotlinx.serialization.Serializable
import java.util.UUID

/** 新解压任务独立保存尺寸与完成要求，不改变旧任务结构，也不保存密码。 */
@Serializable
internal data class FileArchiveVerificationOutput(
    val path: String, val isDirectory: Boolean, val expectedBytes: Long?, val requiresTaskCompletion: Boolean,
) {
    fun toOutput() = FileServerMutationExpectedOutput(path, isDirectory, expectedBytes = expectedBytes,
        requiresTaskCompletion = requiresTaskCompletion)
}

@Serializable
internal data class FileArchiveVerificationPlan(
    val schemaVersion: Int = 1,
    val taskId: String,
    val profileId: String,
    val sourcePath: String,
    val destinationPath: String,
    val outputs: List<FileArchiveVerificationOutput>,
) {
    fun matches(record: PersistedServerTransfer): Boolean = schemaVersion == 1 && record.isPlannedExtraction &&
        taskId == record.id && profileId == record.profileId && record.operation == PersistedServerOperation.EXTRACT &&
        record.sourceBaselines.singleOrNull()?.path == sourcePath && record.destinationFolderBaseline?.path == destinationPath &&
        outputs.isNotEmpty() && outputs.map { it.path }.distinct().size == outputs.size && outputs.all {
            isFileMutationPath(it.path) && it.path.startsWith(destinationPath.trimEnd('/') + "/") && it.path != sourcePath &&
                (it.expectedBytes == null || it.expectedBytes >= 0)
        } && outputs.map { it.toOutput().toPersistedServerExpectedOutput() } == record.expectedOutputs
}

internal val PersistedServerTransfer.isPlannedExtraction get() = id.startsWith(EXTRACTION_PREFIX)
internal fun newFileExtractionId(): String = EXTRACTION_PREFIX + UUID.randomUUID()
private const val EXTRACTION_PREFIX = "file-extraction-"
internal fun fileArchiveVerificationKey(id: String) = "file_archive_verification_v1_" +
    java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(id.toByteArray(Charsets.UTF_8))
internal class FileArchiveVerificationUnavailable : java.io.IOException("Archive verification record is unavailable")
