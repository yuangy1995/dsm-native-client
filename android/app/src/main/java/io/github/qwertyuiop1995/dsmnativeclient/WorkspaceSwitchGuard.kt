package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedDownload
import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedUpload
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoUploadStore
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoEditStore
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoAlbumStore
import io.github.qwertyuiop1995.dsmnativeclient.photos.SynologyPhotoDeletionStore

internal fun workspaceSwitchIsBlocked(state: WorkspaceState, store: TransferStore): Boolean {
    val profileId = state.profile.id
    val retired = store.servers(profileId).filter {
        it.state == TransferState.PAUSED && it.errorKind == DsmErrorKind.WORKSPACE_CHANGED.name
    }.mapTo(mutableSetOf()) { it.id }
    return workspaceSwitchIsBlocked(state, store.downloads(profileId), store.uploads(profileId), retired,
        photosUploading = SynologyPhotoUploadStore.isProfileBusy(profileId), photosEditing = SynologyPhotoEditStore.isProfileBusy(profileId),
        photosAlbumWriting = SynologyPhotoAlbumStore.isProfileBusy(profileId), photosDeleting = SynologyPhotoDeletionStore.isProfileBusy(profileId))
}

/** 未迁移的写操作沿用原切换保护；已因身份不符暂停的旧记录不占用新账号。 */
internal fun workspaceSwitchIsBlocked(
    state: WorkspaceState,
    downloads: List<PersistedDownload>,
    uploads: List<PersistedUpload>,
    retiredServerIds: Set<String> = emptySet(),
    photosUploading: Boolean = false,
    photosEditing: Boolean = false,
    photosAlbumWriting: Boolean = false,
    photosDeleting: Boolean = false,
): Boolean {
    val retiredDownloads = downloads.filter { it.state == TransferState.PAUSED && it.errorKind == DsmErrorKind.WORKSPACE_CHANGED.name }
    val retiredUploads = uploads.filter { it.state == TransferState.PAUSED && it.errorKind == DsmErrorKind.WORKSPACE_CHANGED.name }
    val retiredIds = retiredServerIds + retiredDownloads.map { it.id } + retiredUploads.map { it.id }
    val chatMutation = chatMutationBlocksWorkspaceExit(state.chatMutationState) ||
        state.chatOutgoingMessages.values.flatten().any { it.deliveryState == ChatDeliveryState.SENDING } ||
        (state.chatMessages as? Loadable.Ready)?.value?.messages.orEmpty().any { it.deliveryState == ChatDeliveryState.SENDING }
    return photosUploading || photosEditing || photosAlbumWriting || photosDeleting || state.hasBlockingStructuredNasMutation() ||
        fileStationMutationBlocksWorkspaceExit(state.fileStationMutationState) ||
        downloadCreationBlocksWorkspaceExit(state.downloadCreationState) ||
        downloadControlBlocksWorkspaceExit(state.downloadControlState) ||
        downloadDestinationEditBlocksWorkspaceExit(state.downloadDestinationEditState) ||
        downloadSettingsBlocksWorkspaceExit(state.downloadSettingsState) ||
        downloadRssRefreshBlocksWorkspaceExit(state.downloadRssRefreshState) ||
        virtualMachineMutationBlocksWorkspaceExit(state.virtualMachineMutationState) ||
        !canSafelySwitchNas(downloads.filterNot { it.id in retiredIds }, uploads.filterNot { it.id in retiredIds },
            state.transfers.filterNot { it.id in retiredIds }, state.isPerformingAction, chatMutation)
}
