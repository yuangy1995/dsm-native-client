package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.CrossNasTransferCoordinator
import io.github.qwertyuiop1995.dsmnativeclient.data.CrossNasTransferEndpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import kotlinx.coroutines.*

/** 清单是恢复事实来源；恢复读取不会重放上传、建目录或删除。 */
internal class CrossNasTransferQueue(
    private val store: CrossNasTransferStore,
    private val plan: CrossNasTransferPlan = CrossNasTransferPlan(),
    private val stream: CrossNasTransferCoordinator = CrossNasTransferCoordinator(),
) {
    suspend fun create(source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint, roots: List<FileItem>,
        destination: FileItem, moveRequested: Boolean, sourceName: String, targetName: String): CrossNasTransferRecord = withContext(Dispatchers.IO) {
        val row = plan.prepare(source, target, roots, destination, moveRequested, sourceName, targetName)
        source.requireAccess(); target.requireAccess(); store.begin(row)
        row
    }
    suspend fun copy(id: String, source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint,
        onProgress: (Long, Long) -> Unit = { _, _ -> }, onChanged: (CrossNasTransferRecord) -> Unit = {}): CrossNasTransferRecord =
        operate(id, source, target, onChanged) { initial, save ->
            var row = initial
            if (!row.canContinueCopy) throw crossNasPending()
            plan.checkTree(source, row)
            row.entries.filter { it.state == CrossNasEntryState.COPIED }.forEach {
                plan.sourceItem(source, it); plan.targetItem(target, it)
            }
            row = save(row.copy(phase = CrossNasPhase.COPYING))
            val total = row.entries.filter { !it.source.directory }.fold(0L) { sum, entry -> Math.addExact(sum, entry.source.size) }
            var completed = row.entries.filter { it.state == CrossNasEntryState.COPIED && !it.source.directory }.sumOf { it.source.size }
            for (index in row.entries.indices) {
                val entry = row.entries[index]
                if (entry.state != CrossNasEntryState.PENDING) continue
                source.requireAccess(); target.requireAccess()
                val item = plan.sourceItem(source, entry)
                val parentPath = crossNasParent(entry.targetPath)
                val parent = target.findItem(parentPath) ?: throw crossNasChanged()
                if (!parent.isDirectory || !parent.canWrite || !parent.canRead || !isNormalFileMountType(parent.mountPointType)) throw crossNasChanged()
                if (parentPath == row.destination.path && !row.destination.matchesDirectory(parent)) throw crossNasChanged()
                if (plan.children(target, parentPath).any { it.path == entry.targetPath }) throw crossNasConflict()
                row = save(row.entry(index, CrossNasEntryState.WRITING))
                var sent = false
                val result = try {
                    currentCoroutineContext().ensureActive(); source.requireAccess(); target.requireAccess()
                    sent = true
                    if (item.isDirectory) target.createFolderResult(parent, item.name) else
                        stream.copyFile(source, target, item, parent.path) { bytes -> onProgress(completed + bytes, total) }
                } catch (error: Exception) {
                    if (!sent) row = save(row.entry(index, CrossNasEntryState.PENDING))
                    throw error
                }
                if (!result.submitted && result.status != MutationResultStatus.CONFIRMED_SUCCESS) {
                    row = save(row.entry(index, CrossNasEntryState.PENDING)); throw crossNasChanged()
                }
                if (item.isDirectory && result.status != MutationResultStatus.CONFIRMED_SUCCESS) throw crossNasPending()
                plan.sourceItem(source, entry); plan.targetItem(target, entry)
                if (item.isDirectory && plan.children(target, entry.targetPath).isNotEmpty()) throw crossNasChanged()
                row = save(row.entry(index, CrossNasEntryState.COPIED))
                if (!item.isDirectory) completed += item.size
                onProgress(completed, total)
            }
            verifyCopies(source, target, row)
            save(row.copy(phase = if (row.moveRequested) CrossNasPhase.COPIED else CrossNasPhase.FINISHED))
        }

    suspend fun review(id: String, source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint,
        onChanged: (CrossNasTransferRecord) -> Unit = {}): CrossNasTransferRecord = operate(id, source, target, onChanged) { initial, save ->
        if (initial.phase == CrossNasPhase.KEPT) return@operate initial
        var row = initial
        for (index in row.entries.indices) {
            val entry = row.entries[index]
            when (entry.state) {
                CrossNasEntryState.WRITE_UNKNOWN -> if (!entry.source.directory) {
                    plan.sourceItem(source, entry); plan.targetItem(target, entry)
                    row = save(row.entry(index, CrossNasEntryState.COPIED))
                }
                CrossNasEntryState.DELETE_UNKNOWN -> if (plan.children(source, crossNasParent(entry.source.path)).none { it.path == entry.source.path }) {
                    row = save(row.entry(index, CrossNasEntryState.REMOVED))
                }
                else -> Unit
            }
        }
        if (row.entries.all { it.state == CrossNasEntryState.REMOVED }) save(row.copy(phase = CrossNasPhase.FINISHED))
        else if (row.entries.all { it.state in setOf(CrossNasEntryState.COPIED, CrossNasEntryState.REMOVED) }) {
            verifyCopies(source, target, row)
            save(row.copy(phase = if (row.moveRequested) CrossNasPhase.COPIED else CrossNasPhase.FINISHED))
        } else row
    }

    suspend fun removeSource(id: String, source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint, confirmed: Boolean,
        onChanged: (CrossNasTransferRecord) -> Unit = {}): CrossNasTransferRecord = operate(id, source, target, onChanged) { initial, save ->
        var row = initial
        if (!confirmed || !row.canRemoveSource || !source.supportsSource(true)) throw crossNasChanged()
        verifyCopies(source, target, row)
        row = save(row.copy(phase = CrossNasPhase.REMOVING))
        // 先文件、后目录；每个目录只能非递归删除，新增子项会使该步停止。
        for (index in row.entries.indices.reversed()) {
            val entry = row.entries[index]
            if (entry.state == CrossNasEntryState.REMOVED) continue
            source.requireAccess(); target.requireAccess()
            plan.targetItem(target, entry)
            val item = plan.sourceItem(source, entry, deletingDirectory = directoryWasChangedByRemoval(row, entry))
            if (!item.canDelete || item.isDirectory && plan.children(source, item.path).isNotEmpty()) throw crossNasChanged()
            row = save(row.entry(index, CrossNasEntryState.DELETING))
            var sent = false
            val result = try {
                currentCoroutineContext().ensureActive(); source.requireAccess(); target.requireAccess()
                sent = true; source.deleteSingleResult(item)
            } catch (error: Exception) {
                if (!sent) row = save(row.entry(index, CrossNasEntryState.COPIED))
                throw error
            }
            if (!result.submitted) { row = save(row.entry(index, CrossNasEntryState.COPIED)); throw crossNasChanged() }
            if (plan.children(source, crossNasParent(item.path)).any { it.path == item.path }) throw crossNasPending()
            row = save(row.entry(index, CrossNasEntryState.REMOVED))
        }
        save(row.copy(phase = CrossNasPhase.FINISHED))
    }

    private suspend fun verifyCopies(source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint, row: CrossNasTransferRecord) {
        source.requireAccess(); target.requireAccess()
        plan.checkTree(source, row); plan.checkTargetTree(target, row)
        row.entries.forEach { entry ->
            plan.targetItem(target, entry)
            if (entry.state != CrossNasEntryState.REMOVED) plan.sourceItem(source, entry, directoryWasChangedByRemoval(row, entry))
        }
    }
    private fun directoryWasChangedByRemoval(row: CrossNasTransferRecord, entry: CrossNasEntry) = entry.source.directory &&
        row.entries.any { it.state == CrossNasEntryState.REMOVED && it.source.path.startsWith("${entry.source.path}/") }

    private suspend fun operate(id: String, source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint,
        onChanged: (CrossNasTransferRecord) -> Unit,
        block: suspend (CrossNasTransferRecord, (CrossNasTransferRecord) -> CrossNasTransferRecord) -> CrossNasTransferRecord,
    ): CrossNasTransferRecord = withContext(Dispatchers.IO) {
        CrossNasTransferStore.exclusive(id) {
            var row = store.get(id)
            if (!source.owner.hasSameIdentity(row.sourceOwner) || !target.owner.hasSameIdentity(row.targetOwner)) throw crossNasChanged()
            fun save(next: CrossNasTransferRecord): CrossNasTransferRecord {
                store.replace(row, next); row = next; onChanged(next); return next
            }
            if (row.interrupted() != row) save(row.interrupted())
            try {
                source.requireAccess(); target.requireAccess()
                block(row, ::save)
            } finally {
                // 取消后只保存阶段，不读取网络、不重放请求；保存失败保留上一次写前事实。
                withContext(NonCancellable) { if (row.interrupted() != row) save(row.interrupted()) }
            }
        }
    }
    private fun CrossNasTransferRecord.entry(index: Int, state: CrossNasEntryState) = copy(entries = entries.mapIndexed { i, entry ->
        if (i == index) entry.copy(state = state) else entry
    })
}
