package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.content.pm.PackageManager
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.systemfiles.*
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*
import java.io.FileInputStream
import java.io.FileOutputStream

/** 正式注册的提供器与真实 ContentResolver/PFD；只有远端 HTTP 被合成仓储替代。 */
class SystemDocumentsProviderTest {
    private val app = ApplicationProvider.getApplicationContext<Application>()
    private val profiles = SecureProfileStore(app)
    private val store = SystemDocumentStore(app)
    private val office = OfficeDocumentStore(app)
    private val fixture = SystemFileFixture()
    private val previousProfile = profiles.lastProfileId()
    private val authority get() = app.packageName + ".documents"
    private lateinit var location: SystemFileLocation
    private lateinit var owner: WorkspaceOwner
    private lateinit var provider: NasDocumentsProvider
    private lateinit var previousRuntime: Any
    private val runtimeField = NasDocumentsProvider::class.java.getDeclaredField("runtime\$delegate").apply { isAccessible = true }
    @Before fun prepare() {
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        location = store.enable(owner); profiles.bindRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id, owner)
        fixture.entries["/share/document.docx"] = SystemFileFixture.item("/share/document.docx")
        val repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        app.contentResolver.acquireContentProviderClient(authority)!!.use { provider = it.localContentProvider as NasDocumentsProvider }
        previousRuntime = runtimeField.get(provider)
        runtimeField.set(provider, lazyOf(SystemDocumentRuntime(store, profiles, { candidate ->
            check(candidate.owner.hasSameIdentity(owner)); repo
        }, office)))
    }
    @After fun cleanup() {
        if (::owner.isInitialized) runBlocking {
            withTimeout(8_000) { while (!office.canRemoveProfile(owner.profileId) && office.records(owner).any { office.externalActive(it) }) delay(10) }
            office.records(owner).forEach { office.discard(it, discardExternal = true) }
            store.removeProfile(owner.profileId); profiles.removeProfile(owner.profileId)
            profiles.setLastProfileId(previousProfile)
        }
        if (::previousRuntime.isInitialized) runtimeField.set(provider, previousRuntime)
    }
    private fun uri(id: String) = DocumentsContract.buildDocumentUri(authority, id)
    private fun doc() = store.document(store.location(location.id), "/share/document.docx", false)
    private fun flags(id: String): Int = app.contentResolver.query(uri(id), arrayOf(Document.COLUMN_FLAGS), null, null, null)!!.use {
        assertTrue(it.moveToFirst()); it.getInt(0)
    }
    private suspend fun received() {
        withTimeout(8_000) { while (office.records(owner).singleOrNull()?.let { it.externalId == null } != true) delay(10) }
    }
    @Test fun registeredProviderListsOpaqueDocumentsAndReturnsSeekableReadOnlyContent() {
        val info = app.packageManager.resolveContentProvider(authority, PackageManager.GET_META_DATA)!!
        assertTrue(info.exported); assertTrue(info.grantUriPermissions); assertEquals("android.permission.MANAGE_DOCUMENTS", info.readPermission)
        val roots = DocumentsContract.buildRootsUri(authority)
        app.contentResolver.query(roots, null, null, null, null)!!.use { cursor ->
            var found = false
            while (cursor.moveToNext()) if (cursor.getString(cursor.getColumnIndexOrThrow(DocumentsContract.Root.COLUMN_ROOT_ID)) == location.id) found = true
            assertTrue(found)
        }
        var shareId = ""
        app.contentResolver.query(DocumentsContract.buildChildDocumentsUri(authority, location.id), null, null, null, null)!!.use {
            assertTrue(it.moveToFirst()); shareId = it.getString(it.getColumnIndexOrThrow(Document.COLUMN_DOCUMENT_ID))
            assertEquals("share", it.getString(it.getColumnIndexOrThrow(Document.COLUMN_DISPLAY_NAME)))
        }
        app.contentResolver.query(DocumentsContract.buildChildDocumentsUri(authority, shareId), null, null, null, null)!!.use { assertEquals(2, it.count) }
        val document = doc(); assertEquals(0, flags(document.id) and Document.FLAG_SUPPORTS_WRITE)
        app.contentResolver.openFileDescriptor(uri(document.id), "r")!!.use { descriptor ->
            val input = FileInputStream(descriptor.fileDescriptor); assertEquals(3L, descriptor.statSize)
            input.channel.position(1); assertEquals('b'.code, input.read())
        }
        try { app.contentResolver.openFileDescriptor(uri(document.id), "rw"); fail("Read only") } catch (_: java.io.FileNotFoundException) { }
        assertTrue(office.records(owner).isEmpty())
    }
    @Test fun externalEditorCloseOnlyReceivesLocalCopyAndPreservesOriginal() = runBlocking {
        location = store.update(location, true, editing = true); val document = doc()
        assertTrue(flags(document.id) and Document.FLAG_SUPPORTS_WRITE != 0)
        app.contentResolver.openFileDescriptor(uri(document.id), "rwt")!!.use { descriptor ->
            val output = FileOutputStream(descriptor.fileDescriptor); output.write("edited-document".toByteArray()); output.flush()
            assertFalse(office.records(owner).single().canSave)
            try { app.contentResolver.openFileDescriptor(uri(document.id), "rw"); fail("Only one editor") } catch (_: java.io.FileNotFoundException) { }
        }
        received(); val row = office.records(owner).single()
        assertEquals(OfficeDocumentPhase.CHANGED, row.phase); assertTrue(row.canSave)
        assertEquals("abc", office.artifact(row.id, row.originalId).readText())
        assertEquals("edited-document", office.artifact(row.id, row.localId).readText())
        app.contentResolver.openInputStream(uri(document.id))!!.use { assertEquals("edited-document", it.reader().readText()) }
        assertFalse(fixture.calls.any { it["api"] == "SYNO.FileStation.Upload" })
    }
    @Test fun errorCloseKeepsRecoveryCopyAndDisabledOrSignedOutUrisRefuseReads() = runBlocking {
        location = store.update(location, true, editing = true); val document = doc()
        val descriptor = app.contentResolver.openFileDescriptor(uri(document.id), "rw")!!
        FileOutputStream(descriptor.fileDescriptor).apply { write("edited-document".toByteArray()); flush() }
        descriptor.closeWithError("synthetic-close-error")
        withTimeout(8_000) { while (office.records(owner).single().let { office.externalActive(it) }) delay(10) }
        val row = office.records(owner).single(); assertNotNull(row.externalId); assertFalse(row.canSave)
        assertTrue(office.artifact(row.id, row.externalId!!).exists())
        OfficeDocumentTransfer(office).receiveExternal(row.id, owner)
        store.update(location, false)
        try { app.contentResolver.openInputStream(uri(document.id)); fail("Disabled location") } catch (_: java.io.FileNotFoundException) { }
        store.enable(owner); profiles.signOut(owner)
        assertNull(runCatching { app.contentResolver.query(uri(document.id), null, null, null, null) }.getOrNull())
        assertFalse(fixture.calls.any { it["api"] == "SYNO.FileStation.Upload" })
    }
    @Test fun cancellationAndTreeScopeCannotOpenAnUnrelatedDocument() {
        val document = doc(); val cancelled = CancellationSignal().apply { cancel() }
        try { app.contentResolver.openFileDescriptor(uri(document.id), "r", cancelled); fail("Cancelled") } catch (_: android.os.OperationCanceledException) { }
        val parent = store.document(location, "/share/folder", true)
        assertFalse(provider.isChildDocument(parent.id, document.id))
        assertTrue(provider.isChildDocument(location.id, document.id))
        val path = provider.findDocumentPath(null, document.id)
        assertEquals(location.id, path.rootId); assertEquals(location.id, path.path.first()); assertEquals(document.id, path.path.last())
        assertEquals(listOf("", "/share", "/share/document.docx"), path.path.map { store.document(it).path })
        try { provider.findDocumentPath(parent.id, document.id); fail("Unrelated parent") } catch (_: java.io.FileNotFoundException) { }

        try { app.contentResolver.openInputStream(uri("/share/document.docx")); fail("Opaque IDs only") } catch (_: java.io.FileNotFoundException) { }
    }
}
