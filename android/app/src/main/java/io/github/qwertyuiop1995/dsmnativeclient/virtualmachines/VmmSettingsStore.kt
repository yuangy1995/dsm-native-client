package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal data class VmmSettingsActivity(val id: String, val owner: WorkspaceOwner, val target: String,
    val name: String, val desiredName: String, val desired: String, val source: VmmSource,
    val stage: VmmStage = VmmStage.PREPARED, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = stage in setOf(VmmStage.PREPARED, VmmStage.SUBMITTED, VmmStage.ACCEPTED)
    override fun toString() = "VmmSettingsActivity($stage)"
}

/** 设置明文只在编辑内存中存活；独立加密记录保存字段摘要与接受阶段。 */
internal class VmmSettingsStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_vmm_settings",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: VmmSettingsActivity) = synchronized(lock) {
        if (record.stage != VmmStage.PREPARED || all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending &&
            (it.target == record.target || record.desiredName in setOf(it.name, it.desiredName)) }) vmmConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: VmmStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: storageFailure()
        val allowed = when (old.stage) {
            VmmStage.PREPARED -> if (old.owner == owner) setOf(VmmStage.SUBMITTED, VmmStage.CANCELLED) else setOf(VmmStage.CANCELLED)
            VmmStage.SUBMITTED -> if (old.owner == owner) setOf(VmmStage.ACCEPTED, VmmStage.REJECTED) else emptySet()
            VmmStage.ACCEPTED -> setOf(VmmStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed) vmmConflict()
        write(old.copy(stage = stage))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.pending != false) vmmConflict()
        if (!preferences.edit().remove(key(id)).commit()) storageFailure()
    }
    fun removeProfile(id: String) = synchronized(lock) {
        VmmExecutionGate.requireIdle(id)
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) storageFailure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, wait: Boolean = false, block: suspend () -> T): T = VmmExecutionGate.execute(owner, wait, block)
    private fun all(): List<VmmSettingsActivity> = try {
        if (failed) storageFailure()
        preferences.all.filterKeys { it.startsWith("settings:") }.map { (key, raw) ->
            json.decodeFromString<VmmSettingsActivity>(raw as? String ?: storageFailure()).also { validate(it); if (key != key(it.id)) storageFailure() }
        }
    } catch (_: Exception) { storageFailure() }
    private fun validate(record: VmmSettingsActivity) {
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 ||
            listOf(record.target, record.name, record.desiredName, record.desired).any { value -> value.length != 64 || value.any { it !in "0123456789abcdef" } }) storageFailure()
    }
    private fun write(record: VmmSettingsActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) storageFailure() }
    private fun key(id: String) = "settings:$id"
    private fun storageFailure(): Nothing { failed = true; throw VmmFailure(VmmProblem.STORAGE) }
    companion object { private val lock = Any() }
}
