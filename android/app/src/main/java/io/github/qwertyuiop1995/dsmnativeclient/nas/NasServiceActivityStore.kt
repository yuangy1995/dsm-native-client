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

@Serializable internal data class NasServiceStepRecord(val step: NasServiceStep, val targetDigest: String,
    val stage: NasServiceStage = NasServiceStage.PREPARED, val requiresTask: Boolean = false, val task: NasFirewallTask? = null, val accepted: Boolean = false)
@Serializable internal data class NasServiceRecord(val id: String, val owner: WorkspaceOwner, val kind: NasServiceKind,
    val steps: List<NasServiceStepRecord>, val createdAt: Long = System.currentTimeMillis(), val version: Int = 1,
    val targetId: String? = null, val accountDigest: String? = null, val recoveryOwner: WorkspaceOwner? = null) {
    fun accessibleTo(current: WorkspaceOwner) = owner.hasSameIdentity(current) || recoveryOwner?.hasSameIdentity(current) == true
    fun canAssociate(current: WorkspaceOwner, account: String) = kind == NasServiceKind.ETHERNET && !terminal &&
        !accessibleTo(current) && owner.profileId == current.profileId && accountDigest == account &&
        owner.sessionGeneration != current.sessionGeneration && recoveryOwner?.sessionGeneration != current.sessionGeneration
    val terminal get() = steps.none { it.stage in setOf(NasServiceStage.PREPARED, NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED) }
    val continuationStep: NasServiceStep? get() {
        val (first, second) = when (kind) {
            NasServiceKind.HARDWARE -> NasServiceStep.LED_BRIGHTNESS to NasServiceStep.LED_UPDATE
            NasServiceKind.MEMORY_COMPRESSION -> NasServiceStep.ZRAM to NasServiceStep.REBOOT_REQUIRED
            else -> return null
        }
        return second.takeIf { terminal && steps.any { it.step == first && it.stage == NasServiceStage.VERIFIED && it.accepted } &&
            steps.any { it.step == second && it.stage in setOf(NasServiceStage.CANCELLED, NasServiceStage.REJECTED) && !it.accepted } }
    }
    val canContinueLed get() = continuationStep == NasServiceStep.LED_UPDATE
    fun result() = serviceResult(kind, steps.map { it.stage })
}

/** 不存地址、端口、账号正文或配置值；未知记录只能通过原账号读取实际配置结束。 */
internal class NasServiceActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_service_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner): List<NasServiceRecord> = synchronized(lock) {
        all().filter { it.accessibleTo(owner) || it.kind == NasServiceKind.ETHERNET && it.owner.profileId == owner.profileId && !it.terminal }.sortedByDescending { it.createdAt }
    }
    fun begin(record: NasServiceRecord) = synchronized(lock) {
        if (record.recoveryOwner != null || record.steps.any { it.stage != NasServiceStage.PREPARED || it.task != null || it.accepted } || all().any { it.id == record.id ||
                it.kind == record.kind && !it.terminal && (it.owner.hasSameIdentity(record.owner) ||
                    record.kind == NasServiceKind.ETHERNET && it.owner.profileId == record.owner.profileId) }) serviceConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, event: NasServiceCheckpoint) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (!old.accessibleTo(owner)) serviceConflict()
        val step = old.steps.singleOrNull { it.step == event.step } ?: failure()
        val allowed = when (step.stage) {
            NasServiceStage.PREPARED -> setOf(NasServiceStage.SUBMITTED, NasServiceStage.CANCELLED)
            NasServiceStage.SUBMITTED -> setOf(NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED, NasServiceStage.REJECTED)
            NasServiceStage.ACCEPTED -> setOf(NasServiceStage.VERIFIED, NasServiceStage.SUBMITTED, NasServiceStage.REJECTED)
            NasServiceStage.VERIFIED -> setOf(NasServiceStage.SUBMITTED)
            else -> emptySet()
        }
        if (event.stage !in allowed && !(event.stage == step.stage && event.task != null && step.stage in setOf(NasServiceStage.ACCEPTED, NasServiceStage.SUBMITTED))) serviceConflict()
        val task = event.task ?: step.task
        if (event.task != null) {
            if (!step.requiresTask || step.step != NasServiceStep.FIREWALL) serviceConflict()
            step.task?.let { previous ->
                if (task?.id != previous.id || previous.outcome != null && task.outcome != previous.outcome ||
                    previous.cleanupAttempted && !task.cleanupAttempted || previous.cleanupAccepted && !task.cleanupAccepted) serviceConflict()
            }
        }
        val accepted = step.accepted || event.stage == NasServiceStage.ACCEPTED
        if (step.step.requiresAcceptance && event.stage == NasServiceStage.VERIFIED && !accepted) serviceConflict()
        if (step.requiresTask && event.stage == NasServiceStage.VERIFIED && task?.outcome != true) serviceConflict()
        write(old.copy(steps = old.steps.map { if (it.step == event.step) it.copy(stage = event.stage, task = task, accepted = accepted) else it }))
    }
    /** 用户主动继续明确未完成的第二步；不能重发首步或未知请求。 */
    fun prepareContinuation(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        val step = old.continuationStep ?: serviceConflict()
        write(old.copy(steps = old.steps.map { if (it.step == step) it.copy(stage = NasServiceStage.PREPARED) else it }))
    }
    /** 用户已通过原连接配置在新地址重新登录，并明确选择同一 NAS；仅授权读取原结果。 */
    fun associateEthernet(owner: WorkspaceOwner, account: String, id: String) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: failure()
        if (!old.canAssociate(owner, account)) serviceConflict()
        write(old.copy(recoveryOwner = owner))
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (records(owner).singleOrNull { it.id == id }?.terminal != true) serviceConflict()
        if (!preferences.edit().remove(key(id)).commit()) failure()
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        if (active.any { it.first == profileId }) serviceConflict()
        val edit = preferences.edit(); all().filter { it.owner.profileId == profileId }.forEach { edit.remove(key(it.id)) }
        if (!edit.commit()) failure()
    }
    suspend fun <T> execute(owner: WorkspaceOwner, kind: NasServiceKind, block: suspend () -> T): T {
        val identity = owner.profileId to kind
        synchronized(lock) { if (!active.add(identity)) serviceConflict() }
        try { return block() } finally { synchronized(lock) { active.remove(identity) } }
    }
    private fun all(): List<NasServiceRecord> = try {
        if (failed) failure()
        preferences.all.filterKeys { it.startsWith("service:") }.map { (key, raw) ->
            json.decodeFromString<NasServiceRecord>(raw as? String ?: failure()).also { validate(it); if (key != key(it.id)) failure() }
        }
    } catch (_: Exception) { failure() }
    private fun validate(record: NasServiceRecord) {
        for (step in record.steps) {
            if (step.step.requiresAcceptance && step.stage == NasServiceStage.VERIFIED && !step.accepted ||
                step.accepted && step.stage in setOf(NasServiceStage.PREPARED, NasServiceStage.CANCELLED)) failure()
            if (step.requiresTask && step.step != NasServiceStep.FIREWALL || !step.requiresTask && step.task != null ||
                step.requiresTask && step.stage == NasServiceStage.VERIFIED && step.task?.outcome != true) failure()
            step.task?.let { task ->
                if (task.id.isBlank() || step.stage in setOf(NasServiceStage.PREPARED, NasServiceStage.CANCELLED) ||
                    task.cleanupAttempted && task.outcome == null || task.cleanupAccepted && !task.cleanupAttempted) failure()
            }
        }
        if (record.kind == NasServiceKind.ETHERNET) {
            if (record.targetId?.let(::isSafeEthernetId) != true || record.accountDigest?.let {
                    it.length == 64 && it.all { char -> char in "0123456789abcdef" } } != true ||
                record.recoveryOwner?.let { it.profileId != record.owner.profileId || it.sessionGeneration == record.owner.sessionGeneration } == true) failure()
        } else if (record.targetId != null || record.accountDigest != null || record.recoveryOwner != null) failure()
        if (record.version != 1 || record.id.isBlank() || record.createdAt < 0 || record.steps.isEmpty() ||
            record.steps.map { it.step }.distinct().size != record.steps.size || record.steps.any {
                it.targetDigest.length != 64 || it.targetDigest.any { char -> char !in "0123456789abcdef" } || when (record.kind) {
                    NasServiceKind.FILES -> it.step !in setOf(NasServiceStep.SMB, NasServiceStep.NFS, NasServiceStep.FTP, NasServiceStep.SFTP, NasServiceStep.WEB_DISCOVERY, NasServiceStep.TIME_MACHINE)
                    NasServiceKind.TERMINAL -> it.step != NasServiceStep.TERMINAL
                    NasServiceKind.PROXY -> it.step != NasServiceStep.PROXY
                    NasServiceKind.REMOTE_ACCESS -> it.step !in setOf(NasServiceStep.RELAY, NasServiceStep.ROUTER)
                    NasServiceKind.ETHERNET -> it.step != NasServiceStep.ETHERNET
                    NasServiceKind.SECURITY -> it.step !in setOf(NasServiceStep.AUTO_BLOCK, NasServiceStep.DOS, NasServiceStep.FIREWALL_NOTIFICATIONS, NasServiceStep.FIREWALL)
                    NasServiceKind.HARDWARE -> it.step !in hardwareSteps
                    NasServiceKind.MEMORY_COMPRESSION -> it.step !in setOf(NasServiceStep.ZRAM, NasServiceStep.REBOOT_REQUIRED)
                    NasServiceKind.POWER_SCHEDULE -> it.step != NasServiceStep.POWER_SCHEDULE
                }
            }) failure()
    }
    private fun write(record: NasServiceRecord) {
        validate(record)
        if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) failure()
    }
    private fun key(id: String) = "service:$id"
    private fun failure(): Nothing { failed = true; throw DsmFailure(null, "Service activity could not be saved", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED) }
    companion object { private val lock = Any(); private val active = mutableSetOf<Pair<String, NasServiceKind>>() }
}
