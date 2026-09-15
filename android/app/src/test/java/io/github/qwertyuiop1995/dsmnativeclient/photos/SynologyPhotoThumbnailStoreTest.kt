package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SynologyPhotoThumbnailStoreTest {
    @Test fun `同一可见项目合并请求并在最后等待者离开时取消`() = runTest {
        SynologyPhotoThumbnailStore(this).use { cache ->
            var requests = 0
            var cancelled = 0
            val loader: suspend () -> ByteArray = { requests++; try { awaitCancellation() } finally { cancelled++ } }
            val first = async { cache.load(photo(1), loader) }
            val second = async { cache.load(photo(1), loader) }
            runCurrent(); assertEquals(1, requests)
            first.cancelAndJoin(); runCurrent(); assertEquals(0, cancelled)
            second.cancelAndJoin(); runCurrent(); assertEquals(1, cancelled)
        }
    }

    @Test fun `并发上限和缓存字节预算不会随万张图库增长`() = runTest {
        SynologyPhotoThumbnailStore(this, maximumBytes = 6, concurrency = 2).use { cache ->
            var active = 0
            var peak = 0
            val workers = (1L..30L).map { id -> async {
                cache.load(photo(id)) { active++; peak = maxOf(peak, active); delay(10); active--; ByteArray(4) }
            } }
            workers.awaitAll()
            assertEquals(2, peak)
            assertTrue(cache.cost() <= 6)
        }
    }

    @Test fun `修订和账号身份不共享缓存且清理后不插回迟到响应`() = runTest {
        SynologyPhotoThumbnailStore(this, maximumBytes = 8).use { cache ->
            var requests = 0
            suspend fun load(photo: SynologyPhoto) = cache.load(photo) { requests++; byteArrayOf(1) }
            load(photo(1)); load(photo(1))
            assertEquals(1, requests)
            load(photo(1).copy(thumbnail = SynologyPhotoThumbnail(1001, "changed")))
            load(photo(1).copy(id = photo(1).id.copy(profileId = "profile-b")))
            assertEquals(3, requests)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val pending = async {
                cache.load(photo(2)) { withContext(NonCancellable) { entered.complete(Unit); release.await(); byteArrayOf(9) } }
            }
            entered.await(); cache.clear(); release.complete(Unit)
            try { pending.await(); fail("已清理请求应取消") } catch (_: CancellationException) { }
            assertEquals(0, cache.cost())
        }
    }

    private fun photo(id: Long) = SynologyPhoto(SynologyPhotoId("profile-a", SynologyPhotoSpace.PERSONAL, id), "sample.heic", 4,
        100.0, 101.0, 5, "photo", SynologyPhotoThumbnail(id + 1000, "revision"))
}
