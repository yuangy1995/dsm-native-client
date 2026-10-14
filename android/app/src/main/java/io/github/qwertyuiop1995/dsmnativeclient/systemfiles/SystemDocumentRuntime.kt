package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isNormalFileMountType
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

internal data class SystemDocumentItem(val reference: SystemDocumentRef, val item: FileItem?, val canEdit: Boolean = false, val hasLocalEdits: Boolean = false)
internal data class SystemOfficeEdit(val record: OfficeDocumentRecord, val file: File)

/** 每次系统调用重取原身份及权限，既有 URI 不能因切换前台 NAS 而指向新账号。 */
internal class SystemDocumentRuntime(
    private val store: SystemDocumentStore, private val profiles: SecureProfileStore,
    private val repository: suspend (SystemFileLocation) -> DsmRepository,
    private val office: OfficeDocumentStore? = null,
) {
    fun roots(): List<Pair<SystemFileLocation, NasProfile>> = store.locations().mapNotNull { location ->
        if (!location.enabled) return@mapNotNull null
        runCatching { connection(location); profiles.profileForOwner(location.owner)?.let { location to it } }.getOrNull()
    }
    fun connection(location: SystemFileLocation): SavedWorkspaceConnection {
        if (!location.enabled || store.location(location.id) != location) throw workspaceChangedFailure()
        val connection = profiles.savedConnectionForRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id)
        if (!connection.owner.hasSameIdentity(location.owner)) throw workspaceChangedFailure()
        return connection
    }
    private suspend fun access(location: SystemFileLocation): DsmRepository {
        connection(location)
        val repo = repository(location)
        if (repo.owner?.hasSameIdentity(location.owner) != true) throw workspaceChangedFailure()
        repo.requireCurrentOwner(); repo.refreshAccess(true); repo.requireCurrentOwner(); connection(location)
        if (!repo.filePermissionAccess.granted) throw unavailable()
        return repo
    }
    suspend fun item(id: String): SystemDocumentItem {
        val ref = store.document(id); val location = store.location(ref.locationId)
        val repo = access(location)
        val item = if (ref.path.isEmpty()) null else actual(repo, ref)
        connection(location); repo.requireCurrentOwner()
        return decorate(location, ref, item, office?.records(location.owner).orEmpty()).also {
            connection(location); repo.requireCurrentOwner()
        }
    }
    suspend fun children(id: String): List<SystemDocumentItem> {
        val parent = store.document(id); val location = store.location(parent.locationId)
        if (!parent.directory) throw unavailable()
        val repo = access(location)
        if (parent.path.isNotEmpty()) actual(repo, parent)
        val items = mutableListOf<FileItem>(); val seen = mutableSetOf<String>(); var offset = 0; var total: Int? = null
        do {
            currentCoroutineContext().ensureActive(); connection(location); repo.requireCurrentOwner()
            val page = if (parent.path.isEmpty()) repo.listShares(offset, 100)
                else repo.fileStationRepository.crossNasReader.page(parent.path, offset, 100)
            if (page.offset != offset || page.total < offset + page.items.size || page.items.size > 100 ||
                total != null && total != page.total || page.items.isEmpty() && offset < page.total ||
                page.items.any { it.path.substringBeforeLast('/', "") != parent.path } ||
                page.items.any { !seen.add(it.path) }) throw unavailable()
            items += page.items; offset += page.items.size; total = page.total
        } while (offset < total!!)
        connection(location); repo.requireCurrentOwner()
        val records = office?.records(location.owner).orEmpty()
        return items.filter { it.canRead && isNormalFileMountType(it.mountPointType) && it.path.split('/').none { part -> part == "#recycle" } }
            .map { decorate(location, store.document(location, it.path, it.isDirectory), it, records) }
            .also { connection(location); repo.requireCurrentOwner() }
    }
    suspend fun path(parentId: String?, childId: String): Pair<String?, List<String>> {
        val child = store.document(childId); val location = store.location(child.locationId)
        val parent = parentId?.let(store::document) ?: store.document(location.id)
        if (parent.locationId != child.locationId || !parent.directory || parent.id != child.id && !store.descendant(parent, child)) throw unavailable()
        val repo = access(location)
        val documents = mutableListOf<SystemDocumentRef>()
        var path = child.path
        while (true) {
            currentCoroutineContext().ensureActive(); connection(location)
            val ref = when (path) {
                child.path -> child
                "" -> store.document(location.id)
                else -> store.document(location, path, directory = true)
            }
            if (path.isNotEmpty()) actual(repo, ref)
            documents += ref
            if (path == parent.path) break
            path = path.substringBeforeLast('/', "")
        }
        connection(location); repo.requireCurrentOwner()
        return location.id.takeIf { parentId == null } to documents.asReversed().map { it.id }
    }
    suspend fun download(id: String, directory: File): File {
        val ref = store.document(id); val location = store.location(ref.locationId)
        if (ref.directory) throw unavailable()
        val repo = access(location); val before = actual(repo, ref)
        if (before.size < 0 || before.modifiedAtEpochSeconds == null) throw unavailable()
        if (!directory.mkdirs() && !directory.isDirectory) throw workspaceStorageFailure()
        val copy = File(directory, UUID.randomUUID().toString())
        var retained = false
        try {
            val operation = currentCoroutineContext()
            val local = office?.records(location.owner)?.singleOrNull { it.baseline.path == ref.path && localEdits(it) }
            if (local != null) OfficeDocumentTransfer(checkNotNull(office)).export(local.id, location.owner) { copy.outputStream() }
            else copy.outputStream().use { output -> repo.download(before, output) { _, _ ->
                    operation.ensureActive(); connection(location); repo.requireCurrentOwner()
                }; output.fd.sync() }
            currentCoroutineContext().ensureActive(); connection(location); repo.requireCurrentOwner()
            repo.refreshAccess(true)
            if (!repo.filePermissionAccess.granted) throw unavailable()
            connection(location); repo.requireCurrentOwner()
            if (copy.length() != (local?.localFingerprint?.bytes ?: before.size) ||
                local == null && !OfficeDocumentBaseline(before).matches(actual(repo, ref))) throw unavailable()
            retained = true; return copy
        } finally { if (!retained) copy.delete() }
    }
    suspend fun beginEdit(id: String): SystemOfficeEdit {
        val documents = office ?: throw unavailable()
        val ref = store.document(id); val location = store.location(ref.locationId)
        if (!location.editing || ref.directory) throw unavailable()
        val repo = access(location); val item = actual(repo, ref)
        if (!item.canWrite || !OfficeDocumentPolicy.supports(item)) throw unavailable()
        val transfer = OfficeDocumentTransfer(documents)
        val row = transfer.prepare(RepositoryOfficeDocumentEndpoint(repo), item)
        connection(location); repo.requireCurrentOwner(); repo.refreshAccess(true)
        if (!repo.filePermissionAccess.granted || !actual(repo, ref).canWrite) throw unavailable()
        val editing = withContext(NonCancellable) { transfer.beginExternal(row.id, repo.owner ?: throw workspaceChangedFailure()) }
        try {
            currentCoroutineContext().ensureActive()
            connection(location); repo.requireCurrentOwner()
            return SystemOfficeEdit(editing, documents.artifact(row.id, checkNotNull(editing.externalId)))
        } catch (error: Exception) { withContext(NonCancellable) { transfer.closeExternal(editing, successful = true) }; throw error }
    }
    suspend fun closeEdit(edit: SystemOfficeEdit, successful: Boolean) =
        OfficeDocumentTransfer(office ?: throw unavailable()).closeExternal(edit.record, successful)
    private fun decorate(location: SystemFileLocation, ref: SystemDocumentRef, item: FileItem?, records: List<OfficeDocumentRecord>): SystemDocumentItem {
        val local = records.singleOrNull { it.baseline.path == ref.path }
        return SystemDocumentItem(ref, if (local?.let(::localEdits) == true) item?.copy(size = local.localFingerprint.bytes) else item,
            canEdit = location.editing && item != null && item.canWrite && OfficeDocumentPolicy.supports(item) && local?.canImport != false,
            hasLocalEdits = local?.let(::localEdits) == true)
    }
    private fun localEdits(row: OfficeDocumentRecord) = row.candidateId != null && row.phase != OfficeDocumentPhase.SAVED
    private suspend fun actual(repo: DsmRepository, ref: SystemDocumentRef): FileItem =
        repo.fileStationRepository.crossNasReader.item(ref.path)?.takeIf {
            it.path == ref.path && it.isDirectory == ref.directory && it.canRead && isNormalFileMountType(it.mountPointType)
        } ?: throw unavailable()
    private fun unavailable() = DsmFailure(null, "The file is unavailable", "Open the original connection and refresh the folder.", kind = DsmErrorKind.INVALID_RESPONSE)

    companion object {
        fun create(context: Context, store: SystemDocumentStore = SystemDocumentStore(context)): SystemDocumentRuntime {
            val profiles = SecureProfileStore(context)
            return SystemDocumentRuntime(store, profiles, { location ->
                val saved = profiles.savedConnectionForRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id)
                val lease = profiles.lease(saved.owner)
                val api = DsmApiClient(LocalNetworkAccess(context).httpClient()).authorized({
                    lease.requireCurrent()
                    if (!location.enabled || store.location(location.id) != location) throw workspaceChangedFailure()
                })
                val discovered = DsmConnectionResolver(api).discover(saved.profile)
                DsmRepository(discovered.profile, saved.session, api, discovered.capabilities).also {
                    it.bindOwner(saved.owner, lease::requireCurrent)
                }
            }, OfficeDocumentStore(context))
        }
    }
}
