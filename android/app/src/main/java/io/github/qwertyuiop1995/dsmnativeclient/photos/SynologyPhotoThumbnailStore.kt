package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.SynologyPhoto
import java.io.Closeable
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit

/** 可见单元共享请求；最后一位等待者离开即取消，不积累滚动离屏后的预取队列。 */
internal class SynologyPhotoThumbnailStore(
    parent: CoroutineScope,
    private val maximumBytes: Int = 16 * 1024 * 1024,
    concurrency: Int = 4,
) : Closeable {
    private val job = SupervisorJob(parent.coroutineContext[Job])
    private val scope = CoroutineScope(parent.coroutineContext + job)
    private val semaphore = Semaphore(concurrency)
    private val mutex = Mutex()
    private data class Key(val photo: String, val unit: Long?, val revision: String?)
    private data class Request(val deferred: Deferred<ByteArray>, var waiters: Int)
    private val cache = LinkedHashMap<Key, ByteArray>(32, 0.75f, true)
    private val requests = mutableMapOf<Key, Request>()
    private var generation = 0L
    private var bytes = 0

    suspend fun load(photo: SynologyPhoto, loader: suspend () -> ByteArray): ByteArray {
        val key = Key("${photo.id.profileId}|${photo.id.space}|${photo.id.itemId}", photo.thumbnail?.unitId, photo.thumbnail?.revision)
        val request = mutex.withLock {
            cache[key]?.let { return it }
            requests[key]?.also { it.waiters++ } ?: run {
                val current = generation
                val deferred = scope.async(start = CoroutineStart.LAZY) {
                    val data = semaphore.withPermit { loader() }
                    currentCoroutineContext().ensureActive()
                    mutex.withLock {
                        if (current == generation && data.size <= maximumBytes) {
                            cache.remove(key)?.let { bytes -= it.size }
                            cache[key] = data
                            bytes += data.size
                            while (bytes > maximumBytes) cache.remove(cache.keys.first())?.let { bytes -= it.size }
                        }
                    }
                    data
                }
                Request(deferred, 1).also { requests[key] = it }
            }
        }
        request.deferred.start()
        return try { request.deferred.await() } finally {
            withContext(NonCancellable) {
                mutex.withLock {
                    request.waiters--
                    if (request.waiters == 0 && requests[key] === request) {
                        requests.remove(key)
                        if (!request.deferred.isCompleted) request.deferred.cancel()
                    }
                }
            }
        }
    }

    suspend fun cost(): Int = mutex.withLock { bytes }
    suspend fun clear() {
        mutex.withLock {
            generation++
            requests.values.forEach { it.deferred.cancel() }
            requests.clear(); cache.clear(); bytes = 0
        }
    }
    override fun close() { job.cancel(); scope.launch(NonCancellable) { clear() } }
}
