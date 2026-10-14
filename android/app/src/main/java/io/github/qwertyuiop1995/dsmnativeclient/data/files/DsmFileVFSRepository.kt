package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

/** Connection 和 Profile 分别记录结果，恢复入口只有读取，永不重放组合写入。 */
internal class DsmFileVFSRepository(
    private val supports: (String, Int) -> Boolean,
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val access: () -> FilePermissionAccess, private val refreshAccess: suspend () -> Unit,
    private val secureTransport: () -> Boolean, private val owner: () -> WorkspaceOwner?, private val requireOwner: () -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) {
    val reader = FileVFSReader(call, owner, requireOwner)
    private val mutex = Mutex()
    private var store: FileVFSRecoveryStore? = null
    private var authorizationRequest: FileVFSCloudRequest? = null
    fun bindRecovery(value: FileVFSRecoveryStore) { store = value }
    fun supportsRead() = supports(VFS_PROFILE_API, 1) && supports(VFS_PROTOCOL_API, 1)
    fun supportsWrite() = supportsRead() && supports(VFS_CONNECTION_API, 1)
    suspend fun pending(): List<FileVFSPending> = withContext(Dispatchers.IO) {
        requireOwner(); (store ?: throw workspaceStorageFailure()).pending(owner() ?: throw workspaceStorageFailure())
    }

    suspend fun prepareCloudAuthorization(protocolId: String): FileVFSCloudRequest {
        requireSecure(); requireWrite()
        if (!reader.protocols().any { it.id == protocolId && it.supportsCloudAuthorization }) throw vfsUnavailable()
        val info = call("SYNO.Core.System", "info", emptyMap(), 1)
        val version = (info["firmware_ver"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw vfsReadFailure()
        val match = Regex("(?:^|[^0-9])([0-9]+)\\.([0-9]+)(?:[^0-9]|$)").find(version) ?: throw vfsReadFailure()
        val major = match.groupValues[1].toIntOrNull()?.takeIf { it > 0 } ?: throw vfsReadFailure()
        val minor = match.groupValues[2].toIntOrNull() ?: throw vfsReadFailure()
        requireOwner()
        return FileVFSCloudRequest(owner = owner() ?: throw workspaceStorageFailure(), protocolId = protocolId,
            loginUrl = "https://synooauth.synology.com/FileStation/Cloud/login.php?major=$major&minor=$minor&type=$protocolId",
            createdAtMillis = now()).also { authorizationRequest = it }
    }
    fun cancelCloudAuthorization(id: String) { if (authorizationRequest?.id == id) authorizationRequest = null }

    suspend fun changeVFSResult(change: FileVFSChange, password: String?, confirmed: Boolean,
                                cleartextAccepted: Boolean = false): FileVFSOutcome {
        if (change is FileVFSChange.CreateCloud || change is FileVFSChange.Reauthorize) throw vfsChanged()
        return locked { perform(change, password, null, confirmed, cleartextAccepted) }
    }
    suspend fun authorizeVFSResult(change: FileVFSChange, authorization: FileVFSCloudAuthorization, confirmed: Boolean): FileVFSOutcome = locked {
        if (change !is FileVFSChange.CreateCloud && change !is FileVFSChange.Reauthorize) throw vfsChanged()
        val request = authorizationRequest ?: throw vfsAuthorizationExpired()
        if (request.owner != owner() || request.id != authorization.requestId || request.owner != authorization.owner ||
            request.protocolId != authorization.protocolId || now() - request.createdAtMillis !in 0..600_000) throw vfsAuthorizationExpired()
        authorizationRequest = null
        perform(change, null, authorization, confirmed, false)
    }

    private suspend fun perform(raw: FileVFSChange, password: String?, authorization: FileVFSCloudAuthorization?, confirmed: Boolean,
                                cleartextAccepted: Boolean): FileVFSOutcome {
        if (!confirmed) throw vfsChanged()
        requireWrite()
        if (pending().isNotEmpty()) throw vfsPending()
        val before = reader.profiles()
        val change = when (raw) {
            is FileVFSChange.Create -> raw.copy(setup = resolve(raw.setup))
            is FileVFSChange.Update -> raw.copy(setup = resolve(raw.setup, raw.baseline.profile.protocolId))
            else -> raw
        }
        val parameters: Map<String, String>; val method: String
        when (change) {
            is FileVFSChange.Create -> {
                requireSecure(); requireCleartext(change.setup, cleartextAccepted)
                if (before.any { it.alias == change.setup.alias || it.matches(change.setup) }) throw vfsChanged()
                parameters = setupParameters(change.setup, password ?: ""); method = "create"
            }
            is FileVFSChange.Update -> {
                requireSecure(); requireCleartext(change.setup, cleartextAccepted)
                val baseline = change.baseline
                requireBaseline(before, baseline.profile)
                if (baseline.profile.state == FileVFSConnectionState.UNKNOWN || reader.detail(baseline.profile).configuration != baseline.configuration ||
                    change.setup == baseline.configuration && password == null || before.any { it.id != baseline.profile.id && it.alias == change.setup.alias }) throw vfsChanged()
                val original = setupParameters(baseline.configuration, null)
                parameters = setupParameters(change.setup, password).filter { (key, value) -> key != "protocol" && (key == "password" || original[key] != value) } +
                    ("id" to baseline.profile.id)
                method = "set"
            }
            is FileVFSChange.CreateCloud -> {
                requireSecure(); validateAuthorization(authorization, change.identity)
                if (before.any { it.alias == change.identity.alias || it.protocolId == change.identity.protocolId && it.account == change.identity.account }) throw vfsChanged()
                parameters = cloudParameters(authorization!!) + mapOf("protocol" to change.identity.protocolId, "alias" to change.identity.alias, "hostname" to "")
                method = "create"
            }
            is FileVFSChange.Reauthorize -> {
                requireSecure(); requireBaseline(before, change.baseline)
                validateAuthorization(authorization, FileVFSCloudIdentity(change.baseline.protocolId, change.baseline.alias, change.baseline.account ?: throw vfsChanged()))
                parameters = cloudParameters(authorization!!) + ("id" to change.baseline.id); method = "set"
            }
            is FileVFSChange.Connect -> {
                requireBaseline(before, change.baseline)
                if (change.baseline.state != FileVFSConnectionState.DISCONNECTED) throw vfsChanged()
                parameters = mapOf("profile_id" to change.baseline.id); method = "create"
            }
            is FileVFSChange.Disconnect -> {
                requireBaseline(before, change.baseline)
                if (change.baseline.state != FileVFSConnectionState.CONNECTED) throw vfsChanged()
                parameters = mapOf("id" to change.baseline.id); method = "delete"
            }
            is FileVFSChange.RemoveSaved -> {
                requireBaseline(before, change.baseline)
                if (change.baseline.state != FileVFSConnectionState.DISCONNECTED) throw vfsChanged()
                parameters = mapOf("id" to change.baseline.id); method = "delete"
            }
        }
        requireWrite()
        val fresh = reader.profiles()
        if (fresh.size != before.size || before.any { previous -> fresh.none { it.sameSnapshot(previous) } }) throw vfsChanged()
        currentCoroutineContext().ensureActive(); requireOwner()
        val removing = change is FileVFSChange.RemoveSaved
        var record = FileVFSPending(owner = owner() ?: throw workspaceStorageFailure(), change = change, originalIds = before.map { it.id }.toSet(),
            connection = if (removing) FileVFSStep.UNSENT else FileVFSStep.SUBMITTED,
            profile = if (removing) FileVFSStep.SUBMITTED else FileVFSStep.UNSENT)
        persist { it.begin(record) }
        val firstApi = if (removing) VFS_PROFILE_API else VFS_CONNECTION_API
        val firstParameters = if (!removing && method != "delete") parameters + ("force" to "false") else parameters
        try {
            requireCurrentWrite(); call(firstApi, method, firstParameters, 1)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            if (error is DsmFailure && definiteRejection(error)) {
                persist { it.replace(record, null) }
                return FileVFSOutcome(FileVFSOutcomeStatus.REJECTED, failure = identityFailure(error))
            }
            return reviewCore(record)
        }
        val acknowledged = if (removing) record.copy(profile = FileVFSStep.ACKNOWLEDGED) else record.copy(connection = FileVFSStep.ACKNOWLEDGED)
        persist { it.replace(record, acknowledged) }; record = acknowledged
        if (change.writesBoth) {
            currentCoroutineContext().ensureActive(); requireCurrentWrite()
            val submitted = record.copy(profile = FileVFSStep.SUBMITTED)
            persist { it.replace(record, submitted) }; record = submitted
            try {
                requireCurrentWrite(); call(VFS_PROFILE_API, method, parameters, 1)
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (error is DsmFailure && definiteRejection(error)) {
                    val rejected = record.copy(profile = FileVFSStep.REJECTED)
                    persist { it.replace(record, rejected) }; record = rejected
                }
                return reviewCore(record)
            }
            val saved = record.copy(profile = FileVFSStep.ACKNOWLEDGED)
            persist { it.replace(record, saved) }; record = saved
        }
        return reviewCore(record)
    }

    suspend fun review(id: String): FileVFSOutcome = locked {
        val record = pending().singleOrNull { it.id == id } ?: throw vfsChanged()
        reviewCore(record)
    }
    private suspend fun reviewCore(record: FileVFSPending): FileVFSOutcome {
        val completed = try {
            if (pending().singleOrNull() != record) throw vfsChanged()
            val profiles = reader.profiles()
            when (val change = record.change) {
                is FileVFSChange.Create -> {
                    val matches = profiles.filter { it.id !in record.originalIds && it.matches(change.setup) && it.state == FileVFSConnectionState.CONNECTED }
                    bothAcknowledged(record) && matches.size == 1 && reader.detail(matches.single()).configuration == change.setup
                }
                is FileVFSChange.Update -> {
                    val profile = profiles.singleOrNull { it.id == change.baseline.profile.id && it.matches(change.setup) && it.state == FileVFSConnectionState.CONNECTED }
                    bothAcknowledged(record) && profile != null && reader.detail(profile).configuration == change.setup
                }
                is FileVFSChange.CreateCloud -> bothAcknowledged(record) && profiles.count { it.id !in record.originalIds &&
                    it.protocolId == change.identity.protocolId && it.account == change.identity.account && it.alias == change.identity.alias && it.state == FileVFSConnectionState.CONNECTED } == 1
                is FileVFSChange.Reauthorize -> bothAcknowledged(record) && profiles.any { it.sameIdentity(change.baseline) && it.state == FileVFSConnectionState.CONNECTED }
                is FileVFSChange.Connect -> profiles.any { it.sameIdentity(change.baseline) && it.state == FileVFSConnectionState.CONNECTED }
                is FileVFSChange.Disconnect -> profiles.any { it.sameIdentity(change.baseline) && it.state == FileVFSConnectionState.DISCONNECTED }
                is FileVFSChange.RemoveSaved -> profiles.none { it.id == change.baseline.id }
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            false
        }
        if (completed) persist { it.replace(record, null) }
        return FileVFSOutcome(if (completed) FileVFSOutcomeStatus.COMPLETED else FileVFSOutcomeStatus.UNKNOWN, if (completed) null else record)
    }
    private suspend fun resolve(setup: FileVFSConfiguration, editing: String? = null): FileVFSConfiguration {
        val options = reader.protocols()
        return runCatching { setup.resolved(options, editing) }.getOrElse { throw vfsOptionsInvalid() }
    }
    private fun requireBaseline(profiles: List<FileVFSProfile>, profile: FileVFSProfile) {
        if (owner()?.hasSameIdentity(profile.owner) != true || profiles.none { it.sameSnapshot(profile) }) throw vfsChanged()
    }
    private suspend fun requireWrite() { requireOwner(); refreshAccess(); requireCurrentWrite() }
    private fun requireCurrentWrite() {
        requireOwner()
        if (!supportsWrite()) throw vfsUnavailable()
        if (!access().granted || !access().administrator) throw DsmFailure(null, "Connection management is unavailable", "Ask an administrator for access.", kind = DsmErrorKind.PERMISSION_DENIED)
    }
    private fun requireSecure() {
        requireOwner()
        if (!secureTransport()) throw DsmFailure(null, "A secure NAS connection is required", "Connect to the NAS using HTTPS and try again.", kind = DsmErrorKind.INSECURE_ADDRESS)
    }
    private fun requireCleartext(setup: FileVFSConfiguration, accepted: Boolean) { if (setup.usesCleartext && !accepted) throw vfsOptionsInvalid() }
    private suspend fun validateAuthorization(value: FileVFSCloudAuthorization?, identity: FileVFSCloudIdentity) {
        if (value == null || value.owner != owner() || value.protocolId != identity.protocolId || value.account != identity.account ||
            value.accessToken.isEmpty() || identity.account.isEmpty() || identity.alias.isBlank() || identity.alias.length > 255 ||
            value.expiresIn?.let { it < 0 } == true || !reader.protocols().any { it.id == identity.protocolId && it.supportsCloudAuthorization }) throw vfsChanged()
    }
    private suspend fun persist(block: (FileVFSRecoveryStore) -> Unit) = withContext(Dispatchers.IO) {
        requireOwner(); block(store ?: throw workspaceStorageFailure())
    }
    private suspend fun <T> locked(block: suspend () -> T): T {
        requireOwner()
        if (!mutex.tryLock()) throw vfsPending()
        try { return block() } finally { mutex.unlock() }
    }
    private fun bothAcknowledged(record: FileVFSPending) = record.connection == FileVFSStep.ACKNOWLEDGED && record.profile == FileVFSStep.ACKNOWLEDGED
    private fun definiteRejection(failure: DsmFailure) = failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.AUTHENTICATION_FAILED,
        DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED) ||
        failure.kind == DsmErrorKind.REQUEST_FAILED && (failure.code ?: 0) > 0
    private fun identityFailure(failure: DsmFailure) = if (failure.code in setOf(2107, 2112, 2115))
        DsmFailure(failure.code, "The remote server requires attention", "Check its identity or sign in again before reconnecting.", kind = DsmErrorKind.FILE_VFS_IDENTITY_WARNING) else failure
    private fun setupParameters(value: FileVFSConfiguration, password: String?) = buildMap {
        put("protocol", value.protocolId); put("hostname", value.hostname); put("port", value.port.toString()); put("alias", value.alias)
        put("account", value.account); put("codepage", value.codepage); put("uri_path", value.folder); put("max_connection", if (value.usesOneConnection) "1" else "0")
        if (password != null) put("password", password)
    }
    private fun cloudParameters(value: FileVFSCloudAuthorization) = buildMap {
        put("account", value.account); put("access_token", value.accessToken)
        value.clientId?.let { put("client_id", it) }; value.refreshToken?.let { put("refresh_token", it) }; value.expiresIn?.let { put("expires_in", it.toString()) }
    }
}

internal fun vfsUnavailable() = DsmFailure(null, "Connection management is unavailable", "Check File Station and try again.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
internal fun vfsOptionsInvalid() = DsmFailure(null, "The connection settings are invalid", "Check the address, port, and connection options.", kind = DsmErrorKind.FILE_VFS_OPTIONS)
internal fun vfsAuthorizationExpired() = DsmFailure(null, "The sign-in attempt expired", "Start signing in again.", kind = DsmErrorKind.FILE_VFS_AUTHORIZATION_EXPIRED)
