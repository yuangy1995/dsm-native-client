package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.ui.navigation.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.update
import org.junit.Assert.*
import org.junit.Test

class WorkspaceAccessStateTest {
    private val profile = NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "synthetic")
    private fun access(allowed: Boolean) = Module.entries.map { ModuleAvailability(it, allowed) }
    private fun contents() = WorkspaceState(profile, availability = access(true),
        files = Loadable.Ready(FilePage(emptyList(), 0, 0)), favoritePaths = setOf("/synthetic"),
        conversations = Loadable.Ready(emptyList()), chatAttachmentThumbnails = mapOf("synthetic" to Loadable.Ready(byteArrayOf(1))),
        downloads = Loadable.Ready(emptyList()), nasSettings = Loadable.Loading, virtualMachines = Loadable.Loading,
        containers = Loadable.Loading, photos = Loadable.Loading, fileBackgroundTasks = Loadable.Loading)

    @Test fun `撤销清除各模块读取内容但保留本机任务与提交事实`() {
        val task = TransferTask("synthetic", "Synthetic", "", TransferDirection.UPLOAD, TransferState.RUNNING)
        val original = contents().copy(transfers = listOf(task),
            downloadCreationState = DownloadCreationWorkspaceState(mutationInProgress = true),
            chatMutationState = ChatMutationWorkspaceState())
        val result = original.copy(availability = access(false)).withoutUnavailableContent()
        assertEquals(Loadable.Idle, result.files)
        assertEquals(Loadable.Idle, result.photos)
        assertEquals(Loadable.Idle, result.conversations)
        assertEquals(Loadable.Idle, result.downloads)
        assertEquals(Loadable.Idle, result.containers)
        assertEquals(Loadable.Idle, result.virtualMachines)
        assertEquals(Loadable.Idle, result.nasSettings)
        assertEquals(Loadable.Idle, result.fileBackgroundTasks)
        assertTrue(result.favoritePaths.isEmpty())
        assertTrue(result.chatAttachmentThumbnails.isEmpty())
        assertEquals(original.transfers, result.transfers)
        assertEquals(original.downloadCreationState, result.downloadCreationState)
        assertEquals(original.chatMutationState, result.chatMutationState)
        // 电源提交事实已迁入独立加密记录，撤权/重建回归见 NasPowerActionModelTest。
    }

    @Test fun `旧状态通过每个写入入口返回时不能恢复授权或内容`() = runBlocking {
        var current = access(true)
        val store = WorkspaceStateStore(availability = { current })
        val late = contents()
        store.value = late
        current = access(false)
        store.update { late }
        assertRevoked(store.value!!)
        store.value = late
        assertRevoked(store.value!!)
        store.emit(late)
        assertRevoked(store.value!!)
        assertTrue(store.tryEmit(late))
        assertRevoked(store.value!!)
        assertFalse(store.compareAndSet(late, late))
    }

    @Test fun `其他模块与本机入口不受单模块撤销影响`() {
        val original = contents()
        val result = original.copy(availability = access(true).map {
            if (it.module == Module.FILES) ModuleAvailability(it.module, false) else it
        }).withoutUnavailableContent()
        assertEquals(Loadable.Idle, result.files)
        assertEquals(original.conversations, result.conversations)
        assertEquals(original.downloads, result.downloads)
        assertTrue(emptyList<ModuleAvailability>().allows(Module.SETTINGS))
        assertTrue(emptyList<ModuleAvailability>().allows(Module.TRANSFERS))
        assertFalse(emptyList<ModuleAvailability>().allows(Module.FILES))
    }

    @Test fun `重新授权不恢复旧缓存且允许新读取进入`() {
        var current = access(false)
        val store = WorkspaceStateStore(availability = { current })
        store.value = contents()
        current = access(true)
        store.update { it?.copy(availability = current) }
        assertEquals(Loadable.Idle, store.value?.files)
        val newPage = FilePage(emptyList(), 0, 0)
        store.update { it?.copy(files = Loadable.Ready(newPage)) }
        assertEquals(Loadable.Ready(newPage), store.value?.files)
    }

    @Test fun `导航临时过滤不修改已保存的固定项`() {
        val pinned = PinnedModules()
        val encoded = pinned.encode()
        assertEquals(listOf(ClientDestination.HOME, ClientDestination.DEVICE), pinned.visibleItems(access(false)))
        assertEquals(ClientDestination.defaults, pinned.visibleItems(access(true)))
        assertEquals(encoded, pinned.encode())
    }

    private fun assertRevoked(state: WorkspaceState) {
        assertFalse(state.availability.allows(Module.FILES))
        assertEquals(Loadable.Idle, state.files)
        assertEquals(Loadable.Idle, state.conversations)
    }
}
