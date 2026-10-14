package io.github.qwertyuiop1995.dsmnativeclient.storage

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import kotlinx.serialization.Serializable
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.flow.update

/** 连接、账号/目标版本与会话代次；只含随机标识，不能用作 NAS 凭据。 */
@Serializable
internal data class WorkspaceOwner(
    val profileId: String,
    val identityRevision: String,
    val sessionGeneration: String,
) {
    fun hasSameIdentity(other: WorkspaceOwner): Boolean =
        profileId == other.profileId && identityRevision == other.identityRevision
}

/** 与旧配置分离的受保护记录；目标或账号变化不能沿用旧任务归属。 */
@Serializable
internal data class WorkspaceIdentityRecord(
    val schemaVersion: Int = 1,
    val owner: WorkspaceOwner,
    val identityFingerprint: String,
    val sessionFingerprint: String,
    val active: Boolean = true,
) {
    fun hasIdentity(profile: NasProfile): Boolean = schemaVersion == 1 &&
        owner.profileId == profile.id && identityFingerprint == profile.workspaceIdentityFingerprint()

    fun matches(profile: NasProfile): Boolean = active && hasIdentity(profile)

    fun matches(profile: NasProfile, session: DsmSession): Boolean = matches(profile) &&
        session.profileId == profile.id && sessionFingerprint == session.workspaceSessionFingerprint()

    fun invalidated(): WorkspaceIdentityRecord = copy(
        owner = owner.copy(sessionGeneration = UUID.randomUUID().toString()), active = false,
    )
}

internal data class WorkspaceConnectionAttempt(
    val profileId: String,
    val previousIdentityFingerprint: String?,
    val previousRecord: WorkspaceIdentityRecord?,
) {
    fun stillMatches(profile: NasProfile?, record: WorkspaceIdentityRecord?): Boolean =
        previousIdentityFingerprint == profile?.workspaceIdentityFingerprint() && previousRecord == record
}

internal enum class WorkspaceRecordKind { DOWNLOAD, UPLOAD, SERVER, VMM_IMPORT, PHOTO_SOURCE, OPAQUE_ROUTE, DOCUMENT_PROVIDER }

@Serializable
internal data class WorkspaceRecordOwner(val schemaVersion: Int = 1, val owner: WorkspaceOwner)

internal data class SavedWorkspaceConnection(val profile: NasProfile, val session: DsmSession, val owner: WorkspaceOwner)

internal fun nextWorkspaceIdentity(
    previous: WorkspaceIdentityRecord?,
    profile: NasProfile,
    session: DsmSession,
): WorkspaceIdentityRecord {
    require(profile.id == session.profileId)
    val fingerprint = profile.workspaceIdentityFingerprint()
    val sameIdentity = previous?.schemaVersion == 1 && previous.owner.profileId == profile.id &&
        previous.identityFingerprint == fingerprint
    val sameSession = sameIdentity && previous!!.active &&
        previous.sessionFingerprint == session.workspaceSessionFingerprint()
    return WorkspaceIdentityRecord(
        owner = WorkspaceOwner(profile.id,
            if (sameIdentity) previous!!.owner.identityRevision else UUID.randomUUID().toString(),
            if (sameSession) previous!!.owner.sessionGeneration else UUID.randomUUID().toString()),
        identityFingerprint = fingerprint,
        sessionFingerprint = session.workspaceSessionFingerprint(),
    )
}

/** 不猜测别名、大小写或 QuickConnect 路径是否属于同一设备。显示名不参与身份。 */
internal fun NasProfile.workspaceIdentityFingerprint(): String =
    workspaceFingerprint(listOf(id, address.trim(), port?.toString().orEmpty(), username.trim()))

private fun DsmSession.workspaceSessionFingerprint(): String =
    workspaceFingerprint(listOf(profileId, sid, synoToken.orEmpty(), deviceId.orEmpty()))

private fun workspaceFingerprint(fields: List<String>): String {
    val digest = MessageDigest.getInstance("SHA-256")
    fields.forEach { value ->
        val bytes = value.toByteArray(Charsets.UTF_8)
        digest.update(bytes.size.toString().toByteArray(Charsets.US_ASCII))
        digest.update(':'.code.toByte())
        digest.update(bytes)
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

internal fun workspaceChangedFailure() = DsmFailure(null,
    "The connection account or target has changed", "Open the original connection and sign in again.",
    kind = DsmErrorKind.WORKSPACE_CHANGED)

internal fun workspaceStorageFailure() = DsmFailure(null,
    "The connection could not be saved", "Free up storage and connect again.",
    kind = DsmErrorKind.LOCAL_STORAGE_FAILED)

/** 所有实例和 Worker 共用同一锁，保护加密配置与归属记录的读改写。 */
internal val workspaceStoreLock = Any()
internal val workspaceIdentityChanges = kotlinx.coroutines.flow.MutableStateFlow(0L)
internal fun notifyWorkspaceIdentityChanged() { workspaceIdentityChanges.update { it + 1 } }

/** 每次媒体范围读取只检查内存代次；任意配置/会话写入后重新核对受保护记录。 */
internal class WorkspaceOwnerLease(
    private val validate: () -> Unit,
    private val revision: () -> Long = { workspaceIdentityChanges.value },
) {
    @Volatile private var acceptedRevision = Long.MIN_VALUE
    fun requireCurrent() {
        val before = revision()
        if (before == acceptedRevision) return
        validate()
        acceptedRevision = before
    }
}
