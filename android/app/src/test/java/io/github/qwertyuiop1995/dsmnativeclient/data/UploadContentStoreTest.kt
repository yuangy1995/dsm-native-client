package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class UploadContentStoreTest {
    private val preferences = MemoryPreferences()
    private val transfers = TransferStore(preferences)
    private val task = PersistedUpload("task-a", "profile-a", "content://synthetic/item", "file.bin",
        expectedBytes = 3, destinationPath = "/synthetic", state = TransferState.FAILED,
        workId = "execution-a", requiresRefresh = true)
    private val fingerprint = UploadContentDigest(3).also { it.write(byteArrayOf(1, 2, 3)) }.finish()

    @Test fun `独立摘要跨实例可读且不改旧任务格式`() {
        transfers.upsert(task)
        val old = preferences.getString("uploads", null)
        transfers.saveUploadContent(task, "execution-a", fingerprint)
        assertEquals(fingerprint, TransferStore(preferences).uploadContent(task))
        assertEquals(old, preferences.getString("uploads", null))
        val record = preferences.all.filterKeys { it.startsWith("upload_content_v1_") }.values.single().toString()
        assertFalse(record.contains("content://")); assertFalse(record.contains("/synthetic"))
    }

    @Test fun `其他执行器账号及改变的长度不接受摘要`() {
        transfers.upsert(task); transfers.saveUploadContent(task, "execution-a", fingerprint)
        assertNull(transfers.uploadContent(task.copy(workId = "execution-b")))
        assertNull(transfers.uploadContent(task.copy(profileId = "profile-b")))
        assertThrows(IOException::class.java) { transfers.saveUploadContent(task, "execution-b", fingerprint) }
        assertThrows(IOException::class.java) { transfers.saveUploadContent(task, "execution-a", fingerprint.copy(bytes = 4)) }
    }

    @Test fun `取消后的原执行器可保留完整摘要但新执行器不能覆写`() {
        transfers.upsert(task.copy(state = TransferState.CANCELLED))
        transfers.saveUploadContent(task, "execution-a", fingerprint)
        assertEquals(fingerprint, transfers.uploadContent(task))
        transfers.upsert(task.copy(workId = "execution-b"))
        assertThrows(IOException::class.java) { transfers.saveUploadContent(task, "execution-a", fingerprint) }
    }

    @Test fun `清理完成任务同时删除摘要而保留未定任务`() {
        transfers.upsert(task); transfers.saveUploadContent(task, "execution-a", fingerprint)
        transfers.removeTerminal(task.profileId)
        assertEquals(fingerprint, transfers.uploadContent(task))
        transfers.upsert(task.copy(state = TransferState.SUCCEEDED, requiresRefresh = false))
        transfers.removeTerminal(task.profileId)
        assertNull(transfers.upload(task.id)); assertNull(transfers.uploadContent(task))
    }

    @Test fun `保存失败会返回失败而不是宣称摘要可恢复`() {
        transfers.upsert(task); preferences.commitSucceeds = false
        assertThrows(IOException::class.java) { transfers.saveUploadContent(task, "execution-a", fingerprint) }
    }

    @Test fun `大文件摘要分段读取且短读长读都失败`() = runBlocking {
        val length = 16L * 1024 * 1024
        var largestRead = 0
        val source = UploadSource("large.bin", null, length, {
            object : InputStream() {
                var remaining = length
                override fun read(): Int = error("应分段读取")
                override fun read(buffer: ByteArray, offset: Int, size: Int): Int {
                    largestRead = maxOf(largestRead, size)
                    if (remaining == 0L) return -1
                    val count = minOf(size.toLong(), remaining).toInt()
                    buffer.fill(42, offset, offset + count); remaining -= count; return count
                }
            }
        })
        val digest = MessageDigest.getInstance("SHA-256")
        repeat(2048) { digest.update(ByteArray(8192) { 42 }) }
        assertEquals(UploadContentFingerprint(length, digest.digest().joinToString("") { "%02x".format(it) }), source.contentFingerprint())
        assertTrue(largestRead <= 8192)
        assertTrue(runCatching { source.copy(contentLength = length - 1).contentFingerprint() }.exceptionOrNull() is IOException)
        assertTrue(runCatching { source.copy(contentLength = length + 1).contentFingerprint() }.exceptionOrNull() is IOException)
    }
}
