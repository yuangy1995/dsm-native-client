package io.github.qwertyuiop1995.dsmnativeclient.nas

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal data class NasDdnsRecordActivity(val id: String, val owner: WorkspaceOwner, val operation: DdnsMutationOperation,
    val providerDigest: String?, val targetDigest: String?, val requiresAcceptance: Boolean,
    val stage: NasServiceStage = NasServiceStage.PREPARED, val accepted: Boolean = false, val dismissed: Boolean = false,
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val transient get() = operation in setOf(DdnsMutationOperation.TEST, DdnsMutationOperation.ADDRESS_REFRESH)
    val terminal get() = stage in setOf(NasServiceStage.VERIFIED, NasServiceStage.REJECTED, NasServiceStage.CANCELLED)
    val blocks get() = !terminal && !transient
    fun result() = ddnsResult(operation, stage)
}
/** 仅保存原账号与不可逆摘要；瞬时动作未知可以关闭，但原结果不被删除或改写为成功。 */
internal class NasDdnsActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_ddns_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: NasDdnsRecordActivity) = synchronized(lock) {
        if (record.stage != NasServiceStage.PREPARED || record.accepted || record.dismissed || all().any { it.id == record.id ||
                it.owner.hasSameIdentity(record.owner) && it.blocks }) serviceConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, stage: NasServiceStage) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val allowed = when (old.stage) {
            NasServiceStage.PREPARED -> setOf(NasServiceStage.SUBMITTED, NasServiceStage.CANCELLED)
            NasServiceStage.SUBMITTED -> setOf(NasServiceStage.ACCEPTED, NasServiceStage.REJECTED, NasServiceStage.VERIFIED)
            NasServiceStage.ACCEPTED -> setOf(NasServiceStage.VERIFIED)
            else -> emptySet()
        }
        if (stage !in allowed || stage == NasServiceStage.VERIFIED && old.requiresAcceptance && !old.accepted) serviceConflict()
        write(old.copy(stage = stage, accepted = old.accepted || stage == NasServiceStage.ACCEPTED))
    }
    fun dismiss(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (old.blocks) serviceConflict()
        write(old.copy(dismissed = true))
    }
    fun removeProfile(id: String) = synchronized(lock) {
        if (id in active) serviceConflict()
        val editor = preferences.edit(); all().filter { it.owner.profileId == id }.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, action: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) serviceConflict() }
        try { return action() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<NasDdnsRecordActivity> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("ddns:") }.map { (key, raw) ->
            json.decodeFromString<NasDdnsRecordActivity>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasDdnsRecordActivity) {
        fun String?.digest() = this != null && length == 64 && all { it in "0123456789abcdef" }
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || record.dismissed && record.blocks ||
            record.stage == NasServiceStage.ACCEPTED && !record.accepted ||
            record.stage == NasServiceStage.VERIFIED && record.requiresAcceptance && !record.accepted ||
            record.stage in setOf(NasServiceStage.PREPARED, NasServiceStage.SUBMITTED, NasServiceStage.REJECTED, NasServiceStage.CANCELLED) && record.accepted ||
            when (record.operation) {
                DdnsMutationOperation.TEST -> !record.providerDigest.digest() || record.targetDigest != null || !record.requiresAcceptance
                DdnsMutationOperation.ADDRESS_REFRESH -> record.providerDigest != null || !record.targetDigest.digest() || !record.requiresAcceptance
                DdnsMutationOperation.SAVE -> !record.providerDigest.digest() || !record.targetDigest.digest()
                DdnsMutationOperation.DELETE -> !record.providerDigest.digest() || record.targetDigest != null || record.requiresAcceptance
            }) failure()
    }
    private fun write(record: NasDdnsRecordActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure() }
    private fun key(id: String) = "ddns:$id"
    private fun failure(): Nothing { failed = true; throw DsmFailure(null, "DDNS activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
