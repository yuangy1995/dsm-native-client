package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.downloadFailureKind
import io.github.qwertyuiop1995.dsmnativeclient.testing.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class FileVFSDownloadPlanTest {
    private val fixture = FileVFSFixture()
    private val source = FileVFSDownloadSource(fixture.original, fixture.original.uri, fixture.original.uri + "/report.txt", "report.txt", 8, 10)
    private val record = PersistedDownload(newVFSDownloadId(), fixture.nas.id, source.path, source.name, "content://synthetic/target", false, expectedBytes = 8)
    private val plan = FileVFSDownloadPlan(taskId = record.id, destinationUri = record.destinationUri, source = source)
    @Test fun durablePlanPreservesRawUriAndDoesNotReplaceLegacyOrExistingTask() {
        val preferences = MemoryPreferences(); val store = TransferStore(preferences)
        val legacy = record.copy(id = "legacy", sourcePath = "/synthetic/file")
        store.upsert(legacy); assertTrue(store.createVFSDownloadDurably(record, plan))
        assertEquals(plan, TransferStore(preferences).vfsDownloadPlan(record)); assertNull(store.vfsDownloadPlan(legacy))
        assertFalse(store.createVFSDownloadDurably(record, plan)); assertEquals(legacy, store.download(legacy.id))
        assertFalse(preferences.all.values.joinToString().contains("access_token")); assertFalse(preferences.all.values.joinToString().contains("password"))
    }
    @Test fun lostChangedOrCorruptPlanNeverFallsBackToBareUri() {
        val preferences = MemoryPreferences(); val store = TransferStore(preferences)
        assertThrows(FileVFSDownloadPlanUnavailable::class.java) { store.vfsDownloadPlan(record) }
        store.createVFSDownloadDurably(record, plan)
        listOf(record.copy(profileId = "another"), record.copy(sourcePath = source.path + "new"), record.copy(destinationUri = "content://synthetic/other"),
            record.copy(isDirectory = true), record.copy(expectedBytes = 9)).forEach {
            assertThrows(FileVFSDownloadPlanUnavailable::class.java) { store.vfsDownloadPlan(it) }
        }
        preferences.edit().putString(preferences.all.keys.single { it.startsWith("vfs_download_plan_v1_") }, "{").commit()
        assertThrows(FileVFSDownloadPlanUnavailable::class.java) { store.vfsDownloadPlan(record) }
        assertEquals(DsmErrorKind.DOWNLOAD_SOURCE_UNAVAILABLE, downloadFailureKind(FileVFSDownloadPlanUnavailable()))
    }
    @Test fun failedSavePreventsQueueAndHistoryRemovalOnlyCleansMatchingSource() {
        val preferences = MemoryPreferences(); val store = TransferStore(preferences)
        preferences.commitSucceeds = false; assertFalse(store.createVFSDownloadDurably(record, plan))
        for (removal in 0..2) {
            val memory = MemoryPreferences(); val transfer = TransferStore(memory)
            val own = record.copy(state = TransferState.FAILED)
            val other = record.copy(id = newVFSDownloadId(), profileId = "other")
            val otherSource = source.copy(profile = source.profile.copy(owner = source.profile.owner.copy(profileId = "other")))
            assertTrue(transfer.createVFSDownloadDurably(own, plan))
            assertTrue(transfer.hasDownloadDestinationReference(own.destinationUri))
            assertFalse(transfer.hasDownloadDestinationReference(own.destinationUri, own.id))
            assertTrue(transfer.createVFSDownloadDurably(other, plan.copy(taskId = other.id, source = otherSource)))
            when (removal) { 0 -> transfer.remove(own.id); 1 -> transfer.removeTerminal(own.profileId); else -> transfer.removeProfile(own.profileId) }
            assertThrows(FileVFSDownloadPlanUnavailable::class.java) { transfer.vfsDownloadPlan(own) }
            assertNotNull(transfer.vfsDownloadPlan(other))
        }
    }
    @Test fun resumedDownloadFindsOriginalItemAcrossPagesBeforeOpeningOutput() = runBlocking {
        fixture.children = { path, offset -> FilePage(listOf(if (offset == 0) FileItem(path + "/a.txt", "a.txt", false)
            else source.item()), 2, offset) }
        assertEquals(source.item(), fixture.repository.fileMounts.vfs.reader.requireDownloadSource(source))
        assertEquals(listOf("0", "1"), fixture.calls.filter { it["api"] == "SYNO.FileStation.List" }.map { it["offset"] })
        assertTrue(fixture.writes().isEmpty())
    }
    @Test fun changedConnectionFileMetadataAndReadPermissionRejectOriginalSource() = runBlocking {
        fixture.profiles = listOf(fixture.original.copy(account = "other"))
        assertTrue(runCatching { fixture.repository.fileMounts.vfs.reader.requireDownloadSource(source) }.isFailure)
        assertTrue(fixture.calls.none { it["api"] == "SYNO.FileStation.List" })
        fixture.profiles = listOf(fixture.original)
        for (item in listOf(source.item().copy(size = 9), source.item().copy(modifiedAtEpochSeconds = 11), source.item().copy(canRead = false), source.item().copy(isDirectory = true))) {
            fixture.children = { _, _ -> FilePage(listOf(item), 1, 0) }
            assertTrue(runCatching { fixture.repository.fileMounts.vfs.reader.requireDownloadSource(source) }.exceptionOrNull() is FileVFSDownloadPlanUnavailable)
        }
    }
    @Test fun connectionChangingDuringDirectoryReadAndParentMismatchAreRejected() = runBlocking {
        fixture.before = { fields -> if (fields["api"] == "SYNO.FileStation.List") fixture.profiles = listOf(fixture.original.copy(account = "changed")) }
        assertTrue(runCatching { fixture.repository.fileMounts.vfs.reader.requireDownloadSource(source) }.isFailure)
        assertFalse(source.copy(parent = fixture.original.uri + "/different").valid())
        assertTrue(fixture.writes().isEmpty())
    }
    @Test fun incompleteChangedPagesAndUnavailableFolderCannotBeAcceptedAsEmpty() = runBlocking {
        fixture.children = { path, offset -> if (offset == 0) FilePage(listOf(FileItem(path + "/a.txt", "a.txt", false)), 2, 0)
            else FilePage(listOf(source.item()), 3, 1) }
        assertTrue(runCatching { fixture.repository.fileMounts.vfs.reader.requireDownloadSource(source) }.isFailure)
        fixture.folderFailure = true
        assertTrue(runCatching { fixture.repository.fileMounts.vfs.reader.requireDownloadSource(source) }.isFailure)
        assertTrue(fixture.writes().isEmpty())
    }
}
