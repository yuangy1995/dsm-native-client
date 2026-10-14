package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import android.content.ContentProvider
import android.content.ContentValues
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.FileNotFoundException

/** 不导出、不授予外部访问；只供现有上传 Worker 读取已接收的私有副本。 */
class SharedInputProvider : ContentProvider() {
    private val store by lazy { SharedInputStore(requireNotNull(context)) }
    override fun onCreate() = true
    override fun getType(uri: Uri) = store.entry(id(uri)).mime ?: "application/octet-stream"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): MatrixCursor {
        val row = store.entry(id(uri))
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply { addRow(columns.map { when (it) {
            OpenableColumns.DISPLAY_NAME -> row.name
            OpenableColumns.SIZE -> row.bytes
            else -> null
        } }) }
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read only")
        val row = store.entry(id(uri)); val file = store.file(row.id)
        if (!file.isFile || file.length() != row.bytes) throw FileNotFoundException("Shared copy unavailable")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }
    private fun id(uri: Uri) = store.id(uri.toString()) ?: throw FileNotFoundException("Shared copy unavailable")
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}
