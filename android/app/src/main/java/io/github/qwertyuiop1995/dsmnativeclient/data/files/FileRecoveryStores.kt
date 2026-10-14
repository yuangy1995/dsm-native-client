package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository

/** 文件功能恢复存储统一绑定和按连接移除，避免新增功能漏接生命周期。 */
internal class FileRecoveryStores(private val context: Context) {
    val crossNas by lazy { CrossNasTransferStore(context) }
    val office by lazy { OfficeDocumentStore(context) }
    private val sharing by lazy { FileShareRecoveryStore(context) }
    private val permissions by lazy { FilePermissionRecoveryStore(context) }
    private val iso by lazy { FileISOMountRecoveryStore(context) }
    private val remote by lazy { FileRemoteMountRecoveryStore(context) }
    private val vfs by lazy { FileVFSRecoveryStore(context) }
    private val settings by lazy { FileSettingsRecoveryStore(context) }
    private val background by lazy { FileBackgroundTaskRecoveryStore(context) }
    fun bind(repository: DsmRepository) {
        repository.bindShareRecovery(sharing)
        repository.filePermissions.bindRecovery(permissions)
        repository.fileMounts.bindRecovery(iso)
        repository.fileMounts.remote.bindRecovery(remote)
        repository.fileMounts.vfs.bindRecovery(vfs)
        repository.fileSettings.bindRecovery(settings)
        repository.fileBackgroundTasks.bindRecovery(background)
    }
    fun removeProfile(profileId: String) {
        sharing.removeProfile(profileId); permissions.removeProfile(profileId); iso.removeProfile(profileId)
        remote.removeProfile(profileId); vfs.removeProfile(profileId); settings.removeProfile(profileId)
        background.removeProfile(profileId); crossNas.removeProfile(profileId); office.removeProfile(profileId)
    }
}
