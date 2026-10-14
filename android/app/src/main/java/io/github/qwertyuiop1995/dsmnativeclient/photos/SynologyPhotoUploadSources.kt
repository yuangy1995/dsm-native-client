package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.github.qwertyuiop1995.dsmnativeclient.scanDocumentTree
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 只读取系统选择器授权的项目；临时授权在复制完成后不再用于恢复。 */
internal suspend fun photoUploadSources(context: Context, uris: List<Uri>): List<SynologyPhotoLocalSource> {
    if (uris.size > MAX_PHOTO_IMPORT_ITEMS) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LIMIT)
    val resolver = context.contentResolver
    return uris.distinct().map { uri ->
        currentCoroutineContext().ensureActive()
        if (uri.scheme != "content" || !isPhotoUploadMime(resolver.getType(uri).orEmpty())) localSourceFailure()
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) localSourceFailure()
            val name = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val size = cursor.getColumnIndex(OpenableColumns.SIZE)
            val modified = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            if (name < 0 || cursor.isNull(name)) localSourceFailure()
            SynologyPhotoLocalSource(cursor.getString(name), if (size < 0 || cursor.isNull(size)) null else cursor.getLong(size),
                if (modified < 0 || cursor.isNull(modified)) null else cursor.getLong(modified).takeIf { it > 0 }?.div(1_000),
                open = { resolver.openInputStream(uri) ?: localSourceFailure() })
        } ?: localSourceFailure()
    }
}

internal suspend fun photoUploadFolderSources(context: Context, uri: Uri): List<SynologyPhotoLocalSource> {
    if (uri.scheme != "content") localSourceFailure()
    val scan = scanDocumentTree(context, uri, MAX_PHOTO_IMPORT_ITEMS, includeRoot = true, includeMimeType = ::isPhotoUploadMime)
    if (scan.truncated) throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LIMIT)
    if (scan.unavailable.isNotEmpty()) localSourceFailure()
    return scan.files.map { file -> SynologyPhotoLocalSource(file.name, file.size, file.modifiedAtEpochMillis?.div(1_000), file.relativeFolder,
        open = { context.contentResolver.openInputStream(file.uri) ?: localSourceFailure() }) }
}

private fun isPhotoUploadMime(type: String) = type.startsWith("image/") || type.startsWith("video/")
private fun localSourceFailure(): Nothing = throw SynologyPhotoUploadFailure(SynologyPhotoUploadProblem.LOCAL_FILE)
