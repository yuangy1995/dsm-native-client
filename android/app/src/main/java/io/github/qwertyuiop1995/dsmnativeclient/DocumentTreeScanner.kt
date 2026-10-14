package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

internal data class DocumentTreeNode(
    val id: String,
    val name: String,
    val mimeType: String,
    val size: Long? = null,
    val modifiedAtEpochMillis: Long? = null,
    val virtual: Boolean = false,
) {
    val isDirectory: Boolean get() = mimeType == DIRECTORY_MIME
}

internal enum class DocumentSourceIssue { INVALID_NAME, UNREADABLE, UNKNOWN_SIZE, VIRTUAL_DOCUMENT, DUPLICATE }

internal data class CollectedDocument(
    val node: DocumentTreeNode,
    val relativePath: String,
    val issue: DocumentSourceIssue? = null,
)

internal data class CollectedDocumentTree(val entries: List<CollectedDocument>, val truncated: Boolean)

/** 固定来源清单；根目录可按调用方选择保留，任何漏读都必须成为明确失败。 */
internal suspend fun collectDocumentTree(
    root: DocumentTreeNode,
    includeRoot: Boolean,
    maximumDocuments: Int,
    includeMimeType: (String) -> Boolean,
    children: suspend (id: String, maximum: Int) -> List<DocumentTreeNode>,
): CollectedDocumentTree {
    require(maximumDocuments > 0)
    if (!root.isDirectory || !isSafeBackupName(root.name)) throw IOException("The selected folder is unavailable")
    val result = mutableListOf<CollectedDocument>()
    val rootPath = if (includeRoot) root.name else ""
    if (includeRoot) result += CollectedDocument(root, rootPath)
    val pending = ArrayDeque<Pair<DocumentTreeNode, String>>().apply { add(root to rootPath) }
    val seenIds = mutableSetOf(root.id)
    val seenPaths = mutableSetOf<String>()
    var visited = if (includeRoot) 1 else 0
    while (pending.isNotEmpty()) {
        currentCoroutineContext().ensureActive()
        val (parent, relative) = pending.removeFirst()
        val remaining = maximumDocuments - visited
        val nodes = try {
            children(parent.id, remaining + 1)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            val index = result.indexOfFirst { it.node.id == parent.id && it.relativePath == relative }
            val failed = CollectedDocument(parent, relative, DocumentSourceIssue.UNREADABLE)
            if (index >= 0) result[index] = failed else result += failed
            continue
        }
        if (nodes.size > remaining) return CollectedDocumentTree(result, truncated = true)
        for (node in nodes) {
            currentCoroutineContext().ensureActive()
            visited++
            val path = if (relative.isEmpty()) node.name else "$relative/${node.name}"
            val issue = when {
                node.id.isEmpty() || !isSafeBackupName(node.name) -> DocumentSourceIssue.INVALID_NAME
                !seenIds.add(node.id) || !seenPaths.add(path) -> DocumentSourceIssue.DUPLICATE
                node.virtual -> DocumentSourceIssue.VIRTUAL_DOCUMENT
                !node.isDirectory && includeMimeType(node.mimeType) && (node.size == null || node.size < 0) -> DocumentSourceIssue.UNKNOWN_SIZE
                else -> null
            }
            if (node.isDirectory || includeMimeType(node.mimeType) || issue != null) {
                result += CollectedDocument(node, path, issue)
            }
            if (node.isDirectory && issue == null) pending += node to path
        }
    }
    // 同级重名会指向相同 NAS 目标，两项都标明冲突，不能仅让第一个来源上传。
    val duplicates = result.groupingBy(CollectedDocument::relativePath).eachCount().filterValues { it > 1 }.keys
    return CollectedDocumentTree(result.map {
        if (it.relativePath in duplicates) it.copy(issue = DocumentSourceIssue.DUPLICATE) else it
    }, truncated = false)
}

internal data class BackupDocument(
    val uri: Uri, val name: String, val mimeType: String, val size: Long, val relativeFolder: String,
    val modifiedAtEpochMillis: Long? = null,
)

internal data class BackupDirectory(val uri: Uri, val name: String, val relativePath: String)
internal data class UnavailableDocument(val relativePath: String, val issue: DocumentSourceIssue)
internal data class DocumentTreeScan(
    val files: List<BackupDocument>,
    val truncated: Boolean,
    val directories: List<BackupDirectory> = emptyList(),
    val unavailable: List<UnavailableDocument> = emptyList(),
)

internal suspend fun scanDocumentTree(
    context: Context,
    treeUri: Uri,
    maximumDocuments: Int,
    includeRoot: Boolean = false,
    includeMimeType: (String) -> Boolean,
): DocumentTreeScan = withContext(Dispatchers.IO) {
    val rootId = DocumentsContract.getTreeDocumentId(treeUri)
    val root = readDocumentNodes(context, DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId), 1)
        .singleOrNull() ?: throw IOException("The selected folder is unavailable")
    val collected = collectDocumentTree(root, includeRoot, maximumDocuments, includeMimeType) { id, maximum ->
        readDocumentNodes(context, DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, id), maximum)
    }
    val files = mutableListOf<BackupDocument>()
    val directories = mutableListOf<BackupDirectory>()
    val unavailable = mutableListOf<UnavailableDocument>()
    for (entry in collected.entries) {
        if (entry.issue != null) {
            unavailable += UnavailableDocument(entry.relativePath, entry.issue)
            continue
        }
        val node = entry.node
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, node.id)
        if (node.isDirectory) directories += BackupDirectory(uri, node.name, entry.relativePath)
        else files += BackupDocument(uri, node.name, node.mimeType, checkNotNull(node.size),
            entry.relativePath.substringBeforeLast('/', ""), node.modifiedAtEpochMillis)
    }
    DocumentTreeScan(files, collected.truncated, directories, unavailable)
}

private suspend fun readDocumentNodes(context: Context, uri: Uri, maximum: Int): List<DocumentTreeNode> {
    currentCoroutineContext().ensureActive()
    val result = mutableListOf<DocumentTreeNode>()
    val cursor = context.contentResolver.query(uri, TREE_PROJECTION, null, null, null)
        ?: throw IOException("The selected folder could not be read")
    cursor.use {
        if (cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING)) throw IOException("The folder is still loading")
        val id = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        val name = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val mime = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
        val size = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
        val modified = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val flags = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
        while (result.size < maximum && cursor.moveToNext()) {
            currentCoroutineContext().ensureActive()
            result += DocumentTreeNode(cursor.getString(id).orEmpty(), cursor.getString(name).orEmpty(),
                cursor.getString(mime).orEmpty(), if (cursor.isNull(size)) null else cursor.getLong(size),
                if (modified < 0 || cursor.isNull(modified)) null else cursor.getLong(modified).takeIf { it > 0 },
                flags >= 0 && !cursor.isNull(flags) && cursor.getInt(flags) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0)
        }
    }
    return result
}

private const val DIRECTORY_MIME = "vnd.android.document/directory"
private val TREE_PROJECTION = arrayOf(
    DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
    DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
    DocumentsContract.Document.COLUMN_LAST_MODIFIED, DocumentsContract.Document.COLUMN_FLAGS,
)
