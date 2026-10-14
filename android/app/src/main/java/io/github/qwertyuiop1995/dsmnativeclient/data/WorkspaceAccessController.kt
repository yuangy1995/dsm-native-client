package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileStationRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileStationRepositoryGateway
import kotlinx.serialization.json.JsonObject
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** 一个 Repository 对应一个账号快照；独立 Photos 读取不重置已打开图库的对象权限。 */
internal class WorkspaceAccessController(
    profile: NasProfile,
    session: DsmSession,
    api: DsmApiClient,
    capabilities: Map<String, ApiCapability>,
    accessReader: WorkspaceAccessReader? = null,
) {
    @Volatile var snapshot = WorkspaceAccessSnapshot.unread()
        private set
    private val refreshLock = Mutex()
    private val invalidated = AtomicBoolean(false)
    private val revision = AtomicLong(0)
    private var readFailure: Exception? = null
    private val requestBuilder = DsmRepositoryRequestBuilder(profile, session, api, DsmRepositoryCapabilityResolver(capabilities))
    private val sessionFiles = DsmFileStationRepository(object : DsmFileStationRepositoryGateway {
        override suspend fun call(apiName: String, method: String, parameters: Map<String, String>): JsonObject =
            requestBuilder.call(apiName, method, parameters)
        override fun jsonStrings(values: List<String>): String = requestBuilder.jsonStrings(values)
    })
    private val reader = accessReader ?: WorkspaceAccessReader(capabilities,
        readPrivileges = {
            val capability = capabilities["SYNO.Core.Desktop.Initdata"]
                ?.takeIf { 1 in it.minVersion..it.maxVersion }
                ?: throw DsmFailure(103, "Feature unsupported", "Refresh to try again.",
                    kind = DsmErrorKind.FEATURE_UNSUPPORTED)
            DesktopAppPrivileges.decode(api.get(profile, session, capability.copy(maxVersion = 1),
                "get_user_service", mapOf("launch_app" to "null")))
        },
        readFileSession = { sessionFiles.listShares(offset = 0, limit = 1); Unit },
        readPhotoAccess = { SynologyPhotosRepository(profile, session, api, capabilities).access(); Unit },
    )

    fun requireApi(apiName: String) {
        val module = when {
            apiName.startsWith("SYNO.FileStation.") || apiName == "SYNO.Core.ACL" -> Module.FILES
            apiName.startsWith("SYNO.Foto.") || apiName.startsWith("SYNO.FotoTeam.") -> Module.PHOTOS
            apiName.startsWith("SYNO.Chat.") -> Module.CHAT
            apiName.startsWith("SYNO.DownloadStation.") || apiName.startsWith("SYNO.DownloadStation2.") -> Module.DOWNLOADS
            apiName.startsWith("SYNO.Docker.") -> Module.CONTAINERS
            apiName.startsWith("SYNO.Virtualization.") -> Module.VIRTUAL_MACHINES
            apiName.startsWith("SYNO.Core.") || apiName.startsWith("SYNO.Storage.") || apiName.startsWith("SYNO.LogCenter.") -> Module.NAS_SETTINGS
            else -> throw DsmFailure(null, "Feature unsupported", "Refresh to try again.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        }
        val access = snapshot.availability.single { it.module == module }.access
        if (access == ModuleAccessState.ALLOWED) return
        val kind = when (access) {
            ModuleAccessState.DENIED -> DsmErrorKind.PERMISSION_DENIED
            ModuleAccessState.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
            ModuleAccessState.AUTHENTICATION_REQUIRED -> DsmErrorKind.SESSION_EXPIRED
            else -> DsmErrorKind.REQUEST_FAILED
        }
        throw DsmFailure(null, "This feature is unavailable", "Refresh or sign in again.",
            isAuthenticationFailure = kind == DsmErrorKind.SESSION_EXPIRED, kind = kind)
    }

    fun invalidate() {
        invalidated.set(true)
        snapshot = WorkspaceAccessSnapshot.unread()
    }

    suspend fun refresh(requireSessionConfirmation: Boolean) {
        val startedAt = revision.get()
        refreshLock.withLock {
            if (invalidated.get()) throw CancellationException()
            // 等待同一正在读取的请求时直接复用结果，不为前台恢复与手动刷新重复请求。
            if (startedAt == revision.get()) {
                val next = try { reader.read() } catch (error: Exception) {
                    if (error !is CancellationException) {
                        snapshot = WorkspaceAccessSnapshot.failed(error)
                        readFailure = error
                        revision.incrementAndGet()
                    }
                    throw error
                }
                if (invalidated.get()) throw CancellationException()
                snapshot = next
                readFailure = null
                revision.incrementAndGet()
            }
            readFailure?.let { throw it }
            if (requireSessionConfirmation && !snapshot.sessionConfirmed) throw snapshot.recoveryFailure
                ?: DsmFailure(null, "Could not restore this connection", "Check the connection and try again.",
                    kind = DsmErrorKind.CONNECTION_FAILED)
        }
    }
}
