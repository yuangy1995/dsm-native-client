package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.CrossNasTransferEndpoint
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal class CrossNasTransferPlan {
    suspend fun prepare(source: CrossNasTransferEndpoint, target: CrossNasTransferEndpoint, roots: List<FileItem>,
        destination: FileItem, moveRequested: Boolean, sourceName: String, targetName: String): CrossNasTransferRecord {
        source.requireAccess(); target.requireAccess()
        if (source.owner.profileId == target.owner.profileId || !source.supportsSource(moveRequested) ||
            !target.supportsTarget(roots.any { it.isDirectory })) throw crossNasChanged()
        if (roots.isEmpty() || roots.map { it.path }.distinct().size != roots.size || roots.any { a ->
            roots.any { b -> a.path != b.path && mountPathsOverlap(a.path, b.path) } } ||
            roots.map { it.name }.distinct().size != roots.size) throw crossNasChanged()
        val destinationFresh = target.findItem(destination.path) ?: throw crossNasChanged()
        if (!CrossNasFileSnapshot(destination).matches(destinationFresh) || !destinationFresh.isDirectory ||
            !destinationFresh.canWrite || !destinationFresh.canRead || !isNormalFileMountType(destinationFresh.mountPointType)) throw crossNasChanged()
        if (children(target, destination.path).any { item -> roots.any { it.name == item.name } }) throw crossNasConflict()
        val entries = mutableListOf<CrossNasEntry>()
        val queue = ArrayDeque<Pair<FileItem, String>>()
        roots.forEach { queue.add(it to crossNasJoin(destination.path, it.name)) }
        while (queue.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val (baseline, targetPath) = queue.removeFirst()
            val item = source.findItem(baseline.path) ?: throw crossNasChanged()
            if (!CrossNasFileSnapshot(baseline).matches(item) || !item.canRead ||
                moveRequested && !item.canDelete || item.size < 0 || item.modifiedAtEpochSeconds == null ||
                !isNormalFileMountType(item.mountPointType)) throw crossNasChanged()
            val digest = if (item.isDirectory) null else source.contentDigest(item.path).also {
                if (!crossNasDigest(it)) throw crossNasReadFailure()
            }
            if (source.findItem(item.path)?.let(CrossNasFileSnapshot(item)::matches) != true) throw crossNasChanged()
            entries += CrossNasEntry(CrossNasFileSnapshot(item), targetPath, digest)
            if (item.isDirectory) children(source, item.path).forEach { queue.add(it to crossNasJoin(targetPath, it.name)) }
        }
        val record = CrossNasTransferRecord(sourceOwner = source.owner, targetOwner = target.owner,
            sourceName = sourceName, targetName = targetName, destination = CrossNasFileSnapshot(destinationFresh),
            moveRequested = moveRequested, roots = roots.map { it.path }, entries = entries)
        checkTree(source, record)
        return record
    }
    suspend fun children(endpoint: CrossNasTransferEndpoint, path: String): List<FileItem> {
        var total: Int? = null
        val result = mutableListOf<FileItem>()
        val paths = mutableSetOf<String>()
        do {
            currentCoroutineContext().ensureActive()
            val page = endpoint.listDirectory(path, result.size, 200)
            if (page.offset != result.size || page.total < result.size + page.items.size || page.items.size > 200 ||
                total != null && total != page.total || page.items.isEmpty() && result.size != page.total || page.items.any {
                    !isFileMutationPath(it.path) || crossNasParent(it.path) != path || it.name != it.path.substringAfterLast('/') || !paths.add(it.path)
                }) throw crossNasReadFailure()
            total = page.total; result += page.items
        } while (result.size < total!!)
        return result
    }
    suspend fun sourceItem(endpoint: CrossNasTransferEndpoint, entry: CrossNasEntry, deletingDirectory: Boolean = false): FileItem {
        val item = endpoint.findItem(entry.source.path) ?: throw crossNasChanged()
        if (!(if (deletingDirectory) entry.source.matchesDirectory(item) else entry.source.matches(item)) ||
            !item.canRead || !isNormalFileMountType(item.mountPointType)) throw crossNasChanged()
        if (!item.isDirectory && endpoint.contentDigest(item.path) != entry.digest) throw crossNasChanged()
        if (endpoint.findItem(item.path)?.let(CrossNasFileSnapshot(item)::matches) != true) throw crossNasChanged()
        return item
    }
    suspend fun targetItem(endpoint: CrossNasTransferEndpoint, entry: CrossNasEntry): FileItem {
        val item = endpoint.findItem(entry.targetPath) ?: throw crossNasChanged()
        if (item.isDirectory != entry.source.directory || !item.canRead || !isNormalFileMountType(item.mountPointType) ||
            !item.isDirectory && (item.size != entry.source.size || endpoint.contentDigest(item.path) != entry.digest)) throw crossNasChanged()
        if (endpoint.findItem(item.path)?.let(CrossNasFileSnapshot(item)::matches) != true) throw crossNasChanged()
        return item
    }
    suspend fun checkTree(source: CrossNasTransferEndpoint, row: CrossNasTransferRecord) {
        row.entries.filter { it.source.directory && it.state != CrossNasEntryState.REMOVED }.forEach { parent ->
            val expected = row.entries.filter { crossNasParent(it.source.path) == parent.source.path && it.state != CrossNasEntryState.REMOVED }.map { it.source.path }.toSet()
            if (children(source, parent.source.path).map { it.path }.toSet() != expected) throw crossNasChanged()
        }
    }
    suspend fun checkTargetTree(target: CrossNasTransferEndpoint, row: CrossNasTransferRecord) {
        row.entries.filter { it.source.directory }.forEach { parent ->
            val expected = row.entries.filter { crossNasParent(it.targetPath) == parent.targetPath }.map { it.targetPath }.toSet()
            if (children(target, parent.targetPath).map { it.path }.toSet() != expected) throw crossNasChanged()
        }
    }
}
