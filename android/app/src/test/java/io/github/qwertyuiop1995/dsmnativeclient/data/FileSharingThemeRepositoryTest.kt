package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileSettingsFixture
import io.github.qwertyuiop1995.dsmnativeclient.testing.FileSettingsFixture.Companion.imageRow
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class FileSharingThemeRepositoryTest {
    @Test fun themeRequiresRecordedTypesAndPreservesOptionalSequences() = runBlocking {
        val f = FileSettingsFixture(); val first = f.settings.reader.theme()
        assertEquals("1", first.logoSequence); assertEquals("2", first.backgroundSequence)
        f.theme = JsonObject(f.theme - "logo_seq" + ("background_seq" to JsonNull))
        assertNull(f.settings.reader.theme().logoSequence); assertNull(f.settings.reader.theme().backgroundSequence)
        for ((key, value) in listOf("enable_logo_customize" to JsonPrimitive("false"), "logo_position" to JsonPrimitive("unknown"),
                "background_position" to JsonPrimitive("unknown"), "logo_seq" to JsonPrimitive(true), "logo_seq" to JsonPrimitive(1.5))) {
            f.theme = JsonObject(FileSettingsFixture.initialTheme() + (key to value)); failure { f.settings.reader.theme() }
        }
    }
    @Test fun layoutWritesFullRecordedFieldsAndReloadsCompleteResult() = runBlocking {
        val f = FileSettingsFixture(); val old = f.settings.reader.theme()
        val next = old.copy(footer = "Synthetic footer", backgroundColor = "#123AbC", footerUsesHtml = true,
            logoPosition = FileThemeLogoPosition.BOTTOM_LEFT, backgroundPosition = FileThemeBackgroundPosition.TILE)
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, f.settings.changeSettingsResult(FileSettingsChange.Theme(old, next), true).status)
        val fields = f.writes().single().filterKeys { it !in setOf("api", "method", "version", "_sid") }
        assertEquals(next.settingsValue().mapValues { it.value.jsonPrimitive.content }, fields)
        assertTrue(f.settings.pending().isEmpty())
    }
    @Test fun invalidThemeNeverWritesAndChangingDisabledImageNeedsSelection() = runBlocking {
        val f = FileSettingsFixture(); val old = f.settings.reader.theme()
        for (next in listOf(old, old.copy(customLogo = true), old.copy(customBackground = true), old.copy(footer = "x".repeat(513)),
                old.copy(footer = "a\nb"), old.copy(backgroundColor = "red"), old.copy(logoSequence = "3"),
                old.copy(logoImage = FileThemeImage.defaults.first()), old.copy(owner = old.owner.copy(sessionGeneration = "other"))))
            failure { f.settings.changeSettingsResult(FileSettingsChange.Theme(old, next), true) }
        assertTrue(f.writes().isEmpty())
        failure { f.settings.changeSettingsResult(FileSettingsChange.Theme(old, old.copy(footer = "new")), false) }
    }
    @Test fun changedBaselineAndRevokedAdminOrCoreAccessPreventThemeWrites() = runBlocking {
        for (mode in 0..3) {
            val f = FileSettingsFixture(); val old = f.settings.reader.theme()
            when (mode) {
                0 -> f.theme = JsonObject(f.theme + ("logo_seq" to JsonPrimitive("9")))
                1 -> f.administrator = false
                2 -> f.nasAllowed = false
                3 -> f.ownerValid = false
            }
            failure { f.settings.changeSettingsResult(FileSettingsChange.Theme(old, old.copy(footer = "new")), true) }
            assertTrue(f.writes().isEmpty())
        }
    }
    @Test fun historyReResolvesStablePathBeforePreviewAndCredentialsStayOutOfUrl() = runBlocking {
        val f = FileSettingsFixture(); val kind = FileThemeImageKind.LOGO
        f.themeImages = f.themeImages + (kind to listOf(imageRow("/history/logo.png", 1)))
        val selected = f.settings.images.history(kind).single()
        f.themeImages = f.themeImages + (kind to listOf(imageRow("/history/other.png", 1), imageRow(selected.path, 7)))
        val file = File.createTempFile("theme-preview", ".png")
        try {
            f.settings.images.download(selected, file)
            assertEquals("7", f.calls.last()["index"]); assertEquals("true", f.calls.last()["is_thumbnail"])
            assertArrayEquals(f.imageBytes, file.readBytes())
            assertNull(f.lastRequest!!.url.queryParameter("_sid")); assertNull(f.lastRequest!!.url.queryParameter("SynoToken"))
            assertEquals("id=synthetic", f.lastRequest!!.header("Cookie"))
        } finally { file.delete() }
    }
    @Test fun historyRejectsDuplicateIdentityAndInvalidIndexOrPath() = runBlocking {
        val f = FileSettingsFixture(); val kind = FileThemeImageKind.LOGO
        for (rows in listOf(listOf(imageRow("/history/a.png", 0), imageRow("/history/a.png", 1)),
                listOf(imageRow("/history/a.png", 0), imageRow("/history/b.png", 0)), listOf(imageRow("/history/a.png", -1)),
                listOf(imageRow("/history/../a.png", 0)), listOf(imageRow("/history/a.txt", 0)))) {
            f.themeImages = f.themeImages + (kind to rows); failure { f.settings.images.history(kind) }
        }
    }
    @Test fun defaultsAreExactAndDoNotSendCredentials() = runBlocking {
        val f = FileSettingsFixture(); val image = FileThemeImage.defaults.last(); assertEquals("dsm7_010.jpg", image.path)
        val file = File.createTempFile("theme-default", ".png")
        try {
            f.settings.images.download(image, file)
            assertTrue(f.lastRequest!!.url.encodedPath.endsWith("/default_login_background/dsm7_010.jpg"))
            assertNull(f.lastRequest!!.header("Cookie")); assertNull(f.lastRequest!!.header("X-SYNO-TOKEN"))
            failure { f.settings.images.validate(image.copy(kind = FileThemeImageKind.LOGO)) }
            failure { f.settings.images.validate(image.copy(path = "dsm7_10.jpg")) }
        } finally { file.delete() }
    }
    @Test fun nasSelectionRequiresExactReadableFileAndKeepsFullPath() = runBlocking {
        val f = FileSettingsFixture(); val image = FileThemeImage(FileThemeImageKind.LOGO, FileThemeImageSource.NAS, "/synthetic/logo.png", "logo.png")
        var directory = false; var canRead = true; var path = image.path
        f.overrideResponse = { fields -> if (fields["api"] == "SYNO.FileStation.List") buildJsonObject { putJsonArray("files") {
            add(buildJsonObject { put("path", path); put("name", "logo.png"); put("isdir", directory); putJsonObject("additional") { putJsonObject("perm") { put("read", canRead) } } })
        } } else null }
        assertEquals(image, f.settings.images.validate(image))
        val old = f.settings.reader.theme(); val change = FileSettingsChange.Theme(old, old.copy(customLogo = true, logoImage = image))
        assertEquals(image.path, change.parameters()["logo_path"])
        path = "/synthetic/literal\\name.png"
        assertEquals(path, f.settings.images.validate(image.copy(path = path)).path)
        path = image.path
        directory = true; failure { f.settings.images.validate(image) }
        directory = false; canRead = false; failure { f.settings.images.validate(image) }
        canRead = true; path = "/synthetic/other.png"; failure { f.settings.images.validate(image) }
    }
    @Test fun acknowledgedImageNeedsSequenceChangeAndOldDigestSurvivesReopen() = runBlocking {
        val f = FileSettingsFixture(); f.advanceThemeSequences = false
        val old = f.settings.reader.theme(); val next = old.copy(customBackground = true, backgroundImage = FileThemeImage.defaults.first())
        val change = FileSettingsChange.Theme(old, next)
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, f.settings.changeSettingsResult(change, true).status)
        val record = f.settings.pending().single(); assertTrue(record.acknowledged)
        assertEquals(themeSequenceDigest(old.backgroundSequence), record.backgroundBefore)
        assertFalse(f.preferences.all.toString().contains("dsm7_01.jpg"))
        val reopened = FileSettingsFixture(session = "new-session", preferences = f.preferences)
        reopened.theme = JsonObject(f.theme + ("background_seq" to JsonPrimitive("3")))
        val refreshed = reopened.settings.reader.theme()
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, reopened.settings.review(FileSettingsChange.Theme(refreshed, refreshed.copy(footer = "ignored"))).status)
        assertTrue(reopened.writes().isEmpty())
    }
    @Test fun lostAcknowledgementDoesNotBecomeSuccessFromSequenceAlone() = runBlocking {
        val f = FileSettingsFixture(); val old = f.settings.reader.theme()
        f.afterWrite = { throw DsmFailure(null, "Interrupted", "Refresh", kind = DsmErrorKind.CONNECTION_FAILED) }
        val change = FileSettingsChange.Theme(old, old.copy(customBackground = true, backgroundImage = FileThemeImage.defaults.first()))
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, f.settings.changeSettingsResult(change, true).status)
        assertFalse(f.settings.pending().single().acknowledged)
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, f.settings.review(change).status)
        assertEquals(1, f.writes().size)
    }
    @Test fun bothSelectedImagesRequireIndependentSequenceChanges() = runBlocking {
        val f = FileSettingsFixture(); val old = f.settings.reader.theme()
        f.themeImages = f.themeImages + (FileThemeImageKind.LOGO to listOf(imageRow("/history/logo.png", 0)))
        val logo = f.settings.images.history(FileThemeImageKind.LOGO).single()
        f.afterWrite = { f.theme = JsonObject(f.theme + ("background_seq" to JsonPrimitive(old.backgroundSequence))) }
        val change = FileSettingsChange.Theme(old, old.copy(customLogo = true, customBackground = true, logoImage = logo, backgroundImage = FileThemeImage.defaults.first()))
        assertEquals(FileSettingsOutcomeStatus.UNKNOWN, f.settings.changeSettingsResult(change, true).status)
        f.theme = JsonObject(f.theme + ("background_seq" to JsonPrimitive("4")))
        assertEquals(FileSettingsOutcomeStatus.COMPLETED, f.settings.review(change).status)
    }
    @Test fun uploadUsesMultipartAndHistoryIdentityWithoutApplyingTheme() = runBlocking {
        val f = FileSettingsFixture(); withUpload { input ->
            val result = f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true)
            assertEquals(FileSettingsOutcomeStatus.COMPLETED, result.status); assertEquals(f.uploadedPath, result.image?.path)
            assertTrue(f.uploadBody.contains("name=\"upload_image\"; filename=\"synthetic.png\""))
            assertTrue(f.calls.single { it["method"] == "upload" }.keys.containsAll(listOf("api", "method", "version", "type", "_sid")))
            assertTrue(f.writes().isEmpty()); assertTrue(f.settings.pending().isEmpty())
        }
    }
    @Test fun unknownUploadBlocksSameContentAcrossReopenButNotOtherKindOrSettings() = runBlocking {
        val f = FileSettingsFixture(); f.afterWrite = { if (it["method"] == "upload") throw DsmFailure(null, "Interrupted", "Refresh", kind = DsmErrorKind.CONNECTION_FAILED) }
        withUpload { input ->
            assertEquals(FileSettingsOutcomeStatus.UNKNOWN, f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true).status)
            val reopened = FileSettingsFixture(session = "new-session", preferences = f.preferences)
            failure { reopened.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true) }
            assertTrue(reopened.calls.none { it["method"] == "upload" })
            assertEquals(FileSettingsOutcomeStatus.COMPLETED, reopened.settings.uploadThemeImageResult(input, FileThemeImageKind.BACKGROUND, true).status)
            val old = reopened.settings.reader.theme()
            assertEquals(FileSettingsOutcomeStatus.COMPLETED, reopened.settings.changeSettingsResult(FileSettingsChange.Theme(old, old.copy(footer = "new")), true).status)
            assertEquals(1, reopened.settings.pending().size)
        }
    }
    @Test fun changedFileOrDeniedUploadNeverSendsAndDefiniteRejectionClearsOnlyItsRecord() = runBlocking {
        val f = FileSettingsFixture()
        withUpload { input ->
            failure { f.settings.uploadThemeImageResult(input.copy(filename = "bad\n.png"), FileThemeImageKind.LOGO, true) }
            failure { f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, false) }
            input.file.appendText("changed"); failure { f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true) }
            assertTrue(f.calls.none { it["method"] == "upload" })
        }
        withUpload { input ->
            f.responseError = { if (it["method"] == "upload") 105 else null }
            assertEquals(FileSettingsOutcomeStatus.REJECTED, f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true).status)
            assertTrue(f.settings.pending().isEmpty())
        }
    }
    @Test fun acknowledgedUploadMissingFromHistoryRemainsUnknown() = runBlocking {
        val f = FileSettingsFixture(); f.applyWrites = false
        withUpload { input ->
            assertEquals(FileSettingsOutcomeStatus.UNKNOWN, f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true).status)
            assertTrue(f.settings.pending().single().acknowledged)
            failure { f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true) }
            assertEquals(1, f.calls.count { it["method"] == "upload" })
        }
    }
    @Test fun cancelledUploadPreservesSubmissionFactAndNeverAutomaticallyReplays() = runBlocking {
        val f = FileSettingsFixture(); val entered = java.util.concurrent.CountDownLatch(1); val release = java.util.concurrent.CountDownLatch(1)
        f.before = { if (it["method"] == "upload") { entered.countDown(); check(release.await(5, java.util.concurrent.TimeUnit.SECONDS)) } }
        withUpload { input ->
            val job = launch(Dispatchers.Default) { f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true) }
            try {
                withContext(Dispatchers.IO) { assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS)) }
                job.cancelAndJoin(); assertEquals(1, f.settings.pending().size)
                failure { f.settings.uploadThemeImageResult(input, FileThemeImageKind.LOGO, true) }
                assertEquals(1, f.calls.count { it["method"] == "upload" })
            } finally { release.countDown(); job.cancelAndJoin() }
        }
    }
    private suspend fun withUpload(block: suspend (FileThemeUpload) -> Unit) {
        val file = File.createTempFile("synthetic-theme", ".png")
        try { file.writeBytes(byteArrayOf(1, 2, 3, 4)); block(FileThemeUpload(file, "synthetic.png", file.length(), themeFileDigest(file))) }
        finally { file.delete() }
    }
    private suspend fun failure(block: suspend () -> Any?) {
        try { block(); fail("Expected rejection") } catch (_: DsmFailure) { }
    }
}
