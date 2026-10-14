package io.github.qwertyuiop1995.dsmnativeclient.domain

import org.junit.Assert.*
import org.junit.Test

class FileNameSearchTest {
    @Test fun `普通关键词未闭合或未知标志保持普通搜索`() {
        listOf("report", "*.pdf", "/", "/report", "/report/g", "/report/I", " /report/", "/one/i/other/g").forEach {
            assertFalse(it, FileNameSearch.parse(it).isRegularExpression)
        }
    }

    @Test fun `无标志区分大小写而小写i支持Unicode不区分大小写`() {
        val sensitive = requireNotNull(FileNameSearch.parse("/^résumé\\.pdf$/").expression)
        val insensitive = requireNotNull(FileNameSearch.parse("/^résumé\\.pdf$/i").expression)
        assertTrue(sensitive.containsMatchIn("résumé.pdf")); assertFalse(sensitive.containsMatchIn("RÉSUMÉ.PDF"))
        assertTrue(insensitive.containsMatchIn("RÉSUMÉ.PDF")); assertFalse(insensitive.containsMatchIn("copy-résumé.pdf"))
        assertTrue(requireNotNull(FileNameSearch.parse("/报告|照片/ii").expression).containsMatchIn("年度报告.txt"))
    }

    @Test fun `最后未转义斜线按反斜线奇偶识别`() {
        assertEquals("one\\/two", FileNameSearch.parse("/one\\/two/i").expression?.pattern)
        assertFalse(FileNameSearch.parse("/one\\/").isRegularExpression)
        assertEquals("one\\\\", FileNameSearch.parse("/one\\\\/").expression?.pattern)
        assertEquals("one/i/two", FileNameSearch.parse("/one/i/two/").expression?.pattern)
    }

    @Test fun `空表达式匹配任意名称而语法错误明确拒绝`() {
        assertTrue(requireNotNull(FileNameSearch.parse("//").expression).containsMatchIn("report.txt"))
        val request = FileSearchRequest(listOf("/share"), name = "/[/")
        assertTrue(request.nameSearch.isRegularExpression); assertNull(request.nameSearch.expression)
        assertEquals(DsmErrorKind.FILE_SEARCH_INVALID_REGEX, request.nameError); assertFalse(request.isValid)
    }

    @Test fun `正文搜索与正则不能混用且修改条件重新计算错误`() {
        val request = FileSearchRequest(listOf("/share"), name = "/report/i", searchesContents = true)
        assertEquals(DsmErrorKind.FILE_CONTENT_SEARCH_REGEX, request.nameError); assertFalse(request.isValid)
        assertTrue(request.copy(searchesContents = false).isValid)
        assertTrue(request.copy(name = "report").isValid)
    }
}
