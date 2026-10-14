package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject

/** 内部挂载接口，绑定当前账号；未知结果只有回读，没有重放或删除目录的分支。 */
internal class DsmFileMountRepository(
    private val supports: (String, Int) -> Boolean,
    private val call: suspend (String, String, Map<String, String>, Int?) -> JsonObject,
    private val access: () -> FilePermissionAccess,
    private val refreshAccess: suspend () -> Unit,
    private val claimPaths: suspend (Set<String>) -> Boolean,
    private val releasePaths: suspend (Set<String>) -> Unit,
    private val permissionPendingPaths: suspend () -> List<String>,
    private val owner: () -> WorkspaceOwner?,
    private val requireOwner: () -> Unit,
    private val secureTransport: () -> Boolean = { false },
) {
    private val reader = FileMountReader(::request)
    val remote = DsmRemoteMountRepository(reader, ::request, ::supportsWrite, secureTransport, access, refreshAccess,
        claimPaths, releasePaths, { permissionPendingPaths() + pending().map { it.connection.mountPoint } }, owner, requireOwner)
    val vfs = DsmFileVFSRepository(supports, ::request, access, refreshAccess, secureTransport, owner, requireOwner)
    private var store: FileISOMountRecoveryStore? = null
    private val lock = Mutex()
    private val active = mutableSetOf<String>()
    fun bindRecovery(value: FileISOMountRecoveryStore) { store = value }
    fun supportsRead() = supports(MOUNT_LIST_API, 1) && supports("SYNO.FileStation.List", 2)
    fun supportsWrite() = supportsRead() && supports(MOUNT_API, 1)
    suspend fun inventory() = reader.inventory()
    suspend fun pendingPaths() = pending().map { it.connection.mountPoint } + remote.pending().flatMap { it.paths }
    suspend fun remoteLocations(offset: Int, limit: Int): FilePage {
        require(offset >= 0 && limit in 1..500)
        val data = request("SYNO.FileStation.VirtualFolder", "list", mapOf("type" to "all", "offset" to offset.toString(),
            "limit" to limit.toString(), "sort_by" to "name", "sort_direction" to "asc",
            "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\"]"), null)
        return io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture(data,
            if (data["folders"] is kotlinx.serialization.json.JsonArray) "folders" else "files")
    }
    suspend fun item(path: String, source: Boolean = false) = reader.item(path, requireFileMetadata = source) ?: throw mountChanged()
    suspend fun pending(): List<FileISOMountPending> = withContext(Dispatchers.IO) {
        requireOwner()
        (store ?: throw workspaceStorageFailure()).pending(owner() ?: throw workspaceStorageFailure())
    }

    suspend fun changeISOMountResult(change: FileISOMountChange, confirmed: Boolean): MutationResult {
        val point = change.mountPoint
        if (!lock.withLock { active.add(point) }) throw mountPending()
        val paths = if (change is FileISOMountChange.Mount) setOf(point, change.source.path) else setOf(point)
        var claimed = false
        try {
            requireOwner()
            if (!confirmed || !isMountTargetPath(point)) throw mountChanged()
            if (pending().any { record -> paths.any { mountPathsOverlap(it, record.connection.mountPoint) } }) throw mountPending()
            claimed = claimPaths(paths)
            if (!claimed) throw mountChanged()
            requireWriteAccess()
            checkPermissionChanges(paths)
            validate(change)
            // 清单与目录查询期间授权或目标可能变化，再次核对后才保存写前记录。
            requireWriteAccess()
            checkPermissionChanges(paths)
            val connection = validate(change)
            currentCoroutineContext().ensureActive(); requireOwner()
            val record = FileISOMountPending(owner = owner() ?: throw workspaceStorageFailure(),
                connecting = change is FileISOMountChange.Mount, connection = connection)
            withContext(Dispatchers.IO) { (store ?: throw workspaceStorageFailure()).begin(record) }
            try {
                requireOwner(); requireCurrentWriteAccess()
                if (record.connecting) request(MOUNT_API, "mount_iso", mapOf("source" to connection.source,
                    "mount_point" to point, "auto_mount" to connection.automatic.toString(), "user_set" to "true"), 1)
                else request(MOUNT_LIST_API, "unmount", mapOf("mount_point" to mountStrings(listOf(point))), 1)
            } catch (error: Exception) {
                if (error is DsmFailure && error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED,
                        DsmErrorKind.AUTHENTICATION_FAILED)) {
                    finish(record)
                    return result(MutationResultStatus.PERMISSION_DENIED)
                }
                if (error is CancellationException) throw error
            }
            return reviewCore(record)
        } finally {
            withContext(NonCancellable) {
                if (claimed) releasePaths(paths)
                lock.withLock { active.remove(point) }
            }
        }
    }

    suspend fun review(id: String): MutationResult {
        val record = pending().singleOrNull { it.id == id } ?: throw mountChanged()
        val point = record.connection.mountPoint
        if (!lock.withLock { active.add(point) }) throw mountPending()
        try { return reviewCore(record) }
        finally { withContext(NonCancellable) { lock.withLock { active.remove(point) } } }
    }

    private suspend fun reviewCore(record: FileISOMountPending): MutationResult {
        try {
            requireOwner()
            if (owner()?.hasSameIdentity(record.owner) != true) throw mountChanged()
            val inventory = reader.inventory()
            val expected = record.connection
            val item = reader.item(expected.mountPoint, allowMissing = !record.connecting)
            val related = inventory.connections.filter { mountPathsOverlap(it.mountPoint, expected.mountPoint) }
            val complete = if (record.connecting) related == listOf(expected) && item?.isDirectory == true && item.mountPointType == "iso"
                else related.isEmpty() && (item == null || item.isDirectory && isNormalFileMountType(item.mountPointType))
            if (complete) { finish(record); return result(MutationResultStatus.CONFIRMED_SUCCESS) }
        } catch (error: Exception) { if (error is CancellationException) throw error }
        return result(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED)
    }

    private suspend fun validate(change: FileISOMountChange): FileMountConnection {
        val inventory = reader.inventory()
        if (!inventory.isoEnabled) throw mountUnavailable()
        val related = inventory.connections.filter { mountPathsOverlap(it.mountPoint, change.mountPoint) }
        return when (change) {
            is FileISOMountChange.Mount -> {
                if (related.isNotEmpty() || !change.source.canRead || change.source.isDirectory || change.source.extension != "iso" ||
                    !isMountTargetPath(change.source.path) || mountPathsOverlap(change.source.path, change.mountPoint)) throw mountChanged()
                val source = reader.item(change.source.path, requireFileMetadata = true) ?: throw mountChanged()
                val destination = reader.item(change.mountPoint) ?: throw mountChanged()
                if (source != change.source.copy(accessedAtEpochSeconds = null) || !source.canRead ||
                    destination != change.destination.copy(accessedAtEpochSeconds = null) || !destination.isDirectory ||
                    !destination.canWrite || !isNormalFileMountType(destination.mountPointType)) throw mountChanged()
                reader.requireEmpty(change.mountPoint)
                FileMountConnection(FileMountKind.ISO, source.path, change.mountPoint, change.automatic)
            }
            is FileISOMountChange.Unmount -> {
                if (change.connection.kind != FileMountKind.ISO || related != listOf(change.connection)) throw mountChanged()
                val item = reader.item(change.mountPoint) ?: throw mountChanged()
                if (!item.isDirectory || item.mountPointType != "iso") throw mountChanged()
                change.connection
            }
        }
    }
    private suspend fun requireWriteAccess() { refreshAccess(); requireOwner(); requireCurrentWriteAccess() }
    private fun requireCurrentWriteAccess() {
        if (!supportsWrite()) throw mountUnavailable()
        if (!access().granted || !access().administrator) throw DsmFailure(null, "ISO mounts cannot be changed",
            "Ask the NAS administrator for access.", kind = DsmErrorKind.PERMISSION_DENIED)
    }
    private suspend fun checkPermissionChanges(paths: Set<String>) {
        if (permissionPendingPaths().any { pending -> paths.any { mountPathsOverlap(it, pending) } }) throw permissionPending()
        if (remote.pending().any { pending -> pending.paths.any { point -> paths.any { mountPathsOverlap(it, point) } } }) throw mountPending()
    }
    private suspend fun request(api: String, method: String, parameters: Map<String, String>, version: Int?): JsonObject {
        requireOwner()
        if (version != null && !supports(api, version)) throw mountUnavailable()
        return call(api, method, parameters, version)
    }
    private suspend fun finish(record: FileISOMountPending) = withContext(Dispatchers.IO) {
        requireOwner(); (store ?: throw workspaceStorageFailure()).finish(record)
    }
    private fun result(status: MutationResultStatus): MutationResult {
        val success = status == MutationResultStatus.CONFIRMED_SUCCESS
        val unknown = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        return MutationResult(1, status, "isoMount", true, unknown,
            MutationResultCounts(if (success) 1 else 0, if (!success && !unknown) 1 else 0, if (unknown) 1 else 0))
    }
}

internal fun mountUnavailable() = DsmFailure(null, "ISO mounts are unavailable", "Manage ISO files in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
