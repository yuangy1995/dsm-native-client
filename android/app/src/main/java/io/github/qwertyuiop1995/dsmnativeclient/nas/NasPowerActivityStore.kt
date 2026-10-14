package io.github.qwertyuiop1995.dsmnativeclient.nas

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerStage
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.serviceConflict
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal data class NasPowerActivity(val id: String, val owner: WorkspaceOwner, val action: NasPowerAction,
    val sessionDigest: String, val stage: NasPowerStage = NasPowerStage.PREPARED,
    val restored: Boolean = false, val dismissed: Boolean = false, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val needsRecovery get() = stage in setOf(NasPowerStage.SUBMITTED, NasPowerStage.ACCEPTED) && !restored
    val blocks get() = stage == NasPowerStage.PREPARED || needsRecovery
    override fun toString() = "NasPowerActivity($action, $stage, restored=$restored)"
}

/** 跨进程保留防重复；解锁不改写此前接受/未知结果，不保存会话凭据。 */
internal class NasPowerActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_power_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: NasPowerActivity) = synchronized(lock) {
        if (record.stage != NasPowerStage.PREPARED || record.restored || record.dismissed ||
            all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.blocks }) serviceConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: NasPowerStage) = synchronized(lock) {
        val old = record(owner, id)
        if (old.owner != owner || when (old.stage) {
                NasPowerStage.PREPARED -> stage !in setOf(NasPowerStage.SUBMITTED, NasPowerStage.CANCELLED)
                NasPowerStage.SUBMITTED -> stage !in setOf(NasPowerStage.ACCEPTED, NasPowerStage.REJECTED)
                else -> true
            }) serviceConflict()
        write(old.copy(stage = stage))
    }
    fun cancelPrepared(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = record(owner, id)
        if (old.stage != NasPowerStage.PREPARED) serviceConflict()
        write(old.copy(stage = NasPowerStage.CANCELLED))
    }
    fun restore(owner: WorkspaceOwner, id: String, sessionDigest: String) = synchronized(lock) {
        val old = record(owner, id)
        if (!old.needsRecovery || sessionDigest == old.sessionDigest || !sessionDigest.digest()) serviceConflict()
        write(old.copy(restored = true))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = record(owner, id); if (old.blocks) serviceConflict(); write(old.copy(dismissed = true))
    }
    fun removeProfile(id: String) = synchronized(lock) {
        if (id in active) serviceConflict()
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) serviceConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun record(owner: WorkspaceOwner, id: String) = records(owner).singleOrNull { it.id == id } ?: failure()
    private fun all(): List<NasPowerActivity> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("power:") }.map { (key, raw) ->
            json.decodeFromString<NasPowerActivity>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasPowerActivity) {
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || !record.sessionDigest.digest() ||
            record.restored && record.stage !in setOf(NasPowerStage.SUBMITTED, NasPowerStage.ACCEPTED) || record.dismissed && record.blocks) failure()
    }
    private fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
    private fun write(record: NasPowerActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure() }
    private fun key(id: String) = "power:$id"
    private fun failure(): Nothing { failed = true; throw DsmFailure(null, "Power action could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
