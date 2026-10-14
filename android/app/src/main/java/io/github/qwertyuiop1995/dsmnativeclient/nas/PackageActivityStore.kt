package io.github.qwertyuiop1995.dsmnativeclient.nas

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import java.security.MessageDigest
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

@Serializable internal enum class PackageActivityKind { SETTINGS, SOURCE, INSTALL, CONTROL }
@Serializable internal enum class PackageActivityPhase { READY, SUBMITTED, PREPARED, COMPLETED, REJECTED, CANCELLED, INTERRUPTED }
@Serializable internal data class PackageActivityItem(
    val packageId: String = "", val originalVersion: String? = null, val version: String = "",
    val phase: PackageActivityPhase = PackageActivityPhase.READY, val step: String = "", val accepted: Boolean = false,
)
/** 仅记录账号、公开套件标识/版本和摘要；不保存 taskid、来源地址、暂存路径或安装密码。 */
@Serializable internal data class PackageActivityRecord(
    val id: String, val owner: WorkspaceOwner, val kind: PackageActivityKind, val items: List<PackageActivityItem>,
    val expectedDigest: String = "", val sourceAddressDigest: String = "", val previousAddressDigest: String = "",
    val createdAt: Long = System.currentTimeMillis(), val version: Int = 1,
) {
    val terminal get() = items.all { it.phase in setOf(PackageActivityPhase.COMPLETED, PackageActivityPhase.REJECTED, PackageActivityPhase.CANCELLED, PackageActivityPhase.INTERRUPTED) }
    override fun toString() = "PackageActivityRecord($kind, ${items.size}, $terminal)"
}
internal class PackageActivityStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_package_activity",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV, EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { encodeDefaults = true }
    private var failed = false
    private val pendingControls = mutableSetOf<String>()
    fun records(owner: WorkspaceOwner): List<PackageActivityRecord> = synchronized(lock) {
        all().filter { it.owner.hasSameIdentity(owner) }.sortedByDescending { it.createdAt }
    }
    fun begin(record: PackageActivityRecord) = synchronized(lock) {
        val values = all()
        if (values.any { it.id == record.id || it.owner.hasSameIdentity(record.owner) && !it.terminal }) busy()
        if (record.items.any { it.phase != PackageActivityPhase.READY }) failure()
        write(record)
    }
    fun get(owner: WorkspaceOwner, id: String): PackageActivityRecord = synchronized(lock) {
        records(owner).singleOrNull { it.id == id } ?: failure()
    }
    fun checkpoint(owner: WorkspaceOwner, event: NasPackageCheckpoint) = synchronized(lock) {
        val record = get(owner, event.operationId)
        if (event.total != record.items.size || event.index !in record.items.indices) failure()
        val old = record.items[event.index]
        if (record.kind == PackageActivityKind.CONTROL) {
            if (owner != record.owner || event.step.name != old.step || event.entry != null ||
                event.stage == NasPackageWriteStage.WILL_SUBMIT && old.phase != PackageActivityPhase.READY ||
                event.stage in setOf(NasPackageWriteStage.ACCEPTED, NasPackageWriteStage.REJECTED, NasPackageWriteStage.VERIFIED) && old.phase != PackageActivityPhase.SUBMITTED ||
                event.stage == NasPackageWriteStage.PREPARED) failure()
        }
        if (old.phase == PackageActivityPhase.CANCELLED && old.step == NasPackageWriteStep.CLEANUP.name &&
            event.step == NasPackageWriteStep.CANCEL_DOWNLOAD && event.stage == NasPackageWriteStage.VERIFIED) return@synchronized
        if (old.phase in setOf(PackageActivityPhase.COMPLETED, PackageActivityPhase.REJECTED, PackageActivityPhase.CANCELLED, PackageActivityPhase.INTERRUPTED)) failure()
        val entry = event.entry
        if (record.kind == PackageActivityKind.INSTALL && entry != null && old.packageId.isNotEmpty() &&
            (entry.packageId != old.packageId || entry.version != old.version || entry.installedVersion != old.originalVersion)) failure()
        val expectedStep = event.step.name
        if (event.stage !in setOf(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.NOT_SUBMITTED) && old.step != expectedStep) {
            // 下载在取消流程完成后可以结算原取消动作；其余阶段须属于当前提交。
            if (!(event.step == NasPackageWriteStep.CANCEL_DOWNLOAD && event.stage == NasPackageWriteStage.VERIFIED && old.step == NasPackageWriteStep.CLEANUP.name)) failure()
        }
        if (event.stage == NasPackageWriteStage.WILL_SUBMIT && old.step == expectedStep && old.phase == PackageActivityPhase.SUBMITTED) failure()
        if (event.stage == NasPackageWriteStage.NOT_SUBMITTED && old.phase != PackageActivityPhase.READY) failure()
        val phase = when (event.stage) {
            NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStage.ACCEPTED -> PackageActivityPhase.SUBMITTED
            NasPackageWriteStage.PREPARED -> PackageActivityPhase.PREPARED
            NasPackageWriteStage.REJECTED -> PackageActivityPhase.REJECTED
            NasPackageWriteStage.NOT_SUBMITTED -> PackageActivityPhase.CANCELLED
            NasPackageWriteStage.VERIFIED -> if (event.step in setOf(NasPackageWriteStep.CLEANUP, NasPackageWriteStep.CANCEL_DOWNLOAD)) PackageActivityPhase.CANCELLED else PackageActivityPhase.COMPLETED
        }
        val next = old.copy(packageId = entry?.packageId ?: old.packageId, version = entry?.version ?: old.version,
            originalVersion = entry?.installedVersion ?: old.originalVersion, phase = phase, step = expectedStep,
            accepted = event.stage != NasPackageWriteStage.WILL_SUBMIT && (old.accepted || event.stage == NasPackageWriteStage.ACCEPTED))
        val items = record.items.toMutableList().also { it[event.index] = next }
        if (phase in setOf(PackageActivityPhase.REJECTED, PackageActivityPhase.CANCELLED)) {
            for (i in event.index + 1 until items.size) if (items[i].phase == PackageActivityPhase.READY) items[i] = items[i].copy(phase = PackageActivityPhase.CANCELLED)
        }
        write(record.copy(items = items))
    }
    /** 恢复只允许结算已发送的正式安装或设置；未发送的依赖终止，绝不补发。 */
    fun completeRecovered(owner: WorkspaceOwner, id: String, completed: Set<Int>) = synchronized(lock) {
        val record = get(owner, id)
        val items = record.items.mapIndexed { index, item -> when {
            index in completed && item.phase == PackageActivityPhase.SUBMITTED -> item.copy(phase = PackageActivityPhase.COMPLETED)
            item.phase == PackageActivityPhase.READY -> item.copy(phase = PackageActivityPhase.CANCELLED)
            else -> item
        } }
        if (completed.any { it !in record.items.indices }) failure()
        write(record.copy(items = items))
    }
    /** 跨进程仅结束未进入正式安装的本机准备；不声称 NAS 下载或暂存文件已经取消/清理。 */
    fun interruptPreparation(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (owner.profileId in active) return@synchronized
        val record = get(owner, id)
        if (record.kind != PackageActivityKind.INSTALL || record.items.any {
            it.phase == PackageActivityPhase.SUBMITTED && it.step == NasPackageWriteStep.INSTALL.name
        }) return@synchronized
        write(record.copy(items = record.items.map { item ->
            if (item.phase in setOf(PackageActivityPhase.READY, PackageActivityPhase.SUBMITTED, PackageActivityPhase.PREPARED)) item.copy(phase = PackageActivityPhase.INTERRUPTED) else item
        }))
    }
    fun discard(owner: WorkspaceOwner, id: String) = synchronized(lock) {
        if (!get(owner, id).terminal) failure()
        if (!preferences.edit().remove(key(id)).commit()) failure()
        pendingControls.remove(id)
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.owner.profileId == profileId }
        if (profileId in active) failure()
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (!editor.commit()) failure()
        pendingControls.removeAll(rows.map { it.id }.toSet())
    }
    suspend fun <T> execute(owner: WorkspaceOwner, block: suspend () -> T): T {
        val id = owner.profileId
        synchronized(lock) { if (!active.add(id)) busy() }
        try { return block() } finally { synchronized(lock) { active.remove(id) } }
    }
    private fun all(): List<PackageActivityRecord> = try {
        if (failed) failure()
        val values = preferences.all.filterKeys { it.startsWith("package:") }.map { (key, raw) ->
            val value = json.decodeFromString<PackageActivityRecord>(raw as? String ?: failure())
            validate(value); if (key != key(value.id)) failure(); value
        }
        if (pendingControls.any { id -> values.none { it.id == id } }) failure()
        pendingControls.clear(); pendingControls.addAll(values.filter { it.kind == PackageActivityKind.CONTROL && !it.terminal }.map { it.id })
        values
    } catch (_: Exception) { failed = true; failure() }
    private fun validate(record: PackageActivityRecord) {
        if (record.kind == PackageActivityKind.CONTROL && (record.items.size != 1 || record.expectedDigest.length != 64 ||
            record.items.any { it.packageId.isBlank() || it.version.isBlank() || it.step !in setOf("START", "STOP", "UNINSTALL") ||
                it.phase in setOf(PackageActivityPhase.PREPARED, PackageActivityPhase.INTERRUPTED) })) failure()
        if (record.id.isBlank() || record.version != 1 || record.items.isEmpty() || record.createdAt < 0 ||
            listOf(record.expectedDigest, record.sourceAddressDigest, record.previousAddressDigest).any { it.isNotEmpty() && (it.length != 64 || it.any { char -> char !in "0123456789abcdef" }) } ||
            record.items.any { it.step.isNotEmpty() && it.step !in NasPackageWriteStep.entries.map { step -> step.name } || it.accepted && it.phase == PackageActivityPhase.READY }) failure()
    }
    private fun write(record: PackageActivityRecord) {
        validate(record)
        if (!preferences.edit().putString(key(record.id), json.encodeToString(record)).commit()) { failed = true; failure() }
        if (record.kind == PackageActivityKind.CONTROL && !record.terminal) pendingControls.add(record.id) else pendingControls.remove(record.id)
    }
    private fun key(id: String) = "package:$id"
    private fun failure(): Nothing = throw DsmFailure(null, "Package activity could not be saved on this device", "Free up space and try again.", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
    private fun busy(): Nothing = throw DsmFailure(null, "A package operation is still updating", "Open package activity and refresh its status.", kind = DsmErrorKind.WORKSPACE_BUSY)
    companion object { private val lock = Any(); private val active = mutableSetOf<String>() }
}
internal fun packageDigest(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
internal fun preferencesDigest(value: NasPackagePreferences): String = packageDigest(buildJsonObject {
    put("beta", value.beta); put("email", value.email); put("desktop", value.desktop); put("policy", value.policy.name); put("volume", value.defaultVolume)
    if (value.policy == NasPackageUpdatePolicy.SELECTED) put("packages", JsonArray(value.packages.filter { it.policy != NasPackageUpdatePolicy.MANUAL }.sortedBy { it.id }.map {
        buildJsonObject { put("id", it.id); put("policy", it.policy?.name) }
    }))
}.toString())
internal fun sourceDigest(value: NasPackageSource) = packageDigest(JsonArray(listOf(JsonPrimitive(value.name), JsonPrimitive(value.url))).toString())
