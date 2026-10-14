package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 仅使用系统授予的本次文档/目录；不保存URI或申请持久权限。 */
internal class SynologyPhotoDocumentDestination(
    private val resolver: ContentResolver,
    private val uri: Uri,
    private val directory: Boolean,
) : SynologyPhotoExportDestination {
    private var completed = false
    override suspend fun save(file: File, filename: String, mime: String, checkCurrent: suspend () -> Unit) = withContext(Dispatchers.IO) {
        checkCurrent()
        var created: Uri? = null
        var complete = false
        try {
            val target = if (directory) {
                val parentId = DocumentsContract.getTreeDocumentId(uri)
                val parent = DocumentsContract.buildDocumentUriUsingTree(uri, parentId)
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, parentId)
                val names = mutableSetOf<String>()
                val ids = mutableSetOf<String>()
                val columns = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                (resolver.query(children, columns, null, null, null) ?: throw IOException("Photos directory unavailable")).use { cursor ->
                    while (cursor.moveToNext()) { checkCurrent(); names += cursor.getString(0); ids += cursor.getString(1) }
                }
                val name = uniqueName(filename, names)
                checkCurrent()
                val value = DocumentsContract.createDocument(resolver, parent, mime, name) ?: throw IOException("Photos document not created")
                // 提供器返回已有对象时拒绝写入/删除；不把它当作本次新文件。
                if (DocumentsContract.getDocumentId(value) in ids) throw IOException("Photos document already exists")
                created = value
                value
            } else {
                // ACTION_CREATE_DOCUMENT应创建空文档；若提供器返回非空对象则保留原文件。
                resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0) && cursor.getLong(0) > 0) throw IOException("Photos document already contains data")
                }
                created = uri
                uri
            }
            checkCurrent()
            val expected = file.length()
            file.inputStream().use { input ->
                (resolver.openOutputStream(target, "w") ?: throw IOException("Photos destination unavailable")).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        checkCurrent()
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count); copied += count
                    }
                    if (copied != expected) throw IOException("Photos staging length changed")
                    output.flush()
                }
            }
            checkCurrent()
            complete = true; completed = true
        } finally {
            if (!complete) created?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
        }
    }

    /** 选择器返回后已撤权或目标失效时，只移除本次仍为空的单文档。 */
    override suspend fun abandon() = withContext(Dispatchers.IO) {
        if (directory || completed) return@withContext
        runCatching {
            val empty = resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
                cursor.moveToFirst() && !cursor.isNull(0) && cursor.getLong(0) == 0L
            } == true
            if (empty) DocumentsContract.deleteDocument(resolver, uri)
        }
        Unit
    }

    private fun uniqueName(filename: String, names: Set<String>): String {
        if (filename !in names) return filename
        val dot = filename.lastIndexOf('.').takeIf { it > 0 } ?: filename.length
        val base = filename.substring(0, dot); val suffix = filename.substring(dot)
        var count = 1
        while ("$base ($count)$suffix" in names) count++
        return "$base ($count)$suffix"
    }
}
