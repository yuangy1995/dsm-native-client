package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.isExpiredWorkspaceSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.ConnectionStatus
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import java.util.UUID

/** 单连接的登录、验证码与恢复任务；宿主选择不会把尝试转交给另一账号。 */
internal class WorkspaceLoginModel(
    private val scope: CoroutineScope,
    private val _login: MutableStateFlow<LoginState>,
    private val store: SecureProfileStore,
    private val connections: WorkspaceConnectionService,
    private val isSwitching: () -> Boolean,
    private val activeProfileId: () -> String?,
    private val onSelectionChanged: () -> Unit,
    private val onConnected: (NasProfile, DsmRepository) -> Unit,
) {
    private val loginAttempt = LoginAttemptOwner()

    fun restoreAutomatically() {
        val initial = _login.value
        val profile = initial.profiles.firstOrNull { it.id == initial.selectedProfileId } ?: return
        if (initial.autoLoginEnabled && initial.savedPassword.isNotEmpty()) restore(profile, initial.savedPassword)
    }

    fun selectProfile(profile: NasProfile) {
        if (isSwitching()) return
        if (activeProfileId() != profile.id) onSelectionChanged()
        store.setLastProfileId(profile.id)
        val storedPassword = store.password(profile.id).orEmpty()
        _login.update {
            it.copy(
                selectedProfileId = profile.id,
                savedPassword = storedPassword,
                rememberPassword = storedPassword.isNotEmpty(),
                autoLoginEnabled = storedPassword.isNotEmpty() &&
                    store.isAutoLoginEnabled(profile.id),
                error = null,
                needsOtp = false,
            )
        }
    }

    fun newProfile() {
        if (isSwitching()) return
        onSelectionChanged()
        store.setLastProfileId(null)
        _login.update {
            it.copy(
                selectedProfileId = null,
                savedPassword = "",
                rememberPassword = false,
                autoLoginEnabled = false,
                error = null,
                needsOtp = false,
            )
        }
    }

    fun clearAutofill() {
        if (!_login.value.isConnecting) _login.update { it.copy(savedPassword = "", error = null, needsOtp = false) }
    }

    fun connect(
        profileId: String?,
        name: String,
        address: String,
        portText: String,
        username: String,
        password: String,
        otp: String,
        rememberPassword: Boolean,
        autoLoginEnabled: Boolean,
    ) {
        if (isSwitching()) return
        if (_login.value.isConnecting) return
        val existing = profileId?.let { id -> _login.value.profiles.firstOrNull { it.id == id } }
        val profile = NasProfile(
            id = existing?.id ?: UUID.randomUUID().toString(),
            name = name.trim().ifBlank { "NAS" },
            address = address.trim(),
            username = username.trim(),
            port = portText.toIntOrNull(),
            rememberSession = rememberPassword,
        )
        if (profile.address.isBlank() || profile.username.isBlank() || password.isBlank()) {
            _login.update {
                it.copy(
                    error = DsmFailure(
                        null,
                        "NAS address, account, and password are required",
                        "Complete the sign-in information and connect again.",
                        kind = DsmErrorKind.MISSING_LOGIN_FIELDS,
                    )
                )
            }
            return
        }
        loginAttempt.launch(scope) {
            _login.update {
                it.copy(
                    isConnecting = true,
                    connectionStatus = ConnectionStatus.PREPARING,
                    error = null,
                )
            }
            suspendRunCatching {
                connections.connect(profile, existing, password, otp, rememberPassword, autoLoginEnabled) { status ->
                    if (isActive) _login.update { it.copy(connectionStatus = status) }
                }
            }.onSuccess { repo ->
                currentCoroutineContext().ensureActive()
                _login.value = LoginState(
                    profiles = store.profiles(),
                    selectedProfileId = profile.id,
                    savedPassword = if (rememberPassword) password else "",
                    rememberPassword = rememberPassword,
                    autoLoginEnabled = rememberPassword && autoLoginEnabled,
                )
                onConnected(profile, repo)
            }.onFailure { error -> currentCoroutineContext().ensureActive()
                val failure = error.asDsmFailure()
                _login.update {
                    it.copy(
                        isConnecting = false,
                        connectionStatus = null,
                        error = failure,
                        needsOtp = failure.kind in setOf(DsmErrorKind.OTP_REQUIRED, DsmErrorKind.OTP_INVALID),
                    )
                }
            }
        }
    }

    internal fun cancelLogin(): Boolean {
        if (isSwitching() || activeProfileId() != null || !loginAttempt.cancel()) return false
        _login.update { it.copy(isConnecting = false, connectionStatus = null, error = null) }
        return true
    }

    fun restore(profile: NasProfile, fallbackPassword: String? = null) {
        if (isSwitching()) return
        store.setLastProfileId(profile.id)
        val session = store.session(profile.id)
        if (session == null) {
            if (!fallbackPassword.isNullOrEmpty()) {
                connect(
                    profile.id,
                    profile.name,
                    profile.address,
                    profile.port?.toString().orEmpty(),
                    profile.username,
                    fallbackPassword,
                    "",
                    rememberPassword = true,
                    autoLoginEnabled = store.isAutoLoginEnabled(profile.id),
                )
            } else {
                selectProfile(profile)
                _login.update {
                    it.copy(
                        error = DsmFailure(
                            null,
                            "No saved session is available",
                            "Enter the password and connect again.",
                            true,
                            DsmErrorKind.NO_SAVED_SESSION,
                        )
                    )
                }
            }
            return
        }
        if (_login.value.isConnecting) return
        loginAttempt.launch(scope) {
            _login.update {
                it.copy(
                    isConnecting = true,
                    connectionStatus = ConnectionStatus.RESTORING_SESSION,
                    error = null,
                )
            }
            suspendRunCatching {
                connections.restore(profile, session) { status ->
                    if (isActive) _login.update { it.copy(connectionStatus = status) }
                }
            }.onSuccess { repo ->
                currentCoroutineContext().ensureActive()
                _login.update { it.copy(isConnecting = false, connectionStatus = null) }
                onConnected(profile, repo)
            }.onFailure { error -> currentCoroutineContext().ensureActive()
                if (!isExpiredWorkspaceSession(error)) {
                    _login.update { it.copy(isConnecting = false, connectionStatus = null, error = error.asDsmFailure()) }
                    return@onFailure
                }
                if (!store.clearSessionIfCurrent(profile.id, session)) {
                    _login.update { it.copy(isConnecting = false, connectionStatus = null,
                        error = io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceChangedFailure()) }
                    return@onFailure
                }
                val savedPassword = fallbackPassword ?: store.password(profile.id)
                _login.update { it.copy(isConnecting = false, connectionStatus = null) }
                if (!savedPassword.isNullOrEmpty() && store.isAutoLoginEnabled(profile.id)) {
                    connect(
                        profile.id,
                        profile.name,
                        profile.address,
                        profile.port?.toString().orEmpty(),
                        profile.username,
                        savedPassword,
                        "",
                        rememberPassword = true,
                        autoLoginEnabled = true,
                    )
                } else {
                    selectProfile(profile)
                    _login.update {
                        it.copy(
                            error = DsmFailure(
                                null,
                                "The saved session expired",
                                "The saved password is filled in. Connect again.",
                                true,
                                DsmErrorKind.SAVED_SESSION_EXPIRED,
                            ),
                        )
                    }
                }
            }
        }
    }

}

internal fun initialWorkspaceLoginState(store: SecureProfileStore, selectedProfileId: String?, selectLastProfile: Boolean): LoginState {
    val profiles = store.profiles()
    val profile = if (selectLastProfile) profiles.firstOrNull { it.id == store.lastProfileId() }
        ?: profiles.firstOrNull() else profiles.firstOrNull { it.id == selectedProfileId }
    val password = profile?.let { store.password(it.id) }.orEmpty()
    return LoginState(profiles = profiles, selectedProfileId = profile?.id, savedPassword = password,
        rememberPassword = password.isNotEmpty(), autoLoginEnabled = password.isNotEmpty() &&
            profile?.let { store.isAutoLoginEnabled(it.id) } == true)
}
