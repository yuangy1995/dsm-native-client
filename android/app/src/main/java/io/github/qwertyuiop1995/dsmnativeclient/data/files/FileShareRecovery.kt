package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/** 只保存非凭据的预期结果；不保存新旧密码，也不允许从记录重建写请求。 */
@Serializable
internal data class FileShareExpectation(
    val hasPassword: Boolean,
    val requiresAcknowledgement: Boolean,
    val availableAt: String?,
    val expiresAt: String?,
    val exactAvailable: Boolean = false,
    val exactExpiration: Boolean = false,
    val advanced: FileShareAdvancedDetails? = null,
    val fileRequest: FileRequestConfiguration? = null,
    val creation: Boolean = false,
    val ignoreAudienceMembers: Boolean = false,
) {
    fun matches(link: FileShareLink, acknowledged: Boolean): Boolean {
        if (requiresAcknowledgement && !acknowledged || !link.passwordKnown || !link.availabilityKnown || !link.expirationKnown || link.hasPassword != hasPassword) return false
        fun date(value: String?, expected: String?, exact: Boolean) = value == expected ||
            !exact && expected != null && value == "$expected 00:00:00"
        if (!date(link.availableAt, availableAt, exactAvailable) || !date(link.expiresAt, expiresAt, exactExpiration)) return false
        if (advanced != null) {
            val actual = link.advanced ?: return false
            val expected = if (ignoreAudienceMembers) advanced.copy(users = actual.users, groups = actual.groups) else advanced
            if (actual != expected) return false
        }
        if (creation) {
            if (fileRequest == null) return link.advanced?.isFileRequest != true
            return link.advanced?.let { it.isFileRequest && it.allowsUpload &&
                it.requestName == fileRequest.name && it.requestMessage == fileRequest.message } == true
        }
        return true
    }
}

internal fun FileShareCreateRequest.expectation() = FileShareExpectation(password != null, password != null,
    availableOn?.toString(), expiresOn?.toString(), fileRequest = fileRequest, creation = true)

internal fun FileShareEditRequest.expectation(): FileShareExpectation {
    fun date(change: FileShareDateChange, original: String?) = when (change) {
        FileShareDateChange.Keep -> original
        FileShareDateChange.Clear -> null
        is FileShareDateChange.Set -> change.date.toString()
    }
    val audience = advanced?.audience ?: FileShareAudienceChange.Keep
    val members = (audience as? FileShareAudienceChange.Principals)?.members
    val desired = baseline.advanced?.let { before ->
        before.copy(
            protection = when (audience) {
                FileShareAudienceChange.Anyone -> FileShareProtection.NONE
                is FileShareAudienceChange.Principals -> FileShareProtection.USERS
                FileShareAudienceChange.Keep -> when (password) {
                    FileSharePasswordChange.Keep -> before.protection
                    FileSharePasswordChange.Remove -> FileShareProtection.NONE
                    is FileSharePasswordChange.Set -> FileShareProtection.PASSWORD
                }
            },
            users = if (audience == FileShareAudienceChange.Keep) before.users else members.orEmpty().filter { it.kind == FileSharePrincipalKind.USER }.map { it.name }.toSet(),
            groups = if (audience == FileShareAudienceChange.Keep) before.groups else members.orEmpty().filter { it.kind == FileSharePrincipalKind.GROUP }.map { it.name }.toSet(),
            maximumAccesses = advanced?.maximumAccesses ?: before.maximumAccesses,
            requestName = advanced?.requestName ?: before.requestName,
            requestMessage = advanced?.requestMessage ?: before.requestMessage,
        )
    }
    val hasPassword = when (password) {
        FileSharePasswordChange.Keep -> audience == FileShareAudienceChange.Keep && baseline.hasPassword
        FileSharePasswordChange.Remove -> false
        is FileSharePasswordChange.Set -> true
    }
    return FileShareExpectation(hasPassword, password is FileSharePasswordChange.Set,
        date(availableOn, baseline.availableAt), date(expiresOn, baseline.expiresAt),
        exactAvailable = availableOn == FileShareDateChange.Keep, exactExpiration = expiresOn == FileShareDateChange.Keep,
        advanced = desired, ignoreAudienceMembers = audience == FileShareAudienceChange.Anyone)
}

@Serializable
internal data class FileSharePendingChange(
    val schemaVersion: Int = 1,
    val id: String = UUID.randomUUID().toString(),
    val owner: WorkspaceOwner,
    val key: String,
    val path: String,
    val name: String,
    val expected: FileShareExpectation,
    val linkId: String? = null,
    val originalUrl: String? = null,
    val acknowledged: Boolean = false,
) {
    fun matches(link: FileShareLink) = link.id == linkId && link.path == path &&
        (originalUrl == null || link.url == originalUrl) && expected.matches(link, acknowledged)
}

/** 独立版本键，写前同步保存；存储不可读时拒绝新写，不能悄悄丢弃未知结果。 */
internal class FileShareRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_share_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }

    fun pending(owner: WorkspaceOwner): List<FileSharePendingChange> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val records = runCatching { json.decodeFromString<List<FileSharePendingChange>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (records.any { it.schemaVersion != 1 || !it.owner.hasSameIdentity(owner) || !isFileMutationPath(it.path) || it.key.isBlank() } || records.map { it.id }.distinct().size != records.size) throw workspaceStorageFailure()
        records
    }
    fun begin(record: FileSharePendingChange) = synchronized(lock) {
        val existing = pending(record.owner)
        if (existing.any { it.key == record.key || it.id == record.id }) throw DsmFailure(null,
            "An earlier sharing change has not finished", "Refresh shared links before trying again.", kind = DsmErrorKind.CHANGE_NOT_CONFIRMED)
        save(record.owner, existing + record)
    }
    fun acknowledge(record: FileSharePendingChange) = synchronized(lock) {
        val existing = pending(record.owner)
        if (existing.none { it.id == record.id }) throw workspaceStorageFailure()
        save(record.owner, existing.map { if (it.id == record.id) record else it })
    }
    fun finish(record: FileSharePendingChange) = synchronized(lock) { save(record.owner, pending(record.owner).filterNot { it.id == record.id }) }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { key -> key.startsWith("sharing_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(key.removePrefix("sharing_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit()
            keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun save(owner: WorkspaceOwner, records: List<FileSharePendingChange>) {
        val editor = preferences.edit()
        if (records.isEmpty()) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(records))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "sharing_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object { val lock = Any() }
}
