package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class WorkspaceTransferRecoveryTest {
    private val profile = NasProfile("a", "NAS", "https://nas.example.invalid", "account")
    private val store = SecureProfileStore(MemoryPreferences())
    private val preferences = MemoryPreferences()
    private val transfers = TransferStore(preferences)
    private fun owner() = store.commitConnection(store.connectionAttempt(profile.id), profile,
        DsmSession(profile.id, "synthetic"), "synthetic", false)
    private fun download(id: String) = PersistedDownload(id, profile.id, "/synthetic/a", "a",
        "content://synthetic/a", false, expectedBytes = 90, state = TransferState.RUNNING,
        completedBytes = 30, workId = "original-work")

    @Test fun `旧下载暂停并保留已下载内容和原执行编号`() {
        val owner = owner(); val original = download("legacy")
        transfers.upsert(original)
        pauseUnownedTransfers(store, transfers, owner)
        assertEquals(original.copy(state = TransferState.PAUSED, errorKind = DsmErrorKind.WORKSPACE_CHANGED.name), transfers.download(original.id))
    }

    @Test fun `已绑定原账号的下载不受另一旧记录影响`() {
        val owner = owner(); val original = download("owned")
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, original.id, owner)
        transfers.upsert(original); transfers.upsert(download("legacy"))
        pauseUnownedTransfers(store, transfers, owner)
        assertEquals(original, transfers.download(original.id))
        assertEquals(TransferState.PAUSED, transfers.download("legacy")?.state)
    }

    @Test fun `未定上传暂停但保留写入事实与目标`() {
        val owner = owner()
        val upload = PersistedUpload("legacy-upload", profile.id, "content://synthetic/upload", "a", expectedBytes = 80,
            destinationPath = "/synthetic", state = TransferState.RUNNING, completedBytes = 10, requiresRefresh = true)
        transfers.upsert(upload)
        pauseUnownedTransfers(store, transfers, owner)
        assertEquals(upload.copy(state = TransferState.PAUSED, errorKind = DsmErrorKind.WORKSPACE_CHANGED.name), transfers.upload(upload.id))
    }

    @Test fun `旧备份来源停用但保留本地授权与目录`() {
        val owner = owner()
        val source = PersistedPhotoBackupSource(profile.id, "content://synthetic/tree", "/synthetic", workId = "original-work")
        transfers.upsertPhotoBackupSource(source)
        pauseUnownedTransfers(store, transfers, owner)
        assertEquals(source.copy(enabled = false, needsAttention = true), transfers.photoBackupSource(profile.id))
    }

    @Test fun `多个Worker同时保存不同任务不会丢失其他账号进度`() {
        val pool = Executors.newFixedThreadPool(4)
        val futures = (1..80).map { number -> pool.submit {
            TransferStore(preferences).upsert(download("download-$number").copy(profileId = if (number % 2 == 0) "a" else "b"))
        } }
        futures.forEach { it.get(5, TimeUnit.SECONDS) }; pool.shutdownNow()
        assertEquals(40, transfers.downloads("a").size); assertEquals(40, transfers.downloads("b").size)
    }

    @Test fun `不同实例更新同一任务严格串行保留每次进度`() {
        transfers.upsert(download("shared").copy(completedBytes = 0))
        val pool = Executors.newFixedThreadPool(4)
        val futures = (1..80).map { pool.submit {
            TransferStore(preferences).update("shared") { it.copy(completedBytes = it.completedBytes + 1) }
        } }
        futures.forEach { it.get(5, TimeUnit.SECONDS) }; pool.shutdownNow()
        assertEquals(80L, transfers.download("shared")?.completedBytes)
    }

    @Test fun `移除连接保留尚未收敛的上传事实`() {
        val pending = PersistedUpload("pending", profile.id, "content://synthetic/upload", "a", expectedBytes = 80,
            destinationPath = "/synthetic", state = TransferState.FAILED, completedBytes = 10, requiresRefresh = true)
        transfers.upsert(pending)
        transfers.upsert(pending.copy(id = "finished", state = TransferState.SUCCEEDED, requiresRefresh = false))
        transfers.removeProfile(profile.id)
        assertEquals(pending, transfers.upload(pending.id))
        assertNull(transfers.upload("finished"))
    }

    @Test fun `另一账号仍使用同一文件时不能撤销读取授权`() {
        val shared = "content://synthetic/shared"
        transfers.upsert(PersistedUpload("other-account", "b", shared, "shared", expectedBytes = 80,
            destinationPath = "/synthetic", state = TransferState.RUNNING))
        assertTrue(transfers.hasReadGrantReference(shared, "current-account"))
        transfers.updateUpload("other-account") { it.copy(state = TransferState.SUCCEEDED) }
        assertFalse(transfers.hasReadGrantReference(shared, "current-account"))
    }

    @Test fun `暂停且结果未定的任务继续保留原文件授权`() {
        val shared = "content://synthetic/shared"
        transfers.upsert(PersistedUpload("uncertain", "b", shared, "shared", expectedBytes = 80,
            destinationPath = "/synthetic", state = TransferState.PAUSED, requiresRefresh = true))
        assertTrue(transfers.hasReadGrantReference(shared))
    }

    @Test fun `取消单个下载不释放其他账号的相同目标`() {
        val first = download("a-download")
        transfers.upsert(first)
        transfers.upsert(first.copy(id = "b-download", profileId = "b"))
        assertTrue(transfers.hasDownloadDestinationReference(first.destinationUri, first.id))
        transfers.update("b-download") { it.copy(state = TransferState.CANCELLED) }
        assertFalse(transfers.hasDownloadDestinationReference(first.destinationUri, first.id))
    }

    @Test fun `备份目录来源仍引用的授权不因清理上传历史而释放`() {
        val tree = "content://synthetic/tree"
        transfers.upsertPhotoBackupSource(PersistedPhotoBackupSource("b", tree, "/synthetic", sourceId = "source-b"))
        assertTrue(transfers.hasReadGrantReference(tree))
        transfers.removePhotoBackupSource("b")
        assertFalse(transfers.hasReadGrantReference(tree))
    }
}
