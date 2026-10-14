package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * 仅用于本机加密外链映射的最小业务定位符。
 *
 * 这个模型不能进入 URI、Intent、SavedState 或日志。远端对象打开时须从所属 NAS 重新读取；
 * 本机任务仅定位原身份的记录，不触发连接或业务写。这里不保存完整领域对象、显示名、
 * NAS 地址、会话或服务端响应。
 */
@Serializable
sealed interface OpaqueWorkspaceTarget {
    @Serializable
    @SerialName("local_transfer")
    data class LocalTransfer(val kind: LocalTransferKind, val id: String) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("workspace_page")
    data class Page(val page: WorkspacePage) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("file_directory")
    data class FileDirectory(
        val canonicalPath: String,
    ) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("file_preview")
    data class FilePreview(
        val canonicalPath: String,
    ) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("photo_folder")
    data class PhotoFolder(
        val spaceId: String,
        val canonicalPath: String,
    ) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("photo_viewer")
    data class PhotoViewer(
        val spaceId: String,
        val canonicalPath: String,
    ) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("chat_conversation")
    data class ChatConversation(
        val conversationId: String,
    ) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("download_task")
    data class DownloadTask(
        val taskId: String,
    ) : OpaqueWorkspaceTarget

    @Serializable
    @SerialName("virtual_machine_guest")
    data class VirtualMachineGuest(
        val guestId: String,
    ) : OpaqueWorkspaceTarget
}

@Serializable
enum class LocalTransferKind { DOWNLOAD, UPLOAD, SERVER, VMM_IMPORT }

@Serializable
enum class WorkspacePage(val module: Module) {
    FILES(Module.FILES), PHOTOS(Module.PHOTOS), CHAT(Module.CHAT), DOWNLOADS(Module.DOWNLOADS),
    CONTAINERS(Module.CONTAINERS), VIRTUAL_MACHINES(Module.VIRTUAL_MACHINES), NAS_SETTINGS(Module.NAS_SETTINGS),
    TRANSFERS(Module.TRANSFERS), SETTINGS(Module.SETTINGS), CONTAINER_REGISTRY(Module.CONTAINERS),
    VIRTUAL_MACHINE_TASKS(Module.VIRTUAL_MACHINES), NAS_PERFORMANCE(Module.NAS_SETTINGS),
}

/**
 * 已加密保存的本机外链记录。
 *
 * [token] 是 URI 中唯一允许出现的值；其余字段只保存在现有的加密资料存储内。
 */
@Serializable
data class OpaqueWorkspaceRouteRecord(
    val token: String,
    val profileId: String,
    val target: OpaqueWorkspaceTarget,
    val createdAtEpochMillis: Long,
    val schemaVersion: Int = OPAQUE_WORKSPACE_ROUTE_SCHEMA_VERSION,
)

const val OPAQUE_WORKSPACE_ROUTE_SCHEMA_VERSION = 1
