package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import org.junit.Assert.*
import org.junit.Test

class FileVFSFormTest {
    private val protocols = listOf(FileVFSProtocol("ftp", "FTP", 21, false), FileVFSProtocol("sftp", "SFTP", 22, false),
        FileVFSProtocol("dav", "WebDAV", 80, false), FileVFSProtocol("davs", "WebDAV HTTPS", 443, false))
    private val draft = FileVFSConfiguration("davs", "server.invalid", 443, "Synthetic", "synthetic-account")
    @Test fun webDavAddressResolvesProtocolPortAndDecodedFolderWithoutChangingFilenameSpaces() {
        val result = draft.copy(protocolId = "dav", hostname = "https://server.invalid/Shared%20Files", port = 80).resolved(protocols)
        assertEquals("davs", result.protocolId); assertEquals(443, result.port); assertEquals("Shared Files", result.folder)
        assertFalse(result.usesCleartext)
        assertEquals(" folder ", draft.copy(folder = "/ folder ").resolved(protocols).folder)
    }
    @Test fun explicitPortSurvivesResolutionAndEditingCannotSwitchProtocol() {
        assertEquals(8443, draft.copy(hostname = "https://server.invalid", port = 8443).resolved(protocols).port)
        assertEquals(9443, draft.copy(hostname = "https://server.invalid:9443").resolved(protocols).port)
        assertTrue(runCatching { draft.copy(hostname = "http://server.invalid").resolved(protocols, "davs") }.isFailure)
    }
    @Test fun ambiguousCredentialsQueryFragmentAndConflictingFoldersAreRejected() {
        for (address in listOf("https://user:secret@server.invalid", "https://server.invalid?query=1", "https://server.invalid#fragment",
            "ftp://server.invalid", "server.invalid:443", "server.invalid/path")) {
            assertTrue(address, runCatching { draft.copy(hostname = address).resolved(protocols) }.isFailure)
        }
        assertTrue(runCatching { draft.copy(hostname = "https://server.invalid/one", folder = "two").resolved(protocols) }.isFailure)
    }
    @Test fun savedAdvancedFieldsArePreservedAndAvailabilityIsDynamic() {
        assertTrue(draft.copy(protocolId = "ftp", port = 21, usesOneConnection = true).resolved(protocols).usesCleartext)
        assertTrue(draft.copy(usesOneConnection = true).resolved(protocols).usesOneConnection)
        assertEquals("folder", draft.copy(protocolId = "sftp", folder = "folder").resolved(protocols).folder)
        assertTrue(runCatching { draft.copy(protocolId = "sftp", hostname = "sftp://server.invalid/folder").resolved(protocols) }.isFailure)
        assertTrue(runCatching { draft.resolved(protocols.filterNot { it.id == "davs" }) }.isFailure)
        assertTrue(FileVFSProtocol("google", "Google", null, false).supportsCloudAuthorization)
        assertFalse(FileVFSProtocol("unknown", "Other", null, false).supportsCloudAuthorization)
    }
}
