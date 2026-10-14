package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.canPauseDownload
import io.github.qwertyuiop1995.dsmnativeclient.canResumeDownload
import io.github.qwertyuiop1995.dsmnativeclient.canRetryDownload
import io.github.qwertyuiop1995.dsmnativeclient.downloadFailureKind
import io.github.qwertyuiop1995.dsmnativeclient.shouldDeleteFailedDownload
import io.github.qwertyuiop1995.dsmnativeclient.shouldDeleteFailedForegroundDownload
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class ArchiveDownloadPlanStoreTest {
    private val preferences = MemoryPreferences()
    private val store = TransferStore(preferences)
    private val record = PersistedDownload(newArchiveDownloadId(), "profile-a", "/synthetic/a.txt ", "Selected.zip",
        "content://synthetic/target", isDirectory = true, workId = "worker-a")
    private val plan = ArchiveDownloadPlan(taskId = record.id, profileId = record.profileId,
        destinationUri = record.destinationUri, sources = listOf(
            ArchiveDownloadSource(record.sourcePath, "a.txt ", false),
            ArchiveDownloadSource("/synthetic/Empty", "Empty", true)))

    @Test fun restoreKeepsOrderedRawPathsAndLegacyDownload() {
        val legacy = record.copy(id = "legacy", isDirectory = false, expectedBytes = 8)
        store.upsert(legacy)
        assertTrue(store.createArchiveDownloadDurably(record, plan))
        val restored = TransferStore(preferences)
        assertEquals(record, restored.download(record.id))
        assertEquals(plan, restored.archiveDownloadPlan(record))
        assertNull(restored.archiveDownloadPlan(legacy))
        assertEquals(legacy, restored.download(legacy.id))
    }

    @Test fun repeatedEnqueueCannotReplaceOrExpandSources() {
        assertTrue(store.createArchiveDownloadDurably(record, plan))
        assertFalse(store.createArchiveDownloadDurably(record, plan.copy(sources = plan.sources +
            ArchiveDownloadSource("/synthetic/new.txt", "new.txt", false))))
        assertEquals(plan, store.archiveDownloadPlan(record))
    }

    @Test fun missingCorruptOrChangedIdentityNeverFallsBackToFirstItem() {
        assertThrows(IOException::class.java) { store.archiveDownloadPlan(record) }
        assertTrue(store.createArchiveDownloadDurably(record, plan))
        listOf(record.copy(profileId = "profile-b"), record.copy(destinationUri = "content://synthetic/other"),
            record.copy(sourcePath = "/other"), record.copy(expectedBytes = 100)).forEach {
            assertThrows(IOException::class.java) { store.archiveDownloadPlan(it) }
        }
        val key = preferences.all.keys.single { it.startsWith("archive_download_plan_v1_") }
        preferences.edit().putString(key, "{").commit()
        assertThrows(IOException::class.java) { store.archiveDownloadPlan(record) }
        assertFalse(plan.copy(schemaVersion = 2).matches(record))
        assertFalse(plan.copy(sources = emptyList()).matches(record))
        assertFalse(plan.copy(sources = plan.sources + plan.sources.first()).matches(record))
        assertFalse(plan.copy(sources = listOf(ArchiveDownloadSource("/", "root", true))).matches(record))
    }

    @Test fun archivePauseAndFailureRetainTargetWhileLegacyFolderFailureCleansUp() {
        assertTrue(record.canPauseDownload())
        assertTrue(record.copy(state = TransferState.PAUSED).canResumeDownload())
        val failed = record.copy(state = TransferState.FAILED)
        assertFalse(failed.shouldDeleteFailedDownload("worker-a"))
        assertFalse(shouldDeleteFailedForegroundDownload(failed, true))
        assertTrue(failed.canRetryDownload())
        val unavailable = downloadFailureKind(ArchiveDownloadPlanUnavailable())
        assertEquals(io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.DOWNLOAD_SOURCE_UNAVAILABLE, unavailable)
        assertFalse(failed.copy(errorKind = unavailable.name).canRetryDownload())
        assertTrue(failed.copy(id = "legacy-directory").shouldDeleteFailedDownload("worker-a"))
        store.createArchiveDownloadDurably(failed, plan)
        assertTrue(store.hasDownloadDestinationReference(record.destinationUri))
        assertFalse(store.hasDownloadDestinationReference(record.destinationUri, record.id))
        store.update(record.id) { it.copy(state = TransferState.SUCCEEDED) }
        assertFalse(store.hasDownloadDestinationReference(record.destinationUri))
    }

    @Test fun historyRemovalCleansOnlyMatchingPlan() {
        for (remove in 0..2) {
            val own = record.copy(id = newArchiveDownloadId(), state = TransferState.FAILED)
            assertTrue(store.createArchiveDownloadDurably(own, plan.copy(taskId = own.id)))
            val other = record.copy(id = newArchiveDownloadId(), profileId = "profile-b")
            assertTrue(store.createArchiveDownloadDurably(other, plan.copy(taskId = other.id, profileId = other.profileId)))
            when (remove) {
                0 -> store.removeTerminal(own.profileId)
                1 -> store.removeProfile(own.profileId)
                else -> store.remove(own.id)
            }
            assertNull(store.download(own.id))
            assertThrows(IOException::class.java) { store.archiveDownloadPlan(own) }
            assertNotNull(store.archiveDownloadPlan(other))
        }
    }

    @Test fun durableWriteFailureCannotAllowEnqueue() {
        preferences.commitSucceeds = false
        assertFalse(store.createArchiveDownloadDurably(record, plan))
    }
}
