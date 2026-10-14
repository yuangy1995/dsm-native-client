package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

internal data class FilePermissionOutcome(val result: MutationResult, val partialFailure: Boolean = false)

/** 已记录的内部 ACL/Property 接口；写前完整快照、明确授权、自锁检查和不可重放日志。 */
internal class DsmFilePermissionRepository(
    private val supports: (String, Int) -> Boolean,
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val access: () -> FilePermissionAccess,
    private val refreshAccess: suspend () -> Unit,
    private val principals: suspend (String, Int, Int) -> FileSharePrincipalPage,
    private val claimPaths: suspend (Set<String>) -> Boolean,
    private val releasePaths: suspend (Set<String>) -> Unit,
    private val owner: () -> WorkspaceOwner?,
    private val requireOwner: () -> Unit,
    private val mountPendingPaths: suspend () -> List<String> = { emptyList() },
) {
    private val reader = FilePermissionReader(::request, access)
    private var store: FilePermissionRecoveryStore? = null
    private val lock = Mutex()
    private val active = mutableSetOf<String>()
    // 保存回执失败时仍保留内存证据；冷启动只采用已经成功保存的较保守记录。
    private val memoryPending = mutableMapOf<String, FilePermissionPending>()
    fun bindRecovery(value: FilePermissionRecoveryStore) { store = value }
    fun supportsRead() = supports("SYNO.FileStation.List", 2)
    suspend fun load(path: String): FilePermissionSnapshot {
        val value = reader.load(path)
        return value.copy(canChangePermissions = value.canChangePermissions && supports(
            if (value.isACL) PERMISSION_ACL_API else PERMISSION_PROPERTY_API, 1))
    }
    suspend fun pending(): List<FilePermissionPending> = withContext(Dispatchers.IO) {
        requireOwner()
        val records = store?.pending(owner() ?: throw workspaceStorageFailure()) ?: throw workspaceStorageFailure()
        lock.withLock { records.map { memoryPending[it.id] ?: it } }
    }

    suspend fun changePermissionsResult(change: FilePermissionChange, confirmed: Boolean): FilePermissionOutcome {
        val path = change.baseline.target.path
        if (!lock.withLock { active.add(path) }) throw permissionChanged()
        var claimed = false
        try {
            requireOwner()
            if (pending().any { permissionPathsOverlap(it.path, path) }) throw permissionPending()
            claimed = claimPaths(setOf(path))
            if (!claimed) throw permissionChanged()
            if (mountPendingPaths().any { permissionPathsOverlap(it, path) }) throw mountPending()
            if (!confirmed || !change.hasChanges || !permissionTargetEditable(change.baseline.target) ||
                change.recursive && !change.baseline.target.isDirectory) throw permissionDenied()
            requireWriteAccess(change)
            if (load(path) != change.baseline) throw permissionChanged()
            val parameters = parameters(change)
            // 查询成员及自锁期间可能有人修改权限；再次读取授权和目标完整快照。
            requireWriteAccess(change)
            if (load(path) != change.baseline) throw permissionChanged()
            currentCoroutineContext().ensureActive()
            requireOwner()
            val recovery = store ?: throw workspaceStorageFailure()
            var record = FilePermissionPending(owner = owner() ?: throw workspaceStorageFailure(), path = path,
                isACL = change.baseline.isACL, recursive = change.recursive, expected = change.expectation())
            withContext(Dispatchers.IO) { recovery.begin(record) }
            lock.withLock { memoryPending[record.id] = record }
            try {
                requireOwner()
                requireCurrentWriteAccess(change)
                val response = request(api(record), "set", parameters, 1)
                val task = permissionTask(response, record.isACL)
                record = record.copy(acknowledged = true, taskId = task.id,
                    finished = task.finished || task.id == null && !record.recursive && !task.running,
                    partialFailure = task.failed)
                save(record)
            } catch (error: Exception) {
                // 只有明确权限拒绝能证明没有修改；超时、取消、格式错误均保留只读恢复。
                if (error is DsmFailure && error.kind == DsmErrorKind.PERMISSION_DENIED) {
                    finish(record)
                    return outcome(MutationResultStatus.PERMISSION_DENIED)
                }
                if (error is CancellationException) throw error
            }
            return reviewCore(record)
        } finally {
            withContext(NonCancellable) {
                if (claimed) releasePaths(setOf(path))
                lock.withLock { active.remove(path) }
            }
        }
    }

    suspend fun review(path: String): FilePermissionOutcome {
        if (!lock.withLock { active.add(path) }) throw permissionChanged()
        try {
            val record = pending().singleOrNull { it.path == path } ?: throw permissionChanged()
            return reviewCore(record)
        } finally { withContext(NonCancellable) { lock.withLock { active.remove(path) } } }
    }
    private suspend fun reviewCore(original: FilePermissionPending): FilePermissionOutcome {
        var record = original
        try {
            requireOwner()
            if (owner()?.hasSameIdentity(record.owner) != true) throw permissionDenied()
            if (record.partialFailure) return outcome(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, true)
            if (record.taskId != null && !record.finished) {
                val data = request(api(record), "status", mapOf((if (record.isACL) "task_id" else "taskid") to record.taskId!!), 1)
                val task = permissionTask(data, record.isACL)
                record = record.copy(finished = task.finished, partialFailure = task.failed)
                save(record)
            }
            if (record.partialFailure) return outcome(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, true)
            val current = load(record.path)
            if (record.expected.matches(current) && (!record.recursive || record.acknowledged && record.finished) &&
                (record.taskId == null || record.finished)) {
                finish(record)
                return outcome(MutationResultStatus.CONFIRMED_SUCCESS)
            }
        } catch (error: Exception) { if (error is CancellationException) throw error }
        return outcome(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, record.partialFailure)
    }
    private suspend fun requireWriteAccess(change: FilePermissionChange) {
        refreshAccess(); requireOwner()
        requireCurrentWriteAccess(change)
    }
    private fun requireCurrentWriteAccess(change: FilePermissionChange) {
        val current = access()
        if (!current.granted || (!change.baseline.isACL || change.owner != null || change.group != null) && !current.administrator) throw permissionDenied()
    }
    private suspend fun parameters(change: FilePermissionChange): Map<String, String> {
        val before = change.baseline
        for (principal in listOfNotNull(change.owner, change.group)) requirePrincipal(principal)
        return if (before.isACL) {
            if (change.posixMode != null || change.group != null || change.owner != null && before.owner?.canChange != true ||
                change.explicitRules != null && !before.canChangePermissions) throw permissionDenied()
            val rules = change.explicitRules ?: before.explicitRules
            if (rules.size > 200 || rules.any { it.level != 0 }) throw permissionFailure()
            for (rule in rules) {
                if (before.explicitRules.none { it.ownerType == rule.ownerType && it.ownerName == rule.ownerName &&
                        it.ownerId == rule.ownerId && it.isInternal == rule.isInternal }) {
                    val kind = FileSharePrincipalKind.entries.singleOrNull { it.name.lowercase() == rule.ownerType }
                        ?: throw permissionFailure()
                    if (rule.ownerId != null || rule.isInternal != null) throw permissionFailure()
                    requirePrincipal(FileSharePrincipal(rule.ownerName, kind))
                }
            }
            val result = buildMap {
                put("file_path", before.resolvedPath); put("change_acl", (change.explicitRules != null).toString())
                put("rules", JsonArray(rules.map(::permissionRulePayload)).toString()); put("inherited", before.isInherited.toString())
                put("acl_recur", (change.recursive && change.explicitRules != null).toString())
                change.owner?.let {
                    put("change_acl_owner", "true"); put("acl_owner_type", it.kind.name.lowercase()); put("acl_owner", it.name)
                    put("acl_owner_recur", change.recursive.toString())
                }
            }
            val check = request(PERMISSION_ACL_API, "check_self_denied", result, 1)
            if (check.permissionBoolean("is_denied")) throw DsmFailure(null, "This change would remove your own access",
                "Keep a rule that allows your account to manage permissions.", kind = DsmErrorKind.FILE_PERMISSIONS_SELF_DENIED)
            result
        } else {
            if (!before.canChangePermissions || change.explicitRules != null || change.owner?.kind == FileSharePrincipalKind.GROUP ||
                change.group?.kind == FileSharePrincipalKind.USER || change.posixMode?.let { !validFilePermissionMode(it) } == true) throw permissionDenied()
            buildMap {
                put("files", permissionStrings(listOf(before.resolvedPath)))
                put("dir_paths", permissionStrings(listOf(if (before.target.isDirectory) before.target.path else before.target.path.substringBeforeLast('/'))))
                put("mode", change.posixMode ?: "-1"); put("posix_mode_recur", (change.recursive && change.posixMode != null).toString())
                put("posix_owner_recur", (change.recursive && (change.owner != null || change.group != null)).toString())
                change.owner?.let { put("owner", it.name) }; change.group?.let { put("group", it.name) }
            }
        }
    }
    private suspend fun requirePrincipal(principal: FileSharePrincipal) {
        var offset = 0
        do {
            currentCoroutineContext().ensureActive()
            val page = principals(principal.name, offset, 200)
            if (principal in page.items) return
            if (page.nextOffset <= offset || page.nextOffset >= page.total) break
            offset = page.nextOffset
        } while (true)
        throw permissionChanged()
    }
    private suspend fun request(api: String, method: String, parameters: Map<String, String>, version: Int): JsonObject {
        requireOwner()
        if (!supports(api, version)) throw DsmFailure(null, "Permissions are unavailable", "Use DSM to manage this item.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        return call(api, method, parameters, version)
    }
    private suspend fun save(record: FilePermissionPending) {
        requireOwner()
        lock.withLock { memoryPending[record.id] = record }
        withContext(Dispatchers.IO) { (store ?: throw workspaceStorageFailure()).update(record) }
    }
    private suspend fun finish(record: FilePermissionPending) {
        requireOwner()
        withContext(Dispatchers.IO) { (store ?: throw workspaceStorageFailure()).finish(record) }
        lock.withLock { memoryPending.remove(record.id) }
    }
    private fun api(record: FilePermissionPending) = if (record.isACL) PERMISSION_ACL_API else PERMISSION_PROPERTY_API
    private fun outcome(status: MutationResultStatus, partial: Boolean = false): FilePermissionOutcome {
        val success = status == MutationResultStatus.CONFIRMED_SUCCESS
        val unknown = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        return FilePermissionOutcome(MutationResult(1, status, "filePermissions", true, unknown,
            MutationResultCounts(if (success) 1 else 0, if (!success && !unknown) 1 else 0, if (unknown) 1 else 0)), partial)
    }
}

private data class PermissionTask(val id: String?, val running: Boolean, val finished: Boolean, val failed: Boolean)
private fun permissionTask(data: JsonObject, isACL: Boolean): PermissionTask {
    val idKey = if (isACL) "task_id" else "taskid"
    val id = data[idKey]?.takeUnless { it is JsonNull }?.let { value ->
        (value as? JsonPrimitive)?.takeIf { it.isString || it.longOrNull != null }?.contentOrNull
            ?.takeIf(String::isNotBlank) ?: throw permissionFailure()
    }
    fun flag(key: String) = data[key]?.takeUnless { it is JsonNull }?.let { data.permissionBoolean(key) } ?: false
    val errors = data["errItems"]?.takeUnless { it is JsonNull }?.let { it as? JsonArray ?: throw permissionFailure() }
    val errno = data["errno"]?.takeUnless { it is JsonNull }?.permissionInteger()
    return PermissionTask(id, flag("running"), flag("finished"), data.permissionText("result") == "fail" ||
        errno != null && errno != 0L || errors?.isNotEmpty() == true)
}
