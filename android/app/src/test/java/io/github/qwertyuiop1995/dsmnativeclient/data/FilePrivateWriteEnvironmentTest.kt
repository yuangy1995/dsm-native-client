package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileSettingsFixture
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileVFSFixture
import java.io.File
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class FilePrivateWriteEnvironmentTest {
    @Test fun `设置不同DSM或缺套件版本仍按实际权限保存且不读取版本`() = runBlocking {
        for (version in listOf("future", "")) {
            val f = FileSettingsFixture(); f.firmware = "DSM 7.3"; f.packageVersion = version
            f.before = { check(it["api"] !in setOf("SYNO.Core.System", "SYNO.Core.Package")) }
            val old = f.settings.reader.general()
            assertEquals(FileSettingsOutcomeStatus.COMPLETED,
                f.settings.changeSettingsResult(FileSettingsChange.General(old, old.copy(recordsTransfers = true)), true).status)
            assertEquals(1, f.writes().size); assertTrue(f.settings.pending().isEmpty())
        }
    }
    @Test fun `设置仍需要实际管理员权限不能因删除版本门放宽`() = runBlocking {
        val f = FileSettingsFixture(); val old = f.settings.reader.general(); f.administrator = false
        val error = runCatching { f.settings.changeSettingsResult(FileSettingsChange.General(old, old.copy(recordsTransfers = true)), true) }.exceptionOrNull()
        assertEquals(DsmErrorKind.PERMISSION_DENIED, (error as DsmFailure).kind)
        assertTrue(f.writes().isEmpty()); assertTrue(f.settings.pending().isEmpty())
    }
    @Test fun `主题图片上传不读取系统或套件版本且仍有独立结果`() = runBlocking {
        val f = FileSettingsFixture(); f.packageVersion = "future"
        f.before = { check(it["api"] !in setOf("SYNO.Core.System", "SYNO.Core.Package")) }
        val file = File.createTempFile("synthetic-theme-", ".png")
        try {
            file.writeBytes(byteArrayOf(1, 2, 3)); val input = FileThemeUpload(file, "synthetic.png", file.length(), themeFileDigest(file))
            val result = f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true)
            assertEquals(FileSettingsOutcomeStatus.COMPLETED, result.status)
            assertEquals(1, f.calls.count { it["method"] == "upload" }); assertTrue(f.settings.pending().isEmpty())
        } finally { file.delete() }
    }
    @Test fun `远程连接未知版本仍可操作且不读取系统元数据`() = runBlocking {
        val f = FileVFSFixture(); f.firmware = "DSM 7.3"; f.packageVersion = "future"
        f.before = { check(it["api"] !in setOf("SYNO.Core.System", "SYNO.Core.Package")) }
        val result = f.repository.fileMounts.vfs.changeVFSResult(FileVFSChange.Disconnect(f.original), null, true)
        assertEquals(FileVFSOutcomeStatus.COMPLETED, result.status)
        assertEquals(1, f.writes().size); assertTrue(f.repository.fileMounts.vfs.pending().isEmpty())
    }
    @Test fun `旧远程连接未知结果仍只读恢复而不重发`() = runBlocking {
        val f = FileVFSFixture(); val vfs = f.repository.fileMounts.vfs
        f.before = { if (it["api"] == VFS_CONNECTION_API && it["method"] == "delete") throw IOException("synthetic lost receipt") }
        val original = vfs.changeVFSResult(FileVFSChange.Disconnect(f.original), null, true)
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, original.status)
        f.firmware = "DSM 7.3"; f.before = {}
        assertEquals(FileVFSOutcomeStatus.UNKNOWN, vfs.review(original.pending!!.id).status)
        assertEquals(1, f.writes().size); assertFalse(f.calls.any { it["api"] in setOf("SYNO.Core.System", "SYNO.Core.Package") })
    }
}
