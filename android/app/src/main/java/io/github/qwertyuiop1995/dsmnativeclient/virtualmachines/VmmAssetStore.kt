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

@Serializable internal enum class VmmAssetKind { NETWORK, IMAGE }
@Serializable internal enum class VmmAssetAction { RENAME, DELETE }
@Serializable internal data class VmmAssetItem(val id: String, val identity: String, val name: String,
    val source: VmmSource, val topology: String? = null, val desiredName: String? = null,
    val guests: Set<String> = emptySet(), val stage: VmmStage = VmmStage.PREPARED) {
    val pending get() = stage in setOf(VmmStage.PREPARED, VmmStage.SUBMITTED, VmmStage.ACCEPTED)
}
@Serializable internal data class VmmAssetActivity(val id: String, val owner: WorkspaceOwner, val kind: VmmAssetKind,
    val action: VmmAssetAction, val items: List<VmmAssetItem>, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val pending get() = items.any { it.pending }
    override fun toString() = "VmmAssetActivity($kind, $action)"
}

/** 独立加密摘要，不保存网络、映像名称、原始 ID、主机或日志正文。写前落盘失败不得发送。 */
internal class VmmAssetStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_vmm_assets",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: VmmAssetActivity) = synchronized(lock) {
        if (record.items.any { it.stage != VmmStage.PREPARED } || all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.kind == record.kind && it.items.any { old -> old.pending && record.items.any { next -> next.id == old.id || next.desiredName != null && (next.desiredName == old.name || next.desiredName == old.desiredName) } } }) vmmConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, index: Int, stage: VmmStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: storageFailure()
        val item = old.items.getOrNull(index) ?: storageFailure()
        val allowed = when (item.stage) {
            VmmStage.PREPARED -> if (old.owner == owner) setOf(VmmStage.SUBMITTED, VmmStage.CANCELLED) else setOf(VmmStage.CANCELLED)
            VmmStage.SUBMITTED -> if (old.owner == owner) setOf(VmmStage.ACCEPTED, VmmStage.REJECTED) else emptySet()
            VmmStage.ACCEPTED -> setOf(VmmStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed) vmmConflict()
        write(old.copy(items = old.items.mapIndexed { position, value -> if (position == index) value.copy(stage = stage) else value }))
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
    private fun all(): List<VmmAssetActivity> = try {
        if (failed) storageFailure()
        preferences.all.filterKeys { it.startsWith("asset:") }.map { (key, raw) ->
            json.decodeFromString<VmmAssetActivity>(raw as? String ?: storageFailure()).also { validate(it); if (key != key(it.id)) storageFailure() }
        }
    } catch (_: Exception) { storageFailure() }
    private fun validate(record: VmmAssetActivity) {
        fun String.digest() = length == 64 && all { it in "0123456789abcdef" }
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || record.items.isEmpty() || record.items.any { !it.id.digest() || !it.identity.digest() || !it.name.digest() } ||
            record.items.map { it.id }.distinct().size != record.items.size ||
            record.items.any { item -> item.topology?.digest() == false || item.desiredName?.digest() == false || item.guests.any { !it.digest() } ||
                record.kind == VmmAssetKind.NETWORK && (item.topology == null || item.source != VmmSource.INTERNAL) ||
                record.action == VmmAssetAction.RENAME && (record.kind != VmmAssetKind.NETWORK || item.desiredName == null) } ||
            record.action == VmmAssetAction.RENAME && record.items.size != 1) storageFailure()
    }
    private fun write(record: VmmAssetActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) storageFailure() }
    private fun key(id: String) = "asset:$id"
    private fun storageFailure(): Nothing { failed = true; throw VmmFailure(VmmProblem.STORAGE) }
    companion object { private val lock = Any() }
}
