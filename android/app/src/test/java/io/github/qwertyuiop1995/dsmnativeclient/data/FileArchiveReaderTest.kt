package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class FileArchiveReaderTest {
    private val source = "/synthetic/archive.zip"
    private val destination = "/synthetic/destination"
    private val folder = ArchiveItem(7, "Folder", "Folder", true)
    private val child = ArchiveItem(3, "a.txt", "Folder/a.txt", false, 12)
    private val other = ArchiveItem(8, "b.txt", "b.txt", false, 0)

    @Test fun `官方两种编号字段和零字节均保留且路径不裁剪`() = runBlocking {
        val parameters = mutableListOf<Map<String, String>>()
        val reader = FileArchiveReader { fields -> parameters += fields; Json.parseToJsonElement("""{"items":[{"item_id":7,"path":"Folder/a.txt ","name":"a.txt ","is_dir":false,"size":0}],"total":201}""").jsonObject }
        val page = reader.page(source, 7, 200, 200, "chs", "synthetic-password")
        assertEquals("Folder/a.txt ", page.items.single().path)
        assertEquals(0L, page.items.single().size)
        assertFalse(page.hasMore)
        assertEquals(mapOf("file_path" to source, "item_id" to "7", "offset" to "200", "limit" to "200", "sort_by" to "name", "sort_direction" to "asc", "codepage" to "chs", "password" to "synthetic-password"), parameters.single())
    }

    @Test fun `超过一页时完整读取并拒绝重复或中途空页`() = runBlocking {
        val calls = mutableListOf<Int>()
        val reader = FileArchiveReader { fields ->
            val offset = fields.getValue("offset").toInt(); calls += offset
            page(listOf(if (offset == 0) child else other), total = 2)
        }
        assertEquals(listOf(child, other), reader.children(source))
        assertEquals(listOf(0, 1), calls)
        for (second in listOf(page(listOf(child), 2), page(emptyList(), 2))) {
            var count = 0
            val invalid = FileArchiveReader { if (count++ == 0) page(listOf(child), 2) else second }
            assertEquals(DsmErrorKind.ARCHIVE_CONTENT_UNAVAILABLE, (runCatching { invalid.children(source) }.exceptionOrNull() as DsmFailure).kind)
        }
    }

    @Test fun `缺少总数时整页继续读取直到末页`() = runBlocking {
        val first = (0 until 200).map { ArchiveItem(it, "$it.txt", "$it.txt", false) }
        val offsets = mutableListOf<String>()
        val reader = FileArchiveReader { fields -> offsets += fields.getValue("offset"); page(if (offsets.size == 1) first else listOf(other.copy(id = 999))) }
        assertEquals(201, reader.children(source).size)
        assertEquals(listOf("0", "200"), offsets)
    }

    @Test fun `异常条目不可丢弃后当成完整清单`() = runBlocking {
        val invalidPaths = listOf("", "/absolute", "../file", "Folder/../file", "Folder//file", "C:file", "Folder\\file", "a\n.txt")
        for (path in invalidPaths) {
            val reader = FileArchiveReader { page(listOf(child.copy(path = path, name = path.substringAfterLast('/')))) }
            assertTrue(runCatching { reader.page(source) }.exceptionOrNull() is DsmFailure)
        }
        for (raw in listOf("""{"items":[null]}""", """{"items":[{"itemid":1,"path":"a","name":"a"}]}""", """{"items":[],"total":2}""", """{"items":[{"itemid":1,"path":"a","name":"b","is_dir":false}]}""")) {
            val reader = FileArchiveReader { Json.parseToJsonElement(raw).jsonObject }
            assertTrue(runCatching { reader.page(source) }.exceptionOrNull() is DsmFailure)
        }
    }

    @Test fun `所选文件夹包括子项但不会把其他根项目加入解压`() = runBlocking {
        val calls = mutableListOf<String>()
        val reader = FileArchiveReader { fields -> calls += fields.getValue("item_id"); page(if (fields["item_id"] == "-1") listOf(folder, other) else listOf(child)) }
        val inventory = reader.inventory(source, FileExtractionOptions(selection = FileArchiveSelection.Items(listOf(folder))))
        assertEquals(listOf(folder, child), inventory)
        assertEquals(listOf("-1", "7"), calls)
    }

    @Test fun `空选择编号漂移目录循环或错层路径均拒绝`() = runBlocking {
        val reader = FileArchiveReader { fields -> page(if (fields["item_id"] == "-1") listOf(folder, other) else listOf(child)) }
        for (selection in listOf(emptyList(), listOf(child.copy(path = "changed/a.txt")))) {
            assertEquals(DsmErrorKind.ARCHIVE_INVALID_SELECTION, (runCatching { reader.inventory(source, FileExtractionOptions(selection = FileArchiveSelection.Items(selection))) }.exceptionOrNull() as DsmFailure).kind)
        }
        for (invalidChild in listOf(folder, child.copy(path = "Other/a.txt"))) {
            val invalid = FileArchiveReader { fields -> page(if (fields["item_id"] == "-1") listOf(folder) else listOf(invalidChild)) }
            assertTrue(runCatching { invalid.inventory(source, FileExtractionOptions()) }.exceptionOrNull() is DsmFailure)
        }
    }

    @Test fun `输出保留结构和尺寸且覆盖必须观察任务结束`() {
        val outputs = extractionOutputs(source, destination, FileExtractionOptions(createSubfolder = true, overwrite = true), listOf(folder, child, other))
        assertEquals(listOf("$destination/archive/Folder", "$destination/archive/Folder/a.txt", "$destination/archive/b.txt"), outputs.map { it.path })
        assertEquals(listOf(null, 12L, 0L), outputs.map { it.expectedBytes })
        assertTrue(outputs.all { it.requiresTaskCompletion })
        val flat = extractionOutputs(source, destination, FileExtractionOptions(keepDirectories = false), listOf(folder, child, other))
        assertEquals(listOf("$destination/a.txt", "$destination/b.txt"), flat.map { it.path })
    }

    @Test fun `扁平化同名冲突或输出覆盖源归档均拒绝`() {
        assertThrows(DsmFailure::class.java) { extractionOutputs(source, destination, FileExtractionOptions(keepDirectories = false), listOf(child, child.copy(id = 4, path = "Other/a.txt"))) }
        assertThrows(DsmFailure::class.java) { extractionOutputs(source, "/synthetic", FileExtractionOptions(), listOf(ArchiveItem(1, "archive.zip", "archive.zip", false))) }
        assertThrows(DsmFailure::class.java) { extractionOutputs(source, destination, FileExtractionOptions(keepDirectories = false), listOf(folder)) }
    }

    @Test fun `密码错误保留可纠正类别而其他权限错误不被吞掉`() = runBlocking {
        for ((code, kind, expected) in listOf(Triple(1403, DsmErrorKind.REQUEST_FAILED, DsmErrorKind.ARCHIVE_PASSWORD_REQUIRED), Triple(105, DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.PERMISSION_DENIED))) {
            val reader = FileArchiveReader { throw DsmFailure(code, "synthetic", "synthetic", kind = kind) }
            assertEquals(expected, (runCatching { reader.page(source) }.exceptionOrNull() as DsmFailure).kind)
        }
    }

    private fun page(items: List<ArchiveItem>, total: Int? = null) = buildJsonObject {
        putJsonArray("items") { items.forEach { item -> add(buildJsonObject {
            put("itemid", item.id); put("name", item.name); put("path", item.path); put("is_dir", item.isDirectory); item.size?.let { put("size", it) }
        }) } }
        total?.let { put("total", it) }
    }
}
