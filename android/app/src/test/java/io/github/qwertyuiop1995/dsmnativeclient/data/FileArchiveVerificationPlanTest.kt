package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class FileArchiveVerificationPlanTest {
    private val preferences = MemoryPreferences()
    private val store = TransferStore(preferences)
    private val record = PersistedServerTransfer(newFileExtractionId(), "profile-a", "archive.zip", PersistedServerOperation.EXTRACT,
        executionGeneration = 7, sourceBaselines = listOf(PersistedServerFileBaseline("/share/archive.zip", "archive.zip", false)),
        destinationFolderBaseline = PersistedServerFileBaseline("/share/target", "target", true))
    private val outputs = listOf(FileServerMutationExpectedOutput("/share/target/a.txt", false, expectedBytes = 12, requiresTaskCompletion = true))

    @Test fun `独立清单与任务同时保存并在新存储实例中恢复`() {
        store.upsert(record)
        val updated = store.updateExtractionOutputs(record.id, 7, outputs)!!
        val restored = TransferStore(preferences)
        assertEquals(outputs, restored.extractionOutputs(updated))
        assertEquals(listOf(PersistedServerExpectedOutput("/share/target/a.txt", false)), updated.expectedOutputs)
        val legacy = record.copy(id = "legacy", expectedOutputs = updated.expectedOutputs)
        assertEquals(legacy.expectedOutputs.map { it.toFileServerMutationExpectedOutput() }, restored.extractionOutputs(legacy))
    }

    @Test fun `清单缺失损坏或归属改变不能退回旧的存在性判断`() {
        assertThrows(FileArchiveVerificationUnavailable::class.java) { store.extractionOutputs(record) }
        store.upsert(record)
        val saved = store.updateExtractionOutputs(record.id, 7, outputs)!!
        for (changed in listOf(saved.copy(profileId = "other"), saved.copy(expectedOutputs = emptyList()), saved.copy(sourceBaselines = emptyList()))) {
            assertThrows(FileArchiveVerificationUnavailable::class.java) { store.extractionOutputs(changed) }
        }
        preferences.edit().putString(fileArchiveVerificationKey(record.id), "{").commit()
        assertThrows(FileArchiveVerificationUnavailable::class.java) { store.extractionOutputs(saved) }
        assertEquals(DsmErrorKind.ARCHIVE_RECOVERY_UNAVAILABLE, FileArchiveVerificationUnavailable().asDsmFailure().kind)
    }

    @Test fun `过时代次与已提交状态不能重写输出`() {
        store.upsert(record)
        assertNull(store.updateExtractionOutputs(record.id, 6, outputs))
        store.updateExtractionOutputs(record.id, 7, outputs)
        store.updateServer(record.id) { it.copy(submissionPhase = PersistedServerSubmissionPhase.SUBMITTED) }
        assertNull(store.updateExtractionOutputs(record.id, 7, outputs))
        assertEquals(outputs, store.extractionOutputs(store.server(record.id)!!))
    }

    @Test fun `持久保存失败向调用方抛错而非返回可提交记录`() {
        store.upsert(record)
        preferences.commitSucceeds = false
        assertThrows(IllegalStateException::class.java) { store.updateExtractionOutputs(record.id, 7, outputs) }
    }

    @Test fun `结束任务清理只移除相应清单未知任务保持恢复事实`() {
        store.upsert(record)
        store.updateExtractionOutputs(record.id, 7, outputs)
        val other = record.copy(id = newFileExtractionId(), profileId = "profile-b")
        store.upsert(other); store.updateExtractionOutputs(other.id, 7, outputs)
        assertFalse(store.removeServer(record.id))
        store.updateServer(record.id) { it.copy(state = TransferState.SUCCEEDED, submissionPhase = PersistedServerSubmissionPhase.TERMINAL) }
        assertTrue(store.removeServer(record.id))
        assertFalse(preferences.contains(fileArchiveVerificationKey(record.id)))
        assertEquals(outputs, store.extractionOutputs(store.server(other.id)!!))
    }
}
