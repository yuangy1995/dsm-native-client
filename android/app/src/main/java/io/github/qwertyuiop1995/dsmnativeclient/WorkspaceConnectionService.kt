package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmConnectionResolver
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 登录结果只安装到发起连接的身份；任务与界面共用该归属，失败不改写旧配置。 */
internal class WorkspaceConnectionService(
    private val store: SecureProfileStore,
    private val api: DsmApiClient,
    private val resolver: DsmConnectionResolver,
    private val requestLocalNetworkAccess: suspend () -> Boolean = { false },
) {
    suspend fun connect(
        profile: NasProfile,
        previousProfile: NasProfile?,
        password: String,
        otp: String,
        rememberPassword: Boolean,
        autoLogin: Boolean,
        status: (ConnectionStatus) -> Unit,
    ): DsmRepository {
        val attempt = store.connectionAttempt(profile.id)
        if (attempt.previousIdentityFingerprint != previousProfile?.workspaceIdentityFingerprint()) {
            throw workspaceChangedFailure()
        }
        val previousSession = store.session(profile.id).takeIf {
            attempt.previousIdentityFingerprint == profile.workspaceIdentityFingerprint()
        }
        val discovered = discover(profile, status)
        currentCoroutineContext().ensureActive()
        status(ConnectionStatus.AUTHENTICATING)
        val session = api.login(discovered.profile, password, otp.ifBlank { null }, deviceId = previousSession?.deviceId)
        val repo = DsmRepository(discovered.profile, session, api, discovered.capabilities)
        repo.refreshAccess()
        currentCoroutineContext().ensureActive()
        val owner = store.commitConnection(attempt, profile, session, password.takeIf { rememberPassword }, autoLogin)
        repo.bindOwner(owner, store.lease(owner)::requireCurrent)
        return repo
    }

    suspend fun restore(profile: NasProfile, session: DsmSession, makeLastProfile: Boolean = true, status: (ConnectionStatus) -> Unit): DsmRepository {
        val attempt = store.connectionAttempt(profile.id)
        if (attempt.previousIdentityFingerprint != profile.workspaceIdentityFingerprint() ||
            store.session(profile.id) != session) throw workspaceChangedFailure()
        val password = store.password(profile.id)
        val autoLogin = store.isAutoLoginEnabled(profile.id)
        val discovered = discover(profile, status)
        currentCoroutineContext().ensureActive()
        val repo = DsmRepository(discovered.profile, session, api, discovered.capabilities)
        repo.refreshAccess(requireSessionConfirmation = true)
        currentCoroutineContext().ensureActive()
        val owner = store.commitConnection(attempt, profile, session, password, autoLogin,
            persistSession = true, makeLastProfile = makeLastProfile)
        repo.bindOwner(owner, store.lease(owner)::requireCurrent)
        return repo
    }

    private suspend fun discover(profile: NasProfile, status: (ConnectionStatus) -> Unit) = try {
        resolver.discover(profile, status)
    } catch (error: io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure) {
        if (error.kind != io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.LOCAL_NETWORK_PERMISSION_REQUIRED ||
            !requestLocalNetworkAccess()) throw error
        currentCoroutineContext().ensureActive()
        // 仅重新执行尚未提交凭据的只读发现，绝不自动重发登录或业务写操作。
        resolver.discover(profile, status)
    }
}
