package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

internal interface OfficeDocumentEndpoint {
    val owner: WorkspaceOwner
    suspend fun requireAccess()
    suspend fun item(path: String): FileItem?
    suspend fun md5(path: String): String
    suspend fun download(item: FileItem, output: OutputStream): Long
    suspend fun upload(source: UploadSource, destination: String, beforeSubmission: suspend () -> Unit,
        onProgress: (Long, Long) -> Unit): MutationResult
}

internal class RepositoryOfficeDocumentEndpoint(private val repository: DsmRepository) : OfficeDocumentEndpoint {
    override val owner get() = repository.owner ?: throw workspaceStorageFailure()
    override suspend fun requireAccess() {
        repository.requireCurrentOwner(); repository.refreshAccess(); repository.requireCurrentOwner()
        if (!repository.filePermissionAccess.granted) throw officePermissionFailure()
    }
    // 复用已接入的严格元数据读取，漏字段不能变成可覆盖的目标。
    override suspend fun item(path: String): FileItem? = try { repository.fileStationRepository.crossNasReader.item(path) }
        catch (failure: DsmFailure) {
            if (failure.kind == DsmErrorKind.CROSS_NAS_INCOMPLETE) throw DsmFailure(null,
                "The file could not be read", "Refresh the file and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
            throw failure
        }
    override suspend fun md5(path: String) = repository.fileMd5(path)
    override suspend fun download(item: FileItem, output: OutputStream) = repository.download(item, output)
    override suspend fun upload(source: UploadSource, destination: String, beforeSubmission: suspend () -> Unit,
        onProgress: (Long, Long) -> Unit) = repository.uploadOfficeResult(source, destination, beforeSubmission, onProgress)
}

/** 外部编辑只处理副本；每次覆盖在既有文件写锁内核对原件并先落盘，未知仅回读。 */
internal class OfficeDocumentTransfer(private val store: OfficeDocumentStore) {
    suspend fun prepare(endpoint: OfficeDocumentEndpoint, item: FileItem): OfficeDocumentRecord = withContext(Dispatchers.IO) {
        endpoint.requireAccess()
        if (!OfficeDocumentPolicy.supports(item)) throw officeFormatFailure()
        val id = UUID.randomUUID().toString()
        store.exclusive(endpoint.owner, item.path, id) {
            store.records(endpoint.owner).singleOrNull { it.baseline.path == item.path }?.let { return@exclusive it }
            val originalId = UUID.randomUUID().toString()
            val file = store.artifact(id, originalId)
            var retained = false
            try {
                val before = endpoint.item(item.path)?.takeIf { OfficeDocumentPolicy.supports(it) } ?: throw officeChanged()
                if (!OfficeDocumentBaseline(item).matches(before)) throw officeChanged()
                if (!file.parentFile!!.mkdirs() && !file.parentFile!!.isDirectory) throw officeLocalFailure()
                file.outputStream().use { endpoint.download(before, it) }
                val fingerprint = officeFingerprint(file)
                val after = endpoint.item(item.path) ?: throw officeChanged()
                val row = OfficeDocumentRecord(id = id, owner = endpoint.owner, baseline = OfficeDocumentBaseline(before),
                    originalId = originalId, originalFingerprint = fingerprint)
                if (!row.baseline.matches(after) || fingerprint.bytes != after.size) throw officeChanged()
                requireBaseline(row, endpoint, requireWrite = false)
                currentCoroutineContext().ensureActive()
                store.begin(row); retained = true; row
            } finally { if (!retained) store.directory(id).deleteRecursively() }
        }
    }

    suspend fun importEdited(id: String, owner: WorkspaceOwner, name: String, input: () -> InputStream): OfficeDocumentRecord =
        withContext(Dispatchers.IO) {
            val before = owned(id, owner)
            store.exclusive(owner, before.baseline.path, id) {
                val row = owned(id, owner)
                if (!row.canImport) throw officePending()
                if (name.substringAfterLast('.', "").lowercase() != row.baseline.asItem().extension) throw officeFormatFailure()
                importCandidate(row, input)
            }
        }

    /** 外部编辑只获得工作副本；原件与上一次已接收副本始终不可写。 */
    suspend fun beginExternal(id: String, owner: WorkspaceOwner): OfficeDocumentRecord = withContext(Dispatchers.IO) {
        val row = owned(id, owner)
        val externalId = UUID.randomUUID().toString(); val file = store.artifact(id, externalId)
        val editing = row.copy(externalId = externalId)
        store.holdExternal(row, externalId)
        var retained = false
        var indexAttempted = false
        try {
            val source = store.artifact(id, row.localId)
            if (officeFingerprint(source) != row.localFingerprint) throw officeLocalFailure()
            source.inputStream().use { input -> file.outputStream().use { output ->
                val bytes = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(bytes); if (count < 0) break
                    output.write(bytes, 0, count)
                }
                output.fd.sync()
            } }
            indexAttempted = true
            store.replace(row, editing); retained = true; editing
        } finally { if (!retained) { if (!indexAttempted) file.delete(); store.releaseExternal(editing) } }
    }

    /** 正常关闭才自动接收；错误或进程中断保留工作副本供用户关闭编辑器后主动接收。 */
    suspend fun closeExternal(row: OfficeDocumentRecord, successful: Boolean): OfficeDocumentRecord = withContext(Dispatchers.IO) {
        try {
            if (!store.externalActive(row) || store.get(row.id) != row) throw officePending()
            if (successful) receiveExternalInside(row) else row
        } finally { store.releaseExternal(row) }
    }
    suspend fun receiveExternal(id: String, owner: WorkspaceOwner): OfficeDocumentRecord = withContext(Dispatchers.IO) {
        val row = owned(id, owner)
        store.exclusive(owner, row.baseline.path, id) { receiveExternalInside(owned(id, owner)) }
    }
    private suspend fun receiveExternalInside(row: OfficeDocumentRecord): OfficeDocumentRecord {
        val file = store.artifact(row.id, row.externalId ?: throw officePending())
        val before = officeFingerprint(file)
        return importCandidate(row, { file.inputStream() }, before).also { file.delete() }
    }

    private suspend fun importCandidate(row: OfficeDocumentRecord, input: () -> InputStream,
        externalFingerprint: OfficeDocumentFingerprint? = null): OfficeDocumentRecord {
        val candidateId = UUID.randomUUID().toString()
        val file = store.artifact(row.id, candidateId)
        var retained = false
        var indexAttempted = false
        try {
            if (!file.parentFile!!.isDirectory) throw officeLocalFailure()
            input().use { source -> file.outputStream().use { destination ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = source.read(buffer)
                    if (count < 0) break
                    destination.write(buffer, 0, count)
                }
                destination.fd.sync()
            } }
            val fingerprint = officeFingerprint(file)
            if (externalFingerprint != null && (fingerprint != externalFingerprint ||
                officeFingerprint(store.artifact(row.id, checkNotNull(row.externalId))) != externalFingerprint)) throw officeLocalFailure()
            val phase = if (row.phase == OfficeDocumentPhase.CONFLICT) row.phase else
                if (fingerprint == row.originalFingerprint) OfficeDocumentPhase.UNCHANGED else OfficeDocumentPhase.CHANGED
            val updated = row.copy(candidateId = candidateId, candidateFingerprint = fingerprint, phase = phase, externalId = null)
            indexAttempted = true
            store.replace(row, updated); retained = true
            row.candidateId?.let { store.artifact(row.id, it).delete() }
            return updated
        } finally { if (!retained && !indexAttempted) file.delete() }
    }

    suspend fun save(id: String, endpoint: OfficeDocumentEndpoint, confirmed: Boolean,
        onProgress: (Long, Long) -> Unit = { _, _ -> }): OfficeDocumentRecord = withContext(Dispatchers.IO) {
        val original = owned(id, endpoint.owner)
        if (!confirmed || !original.canSave) throw officePending()
        store.exclusive(endpoint.owner, original.baseline.path, id) {
            var row = owned(id, endpoint.owner)
            if (!row.canSave) throw officePending()
            try {
                endpoint.requireAccess()
                val file = store.artifact(id, checkNotNull(row.candidateId))
                val expected = checkNotNull(row.candidateFingerprint)
                if (officeFingerprint(file) != expected) throw officeLocalFailure()
                val source = UploadSource(row.baseline.name, OfficeDocumentPolicy.mime(row.baseline.name), expected.bytes,
                    openInputStream = { file.inputStream() })
                val result = endpoint.upload(source, row.baseline.path.substringBeforeLast('/'), beforeSubmission = {
                    requireBaseline(row, endpoint, requireWrite = true)
                    currentCoroutineContext().ensureActive()
                    val writing = row.copy(phase = OfficeDocumentPhase.SAVING)
                    store.replace(row, writing); row = writing
                }, onProgress = onProgress)
                if (!result.submitted) {
                    if (row.phase == OfficeDocumentPhase.SAVING) {
                        val previous = row.copy(phase = OfficeDocumentPhase.CHANGED)
                        store.replace(row, previous); row = previous
                    }
                    throw submissionFailure(result)
                }
                if (row.phase != OfficeDocumentPhase.SAVING) throw workspaceStorageFailure()
                val unknown = row.copy(phase = OfficeDocumentPhase.UNKNOWN)
                store.replace(row, unknown); row = unknown
                verify(row, endpoint)
            } catch (failure: Exception) {
                if (row.phase == OfficeDocumentPhase.SAVING) withContext(NonCancellable + Dispatchers.IO) {
                    store.replace(row, row.copy(phase = OfficeDocumentPhase.UNKNOWN))
                } else if ((failure as? DsmFailure)?.kind == DsmErrorKind.OFFICE_CHANGED && row.phase == OfficeDocumentPhase.CHANGED) {
                    store.replace(row, row.copy(phase = OfficeDocumentPhase.CONFLICT))
                }
                throw failure
            }
        }
    }

    suspend fun refresh(id: String, endpoint: OfficeDocumentEndpoint): OfficeDocumentRecord = withContext(Dispatchers.IO) {
        val row = owned(id, endpoint.owner)
        store.exclusive(endpoint.owner, row.baseline.path, id) {
            endpoint.requireAccess()
            val current = owned(id, endpoint.owner)
            if (current.phase != OfficeDocumentPhase.UNKNOWN) current else verify(current, endpoint)
        }
    }

    suspend fun export(id: String, owner: WorkspaceOwner, output: () -> OutputStream) = withContext(Dispatchers.IO) {
        val row = owned(id, owner)
        store.exclusive(owner, row.baseline.path, id) {
            val current = owned(id, owner)
            val file = store.artifact(id, current.localId)
            if (officeFingerprint(file) != current.localFingerprint) throw officeLocalFailure()
            output().use { destination -> file.inputStream().use { source ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = source.read(buffer)
                    if (count < 0) break
                    destination.write(buffer, 0, count)
                }
            } }
        }
    }

    private suspend fun requireBaseline(row: OfficeDocumentRecord, endpoint: OfficeDocumentEndpoint, requireWrite: Boolean) {
        val item = endpoint.item(row.baseline.path) ?: throw officeChanged()
        if (!row.baseline.matches(item) || !OfficeDocumentPolicy.supports(item)) throw officeChanged()
        if (requireWrite && !item.canWrite) throw officePermissionFailure()
        if (endpoint.md5(item.path) != row.originalFingerprint.md5 ||
            endpoint.item(item.path)?.let(row.baseline::matches) != true) throw officeChanged()
    }
    private suspend fun verify(row: OfficeDocumentRecord, endpoint: OfficeDocumentEndpoint): OfficeDocumentRecord {
        val item = endpoint.item(row.baseline.path) ?: return row
        val fingerprint = row.candidateFingerprint ?: throw officeLocalFailure()
        if (!OfficeDocumentPolicy.supports(item) || item.name != row.baseline.name || item.size != fingerprint.bytes) return row
        val digest = OfficeDocumentDigest()
        endpoint.download(item, digest)
        if (digest.finish() != fingerprint || endpoint.item(item.path)?.let(OfficeDocumentBaseline(item)::matches) != true) return row
        return row.copy(phase = OfficeDocumentPhase.SAVED).also { store.replace(row, it) }
    }
    private fun owned(id: String, owner: WorkspaceOwner) = store.get(id).also {
        if (!it.owner.hasSameIdentity(owner)) throw DsmFailure(null, "The connection changed", "Open the original connection.", kind = DsmErrorKind.WORKSPACE_CHANGED)
    }
    private fun submissionFailure(result: MutationResult): DsmFailure = when (result.errorCategory) {
        MutationErrorCategory.PERMISSION, MutationErrorCategory.AUTHENTICATION -> officePermissionFailure()
        MutationErrorCategory.CONFLICT -> officeChanged()
        MutationErrorCategory.UNSUPPORTED -> DsmFailure(null, "Saving is unavailable", "Save a local copy instead.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        else -> DsmFailure(null, "The file could not be saved", "Check the connection and try again.", kind = DsmErrorKind.CONNECTION_FAILED)
    }
}

private fun officePermissionFailure() = DsmFailure(null, "The file is not writable", "Use an account with access or save a local copy.", kind = DsmErrorKind.PERMISSION_DENIED)
