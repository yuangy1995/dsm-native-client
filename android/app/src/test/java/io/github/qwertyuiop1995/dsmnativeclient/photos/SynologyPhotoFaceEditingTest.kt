package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoFaceEditingTest {
    @Test fun `居中新增框按实际显示像素保持正方形`() {
        for ((width, height) in listOf(480 to 320, 80 to 160, 13 to 11)) {
            val bounds = SynologyPhotoFaceEditing.center(width, height)
            assertEquals(bounds.width * width, bounds.height * height, 1e-6)
            assertEquals(0.5, bounds.x + bounds.width / 2, 1e-6); assertEquals(0.5, bounds.y + bounds.height / 2, 1e-6)
        }
    }
    @Test fun `长宽不等图片正反方向拖动都保持像素方形且限制边界`() {
        val forward = SynologyPhotoFaceEditing.square(40f, 40f, 140f, 100f, 400f, 200f)!!
        assertEquals(0.1, forward.x, 1e-6); assertEquals(0.2, forward.y, 1e-6)
        assertEquals(100.0, forward.width * 400, 1e-6); assertEquals(100.0, forward.height * 200, 1e-6)
        val reverse = SynologyPhotoFaceEditing.square(380f, 180f, -100f, -100f, 400f, 200f)!!
        assertEquals(180.0, reverse.width * 400, 1e-6); assertEquals(0.0, reverse.y, 1e-6); assertTrue(reverse.valid)
    }
    @Test fun `短拖动零尺寸及无效坐标不生成框边缘满足最小尺寸`() {
        assertNull(SynologyPhotoFaceEditing.square(0f, 0f, 35f, 10f, 400f, 200f))
        assertNull(SynologyPhotoFaceEditing.square(0f, 0f, 50f, 50f, 0f, 200f))
        assertNull(SynologyPhotoFaceEditing.square(Float.NaN, 0f, 50f, 50f, 400f, 200f))
        val small = SynologyPhotoFaceEditing.square(0f, 0f, 30f, 30f, 30f, 30f)!!
        assertEquals(SynologyPhotoFaceBounds(0.0, 0.0, 1.0, 1.0), small)
    }
    @Test fun `原始未知人物及舍入微差不产生无意义修改`() {
        val original = SynologyPhotoFaceSnapshot(7, 0, "", SynologyPhotoFaceBounds(0.1, 0.1, 0.2, 0.2))
        val draft = SynologyPhotoFaceEditing.drafts(listOf(original), SynologyPhotoSpace.PERSONAL).single()
        assertFalse(draft.changed); assertTrue(draft.valid)
        assertFalse(draft.copy(bounds = draft.bounds.copy(width = 0.20000000000000004)).changed)
        assertTrue(SynologyPhotoFaceEditing.changes(listOf(draft), emptyMap()).isEmpty())
    }
    @Test fun `新增后移除不裁剪也不写原有框移除只生成一次删除`() {
        val bounds = SynologyPhotoFaceBounds(0.1, 0.1, 0.2, 0.2)
        val added = SynologyPhotoFaceDraft("new", null, bounds, null, "Name", removed = true)
        val old = SynologyPhotoFaceEditing.drafts(listOf(SynologyPhotoFaceSnapshot(7, 1, "Name", bounds)), SynologyPhotoSpace.PERSONAL).single().copy(removed = true)
        assertFalse(added.needsCrop); assertFalse(added.changed)
        assertEquals(listOf(SynologyPhotoFaceChange.Remove(old.original!!)), SynologyPhotoFaceEditing.changes(listOf(added, old), emptyMap()))
    }
    @Test fun `改归属现有人物保留原名空格新人物才裁剪空白`() {
        val original = SynologyPhotoFaceSnapshot(7, 1, "First", SynologyPhotoFaceBounds(0.1, 0.1, 0.2, 0.2))
        val draft = SynologyPhotoFaceEditing.drafts(listOf(original), SynologyPhotoSpace.SHARED).single()
        val target = SynologyPhotoPersonSnapshot(2, " Existing ", null, SynologyPhotoSpace.SHARED)
        val existing = SynologyPhotoFaceEditing.changes(listOf(draft.copy(person = target, name = target.name)), emptyMap()).single() as SynologyPhotoFaceChange.Reassign
        assertEquals(" Existing ", existing.name); assertEquals(target, existing.person)
        val fresh = SynologyPhotoFaceEditing.changes(listOf(draft.copy(person = null, name = " New ")), emptyMap()).single() as SynologyPhotoFaceChange.Reassign
        assertEquals("New", fresh.name); assertNull(fresh.person)
    }
}
