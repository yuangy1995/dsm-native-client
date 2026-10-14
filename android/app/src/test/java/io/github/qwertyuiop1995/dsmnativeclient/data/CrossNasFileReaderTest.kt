package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.CrossNasFileReader
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class CrossNasFileReaderTest {
    @Test fun `strict read preserves exact names metadata and permission without repairing paths`() = runBlocking {
        val reader = CrossNasFileReader { method, fields ->
            assertEquals("list", method); assertEquals("/source", fields["folder_path"])
            assertEquals("0", fields["offset"]); assertEquals("200", fields["limit"])
            assertEquals("asc", fields["sort_direction"]); assertEquals("all", fields["filetype"])
            page(listOf(item("/source/ a.bin ")))
        }
        val file = reader.page("/source", 0, 200).items.single()
        assertEquals(" a.bin ", file.name); assertEquals(3L, file.size)
        assertEquals(100L, file.modifiedAtEpochSeconds); assertTrue(file.canRead); assertFalse(file.canDelete)
    }
    @Test fun `missing total offset rows or incomplete rows never become an empty page`() = runBlocking {
        val valid = page(listOf(item()))
        val bad = listOf(JsonObject(valid - "total"), JsonObject(valid - "offset"), JsonObject(valid - "files"),
            page(emptyList(), 1), page(listOf(item()), 0), page(listOf(item()), 1, 1),
            page(listOf(item(), item()), 2), page(listOf(item("/another/a.bin"))),
            page(listOf(JsonObject(item() - "isdir"))), page(listOf(JsonObject(item() - "name"))),
            page(listOf(buildJsonObject { put("path", "/source/a.bin"); put("code", 408) })),
            page(listOf(JsonObject(item() + ("additional" to buildJsonObject { put("size", 3) })))),
            page(listOf(JsonPrimitive("not-an-item"))))
        for (data in bad) failure { CrossNasFileReader { _, _ -> data }.page("/source", 0, 200) }
    }
    @Test fun `missing item is accepted only from the exact explicit missing path`() = runBlocking {
        val missing = buildJsonObject { putJsonArray("files") { add(buildJsonObject { put("path", "/source/a.bin"); put("code", 408) }) } }
        assertNull(CrossNasFileReader { _, _ -> missing }.item("/source/a.bin"))
        failure { CrossNasFileReader { _, _ -> missing }.item("/source/b.bin") }
        failure { CrossNasFileReader { _, _ -> page(emptyList()) }.item("/source/a.bin") }
        failure { CrossNasFileReader { _, _ -> buildJsonObject {} }.item("/source/a.bin") }
        assertEquals("/source/a.bin", CrossNasFileReader { _, _ -> page(listOf(item())) }.item("/source/a.bin")?.path)
    }
    private suspend fun failure(block: suspend () -> Any?) {
        try { block(); throw AssertionError("Expected a domain failure") } catch (_: DsmFailure) { }
    }
    private fun page(rows: List<JsonElement>, total: Int = rows.size, offset: Int = 0) = buildJsonObject {
        put("total", total); put("offset", offset); put("files", JsonArray(rows))
    }
    private fun item(path: String = "/source/a.bin") = buildJsonObject {
        put("path", path); put("name", path.substringAfterLast('/')); put("isdir", false)
        putJsonObject("additional") {
            put("size", 3); put("mount_point_type", "normal"); putJsonObject("time") { put("mtime", 100) }
            putJsonObject("perm") { put("read", true); put("write", false); put("delete", false) }
        }
    }
}
