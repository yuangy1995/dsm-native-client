package io.github.qwertyuiop1995.dsmnativeclient.ui.home

import org.junit.Assert.*
import org.junit.Test

class HomeLayoutTest {
    @Test fun 首次启动四个模块均显示() {
        val initial = HomeLayout.decode(null)
        assertTrue(HomeSection.entries.all(initial::isVisible))
        assertEquals("", initial.encode())
    }

    @Test fun 全部隐藏可持久化而不强制恢复默认() {
        val hidden = HomeSection.entries.fold(HomeLayout()) { layout, section ->
            layout.withVisibility(section, false)
        }
        assertTrue(HomeSection.entries.none(hidden::isVisible))
        assertEquals(hidden, HomeLayout.decode(hidden.encode()))
    }

    @Test fun 修改一个模块保留其他选择且不改原草稿() {
        val initial = HomeLayout().withVisibility(HomeSection.ACTIVE_TASKS, false)
        val draft = initial.withVisibility(HomeSection.RECENT_ITEMS, false)
        assertTrue(initial.isVisible(HomeSection.RECENT_ITEMS))
        assertFalse(draft.isVisible(HomeSection.ACTIVE_TASKS))
        assertEquals(initial, draft.withVisibility(HomeSection.RECENT_ITEMS, true))
    }

    @Test fun 未知标识和重复项不隐藏其他模块() {
        val value = HomeLayout.decode("unknown|recentItems|recentItems")
        assertEquals(setOf(HomeSection.RECENT_ITEMS), value.hidden)
        assertEquals("recentItems", value.encode())
    }

    @Test fun 恢复默认不会复用旧隐藏集合() {
        val hidden = HomeLayout(setOf(HomeSection.QUICK_ACTIONS, HomeSection.COMMON_LOCATIONS))
        assertTrue(HomeSection.entries.all(HomeLayout()::isVisible))
        assertEquals(hidden, HomeLayout.decode(hidden.encode()))
    }
}
