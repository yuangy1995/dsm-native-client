package io.github.qwertyuiop1995.dsmnativeclient.ui

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class ApprovedPhotoLayoutTest {
    @Test fun 日期标题和组合图不丢失或重复照片索引() {
        val photos = (0..5).map { index -> PhotoItem("photo-$index", FileItem("/synthetic/$index.jpg", "$index.jpg", false),
            PhotoItemKind.IMAGE, Instant.parse(if (index < 4) "2026-09-08T12:00:00Z" else "2026-09-07T12:00:00Z").epochSecond) }
        val entries = photoGridEntries(photos, true, ZoneId.of("UTC"))
        assertEquals(listOf(0, 1, 2, 3, 4, 5), entries.flatMap { it.indices })
        assertEquals(2, entries.count { it.indices.isEmpty() })
        assertEquals(listOf(0, 1, 2), entries[1].indices)
    }
    @Test fun 文件夹模式保持每个项目单独索引() {
        val photos = listOf(PhotoItem("folder", FileItem("/synthetic/folder", "Folder", true), PhotoItemKind.FOLDER, null))
        assertEquals(listOf(PhotoGridEntry(listOf(0))), photoGridEntries(photos, false, ZoneId.of("UTC")))
    }
    @Test fun 缺少日期有独立标题而不是假日期() {
        val photos = listOf(PhotoItem("photo", FileItem("/synthetic/photo.jpg", "Photo", false), PhotoItemKind.IMAGE, null))
        val entries = photoGridEntries(photos, true, ZoneId.of("UTC"))
        assertTrue(entries.first().indices.isEmpty())
        assertNull(entries.first().date)
        assertEquals(listOf(0), entries.last().indices)
    }
}
