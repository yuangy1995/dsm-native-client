package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.OutputStream
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/** 单文件和 ZIP 共用既有授权传输，保留不同的长度与续传语义。 */
internal class DsmFileDownloadRepository(
    private val profile: NasProfile,
    private val session: DsmSession,
    private val api: DsmApiClient,
    private val capability: () -> ApiCapability,
) {
    suspend fun download(
        item: FileItem,
        output: OutputStream,
        resumeFrom: Long = 0,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long {
        if (!item.canRead) {
            throw DsmFailure(
                null,
                "This item cannot be downloaded with the current account",
                "Ask an administrator for read access and try again.",
                kind = DsmErrorKind.PERMISSION_DENIED,
            )
        }
        require(resumeFrom >= 0 && (!item.isDirectory || resumeFrom == 0L))
        val expected = item.size.takeIf { !item.isDirectory && it > 0 }
        require(resumeFrom == 0L || expected != null && resumeFrom < expected) {
            "The saved download position is invalid"
        }
        return api.downloadBinaryToOutput(
            profile = profile,
            session = session,
            capability = capability(),
            preferredVersion = 2,
            method = "download",
            parameters = mapOf("path" to JsonArray(listOf(JsonPrimitive(item.path))).toString(), "mode" to "download"),
            output = output,
            expectedBytes = expected,
            range = expected?.takeIf { resumeFrom > 0 }?.let { resumeFrom..(it - 1) },
            initialBytes = resumeFrom,
            onProgress = onProgress,
        )
    }

    /** 公开 Download v2 的多路径下载；ZIP 每次重新生成，不沿用源文件大小或续传位置。 */
    suspend fun downloadArchive(
        items: List<FileItem>,
        output: OutputStream,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long {
        require(items.isNotEmpty() && (items.size > 1 || items.single().isDirectory))
        require(items.all { isFileMutationPath(it.path) })
        if (items.any { !it.canRead }) throw DsmFailure(null,
            "Some selected items cannot be downloaded", "Ask an administrator for read access and try again.",
            kind = DsmErrorKind.PERMISSION_DENIED)
        return api.downloadBinaryToOutput(
            profile = profile, session = session, capability = capability(),
            preferredVersion = 2, method = "download",
            parameters = mapOf("path" to JsonArray(items.map(FileItem::path).distinct().map(::JsonPrimitive)).toString(), "mode" to "download"),
            output = output, expectedBytes = null, onProgress = onProgress,
        )
    }

}
