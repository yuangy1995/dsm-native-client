package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoAutomaticPreviewSelectionTest {
    private fun photo(id: Long, type: String = "photo") = SynologyPhoto(SynologyPhotoId("synthetic", SynologyPhotoSpace.PERSONAL, id), "Synthetic$id.jpg", 4, 1.0, 2.0, 9, type)
    private fun view(count: Int, index: Int = 0, timeline: Boolean = true, complete: Boolean = true): SynologyPhotoAutomaticPreviewView {
        val photos = (1..count).map { photo(it.toLong()) }
        return SynologyPhotoAutomaticPreviewView(photos, photos.getOrNull(index), SynologyPhotoSpace.PERSONAL, listOf(SynologyPhotoSpace.PERSONAL), false, timeline, complete)
    }
    private fun ids(photos: List<SynologyPhoto>) = photos.map { it.id.itemId }
    @Test fun `少于四张仅下一张和前一张且去重`() {
        assertTrue(view(1).neighbors().isEmpty()); assertEquals(listOf(2L), ids(view(2).neighbors()))
        assertEquals(listOf(2L, 3L), ids(view(3, timeline = false).neighbors()))
    }
    @Test fun `四张缩减下一侧且五张仅保留前一张`() {
        assertEquals(listOf(2L, 3L, 4L), ids(view(4, timeline = false).neighbors()))
        assertEquals(listOf(4L, 5L, 1L, 2L), ids(view(5, index = 2).neighbors()))
    }
    @Test fun `六张完整集合先后三前二顺序`() {
        assertEquals(listOf(4L, 5L, 6L, 1L, 2L), ids(view(6, index = 2).neighbors()))
    }
    @Test fun `时间线不向前环绕未完整分页不向任一方向环绕`() {
        assertEquals(listOf(2L, 3L), ids(view(6).neighbors()))
        // 已加载邻域只有四个唯一项目时，基准会移除下一侧最后一项，即使该侧仅一项。
        assertEquals(listOf(4L), ids(view(6, index = 4, complete = false).neighbors()))
        assertEquals(listOf(2L, 3L, 4L, 5L, 6L), ids(view(6, timeline = false).neighbors()))
    }
    @Test fun `先确定邻域再排除视频不补范围外的照片`() {
        val input = view(10, 3)
        val changed = input.copy(photos = input.photos.map { if (it.id.itemId in setOf(3L, 5L, 6L)) it.copy(mediaType = "video") else it })
        assertEquals(listOf(7L, 2L), ids(changed.neighbors()))
        assertEquals(listOf(7L, 2L), ids(changed.copy(photos = changed.photos.map { if (it.mediaType == "video") it.copy(mediaType = "video360") else it }).neighbors()))
    }
    @Test fun `当前相邻可见按顺序合并不重复`() {
        val input = view(9, 3)
        assertEquals(listOf(4L, 5L, 6L, 7L, 2L, 3L, 1L, 9L), ids(input.ordered(setOf(input.photos[0].id, input.photos[4].id, input.photos[8].id))))
        assertEquals(listOf(1L), ids(input.copy(current = null).ordered(setOf(input.photos[0].id))))
    }
}
