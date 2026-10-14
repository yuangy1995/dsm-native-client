package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import javax.net.ssl.SSLException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** 只保留已有模块的白名单授权，绝不保存原始 Session 或 UserSettings。 */
internal enum class DesktopApplication(val key: String, val module: Module) {
    FILES("SYNO.SDS.App.FileStation3.Instance", Module.FILES),
    CHAT("SYNO.SDS.Chat.Application", Module.CHAT),
    DOWNLOADS("SYNO.SDS.DownloadStation.Application", Module.DOWNLOADS),
    CONTAINERS("SYNO.SDS.ContainerManager.Application", Module.CONTAINERS),
    VIRTUAL_MACHINES("SYNO.SDS.Virtualization.Application", Module.VIRTUAL_MACHINES),
    NAS_SETTINGS("SYNO.SDS.AdminCenter.Application", Module.NAS_SETTINGS),
}

internal data class DesktopAppPrivileges(
    val applications: Map<DesktopApplication, Boolean>,
    val isAdministrator: Boolean,
) {
    companion object {
        fun decode(data: JsonObject): DesktopAppPrivileges {
            fun boolean(value: kotlinx.serialization.json.JsonElement?): Boolean =
                (value as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
                    ?: throw invalidPrivilegeSummary()
            val session = when (val value = data["Session"]) {
                null, JsonNull -> null
                is JsonObject -> value
                else -> throw invalidPrivilegeSummary()
            }
            fun role(key: String): Boolean? = session?.get(key)
                ?.takeUnless { it is JsonNull }?.let(::boolean)
            // 未登录空摘要是该接口读取失败，不能直接宣布整个 FileStation 会话过期。
            if (role("isLogined") == false) throw invalidPrivilegeSummary()
            val administrator = role("is_admin") == true
            val raw = data["AppPrivilege"] as? JsonObject ?: throw invalidPrivilegeSummary()
            return DesktopAppPrivileges(DesktopApplication.entries.mapNotNull { application ->
                if (!raw.containsKey(application.key)) null else application to boolean(raw[application.key])
            }.toMap(), administrator)
        }
    }
}

internal data class WorkspaceAccessSnapshot(
    val availability: List<ModuleAvailability>,
    val lookupFailed: Boolean = false,
    val sessionConfirmed: Boolean = false,
    val recoveryFailure: Throwable? = null,
    val filePermissionAccess: FilePermissionAccess = FilePermissionAccess(),
) {
    companion object {
        fun unread() = WorkspaceAccessSnapshot(Module.entries.map { module ->
            moduleAvailability(module, if (module.isLocal()) ModuleAccessState.ALLOWED else ModuleAccessState.UNREAD)
        })
        fun failed(error: Throwable) = WorkspaceAccessSnapshot(Module.entries.map { module ->
            moduleAvailability(module, when {
                module.isLocal() -> ModuleAccessState.ALLOWED
                isExpiredWorkspaceSession(error) -> ModuleAccessState.AUTHENTICATION_REQUIRED
                else -> ModuleAccessState.FAILED
            })
        }, lookupFailed = true, recoveryFailure = error)
    }
}

/** 只执行摘要、最小文件会话读取和 Photos 自身授权；不轮询其他套件业务列表。 */
internal class WorkspaceAccessReader(
    private val capabilities: Map<String, ApiCapability>,
    private val readPrivileges: suspend () -> DesktopAppPrivileges,
    private val readFileSession: suspend () -> Unit,
    private val readPhotoAccess: suspend () -> Unit,
) {
    suspend fun read(): WorkspaceAccessSnapshot {
        val values = WorkspaceAccessSnapshot.unread().availability.associate { it.module to it.access }.toMutableMap()
        var failed = false
        var confirmed = false
        var recoveryFailure: Throwable? = null
        var filePermissionAccess = FilePermissionAccess()
        try {
            val privileges = readPrivileges()
            filePermissionAccess = FilePermissionAccess(privileges.applications[DesktopApplication.FILES] == true,
                privileges.isAdministrator)
            confirmed = true
            DesktopApplication.entries.forEach { application ->
                val granted = if (application in setOf(DesktopApplication.NAS_SETTINGS, DesktopApplication.CONTAINERS)) {
                    privileges.isAdministrator && privileges.applications[application] != false
                } else privileges.applications[application] == true
                values[application.module] = when {
                    !granted -> ModuleAccessState.DENIED
                    !supportsModule(application.module) -> ModuleAccessState.UNSUPPORTED
                    else -> ModuleAccessState.ALLOWED
                }
            }
        } catch (error: Exception) {
            stopForSecurityOrCancellation(error)
            failed = true
            recoveryFailure = error
            DesktopApplication.entries.forEach { values[it.module] = ModuleAccessState.FAILED }
            if (!supportsModule(Module.FILES)) values[Module.FILES] = ModuleAccessState.UNSUPPORTED
            else try {
                readFileSession()
                confirmed = true
                values[Module.FILES] = ModuleAccessState.ALLOWED
            } catch (fileError: Exception) {
                stopForSecurityOrCancellation(fileError)
                recoveryFailure = fileError
                values[Module.FILES] = accessFailure(fileError)
            }
        }
        currentCoroutineContext().ensureActive()
        if (!supportsPhotoAccess(capabilities)) values[Module.PHOTOS] = ModuleAccessState.UNSUPPORTED
        else try {
            readPhotoAccess()
            confirmed = true
            values[Module.PHOTOS] = ModuleAccessState.ALLOWED
        } catch (error: Exception) {
            stopForSecurityOrCancellation(error)
            values[Module.PHOTOS] = accessFailure(error)
            if (values[Module.PHOTOS] == ModuleAccessState.FAILED) failed = true
            if (!confirmed) recoveryFailure = error
        }
        currentCoroutineContext().ensureActive()
        return WorkspaceAccessSnapshot(values.map { (module, state) -> moduleAvailability(module, state) },
            failed, confirmed, recoveryFailure, filePermissionAccess)
    }

    private fun supportsModule(module: Module): Boolean {
        fun has(vararg names: String) = names.any { name ->
            capabilities[name]?.let { it.minVersion > 0 && it.maxVersion >= it.minVersion } == true
        }
        return when (module) {
            Module.FILES -> has("SYNO.FileStation.List")
            Module.CHAT -> has("SYNO.Chat.Channel") && has("SYNO.Chat.User")
            Module.DOWNLOADS -> has("SYNO.DownloadStation.Task", "SYNO.DownloadStation2.Task")
            Module.CONTAINERS -> has("SYNO.Docker.Container")
            Module.VIRTUAL_MACHINES -> has("SYNO.Virtualization.API.Guest", "SYNO.Virtualization.Guest")
            Module.NAS_SETTINGS -> has("SYNO.Core.System")
            else -> false
        }
    }
}

internal fun supportsPhotoAccess(capabilities: Map<String, ApiCapability>): Boolean =
    listOf("SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace")
        .all { name -> capabilities[name]?.let { 1 in it.minVersion..it.maxVersion && it.requestFormat.equals("JSON", ignoreCase = true) } == true }

internal fun isExpiredWorkspaceSession(error: Throwable): Boolean = error is DsmFailure &&
    error.kind in setOf(DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.SAVED_SESSION_EXPIRED)

private fun stopForSecurityOrCancellation(error: Exception) {
    if (error is CancellationException || error is SSLException ||
        error is DsmFailure && (error.isAuthenticationFailure ||
            error.kind in setOf(DsmErrorKind.INSECURE_ADDRESS, DsmErrorKind.TLS_UNTRUSTED, DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED, DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH))) throw error
}

private fun accessFailure(error: Throwable): ModuleAccessState = when {
    (error as? SynologyPhotoFailure)?.kind == SynologyPhotoFailureKind.PERMISSION -> ModuleAccessState.DENIED
    (error as? SynologyPhotoFailure)?.kind == SynologyPhotoFailureKind.UNAVAILABLE -> ModuleAccessState.UNSUPPORTED
    (error as? DsmFailure)?.kind == DsmErrorKind.PERMISSION_DENIED -> ModuleAccessState.DENIED
    (error as? DsmFailure)?.kind in setOf(DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED) -> ModuleAccessState.UNSUPPORTED
    else -> ModuleAccessState.FAILED
}

private fun Module.isLocal(): Boolean = this == Module.SETTINGS || this == Module.TRANSFERS

private fun moduleAvailability(module: Module, state: ModuleAccessState) = ModuleAvailability(
    module, state == ModuleAccessState.ALLOWED, when (state) {
        ModuleAccessState.ALLOWED -> null
        ModuleAccessState.DENIED -> ModuleUnavailableReason.ACCESS_DENIED
        ModuleAccessState.UNREAD -> ModuleUnavailableReason.ACCESS_UNREAD
        ModuleAccessState.FAILED -> ModuleUnavailableReason.ACCESS_FAILED
        ModuleAccessState.AUTHENTICATION_REQUIRED -> ModuleUnavailableReason.AUTHENTICATION_REQUIRED
        ModuleAccessState.UNSUPPORTED -> ModuleUnavailableReason.FEATURE_UNSUPPORTED
    }, state,
)

private fun invalidPrivilegeSummary() = DsmFailure(null, "Application access could not be read",
    "Refresh to try again.", kind = DsmErrorKind.INVALID_RESPONSE)
