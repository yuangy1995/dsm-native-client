package io.github.qwertyuiop1995.dsmnativeclient.ui.transfers

import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferTask

internal enum class ClientTaskStatus { ACTIVE, FINISHED }

/** 需要核对的失败操作仍在待处理集合；不能因显示“失败”就藏到已结束。 */
internal fun ClientTaskStatus.matches(task: TransferTask): Boolean {
    val finished = task.state in setOf(TransferState.SUCCEEDED, TransferState.FAILED, TransferState.CANCELLED) && !task.requiresRefresh
    return if (this == ClientTaskStatus.FINISHED) finished else !finished
}

/** 现有解析器将 finished 映射为 STOPPED，seeding 仍属于 RUNNING。未知状态不冒充已结束。 */
internal fun ClientTaskStatus.matches(state: ResourceState): Boolean {
    val finished = state in setOf(ResourceState.STOPPED, ResourceState.HEALTHY, ResourceState.ERROR)
    return if (this == ClientTaskStatus.FINISHED) finished else !finished
}
