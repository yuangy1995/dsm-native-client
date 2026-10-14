package io.github.qwertyuiop1995.dsmnativeclient.nas

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.directoryFields
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.directoryKey
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** 只保存身份、字段摘要及回执；账号名称、邮件、组关系和密码不落盘。 */
@Serializable internal data class NasDirectoryRecord(
    val id: String, val owner: WorkspaceOwner, val kind: NasDirectoryKind, val action: NasDirectoryAction,
    val targetDigest: String, val fieldsDigest: String, val numericId: Long?,
    val includeGroups: Boolean, val requiresAcknowledgement: Boolean,
    val stage: NasDirectoryStage = NasDirectoryStage.SUBMITTED, val accepted: Boolean = false,
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1,
) {
    val terminal get() = stage in setOf(NasDirectoryStage.COMPLETED, NasDirectoryStage.REJECTED)
    override fun toString() = "NasDirectoryRecord($kind, $action, $stage)"
}
internal class NasDirectoryActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_directory_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }
    private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(value: NasDirectoryRecord) = synchronized(lock) {
        if (all().any { it.id == value.id || it.owner.hasSameIdentity(value.owner) && !it.terminal }) busy()
        if (value.stage != NasDirectoryStage.SUBMITTED || value.accepted) failure()
        write(value)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: NasDirectoryStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (old.terminal || stage == NasDirectoryStage.SUBMITTED || stage == NasDirectoryStage.ACCEPTED && old.accepted ||
            stage == NasDirectoryStage.REJECTED && old.accepted) failure()
        if (stage == NasDirectoryStage.COMPLETED && old.requiresAcknowledgement && !old.accepted) failure()
        write(old.copy(stage = stage, accepted = old.accepted || stage == NasDirectoryStage.ACCEPTED))
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.terminal != true) failure()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        if (profileId in active) busy()
        val editor = preferences.edit(); all().filter { it.owner.profileId == profileId }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) busy() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<NasDirectoryRecord> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("directory:") }.map { (key, raw) ->
            val record = json.decodeFromString<NasDirectoryRecord>(raw as? String ?: failure())
            validate(record); if (key != key(record.id)) failure(); record
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasDirectoryRecord) {
        if (record.id.isBlank() || record.version != 1 || record.createdAt < 0 || record.numericId?.let { it < 0 } == true ||
            listOf(record.targetDigest, record.fieldsDigest).any { it.length != 64 || it.any { char -> char !in "0123456789abcdef" } } ||
            record.stage == NasDirectoryStage.ACCEPTED && !record.accepted || record.stage == NasDirectoryStage.REJECTED && record.accepted ||
            record.stage == NasDirectoryStage.COMPLETED && record.requiresAcknowledgement && !record.accepted) failure()
    }
    private fun write(value: NasDirectoryRecord) {
        validate(value)
        if (!preferences.edit().putString(key(value.id), json.encodeToString(value)).commit()) { failed = true; failure() }
    }
    private fun key(id: String) = "directory:$id"
    private fun failure(): Nothing = throw DsmFailure(null, "Directory activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
    private fun busy(): Nothing = throw NasDirectoryFailure(NasDirectoryProblem.BUSY)
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
internal fun directoryRecord(id: String, owner: WorkspaceOwner, change: NasDirectoryChange) = NasDirectoryRecord(
    id, owner, change.kind, change.action, packageDigest(directoryKey(change.name)), packageDigest(directoryFields(change).toString()),
    change.originalId, change.groups != null, change.requiresAcknowledgement)
