package io.github.qwertyuiop1995.dsmnativeclient.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceRouteRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceTarget
import io.github.qwertyuiop1995.dsmnativeclient.domain.OPAQUE_WORKSPACE_ROUTE_SCHEMA_VERSION
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.Base64

/**
 * 保存 NAS 配置，以及受 Android Keystore 保护的会话和用户主动选择保存的密码。
 */
class SecureProfileStore internal constructor(
    private val preferences: SharedPreferences,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    constructor(context: Context, json: Json = Json { ignoreUnknownKeys = true }) : this(
        EncryptedSharedPreferences.create(context, "lanstash_secure_profiles",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM), json)

    fun profiles(): List<NasProfile> {
        val value = preferences.getString(KEY_PROFILES, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(NasProfile.serializer()), value)
        }.getOrDefault(emptyList())
    }

    fun saveProfile(profile: NasProfile) = synchronized(workspaceStoreLock) {
        val previous = profiles().firstOrNull { it.id == profile.id }
        val profiles = profiles().filterNot { it.id == profile.id } + profile
        val editor = preferences.edit()
            .putString(KEY_PROFILES, json.encodeToString(ListSerializer(NasProfile.serializer()), profiles))
        identityRecord(profile.id)?.takeIf { !it.hasIdentity(profile) }?.let {
            editor.putString(identityKey(profile.id), json.encodeToString(it.invalidated()))
                .remove(sessionKey(profile.id)).remove(passwordKey(profile.id))
                .putBoolean(autoLoginKey(profile.id), false)
        }
        if (previous != null && previous.workspaceIdentityFingerprint() != profile.workspaceIdentityFingerprint()) {
            editor.remove(recentDirectoriesKey(profile.id)).remove(workspaceUiStateKey(profile.id))
            opaqueWorkspaceRouteKeys(profile.id).forEach(editor::remove)
        }
        editor.apply()
        notifyWorkspaceIdentityChanged()
    }

    internal fun renameProfile(expected: NasProfile, name: String): Boolean = synchronized(workspaceStoreLock) {
        val current = profiles()
        val profile = current.firstOrNull { it.id == expected.id } ?: return@synchronized false
        if (name.isBlank() || profile.workspaceIdentityFingerprint() != expected.workspaceIdentityFingerprint()) return@synchronized false
        val saved = preferences.edit().putString(KEY_PROFILES, json.encodeToString(ListSerializer(NasProfile.serializer()),
            current.map { if (it.id == profile.id) it.copy(name = name.trim()) else it })).commit()
        if (saved) notifyWorkspaceIdentityChanged()
        saved
    }

    @Synchronized
    fun removeProfile(profileId: String) = synchronized(workspaceStoreLock) {
        val profiles = profiles().filterNot { it.id == profileId }
        val editor = preferences.edit()
            .putString(KEY_PROFILES, json.encodeToString(ListSerializer(NasProfile.serializer()), profiles))
            .remove(sessionKey(profileId))
            .remove(passwordKey(profileId))
            .remove(autoLoginKey(profileId))
            .remove(recentDirectoriesKey(profileId))
            .remove(workspaceUiStateKey(profileId))
        opaqueWorkspaceRouteKeys(profileId).forEach(editor::remove)
        identityRecord(profileId)?.let { editor.putString(identityKey(profileId), json.encodeToString(
            it.invalidated().copy(identityFingerprint = ""))) }
        editor.apply()
        if (lastProfileId() == profileId) {
            preferences.edit().remove(KEY_LAST_PROFILE_ID).apply()
        }
        notifyWorkspaceIdentityChanged()
    }

    fun session(profileId: String): DsmSession? =
        preferences.getString(sessionKey(profileId), null)?.let {
            runCatching { json.decodeFromString<DsmSession>(it) }.getOrNull()
        }

    fun saveSession(session: DsmSession) = synchronized(workspaceStoreLock) {
        val editor = preferences.edit()
            .putString(sessionKey(session.profileId), json.encodeToString(session))
        identityRecord(session.profileId)?.let {
            editor.putString(identityKey(session.profileId), json.encodeToString(it.invalidated()))
        }
        editor.apply()
        notifyWorkspaceIdentityChanged()
    }

    fun clearSession(profileId: String) = synchronized(workspaceStoreLock) {
        val editor = preferences.edit().remove(sessionKey(profileId))
        identityRecord(profileId)?.let { editor.putString(identityKey(profileId), json.encodeToString(it.invalidated())) }
        editor.apply()
        notifyWorkspaceIdentityChanged()
    }

    internal fun connectionAttempt(profileId: String): WorkspaceConnectionAttempt = synchronized(workspaceStoreLock) {
        WorkspaceConnectionAttempt(profileId,
            profiles().firstOrNull { it.id == profileId }?.workspaceIdentityFingerprint(), identityRecord(profileId))
    }

    /** 认证与权限读取成功后一次保存；失败/取消的旧登录不能覆盖新账号或退出状态。 */
    internal fun commitConnection(
        attempt: WorkspaceConnectionAttempt,
        profile: NasProfile,
        session: DsmSession,
        password: String?,
        autoLogin: Boolean,
        persistSession: Boolean = password != null,
        makeLastProfile: Boolean = true,
    ): WorkspaceOwner = synchronized(workspaceStoreLock) {
        val currentProfiles = profiles()
        val previousProfile = currentProfiles.firstOrNull { it.id == attempt.profileId }
        val previous = identityRecord(attempt.profileId)
        if (profile.id != attempt.profileId || !attempt.stillMatches(previousProfile, previous)) {
            throw workspaceChangedFailure()
        }
        val next = nextWorkspaceIdentity(previous, profile, session)
        val identityChanged = previousProfile != null &&
            previousProfile.workspaceIdentityFingerprint() != profile.workspaceIdentityFingerprint() ||
            previous != null && previous.identityFingerprint != profile.workspaceIdentityFingerprint()
        val editor = preferences.edit()
            .putString(KEY_PROFILES, json.encodeToString(ListSerializer(NasProfile.serializer()),
                currentProfiles.filterNot { it.id == profile.id } + profile))
            .putString(identityKey(profile.id), json.encodeToString(next))
            .putBoolean(autoLoginKey(profile.id), password != null && autoLogin)
        if (makeLastProfile) editor.putString(KEY_LAST_PROFILE_ID, profile.id)
        if (password != null) {
            editor.putString(passwordKey(profile.id), password)
        } else {
            editor.remove(passwordKey(profile.id))
        }
        if (persistSession) editor.putString(sessionKey(profile.id), json.encodeToString(session))
        else editor.remove(sessionKey(profile.id))
        if (identityChanged) {
            editor.remove(recentDirectoriesKey(profile.id)).remove(workspaceUiStateKey(profile.id))
            opaqueWorkspaceRouteKeys(profile.id).forEach(editor::remove)
        }
        if (!editor.commit()) throw workspaceStorageFailure()
        notifyWorkspaceIdentityChanged()
        next.owner
    }

    internal fun clearSessionIfCurrent(profileId: String, expected: DsmSession): Boolean = synchronized(workspaceStoreLock) {
        if (session(profileId) != expected) return@synchronized false
        clearSession(profileId)
        true
    }

    internal fun signOut(owner: WorkspaceOwner): Boolean = synchronized(workspaceStoreLock) {
        if (identityRecord(owner.profileId)?.owner != owner) return@synchronized false
        clearSession(owner.profileId)
        preferences.edit().putBoolean(autoLoginKey(owner.profileId), false).apply()
        true
    }

    internal fun requireCurrentOwner(owner: WorkspaceOwner) = synchronized(workspaceStoreLock) {
        val profile = profiles().firstOrNull { it.id == owner.profileId } ?: throw workspaceChangedFailure()
        val current = identityRecord(owner.profileId)
        if (current?.owner != owner || !current.matches(profile)) throw workspaceChangedFailure()
    }

    internal fun currentOwner(profileId: String): WorkspaceOwner? = synchronized(workspaceStoreLock) {
        val profile = profiles().firstOrNull { it.id == profileId } ?: return@synchronized null
        identityRecord(profileId)?.takeIf { it.matches(profile) }?.owner
    }

    /** 本机历史在退出后仍可见；账号或目标已修改则不能展示旧身份的业务资料。 */
    internal fun profileForOwner(owner: WorkspaceOwner): NasProfile? = synchronized(workspaceStoreLock) {
        val profile = profiles().firstOrNull { it.id == owner.profileId } ?: return@synchronized null
        identityRecord(profile.id)?.takeIf { it.hasIdentity(profile) && it.owner.hasSameIdentity(owner) }?.let { profile }
    }

    internal fun lease(owner: WorkspaceOwner): WorkspaceOwnerLease =
        WorkspaceOwnerLease({ requireCurrentOwner(owner) }).also { it.requireCurrent() }

    /** 只供原任务恢复使用；允许同一身份重新登录，不允许换账号后认领原任务。 */
    internal fun savedConnectionForRecord(kind: WorkspaceRecordKind, id: String): SavedWorkspaceConnection =
        synchronized(workspaceStoreLock) {
            val expected = recordOwner(kind, id) ?: throw workspaceChangedFailure()
            val profile = profiles().firstOrNull { it.id == expected.profileId } ?: throw workspaceChangedFailure()
            val session = session(profile.id) ?: throw DsmFailure(null, "No saved session is available",
                "Sign in to the original connection again.", true, DsmErrorKind.NO_SAVED_SESSION)
            val current = identityRecord(profile.id)
            if (current == null || !current.matches(profile, session) ||
                !current.owner.hasSameIdentity(expected)) throw workspaceChangedFailure()
            SavedWorkspaceConnection(profile, session, current.owner)
        }

    /** 必须在任务事实保存及提交前写入；既有归属不可被新的账号覆写。 */
    internal fun bindRecord(kind: WorkspaceRecordKind, id: String, owner: WorkspaceOwner) = synchronized(workspaceStoreLock) {
        requireCurrentOwner(owner)
        recordOwner(kind, id)?.let { existing ->
            if (!existing.hasSameIdentity(owner)) throw workspaceChangedFailure()
            return@synchronized
        }
        if (!preferences.edit().putString(recordOwnerKey(kind, id),
                json.encodeToString(WorkspaceRecordOwner(owner = owner))).commit()) throw workspaceStorageFailure()
    }

    internal fun requireRecordOwner(kind: WorkspaceRecordKind, id: String, owner: WorkspaceOwner) =
        synchronized(workspaceStoreLock) {
            requireCurrentOwner(owner)
            if (recordOwner(kind, id)?.hasSameIdentity(owner) != true) throw workspaceChangedFailure()
        }

    internal fun recordOwner(kind: WorkspaceRecordKind, id: String): WorkspaceOwner? = synchronized(workspaceStoreLock) {
        preferences.getString(recordOwnerKey(kind, id), null)?.let { value ->
            runCatching { json.decodeFromString<WorkspaceRecordOwner>(value) }.getOrNull()
                ?.takeIf { it.schemaVersion == 1 }?.owner ?: throw workspaceStorageFailure()
        }
    }

    private fun identityRecord(profileId: String): WorkspaceIdentityRecord? =
        preferences.getString(identityKey(profileId), null)?.let { value ->
            runCatching { json.decodeFromString<WorkspaceIdentityRecord>(value) }.getOrNull()
                ?.takeIf { it.schemaVersion == 1 && it.owner.profileId == profileId }
                ?: throw workspaceStorageFailure()
        }

    private fun identityKey(profileId: String) = "workspace_identity_v1_${encodeProfileId(profileId)}"
    private fun recordOwnerKey(kind: WorkspaceRecordKind, id: String) =
        "workspace_record_v1_${kind.name}_${encodeProfileId(id)}"

    fun password(profileId: String): String? =
        preferences.getString(passwordKey(profileId), null)

    fun savePassword(profileId: String, password: String) {
        preferences.edit().putString(passwordKey(profileId), password).apply()
    }

    fun clearPassword(profileId: String) {
        preferences.edit()
            .remove(passwordKey(profileId))
            .putBoolean(autoLoginKey(profileId), false)
            .apply()
    }

    fun isAutoLoginEnabled(profileId: String): Boolean =
        preferences.getBoolean(autoLoginKey(profileId), false)

    fun setAutoLoginEnabled(profileId: String, enabled: Boolean) {
        preferences.edit().putBoolean(autoLoginKey(profileId), enabled).apply()
    }

    fun lastProfileId(): String? = preferences.getString(KEY_LAST_PROFILE_ID, null)

    fun setLastProfileId(profileId: String?) {
        preferences.edit().apply {
            if (profileId == null) remove(KEY_LAST_PROFILE_ID)
            else putString(KEY_LAST_PROFILE_ID, profileId)
        }.apply()
    }

    fun recentDirectories(profileId: String): List<String> =
        preferences.getString(recentDirectoriesKey(profileId), null)?.let { value ->
            runCatching {
                json.decodeFromString(ListSerializer(String.serializer()), value)
            }.getOrDefault(emptyList())
        }.orEmpty()

    internal fun recordRecentDirectory(profileId: String, path: String, owner: WorkspaceOwner? = null) = synchronized(workspaceStoreLock) {
        if (!canSaveWorkspaceState(profileId, owner)) return
        if (!path.startsWith('/') || path.split('/').contains("#recycle")) return
        val recent = updateRecentDirectories(recentDirectories(profileId), path)
        preferences.edit().putString(
            recentDirectoriesKey(profileId),
            json.encodeToString(ListSerializer(String.serializer()), recent),
        ).apply()
    }

    fun workspaceUiState(profileId: String): PersistedWorkspaceUiState? =
        preferences.getString(workspaceUiStateKey(profileId), null)?.let { value ->
            runCatching { json.decodeFromString<PersistedWorkspaceUiState>(value) }.getOrNull()
        }

    internal fun saveWorkspaceUiState(profileId: String, state: PersistedWorkspaceUiState, owner: WorkspaceOwner? = null) = synchronized(workspaceStoreLock) {
        if (!canSaveWorkspaceState(profileId, owner)) return
        preferences.edit()
            .putString(workspaceUiStateKey(profileId), json.encodeToString(state))
            .apply()
    }

    private fun canSaveWorkspaceState(profileId: String, owner: WorkspaceOwner?): Boolean =
        if (owner == null) identityRecord(profileId) == null
        else owner.profileId == profileId && runCatching { requireCurrentOwner(owner) }.isSuccess

    /**
     * 同步写入本机加密的业务目标映射；成功后才返回可放进外部 URI 的不透明令牌。
     *
     * 同一资料、同一目标会复用既有令牌。令牌不包含 NAS、会话、路径或对象 ID，且不会过期，
     * 直到资料被删除、存储被清空或调用方显式删除该令牌。
     */
    @Synchronized
    internal fun issueOpaqueWorkspaceTarget(
        profileId: String,
        target: OpaqueWorkspaceTarget,
        owner: WorkspaceOwner,
        createdAtEpochMillis: Long = System.currentTimeMillis(),
    ): String? = synchronized(workspaceStoreLock) {
        if (profiles().none { it.id == profileId }) return null
        if (owner.profileId != profileId || runCatching { requireCurrentOwner(owner) }.isFailure) return null
        issueOwnedOpaqueTarget(profileId, target, owner, createdAtEpochMillis)
    }

    /** 通知只能绑定已有任务的原身份；退出后仍可查看本机记录，不授予网络操作权限。 */
    internal fun issueLocalTransferTarget(kind: WorkspaceRecordKind, id: String,
        createdAtEpochMillis: Long = System.currentTimeMillis()): String? = synchronized(workspaceStoreLock) {
        val taskKind = io.github.qwertyuiop1995.dsmnativeclient.domain.LocalTransferKind.entries.firstOrNull { it.name == kind.name } ?: return null
        val owner = recordOwner(kind, id) ?: return null
        if (profileForOwner(owner) == null) return null
        issueOwnedOpaqueTarget(owner.profileId, OpaqueWorkspaceTarget.LocalTransfer(taskKind, id), owner, createdAtEpochMillis)
    }

    private fun issueOwnedOpaqueTarget(profileId: String, target: OpaqueWorkspaceTarget,
        owner: WorkspaceOwner, createdAtEpochMillis: Long): String? {
        val current = opaqueWorkspaceRoutes(profileId).filter { route ->
            recordOwner(WorkspaceRecordKind.OPAQUE_ROUTE, route.token)?.hasSameIdentity(owner) == true
        }
        val existing = current.firstOrNull { it.target == target }
        if (existing != null) return existing.token

        var token: String
        do {
            token = createOpaqueWorkspaceToken(secureRandom)
        } while (opaqueWorkspaceRoute(token) != null)

        val candidate = OpaqueWorkspaceRouteRecord(
            token = token,
            profileId = profileId,
            target = target,
            createdAtEpochMillis = createdAtEpochMillis,
        )
        // 高频任务通知独立计算容量，不能挤掉用户复制的页面和对象链接。
        val taskLink = target is OpaqueWorkspaceTarget.LocalTransfer
        val samePurpose = current.filter { (it.target is OpaqueWorkspaceTarget.LocalTransfer) == taskLink }
        val mutation = planOpaqueWorkspaceRouteIssue(samePurpose, candidate)
        val editor = preferences.edit()
        mutation.removedTokens.forEach { removedToken ->
            editor.remove(opaqueWorkspaceRouteKey(profileId, removedToken))
            editor.remove(recordOwnerKey(WorkspaceRecordKind.OPAQUE_ROUTE, removedToken))
        }
        editor.putString(
            opaqueWorkspaceRouteKey(profileId, token),
            json.encodeToString(candidate),
        ).putString(recordOwnerKey(WorkspaceRecordKind.OPAQUE_ROUTE, token), json.encodeToString(WorkspaceRecordOwner(owner = owner)))
        return token.takeIf { editor.commit() }
    }

    /**
     * 读取令牌对应的加密记录。资料已删除、记录损坏或 schema 不受支持时一律返回 null。
     */
    @Synchronized
    fun opaqueWorkspaceRoute(token: String): OpaqueWorkspaceRouteRecord? = synchronized(workspaceStoreLock) {
        if (!token.isOpaqueWorkspaceToken()) return null
        val owner = runCatching { recordOwner(WorkspaceRecordKind.OPAQUE_ROUTE, token) }.getOrNull() ?: return null
        return profiles().asSequence()
            .filter { profile -> profile.id == owner.profileId && runCatching {
                val identity = identityRecord(profile.id)
                identity?.hasIdentity(profile) == true && identity.owner.hasSameIdentity(owner)
            }.getOrDefault(false) }
            .mapNotNull { profile ->
                decodeOpaqueWorkspaceRoute(
                    profileId = profile.id,
                    value = preferences.getString(opaqueWorkspaceRouteKey(profile.id, token), null),
                )
            }
            .firstOrNull()
    }

    /** 删除令牌映射并同步确认写入结果；不存在的令牌不会写入。 */
    @Synchronized
    fun removeOpaqueWorkspaceRoute(token: String): Boolean {
        if (!token.isOpaqueWorkspaceToken()) return false
        val editor = preferences.edit()
            .remove(recordOwnerKey(WorkspaceRecordKind.OPAQUE_ROUTE, token))
        var removed = false
        profiles().forEach { profile ->
            val key = opaqueWorkspaceRouteKey(profile.id, token)
            if (preferences.contains(key)) {
                editor.remove(key)
                removed = true
            }
        }
        return removed && editor.commit()
    }

    @Synchronized
    fun clearAll() = synchronized(workspaceStoreLock) {
        preferences.edit().clear().apply()
        notifyWorkspaceIdentityChanged()
    }

    private fun sessionKey(profileId: String) = "session_$profileId"
    private fun passwordKey(profileId: String) = "password_$profileId"
    private fun autoLoginKey(profileId: String) = "auto_login_$profileId"
    private fun recentDirectoriesKey(profileId: String) = "recent_directories_$profileId"
    private fun workspaceUiStateKey(profileId: String) = "workspace_ui_state_$profileId"

    private fun opaqueWorkspaceRoutes(profileId: String): List<OpaqueWorkspaceRouteRecord> {
        val prefix = opaqueWorkspaceRouteKeyPrefix(profileId)
        return runCatching { preferences.all }
            .getOrDefault(emptyMap())
            .asSequence()
            .filter { (key, _) -> key.startsWith(prefix) }
            .mapNotNull { (_, value) ->
                decodeOpaqueWorkspaceRouteRecord(json, profileId, value as? String)
            }
            .sortedBy(OpaqueWorkspaceRouteRecord::createdAtEpochMillis)
            .toList()
    }

    private fun opaqueWorkspaceRouteKeys(profileId: String): List<String> {
        val prefix = opaqueWorkspaceRouteKeyPrefix(profileId)
        return runCatching { preferences.all.keys }
            .getOrDefault(emptySet())
            .filter { it.startsWith(prefix) }
    }

    private fun decodeOpaqueWorkspaceRoute(
        profileId: String,
        value: String?,
    ): OpaqueWorkspaceRouteRecord? = decodeOpaqueWorkspaceRouteRecord(json, profileId, value)

    private fun opaqueWorkspaceRouteKey(profileId: String, token: String): String =
        "${opaqueWorkspaceRouteKeyPrefix(profileId)}$token"

    private fun opaqueWorkspaceRouteKeyPrefix(profileId: String): String =
        "opaque_workspace_route_${encodeProfileId(profileId)}_"

    private fun encodeProfileId(profileId: String): String = Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(profileId.toByteArray(StandardCharsets.UTF_8))

    private companion object {
        const val KEY_PROFILES = "profiles"
        const val KEY_LAST_PROFILE_ID = "last_profile_id"
        const val MAX_RECENT_DIRECTORIES = 20
    }

    private val secureRandom = SecureRandom()
}

@kotlinx.serialization.Serializable
data class PersistedWorkspaceUiState(
    val selectedModule: String = "FILES",
    val filePath: String = "",
    val filePathHistory: List<String> = emptyList(),
    val fileSearchQuery: String = "",
    val fileActiveSearchQuery: String? = null,
    val fileSortOption: String = "NAME",
    val fileSortAscending: Boolean = true,
    val fileTypeFilter: String = "ALL",
    val fileViewMode: String = "LIST",
    val chatPinnedConversationIds: List<String> = emptyList(),
)

internal fun updateRecentDirectories(current: List<String>, path: String): List<String> {
    if (!path.startsWith('/') || path.split('/').contains("#recycle")) return current
    return (listOf(path) + current.filterNot { it == path }).take(20)
}

internal const val MAX_OPAQUE_WORKSPACE_ROUTES_PER_PROFILE = 256
internal const val OPAQUE_WORKSPACE_TOKEN_BYTE_COUNT = 32
internal const val OPAQUE_WORKSPACE_TOKEN_LENGTH = 43

internal data class OpaqueWorkspaceRouteIssue(
    val token: String,
    val removedTokens: Set<String>,
)

/** 规划单资料内的去重和有界淘汰；实际加密写入由 [SecureProfileStore] 负责。 */
internal fun planOpaqueWorkspaceRouteIssue(
    current: List<OpaqueWorkspaceRouteRecord>,
    candidate: OpaqueWorkspaceRouteRecord,
): OpaqueWorkspaceRouteIssue {
    require(current.all { it.profileId == candidate.profileId }) {
        "Opaque workspace routes must belong to one profile"
    }
    current.firstOrNull { it.target == candidate.target }?.let { existing ->
        return OpaqueWorkspaceRouteIssue(existing.token, emptySet())
    }
    val overflow = (current.size + 1 - MAX_OPAQUE_WORKSPACE_ROUTES_PER_PROFILE)
        .coerceAtLeast(0)
    val removed = current
        .mapIndexed { index, route -> IndexedValue(index, route) }
        .sortedWith(
            compareBy<IndexedValue<OpaqueWorkspaceRouteRecord>> { it.value.createdAtEpochMillis }
                .thenBy(IndexedValue<OpaqueWorkspaceRouteRecord>::index),
        )
        .take(overflow)
        .map { it.value.token }
        .toSet()
    return OpaqueWorkspaceRouteIssue(candidate.token, removed)
}

internal fun createOpaqueWorkspaceToken(random: SecureRandom = SecureRandom()): String {
    val bytes = ByteArray(OPAQUE_WORKSPACE_TOKEN_BYTE_COUNT)
    random.nextBytes(bytes)
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
}

internal fun String.isOpaqueWorkspaceToken(): Boolean =
    length == OPAQUE_WORKSPACE_TOKEN_LENGTH &&
        all { character -> character.isAsciiLetterOrDigit() || character == '-' || character == '_' } &&
        runCatching {
            val bytes = Base64.getUrlDecoder().decode(this)
            bytes.size == OPAQUE_WORKSPACE_TOKEN_BYTE_COUNT &&
                Base64.getUrlEncoder().withoutPadding().encodeToString(bytes) == this
        }.getOrDefault(false)

internal fun decodeOpaqueWorkspaceRouteRecord(
    json: Json,
    profileId: String,
    value: String?,
): OpaqueWorkspaceRouteRecord? = value?.let {
    runCatching { json.decodeFromString<OpaqueWorkspaceRouteRecord>(it) }.getOrNull()
}?.takeIf { record ->
    record.schemaVersion == OPAQUE_WORKSPACE_ROUTE_SCHEMA_VERSION &&
        record.profileId == profileId &&
        record.token.isOpaqueWorkspaceToken()
}

private fun Char.isAsciiLetterOrDigit(): Boolean =
    this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
