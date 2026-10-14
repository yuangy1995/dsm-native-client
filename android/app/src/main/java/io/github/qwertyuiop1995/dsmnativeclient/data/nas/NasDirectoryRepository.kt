package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

/** 固定公开记录的内部 v1；保存、删除共用完整列表和单次提交，不凭缓存结束操作。 */
internal class NasDirectoryRepository(private val gateway: NasManagementGateway, private val username: String) {
    private val mutex = Mutex()
    var recoveryPending: () -> Boolean = { false }
    suspend fun accounts() = decodeDirectoryAccounts(gateway.call("SYNO.Core.User", "list", 1, parameters(false)))
    suspend fun groups() = decodeDirectoryGroups(gateway.call("SYNO.Core.Group", "list", 1, parameters(true)))
    private fun parameters(group: Boolean) = mapOf("offset" to JsonPrimitive(0), "limit" to JsonPrimitive(1000),
        "additional" to JsonArray((if (group) listOf("gid", "description", "can_edit", "can_delete") else
            listOf("uid", "description", "email", "expired", "groups", "can_edit", "can_delete")).map(::JsonPrimitive)))
    suspend fun change(change: NasDirectoryChange, checkpoint: suspend (NasDirectoryStage) -> Unit): Boolean {
        if (!mutex.tryLock()) directoryFailure(NasDirectoryProblem.BUSY)
        try {
            if (recoveryPending()) directoryFailure(NasDirectoryProblem.BUSY)
            validate(change)
            gateway.requireWriteAccess()
            preflight(change)
            currentCoroutineContext().ensureActive()
            checkpoint(NasDirectoryStage.SUBMITTED)
            var accepted = false
            try {
                val fields = if (change.action == NasDirectoryAction.DELETE) mapOf("name" to JsonArray(listOf(JsonPrimitive(change.name))))
                    else directoryFields(change).toMutableMap().also { values ->
                        if (change.kind == NasDirectoryKind.ACCOUNT && (change.action == NasDirectoryAction.CREATE || change.password.isNotEmpty())) {
                            values["password"] = JsonPrimitive(change.password); values["password_confirm"] = JsonPrimitive(change.passwordConfirmation)
                        }
                    }
                gateway.call(if (change.kind == NasDirectoryKind.ACCOUNT) "SYNO.Core.User" else "SYNO.Core.Group",
                    when (change.action) { NasDirectoryAction.CREATE -> "create"; NasDirectoryAction.EDIT -> "set"; NasDirectoryAction.DELETE -> "delete" }, 1, fields, true)
                accepted = true
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (directoryExplicitRejection(error)) { checkpoint(NasDirectoryStage.REJECTED); throw error }
                if (directoryTrustFailure(error)) throw error
            }
            if (accepted) checkpoint(NasDirectoryStage.ACCEPTED)
            val complete = try { matches(change, accepted) } catch (error: Exception) {
                if (error is CancellationException || directoryTrustFailure(error)) throw error
                false
            }
            if (complete) checkpoint(NasDirectoryStage.COMPLETED)
            return complete
        } finally { mutex.unlock() }
    }
    private fun validate(value: NasDirectoryChange) {
        if (!directoryNameValid(value.name) || value.action == NasDirectoryAction.CREATE && value.name != value.name.trim()) directoryFailure(NasDirectoryProblem.INVALID)
        if (value.kind == NasDirectoryKind.GROUP && (value.account != null || value.password.isNotEmpty() || value.passwordConfirmation.isNotEmpty() || value.groups != null)) directoryFailure(NasDirectoryProblem.INVALID)
        if (value.kind == NasDirectoryKind.ACCOUNT && value.group != null) directoryFailure(NasDirectoryProblem.INVALID)
        if (value.action == NasDirectoryAction.CREATE && (value.account != null || value.group != null)) directoryFailure(NasDirectoryProblem.INVALID)
        if (value.action != NasDirectoryAction.CREATE && (value.account?.name ?: value.group?.name) != value.name) directoryFailure(NasDirectoryProblem.INVALID)
        if (value.kind == NasDirectoryKind.ACCOUNT && value.action != NasDirectoryAction.DELETE &&
            (value.action == NasDirectoryAction.CREATE && value.password.isEmpty() || value.password != value.passwordConfirmation)) directoryFailure(NasDirectoryProblem.INVALID)
        if (value.groups?.let { it.any { name -> !directoryNameValid(name) } || it.map(::directoryKey).distinct().size != it.size } == true) directoryFailure(NasDirectoryProblem.INVALID)
    }
    private suspend fun preflight(value: NasDirectoryChange) {
        val currentUser = value.name.equals(username, true)
        if (value.kind == NasDirectoryKind.ACCOUNT) {
            val rows = accounts(); val current = rows.singleOrNull { it.name.equals(value.name, true) }
            if (value.action == NasDirectoryAction.CREATE) { if (current != null) directoryFailure(NasDirectoryProblem.CHANGED) }
            else {
                if (current != value.account) directoryFailure(NasDirectoryProblem.CHANGED)
                if (value.action == NasDirectoryAction.DELETE) {
                    if (current?.canDelete != true || currentUser || directoryKey(value.name.trim()) in setOf("admin", "guest")) directoryFailure(NasDirectoryProblem.PERMISSION)
                } else if (current?.canEdit != true || !current.disabledKnown || currentUser && (value.disabled || value.groups != null)) directoryFailure(NasDirectoryProblem.PERMISSION)
            }
            if (value.groups != null) {
                if (currentUser || value.action == NasDirectoryAction.EDIT && value.account?.groups == null) directoryFailure(NasDirectoryProblem.PERMISSION)
                val groups = groups()
                if (groups != value.groupsBaseline || value.groups.any { name -> groups.none { it.name == name } }) directoryFailure(NasDirectoryProblem.CHANGED)
            }
        } else {
            val rows = groups(); val current = rows.singleOrNull { it.name.equals(value.name, true) }
            if (value.action == NasDirectoryAction.CREATE) { if (current != null) directoryFailure(NasDirectoryProblem.CHANGED) }
            else {
                if (current != value.group) directoryFailure(NasDirectoryProblem.CHANGED)
                if (value.action == NasDirectoryAction.DELETE) {
                    if (current?.canDelete != true || directoryKey(value.name.trim()) in setOf("administrators", "users", "http")) directoryFailure(NasDirectoryProblem.PERMISSION)
                } else if (current?.canEdit != true) directoryFailure(NasDirectoryProblem.PERMISSION)
            }
        }
    }
    private suspend fun matches(value: NasDirectoryChange, accepted: Boolean): Boolean {
        if (value.kind == NasDirectoryKind.ACCOUNT) {
            val current = accounts().singleOrNull { it.name.equals(value.name, true) }
            if (value.action == NasDirectoryAction.DELETE) return current == null
            return current != null && (!value.requiresAcknowledgement || accepted) &&
                (value.action == NasDirectoryAction.CREATE || current.id == value.originalId) && directoryFields(current, value.groups != null) == directoryFields(value)
        }
        val current = groups().singleOrNull { it.name.equals(value.name, true) }
        if (value.action == NasDirectoryAction.DELETE) return current == null
        return current != null && (!value.requiresAcknowledgement || accepted) &&
            (value.action == NasDirectoryAction.CREATE || current.id == value.originalId) && directoryFields(current) == directoryFields(value)
    }
}
internal fun directoryExplicitRejection(error: Exception): Boolean = error is DsmFailure &&
    (error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.FEATURE_UNSUPPORTED) || error.code != null || error.isExplicitApiRejection)
internal fun directoryTrustFailure(error: Exception): Boolean = error is DsmFailure && error.kind in setOf(
    DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.WORKSPACE_CHANGED,
    DsmErrorKind.TLS_UNTRUSTED, DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH, DsmErrorKind.LOCAL_STORAGE_FAILED)
