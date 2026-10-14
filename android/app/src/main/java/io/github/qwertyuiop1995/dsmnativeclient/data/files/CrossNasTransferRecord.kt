package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable internal enum class CrossNasEntryState { PENDING, WRITING, COPIED, WRITE_UNKNOWN, DELETING, REMOVED, DELETE_UNKNOWN }
@Serializable internal enum class CrossNasPhase { PAUSED, COPYING, COPIED, REMOVING, FINISHED, INTERRUPTED, KEPT }

/** 只保存恢复必需的元数据；不含凭据、NAS 地址、文件内容或原始响应。 */
@Serializable internal data class CrossNasFileSnapshot(
    val path: String, val name: String, val directory: Boolean, val size: Long,
    val modifiedAt: Long?, val mountType: String?,
) {
    constructor(item: FileItem) : this(item.path, item.name, item.isDirectory, item.size,
        item.modifiedAtEpochSeconds, item.mountPointType)
    fun matches(item: FileItem) = path == item.path && name == item.name && directory == item.isDirectory &&
        (directory || size == item.size) && modifiedAt == item.modifiedAtEpochSeconds && mountType == item.mountPointType
    fun matchesDirectory(item: FileItem) = path == item.path && name == item.name && directory && item.isDirectory && mountType == item.mountPointType
    override fun toString() = "CrossNasFileSnapshot(directory=$directory)"
}
@Serializable internal data class CrossNasEntry(
    val source: CrossNasFileSnapshot, val targetPath: String, val digest: String?,
    val state: CrossNasEntryState = CrossNasEntryState.PENDING,
) { override fun toString() = "CrossNasEntry($state)" }
@Serializable internal data class CrossNasTransferRecord(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(),
    val sourceOwner: WorkspaceOwner, val targetOwner: WorkspaceOwner,
    val sourceName: String, val targetName: String, val destination: CrossNasFileSnapshot,
    val moveRequested: Boolean, val roots: List<String>, val entries: List<CrossNasEntry>,
    val phase: CrossNasPhase = CrossNasPhase.PAUSED,
    val createdAtSeconds: Long = System.currentTimeMillis() / 1_000,
) {
    val isFinished get() = phase in setOf(CrossNasPhase.FINISHED, CrossNasPhase.KEPT)
    val hasUnknown get() = entries.any { it.state in setOf(CrossNasEntryState.WRITING, CrossNasEntryState.WRITE_UNKNOWN,
        CrossNasEntryState.DELETING, CrossNasEntryState.DELETE_UNKNOWN) }
    val canContinueCopy get() = phase in setOf(CrossNasPhase.PAUSED, CrossNasPhase.INTERRUPTED) && !hasUnknown &&
        entries.any { it.state == CrossNasEntryState.PENDING } && entries.all { it.state in setOf(CrossNasEntryState.PENDING, CrossNasEntryState.COPIED) }
    val canRemoveSource get() = moveRequested && !hasUnknown && phase in setOf(CrossNasPhase.COPIED, CrossNasPhase.INTERRUPTED) &&
        entries.all { it.state in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED) } && entries.any { it.state == CrossNasEntryState.COPIED }
    fun interrupted(): CrossNasTransferRecord = copy(
        phase = if (phase in setOf(CrossNasPhase.COPYING, CrossNasPhase.REMOVING)) CrossNasPhase.INTERRUPTED else phase,
        entries = entries.map { it.copy(state = when (it.state) {
            CrossNasEntryState.WRITING -> CrossNasEntryState.WRITE_UNKNOWN
            CrossNasEntryState.DELETING -> CrossNasEntryState.DELETE_UNKNOWN
            else -> it.state
        }) },
    )
    fun samePlan(other: CrossNasTransferRecord) = copy(phase = other.phase,
        entries = entries.mapIndexed { index, entry -> entry.copy(state = other.entries.getOrNull(index)?.state ?: entry.state) }) == other
    override fun toString() = "CrossNasTransferRecord($phase, entries=${entries.size})"
}

internal fun crossNasChanged() = DsmFailure(null, "The selected files changed", "Refresh the transfer and check both locations.", kind = DsmErrorKind.CROSS_NAS_CHANGED)
internal fun crossNasPending() = DsmFailure(null, "A related transfer needs attention", "Open transfers and refresh the earlier transfer.", kind = DsmErrorKind.CROSS_NAS_PENDING)
internal fun crossNasConflict() = DsmFailure(null, "The destination already contains this name", "Choose a different folder.", kind = DsmErrorKind.CROSS_NAS_CONFLICT)
internal fun crossNasReadFailure() = DsmFailure(null, "The full file list could not be read", "Refresh the transfer and try again.", kind = DsmErrorKind.CROSS_NAS_INCOMPLETE)
internal fun crossNasParent(path: String) = path.substringBeforeLast('/').ifEmpty { "/" }
internal fun crossNasJoin(parent: String, name: String) = if (parent == "/") "/$name" else "$parent/$name"
internal fun crossNasDigest(value: String) = value.matches(Regex("[a-f0-9]{32}"))
