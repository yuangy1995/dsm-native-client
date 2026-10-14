package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceUntilIdle
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoExportModelTest {
    @Test fun `导出下载与本机保存分别持有租约选择器等待不占用系统时间`() = runTest {
        val cache = Files.createTempDirectory("photo-export-execution-").toFile()
        val fixture = Fixture(); val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture()
        val owner = WorkspaceOwner(fixture.profileId, "synthetic", "session")
        val model = SynologyPhotoExportModel(fixture, this, execution = execution, owner = owner)
        try {
            model.open(SynologyPhotoExportRequest.Items(listOf(photo)))
            model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join()
            assertEquals(listOf(1), execution.leases.map { it.finishes }); assertTrue(model.state.value.awaitingPicker)
            model.deliver(model.state.value.id!!, SynologyPhotoExportDestination { _, _, _, check -> check() }, cache)!!.join()
            assertEquals(listOf(1, 1), execution.leases.map { it.finishes }); assertEquals(1, model.state.value.saved)
            model.open(SynologyPhotoExportRequest.Items(listOf(photo))); execution.denied = true
            model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join()
            assertEquals(io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.BACKGROUND_EXECUTION_UNAVAILABLE, (model.state.value.error as DsmFailure).kind)
            assertEquals(1, fixture.downloads.size)
        } finally { model.dismiss(); cache.deleteRecursively() }
    }

    @Test fun `已经开始的照片导出退后台继续系统取消后只清理本次暂存`() = runTest {
        val cache = Files.createTempDirectory("photo-background-export-").toFile()
        val fixture = Fixture(); val execution = io.github.qwertyuiop1995.dsmnativeclient.testing.ExecutionFixture()
        val owner = WorkspaceOwner(fixture.profileId, "synthetic", "session")
        val root = SynologyPhotosModel(fixture, this, uploadOwner = owner, execution = execution)
        try {
            root.activate(); advanceUntilIdle()
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            fixture.hook = { entered.complete(Unit); release.await() }
            assertTrue(root.exports.open(SynologyPhotoExportRequest.Items(listOf(photo))))
            val preparing = root.exports.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!
            entered.await(); root.deactivate(preservePreparedExport = true)
            assertTrue(preparing.isActive); assertEquals(0, execution.leases.single().finishes)
            release.complete(Unit); preparing.join(); assertTrue(root.exports.state.value.awaitingPicker)
            assertEquals(1, execution.leases.single().finishes)
            val copying = CompletableDeferred<Unit>()
            val saving = root.exports.deliver(root.exports.state.value.id!!, SynologyPhotoExportDestination { _, _, _, check ->
                copying.complete(Unit); while (true) { delay(10); check() }
            }, cache)!!
            copying.await(); root.deactivate(preservePreparedExport = true); execution.leases.last().expire(); saving.join()
            assertEquals(0, root.exports.state.value.saved); assertTrue(root.exports.state.value.cancelled)
            assertTrue(cache.listFiles()!!.isEmpty()); assertEquals(listOf(1, 1), execution.leases.map { it.finishes })
        } finally { root.close(); cache.deleteRecursively() }
    }
    @Test fun `整册整目录与混选导出不能穿过持久未决的原件编辑`() = runTest {
        val cache = Files.createTempDirectory("photo-pending-export-").toFile()
        val fixture = Fixture()
        val serving = object : SynologyPhotosServing by fixture {
            override val canEditPhotos = true
            override suspend fun photoEditIdentity() = 41L
        }
        val owner = WorkspaceOwner(fixture.profileId, "synthetic", "session")
        val store = SynologyPhotoEditStore(MemoryPreferences())
        val row = SynologyPhotoEditRecord(owner = owner, checkpoint = SynologyPhotoEditCheckpoint(
            profileId = owner.profileId, userId = 41, space = SynologyPhotoSpace.PERSONAL,
            targets = listOf(SynologyPhotoEditTarget(photo)), edit = SynologyPhotoEdit.Rating(3)))
        store.begin(row); store.save(row.id, owner, 41, row.checkpoint.copy(phase = SynologyPhotoEditPhase.SUBMITTING, attempted = setOf(0)))
        try {
            SynologyPhotosModel(serving, this, uploadOwner = owner, editStore = store).use { root ->
                root.activate(); advanceUntilIdle()
                for (target in listOf(SynologyPhotoArchiveTarget.Album(7), SynologyPhotoArchiveTarget.Folder(9, SynologyPhotoSpace.PERSONAL),
                    SynologyPhotoArchiveTarget.Selection(emptyList(), listOf(SynologyPhotoCollection(10, "child", 9, path = "/child"))))) {
                    assertTrue(root.exports.open(SynologyPhotoExportRequest.Archive(target, "Synthetic")))
                    root.exports.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join()
                    assertEquals(SynologyPhotoEditProblem.PENDING, (root.exports.state.value.error as SynologyPhotoEditFailure).problem)
                    assertNull(fixture.archive); assertTrue(fixture.downloads.isEmpty())
                }
            }
        } finally { cache.deleteRecursively() }
    }
    @Test fun `格式选项按实际单项类型能力多项限制且固定初始清单`() = runTest {
        val fixture = Fixture(); val model = SynologyPhotoExportModel(fixture, this)
        val photos = mutableListOf(photo)
        assertTrue(model.open(SynologyPhotoExportRequest.Items(photos), true)); photos.clear()
        assertEquals(listOf(photo), (model.state.value.request as SynologyPhotoExportRequest.Items).photos)
        assertEquals(SynologyPhotoDownloadFormat.entries.toList(), model.state.value.formats)
        for (p in listOf(photo.copy(mediaType = "video"), photo.copy(filename = "Synthetic.gif"), photo.copy(filename = "Synthetic.WEBP"))) {
            assertTrue(model.open(SynologyPhotoExportRequest.Items(listOf(p)), true))
            assertEquals(listOf(SynologyPhotoDownloadFormat.ORIGINAL), model.state.value.formats)
        }
        model.open(SynologyPhotoExportRequest.Items(listOf(photo, photo.copy(id = photo.id.copy(itemId = 2)))), true)
        assertFalse(model.state.value.formats.contains(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG))
        model.open(SynologyPhotoExportRequest.Archive(SynologyPhotoArchiveTarget.Album(7), "Synthetic"), true)
        assertEquals(2, model.state.value.formats.size)
        assertFalse(model.open(SynologyPhotoExportRequest.Items(listOf(photo, photo))))
        assertFalse(model.open(SynologyPhotoExportRequest.Items(listOf(photo.copy(id = photo.id.copy(profileId = "other"))))))
        assertTrue(fixture.downloads.isEmpty()); model.dismiss()
    }

    @Test fun `单张校验后选择器暂停保留返回保存才报告成功且不能重复交付`() = runTest {
        val cache = Files.createTempDirectory("photo-export-model-").toFile()
        val output = Files.createTempDirectory("photo-export-result-").toFile()
        val fixture = Fixture(); val model = SynologyPhotoExportModel(fixture, this)
        try {
            model.open(SynologyPhotoExportRequest.Items(listOf(photo)), true)
            model.prepare(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, cache)!!.join()
            val prepared = model.state.value; assertEquals(SynologyPhotoExportPhase.FILE, prepared.phase)
            assertEquals("Synthetic.jpg", prepared.filename); assertEquals("image/jpeg", prepared.mime)
            assertEquals(0, prepared.saved); assertTrue(prepared.file!!.exists())
            model.deactivate(true); assertEquals(prepared, model.state.value)
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val destination = SynologyPhotoExportDestination { file, name, _, check -> entered.complete(Unit); release.await(); check(); file.copyTo(File(output, name)) }
            val job = model.deliver(prepared.id!!, destination, cache)!!; entered.await()
            assertNull(model.deliver(prepared.id, destination, cache)); assertNull(model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache))
            release.complete(Unit); job.join()
            assertEquals(1, model.state.value.saved); assertEquals(SynologyPhotoExportPhase.FINISHED, model.state.value.phase)
            assertArrayEquals(byteArrayOf(1, 2, 3), File(output, "Synthetic.jpg").readBytes()); assertTrue(cache.listFiles()!!.isEmpty())
        } finally { model.dismiss(); cache.deleteRecursively(); output.deleteRecursively() }
    }

    @Test fun `批量先选目录再逐张保存实际原格式保留且部分失败准确计数`() = runTest {
        val cache = Files.createTempDirectory("photo-batch-model-").toFile()
        val fixture = Fixture().apply { actual = SynologyPhotoDownloadFormat.ORIGINAL; failureAt = 2 }
        val model = SynologyPhotoExportModel(fixture, this)
        val names = mutableListOf<String>()
        try {
            model.open(SynologyPhotoExportRequest.Items((1L..3).map { photo.copy(id = photo.id.copy(itemId = it)) }))
            model.prepare(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG, cache)!!.join()
            assertTrue(fixture.downloads.isEmpty()); assertEquals(SynologyPhotoExportPhase.DIRECTORY, model.state.value.phase)
            model.deliver(model.state.value.id!!, SynologyPhotoExportDestination { file, name, mime, check -> check(); assertEquals("application/octet-stream", mime); assertTrue(file.exists()); names += name }, cache)!!.join()
            assertEquals(listOf("Synthetic.heic"), names); assertEquals(1, model.state.value.saved)
            assertEquals(1, model.state.value.retainedOriginals); assertEquals(3, model.state.value.total)
            assertTrue(model.state.value.error is IOException); assertEquals(2, fixture.downloads.size); assertTrue(cache.listFiles()!!.isEmpty())
        } finally { model.dismiss(); cache.deleteRecursively() }
    }

    @Test fun `复制完成后立即取消仍计入已保存项目并停止后续下载`() = runTest {
        val cache = Files.createTempDirectory("photo-cancel-model-").toFile()
        val fixture = Fixture(); val model = SynologyPhotoExportModel(fixture, this)
        try {
            model.open(SynologyPhotoExportRequest.Items(listOf(photo, photo.copy(id = photo.id.copy(itemId = 2)))))
            model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join()
            val job = model.deliver(model.state.value.id!!, SynologyPhotoExportDestination { _, _, _, check -> check(); model.cancel() }, cache)!!
            job.join()
            assertTrue(model.state.value.cancelled); assertEquals(1, model.state.value.saved); assertEquals(1, fixture.downloads.size)
            assertTrue(cache.listFiles()!!.isEmpty())
        } finally { model.dismiss(); cache.deleteRecursively() }
    }

    @Test fun `下载取消不留下暂存文件旧任务不会回填新请求`() = runTest {
        val cache = Files.createTempDirectory("photo-late-model-").toFile()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val fixture = Fixture().apply { hook = { withContext(NonCancellable) { entered.complete(Unit); release.await() } } }
        val model = SynologyPhotoExportModel(fixture, this)
        try {
            model.open(SynologyPhotoExportRequest.Items(listOf(photo)))
            val old = model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!; entered.await()
            assertFalse(model.open(SynologyPhotoExportRequest.Items(listOf(photo))))
            model.cancel(); model.open(SynologyPhotoExportRequest.Items(listOf(photo.copy(id = photo.id.copy(itemId = 2)))))
            val id = model.state.value.id; release.complete(Unit); old.join()
            assertEquals(id, model.state.value.id); assertEquals(SynologyPhotoExportPhase.FORMAT, model.state.value.phase)
            assertNull(model.state.value.file); assertTrue(cache.listFiles()!!.isEmpty())
        } finally { release.complete(Unit); model.dismiss(); cache.deleteRecursively() }
    }

    @Test fun `账号失效和操作中止守卫在下载及本地写入前生效`() = runTest {
        val cache = Files.createTempDirectory("photo-owner-model-").toFile()
        val fixture = Fixture(); var valid = true; var allowed = true; var blocked = true
        val model = SynologyPhotoExportModel(fixture, this, requireOwner = { if (!valid) throw IOException("Synthetic revoked owner") },
            canStart = { allowed }, beforeStart = { if (blocked) throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED) })
        try {
            allowed = false; assertFalse(model.open(SynologyPhotoExportRequest.Items(listOf(photo))))
            allowed = true; model.open(SynologyPhotoExportRequest.Items(listOf(photo)))
            model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join(); assertTrue(fixture.downloads.isEmpty()); assertNotNull(model.state.value.error)
            blocked = false; model.open(SynologyPhotoExportRequest.Items(listOf(photo)))
            model.prepare(SynologyPhotoDownloadFormat.ORIGINAL, cache)!!.join()
            valid = false; var copied = false
            model.deliver(model.state.value.id!!, SynologyPhotoExportDestination { _, _, _, _ -> copied = true }, cache)!!.join()
            assertFalse(copied); assertEquals(0, model.state.value.saved); assertNotNull(model.state.value.error); assertTrue(cache.listFiles()!!.isEmpty())
        } finally { model.dismiss(); cache.deleteRecursively() }
    }

    @Test fun `归档保持目标选择空目录也可保存且原尺寸不能偷偷进入`() = runTest {
        val cache = Files.createTempDirectory("photo-archive-model-").toFile()
        val fixture = Fixture(); val model = SynologyPhotoExportModel(fixture, this)
        try {
            val target = SynologyPhotoArchiveTarget.Folder(9, SynologyPhotoSpace.SHARED)
            model.open(SynologyPhotoExportRequest.Archive(target, "Synthetic folder"), true)
            assertNull(model.prepare(SynologyPhotoDownloadFormat.ORIGINAL_SIZE_JPEG, cache))
            model.prepare(SynologyPhotoDownloadFormat.OPTIMIZED_JPEG, cache)!!.join()
            assertEquals(target, fixture.archive); assertEquals("Synthetic folder.zip", model.state.value.filename)
            assertEquals("application/zip", model.state.value.mime); assertEquals(0, model.state.value.saved)
            model.pickerCancelled("stale-id"); assertEquals(SynologyPhotoExportPhase.FILE, model.state.value.phase)
            model.pickerCancelled(model.state.value.id!!); assertTrue(model.state.value.cancelled)
        } finally { model.dismiss(); cache.deleteRecursively() }
    }

    private class Fixture : SynologyPhotosServing {
        override val profileId = "export-model"
        val downloads = mutableListOf<SynologyPhotoId>()
        var actual: SynologyPhotoDownloadFormat? = null
        var archive: SynologyPhotoArchiveTarget? = null
        var failureAt: Int? = null
        var hook: suspend () -> Unit = {}
        override suspend fun access() = SynologyPhotoAccess(SynologyPhotoSpace.entries, "synthetic")
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun download(photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, destination: File, progress: (Long, Long) -> Unit): SynologyPhotoDownloadFormat {
            downloads += photo.id; hook()
            if (downloads.size == failureAt) throw IOException("Synthetic interrupted transfer")
            destination.writeBytes(byteArrayOf(1, 2, 3)); progress(3, 3)
            return actual ?: format
        }
        override suspend fun downloadArchive(target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, destination: File, progress: (Long, Long) -> Unit) {
            archive = target; destination.writeBytes(byteArrayOf(1, 2, 3)); progress(3, 3)
        }
    }
    companion object { private val photo = SynologyPhoto(SynologyPhotoId("export-model", SynologyPhotoSpace.PERSONAL, 1), "Synthetic.heic", 3, 1.0, 2.0, 9, "photo") }
}
