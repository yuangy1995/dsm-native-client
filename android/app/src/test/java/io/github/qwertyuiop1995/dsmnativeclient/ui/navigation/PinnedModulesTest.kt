package io.github.qwertyuiop1995.dsmnativeclient.ui.navigation

import org.junit.Assert.*
import org.junit.Test

class PinnedModulesTest {
    @Test fun 默认五个独立入口与已确认设计一致() {
        assertEquals(listOf(ClientDestination.HOME, ClientDestination.FILES, ClientDestination.PHOTOS,
            ClientDestination.CHAT, ClientDestination.DEVICE), PinnedModules().items)
    }
    @Test fun 隐藏全部仍可保存为空而不强制恢复默认() {
        val empty = ClientDestination.defaults.fold(PinnedModules()) { value, item -> value.hide(item) }
        assertTrue(empty.items.isEmpty())
        assertEquals(empty, PinnedModules.decode(empty.encode()))
    }
    @Test fun 替换和排序不会产生重复或第六项() {
        val result = PinnedModules().replace(0, ClientDestination.DOWNLOADS).move(ClientDestination.DEVICE, -1)
        assertEquals(listOf(ClientDestination.DOWNLOADS, ClientDestination.FILES, ClientDestination.PHOTOS,
            ClientDestination.DEVICE, ClientDestination.CHAT), result.items)
        assertEquals(result, PinnedModules.decode(result.encode()))
    }
    @Test(expected = IllegalArgumentException::class) fun 拒绝第六个固定项() { PinnedModules().add(ClientDestination.TASKS) }
    @Test(expected = IllegalArgumentException::class) fun 拒绝重复固定项() { PinnedModules().replace(0, ClientDestination.FILES) }
    @Test fun 新旧版本未知标识不成为导航或影响有效顺序() {
        assertEquals(listOf(ClientDestination.FILES, ClientDestination.CHAT), PinnedModules.decode("files|unknown|files|chat").items)
        assertEquals(PinnedModules(), PinnedModules.decode(null))
    }
    @Test fun 边界移动不改变顺序() {
        assertEquals(PinnedModules(), PinnedModules().move(ClientDestination.HOME, -1))
        assertEquals(PinnedModules(), PinnedModules().move(ClientDestination.DEVICE, 1))
    }
}
