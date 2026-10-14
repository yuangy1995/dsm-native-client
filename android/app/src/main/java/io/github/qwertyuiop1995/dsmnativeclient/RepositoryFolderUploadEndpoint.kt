package io.github.qwertyuiop1995.dsmnativeclient

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceRecordKind
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal class RepositoryFolderUploadEndpoint(
    private val repo: DsmRepository,
    private val resolver: ContentResolver,
    private val ownership: WorkspaceTaskOwnership,
    private val taskId: String,
) : FolderUploadEndpoint {
    override fun requireOwner() = ownership.require(WorkspaceRecordKind.UPLOAD, taskId, repo)
    override suspend fun item(path: String): FileItem? { requireOwner(); return if (repo.itemExists(path)) repo.fileInfo(path) else null }
    override suspend fun directoryIsUsable(path: String): Boolean {
        requireOwner()
        return repo.fileInfo(path)?.let { it.isDirectory && it.canWrite } == true
    }
    override suspend fun createDirectory(parent: String, path: String): io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult {
        requireOwner()
        return repo.ensureSubdirectoryResult(parent, path)
    }
    override suspend fun upload(source: UploadSource, parent: String, overwrite: Boolean, progress: (Long, Long) -> Unit) =
        repo.uploadResult(source, parent, overwrite, progress)
    override suspend fun contentMatches(item: FileItem, fingerprint: UploadContentFingerprint): Boolean = repo.matchesUploadContent(item, fingerprint)

    override suspend fun prepare(entry: FolderUploadEntry): UploadSource = withContext(Dispatchers.IO) {
        requireOwner()
        val source = entry.source
        val uri = Uri.parse(source.uri)
        fun validateMetadata() {
            resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst() || cursor.getString(0) != source.name || cursor.isNull(1) || cursor.getLong(1) != source.bytes ||
                    source.modifiedAtEpochMillis != null && (cursor.isNull(2) || cursor.getLong(2) != source.modifiedAtEpochMillis)) {
                    throw IOException("Folder upload source changed")
                }
            } ?: throw IOException("Folder upload source unavailable")
        }
        validateMetadata()
        val prepared = UploadSource(source.name, source.mimeType, source.bytes, openInputStream = {
            requireOwner()
            validateMetadata()
            resolver.openInputStream(uri) ?: throw IOException("Folder upload source unavailable")
        })
        if (entry.fingerprint != null && prepared.contentFingerprint() != entry.fingerprint) throw IOException("Folder upload content changed")
        prepared
    }
}
