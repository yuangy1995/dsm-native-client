package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonObject

internal enum class RemoteMountOutcomeStatus { COMPLETED, READY, UNKNOWN, REJECTED, ENDED }
internal data class RemoteMountOutcome(val status: RemoteMountOutcomeStatus, val pending: FileRemoteMountPending? = null, val failure: DsmFailure? = null)

/** 复用挂载清单与文件路径锁；每次确认最多执行一个写步骤。 */
internal class DsmRemoteMountRepository(
    private val reader: FileMountReader,
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val supportsWrite: () -> Boolean,
    private val secureTransport: () -> Boolean,
    private val access: () -> FilePermissionAccess,
    private val refreshAccess: suspend () -> Unit,
    private val claimPaths: suspend (Set<String>) -> Boolean,
    private val releasePaths: suspend (Set<String>) -> Unit,
    private val otherPendingPaths: suspend () -> List<String>,
    private val owner: () -> WorkspaceOwner?,
    private val requireOwner: () -> Unit,
) {
    private var store: FileRemoteMountRecoveryStore? = null
    fun bindRecovery(value: FileRemoteMountRecoveryStore) { store = value }
    suspend fun pending(): List<FileRemoteMountPending> = withContext(Dispatchers.IO) {
        requireOwner(); (store ?: throw workspaceStorageFailure()).pending(owner() ?: throw workspaceStorageFailure())
    }

    suspend fun changeRemoteMountResult(setup: FileRemoteMountSetup?, baseline: FileMountConnection?, destination: FileItem?,
                      password: String, confirmed: Boolean): RemoteMountOutcome {
        requireOwner()
        if (!confirmed || setup == null && baseline == null) throw mountChanged()
        val normalized = setup?.let { runCatching { it.normalized() }.getOrElse { throw remoteMountOptionsInvalid() } }
        if (normalized != null && !isMountTargetPath(normalized.mountPoint) || baseline != null &&
            (baseline.kind == FileMountKind.ISO || !isMountTargetPath(baseline.mountPoint))) throw mountChanged()
        if (normalized != null && baseline != null && normalized.mountPoint != baseline.mountPoint &&
            mountPathsOverlap(normalized.mountPoint, baseline.mountPoint)) throw mountChanged()
        val action = if (baseline == null) RemoteMountAction.CREATE else if (normalized == null) RemoteMountAction.DISCONNECT else RemoteMountAction.UPDATE
        val connecting = baseline == null || normalized != null && normalized.mountPoint != baseline.mountPoint
        val record = FileRemoteMountPending(owner = owner() ?: throw workspaceStorageFailure(), action = action, baseline = baseline,
            setup = normalized, stage = if (connecting) RemoteMountStage.CHECK_CONNECTION else RemoteMountStage.CHECK_DISCONNECTION)
        return withPaths(record.paths) {
            checkPending(record.paths)
            repeat(2) {
                requireWriteAccess(record, password, connecting)
                validateInitial(record, destination)
            }
            currentCoroutineContext().ensureActive(); requireOwner()
            persist { it.begin(record) }
            submit(record, connecting, password, rejected = null)
        }
    }

    suspend fun review(id: String): RemoteMountOutcome {
        val record = pending().singleOrNull { it.id == id } ?: throw mountChanged()
        return withPaths(record.paths) {
            requireRecord(record)
            if (record.stage.canContinue) RemoteMountOutcome(RemoteMountOutcomeStatus.READY, record) else reviewCore(record)
        }
    }

    suspend fun continueRemoteMountResult(id: String, password: String, confirmed: Boolean): RemoteMountOutcome {
        if (!confirmed) throw mountChanged()
        val record = pending().singleOrNull { it.id == id } ?: throw mountChanged()
        return withPaths(record.paths) {
            requireRecord(record)
            // 过期窗口对未知步骤只能回读，即使读到下一阶段，也不顺带发送它。
            if (!record.stage.canContinue) return@withPaths reviewCore(record)
            checkPending(record.paths, record.id)
            val connecting = record.stage == RemoteMountStage.READY_TO_CONNECT
            repeat(2) {
                requireWriteAccess(record, password, connecting)
                val inventory = reader.inventory()
                if (!inventory.remoteEnabled) throw mountUnavailable()
                if (connecting) requireDestination(record.setup!!, inventory)
                else {
                    requirePresent(record.setup!!.connection, inventory)
                    val related = related(inventory, record.baseline!!.mountPoint)
                    if (related.isEmpty()) {
                        requireAbsent(record.baseline.mountPoint, inventory)
                        persist { it.replace(record, null) }
                        return@withPaths RemoteMountOutcome(RemoteMountOutcomeStatus.COMPLETED)
                    }
                    requirePresent(record.baseline, inventory)
                }
            }
            currentCoroutineContext().ensureActive(); requireOwner()
            val submitted = record.copy(stage = if (connecting) RemoteMountStage.CHECK_CONNECTION else RemoteMountStage.CHECK_DISCONNECTION)
            persist { it.replace(record, submitted) }
            submit(submitted, connecting, password, rejected = record)
        }
    }

    suspend fun endRemaining(id: String, confirmed: Boolean): RemoteMountOutcome {
        if (!confirmed) throw mountChanged()
        val record = pending().singleOrNull { it.id == id } ?: throw mountChanged()
        return withPaths(record.paths) {
            requireRecord(record)
            if (!record.stage.canContinue) throw mountPending()
            persist { it.replace(record, null) }
            RemoteMountOutcome(RemoteMountOutcomeStatus.ENDED)
        }
    }

    private suspend fun submit(record: FileRemoteMountPending, connecting: Boolean, password: String,
                               rejected: FileRemoteMountPending?): RemoteMountOutcome {
        try {
            requireOwner(); requireCurrentAccess(record, password, connecting)
            if (connecting) {
                val setup = record.setup!!
                val parameters = linkedMapOf("mount_type" to setup.kind.name, "server_ip" to setup.source,
                    "mount_point" to setup.mountPoint, "user_set" to "true", "auto_mount" to setup.automatic.toString())
                if (setup.kind == FileMountKind.CIFS) {
                    parameters["account"] = if (setup.domain.isEmpty()) setup.username else "${setup.domain}\\${setup.username}"
                    parameters["passwd"] = password
                } else { parameters["nfs_version"] = setup.nfsVersion; parameters["protocol"] = setup.nfsTransport }
                call(MOUNT_API, "mount_remote", parameters, 1)
            } else call(MOUNT_LIST_API, "unmount", mapOf("mount_point" to mountStrings(listOf(record.baseline!!.mountPoint))), 1)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (error is DsmFailure && isDefiniteRejection(error)) {
                persist { it.replace(record, rejected) }
                return RemoteMountOutcome(RemoteMountOutcomeStatus.REJECTED, rejected, error)
            }
            // 传输失败或缺失回执不代表 NAS 没有执行；只尝试读取当前结果。
        }
        return reviewCore(record)
    }

    private suspend fun reviewCore(record: FileRemoteMountPending): RemoteMountOutcome {
        val next: FileRemoteMountPending?
        try {
            requireRecord(record)
            val inventory = reader.inventory()
            if (record.stage == RemoteMountStage.CHECK_CONNECTION) {
                requirePresent(record.setup!!.connection, inventory)
                next = if (record.action == RemoteMountAction.UPDATE && record.baseline!!.mountPoint != record.setup.mountPoint)
                    record.copy(stage = RemoteMountStage.READY_TO_DISCONNECT) else null
            } else {
                requireAbsent(record.baseline!!.mountPoint, inventory)
                next = if (record.action == RemoteMountAction.UPDATE && record.baseline.mountPoint == record.setup!!.mountPoint)
                    record.copy(stage = RemoteMountStage.READY_TO_CONNECT) else null
                if (record.action == RemoteMountAction.UPDATE && next == null) requirePresent(record.setup!!.connection, inventory)
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            return RemoteMountOutcome(RemoteMountOutcomeStatus.UNKNOWN, record)
        }
        // 只有同步保存成功才报告进展；保存失败时不执行任何后续写操作。
        persist { it.replace(record, next) }
        return RemoteMountOutcome(if (next == null) RemoteMountOutcomeStatus.COMPLETED else RemoteMountOutcomeStatus.READY, next)
    }

    private suspend fun validateInitial(record: FileRemoteMountPending, destination: FileItem?) {
        val inventory = reader.inventory()
        if (!inventory.remoteEnabled) throw mountUnavailable()
        if (record.baseline != null) requirePresent(record.baseline, inventory)
        if (record.setup != null && record.setup.mountPoint != record.baseline?.mountPoint) {
            val item = requireDestination(record.setup, inventory)
            if (destination == null || item != destination.copy(accessedAtEpochSeconds = null)) throw mountChanged()
        }
    }
    private suspend fun requireDestination(setup: FileRemoteMountSetup, inventory: FileMountInventory): FileItem {
        if (related(inventory, setup.mountPoint).isNotEmpty()) throw mountChanged()
        val item = reader.item(setup.mountPoint) ?: throw mountChanged()
        if (!item.isDirectory || !item.canWrite || !isNormalFileMountType(item.mountPointType)) throw mountChanged()
        reader.requireEmpty(setup.mountPoint)
        return item
    }
    private suspend fun requirePresent(connection: FileMountConnection, inventory: FileMountInventory) {
        if (related(inventory, connection.mountPoint) != listOf(connection)) throw mountChanged()
        val item = reader.item(connection.mountPoint) ?: throw mountChanged()
        if (!item.isDirectory || !isRemoteMountType(item.mountPointType, connection.kind)) throw mountChanged()
    }
    private suspend fun requireAbsent(path: String, inventory: FileMountInventory) {
        if (related(inventory, path).isNotEmpty()) throw mountChanged()
        val item = reader.item(path, allowMissing = true)
        if (item != null && (!item.isDirectory || !isNormalFileMountType(item.mountPointType))) throw mountChanged()
    }
    private fun related(inventory: FileMountInventory, path: String) = inventory.connections.filter { mountPathsOverlap(it.mountPoint, path) }
    private suspend fun requireWriteAccess(record: FileRemoteMountPending, password: String, connecting: Boolean) {
        refreshAccess(); requireOwner(); requireCurrentAccess(record, password, connecting)
        if (otherPendingPaths().any { path -> record.paths.any { mountPathsOverlap(it, path) } }) throw mountPending()
    }
    private fun requireCurrentAccess(record: FileRemoteMountPending, password: String, connecting: Boolean) {
        if (!supportsWrite()) throw mountUnavailable()
        if (!access().granted || (record.setup?.automatic == true || record.baseline != null && record.baseline.automatic != false) &&
            !access().administrator) throw DsmFailure(null, "Remote connection access denied", "Ask the NAS administrator for access.", kind = DsmErrorKind.PERMISSION_DENIED)
        if (connecting && record.setup?.kind == FileMountKind.CIFS && !secureTransport()) throw DsmFailure(null,
            "A secure NAS connection is required", "Reconnect to the NAS securely before entering remote credentials.", kind = DsmErrorKind.INSECURE_ADDRESS)
        if (connecting && record.setup?.kind == FileMountKind.NFS && password.isNotEmpty()) throw remoteMountOptionsInvalid()
    }
    private suspend fun checkPending(paths: Set<String>, excluding: String? = null) {
        if (pending().any { row -> row.id != excluding && row.paths.any { first -> paths.any { mountPathsOverlap(first, it) } } }) throw mountPending()
    }
    private suspend fun requireRecord(record: FileRemoteMountPending) {
        requireOwner()
        if (pending().singleOrNull { it.id == record.id } != record) throw mountChanged()
    }
    private suspend fun persist(block: (FileRemoteMountRecoveryStore) -> Unit) = withContext(Dispatchers.IO) {
        requireOwner(); block(store ?: throw workspaceStorageFailure())
    }
    private suspend fun <T> withPaths(paths: Set<String>, block: suspend () -> T): T {
        requireOwner()
        if (!claimPaths(paths)) throw mountPending()
        try { return block() } finally { withContext(NonCancellable) { releasePaths(paths) } }
    }
    private fun isDefiniteRejection(error: DsmFailure) = error.kind in setOf(DsmErrorKind.PERMISSION_DENIED,
        DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.FEATURE_UNSUPPORTED,
        DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED) || error.kind == DsmErrorKind.REQUEST_FAILED && (error.code ?: 0) > 0
}

internal fun isRemoteMountType(type: String?, kind: FileMountKind) = type == "remote" || type == kind.name.lowercase(java.util.Locale.ROOT)
internal fun remoteMountOptionsInvalid() = DsmFailure(null, "Remote connection fields are invalid", "Check the server, shared folder, and connection options.", kind = DsmErrorKind.FILE_REMOTE_MOUNT_OPTIONS)
