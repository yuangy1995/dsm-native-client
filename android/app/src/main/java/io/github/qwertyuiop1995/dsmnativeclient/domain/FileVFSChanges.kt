package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
internal data class FileVFSCloudIdentity(val protocolId: String, val alias: String, val account: String) {
    override fun toString() = "FileVFSCloudIdentity"
}

/** 写操作仅携带非密码目标，授权令牌通过独立内存参数传递。 */
@Serializable
internal sealed interface FileVFSChange {
    @Serializable data class Create(val setup: FileVFSConfiguration) : FileVFSChange
    @Serializable data class Update(val baseline: FileVFSDetail, val setup: FileVFSConfiguration) : FileVFSChange
    @Serializable data class CreateCloud(val identity: FileVFSCloudIdentity) : FileVFSChange
    @Serializable data class Reauthorize(val baseline: FileVFSProfile) : FileVFSChange
    @Serializable data class Connect(val baseline: FileVFSProfile) : FileVFSChange
    @Serializable data class Disconnect(val baseline: FileVFSProfile) : FileVFSChange
    @Serializable data class RemoveSaved(val baseline: FileVFSProfile) : FileVFSChange
}

internal val FileVFSChange.baselineProfile: FileVFSProfile? get() = when (this) {
    is FileVFSChange.Update -> baseline.profile
    is FileVFSChange.Reauthorize -> baseline
    is FileVFSChange.Connect -> baseline
    is FileVFSChange.Disconnect -> baseline
    is FileVFSChange.RemoveSaved -> baseline
    else -> null
}
internal val FileVFSChange.writesBoth get() = this is FileVFSChange.Create || this is FileVFSChange.Update ||
    this is FileVFSChange.CreateCloud || this is FileVFSChange.Reauthorize

internal enum class FileVFSOutcomeStatus { COMPLETED, UNKNOWN, REJECTED }
