package io.github.qwertyuiop1995.dsmnativeclient.ui

import io.github.qwertyuiop1995.dsmnativeclient.data.FileVFSDownloadSource
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import io.github.qwertyuiop1995.dsmnativeclient.DownloadEnqueueResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem

/** 系统保存页面返回前固定来源与账号代次，不保存凭据或本地目标 URI。 */
internal data class PendingDownloadRequest(
    val owner: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner,
    val items: List<FileItem>,
    val title: String,
    val vfsSource: FileVFSDownloadSource? = null,
) {
    val isArchive: Boolean get() = items.size > 1 || items.singleOrNull()?.isDirectory == true
}

internal fun pendingDownloadRequest(
    owner: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner, items: List<FileItem>, title: String,
) = PendingDownloadRequest(owner, items.distinctBy(FileItem::path).map {
    FileItem(path = it.path, name = it.name, isDirectory = it.isDirectory, size = it.size, canRead = it.canRead)
}, title)

internal data class PendingDownloadRequestState(val request: PendingDownloadRequest? = null)

internal fun PendingDownloadRequestState.toSaveableValues(): List<Any> {
    val pending = request ?: return emptyList()
    pending.vfsSource?.let { source ->
        return listOf("download-remote-v1", pending.owner.profileId, pending.owner.identityRevision,
            pending.owner.sessionGeneration, pending.title, Json.encodeToString(source))
    }
    return listOf("download-selection-v1", pending.owner.profileId, pending.owner.identityRevision,
        pending.owner.sessionGeneration, pending.title, pending.items.size) + pending.items.flatMap {
        listOf(it.path, it.name, it.isDirectory, it.size, it.canRead)
    }
}

internal fun pendingDownloadRequestStateFrom(values: List<Any>): PendingDownloadRequestState {
    val empty = PendingDownloadRequestState()
    if (values.firstOrNull() == "download-remote-v1") {
        if (values.size != 6 || values.any { it !is String }) return empty
        val owner = io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner(values[1] as String, values[2] as String, values[3] as String)
        val source = runCatching { Json.decodeFromString<FileVFSDownloadSource>(values[5] as String) }.getOrNull() ?: return empty
        if (source.profile.owner != owner || !source.valid()) return empty
        return PendingDownloadRequestState(PendingDownloadRequest(owner, listOf(source.item()), values[4] as String, source))
    }
    if (values.firstOrNull() != "download-selection-v1" || values.size < 6) return empty
    val count = values[5] as? Int ?: return empty
    if (count <= 0 || count != (values.size - 6) / 5 || (values.size - 6) % 5 != 0) return empty
    val profile = values[1] as? String ?: return empty
    val identity = values[2] as? String ?: return empty
    val generation = values[3] as? String ?: return empty
    val title = values[4] as? String ?: return empty
    val items = values.drop(6).chunked(5).map {
        FileItem(path = it[0] as? String ?: return empty, name = it[1] as? String ?: return empty,
            isDirectory = it[2] as? Boolean ?: return empty, size = it[3] as? Long ?: return empty,
            canRead = it[4] as? Boolean ?: return empty)
    }
    return PendingDownloadRequestState(PendingDownloadRequest(
        io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner(profile, identity, generation), items, title))
}

internal val PendingDownloadRequestStateSaver: Saver<PendingDownloadRequestState, Any> = listSaver(
    save = { state -> state.toSaveableValues() }, restore = ::pendingDownloadRequestStateFrom,
)

internal enum class DownloadDestinationDecision {
    CANCELLED,
    ENQUEUE,
    DISCARD_ORPHAN,
}

internal data class ResolvedDownloadDestination(
    val decision: DownloadDestinationDecision,
    val request: PendingDownloadRequest? = null,
    val nextPending: PendingDownloadRequestState = PendingDownloadRequestState(),
)

/** 每个选择器结果只消费一次；调用方在执行决策前清空已保存请求。 */
internal fun resolveDownloadDestination(
    pending: PendingDownloadRequestState,
    activeOwner: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner?,
    destinationSelected: Boolean,
): ResolvedDownloadDestination {
    if (!destinationSelected) {
        return ResolvedDownloadDestination(DownloadDestinationDecision.CANCELLED)
    }
    val request = pending.request
    return if (request != null && request.owner == activeOwner) {
        ResolvedDownloadDestination(DownloadDestinationDecision.ENQUEUE, request)
    } else {
        ResolvedDownloadDestination(DownloadDestinationDecision.DISCARD_ORPHAN)
    }
}

internal fun shouldRequestDownloadNotificationPermission(
    enqueueResult: DownloadEnqueueResult,
    sdkInt: Int,
    notificationPermissionGranted: Boolean,
): Boolean = enqueueResult == DownloadEnqueueResult.BACKGROUND &&
    sdkInt >= 33 &&
    !notificationPermissionGranted
