package io.github.qwertyuiop1995.dsmnativeclient.testing

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

/** Office 回传策略的合成文件与端点；不连接真实 NAS。 */
internal class OfficeFixture(val root: File) {
    val original = "original-document".encodeToByteArray(); val edited = "edited-document-content".encodeToByteArray()
    val preferences = MemoryPreferences(); val store = OfficeDocumentStore(preferences, root)
    val transfer = OfficeDocumentTransfer(store); val endpoint = OfficeEndpointFixture(original)
    suspend fun prepare() = transfer.prepare(endpoint, endpoint.current())
    suspend fun changed(): OfficeDocumentRecord {
        val row = prepare()
        return transfer.importEdited(row.id, endpoint.owner, "edited.docx") { edited.inputStream() }
    }
}
internal class OfficeEndpointFixture(var bytes: ByteArray) : OfficeDocumentEndpoint {
    override var owner = WorkspaceOwner(UUID.randomUUID().toString(), "identity", "session")
    var writable = true; var granted = true; var writes = 0; var unknown = false; var applyUpload = true
    var beforeSubmission: suspend () -> Unit = {}; var atWrite: suspend () -> Unit = {}; var afterDownload: () -> Unit = {}
    var path = "/share/document.docx"
    fun current() = FileItem(path, path.substringAfterLast('/'), false, bytes.size.toLong(), 100,
        canWrite = writable, mountPointType = "normal")
    override suspend fun requireAccess() { if (!granted) throw DsmFailure(null, "denied", "retry", kind = DsmErrorKind.PERMISSION_DENIED) }
    override suspend fun item(path: String): FileItem? { requireAccess(); return current().takeIf { it.path == path } }
    override suspend fun md5(path: String) = MessageDigest.getInstance("MD5").digest(bytes).joinToString("") { "%02x".format(it) }
    override suspend fun download(item: FileItem, output: OutputStream): Long {
        requireAccess(); output.write(bytes); val size = bytes.size.toLong(); afterDownload(); return size
    }
    override suspend fun upload(source: UploadSource, destination: String, beforeSubmission: suspend () -> Unit,
        onProgress: (Long, Long) -> Unit): MutationResult {
        this.beforeSubmission(); beforeSubmission(); writes++; atWrite()
        val uploaded = source.openInputStream().use { it.readBytes() }
        if (applyUpload) bytes = uploaded
        onProgress(uploaded.size.toLong(), source.contentLength)
        return MutationResult(1, if (unknown) MutationResultStatus.SUBMITTED_BUT_UNVERIFIED else MutationResultStatus.CONFIRMED_SUCCESS,
            "fileUpload", true, unknown, MutationResultCounts(if (unknown) 0 else 1, 0, if (unknown) 1 else 0),
            localizationKey = "mutation.file_upload.confirmed_success")
    }
}
