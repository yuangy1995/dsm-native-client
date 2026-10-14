package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.photos.*
import java.io.File
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosAutomaticPreviewMutationTest {
    @Test fun `两来源实际下载按Unit上传三档图片并持久保存摘要不再要求缺损状态`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) SynologyPhotosAutomaticPreviewFixture(space).use { f ->
            f.ready(); f.uploadHook = { f.large = "ready"; f.small = "ready" }
            val row = f.perform()
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, row.phase); assertEquals(setOf(0), row.completed)
            assertEquals(setOf("xl", "sm", "m"), row.automaticPreview!!.thumbnailDigests.keys)
            assertEquals(listOf("GET", "POST"), f.requests.map { it.method }); assertEquals("[151]", f.requests.first().url.queryParameter("unit_id"))
            val body = f.uploadBodies.single(); assertTrue(body.contains(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam.Upload.ConvertedFile" else "SYNO.Foto.Upload.ConvertedFile"))
            assertEquals("151", body.substringAfter("name=\"unit_id\"").substringAfter("\r\n\r\n").substringBefore("\r\n")); assertFalse(body.contains("film_h264"))
            assertTrue(f.requests.last().body!!.isOneShot()); assertFalse(body.contains("synthetic-token")); assertFalse(body.contains("Synthetic.heic"))
            assertTrue(f.calls.none { it.method in setOf("set_regenerating", "regenerate_preview_by_nas", "set_broken") }); f.clean()
        }
    }
    @Test fun `完整视频与按需三档缩略图共用一次上传并在上传前保存视频摘要`() = runBlocking {
        for (thumb in listOf(false, true)) SynologyPhotosAutomaticPreviewFixture().use { f ->
            f.type = "video"; f.filename = "Synthetic.mov"; if (!thumb) { f.large = "ready"; f.small = "ready" }; f.ready()
            val row = f.perform(); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, row.phase)
            assertEquals(f.signature, row.automaticPreview!!.videoSignature); assertEquals(thumb, row.automaticPreview.thumbnailDigests.isNotEmpty())
            val body = f.uploadBodies.single(); assertTrue(body.contains("name=\"film_h264\"; filename=\"preview.mp4\""))
            assertEquals(thumb, body.contains("thumb_xl")); assertEquals(1, f.conversionCount); f.clean()
        }
    }
    @Test fun `后台转换不猜Item身份且同步回执后可完成`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) SynologyPhotosAutomaticPreviewFixture(space).use { f ->
            f.management = true; f.ready(); val input = f.row(background = true); f.calls.clear()
            val result = f.perform(input); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase)
            assertTrue(f.calls.none { it.api.endsWith(".Browse.Item") }); assertEquals(setOf(0), result.completed); assertTrue(result.targets.isEmpty()); f.clean()
        }
    }
    @Test fun `后台候选消失不认领未知上传而三档内容全部一致才能恢复`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.unknownUpload = true; f.receivedThumbs = f.thumbs.mapValues { byteArrayOf(99) }
            val pending = f.perform(f.row(background = true)); assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
            f.backgroundPresent = false; f.cold(); val still = f.review(pending); assertEquals(SynologyPhotoAlbumPhase.PENDING, still.phase)
            f.receivedThumbs = f.thumbs; val done = f.review(still); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase)
            assertEquals(1, f.uploadBodies.size); assertEquals(1, f.conversionCount); assertTrue(f.calls.none { it.method == "set_broken" }); f.clean()
        }
    }
    @Test fun `未知图片任意一档不符都不认领且恢复读取强制绕过缓存`() = runBlocking {
        for (size in listOf("xl", "sm", "m")) SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.unknownUpload = true
            f.receivedThumbs = f.thumbs + (size to byteArrayOf(99)); val pending = f.perform()
            assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase); f.cold(); f.large = "ready"; f.small = "ready"
            assertEquals(SynologyPhotoAlbumPhase.PENDING, f.review(pending).phase); f.receivedThumbs = f.thumbs
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, f.review(pending).phase)
            for (request in f.requests.filter { it.url.encodedPath.endsWith("Thumbnail/get") }) {
                assertEquals("\"\"", request.url.queryParameter("cache_key")); assertEquals("151", request.url.queryParameter("id"))
                assertEquals("\"unit\"", request.url.queryParameter("type")); assertTrue(request.cacheControl.noCache); assertNull(request.url.queryParameter("album_id"))
            }
            assertEquals(1, f.uploadBodies.size); f.clean()
        }
    }
    @Test fun `未知视频必须读取原H264并比对逐轨内容不能只比时长或字节数`() = runBlocking {
        for (space in SynologyPhotoSpace.entries) SynologyPhotosAutomaticPreviewFixture(space).use { f ->
            f.type = "video"; f.large = "ready"; f.small = "ready"; f.ready(); f.unknownUpload = true
            f.receivedSignature = f.signature.copy(tracks = f.signature.tracks.map { it.copy(contentDigest = "c".repeat(64)) })
            val pending = f.perform(); assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase); f.cold()
            assertEquals(SynologyPhotoAlbumPhase.PENDING, f.review(pending).phase)
            f.receivedSignature = f.signature; assertEquals(SynologyPhotoAlbumPhase.COMPLETED, f.review(pending).phase)
            for (request in f.requests.filter { it.url.queryParameter("method") == "streaming" }) {
                assertEquals("2", request.url.queryParameter("version")); assertEquals("151", request.url.queryParameter("id"))
                assertEquals("\"orig_h264\"", request.url.queryParameter("quality")); assertEquals("true", request.url.queryParameter("use_mov"))
                assertEquals("\"unit\"", request.url.queryParameter("type")); assertNull(request.header("Range"))
                assertTrue(request.cacheControl.noCache)
                assertEquals(if (space == SynologyPhotoSpace.SHARED) "SYNO.FotoTeam.Streaming" else "SYNO.Foto.Streaming", request.url.queryParameter("api"))
            }
            assertEquals(1, f.uploadBodies.size); f.clean()
        }
    }
    @Test fun `明确上传拒绝终止而不标记源损坏`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.uploadResponse = "{\"success\":false,\"error\":{\"code\":100}}"
            val row = f.perform(); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertTrue(row.automaticPreview!!.uploadRejected)
            assertFalse(row.automaticPreview.failureRecorded); assertTrue(f.calls.none { it.method == "set_broken" })
            f.cold(); assertEquals(row, f.review(row)); assertEquals(1, f.uploadBodies.size); f.clean()
        }
    }
    @Test fun `网络HTTP和畸形上传回执保持未知不转失败标记`() = runBlocking {
        for ((code, body) in listOf(500 to "{\"success\":false,\"error\":{\"code\":100}}", 200 to "{}", 200 to "{\"success\":true,\"error\":null}")) {
            SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.uploadCode = code; f.uploadResponse = body
                f.receivedThumbs = f.thumbs.mapValues { byteArrayOf(99) }; val row = f.perform()
                assertEquals(SynologyPhotoAlbumPhase.PENDING, row.phase); assertTrue(row.automaticPreview!!.uploadAttempted)
                assertFalse(row.automaticPreview.uploadRejected); assertTrue(f.calls.none { it.method == "set_broken" }); assertEquals(1, f.uploadBodies.size); f.clean()
            }
        }
    }
    @Test fun `只有明确阶段内容损坏可在持久记录后同步对应失败`() = runBlocking {
        for (kind in SynologyPhotoAutomaticPreviewFailure.entries) SynologyPhotosAutomaticPreviewFixture().use { f ->
            if (kind == SynologyPhotoAutomaticPreviewFailure.VIDEO) f.type = "video"
            f.ready(); f.convertHook = { throw SynologyPhotoAutomaticPreviewConversionFailure(kind) }
            val row = f.perform(); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase)
            assertEquals(kind, row.automaticPreview!!.failureKind); assertTrue(row.automaticPreview.failureRecorded)
            assertFalse(row.automaticPreview.uploadAttempted); assertTrue(row.automaticPreview.thumbnailDigests.isEmpty())
            val call = f.calls.single { it.method == "set_broken" }
            assertEquals(mapOf("id" to "[151]", "type" to if (kind == SynologyPhotoAutomaticPreviewFailure.PHOTO) "[\"photo\"]" else "[\"video\"]"), call.fields)
            assertTrue(f.uploadBodies.isEmpty()); f.clean()
        }
    }
    @Test fun `未知失败标记只有可见项实际broken能够只读收尾`() = runBlocking {
        for (kind in SynologyPhotoAutomaticPreviewFailure.entries) SynologyPhotosAutomaticPreviewFixture().use { f ->
            if (kind == SynologyPhotoAutomaticPreviewFailure.VIDEO) f.type = "video"
            f.ready(); f.convertHook = { throw SynologyPhotoAutomaticPreviewConversionFailure(kind) }; f.brokenHook = { throw IOException("Synthetic disconnect") }
            var row = f.perform(); assertEquals(SynologyPhotoAlbumPhase.PENDING, row.phase); f.cold()
            f.large = "broken"; assertEquals(SynologyPhotoAlbumPhase.PENDING, f.review(row).phase)
            if (kind == SynologyPhotoAutomaticPreviewFailure.PHOTO) f.small = "broken" else f.videoStatus = "broken"
            row = f.review(row); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertTrue(row.automaticPreview!!.failureRecorded)
            assertTrue(row.completed.isEmpty()); assertEquals(1, f.calls.count { it.method == "set_broken" }); f.clean()
        }
    }
    @Test fun `后台未知失败标记不从候选消失推定已记录`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready()
            f.convertHook = { throw SynologyPhotoAutomaticPreviewConversionFailure(SynologyPhotoAutomaticPreviewFailure.PHOTO) }
            f.brokenHook = { throw IOException("Synthetic disconnect") }; val row = f.perform(f.row(background = true))
            f.backgroundPresent = false; f.cold(); assertEquals(SynologyPhotoAlbumPhase.PENDING, f.review(row).phase)
            assertEquals(1, f.calls.count { it.method == "set_broken" }); assertTrue(f.uploadBodies.isEmpty()); f.clean()
        }
    }
    @Test fun `失败标记明确拒绝可终止但不能报告已记录`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready()
            f.convertHook = { throw SynologyPhotoAutomaticPreviewConversionFailure(SynologyPhotoAutomaticPreviewFailure.PHOTO) }
            f.brokenHook = { throw DsmFailure(100, "Synthetic", "Synthetic", kind = DsmErrorKind.REQUEST_FAILED) }; val row = f.perform()
            assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase); assertTrue(row.automaticPreview!!.failureRejected)
            assertFalse(row.automaticPreview.failureRecorded); f.clean()
        }
    }
    @Test fun `普通转换系统资源能力和取消异常都不能写NAS损坏状态`() = runBlocking {
        for (error in listOf(IOException("Synthetic"), PhotoVideoConversionFailure(PhotoVideoFailureKind.UNSUPPORTED),
            PhotoVideoConversionFailure(PhotoVideoFailureKind.UNREADABLE), PhotoVideoConversionFailure(PhotoVideoFailureKind.SYSTEM),
            CancellationException("Synthetic"))) SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.convertHook = { throw error }
            val row = f.perform(); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase)
            assertFalse(row.automaticPreview!!.uploadAttempted); assertNull(row.automaticPreview.failureKind)
            assertTrue(f.uploadBodies.isEmpty()); assertTrue(f.calls.none { it.method == "set_broken" }); f.clean()
        }
    }
    @Test fun `转换后候选改变自动开关关闭或权限撤回都零写入`() = runBlocking {
        for (change in listOf("needs", "enabled", "filename", "owner", "download")) SynologyPhotosAutomaticPreviewFixture(SynologyPhotoSpace.SHARED).use { f ->
            f.ready(); f.convertHook = { when (change) {
                "needs" -> { f.large = "ready"; f.small = "ready" }
                "enabled" -> f.enabled = false
                "filename" -> f.filename = "Changed.heic"
                "owner" -> f.ownerId = 99
                else -> f.download = false
            } }
            f.perform(); assertTrue(f.uploadBodies.isEmpty()); assertTrue(f.calls.none { it.method == "set_broken" }); f.clean()
        }
    }
    @Test fun `转换损坏后仍需候选及开关保持有效才能同步失败`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.convertHook = {
            f.enabled = false; throw SynologyPhotoAutomaticPreviewConversionFailure(SynologyPhotoAutomaticPreviewFailure.PHOTO)
        }; val row = f.perform(); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, row.phase)
            assertNull(row.automaticPreview!!.failureKind); assertTrue(f.calls.none { it.method == "set_broken" }); f.clean()
        }
    }
    @Test fun `上传或失败尝试无法保存时不会外发请求`() = runBlocking {
        for (broken in listOf(false, true)) SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready()
            if (broken) f.convertHook = { throw SynologyPhotoAutomaticPreviewConversionFailure(SynologyPhotoAutomaticPreviewFailure.PHOTO) }
            failure { f.repository.performAutomaticPreview(f.row(), f.cache) { row ->
                if (row.automaticPreview!!.uploadAttempted || row.automaticPreview.failureKind != null) throw IOException("Synthetic storage failed")
                f.save(row)
            } }
            assertTrue(f.uploadBodies.isEmpty()); assertTrue(f.calls.none { it.method == "set_broken" }); f.clean()
        }
    }
    @Test fun `同任务重复perform及冷恢复不会重发未知上传`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.unknownUpload = true; f.receivedThumbs = f.thumbs.mapValues { byteArrayOf(99) }
            val input = f.row(); val pending = f.perform(input); f.perform(input); f.cold(); f.perform(pending)
            assertEquals(1, f.uploadBodies.size); assertEquals(1, f.conversionCount); f.clean()
        }
    }
    @Test fun `并发执行相同任务只转换并上传一次`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); val started = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            f.convertHook = { started.complete(Unit); release.await() }; val row = f.row()
            val first = async { f.perform(row) }; started.await(); val second = async { f.perform(row) }
            yield(); release.complete(Unit)
            assertEquals(SynologyPhotoAlbumPhase.COMPLETED, first.await().phase); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, second.await().phase)
            assertEquals(1, f.conversionCount); assertEquals(1, f.uploadBodies.size); f.clean()
        }
    }
    @Test fun `未提交媒体的冷恢复只终止不会下载转换或补发`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); val row = f.row().copy(phase = SynologyPhotoAlbumPhase.PENDING)
            f.cold(); val result = f.perform(row); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase)
            assertTrue(f.requests.isEmpty()); assertEquals(0, f.conversionCount); f.clean()
        }
    }
    @Test fun `内容回读期间身份变更不能认领且共享后台仍需管理资格`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.unknownUpload = true; f.receivedThumbs = f.thumbs.mapValues { byteArrayOf(99) }
            val row = f.perform(); f.cold(); f.receivedThumbs = f.thumbs; f.thumbnailHook = { if (it == "m") f.filename = "Changed.heic" }
            assertTrue(failure { f.review(row) } is SynologyPhotoFailure); assertEquals(1, f.uploadBodies.size); f.clean()
        }
        SynologyPhotosAutomaticPreviewFixture(SynologyPhotoSpace.SHARED).use { f -> f.management = true; f.ready(); f.unknownUpload = true; f.receivedThumbs = f.thumbs.mapValues { byteArrayOf(99) }
            val row = f.perform(f.row(background = true)); f.management = false; f.cold(); f.requests.clear()
            assertTrue(failure { f.review(row) } is SynologyPhotoFailure); assertTrue(f.requests.isEmpty()); f.clean()
        }
    }
    @Test fun `真实协程取消清理本次目录并保留未决记录待只读恢复`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); val converted = CompletableDeferred<Unit>()
            f.convertHook = { converted.complete(Unit); awaitCancellation() }; val input = f.row()
            val worker = launch { f.perform(input) }; converted.await(); worker.cancelAndJoin()
            f.clean(); assertTrue(f.uploadBodies.isEmpty()); assertTrue(f.calls.none { it.method == "set_broken" })
            f.cold(); assertEquals(SynologyPhotoAlbumPhase.PARTIAL, f.review(f.saved.last()).phase)
        }
    }
    @Test fun `未知后台写入阻止同源编辑导出和其他管理任务`() = runBlocking {
        SynologyPhotosAutomaticPreviewFixture().use { f -> f.ready(); f.unknownUpload = true; f.receivedThumbs = f.thumbs.mapValues { byteArrayOf(99) }
            f.perform(f.row(background = true)); assertTrue(failure { f.repository.downloadOriginal(f.photo(), File(f.cache, "export")) } is SynologyPhotoFailure)
            assertTrue(failure { f.perform(f.row()) } is SynologyPhotoFailure); assertEquals(1, f.uploadBodies.size); f.clean()
        }
    }
    private suspend fun failure(block: suspend () -> Any?): Throwable {
        try { block() } catch (error: Throwable) { return error }; throw AssertionError("应停止不安全的恢复")
    }
}
