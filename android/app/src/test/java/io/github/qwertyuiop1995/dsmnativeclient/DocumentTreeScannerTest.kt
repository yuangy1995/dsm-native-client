package io.github.qwertyuiop1995.dsmnativeclient

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DocumentTreeScannerTest {
    @Test
    fun `目录上传保留所选根空目录层级和名称空格`() = runTest {
        val result = collectDocumentTree(dir("root", "旅行 "), true, 20, { true }) { id, _ ->
            when (id) {
                "root" -> listOf(dir("empty", "空目录 "), dir("nested", "照片"), file("root-file", "说明.txt "))
                "nested" -> listOf(file("photo", "海边.jpg"))
                else -> emptyList()
            }
        }

        assertFalse(result.truncated)
        assertEquals(listOf("旅行 ", "旅行 /空目录 ", "旅行 /照片", "旅行 /说明.txt ", "旅行 /照片/海边.jpg"), result.entries.map { it.relativePath })
        assertTrue(result.entries.all { it.issue == null })
    }

    @Test
    fun `空的所选根目录仍是一个可执行目录项`() = runTest {
        val result = collectDocumentTree(dir("root", "Empty"), true, 1, { true }) { _, _ -> emptyList() }
        assertFalse(result.truncated)
        assertEquals(listOf("Empty"), result.entries.map { it.relativePath })
    }

    @Test
    fun `照片备份保持根下相对路径并过滤非媒体`() = runTest {
        val result = collectDocumentTree(dir("root", "Camera"), false, 5, { it.startsWith("image/") }) { _, _ ->
            listOf(file("photo", "a.jpg", "image/jpeg"), file("text", "info.txt"))
        }
        assertEquals(listOf("a.jpg"), result.entries.map { it.relativePath })
    }

    @Test
    fun `恰好达到上限仍检查已排队目录是否为空`() = runTest {
        val requests = mutableListOf<Pair<String, Int>>()
        val result = collectDocumentTree(dir("root", "Root"), true, 2, { true }) { id, maximum ->
            requests += id to maximum
            if (id == "root") listOf(dir("empty", "Empty")) else emptyList()
        }
        assertFalse(result.truncated)
        assertEquals(listOf("root" to 2, "empty" to 1), requests)
        val tooLarge = collectDocumentTree(dir("root", "Root"), true, 2, { true }) { id, _ ->
            if (id == "root") listOf(dir("child", "Folder")) else listOf(file("file", "a.txt"))
        }
        assertTrue(tooLarge.truncated)
    }

    @Test
    fun `子目录读取失败成为失败项并继续扫描其他目录`() = runTest {
        val result = collectDocumentTree(dir("root", "Root"), true, 20, { true }) { id, _ ->
            when (id) {
                "root" -> listOf(dir("broken", "Broken"), dir("good", "Good"))
                "broken" -> throw IOException("synthetic source unavailable")
                else -> listOf(file("ok", "a.txt"))
            }
        }
        assertEquals(DocumentSourceIssue.UNREADABLE, result.entries.single { it.relativePath == "Root/Broken" }.issue)
        assertTrue(result.entries.any { it.relativePath == "Root/Good/a.txt" && it.issue == null })
        assertFalse(result.truncated)
    }

    @Test
    fun `失去整个根读取权限不能报告空目录`() = runTest {
        val result = collectDocumentTree(dir("root", "Root"), false, 20, { true }) { _, _ -> throw SecurityException() }
        assertEquals(DocumentSourceIssue.UNREADABLE, result.entries.single().issue)
        val plan = photoBackupScanPlan(DocumentTreeScan(emptyList(), false, unavailable = listOf(UnavailableDocument("", DocumentSourceIssue.UNREADABLE))))
        assertTrue(plan.needsAttention)
        assertTrue(plan.files.isEmpty())
    }

    @Test
    fun `未知大小虚拟文件和无效名字不能静默遗漏`() = runTest {
        val result = collectDocumentTree(dir("root", "Root"), true, 20, { true }) { _, _ ->
            listOf(file("unknown", "unknown.txt").copy(size = null), file("virtual", "note").copy(virtual = true),
                file("invalid", "../bad"), file("zero", "empty.txt").copy(size = 0))
        }
        assertEquals(listOf(null, DocumentSourceIssue.UNKNOWN_SIZE, DocumentSourceIssue.VIRTUAL_DOCUMENT, DocumentSourceIssue.INVALID_NAME, null), result.entries.map { it.issue })
    }

    @Test
    fun `循环提供器目录只读取一次并明确拒绝重复身份`() = runTest {
        var reads = 0
        val result = collectDocumentTree(dir("root", "Root"), true, 20, { true }) { _, _ ->
            reads++
            listOf(dir("root", "Loop"))
        }
        assertEquals(1, reads)
        assertEquals(DocumentSourceIssue.DUPLICATE, result.entries.last().issue)
    }

    @Test
    fun `同路径两个来源都标记冲突而空格不同路径保持独立`() = runTest {
        val result = collectDocumentTree(dir("root", "Root"), true, 20, { true }) { _, _ ->
            listOf(file("a", "same.txt"), file("b", "same.txt"), file("c", "same.txt "))
        }
        assertEquals(2, result.entries.count { it.issue == DocumentSourceIssue.DUPLICATE })
        assertEquals(null, result.entries.last().issue)
    }

    @Test
    fun `取消扫描停止后续目录且不转换成读取失败`() = runTest {
        var cancelled = false
        try {
            collectDocumentTree(dir("root", "Root"), true, 20, { true }) { _, _ -> throw CancellationException() }
        } catch (_: CancellationException) { cancelled = true }
        assertTrue(cancelled)
    }

    private fun dir(id: String, name: String) = DocumentTreeNode(id, name, "vnd.android.document/directory")
    private fun file(id: String, name: String, mime: String = "text/plain") = DocumentTreeNode(id, name, mime, size = 12)
}
