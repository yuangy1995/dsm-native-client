package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import android.content.ContentResolver
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.*
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import io.github.qwertyuiop1995.dsmnativeclient.R
import kotlinx.coroutines.*
import java.io.File
import java.io.FileNotFoundException

/** 系统签名权限保护根目录，第三方仅能使用系统选择器授予的文档 URI。 */
class NasDocumentsProvider : DocumentsProvider() {
    private val store by lazy { SystemDocumentStore(requireNotNull(context)) }
    private val runtime by lazy { SystemDocumentRuntime.create(requireNotNull(context), store) }
    private val closeHandler by lazy { Handler(HandlerThread("system-document-close").apply { start() }.looper) }
    private val authority get() = requireNotNull(context).packageName + ".documents"
    override fun onCreate(): Boolean {
        // 上次进程退出遗留的只读临时副本可重建；编辑副本保存在独立受保护目录。
        File(requireNotNull(context).cacheDir, "system-documents").listFiles()?.forEach { file ->
            if (file.isFile && runCatching { java.util.UUID.fromString(file.name).toString() == file.name }.getOrDefault(false)) file.delete()
        }
        return true
    }
    override fun queryRoots(projection: Array<out String>?): Cursor = guarded {
        val columns = projection ?: ROOT_COLUMNS
        MatrixCursor(columns).apply {
            runtime.roots().forEach { (location, profile) -> addRow(columns.map { column -> when (column) {
                Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID -> location.id
                Root.COLUMN_TITLE -> profile.name
                Root.COLUMN_SUMMARY -> requireNotNull(context).getString(R.string.app_name)
                Root.COLUMN_FLAGS -> Root.FLAG_SUPPORTS_IS_CHILD
                Root.COLUMN_MIME_TYPES -> "*/*"
                Root.COLUMN_ICON -> R.mipmap.ic_launcher
                else -> null
            } }) }
            setNotificationUri(requireNotNull(context).contentResolver, DocumentsContract.buildRootsUri(authority))
        }
    }
    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor = guarded {
        documents(projection, listOf(runtime.item(documentId))).apply {
            setNotificationUri(requireNotNull(context).contentResolver, DocumentsContract.buildDocumentUri(authority, documentId))
        }
    }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor =
        children(parentDocumentId, projection)
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, queryArgs: Bundle?): Cursor =
        children(parentDocumentId, projection)
    private fun children(id: String, projection: Array<out String>?): Cursor = guarded {
        documents(projection, runtime.children(id)).apply {
            setNotificationUri(requireNotNull(context).contentResolver, DocumentsContract.buildChildDocumentsUri(authority, id))
        }
    }
    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = guarded {
        val parent = store.document(parentDocumentId); val child = store.document(documentId)
        runtime.connection(store.location(parent.locationId))
        store.descendant(parent, child)
    }
    override fun findDocumentPath(parentDocumentId: String?, childDocumentId: String): DocumentsContract.Path = guarded {
        val (root, documents) = runtime.path(parentDocumentId, childDocumentId)
        DocumentsContract.Path(root, documents)
    }
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor = guarded(signal) {
        if (mode in setOf("w", "wt", "wa", "rw", "rwt")) {
            val edit = runtime.beginEdit(documentId)
            try {
                signal?.throwIfCanceled()
                return@guarded ParcelFileDescriptor.open(edit.file, ParcelFileDescriptor.parseMode(mode), closeHandler) { error ->
                    // 关闭只能接收本机编辑，异常关闭留下恢复记录，不在回调中覆盖 NAS。
                    runBlocking(Dispatchers.IO) { runCatching { runtime.closeEdit(edit, error == null) } }
                    requireNotNull(context).contentResolver.notifyChange(DocumentsContract.buildDocumentUri(authority, documentId), null)
                }
            } catch (error: Exception) {
                withContext(NonCancellable) { runCatching { runtime.closeEdit(edit, successful = true) } }
                throw error
            }
        }
        if (mode != "r") throw FileNotFoundException(requireNotNull(context).getString(R.string.system_files_read_only))
        val copy = runtime.download(documentId, File(requireNotNull(context).cacheDir, "system-documents"))
        try {
            signal?.throwIfCanceled()
            ParcelFileDescriptor.open(copy, ParcelFileDescriptor.MODE_READ_ONLY, closeHandler) { copy.delete() }
        } catch (error: Exception) { copy.delete(); throw error }
    }
    private fun documents(projection: Array<out String>?, rows: List<SystemDocumentItem>): MatrixCursor {
        val columns = projection ?: DOCUMENT_COLUMNS
        return MatrixCursor(columns).apply { rows.forEach { row ->
            val item = row.item
            addRow(columns.map { column -> when (column) {
                Document.COLUMN_DOCUMENT_ID -> row.reference.id
                Document.COLUMN_DISPLAY_NAME -> item?.name ?: runtime.roots().singleOrNull { it.first.id == row.reference.locationId }?.second?.name
                Document.COLUMN_MIME_TYPE -> if (row.reference.directory) Document.MIME_TYPE_DIR else
                    item?.mimeType ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(item?.extension) ?: "application/octet-stream"
                Document.COLUMN_SIZE -> item?.size?.takeUnless { row.reference.directory }
                Document.COLUMN_LAST_MODIFIED -> item?.modifiedAtEpochSeconds?.times(1_000)
                Document.COLUMN_FLAGS -> if (row.canEdit) Document.FLAG_SUPPORTS_WRITE else 0
                Document.COLUMN_SUMMARY -> if (row.hasLocalEdits || row.canEdit) requireNotNull(context).getString(R.string.system_files_edit_hint) else null
                else -> null
            } })
        } }
    }
    private fun <T> guarded(signal: CancellationSignal? = null, block: suspend () -> T): T = try {
        runBlocking(Dispatchers.IO) {
            signal?.throwIfCanceled()
            val operation = currentCoroutineContext().job
            signal?.setOnCancelListener { operation.cancel() }
            try { block() } finally { signal?.setOnCancelListener(null) }
        }
    } catch (error: Exception) {
        if (error is CancellationException || signal?.isCanceled == true) throw OperationCanceledException()
        // 错误返回不得携带 NAS 路径、地址或原始响应。
        throw FileNotFoundException(requireNotNull(context).getString(R.string.system_files_unavailable))
    }
    companion object {
        private val ROOT_COLUMNS = arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES, Root.COLUMN_ICON)
        private val DOCUMENT_COLUMNS = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS, Document.COLUMN_SUMMARY)
        internal fun changed(resolver: ContentResolver, packageName: String) {
            resolver.notifyChange(DocumentsContract.buildRootsUri("$packageName.documents"), null)
            resolver.notifyChange(Uri.parse("content://$packageName.documents"), null)
        }
    }
}
