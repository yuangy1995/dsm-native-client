package io.github.qwertyuiop1995.dsmnativeclient.nas

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal data class NasConnectionActivity(val id: String, val owner: WorkspaceOwner, val identity: NasConnectionIdentity,
    val stage: NasConnectionStage = NasConnectionStage.PREPARED, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = stage in setOf(NasConnectionStage.PREPARED, NasConnectionStage.SUBMITTED, NasConnectionStage.ACCEPTED)
    override fun toString() = "NasConnectionActivity($stage)"
}

/** 连接内容仅在页面内存存在；跨重启记录只保留不可逆身份与相似性摘要。 */
internal class NasConnectionActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_connection_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: NasConnectionActivity) = synchronized(lock) {
        if (record.stage != NasConnectionStage.PREPARED || all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending }) connectionConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: NasConnectionStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val allowed = when (old.stage) {
            NasConnectionStage.PREPARED -> if (old.owner == owner) setOf(NasConnectionStage.SUBMITTED, NasConnectionStage.CANCELLED) else setOf(NasConnectionStage.CANCELLED)
            NasConnectionStage.SUBMITTED -> if (old.owner == owner) setOf(NasConnectionStage.ACCEPTED, NasConnectionStage.REJECTED, NasConnectionStage.VERIFIED) else setOf(NasConnectionStage.VERIFIED)
            NasConnectionStage.ACCEPTED -> setOf(NasConnectionStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed) connectionConflict()
        write(old.copy(stage = stage))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (old.pending) connectionConflict()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(id: String) = synchronized(lock) {
        if (id in active) connectionConflict()
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) connectionConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<NasConnectionActivity> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("connection:") }.map { (key, raw) ->
            json.decodeFromString<NasConnectionActivity>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasConnectionActivity) {
        fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
        val identity = record.identity
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || !identity.primary.digest() || !identity.similarity.digest() ||
            identity.related.isEmpty() || identity.related.size > 2 || identity.primary !in identity.related || identity.related.any { !it.digest() }) failure()
    }
    private fun write(record: NasConnectionActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure() }
    private fun key(id: String) = "connection:$id"
    private fun failure(): Nothing { failed = true; throw DsmFailure(null, "Connection activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
