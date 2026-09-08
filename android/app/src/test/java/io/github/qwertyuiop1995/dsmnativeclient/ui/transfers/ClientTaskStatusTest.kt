package io.github.qwertyuiop1995.dsmnativeclient.ui.transfers

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import org.junit.Assert.*
import org.junit.Test

class ClientTaskStatusTest {
    @Test fun 仍需核对的失败任务不会隐藏到已结束() {
        val task = TransferTask("fixture", "Fixture", "", TransferDirection.SERVER, TransferState.FAILED, requiresRefresh = true)
        assertTrue(ClientTaskStatus.ACTIVE.matches(task))
        assertFalse(ClientTaskStatus.FINISHED.matches(task))
    }
    @Test fun 未知下载状态不是已结束且暂停仍待处理() {
        assertTrue(ClientTaskStatus.ACTIVE.matches(ResourceState.UNKNOWN))
        assertTrue(ClientTaskStatus.ACTIVE.matches(ResourceState.PAUSED))
        assertTrue(ClientTaskStatus.FINISHED.matches(ResourceState.STOPPED))
        assertFalse(ClientTaskStatus.FINISHED.matches(ResourceState.RUNNING))
    }
}
