package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.ShareLinkMutationOutcome
import io.github.qwertyuiop1995.dsmnativeclient.data.matchesMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure

/** Sharing v3；内部成员/收集扩展只使用已记录字段，所有传输仍经过原工作区授权。 */
internal class DsmFileSharingRepository(
    private val supports: (String, Int) -> Boolean,
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val fileInfo: suspend (String) -> FileItem?,
    private val claimPaths: suspend (Set<String>) -> Boolean,
    private val releasePaths: suspend (Set<String>) -> Unit,
    private val owner: () -> WorkspaceOwner? = { null },
    private val requireOwner: () -> Unit = {},
) {
    private val pendingLock = Mutex()
    private val pendingKeys = mutableSetOf<String>()
    private var recoveryStore: FileShareRecoveryStore? = null

    fun bindRecovery(store: FileShareRecoveryStore) { recoveryStore = store }
    suspend fun pending(): List<FileSharePendingChange> = withContext(Dispatchers.IO) {
        requireOwner()
        recoveryStore?.pending(owner() ?: throw workspaceChangedFailure()).orEmpty()
    }
    suspend fun recover(): List<FileSharePendingChange> {
        val records = pending()
        if (records.isEmpty()) return records
        val links = list()
        records.filter { record -> links.any(record::matches) }.forEach { record ->
            requireOwner()
            withContext(Dispatchers.IO) { recoveryStore?.finish(record) }
            pendingLock.withLock { pendingKeys.remove(record.key) }
        }
        return pending()
    }

    suspend fun list(): List<FileShareLink> {
        val result = linkedMapOf<String, FileShareLink>()
        var offset = 0
        var expectedTotal: Int? = null
        do {
            currentCoroutineContext().ensureActive()
            val data = sharing("list", mapOf("offset" to offset.toString(), "limit" to "500"))
            val raw = data["links"] as? JsonArray ?: throw fileShareReadFailure()
            val total = data.integer("total") ?: throw fileShareReadFailure()
            if (total < offset || raw.size > 500 || raw.size > total - offset || raw.isEmpty() && offset < total ||
                data.integer("offset")?.let { it != offset } == true || expectedTotal?.let { it != total } == true) throw fileShareReadFailure()
            raw.map(::parseFileShareLink).forEach { if (result.put(it.id, it) != null) throw fileShareReadFailure() }
            offset += raw.size
            expectedTotal = total
        } while (offset < expectedTotal!!)
        return result.values.toList()
    }

    suspend fun principals(prefix: String, offset: Int, limit: Int = 200): FileSharePrincipalPage {
        require(offset >= 0 && limit in 1..200)
        if (!supports(PRINCIPALS, 1)) throw DsmFailure(null, "Member selection is unavailable", "Refresh or choose another sharing option.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        val data = call(PRINCIPALS, "list_all", mapOf("type" to "all", "prefix" to prefix, "offset" to offset.toString(), "limit" to limit.toString()), 1)
        val rows = data["owners"] as? JsonArray ?: throw fileShareReadFailure()
        val total = data.integer("total") ?: throw fileShareReadFailure()
        if (total < offset || rows.size > limit || rows.size > total - offset || rows.isEmpty() && offset < total) throw fileShareReadFailure()
        val items = rows.map {
            val row = it as? JsonObject ?: throw fileShareReadFailure()
            val name = row.text("name")?.takeIf(String::isNotBlank) ?: throw fileShareReadFailure()
            val kind = when (row.text("type")) { "user" -> FileSharePrincipalKind.USER; "group" -> FileSharePrincipalKind.GROUP; else -> throw fileShareReadFailure() }
            FileSharePrincipal(name, kind)
        }
        if (items.distinct().size != items.size) throw fileShareReadFailure()
        return FileSharePrincipalPage(items, total, offset + items.size)
    }

    suspend fun create(request: FileShareCreateRequest, checkBaseline: Boolean = true): ShareLinkMutationOutcome {
        val operation = "shareLinkCreate"
        val path = request.target.path.trimEnd('/')
        if (!request.isValid || !isFileMutationPath(path) || checkBaseline && path != request.target.path) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.VALIDATION)
        if (!supports(SHARING, 3)) return outcome(operation, MutationResultStatus.UNSUPPORTED, category = MutationErrorCategory.UNSUPPORTED)
        if (!currentCoroutineContext().isActive) return outcome(operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION)
        val key = "create:$path"
        val claimed = try { claim(key, path) } catch (error: Exception) { return failure(operation, error, submitted = false, submitting = false) }
        if (!claimed) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.CONFLICT)
        var submitted = false
        var unknown = false
        var submitting = false
        var recovery: FileSharePendingChange? = null
        try {
            val observed = fileInfo(path)
            if (observed == null || checkBaseline && !observed.matchesMutationBaseline(request.target)) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.CONFLICT)
            if (!observed.canRead || request.fileRequest != null && (!observed.isDirectory || !observed.canWrite)) return outcome(operation, MutationResultStatus.PERMISSION_DENIED, category = MutationErrorCategory.PERMISSION)
            val existing = list().mapTo(mutableSetOf(), FileShareLink::id)
            currentCoroutineContext().ensureActive()
            val parameters = buildMap {
                put("path", shareStrings(listOf(path)))
                request.password?.let { put("password", it) }
                request.availableOn?.let { put("date_available", it.toString()) }
                request.expiresOn?.let { put("date_expired", it.toString()) }
                request.fileRequest?.let { put("file_request", "true"); put("request_name", it.name); put("request_info", it.message) }
            }
            recovery = beginRecovery(key, path, request.target.name, request.expectation())
            submitted = true
            unknown = true
            submitting = true
            val response = sharing("create", parameters)
            submitting = false
            val rows = response["links"] as? JsonArray
            val receipt = rows?.singleOrNull() as? JsonObject
            val error = receipt?.integer("error")
            if (error != null && error != 0) {
                unknown = false
                return outcome(operation, if (error == 105) MutationResultStatus.PERMISSION_DENIED else MutationResultStatus.CONFIRMED_FAILURE, submitted = true,
                    category = if (error == 105) MutationErrorCategory.PERMISSION else MutationErrorCategory.SERVER)
            }
            val candidate = receipt?.takeIf { error == 0 }?.get("id")?.let { it as? JsonPrimitive }
                ?.takeIf { it.isString || it.longOrNull != null }?.contentOrNull
                ?.takeIf { it.isNotBlank() && receipt.text("path") == path && it !in existing }
            recovery = recovery?.copy(linkId = candidate, acknowledged = true)?.also { record ->
                withContext(Dispatchers.IO) { recoveryStore?.acknowledge(record) }
            }
            // 未返回明确编号时不能根据同名/同路径新链接认领其他客户端的创建。
            val confirmed = list().singleOrNull { it.id == candidate && it.path == path && request.expectation().matches(it, acknowledged = true) }
            if (confirmed != null) {
                unknown = false
                return outcome(operation, MutationResultStatus.CONFIRMED_SUCCESS, submitted = true, link = confirmed)
            }
            return outcome(operation, MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, submitted = true)
        } catch (error: Exception) {
            val result = failure(operation, error, submitted, submitting)
            unknown = result.result.requiresRefresh
            return result
        } finally {
            finish(key, path, unknown, recovery)
        }
    }

    suspend fun edit(request: FileShareEditRequest): ShareLinkMutationOutcome {
        val operation = "shareLinkEdit"
        if (!request.isValid) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.VALIDATION)
        if (!supports(SHARING, 3)) return outcome(operation, MutationResultStatus.UNSUPPORTED, category = MutationErrorCategory.UNSUPPORTED)
        if (!currentCoroutineContext().isActive) return outcome(operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION)
        val baseline = request.baseline
        val key = "edit:${baseline.id}"
        val claimed = try { claim(key, baseline.path) } catch (error: Exception) { return failure(operation, error, submitted = false, submitting = false) }
        if (!claimed) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.CONFLICT)
        var submitted = false
        var unknown = false
        var submitting = false
        var recovery: FileSharePendingChange? = null
        try {
            if (list().singleOrNull { it.id == baseline.id } != baseline) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.CONFLICT)
            val parameters = editParameters(request)
            if (request.advanced != null && list().singleOrNull { it.id == baseline.id } != baseline) return outcome(operation, MutationResultStatus.CONFIRMED_FAILURE, category = MutationErrorCategory.CONFLICT)
            currentCoroutineContext().ensureActive()
            recovery = beginRecovery(key, baseline.path, baseline.name, request.expectation(), baseline.id, baseline.url)
            submitted = true
            unknown = true
            var acknowledged = false
            try {
                submitting = true
                sharing("edit", parameters)
                acknowledged = true
                submitting = false
                recovery = recovery?.copy(acknowledged = true)?.also { record ->
                    withContext(Dispatchers.IO) { recoveryStore?.acknowledge(record) }
                }
            } catch (error: Exception) {
                if (error is CancellationException || error is DsmFailure && error.code != null) throw error
                submitting = false
                // 传输中断只读原链接，不重发写请求。
            }
            val updated = list().singleOrNull { it.id == baseline.id }
            if (updated != null && updated.path == baseline.path && updated.url == baseline.url && request.expectation().matches(updated, acknowledged)) {
                unknown = false
                return outcome(operation, MutationResultStatus.CONFIRMED_SUCCESS, submitted = true, link = updated)
            }
            return outcome(operation, MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, submitted = true)
        } catch (error: Exception) {
            val result = failure(operation, error, submitted, submitting)
            unknown = result.result.requiresRefresh
            return result
        } finally { finish(key, baseline.path, unknown, recovery) }
    }

    private suspend fun editParameters(request: FileShareEditRequest): Map<String, String> {
        val result = mutableMapOf("id" to shareStrings(listOf(request.baseline.id)))
        fun date(key: String, change: FileShareDateChange) { when (change) {
            FileShareDateChange.Keep -> Unit
            FileShareDateChange.Clear -> result[key] = "0"
            is FileShareDateChange.Set -> result[key] = change.date.toString()
        } }
        date("date_available", request.availableOn); date("date_expired", request.expiresOn)
        when (val password = request.password) {
            FileSharePasswordChange.Keep -> Unit
            FileSharePasswordChange.Remove -> result["password"] = ""
            is FileSharePasswordChange.Set -> result["password"] = password.value
        }
        val original = request.baseline.advanced
        request.advanced?.let { change ->
            when (val audience = change.audience) {
                FileShareAudienceChange.Keep -> Unit
                FileShareAudienceChange.Anyone -> result["protect_type"] = "none"
                is FileShareAudienceChange.Principals -> {
                    for (member in audience.members) {
                        var offset = 0
                        var found: Boolean
                        do {
                            val page = principals(member.name, offset)
                            found = member in page.items
                            offset = page.nextOffset
                        } while (!found && offset < page.total)
                        if (!found) throw DsmFailure(null, "A selected member is no longer available", "Choose members again.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED)
                    }
                    val users = audience.members.filter { it.kind == FileSharePrincipalKind.USER }.map { it.name }.sorted()
                    val groups = audience.members.filter { it.kind == FileSharePrincipalKind.GROUP }.map { it.name }.sorted()
                    result["protect_type"] = "user"
                    result["protect_users"] = shareStrings(users); result["protect_groups"] = shareStrings(groups)
                    result["new_protect_users"] = shareStrings(users.filter { it !in original!!.users })
                    result["new_protect_groups"] = shareStrings(groups.filter { it !in original!!.groups })
                }
            }
            change.maximumAccesses?.let { result["expire_times"] = it.toString() }
            change.requestName?.let { result["request_name"] = it }
            change.requestMessage?.let { result["request_info"] = it }
        }
        if (original?.isFileRequest == true) result["file_request"] = "true"
        return result
    }

    private suspend fun claim(key: String, path: String): Boolean {
        if (pending().any { it.key == key }) return false
        if (!pendingLock.withLock { pendingKeys.add(key) }) return false
        var claimed = false
        try { claimed = claimPaths(setOf(path)); return claimed }
        finally { if (!claimed) withContext(NonCancellable) { pendingLock.withLock { pendingKeys.remove(key) } } }
    }
    private suspend fun finish(key: String, path: String, unknown: Boolean, recovery: FileSharePendingChange?) = withContext(NonCancellable) {
        releasePaths(setOf(path))
        if (!unknown) pendingLock.withLock { pendingKeys.remove(key) }
        if (!unknown && recovery != null) withContext(Dispatchers.IO) { recoveryStore?.finish(recovery) }
    }
    private suspend fun beginRecovery(key: String, path: String, name: String, expected: FileShareExpectation,
                                      linkId: String? = null, originalUrl: String? = null): FileSharePendingChange? {
        val store = recoveryStore ?: return null
        requireOwner()
        val record = FileSharePendingChange(owner = owner() ?: throw workspaceChangedFailure(), key = key, path = path,
            name = name, expected = expected, linkId = linkId, originalUrl = originalUrl)
        withContext(Dispatchers.IO) { store.begin(record) }
        return record
    }
    private suspend fun sharing(method: String, parameters: Map<String, String>): JsonObject {
        requireOwner()
        return call(SHARING, method, parameters, 3)
    }

    private fun failure(operation: String, error: Exception, submitted: Boolean, submitting: Boolean): ShareLinkMutationOutcome {
        val category = when ((error as? DsmFailure)?.kind) {
            DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
            DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.SESSION_EXPIRED -> MutationErrorCategory.AUTHENTICATION
            DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED -> MutationErrorCategory.UNSUPPORTED
            DsmErrorKind.CONNECTION_FAILED -> MutationErrorCategory.NETWORK
            else -> MutationErrorCategory.SERVER
        }
        val status = when {
            error is CancellationException -> if (submitted) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION else MutationResultStatus.CANCELLED_BEFORE_SUBMISSION
            submitted && !submitting -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            category in setOf(MutationErrorCategory.PERMISSION, MutationErrorCategory.AUTHENTICATION) -> MutationResultStatus.PERMISSION_DENIED
            category == MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            submitted && (error !is DsmFailure || error.code == null) -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return outcome(operation, status, submitted, category = category)
    }

    private fun outcome(operation: String, status: MutationResultStatus, submitted: Boolean = false,
                        category: MutationErrorCategory? = null, link: FileShareLink? = null): ShareLinkMutationOutcome {
        val success = status == MutationResultStatus.CONFIRMED_SUCCESS
        val unknown = status in setOf(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION)
        return ShareLinkMutationOutcome(MutationResult(1, status, operation, submitted, unknown,
            MutationResultCounts(if (success) 1 else 0, if (!success && !unknown && status != MutationResultStatus.CANCELLED_BEFORE_SUBMISSION) 1 else 0, if (unknown) 1 else 0),
            category, "mutation.${operation.lowercase()}.${status.name.lowercase()}", "file-station.share-link.${operation.lowercase()}.${status.name.lowercase()}"), link)
    }

    private companion object {
        const val SHARING = "SYNO.FileStation.Sharing"
        const val PRINCIPALS = "SYNO.FileStation.UserGrp"
    }
}
