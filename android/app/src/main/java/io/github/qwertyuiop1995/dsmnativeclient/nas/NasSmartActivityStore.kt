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

@Serializable internal data class NasSmartActivity(val id: String, val owner: WorkspaceOwner, val identity: String, val action: NasSmartAction,
    val stage: NasSmartStage = NasSmartStage.PREPARED, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = stage in setOf(NasSmartStage.PREPARED, NasSmartStage.SUBMITTED, NasSmartStage.ACCEPTED)
    override fun toString() = "NasSmartActivity($stage)"
}

/** 硬盘设备标识仅在页面内存存在；跨重启记录只保留原账号、目标摘要、动作与阶段。 */
internal class NasSmartActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_smart_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: NasSmartActivity) = synchronized(lock) {
        if (record.stage != NasSmartStage.PREPARED || all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending }) smartConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: NasSmartStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val allowed = when (old.stage) {
            NasSmartStage.PREPARED -> if (old.owner == owner) setOf(NasSmartStage.SUBMITTED, NasSmartStage.CANCELLED) else setOf(NasSmartStage.CANCELLED)
            NasSmartStage.SUBMITTED -> if (old.owner == owner) setOf(NasSmartStage.ACCEPTED, NasSmartStage.REJECTED, NasSmartStage.VERIFIED) else setOf(NasSmartStage.VERIFIED)
            NasSmartStage.ACCEPTED -> setOf(NasSmartStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed) smartConflict()
        write(old.copy(stage = stage))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (old.pending) smartConflict()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(id: String) = synchronized(lock) {
        if (id in active) smartConflict()
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) smartConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<NasSmartActivity> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("smart:") }.map { (key, raw) ->
            json.decodeFromString<NasSmartActivity>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasSmartActivity) {
        fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || !record.identity.digest()) failure()
    }
    private fun write(record: NasSmartActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure() }
    private fun key(id: String) = "smart:$id"
    private fun failure(): Nothing { failed = true; throw DsmFailure(null, "Drive test activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
