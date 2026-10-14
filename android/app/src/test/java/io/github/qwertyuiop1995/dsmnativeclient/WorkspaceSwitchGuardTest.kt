package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import org.junit.Assert.*
import org.junit.Test

class WorkspaceSwitchGuardTest {
    private val state = WorkspaceState(NasProfile("a", "NAS", "https://nas.example.invalid", "account"))

    @Test fun `当前写操作保留切换保护`() {
        assertTrue(workspaceSwitchIsBlocked(state.copy(isPerformingAction = true), emptyList(), emptyList()))
        assertFalse(workspaceSwitchIsBlocked(state, emptyList(), emptyList()))
    }

    @Test fun `照片上传占用当前账号时阻止切换而暂停后允许`() {
        assertTrue(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosUploading = true))
        assertFalse(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosUploading = false))
    }
    @Test fun `照片资料保存时阻止切换并在完成后释放`() {
        assertTrue(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosEditing = true))
        assertFalse(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosEditing = false))
    }
    @Test fun `相册保存时阻止切换并在完成后释放`() {
        assertTrue(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosAlbumWriting = true))
        assertFalse(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosAlbumWriting = false))
    }

    @Test fun `原件删除占用账号时阻止切换只读等待释放后允许`() {
        assertTrue(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosDeleting = true))
        assertFalse(workspaceSwitchIsBlocked(state, emptyList(), emptyList(), photosDeleting = false))
    }

    @Test fun `只有已因身份不符暂停的旧服务器任务才不阻塞新账号`() {
        val task = TransferTask("old-server", "synthetic", "", TransferDirection.SERVER, TransferState.PAUSED)
        val withTask = state.copy(transfers = listOf(task))
        assertTrue(workspaceSwitchIsBlocked(withTask, emptyList(), emptyList()))
        assertFalse(workspaceSwitchIsBlocked(withTask, emptyList(), emptyList(), setOf(task.id)))
        assertTrue(workspaceSwitchIsBlocked(withTask, emptyList(), emptyList(), setOf("another-task")))
    }
}
