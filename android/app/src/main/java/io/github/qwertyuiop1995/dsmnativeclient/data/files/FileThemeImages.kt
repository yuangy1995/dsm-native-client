package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.File

internal class FileThemeImages(private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val media: FileImageTransport, private val fileInfo: suspend (String) -> FileItem?, private val requireAccess: () -> Unit) {
    suspend fun history(kind: FileThemeImageKind): List<FileThemeImage> {
        requireAccess()
        val rows = call(FILE_THEME_IMAGE_API, "list", mapOf("type" to kind.requestType), 1).settingsRows("list").map { row ->
            val path = row.settingsText("path"); val index = row.settingsInt("index")
            val filename = if ("filename" in row && row["filename"] !is JsonNull) row.settingsText("filename") else path.substringAfterLast('/')
            FileThemeImage(kind, FileThemeImageSource.HISTORY, path, filename, index).also { if (index < 0 || !it.validPath) throw settingsReadFailure() }
        }
        if (rows.map { it.path }.distinct().size != rows.size || rows.map { it.historyIndex }.distinct().size != rows.size) throw settingsReadFailure()
        requireAccess(); return rows
    }
    /** 以稳定 path 找到当前 index；历史新增后不能继续使用选择时的旧 index。 */
    suspend fun validate(image: FileThemeImage): FileThemeImage {
        requireAccess(); if (!image.validPath) throw settingsInvalid()
        val result = when (image.source) {
            FileThemeImageSource.DEFAULT -> FileThemeImage.defaults.singleOrNull { it.kind == image.kind && it.path == image.path } ?: throw settingsInvalid()
            FileThemeImageSource.HISTORY -> history(image.kind).singleOrNull { it.path == image.path } ?: throw settingsChanged()
            FileThemeImageSource.NAS -> {
                if (!image.path.startsWith('/')) throw settingsInvalid()
                val row = fileInfo(image.path) ?: throw settingsChanged()
                if (row.path != image.path || row.isDirectory || !row.canRead) throw settingsChanged()
                image
            }
        }
        requireAccess(); return result
    }
    suspend fun download(image: FileThemeImage, destination: File) = withContext(Dispatchers.IO) {
        try { media.download(validate(image), destination); requireAccess() }
        catch (error: Throwable) { destination.delete(); throw error }
    }
    internal suspend fun upload(input: FileThemeUpload, kind: FileThemeImageKind): String {
        requireAccess()
        return media.upload(input, kind).settingsText("path")
    }
}
