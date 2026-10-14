package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable internal data class VmmCreationActivity(val owner: WorkspaceOwner, val snapshot: VmmCreationSnapshot,
    val progress: VmmCreationProgress = VmmCreationProgress(), val writerGeneration: String = owner.sessionGeneration,
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1) {
    val id get() = snapshot.id
    val pending get() = progress.stage.pending
    override fun toString() = "VmmCreationActivity(${progress.stage})"
}

/** 保存继续尚未发送步骤所需的最小配置，不保存凭据、原始响应或创建前 VM 身份明文。 */
internal class VmmCreationStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_vmm_creation",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }; private var failed = false
    fun records(owner: WorkspaceOwner) = synchronized(lock) { all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt } }
    fun begin(record: VmmCreationActivity) = synchronized(lock) {
        if (record.progress != VmmCreationProgress() || all().any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && it.pending &&
            it.snapshot.plan.configuration.name.equals(record.snapshot.plan.configuration.name, ignoreCase = true) }) vmmConflict()
        write(record)
    }
    fun checkpoint(owner: WorkspaceOwner, id: String, progress: VmmCreationProgress) = synchronized(lock) {
        val old = records(owner).singleOrNull { it.id == id } ?: storageFailure()
        val previous = old.progress; val source = old.snapshot.plan.source
        val allowed = when (previous.stage) {
            VmmCreationStage.PREPARED -> if (old.owner == owner) setOf(VmmCreationStage.CREATE_SENT, VmmCreationStage.CANCELLED) else setOf(VmmCreationStage.CANCELLED)
            VmmCreationStage.CREATE_SENT -> setOf(VmmCreationStage.CREATING, VmmCreationStage.REJECTED)
            VmmCreationStage.CREATING -> setOf(VmmCreationStage.CREATING, VmmCreationStage.CREATED, VmmCreationStage.REJECTED)
            VmmCreationStage.CREATED -> if (source == VmmSource.PUBLIC && previous.baseline != old.snapshot.plan.configuration) setOf(VmmCreationStage.CONFIGURE_SENT)
                else setOf(VmmCreationStage.CONFIGURED)
            VmmCreationStage.CONFIGURE_SENT -> setOf(VmmCreationStage.CONFIGURING, VmmCreationStage.PARTIAL)
            VmmCreationStage.CONFIGURING -> setOf(VmmCreationStage.CONFIGURED)
            VmmCreationStage.CONFIGURED -> if (old.snapshot.plan.powerOn) setOf(VmmCreationStage.POWER_SENT) else setOf(VmmCreationStage.COMPLETE)
            VmmCreationStage.POWER_SENT -> setOf(VmmCreationStage.STARTING, VmmCreationStage.PARTIAL)
            VmmCreationStage.STARTING -> setOf(VmmCreationStage.COMPLETE)
            else -> emptySet()
        }
        val receipt = previous.stage in setOf(VmmCreationStage.CREATE_SENT, VmmCreationStage.CONFIGURE_SENT, VmmCreationStage.POWER_SENT)
        if (progress.stage !in allowed || receipt && old.writerGeneration != owner.sessionGeneration &&
            !(source == VmmSource.INTERNAL && previous.stage == VmmCreationStage.CREATE_SENT && progress.stage == VmmCreationStage.CREATING)) vmmConflict()
        if (previous.task != null && progress.task != previous.task || previous.guest != null && progress.guest != previous.guest ||
            previous.hardware != null && progress.hardware != previous.hardware || previous.baseline != null && progress.baseline != previous.baseline) vmmConflict()
        val sending = progress.stage in setOf(VmmCreationStage.CREATE_SENT, VmmCreationStage.CONFIGURE_SENT, VmmCreationStage.POWER_SENT)
        write(old.copy(progress = progress, writerGeneration = if (sending) owner.sessionGeneration else old.writerGeneration))
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
    private fun all(): List<VmmCreationActivity> = try {
        if (failed) storageFailure()
        preferences.all.filterKeys { it.startsWith("creation:") }.map { (key, raw) ->
            json.decodeFromString<VmmCreationActivity>(raw as? String ?: storageFailure()).also { validate(it); if (key != key(it.id)) storageFailure() }
        }
    } catch (_: Exception) { storageFailure() }
    private fun validate(record: VmmCreationActivity) {
        fun digest(value: String) = value.length == 64 && value.all { it in "0123456789abcdef" }
        val snapshot = record.snapshot; val progress = record.progress
        if (record.version != 1 || record.createdAt < 0 || !snapshot.plan.valid() || record.writerGeneration.isBlank() ||
            runCatching { UUID.fromString(record.id) }.isFailure || !digest(snapshot.parameters) || snapshot.existingIds.any { !digest(it) } ||
            snapshot.plan.source == VmmSource.INTERNAL && snapshot.expected?.let(::digest) != true ||
            snapshot.plan.source == VmmSource.PUBLIC && snapshot.expected != null ||
            progress.task?.let { !validVmmId(it) } == true || progress.guest?.let { !validVmmId(it) || vmmDigest(it) in snapshot.existingIds } == true ||
            progress.hardware?.let { !digest(it) } == true || progress.percent?.let { it !in 0..100 } == true) storageFailure()
        if (progress.stage in setOf(VmmCreationStage.CREATING, VmmCreationStage.CREATED, VmmCreationStage.CONFIGURE_SENT, VmmCreationStage.CONFIGURING,
                VmmCreationStage.CONFIGURED, VmmCreationStage.POWER_SENT, VmmCreationStage.STARTING, VmmCreationStage.COMPLETE, VmmCreationStage.PARTIAL) && progress.task == null) storageFailure()
        if (progress.stage in setOf(VmmCreationStage.CREATED, VmmCreationStage.CONFIGURE_SENT, VmmCreationStage.CONFIGURING, VmmCreationStage.CONFIGURED,
                VmmCreationStage.POWER_SENT, VmmCreationStage.STARTING, VmmCreationStage.COMPLETE, VmmCreationStage.PARTIAL) &&
            (progress.guest == null || progress.hardware == null || progress.baseline == null)) storageFailure()
    }
    private fun write(record: VmmCreationActivity) { validate(record); if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) storageFailure() }
    private fun key(id: String) = "creation:$id"
    private fun storageFailure(): Nothing { failed = true; throw VmmFailure(VmmProblem.STORAGE) }
    companion object { private val lock = Any() }
}
