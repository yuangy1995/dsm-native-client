package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val crossNasChanges = MutableStateFlow(0L)
internal val crossNasTransferChanges = crossNasChanges.asStateFlow()

/** 独立加密清单，写请求前同步保存事实；不迁移旧传输记录。 */
internal class CrossNasTransferStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_cross_nas_transfers",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    fun records(owner: WorkspaceOwner): List<CrossNasTransferRecord> = allRecords().filter { it.sourceOwner.hasSameIdentity(owner) }
    fun allRecords(): List<CrossNasTransferRecord> = synchronized(lock) {
        all().map { row ->
            if (row.id in active) row else row.interrupted().also { if (it != row) write(it) }
        }.sortedByDescending { it.createdAtSeconds }
    }
    fun get(id: String): CrossNasTransferRecord = synchronized(lock) {
        all().singleOrNull { it.id == id } ?: throw crossNasChanged()
    }
    fun begin(row: CrossNasTransferRecord) = synchronized(lock) {
        if (!valid(row) || row.phase != CrossNasPhase.PAUSED || row.entries.any { it.state != CrossNasEntryState.PENDING }) throw workspaceStorageFailure()
        if (all().any { old -> old.id == row.id || !old.isFinished && conflicts(old, row) }) throw crossNasPending()
        write(row)
    }
    fun replace(before: CrossNasTransferRecord, after: CrossNasTransferRecord) = synchronized(lock) {
        if (!valid(after)) throw workspaceStorageFailure()
        if (before.isFinished && before != after || !before.samePlan(after)) throw workspaceStorageFailure()
        if (before.entries.indices.any { !transition(before.entries[it].state, after.entries[it].state) }) throw workspaceStorageFailure()
        if (get(before.id) != before) throw workspaceStorageFailure()
        write(after)
    }
    fun keepOriginals(row: CrossNasTransferRecord): CrossNasTransferRecord = synchronized(lock) {
        if (!row.canRemoveSource || row.id in active) throw crossNasPending()
        row.copy(phase = CrossNasPhase.KEPT).also { replace(row, it) }
    }
    fun removeFinished(row: CrossNasTransferRecord) = synchronized(lock) {
        if (!row.isFinished || row.id in active || get(row.id) != row) throw crossNasPending()
        if (!preferences.edit().remove(key(row.id)).commit()) throw workspaceStorageFailure()
        crossNasChanges.update { it + 1 }
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val rows = all().filter { it.sourceOwner.profileId == profileId || it.targetOwner.profileId == profileId }
        if (rows.any { it.id in active }) throw crossNasPending()
        val editor = preferences.edit(); rows.forEach { editor.remove(key(it.id)) }
        if (rows.isNotEmpty()) {
            if (!editor.commit()) throw workspaceStorageFailure()
            crossNasChanges.update { it + 1 }
        }
    }
    private fun all(): List<CrossNasTransferRecord> = preferences.all.keys.filter { it.startsWith("cross_v1_") }.map { key ->
        val raw = preferences.getString(key, null) ?: throw workspaceStorageFailure()
        val row = runCatching { json.decodeFromString<CrossNasTransferRecord>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (key != key(row.id) || !valid(row)) throw workspaceStorageFailure()
        row
    }
    private fun write(row: CrossNasTransferRecord) {
        if (!preferences.edit().putString(key(row.id), json.encodeToString(row)).commit()) throw workspaceStorageFailure()
        crossNasChanges.update { it + 1 }
    }
    private fun key(id: String) = "cross_v1_$id"
    private fun conflicts(a: CrossNasTransferRecord, b: CrossNasTransferRecord): Boolean {
        fun overlaps(first: List<String>, second: List<String>) = first.any { x -> second.any { y -> mountPathsOverlap(x, y) } }
        return a.targetOwner.hasSameIdentity(b.targetOwner) && overlaps(a.entries.map { it.targetPath }, b.entries.map { it.targetPath }) ||
            a.sourceOwner.hasSameIdentity(b.sourceOwner) && overlaps(a.roots, b.roots) ||
            a.sourceOwner.hasSameIdentity(b.targetOwner) && overlaps(a.roots, b.entries.map { it.targetPath }) ||
            a.targetOwner.hasSameIdentity(b.sourceOwner) && overlaps(a.entries.map { it.targetPath }, b.roots)
    }
    private fun valid(row: CrossNasTransferRecord): Boolean {
        if (row.schemaVersion != 1 || runCatching { java.util.UUID.fromString(row.id) }.isFailure ||
            row.sourceOwner.profileId == row.targetOwner.profileId || row.entries.isEmpty() || row.roots.isEmpty() ||
            row.roots.distinct().size != row.roots.size || row.entries.map { it.source.path }.distinct().size != row.entries.size ||
            row.entries.map { it.targetPath }.distinct().size != row.entries.size || !row.destination.directory ||
            !isFileMutationPath(row.destination.path) || !isNormalFileMountType(row.destination.mountType)) return false
        if (row.phase == CrossNasPhase.KEPT && (!row.moveRequested || row.entries.none { it.state == CrossNasEntryState.COPIED } ||
            row.entries.any { it.state !in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED) })) return false
        if (row.phase == CrossNasPhase.FINISHED && row.entries.any {
            it.state != if (row.moveRequested) CrossNasEntryState.REMOVED else CrossNasEntryState.COPIED
        } || row.phase == CrossNasPhase.COPIED && (!row.moveRequested || row.entries.any {
            it.state !in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED)
        })) return false
        val seen = mutableSetOf<String>()
        return row.entries.all { entry ->
            val source = entry.source
            val root = row.roots.singleOrNull { source.path == it || source.path.startsWith("$it/") } ?: return false
            val rootName = root.substringAfterLast('/')
            val expected = crossNasJoin(row.destination.path, rootName) + source.path.removePrefix(root)
            val parentKnown = source.path == root || crossNasParent(source.path) in seen &&
                row.entries.any { it.source.path == crossNasParent(source.path) && it.source.directory }
            seen += source.path
            parentKnown && isFileMutationPath(source.path) && source.name == source.path.substringAfterLast('/') &&
                source.modifiedAt != null && source.size >= 0 && isNormalFileMountType(source.mountType) &&
                entry.targetPath == expected && isFileMutationPath(entry.targetPath) &&
                if (source.directory) entry.digest == null else entry.digest?.let(::crossNasDigest) == true
        } && row.roots.all { root -> row.entries.any { it.source.path == root } }
    }
    private fun transition(before: CrossNasEntryState, after: CrossNasEntryState) = before == after || when (before) {
        CrossNasEntryState.PENDING -> after == CrossNasEntryState.WRITING
        CrossNasEntryState.WRITING -> after in setOf(CrossNasEntryState.PENDING, CrossNasEntryState.COPIED, CrossNasEntryState.WRITE_UNKNOWN)
        CrossNasEntryState.COPIED -> after == CrossNasEntryState.DELETING
        CrossNasEntryState.WRITE_UNKNOWN -> after == CrossNasEntryState.COPIED
        CrossNasEntryState.DELETING -> after in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED, CrossNasEntryState.DELETE_UNKNOWN)
        CrossNasEntryState.DELETE_UNKNOWN -> after == CrossNasEntryState.REMOVED
        CrossNasEntryState.REMOVED -> false
    }
    companion object {
        private val lock = Any()
        private val active = mutableSetOf<String>()
        internal suspend fun <T> exclusive(id: String, block: suspend () -> T): T {
            synchronized(lock) { if (!active.add(id)) throw crossNasPending() }
            try { return block() } finally { synchronized(lock) { active.remove(id) } }
        }
    }
}
