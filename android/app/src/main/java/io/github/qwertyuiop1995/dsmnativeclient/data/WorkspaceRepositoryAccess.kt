package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/** 仓储请求统一经过身份与模块门禁；只读摘要不越过账号身份，业务不能绕过模块授权。 */
internal class WorkspaceRepositoryAccess(
    profile: NasProfile, session: DsmSession, api: DsmApiClient,
    capabilities: Map<String, ApiCapability>, reader: WorkspaceAccessReader?,
) {
    private val profileId = profile.id
    var owner: WorkspaceOwner? = null
        private set
    private var validate: () -> Unit = {}
    private val ownedApi: DsmApiClient = api.authorized({ requireCurrentOwner() })
    private val access = WorkspaceAccessController(profile, session, ownedApi, capabilities, reader)
    private val failureEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val failures: Flow<Unit> get() = failureEvents
    val transport: DsmApiClient = ownedApi.authorized(access::requireApi) { failureEvents.tryEmit(Unit); Unit }
    val readFailed: Boolean get() = access.snapshot.lookupFailed
    val filePermissionAccess get() = access.snapshot.filePermissionAccess

    fun bindOwner(value: WorkspaceOwner, validation: () -> Unit) {
        check(value.profileId == profileId && (owner == null || owner == value))
        validation()
        owner = value
        validate = validation
    }

    fun requireCurrentOwner() {
        try { validate() } catch (error: Exception) { access.invalidate(); throw error }
    }

    fun availability(): List<io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability> {
        runCatching { requireCurrentOwner() }
        return access.snapshot.availability
    }

    fun invalidate() = access.invalidate()
    suspend fun refresh(requireSessionConfirmation: Boolean) {
        requireCurrentOwner()
        access.refresh(requireSessionConfirmation)
        requireCurrentOwner()
    }
}
