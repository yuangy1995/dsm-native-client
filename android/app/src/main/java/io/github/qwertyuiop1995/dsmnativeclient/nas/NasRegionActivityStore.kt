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

@Serializable internal data class NasRegionStepRecord(val step: NasRegionStep, val stage: NasServiceStage = NasServiceStage.PREPARED,
    val accepted: Boolean = false)
@Serializable internal data class NasRegionRecord(val id: String, val owner: WorkspaceOwner, val targetDigest: String,
    val steps: List<NasRegionStepRecord>, val manualTargetSeconds: Long? = null,
    val createdAt: Long = System.currentTimeMillis(), val supersededBy: String? = null, val version: Int = 1) {
    val terminal get() = supersededBy != null || steps.none { it.stage in setOf(NasServiceStage.PREPARED, NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED) }
    val canStartNewSync get() = steps.any { it.step == NasRegionStep.SYNCHRONIZATION } &&
        steps.none { it.step == NasRegionStep.CONFIGURATION && it.stage != NasServiceStage.VERIFIED }
    fun result() = regionResult(steps.map { it.stage })
}

/** 仅保存目标配置摘要、分步回执和主动选择的墙上时间；不保存时间服务器或配置正文。 */
internal class NasRegionActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_region_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner): List<NasRegionRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt }
    }
    fun begin(record: NasRegionRecord) = synchronized(lock) {
        val all = all()
        if (all.any { it.id == record.id } || record.steps.any { it.stage != NasServiceStage.PREPARED || it.accepted } || record.supersededBy != null) regionConflict()
        val pending = all.filter { it.owner.hasSameIdentity(record.owner) && !it.terminal }
        val syncOnly = record.steps.map { it.step } == listOf(NasRegionStep.SYNCHRONIZATION)
        if (pending.isNotEmpty() && (!syncOnly || pending.any { !it.canStartNewSync })) regionConflict()
        // 新校时必须由用户明确发起；保留上一操作的未知事实，原子写入取代关系。
        validate(record)
        val edit = preferences.edit()
        pending.forEach { edit.putString(key(it.id), json.encodeToString(it.copy(supersededBy = record.id))) }
        edit.putString(key(record.id), json.encodeToString(record))
        if (!edit.commit()) failure()
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, event: NasRegionCheckpoint) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val step = old.steps.singleOrNull { it.step == event.step } ?: failure()
        if (old.supersededBy != null) regionConflict()
        val allowed = when (step.stage) {
            NasServiceStage.PREPARED -> setOf(NasServiceStage.SUBMITTED, NasServiceStage.CANCELLED)
            NasServiceStage.SUBMITTED -> setOf(NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED, NasServiceStage.REJECTED)
            NasServiceStage.ACCEPTED -> setOf(NasServiceStage.VERIFIED, NasServiceStage.SUBMITTED)
            NasServiceStage.VERIFIED -> setOf(NasServiceStage.SUBMITTED)
            else -> emptySet()
        }
        if (event.stage !in allowed || event.stage == NasServiceStage.VERIFIED && !step.accepted &&
            (step.step == NasRegionStep.SYNCHRONIZATION || old.manualTargetSeconds != null)) regionConflict()
        val updated = old.copy(steps = old.steps.map { if (it.step == event.step)
            it.copy(stage = event.stage, accepted = it.accepted || event.stage == NasServiceStage.ACCEPTED) else it })
        validate(updated)
        if (!preferences.edit().putString(key(id), json.encodeToString(updated)).commit()) failure()
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.terminal != true) regionConflict()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        if (profileId in active) regionConflict()
        val edit = preferences.edit(); all().filter { it.owner.profileId == profileId }.forEach { edit.remove(key(it.id)) }
        if (!edit.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        synchronized(lock) { if (!active.add(owner.profileId)) regionConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(owner.profileId) } }
    }
    private fun all(): List<NasRegionRecord> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("region:") }.map { (key, value) ->
            json.decodeFromString<NasRegionRecord>(value as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasRegionRecord) {
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || record.steps.isEmpty() ||
            record.targetDigest.length != 64 || record.targetDigest.any { it !in "0123456789abcdef" } ||
            record.steps.map { it.step }.distinct().size != record.steps.size ||
            record.steps.any { it.accepted && it.stage in setOf(NasServiceStage.PREPARED, NasServiceStage.REJECTED, NasServiceStage.CANCELLED) ||
                it.stage == NasServiceStage.ACCEPTED && !it.accepted || it.stage == NasServiceStage.VERIFIED && !it.accepted &&
                (it.step == NasRegionStep.SYNCHRONIZATION || record.manualTargetSeconds != null) } ||
            record.manualTargetSeconds != null && record.steps.none { it.step == NasRegionStep.CONFIGURATION } ||
            record.supersededBy == record.id) failure()
    }
    private fun key(id: String) = "region:$id"
    private fun failure(): Nothing { failed = true; throw DsmFailure(null, "Region activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
